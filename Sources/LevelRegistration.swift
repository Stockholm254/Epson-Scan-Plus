import CoreGraphics
import CoreImage
import Foundation

/// A scan's levels against the preview of the same holder: per channel, scan = gain × preview +
/// offset. The V850 sets each scan's levels itself, differently for a preview and a scan (blue
/// about 11% higher at 2400 dpi than in a 600 dpi preview) and differently for every window wider
/// than a frame (blue −0.4 to +3.8%, the black level ±0.3%); measured against the preview, each
/// scan can be put back on one scale, the one the film base is measured on. The fit runs in
/// preview pixels over the frame's middle, after finding the scan's sub-pixel place on the
/// preview, and only where the preview is smooth, so a pixel's worth of misplacement does not count.
struct LevelRegistration: Codable, Equatable {
  var gain: RGB
  /// In the scan's units (0–1).
  var offset: RGB
  /// How closely green follows the preview (R²); low when the film moved since the preview or the
  /// picture is too flat to tell gain from offset.
  var fit: Double
  /// A scan in place on its preview fits to 0.9996 or better; a flat picture or moved film less.
  static let minimumFit = 0.995
  /// Tried and not measurable: kept so it is not tried on every opening.
  static let unmeasured = LevelRegistration(gain: RGB(r: 1, g: 1, b: 1), offset: RGB(r: 0, g: 0, b: 0), fit: 0)
  var usable: Bool { fit >= Self.minimumFit && gain.values.allSatisfy { $0 > 0.6 && $0 < 1.6 } }
  /// The scan's values on the preview's scale: (value − offset) / gain.
  var scale: RGB { RGB(gain.values.map { 1 / $0 }) }
  var bias: RGB { RGB((0..<3).map { -offset.values[$0] / gain.values[$0] }) }

  /// Fits `scan`, which covers `footprint` of the overview, to `preview` over the middle of
  /// `region` (both in the overview's normalised coordinates).
  static func measure(scan: CGImage, footprint: NormalRect, preview: CGImage, region: NormalRect) -> LevelRegistration? {
    let inner = NormalRect(
      x: region.x + region.width * 0.1, y: region.y + region.height * 0.1, width: region.width * 0.8, height: region.height * 0.8)
    let pw = Double(preview.width), ph = Double(preview.height), sw = Double(scan.width), sh = Double(scan.height)
    // The preview around the region, with a margin for the shift search.
    let margin = 4
    let px0 = max(0, Int(floor(inner.x * pw)) - margin), py0 = max(0, Int(floor(inner.y * ph)) - margin)
    let px1 = min(preview.width, Int(ceil((inner.x + inner.width) * pw)) + margin)
    let py1 = min(preview.height, Int(ceil((inner.y + inner.height) * ph)) + margin)
    guard px1 - px0 > 4 * margin, py1 - py0 > 4 * margin,
      let previewCrop = preview.cropping(to: CGRect(x: px0, y: py0, width: px1 - px0, height: py1 - py0)),
      let P = Pixels(previewCrop)
    else { return nil }
    // Scan pixels per preview pixel, and the scan's part under the region.
    func scanX(_ previewX: Double) -> Double { (previewX / pw - footprint.x) / footprint.width * sw }
    func scanY(_ previewY: Double) -> Double { (previewY / ph - footprint.y) / footprint.height * sh }
    let sx0 = max(0, Int(floor(scanX(Double(px0))))), sy0 = max(0, Int(floor(scanY(Double(py0)))))
    let sx1 = min(scan.width, Int(ceil(scanX(Double(px1))))), sy1 = min(scan.height, Int(ceil(scanY(Double(py1)))))
    guard sx1 - sx0 > 8, sy1 - sy0 > 8,
      let scanCrop = scan.cropping(to: CGRect(x: sx0, y: sy0, width: sx1 - sx0, height: sy1 - sy0)),
      let S = Pixels(scanCrop)
    else { return nil }
    // One block of the scan per preview pixel, averaged.
    var blocks = [(u: Double, v: Double, rgb: SIMD3<Double>)]()
    for j in (py0 + margin)..<(py1 - margin) {
      let y0 = Int(scanY(Double(j)).rounded()) - sy0, y1 = Int(scanY(Double(j + 1)).rounded()) - sy0
      guard y0 >= 0, y1 <= S.height, y1 > y0 else { continue }
      for i in (px0 + margin)..<(px1 - margin) {
        let x0 = Int(scanX(Double(i)).rounded()) - sx0, x1 = Int(scanX(Double(i + 1)).rounded()) - sx0
        guard x0 >= 0, x1 <= S.width, x1 > x0 else { continue }
        var sum = SIMD3<Double>(repeating: 0)
        for y in y0..<y1 { for x in x0..<x1 { sum += S.rgb(x, y) } }
        blocks.append((Double(i - px0), Double(j - py0), sum / Double((x1 - x0) * (y1 - y0))))
      }
    }
    guard blocks.count >= 200 else { return nil }
    func fit(_ c: Int, _ dx: Double, _ dy: Double, _ keep: [Int]) -> (gain: Double, offset: Double, r2: Double) {
      var n = 0.0, su = 0.0, sv = 0.0, suu = 0.0, suv = 0.0, svv = 0.0
      for k in keep {
        let b = blocks[k], u = P.bilinear(b.u + dx, b.v + dy)[c], v = b.rgb[c]
        n += 1; su += u; sv += v; suu += u * u; suv += u * v; svv += v * v
      }
      let cov = n * suv - su * sv, varU = n * suu - su * su, varV = n * svv - sv * sv
      guard varU > 0, varV > 0 else { return (1, 0, 0) }
      let g = cov / varU
      return (g, (sv - g * su) / n, cov * cov / (varU * varV))
    }
    // The scan's place on the preview, within two and a half preview pixels: coarsely, then to an
    // eighth, then to a twentieth around the best. A quarter of a pixel off tilts the gain by most of
    // a percent where the picture changes fast. All three channels judge it: one alone cannot see
    // a shift along its own contours.
    let coarse = Array(stride(from: 0, to: blocks.count, by: 20)), sample = Array(stride(from: 0, to: blocks.count, by: 10))
    var best = (dx: 0.0, dy: 0.0, r2: -1.0)
    for (span, step, keep) in [(2.5, 0.5, coarse), (0.5, 0.125, sample), (0.1, 0.05, sample)] {
      let around = (dx: best.dx, dy: best.dy)
      best.r2 = -1
      for dy in stride(from: around.dy - span, through: around.dy + span + 1e-9, by: step) {
        for dx in stride(from: around.dx - span, through: around.dx + span + 1e-9, by: step) {
          let r2 = (0..<3).map { fit($0, dx, dy, keep).r2 }.reduce(0, +)
          if r2 > best.r2 { best = (dx, dy, r2) }
        }
      }
    }
    // Best at the edge of the search: the film has moved since the preview.
    guard abs(best.dx) < 2.25, abs(best.dy) < 2.25 else { return .unmeasured }
    let keep = blocks.indices.filter { k in
      let b = blocks[k], c = P.bilinear(b.u + best.dx, b.v + best.dy)[1]
      let d = [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)].map { abs(P.bilinear(b.u + best.dx + $0.0, b.v + best.dy + $0.1)[1] - c) }.max()!
      return d < 0.03 * c + 20 / 65535
    }
    guard keep.count >= 200 else { return nil }
    let fits = (0..<3).map { fit($0, best.dx, best.dy, keep) }
    return LevelRegistration(gain: RGB(fits.map(\.gain)), offset: RGB(fits.map(\.offset)), fit: fits[1].r2)
  }
}

