import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Raster {
  let width: Int
  let height: Int
  var bytes: [UInt8]
  func pixel(_ x: Int, _ y: Int) -> RGB {
    let p = (min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))) * 4
    return RGB(
      r: Double(bytes[p]) / 255, g: Double(bytes[p + 1]) / 255, b: Double(bytes[p + 2]) / 255)
  }
}

/// Float RGBA samples, top row first; see `ImagePipeline.samples`.
struct Samples {
  let width: Int
  let height: Int
  var values: [Float]
  func pixel(_ x: Int, _ y: Int) -> RGB {
    let p = (min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))) * 4
    return RGB(r: Double(values[p]), g: Double(values[p + 1]), b: Double(values[p + 2]))
  }
}

struct ToneAnalysis {
  var base: RGB
  var balance: RGB
  var low: Double
  var high: Double
  var gain: RGB = .one
  /// Over how much log exposure above the base the balance fades in (0: applied evenly), and how
  /// far it has faded in at a picked grey, which keeps it in full, as everything lighter does.
  var fade = 0.0, fadeAtGrey = 1.0
  /// How far the highlights run past `high`: where the frame's brightest 0.1% lie, in the same log
  /// exposure, in their brightest channel once saturated (`ImagePipeline.reach`); nil where the
  /// white is set by hand (a picked highlight, levels off).
  var reach: Double? = nil
}

final class ImagePipeline {
  // The input and kernel operate on encoded scanner values, without implicit ICC transforms.
  // inputGamma is explicit because a 16-bit TIFF is not necessarily linear sensor data.
  let context = CIContext(options: [
    .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false,
  ])
  let outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  static let shared = ImagePipeline()
  /// The ends run out as on paper (`Adjustments.softEnds`): under `softToe` the blacks fall smoothly
  /// towards nothing instead of being cut, the darkest 0.5% of a frame coming out a little above
  /// black (t/e), so their channels still differ and keep their colour; over `softShoulder` the
  /// highlights roll off towards white, never quite reaching it; and the shadows get up to
  /// `shadowColour` more saturation, less as they lighten, as colour runs out there on a screen.
  /// `highlightColour` is how much of a bright colour the shoulder keeps: at 1 the brightest channel
  /// rolls off and the others stay as far below it, so a white lit by the sky and one lit by the sun
  /// still differ near white; at 0 each channel rolls off by itself and they close up into one white.
  /// In the kernel's output values (encoded, 0-1).
  /// Keeping the colour brings every channel down as far as the brightest, so a sky far past white
  /// in its blue comes out darker than the per-channel roll-off had it; `highlightLightness` lifts
  /// it that share of the way back, its hue kept, its colour a little paler.
  static var softToe = 0.05, softShoulder = 0.9, shadowColour = 0.3, highlightColour = 1.0, highlightLightness = 0.5
  /// That shoulder holds what lies up to about half a stop past white; a frame's highlights often
  /// run further, and the negative still has them. So the shoulder reaches as far as the frame's
  /// brightest 0.1% (`ToneAnalysis.reach`), up to `reachStops` past its white, as a print's paper
  /// eases its highlights into white (`shoulder`); highlights −1 takes it `highlightsReach` further.
  /// That brightest 0.1% is counted with the frame `reachDimension` pixels across (`pixelReach`),
  /// not on the analysis' 300-pixel samples, which average a white sign or a lit edge away with
  /// what lies round it; 0 counts it on those samples only.
  static var reachStops = 2.0, highlightsReach = 2.0, reachDimension = 1500
  /// The longer shoulder for `s` and `a`, as the kernel takes it: from `x` up along a log curve
  /// that leaves the straight line at slope 1 and brings `x + y` to 0.98, `z` its bend, then out
  /// to white; `w` how far it replaces the short one, nothing for highlights within its reach.
  static func shoulder(_ s: Adjustments, _ a: ToneAnalysis) -> CIVector {
    guard s.softEndsOn && s.inputIsNegative else { return CIVector(x: 0, y: 0, z: 0, w: 0) }
    let stop = log10(2.0)
    let top = min(max(a.reach ?? a.high, a.high), a.high + reachStops * stop) + max(0, -s.highlightsAmount) * highlightsReach * stop
    // Where the kernel's levels, colour and contrast put it, in its warmest or coolest channel.
    var q = (top + s.exposure * stop - a.low) / max(a.high - a.low, 0.001)
    q = (q - s.black) / max(s.white - s.black, 0.01)
    q += max(s.warmth * 0.12 + s.tint * 0.05, -s.tint * 0.10, -s.warmth * 0.12 + s.tint * 0.05)
    q = (q - 0.5) * s.contrast + 0.5
    // The short shoulder brings 1.1 within 0.015 of white; from there to 1.25 the longer takes over.
    let t = min(1, max(0, (q - 1.1) / 0.15))
    guard t > 0 else { return CIVector(x: 0, y: 0, z: 0, w: 0) }
    let knee = 0.8, span = q - knee, room = 0.98 - knee
    // Slope 1 where it leaves the straight line: room · c / ln(1 + c · span) = 1.
    var lo = 1e-6, hi = 1e6
    for _ in 0..<100 {
      let c = (lo * hi).squareRoot()
      if room * c / log1p(c * span) > 1 { hi = c } else { lo = c }
    }
    return CIVector(x: knee, y: span, z: (lo * hi).squareRoot(), w: t * t * (3 - 2 * t))
  }
  /// A balance that makes the greys grey (a calibrated preset's neutral, a picked grey, Dmax) is
  /// worked out on the straight part of the film's curve. Film that took no light is black in every
  /// layer, and black is neutral; there the balance would only lift red and blue into a purple
  /// black. So, where no fitted toe bends the curve down to the base, the balance fades in over
  /// about a toe's width of log exposure above it (the Kodak sheets' toes are 0.10–0.165): 95% of
  /// it by 0.36, 1.2 stops up.
  static var unexposedFade = 0.12
  /// `image` with its colour smoothed over `radius` pixels and its lightness kept exactly: colour
  /// noise (the sensor's, and what taking the crosstalk out adds to it) goes, the grain stays. The
  /// colour has no lightness of its own, so its blur leaves the luma as it was. Scaled with the
  /// picture, as a smaller one has its noise averaged away already.
  func colourSmoothed(_ image: CIImage, radius: Double) -> CIImage {
    guard radius >= 0.3, let split = Kernels.colourOf, let join = Kernels.withColour,
      let colour = split.apply(extent: image.extent, arguments: [image])
    else { return image }
    let smooth = colour.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
    return join.apply(extent: image.extent, arguments: [image, smooth]) ?? image
  }
  /// Tone curves as a lookup (`Kernels.curves`), from a 1024-entry table.
  func applyCurves(_ curves: ToneCurves, to image: CIImage) -> CIImage {
    guard !curves.isIdentity, let curveKernel = Kernels.curves else { return image }
    let n = 1024
    let entries = curves.table(n)
    let table = CIImage(
      bitmapData: entries.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: n * 16,
      size: CGSize(width: n, height: 1), format: .RGBAf, colorSpace: nil)
    return curveKernel.apply(
      extent: image.extent, roiCallback: { index, rect in index == 0 ? rect : table.extent },
      arguments: [image, table, Float(n)]) ?? image
  }

