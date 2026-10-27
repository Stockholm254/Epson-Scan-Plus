import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// A scanner's measured MTF, horizontal and vertical, in cycles per millimetre, so one
/// measurement serves every scan resolution. Made by `TargetMeasurement` from a target scan.
struct SharpeningProfile: Codable, Equatable {
  struct Point: Codable, Equatable {
    var cyclesPerMM: Double
    var mtf: Double
  }
  var source: String
  var measured: Date
  var targetDPI: Double
  /// The target's encoding: 1 for linear scans, otherwise linearized with this gamma.
  var targetGamma: Double
  var horizontal: [Point]
  var vertical: [Point]
  var horizontalEdges: Int
  var verticalEdges: Int

  /// Beyond the measured range the scanner passes essentially nothing but noise.
  static let floor = 0.01
  static func value(_ curve: [Point], at f: Double) -> Double {
    guard let last = curve.last, f <= last.cyclesPerMM else { return floor }
    guard let i = curve.firstIndex(where: { $0.cyclesPerMM >= f }), i > 0 else { return curve.first?.mtf ?? 1 }
    let a = curve[i - 1], b = curve[i]
    let t = (f - a.cyclesPerMM) / max(1e-9, b.cyclesPerMM - a.cyclesPerMM)
    return max(floor, a.mtf + (b.mtf - a.mtf) * t)
  }
  /// Cycles per millimetre where the curve falls to `level`.
  static func crossing(_ curve: [Point], _ level: Double) -> Double {
    for (a, b) in zip(curve, curve.dropFirst()) where a.mtf >= level && b.mtf < level {
      return a.cyclesPerMM + (b.cyclesPerMM - a.cyclesPerMM) * (a.mtf - level) / max(1e-9, a.mtf - b.mtf)
    }
    return curve.last?.cyclesPerMM ?? 0
  }
  /// Effective resolution: twice the frequency still at 10% contrast.
  var effectivePPI: (horizontal: Double, vertical: Double) {
    (2 * 25.4 * Self.crossing(horizontal, 0.1), 2 * 25.4 * Self.crossing(vertical, 0.1))
  }

  /// A Wiener deconvolution kernel for an image at `dpi`. `strength` 0...1 sets the noise
  /// allowance K from 0.12 (gentle) to 0.015 (strong); the default 0.4 is K ≈ 0.05.
  /// Returns nil when the filter would be practically identity, such as at low resolutions.
  func sharpener(dpi: Double, strength: Double, gamma: Double) -> Sharpener? {
    guard strength > 0.001, dpi > 0 else { return nil }
    let k = 0.12 * pow(0.015 / 0.12, min(1, strength))
    let n = 64, half = n / 2, maxRadius = 20
    let perMM = dpi / 25.4
    // The filter is even in both axes, so the inverse transform is a cosine sum over u, v ≥ 0.
    var w = [Double](repeating: 0, count: (half + 1) * (half + 1))
    for v in 0...half {
      let mv = Self.value(vertical, at: Double(v) / Double(n) * perMM)
      for u in 0...half {
        let h = Self.value(horizontal, at: Double(u) / Double(n) * perMM) * mv
        w[v * (half + 1) + u] = min(5, h * (1 + k) / (h * h + k))
      }
    }
    // Above the optical limit the filter suppresses noise, so judge it by whether it boosts anything.
    guard (w.max() ?? 1) > 1.02 else { return nil }
    let weight = { (i: Int) -> Double in i == 0 || i == half ? 1 : 2 }
    let span = 2 * maxRadius + 1
    var partial = [Double](repeating: 0, count: span * (half + 1))  // [x][v]
    for x in -maxRadius...maxRadius {
      for v in 0...half {
        var s = 0.0
        for u in 0...half { s += weight(u) * w[v * (half + 1) + u] * cos(2 * .pi * Double(u * x) / Double(n)) }
        partial[(x + maxRadius) * (half + 1) + v] = s
      }
    }
    var full = [Double](repeating: 0, count: span * span)  // [y][x]
    for y in -maxRadius...maxRadius {
      for x in -maxRadius...maxRadius {
        var s = 0.0
        for v in 0...half { s += weight(v) * partial[(x + maxRadius) * (half + 1) + v] * cos(2 * .pi * Double(v * y) / Double(n)) }
        full[(y + maxRadius) * span + x + maxRadius] = s / Double(n * n)
      }
    }
    let reference = max(0.3, abs(full[maxRadius * span + maxRadius]))
    // The smallest radius outside which every tap is negligible.
    var radius = 1
    for r in stride(from: maxRadius, through: 1, by: -1) {
      let ring = (-r...r).flatMap { a in [(a, -r), (a, r), (-r, a), (r, a)] }
      if ring.contains(where: { abs(full[($0.1 + maxRadius) * span + $0.0 + maxRadius]) > 0.003 * reference }) {
        radius = r
        break
      }
    }
    // Taper only the outer half (a Tukey window), so the main lobes keep their full weight,
    // then restore unit gain so brightness is unchanged.
    let size = 2 * radius + 1
    func tukey(_ d: Int) -> Double {
      let t = Double(abs(d)) / Double(radius + 1)
      return t <= 0.5 ? 1 : 0.5 * (1 + cos(.pi * (t - 0.5) / 0.5))
    }
    var kernel = [Float](repeating: 0, count: size * size)
    for y in -radius...radius {
      for x in -radius...radius {
        let taper = tukey(x) * tukey(y)
        kernel[(y + radius) * size + x + radius] = Float(full[(y + maxRadius) * span + x + maxRadius] * taper)
      }
    }
    let sum = kernel.reduce(0, +)
    guard sum > 0 else { return nil }
    return Sharpener(kernel: kernel.map { $0 / sum }, radius: radius, gamma: gamma)
  }
}