extension ImagePipeline {
  /// `image` with each channel scaled and offset (value × scale + bias), in its own linear units.
  func leveled(_ image: CGImage, scale: RGB, bias: RGB) -> CGImage {
    let filter = CIFilter(name: "CIColorMatrix")!
    filter.setValue(CIImage(cgImage: image, options: [.colorSpace: NSNull()]), forKey: kCIInputImageKey)
    filter.setValue(CIVector(x: scale.r, y: 0, z: 0, w: 0), forKey: "inputRVector")
    filter.setValue(CIVector(x: 0, y: scale.g, z: 0, w: 0), forKey: "inputGVector")
    filter.setValue(CIVector(x: 0, y: 0, z: scale.b, w: 0), forKey: "inputBVector")
    filter.setValue(CIVector(x: bias.r, y: bias.g, z: bias.b, w: 0), forKey: "inputBiasVector")
    let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let out = filter.outputImage,
      let cg = context.createCGImage(out.cropped(to: extent), from: extent, format: .RGBA16, colorSpace: image.colorSpace ?? outputSpace)
    else { return image }
    return cg
  }
  /// `image`, linear, with the copy light's crosstalk taken out of every pixel, as
  /// `Crosstalk.unmixed` takes it out of a reading: kept above nothing, so each still has a density.
  func unmixed(_ image: CGImage, by crosstalk: Crosstalk) -> CGImage { corrected(image, crosstalk: crosstalk, flat: nil) }
}

/// An image's linear RGB, 0–1, for reading pixels.
private struct Pixels {
  let width: Int, height: Int
  private let data: [UInt16]
  init?(_ image: CGImage) {
    width = image.width
    height = image.height
    var buffer = [UInt16](repeating: 0, count: width * height * 4)
    guard let ctx = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.linearSRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
    else { return nil }
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    data = buffer
  }
  func rgb(_ x: Int, _ y: Int) -> SIMD3<Double> {
    let i = (y * width + x) * 4
    return SIMD3(Double(data[i]), Double(data[i + 1]), Double(data[i + 2])) / 65535
  }
  func bilinear(_ x: Double, _ y: Double) -> SIMD3<Double> {
    let ix = Int(floor(x)), iy = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
    func at(_ i: Int, _ j: Int) -> SIMD3<Double> { rgb(min(width - 1, max(0, i)), min(height - 1, max(0, j))) }
    return (at(ix, iy) * (1 - fx) + at(ix + 1, iy) * fx) * (1 - fy) + (at(ix, iy + 1) * (1 - fx) + at(ix + 1, iy + 1) * fx) * fy
  }
}