  func load(_ url: URL, maxDimension: Int? = nil) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw DeskError.message("无法读取图像：\(url.lastPathComponent)")
    }
    if let maxDimension {
      let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      if let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
        return image
      }
    }
    guard
      let image = CGImageSourceCreateImageAtIndex(
        src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { throw DeskError.message("不支持的图像格式。") }
    if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
      let orientation = props[kCGImagePropertyOrientation] as? Int, orientation != 1
    {
      let ci = CIImage(cgImage: image, options: [.colorSpace: NSNull()]).oriented(
        forExifOrientation: Int32(orientation))
      if let upright = context.createCGImage(
        ci, from: ci.extent, format: image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8,
        colorSpace: image.colorSpace ?? outputSpace)
      {
        return upright
      }
    }
    return image
  }
  func info(_ url: URL) -> (width: Int, height: Int, bits: Int, dpi: Double) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    else { return (0, 0, 0, 0) }
    return (
      (p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0,
      (p[kCGImagePropertyDepth] as? Int) ?? 0, (p[kCGImagePropertyDPIWidth] as? Double) ?? 0
    )
  }
  /// The size `load(url)` gives the picture in a TIFF, PNG or JPEG, turned by its orientation,
  /// read from the file's header: no pixels. Nil for other files (a camera's raw, whose decoded
  /// size the header does not promise) or one that cannot be read.
  func headerSize(_ url: URL) -> CGSize? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let type = CGImageSourceGetType(src) as String?,
      [UTType.tiff.identifier, UTType.png.identifier, UTType.jpeg.identifier].contains(type),
      let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
      let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
    else { return nil }
    let orientation = p[kCGImagePropertyOrientation] as? Int ?? 1
    return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
  }
  func crop(_ image: CGImage, rect: NormalRect) throws -> CGImage {
    let r = rect.pixels(CGSize(width: image.width, height: image.height))
    guard r.width >= 2, r.height >= 2, let result = image.cropping(to: r) else {
      throw DeskError.message("裁切范围太小。")
    }
    return result
  }
  func raster(_ image: CGImage, maxDimension: Int = 600) -> Raster {
    let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
    let w = max(1, Int(Double(image.width) * scale))
    let h = max(1, Int(Double(image.height) * scale))
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ci = CIImage(cgImage: image, options: [.colorSpace: NSNull()]).transformed(
      by: CGAffineTransform(scaleX: scale, y: scale))
    bytes.withUnsafeMutableBytes { p in
      context.render(
        ci, toBitmap: p.baseAddress!, rowBytes: w * 4,
        bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: nil)
    }
    // CIContext render(toBitmap:) preserves CGImage's top-row-first byte order.
    return Raster(width: w, height: h, bytes: bytes)
  }
  /// Float samples for statistics and picking: a linear scan keeps only a few 8-bit codes in a
  /// negative's dense areas, which would quantize film base, end points and neutral samples.
  func samples(_ image: CGImage, maxDimension: Int) -> Samples {
    let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
    let w = max(1, Int(Double(image.width) * scale))
    let h = max(1, Int(Double(image.height) * scale))
    var values = [Float](repeating: 0, count: w * h * 4)
    let ci = CIImage(cgImage: image, options: [.colorSpace: NSNull()]).transformed(
      by: CGAffineTransform(scaleX: scale, y: scale))
    values.withUnsafeMutableBytes { p in
      context.render(
        ci, toBitmap: p.baseAddress!, rowBytes: w * 16,
        bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
    }
    return Samples(width: w, height: h, values: values)
  }
  /// The roll's film base: unexposed film between neighbouring frames on the overview, shared by
  /// every frame of the strip. Nil unless the gaps are even and no denser than the frames' thinnest film.
  func rollBase(_ overview: CGImage, frames: [FilmFrame]) -> RGB? {
    let s = samples(overview, maxDimension: max(overview.width, overview.height))
    let size = CGSize(width: s.width, height: s.height)
    var gap = [[Double](), [Double](), [Double]()], inside = [[Double](), [Double](), [Double]()]
    func collect(_ r: CGRect, into values: inout [[Double]], step: Int = 1) {
      guard r.width >= 1, r.height >= 1 else { return }
      for y in stride(from: Int(r.minY), to: Int(r.maxY), by: step) {
        for x in stride(from: Int(r.minX), to: Int(r.maxX), by: step) {
          let p = s.pixel(x, y).values
          for c in 0..<3 { values[c].append(p[c]) }
        }
      }
    }
    let rects = frames.map { $0.rect.pixels(size) }
    for (i, a) in rects.enumerated() {
      collect(a.insetBy(dx: a.width * 0.1, dy: a.height * 0.1), into: &inside, step: 3)
      for b in rects[(i + 1)...] {
        // Neighbours side by side or one above the other, with a narrow gap between them.
        let (l, r) = a.minX <= b.minX ? (a, b) : (b, a), (t, u) = a.minY <= b.minY ? (a, b) : (b, a)
        let gapX = r.minX - l.maxX, overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let gapY = u.minY - t.maxY, overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        if gapX >= 2, gapX < 0.12 * min(l.width, r.width), overlapY > 0.6 * min(a.height, b.height) {
          collect(CGRect(x: l.maxX + gapX * 0.3, y: max(a.minY, b.minY) + overlapY * 0.15,
            width: gapX * 0.4, height: overlapY * 0.7), into: &gap)
        } else if gapY >= 2, gapY < 0.12 * min(t.height, u.height), overlapX > 0.6 * min(a.width, b.width) {
          collect(CGRect(x: max(a.minX, b.minX) + overlapX * 0.15, y: t.maxY + gapY * 0.3,
            width: overlapX * 0.7, height: gapY * 0.4), into: &gap)
        }
      }
    }
    guard gap[0].count >= 30, !inside[0].isEmpty else { return nil }
    let base = RGB(gap.map { quantile($0, 0.5) })
    // Unexposed film is the thinnest film on the roll, and it is even.
    let thinnest = inside.map { quantile($0, 0.99) }
    let even = (0..<3).allSatisfy { (quantile(gap[$0], 0.9) - quantile(gap[$0], 0.1)) / max(1e-6, base.values[$0]) < 0.25 }
    guard even, (0..<3).allSatisfy({ base.values[$0] > thinnest[$0] * 0.97 }) else { return nil }
    return base
  }
  func quantile(_ a: [Double], _ p: Double) -> Double {
    quantiles(a, [p])[0]
  }
  /// Several quantiles of `a` from one sort.
  func quantiles(_ a: [Double], _ ps: [Double]) -> [Double] {
    let v = a.sorted()
    return ps.map { p in v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count - 1) * p))] }
  }

  /// The pixels colour statistics use, as density above the film base, with the base found.
  func densities(_ image: CGImage, settings: Adjustments, maxDimension: Int = 300) -> (base: RGB, density: [[Double]]) {
    densities(samples(image, maxDimension: maxDimension), settings: settings)
  }
  func densities(_ r: Samples, settings: Adjustments) -> (base: RGB, density: [[Double]]) {
    var pixels = [[Double]]()
    // Statistics are deliberately separate from the export crop. Ignore the outer
    // 5% on each side, including residual film-base/holder edges in older projects.
    // Never feed the expanded crop/film-base editing context into these statistics.
    let marginX = max(1, Int(ceil(Double(r.width) * 0.05)))
    let marginY = max(1, Int(ceil(Double(r.height) * 0.05)))
    for y in marginY..<max(marginY + 1, r.height - marginY) {
      for x in marginX..<max(marginX + 1, r.width - marginX) {
        let p = r.pixel(x, y).values
        // Clipped light (leaks, clear film) carries no density.
        if p.min()! < 0.995 && p.max()! > 0 { pixels.append(p.map { max(1e-6, $0) }) }
      }
    }
    // A picked base wins, then the roll's base from between the frames, then this frame's thinnest film.
    let base = settings.base ?? settings.rollBase
      ?? RGB((0..<3).map { c in max(0.001, quantile(pixels.map { $0[c] }, 0.995)) })
    // Only near-opaque areas, over 3.0 D above the base in every channel (holder, frame lines),
    // are left out, so a linear scan's densest highlights stay in the statistics.
    var density = [[Double](), [Double](), [Double]()]
    for p in pixels {
      let d = (0..<3).map { log10(max(0.0001, base.values[$0]) / p[$0]) * settings.inputGamma }
      guard d.contains(where: { $0 < 3 }) else { continue }
      for c in 0..<3 { density[c].append(d[c]) }
    }
    if density[0].isEmpty {
      density = (0..<3).map { c in pixels.map { log10(max(0.0001, base.values[c]) / $0[c]) * settings.inputGamma } }
    }
    return (base, density)
  }

  /// The slopes a frame converts with, and whether they fix each channel's contrast: a calibrated
  /// preset first, then the roll's own estimate, then the preset's data-sheet slopes. Only the
  /// generic preset without a roll estimate leaves channel contrast to per-frame stretching.
  /// The preset's toe, when the frame's film base is measured (between the frames, or picked). A
  /// base guessed from the frame's own thinnest area is already up the toe, and bending from there
  /// would tint the shadows, so then the straight line is kept.
  static func toe(_ s: Adjustments, _ p: FilmProfile) -> RGB {
    (s.base ?? s.rollBase) != nil ? p.toe ?? .zero : .zero
  }
  static func slopes(_ s: Adjustments, _ p: FilmProfile) -> (slopes: RGB, fixed: Bool) {
    if p.offsets != nil { return (p.slopes, true) }
    if let roll = s.rollSlopes { return (roll, true) }
    return (p.slopes, p.setsChannelContrast)
  }

  /// Channel slopes for a whole roll from local density gradients, after the gray-edge idea in
  /// colour constancy: shading (light falling off across a surface, texture, folds, waves) changes
  /// every channel's log exposure alike, so where green density changes, red and blue change in
  /// the ratio of their slopes. Scene colour that goes with brightness, such as a blue sky over
  /// darker ground, does not enter as it does in global statistics, and the median over every edge
  /// of the roll keeps colour edges from pulling it. Green keeps the preset's slope. Nil for fewer
  /// than two frames, too few edges, or an implausible result.
  /// With a `toe`, density steps near the base are smaller than the exposure steps behind them, by a
  /// different amount per channel; a second pass weighs each edge by the toe's stretch there.
  func rollSlopes(_ frames: [(image: CGImage, settings: Adjustments)], greenSlope: Double, toe: RGB? = nil) -> RGB? {
    guard let first = rollSlopes(frames, greenSlope: greenSlope, stretchedBy: nil) else { return nil }
    guard let toe, toe.values.contains(where: { $0 > 0 }) else { return first }
    return rollSlopes(frames, greenSlope: greenSlope, stretchedBy: (first, toe)) ?? first
  }
  private func rollSlopes(
    _ frames: [(image: CGImage, settings: Adjustments)], greenSlope: Double, stretchedBy toe: (slopes: RGB, widths: RGB)?
  ) -> RGB? {
    guard frames.count >= 2 else { return nil }
    var ratios = [[Double](), [Double]()]
    for f in frames {
      let s = samples(f.image, maxDimension: 240), w = s.width, h = s.height
      let base = densities(s, settings: f.settings).base
      // Density per channel, smoothed by a 3×3 box against grain and noise.
      var b = [[Double]](repeating: [Double](repeating: 0, count: w * h), count: 3)
      for c in 0..<3 {
        let lit = max(0.0001, base.values[c]), gamma = f.settings.inputGamma
        var d = [Double](repeating: 0, count: w * h), row = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) { d[i] = log10(lit / max(1e-6, Double(s.values[i * 4 + c]))) * gamma }
        for y in 0..<h {
          for x in 0..<w {
            let l = max(0, x - 1), r = min(w - 1, x + 1)
            row[y * w + x] = (d[y * w + l] + d[y * w + x] + d[y * w + r]) / 3
          }
        }
        for y in 0..<h {
          let u = max(0, y - 1), v = min(h - 1, y + 1)
          for x in 0..<w { b[c][y * w + x] = (row[u * w + x] + row[y * w + x] + row[v * w + x]) / 3 }
        }
      }
      // Gradients over 2 px each way, inside the same 5% margins as the colour statistics.
      let mx = Int(ceil(Double(w) * 0.05)) + 3, my = Int(ceil(Double(h) * 0.05)) + 3
      guard w > 2 * mx, h > 2 * my else { continue }
      let (red, green, blue) = (b[0], b[1], b[2])
      for y in my..<(h - my) {
        for x in mx..<(w - mx) {
          let i = y * w + x
          // Near the base the film's toe flattens; near opaque only noise is left.
          guard min(red[i], green[i], blue[i]) > 0.05, max(red[i], green[i], blue[i]) < 2.6 else { continue }
          let gx = green[i + 2] - green[i - 2], gy = green[i + 2 * w] - green[i - 2 * w]
          let m = gx * gx + gy * gy
          guard m > 0.03 * 0.03 else { continue }
          // Where shading changes every exposure alike, each channel's density step is its slope over
          // the toe's stretch there; dividing that out leaves the ratio of slopes.
          var weight = (r: 1.0, b: 1.0)
          if let toe {
            let g = FilmToe.stretch(green[i] / toe.slopes.g, width: toe.widths.g)
            weight = (FilmToe.stretch(red[i] / toe.slopes.r, width: toe.widths.r) / g,
                      FilmToe.stretch(blue[i] / toe.slopes.b, width: toe.widths.b) / g)
          }
          ratios[0].append(((red[i + 2] - red[i - 2]) * gx + (red[i + 2 * w] - red[i - 2 * w]) * gy) / m * weight.r)
          ratios[1].append(((blue[i + 2] - blue[i - 2]) * gx + (blue[i + 2 * w] - blue[i - 2 * w]) * gy) / m * weight.b)
        }
      }
    }
    guard ratios[0].count >= 500 else { return nil }
    let k = ratios.map { quantile($0, 0.5) }
    guard k.allSatisfy({ $0 > 0.5 && $0 < 2 }) else { return nil }
    return RGB(r: greenSlope * k[0], g: greenSlope, b: greenSlope * k[1])
  }

  func analyze(_ image: CGImage, settings: Adjustments, profile: FilmProfile) -> ToneAnalysis {
    let (base, density) = densities(image, settings: settings)
    var a = analyze(base: base, density: density, settings: settings, profile: profile)
    if let sampled = a.reach, let counted = pixelReach(image, settings: settings, profile: profile, analysis: a) {
      a.reach = max(sampled, counted)
    }
    // The roll's print: its balance, or its ends, in place of this frame's own, where they are left
    // to the app (no grey, white or balance of the frame's own, no calibrated neutral).
    if let print = settings.rollPrint, settings.highlightSample == nil {
      if settings.sharedBalance == true, settings.autoWhiteBalance, settings.neutralSample == nil, settings.manualBalance == nil, profile.offsets == nil {
        // The frame's ends move with the balance, so it is lit as before, only its colour the roll's.
        let shift = (0..<3).map { print.balance.values[$0] - a.balance.values[$0] }.reduce(0, +) / 3
        a.balance = print.balance
        a.gain = print.gain
        a.low += shift
        a.high += shift
        a.reach = a.reach.map { $0 + shift }
      }
      if settings.sharedLevels == true, settings.autoLevels {
        a.low = print.low
        a.high = print.high
        a.reach = print.reach ?? a.reach
      }
    }
    return a
  }
  /// One print for a roll from its frames' densities together, each above its own base, as one
  /// frame's statistics are worked out; nil without frames. Its highlights reach as far as the
  /// brightest frame's: the roll's shoulder holds every frame's.
  func rollPrint(_ frames: [(image: CGImage, settings: Adjustments)], profile: FilmProfile) -> RollPrint? {
    guard let first = frames.first else { return nil }
    let each = frames.map { f -> (image: CGImage, base: RGB, density: [[Double]], settings: Adjustments) in
      let d = densities(f.image, settings: f.settings)
      return (f.image, d.base, d.density, f.settings)
    }.filter { !$0.density[0].isEmpty }
    var pooled = [[Double](), [Double](), [Double]()]
    for f in each { for c in 0..<3 { pooled[c] += f.density[c] } }
    guard !pooled[0].isEmpty else { return nil }
    var s = first.settings
    (s.neutralSample, s.manualBalance, s.highlightSample) = (nil, nil, nil)
    (s.autoWhiteBalance, s.autoLevels) = (true, true)
    let a = analyze(base: .one, density: pooled, settings: s, profile: profile)
    let reach = each.map { f -> Double in
      let sampled = self.reach(exposures(f.density, settings: s, profile: profile), gain: a.gain, balance: a.balance, weight: nil, saturation: f.settings.saturation)
      var own = a
      (own.base, own.fade, own.fadeAtGrey) = (f.base, 0, 1)
      return max(sampled, pixelReach(f.image, settings: f.settings, profile: profile, analysis: own) ?? sampled)
    }.max()
    return RollPrint(balance: a.balance, gain: a.gain, low: a.low, high: a.high, reach: reach)
  }
  /// Each channel's log exposure from its density above the base, through the film's slopes and toe.
  func exposures(_ density: [[Double]], settings: Adjustments, profile: FilmProfile) -> [[Double]] {
    let (slopes, _) = Self.slopes(settings, profile)
    let toe = Self.toe(settings, profile)
    return (0..<3).map { c in density[c].map { FilmToe.exposure($0 / slopes.values[c], width: toe.values[c]) } }
  }
  /// How far highlights run: where the brightest 0.1% of `e` lie through `gain` and `balance`, in
  /// their brightest channel once saturated, as the kernel saturates them ahead of the shoulder.
  func reach(_ e: [[Double]], gain: RGB, balance: RGB, weight: [Double]?, saturation: Double) -> Double {
    // The same sums as channel by channel, without an array for every sample.
    let n = e[0].count
    let (g0, g1, g2) = (gain.values[0], gain.values[1], gain.values[2])
    let (b0, b1, b2) = (balance.values[0], balance.values[1], balance.values[2])
    var peaks = [Double](repeating: 0, count: n)
    e[0].withUnsafeBufferPointer { r in
      e[1].withUnsafeBufferPointer { g in
        e[2].withUnsafeBufferPointer { b in
          for i in 0..<n {
            let w = weight?[i] ?? 1
            let x0 = r[i] * g0 + b0 * w, x1 = g[i] * g1 + b1 * w, x2 = b[i] * g2 + b2 * w
            let l = 0.2126 * x0 + 0.7152 * x1 + 0.0722 * x2
            peaks[i] = max(l + saturation * (x0 - l), l + saturation * (x1 - l), l + saturation * (x2 - l))
          }
        }
      }
    }
    return quantile(peaks, 0.999)
  }
  /// The same, counted on the GPU over `image` brought to `reachDimension` pixels across, through
  /// the frame's conversion up to its saturation and with none of the user's print exposure,
  /// contrast, colour or levels, as `reach` has it. At 300 pixels a white sign or a lit edge is a
  /// sample or two wide and averaged with what lies round it: a sunlit copy read 0.4 stop past
  /// white there and 1.4 per pixel, so its shoulder stayed short and crushed the sign. At 1500
  /// they keep their light while the grain is still averaged away, and a preview and a full export,
  /// both brought to that size, read alike. Nil for a positive.
  func pixelReach(_ image: CGImage, settings s: Adjustments, profile: FilmProfile, analysis a: ToneAnalysis) -> Double? {
    guard Self.reachDimension > 0, s.inputIsNegative, let toned = Kernels.negativeRange else { return nil }
    let scale = min(1, Double(Self.reachDimension) / Double(max(image.width, image.height)))
    let ci = CIImage(cgImage: image, options: [.colorSpace: NSNull()]).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    var plain = s
    (plain.exposure, plain.contrast, plain.warmth, plain.tint, plain.shadowWarmth, plain.black, plain.white) = (0, 1, 0, 0, nil, 0, 1)
    guard let tones = toned.apply(extent: ci.extent, arguments: Self.arguments(ci, plain, profile, a)) else { return nil }
    // Each pixel's brightest channel, counted in `n` steps from `lo` to `lo + span`, past them in the end steps.
    let n = 2048, lo = -1.0, span = 4.0
    let peaks = tones.applyingFilter("CIMaximumComponent").applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: 1 / span, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: -lo / span, y: 0, z: 0, w: 0),
    ])
    let counts = peaks.applyingFilter("CIAreaHistogram", parameters: [
      kCIInputExtentKey: CIVector(cgRect: peaks.extent), "inputCount": n, kCIInputScaleKey: 1,
    ])
    var out = [Float](repeating: 0, count: n * 4)
    out.withUnsafeMutableBytes {
      context.render(counts, toBitmap: $0.baseAddress!, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: 1), format: .RGBAf, colorSpace: nil)
    }
    let steps = (0..<n).map { Double(out[$0 * 4]) }, total = steps.reduce(0, +)
    guard total > 0 else { return nil }
    var run = 0.0
    for (i, v) in steps.enumerated() {
      run += v
      if run >= total * 0.999 { return a.low + (lo + (Double(i) + 0.5) * span / Double(n)) * (a.high - a.low) }
    }
    return nil
  }
  /// The least a scene's automatic ends span, in log exposure: 4 stops. A shorter one (fog, haze,
  /// flat light) keeps its shortness rather than being pulled out to a full black and white.
  /// Measured on the author's library, the flattest of 262 frames spans 1.25 and the middle 1.6,
  /// so none of them changes; NexFilm's 0.8 D would have reached into ordinary overcast frames.
  static let shortestEnds = 1.2
  /// A frame's balance and ends from its densities above `base`; `shortestEnds` as above.
  func analyze(
    base: RGB, density: [[Double]], settings: Adjustments, profile: FilmProfile, shortestEnds: Double = ImagePipeline.shortestEnds
  ) -> ToneAnalysis {
    let (slopes, fixed) = Self.slopes(settings, profile)
    let toe = Self.toe(settings, profile)
    func exposure(_ density: Double, _ c: Int) -> Double { FilmToe.exposure(density / slopes.values[c], width: toe.values[c]) }
    let e = exposures(density, settings: settings, profile: profile)
    // Independent robust endpoints correct color crossover, not just a single median offset.
    // They are scene statistics, not an ICC calibration; manual neutral/temperature remain available.
    // Each channel sorted once; every quantile of it below is read from that one sort.
    let sorted = e.map { $0.sorted() }
    func at(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count - 1) * p))] }
    let channelLow = sorted.map { at($0, 0.01) }
    let channelHigh = sorted.map { at($0, 0.99) }
    let spans = (0..<3).map { max(0.05, channelHigh[$0] - channelLow[$0]) }
    let commonSpan = quantile(spans, 0.5)
    var gain = RGB.one
    var balance = RGB.zero
    func pointExposure(_ v: RGB) -> [Double] {
      (0..<3).map { exposure(log10(max(0.0001, base.values[$0]) / max(0.0001, v.values[$0])) * settings.inputGamma, $0) }
    }
    let grey = settings.neutralSample.map(pointExposure)
    if let grey {
      // With auto white balance on, the generic preset still fits each channel's contrast to the
      // scene; the picked grey then sets where the channels meet.
      if settings.autoWhiteBalance && !fixed {
        gain = RGB(spans.map { clamp(commonSpan / $0, 0.5, 2) })
      }
      let d = (0..<3).map { grey[$0] * gain.values[$0] }
      let mean = d.reduce(0, +) / 3
      balance = RGB(d.map { mean - $0 })
    } else if let manual = settings.manualBalance {
      balance = manual
    } else if let offsets = profile.offsets {
      // A calibrated preset knows where this film, on this scanner or copy stand, puts a neutral in
      // the light it was calibrated in, so that sets the balance, auto or not. The scene's darkest
      // corner often lies on the base, unexposed: aligning it would take the layers' differing
      // speeds for a cast.
      balance = RGB(offsets.values.map { -$0 })
    } else if settings.autoWhiteBalance {
      // Fixed slopes (roll estimate or a film's data sheet) supply each channel's contrast, so auto
      // white balance only aligns the channels' black points. The generic preset without a roll
      // estimate stretches each channel to the scene's own contrast instead.
      if !fixed {
        gain = RGB(spans.map { clamp(commonSpan / $0, 0.5, 2) })
      }
      balance = RGB((0..<3).map { -channelLow[$0] * gain.values[$0] })
    }
    // The densest highlight picked as white (Dmax): each channel stretched from its own reference,
    // the picked grey, a calibrated preset's neutral, the scene's black under auto white balance,
    // else the film base, up to it, so the highlight comes out a neutral white, and with auto levels
    // the white of the picture.
    var white: Double?
    if let picked = settings.highlightSample {
      let top = pointExposure(picked)
      let reference = grey
        ?? (settings.manualBalance != nil ? [0, 0, 0]
          : profile.offsets?.values ?? (settings.autoWhiteBalance ? channelLow : [0, 0, 0]))
      let reach = (0..<3).map { max(0.02, top[$0] - reference[$0]) }
      let target = reach.reduce(0, +) / 3
      gain = RGB(reach.map { clamp(target / $0, 0.5, 2) })
      let anchored = (0..<3).map { reference[$0] * gain.values[$0] }
      let meet = grey == nil ? 0 : anchored.reduce(0, +) / 3
      balance = RGB(anchored.map { meet - $0 })
      white = (0..<3).map { top[$0] * gain.values[$0] + balance.values[$0] }.reduce(0, +) / 3
    }
    // Unexposed film comes out a neutral black (`unexposedFade`), unless the balance already starts
    // from the scene's black or a fitted toe takes the curve down to the base.
    let fromBlack = settings.neutralSample == nil && settings.manualBalance == nil && profile.offsets == nil
      && settings.autoWhiteBalance
    let fade = fromBlack || toe.values.contains { $0 > 0 } ? 0 : Self.unexposedFade
    func fadedIn(_ e: [Double]) -> Double { 1 - exp(-max(0, e.reduce(0, +) / 3) / fade) }
    let fadeAtGrey = fade > 0 ? max(0.001, grey.map(fadedIn) ?? 1) : 1
    let weight = fade > 0
      ? (0..<e[0].count).map { i in min(1, fadedIn([e[0][i], e[1][i], e[2][i]]) / fadeAtGrey) } : nil
    var lows = [Double]()
    var highs = [Double]()
    for c in 0..<3 {
      if let weight {
        let x = (0..<e[c].count).map { e[c][$0] * gain.values[c] + balance.values[c] * weight[$0] }
        let q = quantiles(x, [0.005, 0.995])
        lows.append(q[0])
        highs.append(q[1])
      } else {
        let q = [at(sorted[c], 0.005), at(sorted[c], 0.995)].map { $0 * gain.values[c] + balance.values[c] }
        lows.append(q[0])
        highs.append(q[1])
      }
    }
    var low = settings.autoLevels ? (lows.min() ?? 0) : 0
    var high = settings.autoLevels ? max(low + 0.05, white ?? highs.max() ?? 2) : 3.6
    // A short scene opened about its middle to `shortestEnds`: its middle tones stay where they
    // were, so it prints grey and soft as the film saw it, not darker (NexFilm found a floor kept
    // from the black end darkened such frames). A white picked by hand is the user's own end.
    if settings.autoLevels, white == nil, high - low < shortestEnds {
      let middle = (low + high) / 2
      (low, high) = (middle - shortestEnds / 2, middle + shortestEnds / 2)
    }
    let reach = settings.autoLevels && white == nil
      ? self.reach(e, gain: gain, balance: balance, weight: weight, saturation: settings.saturation) : nil
    return ToneAnalysis(
      base: base, balance: balance, low: low, high: high, gain: gain, fade: fade, fadeAtGrey: fadeAtGrey, reach: reach)
  }

  /// `sharpener` deconvolves the scan in linear light first; tone statistics use the scan as is.
  func output(
    _ image: CGImage, settings s: Adjustments, profile: FilmProfile, analysis: ToneAnalysis? = nil,
    sharpener: Sharpener? = nil, extendedRange: Bool = false
  ) throws -> CIImage {
    let a = analysis ?? analyze(image, settings: s, profile: profile)
    guard let kernel = extendedRange ? Kernels.negativeUnclipped : Kernels.negative else { throw DeskError.message("图像处理内核初始化失败。") }
    let source = try sharpener.map { try sharpen(image, with: $0) } ?? image
    let ci = CIImage(cgImage: source, options: [.colorSpace: NSNull()])
    guard var result = kernel.apply(extent: ci.extent, arguments: Self.arguments(ci, s, profile, a)) else {
      throw DeskError.message("图像处理失败。")
    }
    if let amount = s.colourNoise, amount > 0 {
      result = colourSmoothed(result, radius: amount * 0.0002 * Double(max(ci.extent.width, ci.extent.height)))
    }
    if let curves = s.curves { result = applyCurves(curves, to: result) }
    result = Self.straightened(result, degrees: s.angle ?? 0)
    if s.rotation % 4 != 0 {
      let orientation: Int32 = [1, 6, 3, 8][((s.rotation % 4) + 4) % 4]
      result = result.oriented(forExifOrientation: orientation)
    }
    if s.flipHorizontal == true {
      result = result.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
    }
    return result.transformed(
      by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
  }
  /// The `negative` kernels' arguments for `ci`.
  static func arguments(_ ci: CIImage, _ s: Adjustments, _ profile: FilmProfile, _ a: ToneAnalysis) -> [Any] {
    func v(_ c: RGB) -> CIVector { CIVector(x: c.r, y: c.g, z: c.b) }
    let fine = s.baseFine ?? .zero
    let effectiveBase = RGB(
      (0..<3).map { max(0.0001, a.base.values[$0]) * pow(2, fine.values[$0]) })
    return [
      ci, v(effectiveBase), v(Self.slopes(s, profile).slopes), v(Self.toe(s, profile)), v(a.gain), v(a.balance),
      CIVector(x: a.low, y: a.high, z: s.black, w: s.white),
      CIVector(x: s.exposure, y: s.midtone, z: s.contrast, w: s.saturation),
      CIVector(x: s.warmth, y: s.tint, z: s.shadowWarmthAmount, w: s.inputGamma),
      s.softEndsOn && s.inputIsNegative
        ? CIVector(x: Self.softToe, y: Self.softShoulder, z: Self.shadowColour, w: Self.highlightColour) : CIVector(x: 0, y: 2, z: 0, w: 0),
      s.inputIsNegative ? 1.0 : 0.0,
      CIVector(x: a.fade, y: a.fadeAtGrey),
      CIVector(x: s.shadowsAmount, y: s.highlightsAmount, z: s.pressHighlightsAmount, w: Self.highlightLightness),
      Self.shoulder(s, a),
    ]
  }
  /// Where `image`'s tones lie against what a screen shows of them (`ToneRange`), as `negative`
  /// takes them into its ends: counted over every pixel, as grain and fine highlights are what
  /// reach furthest and a smaller copy averages them away (the brightest 0.1% of a sunlit frame
  /// read a stop lower at 300 pixels across than at 3000). The screen's black and white are found
  /// by sending a grey ramp over that scale through the frame's ends, midtone and curves.
  func toneRange(_ image: CGImage, settings s: Adjustments, profile: FilmProfile, analysis a: ToneAnalysis) -> ToneRange? {
    guard let toned = Kernels.negativeRange, let ended = Kernels.negative else { return nil }
    let ci = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    guard let tones = toned.apply(extent: ci.extent, arguments: Self.arguments(ci, s, profile, a)) else { return nil }
    // Counted on the GPU in `n` steps from `lo` to `lo + span`, past them in the end steps: each
    // channel, and each pixel's brightest and darkest channel; shares of the frame.
    let n = 2048, lo = -1.0, span = 4.0, width = span / Double(n)
    let onto = tones.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: 1 / span, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1 / span, z: 0, w: 0),
      "inputBVector": CIVector(x: 0, y: 0, z: 1 / span, w: 0), "inputBiasVector": CIVector(x: -lo / span, y: -lo / span, z: -lo / span, w: 0),
    ])
    func counted(_ image: CIImage) -> [Float] {
      let counts = image.applyingFilter("CIAreaHistogram", parameters: [
        kCIInputExtentKey: CIVector(cgRect: image.extent), "inputCount": n, kCIInputScaleKey: 1,
      ])
      var out = [Float](repeating: 0, count: n * 4)
      out.withUnsafeMutableBytes {
        context.render(counts, toBitmap: $0.baseAddress!, rowBytes: n * 16, bounds: CGRect(x: 0, y: 0, width: n, height: 1), format: .RGBAf, colorSpace: nil)
      }
      return out
    }
    let each = counted(onto), tops = counted(onto.applyingFilter("CIMaximumComponent")), bottoms = counted(onto.applyingFilter("CIMinimumComponent"))
    let channels = (0..<3).map { c in (0..<n).map { Double(each[$0 * 4 + c]) } }
    let top = (0..<n).map { Double(tops[$0 * 4]) }, bottom = (0..<n).map { Double(bottoms[$0 * 4]) }
    func at(_ i: Int) -> Double { lo + (Double(i) + 0.5) * width }
    func step(_ q: Double) -> Int { min(n - 1, max(0, Int((q - lo) / width))) }
    func above(_ h: [Double], _ q: Double) -> Double { h[step(q)...].reduce(0, +) / max(1e-12, h.reduce(0, +)) }
    func below(_ h: [Double], _ q: Double) -> Double { h[...step(q)].reduce(0, +) / max(1e-12, h.reduce(0, +)) }
    func quantile(_ h: [Double], _ p: Double) -> Double {
      let want = h.reduce(0, +) * p
      var run = 0.0
      for (i, v) in h.enumerated() {
        run += v
        if run >= want { return at(i) }
      }
      return at(n - 1)
    }
    // The ramp from −1 to 3 on that scale, passed in 2 higher, as a positive is, and levelled from 2
    // to 3 with nothing else in front, so the kernel's ends are all that acts on it.
    let m = 1601, rampStep = span / Double(m - 1)
    let grey = (0..<m).flatMap { (i: Int) -> [Float] in let v = Float(lo + Double(i) * rampStep + 2); return [v, v, v, 1] }
    let line = CIImage(bitmapData: Data(bytes: grey, count: grey.count * 4), bytesPerRow: m * 16,
      size: CGSize(width: m, height: 1), format: .RGBAf, colorSpace: nil)
    var flat = Self.arguments(line, s, profile, a)
    flat[6] = CIVector(x: 0, y: 1, z: 2, w: 3)
    flat[7] = CIVector(x: 0, y: s.midtone, z: 1, w: 1)
    flat[8] = CIVector(x: 0, y: 0, z: 0, w: 1)
    flat[10] = 0.0
    guard var shown = ended.apply(extent: line.extent, arguments: flat) else { return nil }
    if let curves = s.curves { shown = applyCurves(curves, to: shown) }
    var screen = [Float](repeating: 0, count: m * 4)
    screen.withUnsafeMutableBytes {
      context.render(shown, toBitmap: $0.baseAddress!, rowBytes: m * 16, bounds: line.extent, format: .RGBAf, colorSpace: nil)
    }
    // A channel shows black up to the last step at 0 in 8 bits, white from the first at 255; the
    // band is where every channel still has gradation.
    let blackSteps = (0..<3).map { c in (0..<m).last { screen[$0 * 4 + c] < 0.5 / 255 } }
    let whiteSteps = (0..<3).map { c in (0..<m).first { screen[$0 * 4 + c] >= 254.5 / 255 } }
    let black = blackSteps.compactMap { $0 }.max().map { lo + Double($0) * rampStep }
    let white = whiteSteps.compactMap { $0 }.min().map { lo + Double($0) * rampStep }
    let stop = s.inputIsNegative
      ? log10(2.0) * s.contrast / (max(a.high - a.low, 0.001) * max(s.white - s.black, 0.01)) : nil
    // Shown from a little below the darkest 0.1% (the holder's black left to the first step) to a
    // little past the brightest 0.05%, the screen's ends and two stops past white.
    let from = max(-0.35, min(-0.1, (black ?? 0) - 0.05, quantile(bottom, 0.001) - 0.05))
    let to = min(lo + span, max(1.3, (white ?? 1) + 0.1, quantile(top, 0.9995) + 0.05, 1 + 2 * (stop ?? 0) + 0.05))
    let bins = 120
    var counts = [[Double]](repeating: [Double](repeating: 0, count: bins), count: 3)
    for c in 0..<3 {
      for i in 0..<n where channels[c][i] > 0 {
        counts[c][min(bins - 1, max(0, Int((at(i) - from) / (to - from) * Double(bins))))] += channels[c][i]
      }
    }
    return ToneRange(
      counts: counts, domain: from...to, black: black, white: white, stop: stop,
      pastWhite: above(top, 1 + width / 2), atWhite: white.map { above(top, $0) } ?? 0,
      atBlack: black.map { below(bottom, $0) } ?? 0, brightest: quantile(top, 0.999))
  }
  /// The shares of `image`, a picture as shown, with a channel at white and with one at black: what
  /// comes after the ends included, as the colour smoothing, which can take a channel of a bright
  /// edge over white.
  func screenShares(_ image: CGImage) -> (white: Double, black: Double) {
    let ci = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    func counted(_ filter: String) -> [Float] {
      let counts = ci.applyingFilter(filter).applyingFilter("CIAreaHistogram", parameters: [
        kCIInputExtentKey: CIVector(cgRect: ci.extent), "inputCount": 256, kCIInputScaleKey: 1,
      ])
      var out = [Float](repeating: 0, count: 256 * 4)
      out.withUnsafeMutableBytes {
        context.render(counts, toBitmap: $0.baseAddress!, rowBytes: 256 * 16, bounds: CGRect(x: 0, y: 0, width: 256, height: 1), format: .RGBAf, colorSpace: nil)
      }
      return out
    }
    let tops = counted("CIMaximumComponent"), bottoms = counted("CIMinimumComponent")
    return (Double(tops[255 * 4]), Double(bottoms[0]))
  }
  /// `image` turned clockwise on screen by `degrees` about its middle and cut to the largest
  /// rectangle of its own shape inside, so no corner is left empty; as ImageGeometry maps it.
  static func straightened(_ image: CIImage, degrees: Double) -> CIImage {
    guard abs(degrees) > 0.0001 else { return image }
    let e = image.extent, k = CGFloat(ImageGeometry.keep(degrees, aspect: Double(e.width / max(1, e.height))))
    let c = CGPoint(x: e.midX, y: e.midY)
    // Core Image counts up: clockwise on screen is a negative angle here.
    let turn = CGAffineTransform(translationX: -c.x, y: -c.y)
      .concatenating(CGAffineTransform(rotationAngle: -CGFloat(degrees * .pi / 180)))
      .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
    let kept = CGRect(x: c.x - e.width * k / 2, y: c.y - e.height * k / 2, width: e.width * k, height: e.height * k)
    // Whole pixels inside the kept rectangle, so no edge pixel is one stretched from beyond the frame.
    let inside = CGRect(
      x: kept.minX.rounded(.up), y: kept.minY.rounded(.up),
      width: kept.maxX.rounded(.down) - kept.minX.rounded(.up), height: kept.maxY.rounded(.down) - kept.minY.rounded(.up))
    return image.clampedToExtent().transformed(by: turn).cropped(to: inside)
  }
  func preview(_ image: CGImage, settings: Adjustments, profile: FilmProfile) throws -> CGImage {
    let ci = try output(image, settings: settings, profile: profile)
    guard
      let cg = context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: outputSpace)
    else { throw DeskError.message("无法生成预览。") }
    return cg
  }
  func render(
    _ image: CGImage, settings: Adjustments, profile: FilmProfile, analysis: ToneAnalysis?,
    negative: Bool, sharpener: Sharpener? = nil
  ) -> CGImage? {
    guard let ci = shown(image, settings: settings, profile: profile, analysis: analysis, negative: negative, sharpener: sharpener) else { return nil }
    return context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: outputSpace)
  }
  /// Only `region` (normalised to the picture as shown, top left at 0) of `image` rendered: Core
  /// Image works out no more of the frame than that, so a part of a 60-megapixel frame takes a
  /// fraction of the whole.
  func render(
    _ image: CGImage, region: NormalRect, settings: Adjustments, profile: FilmProfile, analysis: ToneAnalysis?, negative: Bool
  ) -> (image: CGImage, region: NormalRect)? {
    guard let ci = shown(image, settings: settings, profile: profile, analysis: analysis, negative: negative) else { return nil }
    let e = ci.extent
    let r = CGRect(x: region.x * e.width, y: (1 - region.y - region.height) * e.height, width: region.width * e.width, height: region.height * e.height)
      .integral.intersection(e)
    guard r.width >= 1, r.height >= 1, let cg = context.createCGImage(ci, from: r, format: .RGBA8, colorSpace: outputSpace) else { return nil }
    return (cg, NormalRect(x: r.minX / e.width, y: 1 - r.maxY / e.height, width: r.width / e.width, height: r.height / e.height))
  }
  /// Each channel divided by the film base (picked, the roll's, or the frame's edges'): the base
  /// shows neutral grey at its own brightness, neither the mask's orange nor a copy light's green,
  /// and what is left is what the layers made, which also shows whether a pick was on the base. A
  /// power-law encoding keeps neutral neutral, so no decoding is needed. As it is with no base.
  static func baseNeutral(_ ci: CIImage, base: RGB?) -> CIImage {
    guard let base, base.values.allSatisfy({ $0 > 1e-4 }) else { return ci }
    let mean = (base.r + base.g + base.b) / 3
    return ci.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: mean / base.r, y: 0, z: 0, w: 0),
      "inputGVector": CIVector(x: 0, y: mean / base.g, z: 0, w: 0),
      "inputBVector": CIVector(x: 0, y: 0, z: mean / base.b, w: 0),
    ])
  }
  /// A negative as the light table shows it, as it lies: its base a neutral grey (`baseNeutral`).
  func neutralNegative(_ image: CGImage, settings: Adjustments) -> CGImage {
    let ci = Self.baseNeutral(CIImage(cgImage: image, options: [.colorSpace: NSNull()]), base: settings.base ?? settings.rollBase)
    return context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: image.colorSpace ?? outputSpace) ?? image
  }
  /// The picture as shown, positive or negative, straightened, turned and mirrored, from the origin.
  private func shown(
    _ image: CGImage, settings: Adjustments, profile: FilmProfile, analysis: ToneAnalysis?,
    negative: Bool, sharpener: Sharpener? = nil
  ) -> CIImage? {
    var ci: CIImage
    if negative {
      ci = Self.baseNeutral(CIImage(cgImage: image, options: [.colorSpace: NSNull()]), base: analysis?.base ?? settings.base ?? settings.rollBase)
      ci = Self.straightened(ci, degrees: settings.angle ?? 0)
      ci = ci.oriented(forExifOrientation: [1, 6, 3, 8][((settings.rotation % 4) + 4) % 4])
      if settings.flipHorizontal == true {
        ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
      }
    } else {
      guard
        let output = try? output(
          image, settings: settings, profile: profile, analysis: analysis, sharpener: sharpener)
      else { return nil }
      ci = output
    }
    return ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
  }
  func export(
    _ image: CGImage, settings: Adjustments, profile: FilmProfile, url: URL, format: ExportFormat,
    dpi: Int, quality: Double = 0.97, sharpener: Sharpener? = nil, colorSpace: ExportColorSpace = .sRGB,
    metadata: ExportMetadata? = nil
  ) throws {
    let wide = colorSpace != .sRGB
    let ci = try output(image, settings: settings, profile: profile, sharpener: sharpener, extendedRange: wide)
    let cg: CGImage?
    if wide {
      // Rendered unclipped as extended sRGB, then converted by ColorSync into the wider space.
      cg = context.createCGImage(ci, from: ci.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
        .flatMap { converted($0, to: colorSpace.space, bitsPerComponent: format.sixteenBit ? 16 : 8) }
    } else {
      cg = opaqueImage(ci, sixteenBit: format.sixteenBit, colorSpace: outputSpace)
    }
    guard let cg else { throw DeskError.message("无法创建导出文件。") }
    try write(cg, to: url, format: format, dpi: dpi, quality: quality, metadata: metadata)
  }
  /// `image` in `space`, with colours outside it clipped there rather than before; without alpha.
  func converted(_ image: CGImage, to space: CGColorSpace, bitsPerComponent: Int) -> CGImage? {
    guard
      let ctx = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage()
  }
  /// `image` turned `turns` quarter turns clockwise and then mirrored left to right, as a frame's
  /// rotation and mirror show it; its pixels copied as they are.
  func turned(_ image: CGImage, quarterTurns turns: Int, mirrored: Bool = false) -> CGImage? {
    let t = ((turns % 4) + 4) % 4
    guard t != 0 || mirrored else { return image }
    let w = image.width, h = image.height
    let size = t == 2 || t == 0 ? (w, h) : (h, w)
    let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? outputSpace
    guard
      let ctx = CGContext(
        data: nil, width: size.0, height: size.1, bitsPerComponent: image.bitsPerComponent > 8 ? 16 : 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // The transform concatenated last applies first: the turn, then the mirror.
    if mirrored { ctx.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(size.0), ty: 0)) }
    // In the context's upward y: a clockwise turn on screen takes (u, v) to (v, w - u).
    switch t {
    case 0: break
    case 1: ctx.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(w)))
    case 2: ctx.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(w), ty: CGFloat(h)))
    default: ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0))
    }
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
  }
  /// `ci` rendered straight into a bitmap whose fourth channel is padding, so the file has no
  /// alpha and the picture is not drawn again to drop it (`opaque`): for a 61-megapixel frame that
  /// was a second 490 MB copy and about half a second. The values are the same.
  func opaqueImage(_ ci: CIImage, sixteenBit: Bool, colorSpace: CGColorSpace) -> CGImage? {
    let extent = ci.extent.integral
    let w = Int(extent.width), h = Int(extent.height)
    guard w > 0, h > 0, let data = NSMutableData(length: w * h * (sixteenBit ? 8 : 4)) else { return nil }
    let rowBytes = w * (sixteenBit ? 8 : 4)
    context.render(ci, toBitmap: data.mutableBytes, rowBytes: rowBytes, bounds: extent, format: sixteenBit ? .RGBA16 : .RGBA8, colorSpace: colorSpace)
    guard let provider = CGDataProvider(data: data) else { return nil }
    let info = CGImageAlphaInfo.noneSkipLast.rawValue | (sixteenBit ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
    return CGImage(
      width: w, height: h, bitsPerComponent: sixteenBit ? 16 : 8, bitsPerPixel: sixteenBit ? 64 : 32, bytesPerRow: rowBytes,
      space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)
  }
  /// `image` without its alpha channel, the values unchanged. Rendered images are opaque, so the
  /// channel only made TIFF and PNG files a third larger, and some apps took them as transparent.
  func opaque(_ image: CGImage) -> CGImage {
    switch image.alphaInfo {
    case .none, .noneSkipLast, .noneSkipFirst: return image
    default: break
    }
    guard let space = image.colorSpace, space.model == .rgb,
      let opaque = converted(image, to: space, bitsPerComponent: image.bitsPerComponent > 8 ? 16 : 8)
    else { return image }
    return opaque
  }
  func write(
    _ image: CGImage, to url: URL, format: ExportFormat, dpi: Int, quality: Double = 0.97,
    metadata: ExportMetadata? = nil
  ) throws {
    guard
      let dest = CGImageDestinationCreateWithURL(
        url as CFURL, format.type.identifier as CFString, 1, nil)
    else { throw DeskError.message("无法创建导出文件。") }
    var properties: [CFString: Any] = [
      kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
      kCGImageDestinationLossyCompressionQuality: quality,
    ]
    if let metadata { properties.merge(metadata.properties) { _, new in new } }
    // LZW roughly halves an 8-bit TIFF; a 16-bit scan only grows with it (a 2400 dpi 35 mm frame
    // 53.5 MB against 44.7 MB), so like the originals it is left uncompressed.
    var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    tiff[kCGImagePropertyTIFFCompression] = format == .tiff ? 1 : 5
    properties[kCGImagePropertyTIFFDictionary] = tiff
    // Written as RGB: ImageIO stores an image with a skipped alpha as three samples per pixel.
    CGImageDestinationAddImage(dest, opaque(image), properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw DeskError.message("图像写入失败。") }
  }
  /// The overview as a contact print: every frame positive with its own settings, kept in scan
  /// orientation so it stays under its frame box, on the overview inverted with the first frame's
  /// base and settings. Unexposed film base prints black and the holder prints as white paper.
  func contactPrint(_ overview: CGImage, frames: [FilmFrame], profile: FilmProfile) -> CGImage? {
    // The light table shows the film as it lies: upright, and not straightened.
    func upright(_ s: Adjustments) -> Adjustments {
      var s = s
      s.rotation = 0
      s.flipHorizontal = nil
      s.angle = nil
      return s
    }
    guard let first = frames.first, let firstCrop = try? crop(overview, rect: first.rect) else {
      return nil
    }
    let s0 = upright(first.adjustments)
    let analysis = analyze(firstCrop, settings: s0, profile: profile)
    let w = overview.width, h = overview.height
    guard let paper = try? output(overview, settings: s0, profile: profile, analysis: analysis),
      let background = context.createCGImage(paper, from: paper.extent, format: .RGBA8, colorSpace: outputSpace),
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: outputSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h))
    for f in frames {
      guard let frameCrop = try? crop(overview, rect: f.rect),
        let positive = try? preview(frameCrop, settings: upright(f.adjustments), profile: profile)
      else { continue }
      let r = f.rect.pixels(CGSize(width: w, height: h))
      ctx.draw(positive, in: CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height))
    }
    return ctx.makeImage()
  }
  func savePNG(_ image: CGImage, to url: URL) throws {
    guard
      let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw DeskError.message("不能保存预览。") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw DeskError.message("不能保存预览。") }
  }
  /// Uncompressed, like the scans in Originals.
  func saveTIFF(_ image: CGImage, to url: URL, dpi: Int) throws {
    guard
      let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
    else { throw DeskError.message("不能保存预览。") }
    let properties: [CFString: Any] = [
      kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1],
    ]
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw DeskError.message("不能保存预览。") }
  }
  /// The whole file decoded into memory now, not again on every draw or crop.
  func loadDecoded(_ url: URL) throws -> CGImage {
    let image = try load(url)
    guard let data = image.dataProvider?.data, let provider = CGDataProvider(data: data),
      let space = image.colorSpace,
      let decoded = CGImage(
        width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent,
        bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow, space: space,
        bitmapInfo: image.bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)
    else { throw DeskError.message("无法读取图像：\(url.lastPathComponent)") }
    return decoded
  }
  /// `image` no larger than `maxDimension`, Lanczos-filtered, in its own depth and colour space.
  func scaled(_ image: CGImage, maxDimension: Int) -> CGImage {
    let scale = Double(maxDimension) / Double(max(image.width, image.height))
    guard scale < 1, let filter = CIFilter(name: "CILanczosScaleTransform") else { return image }
    filter.setValue(CIImage(cgImage: image, options: [.colorSpace: NSNull()]), forKey: kCIInputImageKey)
    filter.setValue(scale, forKey: kCIInputScaleKey)
    filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
    let size = CGRect(
      x: 0, y: 0, width: max(1, (Double(image.width) * scale).rounded()),
      height: max(1, (Double(image.height) * scale).rounded()))
    guard let output = filter.outputImage,
      let result = context.createCGImage(
        output, from: size, format: image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8,
        colorSpace: image.colorSpace ?? outputSpace)
    else { return image }
    return result
  }
}

