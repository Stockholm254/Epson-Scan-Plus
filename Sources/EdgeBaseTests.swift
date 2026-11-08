import AppKit
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
    // An uncropped picture with the automatic base, come up on its own: where the base was read is
    // marked for three seconds and fades; where its edges showed none, a note says whose it uses.
    // Waiting for its edges to be looked at, cropped, or its base picked by hand, nothing is said.
    model.frames[0].edgeBase = nil
    model.select(model.frames[0].id)
    model.singleView = true
    let waiting = model.baseFlash == nil && model.canvasNote == nil
    model.measureEdgeBases(wait: true)
    let marked = model.baseFlash?.id == model.frames[0].id && model.canvasNote == nil
    model.select(model.frames[1].id)
    let borrowed = model.baseFlash == nil ? model.canvasNote ?? "" : ""
    model.frames[2].rect = NormalRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
    model.select(model.frames[2].id)
    let cropped = model.baseFlash == nil && model.canvasNote == nil
    model.frames[2].rect = .full
    model.frames[0].adjustments.base = orange
    model.select(model.frames[0].id)
    let pickedQuiet = model.baseFlash == nil && model.canvasNote == nil
    model.frames[0].adjustments.base = nil
    model.select(model.frames[1].id)
    model.singleView = false
    let fades = BaseFlash.opacity(0) == 1 && BaseFlash.opacity(2.9) == 1 && BaseFlash.opacity(3.3) > 0.1
      && BaseFlash.opacity(3.3) < 0.9 && BaseFlash.opacity(3.7) == 0
    try check(waiting && marked && borrowed == "这张片边上没找到片基，用第 01 张片边的" && cropped && pickedQuiet && fades
      && model.canvasNote == nil,
      "an uncropped picture on its own marks where its automatic base was read, for three seconds and fading, once its edges are looked at; one whose edges show none says whose it uses: \(borrowed)")
    // Drawn: the amber cells and their label while marked, gone once faded.
    func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let canvas = FilmCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = canvas
    canvas.model = model
    model.preferences.showLoupe = false
    model.select(model.frames[0].id)
    model.singleView = true
    model.refresh()
    for _ in 0..<60 where model.displayed == nil || model.rendering { settle(0.1) }
    // The marks' amber, filled or laid over the dark rebate; the test picture is grey and cyan.
    func amber() -> Int {
      guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return 0 }
      canvas.cacheDisplay(in: canvas.bounds, to: rep)
      var n = 0
      for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
          guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
          let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
          if r > 0.3 && r > g + 0.05 && g > b + 0.05 && g / r > 0.6 && g / r < 0.85 { n += 1 }
        }
      }
      return n
    }
    let shown = model.baseFlash != nil ? amber() : 0
    model.baseFlash = model.baseFlash.map { BaseFlash(id: $0.id, start: $0.start - 10) }
    let faded = amber()
    model.singleView = false
    try check(shown > 40 && faded * 10 < shown,
      "on the single view the marks are drawn while they hold (\(shown) amber samples) and gone once faded (\(faded))")
    // The strip over the single frame: where each base comes from, and how the balance is set.
    let strip = (model.baseShort(model.frames[0]), model.baseShort(model.frames[1]))
    model.frames[0].adjustments.base = orange
    model.frames[0].adjustments.baseFine = RGB(r: 0.1, g: 0, b: 0)
    let pickedStrip = model.baseShort(model.frames[0])
    let autoStrip = model.balanceShort(model.frames[0])
    model.frames[0].adjustments.neutralSample = RGB(r: 0.1, g: 0.3, b: 0.2)
    model.frames[0].adjustments.warmth = 0.2
    model.frames[0].adjustments.shadowWarmth = -0.1
    let greyStrip = model.balanceShort(model.frames[0])
    (model.frames[0].adjustments.base, model.frames[0].adjustments.baseFine) = (nil, nil)
    (model.frames[0].adjustments.neutralSample, model.frames[0].adjustments.warmth, model.frames[0].adjustments.shadowWarmth) = (nil, 0, nil)
    try check(strip == ("本张片边", "第 01 张片边") && pickedStrip == "手动取样 · 微调" && autoStrip == "自动"
      && greyStrip == "取样中性灰 · 冷暖 +0.20 · 阴影冷暖 -0.10",
      "the strip over the single frame says in a few words where its base comes from and how its balance is set: \(strip.1) / \(pickedStrip) / \(greyStrip)")
    // A roll whose only picture shows no base at its edges: the picture's clearest film stands in.
    let lone = AppModel(libraryURL: root.appendingPathComponent("library-lone"), preferences: Preferences(defaults: defaults))
    lone.addCapturedFrame(urls[1], original: urls[1], linear: true)
    lone.measureEdgeBases(wait: true)
    lone.select(lone.frames[0].id)
    lone.singleView = true
    let none = lone.canvasNote ?? ""
    lone.singleView = false
    try check(none == "片边上没找到片基，按画面里最透的地方估计 · 可按 B 手动取" && lone.baseFlash == nil
      && lone.baseShort(lone.frames[0]) == "本张最透处估计",
      "where no picture of the roll shows a base at its edges, the note says the picture's clearest film stands in")
    // The crosstalk turned off and on again while the edges were looked at: the look at the reading
    // with it in comes back after the picture has it out again. It is let go, and the look at the
    // picture as it reads now gives the base, the base as unmixed as the picture.
    let mix = Crosstalk.measured
    model.frames[0].edgeBase = nil
    let stale = model.lookAtEdges([model.frames[0]])
    model.frames[0].crosstalk = mix
    model.takeEdgeLooks(stale)
    let letGo = model.frames[0].edgeBase == nil
    model.measureEdgeBases(wait: true)
    try check(letGo && close(model.frames[0].edgeBase?.base, mix.unmixed(orange)) && close(model.frames[0].adjustments.rollBase, mix.unmixed(orange)),
      "a look at the edges taken on a reading the picture no longer has is let go, and the base comes from the reading it has: \(model.frames[0].adjustments.rollBase?.values.map { String(format: "%.3f", $0) } ?? [])")
    model.frames[0].crosstalk = nil
    model.frames[0].edgeBase = nil
    model.measureEdgeBases(wait: true)
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
