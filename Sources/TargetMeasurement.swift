import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// Measures a scanner's MTF from a scanned resolution target, by the slanted-edge method
/// (ISO 12233 style) on the edges of the target's solid squares.
enum TargetMeasurement {
  /// One edge's spatial frequency response, frequencies in cycles per pixel.
  struct Edge {
    var angle: Double
    var freq: [Double]
    var mtf: [Double]
    var mtf50: Double
    var mtf10: Double
    var overshoot: Double
    /// How far the edge drifts across the region, in pixels; under ~0.5 px the phases are too few.
    var drift: Double
  }

  static func measure(_ url: URL) throws -> SharpeningProfile {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { throw DeskError.message("无法读取标靶文件。") }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    let dpi = (props[kCGImagePropertyDPIWidth] as? Double) ?? 0
    guard dpi >= 300 else { throw DeskError.message("标靶文件缺少 dpi 信息，或分辨率低于 300 dpi。") }
    // This app's 48-bit scans are linear; files from other software are assumed gamma 2.2.
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let notes = [kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFImageDescription]
      .compactMap { tiff[$0] as? String }.joined(separator: " ")
    let gamma = notes.contains("identity gamma") || notes.contains("input gamma 1.0") ? 1.0 : 2.2
    let plane = try GreenPlane(image, gamma: gamma)
    let margin = min(48, max(16, Int((0.16 * dpi / 25.4).rounded())))
    var horizontal = [Edge](), vertical = [Edge]()
    for rect in squares(plane, minSide: 3 * margin) {
      let (h, v) = edges(of: rect, in: plane, margin: margin)
      horizontal += h
      vertical += v
      if horizontal.count >= 24 && vertical.count >= 24 { break }
    }
    guard horizontal.count >= 2, vertical.count >= 2 else {
      throw DeskError.message(
        "只找到 \(horizontal.count) 条可用的竖直边缘和 \(vertical.count) 条水平边缘，各需要至少 2 条。请使用带实心方块的分辨率标靶，扫描时让标靶略微倾斜 1–5°。")
    }
    // Median curve per direction, on a grid in cycles per millimetre up to 0.3 cycles per pixel;
    // beyond that a scan at the target's resolution is mostly noise.
    let perMM = dpi / 25.4
    func curve(_ edges: [Edge]) -> [SharpeningProfile.Point] {
      let top = 0.3 * perMM, steps = 48
      var last = 1.0
      return (0...steps).map { i in
        let f = top * Double(i) / Double(steps)
        let values = edges.map { e -> Double in
          let px = f / perMM
          guard let j = e.freq.firstIndex(where: { $0 >= px }), j > 0 else { return e.mtf.first ?? 1 }
          let t = (px - e.freq[j - 1]) / (e.freq[j] - e.freq[j - 1])
          return e.mtf[j - 1] + (e.mtf[j] - e.mtf[j - 1]) * t
        }.sorted()
        let median = values[values.count / 2]
        last = i == 0 ? 1 : min(last, max(SharpeningProfile.floor, median))
        return SharpeningProfile.Point(cyclesPerMM: f, mtf: last)
      }
    }
    return SharpeningProfile(
      source: url.lastPathComponent, measured: Date(), targetDPI: dpi, targetGamma: gamma,
      horizontal: curve(horizontal), vertical: curve(vertical),
      horizontalEdges: horizontal.count, verticalEdges: vertical.count)
  }

  /// The green channel at full resolution, linearized, in a known 16-bit layout.
  struct GreenPlane {
    let width: Int, height: Int
    private var values: [Float]
    init(_ image: CGImage, gamma: Double) throws {
      guard
        let format = vImage_CGImageFormat(
          bitsPerComponent: 16, bitsPerPixel: 64,
          colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
      else { throw DeskError.message("不支持的标靶文件格式。") }
      let buffer = try vImage_Buffer(cgImage: image, format: format)
      defer { buffer.free() }
      width = Int(buffer.width)
      height = Int(buffer.height)
      values = [Float](repeating: 0, count: width * height)
      let g = Float(gamma)
      values.withUnsafeMutableBufferPointer { out in
        for y in 0..<height {
          let row = buffer.data.advanced(by: y * buffer.rowBytes).assumingMemoryBound(to: UInt16.self)
          for x in 0..<width { out[y * width + x] = powf(Float(row[x * 4 + 1]) / 65535, g) }
        }
      }
    }
    subscript(x: Int, y: Int) -> Double { Double(values[y * width + x]) }
    /// Rows × columns, optionally transposed so the edge runs top to bottom.
    func region(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, transposed: Bool) -> (values: [Double], rows: Int, cols: Int) {
      var out = [Double](repeating: 0, count: w * h)
      for y in 0..<h {
        for x in 0..<w {
          let v = Double(values[(y0 + y) * width + x0 + x])
          if transposed { out[x * h + y] = v } else { out[y * w + x] = v }
        }
      }
      return transposed ? (out, w, h) : (out, h, w)
    }
  }

