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
  /// In the kernel's output values (encoded, 0-1).
  static var softToe = 0.05, softShoulder = 0.9, shadowColour = 0.3
  /// A balance that makes the greys grey (a calibrated preset's neutral, a picked grey, Dmax) is
  /// worked out on the straight part of the film's curve. Film that took no light is black in every
  /// layer, and black is neutral; there the balance would only lift red and blue into a purple
  /// black. So, where no fitted toe bends the curve down to the base, the balance fades in over
  /// about a toe's width of log exposure above it (the Kodak sheets' toes are 0.10–0.165): 95% of
  /// it by 0.36, 1.2 stops up.
  static var unexposedFade = 0.12
  // Exposure (tone.x, in EV) is a print exposure: a shift of log exposure, 0.30103 per stop,
  // applied before the levels and clipping so −EV recovers highlights. Positive input scales the
  // linear value instead, through its encoding gamma.
  let kernel: CIColorKernel? = CIColorKernel(source: ImagePipeline.negativeSource)
  /// The same without the final clip: colours the saturation control pushes past sRGB stay, for
  /// exports into a wider colour space.
  let extendedKernel: CIColorKernel? = CIColorKernel(
    source: ImagePipeline.negativeSource.replacingOccurrences(
      of: "return vec4(clamp(q,0.0,1.0),1.0);", with: "return vec4(q,1.0);"))
  private static let negativeSource = """
      kernel vec4 negative(__sample p, vec3 base, vec3 slope, vec3 toe, vec3 gain, vec3 balance, vec4 levels, vec4 tone, vec4 color, vec4 ends, float inverted, vec2 fade, vec2 lights) {
        vec3 v = max(p.rgb, vec3(0.000001));
        vec3 e = log(max(base,vec3(0.000001))/v) * (color.w / 2.302585093) / slope;
        e += toe * log(max(vec3(1.0) - exp(-e / max(toe, vec3(0.000001))), vec3(0.02)));
        vec3 b = balance;
        if (fade.x > 0.0) { b *= min((1.0 - exp(-max((e.r + e.g + e.b) / 3.0, 0.0) / fade.x)) / fade.y, 1.0); }
        vec3 q = (e * gain + b + vec3(tone.x * 0.30103) - vec3(levels.x)) / max(levels.y-levels.x,0.001);
        if (inverted < 0.5) { q = v * pow(2.0, tone.x / max(color.w, 0.1)); }
        q = (q - vec3(levels.z)) / max(levels.w-levels.z,0.01);
        q += vec3(color.x * 0.12 + color.y * 0.05, -color.y * 0.10, -color.x * 0.12 + color.y * 0.05);
        q = (q-vec3(0.5))*tone.z+vec3(0.5);
        // Each side's curve only works out its own side, so a far value (the holder, opaque) does not
        // overflow the other's exp into infinity and come out as nothing.
        if (ends.x > 0.0) { vec3 t = vec3(ends.x); q = mix(t * exp(min(q, t) / t - vec3(1.0)), q, step(t, q)); }
        if (ends.y < 1.0) { float r = 1.0 - ends.y; vec3 o = max(q, vec3(ends.y)) - vec3(ends.y); q = mix(q, vec3(ends.y) + r * (vec3(1.0) - exp(-o / r)), step(vec3(ends.y), q)); }
        q = clamp(q,0.0,1.0);
        // Shadows and highlights: the dark tones (most at a third) and the light ones (most at two
        // thirds) moved by up to 0.12, black and white held, every tone still in order.
        vec3 r = vec3(1.0) - q;
        q += lights.x * 0.81 * q * r * r + lights.y * 0.81 * q * q * r;
        q = pow(q,vec3(1.0/max(tone.y,0.1)));
        float l = dot(q,vec3(0.2126,0.7152,0.0722));
        q = mix(vec3(l),q,tone.w * (1.0 + ends.z * (1.0 - l) * (1.0 - l)));
        return vec4(clamp(q,0.0,1.0),1.0);
      }
      """
  /// Each pixel's colour apart from its lightness (luma), and the two put back together.
  private static let colourOfLuma = CIColorKernel(source: "kernel vec4 colourOf(__sample p) { float l = dot(p.rgb, vec3(0.2126, 0.7152, 0.0722)); return vec4(p.rgb - vec3(l), p.a); }")
  private static let lumaWithColour = CIColorKernel(source: "kernel vec4 withColour(__sample p, __sample c) { float l = dot(p.rgb, vec3(0.2126, 0.7152, 0.0722)); return vec4(vec3(l) + c.rgb, p.a); }")
  /// `image` with its colour smoothed over `radius` pixels and its lightness kept exactly: colour
  /// noise (the sensor's, and what taking the crosstalk out adds to it) goes, the grain stays. The
  /// colour has no lightness of its own, so its blur leaves the luma as it was. Scaled with the
  /// picture, as a smaller one has its noise averaged away already.
  func colourSmoothed(_ image: CIImage, radius: Double) -> CIImage {
    guard radius >= 0.3, let split = Self.colourOfLuma, let join = Self.lumaWithColour,
      let colour = split.apply(extent: image.extent, arguments: [image])
    else { return image }
    let smooth = colour.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
    return join.apply(extent: image.extent, arguments: [image, smooth]) ?? image
  }
  /// Tone curves as a lookup: each channel reads its own row entry from a `n` × 1 table.
  let curveKernel: CIKernel? = CIKernel(
    source: """
      kernel vec4 curves(sampler image, sampler table, float n) {
        vec4 p = sample(image, samplerCoord(image));
        vec3 at = clamp(p.rgb, 0.0, 1.0) * (n - 1.0) + 0.5;
        return vec4(sample(table, samplerTransform(table, vec2(at.r, 0.5))).r,
                    sample(table, samplerTransform(table, vec2(at.g, 0.5))).g,
                    sample(table, samplerTransform(table, vec2(at.b, 0.5))).b, p.a);
      }
      """)
  func applyCurves(_ curves: ToneCurves, to image: CIImage) -> CIImage {
    guard !curves.isIdentity, let curveKernel else { return image }
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
    let v = a.sorted()
    return v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count - 1) * p))]
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
    let (slopes, fixed) = Self.slopes(settings, profile)
    let toe = Self.toe(settings, profile)
    func exposure(_ density: Double, _ c: Int) -> Double { FilmToe.exposure(density / slopes.values[c], width: toe.values[c]) }
    let e = (0..<3).map { c in density[c].map { exposure($0, c) } }
    // Independent robust endpoints correct color crossover, not just a single median offset.
    // They are scene statistics, not an ICC calibration; manual neutral/temperature remain available.
    let channelLow = e.map { quantile($0, 0.01) }
    let channelHigh = e.map { quantile($0, 0.99) }
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
        lows.append(quantile(x, 0.005))
        highs.append(quantile(x, 0.995))
      } else {
        lows.append(quantile(e[c], 0.005) * gain.values[c] + balance.values[c])
        highs.append(quantile(e[c], 0.995) * gain.values[c] + balance.values[c])
      }
    }
    let low = settings.autoLevels ? (lows.min() ?? 0) : 0
    let high = settings.autoLevels ? max(low + 0.05, white ?? highs.max() ?? 2) : 3.6
    return ToneAnalysis(base: base, balance: balance, low: low, high: high, gain: gain, fade: fade, fadeAtGrey: fadeAtGrey)
  }

  /// `sharpener` deconvolves the scan in linear light first; tone statistics use the scan as is.
  func output(
    _ image: CGImage, settings s: Adjustments, profile: FilmProfile, analysis: ToneAnalysis? = nil,
    sharpener: Sharpener? = nil, extendedRange: Bool = false
  ) throws -> CIImage {
    let a = analysis ?? analyze(image, settings: s, profile: profile)
    guard let kernel = extendedRange ? extendedKernel : kernel else { throw DeskError.message("图像处理内核初始化失败。") }
    let source = try sharpener.map { try sharpen(image, with: $0) } ?? image
    let ci = CIImage(cgImage: source, options: [.colorSpace: NSNull()])
    func v(_ c: RGB) -> CIVector { CIVector(x: c.r, y: c.g, z: c.b) }
    let fine = s.baseFine ?? .zero
    let effectiveBase = RGB(
      (0..<3).map { max(0.0001, a.base.values[$0]) * pow(2, fine.values[$0]) })
    let args: [Any] = [
      ci, v(effectiveBase), v(Self.slopes(s, profile).slopes), v(Self.toe(s, profile)), v(a.gain), v(a.balance),
      CIVector(x: a.low, y: a.high, z: s.black, w: s.white),
      CIVector(x: s.exposure, y: s.midtone, z: s.contrast, w: s.saturation),
      CIVector(x: s.warmth, y: s.tint, z: 0, w: s.inputGamma),
      s.softEndsOn && s.inputIsNegative
        ? CIVector(x: Self.softToe, y: Self.softShoulder, z: Self.shadowColour, w: 0) : CIVector(x: 0, y: 2, z: 0, w: 0),
      s.inputIsNegative ? 1.0 : 0.0,
      CIVector(x: a.fade, y: a.fadeAtGrey),
      CIVector(x: s.shadowsAmount, y: s.highlightsAmount),
    ]
    guard var result = kernel.apply(extent: ci.extent, arguments: args) else {
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
      cg = context.createCGImage(ci, from: ci.extent, format: format.sixteenBit ? .RGBA16 : .RGBA8, colorSpace: outputSpace)
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
