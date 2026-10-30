import CoreGraphics
import Foundation

/// The film base read at a copy shot's edges: found in the rebate and the gaps past bare light and
/// grain, not in the picture's own clear shadows; each picture its own, the nearest one's where its
/// edges show none, and a base picked for the roll first.
enum EdgeBaseTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    // A copy shot, linear 16-bit as the sensor reads it: bare light past the film on the left, the
    // grainy rebate along the top and bottom and the gaps at the sides, and inside the picture
    // denser film with a shadow nearly as clear as the base, of its colour, away from the edges.
    let w = 360, h = 240
    func shot(base: RGB?, seed: UInt32) -> CGImage {
      var px = [UInt16](repeating: 0, count: w * h * 3)
      var noise = seed
      func grain() -> Double {
        noise = noise &* 1_664_525 &+ 1_013_904_223
        return 1 + (Double(noise >> 8) / Double(1 << 24) - 0.5) * 0.06
      }
      let film = base ?? RGB(r: 0.25, g: 0.66, b: 0.41)
      for y in 0..<h {
        for x in 0..<w {
          let edge = base != nil && (y < 11 || y >= h - 11 || x < 21 || x >= w - 21)
          var v: [Double]
          if base != nil && x < 4 {
            v = [1, 1, 1]
          } else if edge {
            v = film.values.map { $0 * grain() }
          } else if (150..<200).contains(x) && (80..<140).contains(y) || base != nil && (21..<60).contains(x) && (60..<180).contains(y) {
            // Shadows nearly as clear as the base and of its colour: one in the middle, one reaching
            // into the gap at the side with no frame line between.
            v = film.values.map { $0 * 0.98 }
          } else {
            let d = 0.3 + 0.8 * Double((x / 24 + y / 24) % 4) / 3
            v = [film.r * pow(10, -d * 0.8), film.g * pow(10, -d), film.b * pow(10, -d * 1.1)]
          }
          for c in 0..<3 { px[(y * w + x) * 3 + c] = UInt16(min(65535, max(0, v[c] * 65535))) }
        }
      }
      let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6,
        space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    func close(_ a: RGB?, _ b: RGB, _ e: Double = 0.015) -> Bool {
      guard let a else { return false }
      return zip(a.values, b.values).allSatisfy { abs($0 / $1 - 1) < e }
    }
    let orange = RGB(r: 0.25, g: 0.66, b: 0.41)
    let found = pipe.edgeBase(shot(base: orange, seed: 1))
    let shadow = CGRect(x: 150.0 / Double(w), y: 80.0 / Double(h), width: 50.0 / Double(w), height: 60.0 / Double(h))
    let reaching = CGRect(x: 21.0 / Double(w), y: 60.0 / Double(h), width: 39.0 / Double(w), height: 120.0 / Double(h))
    let atEdges = found.areas.allSatisfy { a in
      a.x < 0.13 || a.x + a.width > 0.87 || a.y < 0.13 || a.y + a.height > 0.87
    }
    try check(close(found.base, orange) && !found.areas.isEmpty && atEdges
      && !found.areas.contains { $0.cg.intersects(shadow) || $0.cg.intersects(reaching) },
      "the base is read off the rebate and the gaps at a copy shot's edges, outside the frame's own edge, past bare light and grain; not off a shadow of the picture as clear, even one reaching into the gap: \(found.base.map { $0.values.map { String(format: "%.3f", $0) } } ?? [])")
    let tight = pipe.edgeBase(shot(base: nil, seed: 2))
    try check(tight.base == nil && tight.areas.isEmpty, "a picture cropped to its frame shows no base at its edges")

    // A roll of three: the light balanced again before the third, the second cropped to its frame.
    let root = folder.appendingPathComponent("edge-base", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let decoded = root.appendingPathComponent("Decoded", isDirectory: true)
    try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
    let balanced = RGB(r: 0.21, g: 0.62, b: 0.43)
    var urls = [URL]()
    for (n, base) in [orange, nil, balanced].enumerated() {
      let url = decoded.appendingPathComponent("EPS0000\(n + 1).tif")
      try pipe.saveTIFF(shot(base: base, seed: UInt32(n + 3)), to: url, dpi: 300)
      urls.append(url)
    }
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: root.appendingPathComponent("library"), preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    for url in urls { model.addCapturedFrame(url, original: url, linear: true) }
    model.measureEdgeBases(wait: true)
    let f = model.frames
    try check(f.count == 3 && close(f[0].edgeBase?.base, orange) && f[1].edgeBase != nil && f[1].edgeBase?.base == nil && close(f[2].edgeBase?.base, balanced)
      && close(f[0].adjustments.rollBase, orange) && close(f[1].adjustments.rollBase, orange) && close(f[2].adjustments.rollBase, balanced),
      "each picture converts from the base at its own edges, the light as it was set for it; one whose edges show none from the nearest one's")
    try check(model.baseSource(f[0]) == "片基来自这一张片边的未曝光片基" && model.baseSource(f[1]).contains("第 01 张")
      && model.edgeBaseSource(1) == 0 && model.edgeBaseSource(2) == 2,
      "the panel says where each frame's base came from: \(model.baseSource(f[1]))")
    let pipeBase = pipe.densities(try model.source(for: model.frames[2], maxDimension: 300), settings: model.frames[2].adjustments).base
    try check(close(pipeBase, balanced), "the conversion divides by the base found at the edges")
    // Picked by hand on the single frame: where, kept with the base, and undone with it.
    model.select(model.frames[0].id)
    model.singleView = true
    model.setFilmBase(RGB(r: 0.26, g: 0.67, b: 0.42), at: NormalRect(x: 0.4, y: 0.02, width: 0.02, height: 0.03))
    let kept = model.frames[0].adjustments.basePicked
    edits.undo()
    try check(kept?.x == 0.4 && model.frames[0].adjustments.base == nil && model.frames[0].adjustments.basePicked == nil
      && model.baseSource(model.frames[0]) == "片基来自这一张片边的未曝光片基",
      "a base picked by hand keeps where it was picked, and undo takes both back to the edges'")
    // Two more: the first light again, and one whose edges read a colour unlike all the others
    // (the holder, say). With three or more reading a base, a reading no other shares is passed
    // over, and so now is the third's, alone under its light.
    let odd = RGB(r: 0.30, g: 0.70, b: 0.26)
    for (n, base) in [orange, odd].enumerated() {
      let url = decoded.appendingPathComponent("EPS0000\(n + 4).tif")
      try pipe.saveTIFF(shot(base: base, seed: UInt32(n + 9)), to: url, dpi: 300)
      model.addCapturedFrame(url, original: url, linear: true)
    }
    model.measureEdgeBases(wait: true)
    try check(model.frames.count == 5 && close(model.frames[4].edgeBase?.base, odd) && model.edgeBaseSource(4) == 3
      && model.edgeBaseSource(2) == 3 && model.edgeBaseSource(0) == 0 && close(model.frames[4].adjustments.rollBase, orange)
      && model.baseSource(model.frames[4]).contains("第 04 张"),
      "a reading at the edges no other picture of the roll shares is passed over for the nearest one that is shared")
    // A base picked by hand and shared with the roll comes first.
    model.select(model.frames[1].id)
    let picked = RGB(r: 0.3, g: 0.6, b: 0.4)
    model.setFilmBase(picked)
    model.shareFilmBase()
    model.updateRollBase()
    try check(model.frames.allSatisfy { close($0.adjustments.rollBase, picked) && $0.adjustments.rollBasePicked == true }
      && model.baseSource(model.frames[0]) == "片基来自整卷共用的手动取样",
      "a base picked and shared with the roll takes the place of the edges'")
  }
}