  /// Solid squares, bright on dark or dark on bright, found on a reduced copy of the plane.
  static func squares(_ plane: GreenPlane, minSide: Int) -> [CGRect] {
    let step = max(1, Int((Double(max(plane.width, plane.height)) / 1600).rounded(.up)))
    let tw = plane.width / step, th = plane.height / step
    // Each reduced pixel averages a sparse grid of the block it covers.
    let sub = max(1, step / 2), taps = (step + sub - 1) / sub
    var small = [Double](repeating: 0, count: tw * th)
    for y in 0..<th {
      for x in 0..<tw {
        var s = 0.0
        for dy in stride(from: 0, to: step, by: sub) {
          for dx in stride(from: 0, to: step, by: sub) { s += plane[x * step + dx, y * step + dy] }
        }
        small[y * tw + x] = s / Double(taps * taps)
      }
    }
    let sorted = stride(from: 0, to: small.count, by: 7).map { small[$0] }.sorted()
    let dark = sorted[sorted.count / 50], bright = sorted[sorted.count * 49 / 50]
    guard bright - dark > 0.15 else { return [] }
    let mid = (dark + bright) / 2
    let minSmall = max(4, minSide / step)
    var found = [(rect: CGRect, area: Int)]()
    for brightSquares in [true, false] {
      var label = [Int32](repeating: 0, count: tw * th)
      var next: Int32 = 0
      var stack = [Int]()
      for start in 0..<(tw * th) where label[start] == 0 && ((small[start] > mid) == brightSquares) {
        next += 1
        label[start] = next
        stack.append(start)
        var minX = tw, maxX = 0, minY = th, maxY = 0, area = 0
        while let p = stack.popLast() {
          let x = p % tw, y = p / tw
          area += 1
          minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
          for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < tw && ny < th {
            let q = ny * tw + nx
            if label[q] == 0 && ((small[q] > mid) == brightSquares) {
              label[q] = next
              stack.append(q)
            }
          }
        }
        let w = maxX - minX + 1, h = maxY - minY + 1
        guard w >= minSmall, h >= minSmall, minX > 2, minY > 2, maxX < tw - 3, maxY < th - 3,
          w <= tw / 4, h <= th / 4, Double(w) / Double(h) > 0.25, Double(w) / Double(h) < 4,
          Double(area) / Double(w * h) > 0.82
        else { continue }
        found.append((CGRect(x: minX * step, y: minY * step, width: w * step, height: h * step), area))
      }
    }
    return found.sorted { $0.area > $1.area }.prefix(30).map(\.rect)
  }

