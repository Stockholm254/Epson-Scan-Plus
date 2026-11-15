import CoreGraphics
import CoreImage
import Foundation

/// The copy stand's light, measured and taken out of what the camera read: its crosstalk, then its
/// fall-off across the frame.
extension ImagePipeline {
  /// `image`, linear as the camera read it, with the copy light's `crosstalk` taken out of every
  /// pixel (kept above nothing, so each still has a density) and then `flat` divided out, each light
  /// by its own fall-off, so the frame reads as if lit everywhere as its brightest part.
  func corrected(_ image: CGImage, crosstalk: Crosstalk?, flat: FlatField?) -> CGImage {
    guard crosstalk != nil || flat != nil else { return image }
    let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    var ci = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    if let crosstalk {
      let k = crosstalk.inverse, least = 1.0 / 65535
      ci = ci.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: k[0], y: k[1], z: k[2], w: 0),
        "inputGVector": CIVector(x: k[3], y: k[4], z: k[5], w: 0),
        "inputBVector": CIVector(x: k[6], y: k[7], z: k[8], w: 0),
      ]).applyingFilter("CIColorClamp", parameters: [
        "inputMinComponents": CIVector(x: least, y: least, z: least, w: 0),
        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
      ])
    }
    if let flat, let divide = Kernels.flatten, let grid = flatImage(flat, size: extent.size) {
      ci = divide.apply(extent: extent, arguments: [ci, grid]) ?? ci
    }
    return image16(ci.cropped(to: extent), extent: extent, colorSpace: image.colorSpace ?? outputSpace) ?? image
  }

  /// The flat field's grid as an image over `size`, between the cells' centres. A bitmap's first row
  /// is its top, as the grid's is.
  func flatImage(_ flat: FlatField, size: CGSize) -> CIImage? {
    guard flat.width > 0, flat.height > 0, flat.values.count == flat.width * flat.height * 3 else { return nil }
    var rgba = [Float](repeating: 1, count: flat.width * flat.height * 4)
    for i in 0..<(flat.width * flat.height) {
      for c in 0..<3 { rgba[i * 4 + c] = flat.values[i * 3 + c] }
    }
    let grid = CIImage(
      bitmapData: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: flat.width * 16,
      size: CGSize(width: flat.width, height: flat.height), format: .RGBAf, colorSpace: nil)
    // Each cell's value at its centre, linear between them, held out to the picture's edges.
    let sx = size.width / CGFloat(flat.width), sy = size.height / CGFloat(flat.height)
    return grid.clampedToExtent()
      .transformed(by: CGAffineTransform(translationX: -0.5, y: -0.5))
      .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
      .transformed(by: CGAffineTransform(translationX: sx / 2, y: sy / 2))
      .cropped(to: CGRect(origin: .zero, size: size))
  }

  /// A blank frame's readings over the picture (no film; the copies' lens, aperture, magnification
  /// and light), as `FlatProfile` keeps them: each channel's median over a grid of 48 × 32 cells,
  /// linear as read. A cell the holder's mask covers or crosses (its darkest tenth under half its
  /// median, or its median under a quarter of the brightest) takes the readings of the nearest cell
  /// wholly lit: a mask edge's half-lit median would brighten the film beside it, and leaving it
  /// alone would leave the edge dark. Too dark, clipped over more than a hundredth of it, too little
  /// of it lit, or not blank (neighbouring cells differing more than a fall-off does: there is a
  /// picture on it), it says so.
  static let flatGrid = (width: 48, height: 32)
  func blankCells(_ image: CGImage) throws -> [Float] {
    let s = samples(image, maxDimension: 960)
    func median(_ v: [Double]) -> Double {
      guard !v.isEmpty else { return 0 }
      let sorted = v.sorted()
      return sorted[sorted.count / 2]
    }
    var clipped = 0
    for y in 0..<s.height { for x in 0..<s.width { let p = s.pixel(x, y); if max(p.r, p.g, p.b) >= 0.98 { clipped += 1 } } }
    guard clipped * 100 <= s.width * s.height else {
      throw DeskError.message("空白帧过曝了：降低曝光，让最亮处约 70%（看直方图）再拍一张。")
    }
    let gw = Self.flatGrid.width, gh = Self.flatGrid.height, n = gw * gh
    var medians = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
    var lit = [Bool](repeating: false, count: n)
    for cy in 0..<gh {
      for cx in 0..<gw {
        var v = [[Double](), [Double](), [Double]()], level = [Double]()
        for y in (cy * s.height / gh)..<max(cy * s.height / gh + 1, (cy + 1) * s.height / gh) {
          for x in (cx * s.width / gw)..<max(cx * s.width / gw + 1, (cx + 1) * s.width / gw) {
            let p = s.pixel(x, y)
            level.append(max(p.r, p.g, p.b))
            if max(p.r, p.g, p.b) < 0.98 { for c in 0..<3 { v[c].append(p.values[c]) } }
          }
        }
        let i = cy * gw + cx
        for c in 0..<3 { medians[c][i] = median(v[c]) }
        let sorted = level.sorted()
        lit[i] = !sorted.isEmpty && sorted[sorted.count / 10] > sorted[sorted.count / 2] / 2
      }
    }
    let tops = (0..<3).map { c in (0..<n).filter { lit[$0] }.map { medians[c][$0] }.max() ?? 0 }
    guard tops.allSatisfy({ $0 > 0.03 }) else {
      throw DeskError.message("空白帧太暗：曝光到最亮处约 70%（看直方图）再拍一张。")
    }
    for i in 0..<n where lit[i] { lit[i] = (0..<3).allSatisfy { medians[$0][i] >= tops[$0] / 4 } }
    // Most of a blank is lit well, its corners a vignetting's fall-off down; a negative's picture
    // lies a density below the clear rebate around it.
    let bright = (0..<n).filter { i in lit[i] && (0..<3).allSatisfy { medians[$0][i] > tops[$0] / 2 } }.count
    guard bright * 2 >= n else {
      throw DeskError.message("这张不像空白帧：大部分地方比最亮处暗一半以上（像底片的画面，或片夹挡住了太多）。拿走底片，用同样的镜头、光圈、放大倍率和灯拍一张，再用那张。")
    }
    for c in 0..<3 {
      // A fall-off changes little from one cell to the next; a picture changes a lot.
      var steps = [Double]()
      for cy in 0..<gh {
        for cx in 0..<gw {
          let i = cy * gw + cx
          for (nx, ny) in [(cx + 1, cy), (cx, cy + 1)] where nx < gw && ny < gh {
            let j = ny * gw + nx
            if lit[i] && lit[j] && min(medians[c][i], medians[c][j]) > tops[c] / 2 { steps.append(abs(log(medians[c][i] / medians[c][j]))) }
          }
        }
      }
      let sorted = steps.sorted()
      guard sorted.count > 100, sorted[sorted.count * 9 / 10] < 0.06 else {
        throw DeskError.message("这张不像空白帧：上面有画面或底片。拿走底片，用同样的镜头、光圈、放大倍率和灯拍一张，再用那张。")
      }
    }
    // Each cell not wholly lit takes the nearest wholly lit cell's readings.
    let litCells = (0..<n).filter { lit[$0] }
    var cells = [Float](repeating: 0, count: n * 3)
    for i in 0..<n {
      let from = lit[i] ? i : litCells.min { a, b in
        let (ax, ay, bx, by, ix, iy) = (a % gw, a / gw, b % gw, b / gw, i % gw, i / gw)
        return (ax - ix) * (ax - ix) + (ay - iy) * (ay - iy) < (bx - ix) * (bx - ix) + (by - iy) * (by - iy)
      } ?? i
      for c in 0..<3 { cells[i * 3 + c] = Float(medians[c][from]) }
    }
    return cells
  }

  /// One light alone on a blank frame, as the camera read it (`lightReading`).
  struct LightReading: Equatable {
    /// The channel it reads brightest in: which light it is.
    var own: Int
    /// Each channel against `own` (1), its median over where `own` is well exposed: the light's
    /// column of the crosstalk.
    var column: [Double]
    /// `own`'s median there, and its brightest (the 99.5th percentile over the frame), of full.
    var level: Double
    var peak: Double
    /// The share of the frame at full in some channel.
    var clipped: Double
    /// How far the light's largest leak varies across the frame: its interquartile range against
    /// its median. One light read through the same filters leaks alike everywhere; other light
    /// (a room's, a second lamp) does not.
    var spread: Double
    /// The pixels `own` is well exposed in (between 5% and 95% of full).
    var count: Int
    /// The largest of the other channels against `own`, and which.
    var leak: (channel: Int, share: Double) {
      let others = (0..<3).filter { $0 != own && $0 < column.count }
      let c = others.max { column[$0] < column[$1] } ?? (own + 1) % 3
      return (c, c < column.count ? column[c] : 0)
    }
  }
  /// What a frame of one light alone tells of the copy light: over the frame but its outer
  /// twentieth, which channel it is, what it leaks into the others, how well it is exposed. Nil
  /// for a frame with no pixels.
  func lightReading(_ image: CGImage) -> LightReading? {
    let s = samples(image, maxDimension: 600)
    func median(_ v: [Double]) -> Double {
      guard !v.isEmpty else { return 0 }
      let s = v.sorted()
      return s[s.count / 2]
    }
    var pixels = [RGB]()
    for y in stride(from: s.height / 20, to: s.height - s.height / 20, by: 2) {
      for x in stride(from: s.width / 20, to: s.width - s.width / 20, by: 2) { pixels.append(s.pixel(x, y)) }
    }
    guard !pixels.isEmpty else { return nil }
    let clipped = Double(pixels.filter { max($0.r, $0.g, $0.b) >= 0.98 }.count) / Double(pixels.count)
    let levels = (0..<3).map { c in median(pixels.map { p in p.values[c] }) }
    let own = levels.indices.max { levels[$0] < levels[$1] } ?? 0
    let brightest = pixels.map { $0.values[own] }.sorted()
    let peak = brightest[min(brightest.count - 1, brightest.count * 995 / 1000)]
    let lit = pixels.filter { p in p.values[own] > 0.05 && p.values[own] < 0.95 }
    let measured = lit.isEmpty ? pixels.filter { $0.values[own] > 0 } : lit
    var column = [Double]()
    for c in 0..<3 { column.append(c == own ? 1 : median(measured.map { p in p.values[c] / max(p.values[own], 1e-6) })) }
    var reading = LightReading(own: own, column: column, level: median(measured.map { $0.values[own] }), peak: peak,
      clipped: clipped, spread: 0, count: lit.count)
    let c = reading.leak.channel
    let ratios = measured.map { p in p.values[c] / max(p.values[own], 1e-6) }.sorted()
    if ratios.count > 3, reading.leak.share > 0 {
      reading.spread = (ratios[ratios.count * 3 / 4] - ratios[ratios.count / 4]) / reading.leak.share
    }
    return reading
  }
  /// The crosstalk of a red, green and blue light's readings, in that order: each its column.
  /// Nil unless each is well enough exposed to measure (`count`), its own light, and leaks less
  /// than 0.8 into any other channel.
  static func crosstalk(_ readings: [LightReading]) -> Crosstalk? {
    guard readings.count == 3, readings.enumerated().allSatisfy({ j, r in
      r.own == j && r.count > 100 && r.column.count == 3 && (0..<3).allSatisfy { $0 == j || r.column[$0] < 0.8 }
    }) else { return nil }
    return Crosstalk(m: (0..<3).flatMap { c in readings.map { $0.column[c] } })
  }

  /// The copy light's crosstalk from its red, green and blue lights each alone on a blank frame (no film), in any
  /// order: which light each frame shows is told by its brightest channel. Each light's column of the
  /// crosstalk is the median of the other channels against its own, over the frame where it is well
  /// exposed (between 5% and 95% of full). Nil when the three frames are not one light each, or a light
  /// is too weak to measure.
  func lightCalibration(_ frames: [CGImage], date: Date = Date()) -> (calibration: LightCalibration, exposure: RGB)? {
    guard frames.count == 3 else { return nil }
    let read = frames.compactMap(lightReading)
    let ordered = (0..<3).compactMap { j in read.first { $0.own == j } }
    guard read.count == 3, ordered.count == 3, let crosstalk = Self.crosstalk(ordered) else { return nil }
    return (LightCalibration(date: date, crosstalk: crosstalk), RGB(ordered.map(\.level)))
  }
}