/// What an export says about itself, for Lightroom, Photos and Finder: the film, the frame, the
/// scanner and when it was scanned. The picture's own capture date is not known, so it is not set.
struct ExportMetadata {
  var title: String
  var description: String
  var keywords: [String]
  /// Nil for imported files: the app does not know what scanned them.
  var scanner: (make: String, model: String)?
  var scanned: Date?
  var software: String
  var properties: [CFString: Any] {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    let date = scanned.map { f.string(from: $0) }
    var tiff: [CFString: Any] = [
      kCGImagePropertyTIFFSoftware: software, kCGImagePropertyTIFFImageDescription: description,
    ]
    if let scanner { (tiff[kCGImagePropertyTIFFMake], tiff[kCGImagePropertyTIFFModel]) = (scanner.make, scanner.model) }
    if let date { tiff[kCGImagePropertyTIFFDateTime] = date }
    var exif: [CFString: Any] = [kCGImagePropertyExifUserComment: description]
    if let date { exif[kCGImagePropertyExifDateTimeDigitized] = date }
    let iptc: [CFString: Any] = [
      kCGImagePropertyIPTCObjectName: title, kCGImagePropertyIPTCCaptionAbstract: description,
      kCGImagePropertyIPTCKeywords: keywords, kCGImagePropertyIPTCOriginatingProgram: "Epson Scan plus",
      kCGImagePropertyIPTCProgramVersion: software.replacingOccurrences(of: "Epson Scan plus ", with: ""),
      kCGImagePropertyIPTCSource: scanner.map { "\($0.make) \($0.model)" } ?? "Epson Scan plus",
    ]
    let png: [CFString: Any] = [
      kCGImagePropertyPNGTitle: title, kCGImagePropertyPNGDescription: description,
      kCGImagePropertyPNGSoftware: software,
    ]
    return [
      kCGImagePropertyTIFFDictionary: tiff, kCGImagePropertyExifDictionary: exif,
      kCGImagePropertyIPTCDictionary: iptc, kCGImagePropertyPNGDictionary: png,
    ]
  }
}

/// The overview file at full resolution and scaled copies, decoded once and shared by the render
/// queues: a 600 dpi preview takes about half a second to decode, too slow for every refresh.
final class OverviewCache {
  private let lock = NSLock()
  private var url: URL?
  private var full: CGImage?
  private var scaled = [Int: CGImage]()
  /// A preview just scanned, already in memory.
  func keep(_ image: CGImage, for url: URL) {
    lock.lock()
    defer { lock.unlock() }
    (self.url, full, scaled) = (url, image, [:])
  }
  func image(_ url: URL, maxDimension: Int? = nil) throws -> CGImage {
    lock.lock()
    defer { lock.unlock() }
    if url != self.url { (self.url, full, scaled) = (url, nil, [:]) }
    let image = try full ?? ImagePipeline.shared.loadDecoded(url)
    full = image
    guard let maxDimension, maxDimension < max(image.width, image.height) else { return image }
    if let copy = scaled[maxDimension] { return copy }
    let copy = ImagePipeline.shared.scaled(image, maxDimension: maxDimension)
    scaled[maxDimension] = copy
    return copy
  }
}
