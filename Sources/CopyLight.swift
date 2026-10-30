import CoreGraphics
import CoreImage
import Foundation

/// The copy stand's light, measured and taken out of what the camera read: its crosstalk, then its
/// fall-off across the frame.
extension ImagePipeline {
  private static let divideByFlat = CIColorKernel(
    source: "kernel vec4 flatten(__sample p, __sample f) { return vec4(p.rgb / max(f.rgb, vec3(0.05)), p.a); }")

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
    if let flat, let divide = Self.divideByFlat, let grid = flatImage(flat, size: extent.size) {
      ci = divide.apply(extent: extent, arguments: [ci, grid]) ?? ci
    }
    return context.createCGImage(ci.cropped(to: extent), from: extent, format: .RGBA16, colorSpace: image.colorSpace ?? outputSpace) ?? image
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

  /// The copy light from its red, green and blue lights each alone on a blank frame (no film), in any
  /// order: which light each frame shows is told by its brightest channel. Each light's column of the
  /// crosstalk is the median of the other channels against its own, over the frame where it is well
  /// exposed (between 5% and 95% of full); its flat field, once the crosstalk is out, its own channel
  /// over a grid of 24 × 16 cells, each cell's median, against the brightest cell. Cells the light
  /// hardly reaches (under a quarter of the brightest: the stand's mask) are left alone. Nil when the
  /// three frames are not one light each, or a light is too weak to measure.
  func lightCalibration(_ frames: [CGImage], date: Date = Date()) -> (calibration: LightCalibration, exposure: RGB)? {
    guard frames.count == 3 else { return nil }
    let read = frames.map { samples($0, maxDimension: 600) }
    func median(_ v: [Double]) -> Double {
      guard !v.isEmpty else { return 0 }
      let s = v.sorted()
      return s[s.count / 2]
    }
    var columns = [Int: [Double]](), exposure = [Int: Double](), lights = [Int]()
    for s in read {
      var pixels = [RGB]()
      for y in stride(from: s.height / 20, to: s.height - s.height / 20, by: 2) {
        for x in stride(from: s.width / 20, to: s.width - s.width / 20, by: 2) { pixels.append(s.pixel(x, y)) }
      }
      let levels = (0..<3).map { c in median(pixels.map { p in p.values[c] }) }
      let own = levels.indices.max { levels[$0] < levels[$1] } ?? 0
      let lit = pixels.filter { p in p.values[own] > 0.05 && p.values[own] < 0.95 }
      guard lit.count > 100, columns[own] == nil else { return nil }
      var column = [Double]()
      for c in 0..<3 { column.append(c == own ? 1 : median(lit.map { p in p.values[c] / p.values[own] })) }
      columns[own] = column
      lights.append(own)
      exposure[own] = median(lit.map { p in p.values[own] })
    }
    guard columns.count == 3, let r = columns[0], let g = columns[1], let b = columns[2],
      [r, g, b].enumerated().allSatisfy({ j, col in (0..<3).allSatisfy { $0 == j || col[$0] < 0.8 } })
    else { return nil }
    let crosstalk = Crosstalk(m: (0..<3).flatMap { c in [r[c], g[c], b[c]] })
    // Each light's own channel once the crosstalk is out, cell by cell.
    let gw = 24, gh = 16
    var values = [Float](repeating: 1, count: gw * gh * 3)
    for (s, light) in zip(read, lights) {
      var cells = [Double]()
      for cy in 0..<gh {
        for cx in 0..<gw {
          var v = [Double]()
          for y in (cy * s.height / gh)..<max(cy * s.height / gh + 1, (cy + 1) * s.height / gh) {
            for x in (cx * s.width / gw)..<max(cx * s.width / gw + 1, (cx + 1) * s.width / gw) {
              let p = s.pixel(x, y)
              guard max(p.r, p.g, p.b) < 0.98 else { continue }
              v.append(crosstalk.unmixed(p).values[light])
            }
          }
          cells.append(median(v))
        }
      }
      let top = cells.max() ?? 1
      guard top > 0 else { return nil }
      for (i, c) in cells.enumerated() {
        let share = c / top
        values[i * 3 + light] = Float(share >= 0.25 ? share : 1)
      }
    }
    return (LightCalibration(date: date, crosstalk: crosstalk, flat: FlatField(width: gw, height: gh, values: values)),
      RGB(r: exposure[0] ?? 0, g: exposure[1] ?? 0, b: exposure[2] ?? 0))
  }
}