  /// The usable edges of one square: vertical edges measure horizontal resolution.
  static func edges(of rect: CGRect, in plane: GreenPlane, margin m: Int) -> (horizontal: [Edge], vertical: [Edge]) {
    // Refine each side to the 50% crossing of the profile through the square's middle.
    let x0 = Int(rect.minX), x1 = Int(rect.maxX), y0 = Int(rect.minY), y1 = Int(rect.maxY)
    let pad = Int(rect.width) / 6 + m
    guard x0 - pad - m > 0, y0 - pad - m > 0, x1 + pad + m < plane.width, y1 + pad + m < plane.height else { return ([], []) }
    func crossing(_ values: [Double], from lo: Int, level: Double, rising: Bool) -> Double? {
      for i in 1..<values.count {
        let a = values[i - 1], b = values[i]
        if rising ? (a < level && b >= level) : (a > level && b <= level) {
          return Double(lo + i - 1) + (level - a) / (b - a)
        }
      }
      return nil
    }
    // Profiles through the middle, each point averaged over 9 lines.
    let midY = (y0 + y1) / 2, midX = (x0 + x1) / 2
    let rowProfile = ((x0 - pad)...(x1 + pad)).map { x in (0..<9).map { plane[x, midY + $0 - 4] }.reduce(0, +) / 9 }
    let colProfile = ((y0 - pad)...(y1 + pad)).map { y in (0..<9).map { plane[midX + $0 - 4, y] }.reduce(0, +) / 9 }
    let inside = rowProfile[rowProfile.count / 2], outside = (rowProfile.first! + rowProfile.last!) / 2
    let level = (inside + outside) / 2
    let brightInside = inside > outside
    guard let left = crossing(rowProfile, from: x0 - pad, level: level, rising: brightInside),
      let right = crossing(Array(rowProfile.reversed()), from: 0, level: level, rising: brightInside)
        .map({ Double(x1 + pad) - $0 }),
      let top = crossing(colProfile, from: y0 - pad, level: level, rising: brightInside),
      let bottom = crossing(Array(colProfile.reversed()), from: 0, level: level, rising: brightInside)
        .map({ Double(y1 + pad) - $0 })
    else { return ([], []) }
    let width = right - left, height = bottom - top
    guard width > Double(3 * m), height > Double(3 * m) else { return ([], []) }
    var horizontal = [Edge](), vertical = [Edge]()
    // Regions: 2m across the edge, the middle 70% along it.
    for (position, isVertical) in [(left, true), (right, true), (top, false), (bottom, false)] {
      let along0 = Int(isVertical ? top + 0.15 * height : left + 0.15 * width)
      let length = Int((isVertical ? height : width) * 0.7)
      let across0 = Int(position.rounded()) - m
      let roi = isVertical
        ? plane.region(across0, along0, 2 * m, length, transposed: false)
        : plane.region(along0, across0, length, 2 * m, transposed: true)
      guard clean(roi.values, rows: roi.rows, cols: roi.cols), let e = sfr(roi.values, rows: roi.rows, cols: roi.cols),
        e.drift >= 0.5, abs(e.angle) < 10, e.mtf50 > 0.01, e.mtf50 < 0.45, e.overshoot < 0.25
      else { continue }
      if isVertical { horizontal.append(e) } else { vertical.append(e) }
    }
    return (horizontal, vertical)
  }

  /// Both sides of the edge are flat and well separated, so no bar or label intrudes.
  static func clean(_ a: [Double], rows: Int, cols: Int) -> Bool {
    func stats(_ c0: Int, _ c1: Int) -> (mean: Double, sd: Double) {
      var s = 0.0, s2 = 0.0, n = 0.0
      for r in 0..<rows { for c in c0..<c1 { let v = a[r * cols + c]; s += v; s2 += v * v; n += 1 } }
      let mean = s / n
      return (mean, sqrt(max(0, s2 / n - mean * mean)))
    }
    let q = cols / 4
    let l = stats(0, q), r = stats(cols - q, cols)
    let contrast = abs(r.mean - l.mean)
    return contrast > 0.1 && l.sd < 0.08 * contrast && r.sd < 0.08 * contrast
  }