/// A kernel ready to apply to one image, in that image's linear light.
struct Sharpener {
  var kernel: [Float]
  var radius: Int
  var gamma: Double
}

enum Sharpening {
  static let defaultStrength = 0.4
  /// Own scans are sharpened gently by default; imported images may come from another
  /// scanner or a camera, so they start unsharpened.
  static func strength(for frame: FilmFrame) -> Double {
    frame.adjustments.sharpening ?? (frame.sourcePath == nil ? defaultStrength : 0)
  }
  /// The kernel for `frame`'s full-resolution source, loaded with `maxDimension` (nil for the
  /// file's own size). Previews and frames without a profile are left alone.
  static func sharpener(_ profile: SharpeningProfile?, frame: FilmFrame, maxDimension: Int?) -> Sharpener? {
    guard let profile, frame.hasFullResolution, let path = frame.scanPath ?? frame.sourcePath else { return nil }
    let strength = strength(for: frame)
    guard strength > 0 else { return nil }
    let info = ImagePipeline.shared.info(URL(fileURLWithPath: path))
    let fileDPI = Double(frame.scanDPI ?? 0) > 0 ? Double(frame.scanDPI!) : info.dpi
    guard fileDPI > 0, info.width > 0 else { return nil }
    let longest = Double(max(info.width, info.height))
    let scale = maxDimension.map { min(1, Double($0) / longest) } ?? 1
    return profile.sharpener(dpi: fileDPI * scale, strength: strength, gamma: frame.adjustments.inputGamma)
  }
}

extension ImagePipeline {
  /// Deconvolves in linear light, before any tonal processing. Works through the image in
  /// bands of rows, so float memory stays a few hundred rows even for a 6400 dpi frame.
  func sharpen(_ image: CGImage, with s: Sharpener) throws -> CGImage {
    guard
      let format = vImage_CGImageFormat(
        bitsPerComponent: 16, bitsPerPixel: 64, colorSpace: image.colorSpace ?? outputSpace,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
    else { throw DeskError.message("锐化：不支持的图像格式。") }
    let source = try vImage_Buffer(cgImage: image, format: format)
    defer { source.free() }
    let output = try vImage_Buffer(width: Int(source.width), height: Int(source.height), bitsPerPixel: 64)
    defer { output.free() }
    let width = Int(source.width), height = Int(source.height), r = s.radius, band = 256
    let size = UInt32(2 * r + 1)
    var gamma = Float(s.gamma), inverse = Float(1 / s.gamma), low: Float = 1e-6, high: Float = 1
    var count = Int32(width * 4)
    func eachRow(_ buffer: vImage_Buffer, _ body: (UnsafeMutablePointer<Float>) -> Void) {
      for row in 0..<Int(buffer.height) {
        body(buffer.data.advanced(by: row * buffer.rowBytes).assumingMemoryBound(to: Float.self))
      }
    }
    var y0 = 0
    while y0 < height {
      let y1 = min(height, y0 + band), top = max(0, y0 - r), bottom = min(height, y1 + r)
      var linear = try vImage_Buffer(width: width, height: bottom - top, bitsPerPixel: 128)
      var result = try vImage_Buffer(width: width, height: y1 - y0, bitsPerPixel: 128)
      defer {
        linear.free()
        result.free()
      }
      var sourceRows = vImage_Buffer(
        data: source.data.advanced(by: top * source.rowBytes), height: vImagePixelCount(bottom - top),
        width: vImagePixelCount(width * 4), rowBytes: source.rowBytes)
      var linearPlanar = vImage_Buffer(
        data: linear.data, height: linear.height, width: vImagePixelCount(width * 4), rowBytes: linear.rowBytes)
      vImageConvert_16UToF(&sourceRows, &linearPlanar, 0, 1 / 65535, vImage_Flags(kvImageNoFlags))
      if gamma != 1 { eachRow(linear) { vvpowsf($0, &gamma, $0, &count) } }
      let error = s.kernel.withUnsafeBufferPointer { k in
        vImageConvolve_ARGBFFFF(
          &linear, &result, nil, 0, vImagePixelCount(y0 - top), k.baseAddress!, size, size, nil,
          vImage_Flags(kvImageEdgeExtend))
      }
      guard error == kvImageNoError else { throw DeskError.message("锐化失败（vImage \(error)）。") }
      eachRow(result) { row in
        vDSP_vclip(row, 1, &low, &high, row, 1, vDSP_Length(count))
        if gamma != 1 { vvpowsf(row, &inverse, row, &count) }
      }
      var resultPlanar = vImage_Buffer(
        data: result.data, height: result.height, width: vImagePixelCount(width * 4), rowBytes: result.rowBytes)
      var outputRows = vImage_Buffer(
        data: output.data.advanced(by: y0 * output.rowBytes), height: vImagePixelCount(y1 - y0),
        width: vImagePixelCount(width * 4), rowBytes: output.rowBytes)
      vImageConvert_FTo16U(&resultPlanar, &outputRows, 0, 1 / 65535, vImage_Flags(kvImageNoFlags))
      y0 = y1
    }
    return try output.createCGImage(format: format)
  }
}
