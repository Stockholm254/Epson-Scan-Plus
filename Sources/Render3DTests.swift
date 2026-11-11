import AppKit
import SceneKit

/// The things drawn in 3D besides the films: a sleeve's plastic, and the calibration's and flat
/// field's plots.
enum Render3DTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    /// The picture's pixels, premultiplied RGBA, 0–1.
    func pixels(_ image: NSImage?) -> (w: Int, h: Int, at: (Int, Int) -> SIMD4<Double>)? {
      guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
      return pixels(cg)
    }
    func pixels(_ cg: CGImage) -> (w: Int, h: Int, at: (Int, Int) -> SIMD4<Double>)? {
      let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
      guard let data = ctx.data else { return nil }
      // Copied out: the context's memory goes with it. Its first row is the picture's top.
      let px = Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4), count: cg.width * cg.height * 4))
      let w = cg.width
      return (cg.width, cg.height, { x, y in
        let i = (y * w + x) * 4
        return SIMD4(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]), Double(px[i + 3])) / 255
      })
    }

    // A sleeve's plastic: never opaque, brighter on its welds than in the middle.
    if let image = SleevePlastic.shared.image(size: CGSize(width: 280, height: 40), scale: 2), let p = pixels(image) {
      var most = 0.0
      for y in 0..<p.h { for x in stride(from: 0, to: p.w, by: 7) { most = max(most, p.at(x, y).w) } }
      func row(_ y: Int) -> Double { (0..<p.w).map { p.at($0, y).x }.reduce(0, +) / Double(p.w) }
      try check(most <= 0.71 && row(2) > row(p.h / 2) * 2,
        String(format: "a sleeve's plastic lets the pictures through (most alpha %.2f) and shows its welds (%.3f against %.3f in the middle)", most, row(2), row(p.h / 2)))
    } else {
      try check(false, "a sleeve's plastic is drawn")
    }

    // The neutral points: the fit's line passes through those on it, the one pushed off is found.
    func point(_ L: Double, off: Double = 0) -> NeutralPoint {
      let s = [0.62, 0.55, 0.5], o = [0.05, 0, -0.08], base = RGB([0.8, 0.5, 0.3])
      let d = (0..<3).map { c in s[c] * (L + o[c]) + (c == 0 ? off : 0) }
      return NeutralPoint(frame: UUID(), value: RGB((0..<3).map { base.values[$0] / pow(10, d[$0]) }), base: base, gamma: 1)
    }
    let points = [point(0.4), point(0.8), point(1.2), point(1.6, off: 0.08), point(2.0)]
    let fit = try FilmCalibration.fit([points[0], points[1], points[2], points[4]], greenSlope: 0.55)
    let found = Plots3D.neutrals(points, fit: fit)
    let path = Plots3D.line(fit, from: 0.3, to: 2.1, steps: 360)
    func nearest(_ d: [Double]) -> Double {
      path.map { q in zip(q, d).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot() }.min() ?? 1
    }
    try check(found.enumerated().allSatisfy { i, p in (p.off > Plots3D.onLine) == (i == 3) } && [0, 1, 2, 4].allSatisfy { nearest(found[$0].d) < 0.01 },
      String(format: "the calibration's neutrals in 3D lie on the fit's line, and the one off it is marked (%.3f D off)", found[3].off))
    let neutralShot = pixels(Plots3D.snapshot(Plots3D.neutralScene(points, fit: fit), pixels: CGSize(width: 300, height: 260)))
    var lit = 0
    if let p = neutralShot { for y in stride(from: 0, to: p.h, by: 2) { for x in stride(from: 0, to: p.w, by: 2) where p.at(x, y).w > 0.5 { lit += 1 } } }
    try check(lit > 300, "the neutral points' plot is drawn (\(lit) samples)")

    // The flat field: one surface per light, as high as its share; the floor at the weakest.
    var values = [Float]()
    let w = 12, h = 8
    for j in 0..<h { for i in 0..<w {
      let x = (Double(i) + 0.5) / Double(w) - 0.5, y = (Double(j) + 0.5) / Double(h) - 0.5, r2 = x * x + y * y
      values += [Float(1 - 1.2 * r2), Float(1 - 0.8 * r2), Float(1 - 0.8 * r2)]
    } }
    let flat = FlatField(width: w, height: h, values: values)
    let low = flat.falloff.values.min()!
    let red = Plots3D.surface(flat, channel: 0, across: 100, deep: 66, floor: low, rise: 50)
    let heights = red.sources(for: .vertex).first.map { s -> [CGFloat] in
      s.data.withUnsafeBytes { raw in
        (0..<s.vectorCount).map { i in
          let at = i * s.dataStride + s.dataOffset + s.bytesPerComponent
          return s.bytesPerComponent == 8 ? CGFloat(raw.load(fromByteOffset: at, as: Double.self)) : CGFloat(raw.load(fromByteOffset: at, as: Float.self))
        }
      }
    } ?? []
    try check(!heights.isEmpty && abs(heights.min() ?? 1) < 1e-3 && abs((heights.max() ?? 0) - CGFloat(1 - low) * 50) < 3,
      String(format: "a flat field's fall-off is a surface per light, its weakest corner on the floor (%.1f to %.1f)", heights.min() ?? -1, heights.max() ?? -1))
  }
}