  /// Slanted-edge SFR: edge fit, 4× oversampled ESF, windowed LSF, MTF.
  static func sfr(_ values: [Double], rows: Int, cols: Int, bins: Int = 4) -> Edge? {
    guard rows >= 8, cols >= 16 else { return nil }
    var a = values
    func columnMean(_ c0: Int, _ c1: Int) -> Double {
      var s = 0.0
      for r in 0..<rows { for c in c0..<c1 { s += a[r * cols + c] } }
      return s / Double(rows * (c1 - c0))
    }
    if columnMean(0, 4) > columnMean(cols - 4, cols) {
      for r in 0..<rows { a[(r * cols)..<((r + 1) * cols)].reverse() }
    }
    func centroids(_ center: ((Int) -> Double)?) -> [Double] {
      (0..<rows).map { r in
        var sw = 0.0, sx = 0.0
        for i in 0..<(cols - 1) {
          var d = a[r * cols + i + 1] - a[r * cols + i]
          let x = Double(i) + 0.5
          if let center { d *= 0.54 + 0.46 * cos(2 * .pi * (x - center(r)) / Double(3 * cols - 2)) }
          sw += d
          sx += d * x
        }
        return sx / sw
      }
    }
    func fit(_ c: [Double]) -> (slope: Double, intercept: Double) {
      let n = Double(rows), ys = (0..<rows).map(Double.init)
      let my = ys.reduce(0, +) / n, mc = c.reduce(0, +) / n
      var sxy = 0.0, sxx = 0.0
      for (y, v) in zip(ys, c) { sxy += (y - my) * (v - mc); sxx += (y - my) * (y - my) }
      let slope = sxy / sxx
      return (slope, mc - slope * my)
    }
    var line = fit(centroids(nil))
    let first = line
    line = fit(centroids { Double($0) * first.slope + first.intercept })
    guard line.slope.isFinite, line.intercept.isFinite else { return nil }
    let cosine = cos(atan(line.slope))
    var minBin = Int.max, maxBin = Int.min
    var keys = [Int](repeating: 0, count: rows * cols)
    for r in 0..<rows {
      for c in 0..<cols {
        let d = (Double(c) - (line.slope * Double(r) + line.intercept)) * cosine
        let b = Int((d * Double(bins)).rounded(.down))
        keys[r * cols + c] = b
        minBin = min(minBin, b)
        maxBin = max(maxBin, b)
      }
    }
    let count = maxBin - minBin + 1
    var sums = [Double](repeating: 0, count: count), counts = [Double](repeating: 0, count: count)
    for i in 0..<(rows * cols) {
      sums[keys[i] - minBin] += a[i]
      counts[keys[i] - minBin] += 1
    }
    let filled = (0..<count).filter { counts[$0] > 0 }
    guard filled.count > 8 else { return nil }
    var esf = [Double](repeating: 0, count: count)
    for i in 0..<count {
      if counts[i] > 0 { esf[i] = sums[i] / counts[i]; continue }
      let lo = filled.last { $0 < i } ?? filled[0], hi = filled.first { $0 > i } ?? filled.last!
      esf[i] = lo == hi ? sums[lo] / counts[lo]
        : sums[lo] / counts[lo] + (sums[hi] / counts[hi] - sums[lo] / counts[lo]) * Double(i - lo) / Double(hi - lo)
    }
    // Trim the sparsely sampled ends.
    let trim = 2 * bins
    guard count > 4 * trim else { return nil }
    esf = Array(esf[trim..<(count - trim)])
    let n = esf.count, sixth = max(1, n / 6)
    func median(_ s: ArraySlice<Double>) -> Double { let v = s.sorted(); return v[v.count / 2] }
    let dark = median(esf[0..<sixth]), bright = median(esf[(n - sixth)..<n])
    guard bright - dark > 1e-4 else { return nil }
    let norm = esf.map { ($0 - dark) / (bright - dark) }
    var lsf = [Double](repeating: 0, count: n)
    for i in 0..<n {
      lsf[i] = i == 0 ? norm[1] - norm[0] : i == n - 1 ? norm[n - 1] - norm[n - 2] : (norm[i + 1] - norm[i - 1]) / 2
    }
    let peak = lsf.indices.max { lsf[$0] < lsf[$1] }!
    let windowed = (0..<n).map { i -> Double in
      let j = Double(n - peak + i)
      return lsf[i] * (0.54 - 0.46 * cos(2 * .pi * j / Double(2 * n - 1)))
    }
    var freq = [Double](), mtf = [Double]()
    var dc = 0.0
    for k in 0...(n / 2) {
      var re = 0.0, im = 0.0
      for i in 0..<n {
        let phase = 2 * .pi * Double(k * i) / Double(n)
        re += windowed[i] * cos(phase)
        im -= windowed[i] * sin(phase)
      }
      let magnitude = (re * re + im * im).squareRoot()
      if k == 0 { dc = magnitude }
      let f = Double(k) / (Double(n) / Double(bins))
      // Correct for the central difference over ±1 bin.
      let x = 2 * f / Double(bins)
      let correction = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
      guard correction > 0.2 else { break }
      freq.append(f)
      mtf.append(magnitude / max(dc, 1e-12) / correction)
    }
    func at(_ level: Double) -> Double {
      for i in 1..<mtf.count where mtf[i] < level {
        return freq[i - 1] + (freq[i] - freq[i - 1]) * (mtf[i - 1] - level) / (mtf[i - 1] - mtf[i])
      }
      return freq.last ?? 0
    }
    return Edge(
      angle: atan(line.slope) * 180 / .pi, freq: freq, mtf: mtf, mtf50: at(0.5), mtf10: at(0.1),
      overshoot: (norm.max() ?? 1) - 1, drift: abs(line.slope) * Double(rows))
  }
}
