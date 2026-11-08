import AppKit

/// The two crops: the picture's, which is shown and exported, and the de-masking region inside it,
/// the only part the base estimate, white balance, levels and highlight reach read.
enum AnalysisRegionTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let pipe = ImagePipeline.shared
    // A negative: its left half greys from thin to dense under an orange mask, its right half one
    // dense patch cast yellow-green (blue layer far denser), its thinnest film in the right half.
    let w = 160, h = 100
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for x in 0..<w {
      for y in 0..<h {
        let d = Double(x % 80) / 80 * 0.9 + Double(y) / Double(h) * 0.3
        let v: (Double, Double, Double) = x < w / 2
          ? (0.8 * pow(10, -d), 0.5 * pow(10, -d), 0.3 * pow(10, -d))
          : (y < 10 ? (0.85, 0.55, 0.33) : (0.8 * pow(10, -0.3), 0.5 * pow(10, -0.35), 0.3 * pow(10, -1.1)))
        ctx.setFillColor(CGColor(red: v.0, green: v.1, blue: v.2, alpha: 1))
        ctx.fill(CGRect(x: x, y: h - 1 - y, width: 1, height: 1))
      }
    }
    let negative = ctx.makeImage()!
    let profile = FilmProfile.builtins[0]
    var plain = Adjustments()
    plain.inputGamma = 2.2
    var left = plain
    left.analysisRegion = NormalRect(x: 0, y: 0, width: 0.5, height: 1)
    var whole = plain
    whole.analysisRegion = .full
    let part = try pipe.crop(negative, rect: NormalRect(x: 0, y: 0, width: 0.5, height: 1))
    let inRegion = pipe.analyze(negative, settings: left, profile: profile)
    let alone = pipe.analyze(part, settings: whole, profile: profile)
    let everywhere = pipe.analyze(negative, settings: plain, profile: profile)
    func near(_ a: RGB, _ b: RGB, _ e: Double = 1e-6) -> Bool { zip(a.values, b.values).allSatisfy { abs($0 - $1) < e } }
    try check(near(inRegion.base, alone.base) && near(inRegion.balance, alone.balance) && abs(inRegion.low - alone.low) < 1e-6
      && abs(inRegion.high - alone.high) < 1e-6,
      "with a de-masking region the base estimate, balance and ends are those of that part alone, all of it, no margin left out")
    try check(!near(inRegion.base, everywhere.base, 0.01) && !near(inRegion.balance, everywhere.balance, 0.02),
      String(format: "and differ from the whole picture's, whose thinnest film and cast lie outside the region: blue balance %.3f against %.3f",
        inRegion.balance.b, everywhere.balance.b))

    // The crop changed: the region stays where it lay on the film, cut to the crop, or follows the
    // picture again once it falls outside.
    var frame = FilmFrame(name: "01", rect: .full, format: "翻拍")
    frame.adjustments.analysisRegion = NormalRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25)
    frame.rect = NormalRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    let moved = frame.adjustments.analysisRegion
    frame.rect = NormalRect(x: 0, y: 0, width: 0.4, height: 0.4)
    try check(moved.map { near(RGB(r: $0.x, g: $0.y, b: $0.width), RGB(r: 0.5, g: 0.5, b: 0.5)) && abs($0.height - 0.5) < 1e-9 } == true
      && frame.adjustments.analysisRegion == nil,
      "a new crop keeps the de-masking region on the same film, and one left outside it follows the picture")

    // In the app: set, undone, kept through 同步到本卷 and 重置, too small left out, ⌫ with its tool.
    let root = folder.appendingPathComponent("analysis-region", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let decoded = root.appendingPathComponent("roll/Decoded", isDirectory: true)
    try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: root.appendingPathComponent("library"), preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    for n in 1...2 {
      let url = decoded.appendingPathComponent("EPS0000\(n).tif")
      try pipe.saveTIFF(negative, to: url, dpi: 300)
      model.addCapturedFrame(url, original: url, linear: false)
    }
    model.select(model.frames[0].id)
    let region = NormalRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5)
    model.setAnalysisRegion(region)
    let set = model.frames[0].adjustments.analysisRegion == region && model.status.contains("去色罩区域")
    edits.undo()
    let undone = model.frames[0].adjustments.analysisRegion == nil
    model.setAnalysisRegion(region)
    model.applyToRoll()
    let ownKept = model.frames[0].adjustments.analysisRegion == region && model.frames[1].adjustments.analysisRegion == nil
    model.resetAdjustments()
    let resetKept = model.frames[0].adjustments.analysisRegion == region
    model.setAnalysisRegion(NormalRect(x: 0.1, y: 0.1, width: 0.01, height: 0.5))
    let tinyIgnored = model.frames[0].adjustments.analysisRegion == region
    model.useTool(.region)
    model.deletePressed()
    try check(set && undone && ownKept && resetKept && tinyIgnored && model.frames[0].adjustments.analysisRegion == nil
      && model.frames.count == 2 && model.singleView,
      "the region is set and undone as an edit, each frame keeps its own through 同步到本卷 and 重置, a box under 3% is left out, and ⌫ with its tool up follows the picture again, the frame kept")

    // On the canvas: a drag with the tool draws the region where the pointer went, in the picture's
    // own coordinates; cyan shows only where there is a region, or its tool is up.
    let canvas = FilmCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = canvas
    canvas.model = model
    model.preferences.showLoupe = false
    model.refresh()
    for _ in 0..<60 where model.displayed == nil || model.rendering { settle(0.1) }
    func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let r = canvas.imageRect
    let from = CGPoint(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.3), to = CGPoint(x: r.minX + r.width * 0.7, y: r.minY + r.height * 0.8)
    let a = canvas.pictureNormal(from), b = canvas.pictureNormal(to)
    canvas.mouseDown(with: event(.leftMouseDown, from))
    canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)))
    canvas.mouseDragged(with: event(.leftMouseDragged, to))
    canvas.mouseUp(with: event(.leftMouseUp, to))
    let drawn = model.frames[0].adjustments.analysisRegion
    let expected = a.flatMap { a in b.map { b in CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)) } }
    try check(drawn != nil && expected.map { e in abs(drawn!.x - e.minX) < 1e-6 && abs(drawn!.width - e.width) < 1e-6
      && abs(drawn!.y - e.minY) < 1e-6 && abs(drawn!.height - e.height) < 1e-6 } == true && r.width > 100,
      "a drag with the de-masking tool draws the region from where it went down to where it came up: \(drawn.map { "\($0.cg)" } ?? "none")")
    func cyan() -> Int {
      guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return 0 }
      canvas.cacheDisplay(in: canvas.bounds, to: rep)
      var n = 0
      for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
          guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
          if c.blueComponent > 0.75 && c.greenComponent > 0.6 && c.redComponent < 0.55 && c.blueComponent - c.redComponent > 0.35 { n += 1 }
        }
      }
      return n
    }
    let editing = cyan()
    model.useTool(.select)
    let showing = cyan()
    model.setAnalysisRegion(nil)
    let none = cyan()
    model.singleView = false
    // The test picture has a few cyan-ish samples of its own.
    try check(editing > showing && showing > none * 5,
      "cyan marks the region: boxed with corners and its label while its tool is up (\(editing)), dashed while it only shows (\(showing)), none without one (\(none))")
    try check(CanvasTool.crop.colour != nil && CanvasTool.region.colour != nil && CanvasTool.crop.symbol != CanvasTool.region.symbol
      && CanvasTool.region.help.contains("青色") && CanvasTool.crop.help.contains("琥珀色") && CanvasTool.region.shortcut == "m",
      "the two crops have their own keys, symbols and colours: the picture amber, the de-masking region cyan (M)")
  }
}
