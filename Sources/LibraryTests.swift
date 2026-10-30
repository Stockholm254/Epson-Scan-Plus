import AppKit
import Foundation

/// The three modules, the library of rolls, and the glass bubble over a dragged crop corner.
enum LibraryTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let pipe = ImagePipeline.shared
    let space = pipe.outputSpace
    /// An image painted by `paint` in top-left coordinates.
    func image(_ w: Int, _ h: Int, _ paint: (CGContext) -> Void) -> CGImage {
      let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.translateBy(x: 0, y: CGFloat(h))
      ctx.scaleBy(x: 1, y: -1)
      paint(ctx)
      return ctx.makeImage()!
    }
    /// RGBA at (x, y) from the top left, 0–1, alpha not undone.
    func pixel(_ cg: CGImage, _ x: Int, _ y: Int) -> [Double] {
      var px = [UInt8](repeating: 0, count: 4)
      let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
      return px.map { Double($0) / 255 }
    }

    // MARK: The glass bubble

    // Grey, with a white dot and a red column out to the right of the corner.
    let picture = image(400, 300) { c in
      c.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
      c.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
      c.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
      c.fill(CGRect(x: 209, y: 155, width: 3, height: 3))
      c.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
      c.fill(CGRect(x: 224, y: 120, width: 4, height: 60))
    }
    let crop = CGRect(x: 200, y: 150, width: 150, height: 100)
    let bubble = CropLens.render(picture, center: CGPoint(x: 200, y: 150), scale: 6, crop: crop, dimOutside: 0.5, pixels: 240)!
    try check(bubble.width == 240 && pixel(bubble, 1, 1)[3] < 0.01 && pixel(bubble, 120, 60)[3] > 0.99,
      "the crop bubble is round: clear in its corners, solid inside")
    let middle = pixel(bubble, 120, 120)
    try check(middle[0] > 0.85 && middle[2] < 0.55,
      "the dragged corner is in the middle of the bubble, on the crop's amber edges")
    let inside = pixel(bubble, 170, 165), outside = pixel(bubble, 70, 165)
    try check(abs(inside[1] - 0.5) < 0.04 && abs(outside[1] - 0.25) < 0.04,
      String(format: "inside the crop the picture is as it is (%.2f), outside darkened as on the canvas (%.2f)", inside[1], outside[1]))
    // The dot, 10.5 and 6.5 pixels from the corner, lands 4 × 1.5 = 6 times as far out.
    var lit = (x: 0.0, y: 0.0, n: 0.0)
    for y in 140...180 { for x in 160...205 where pixel(bubble, x, y)[2] > 0.9 { lit = (lit.x + Double(x), lit.y + Double(y), lit.n + 1) } }
    let dot = (x: lit.x / max(1, lit.n), y: lit.y / max(1, lit.n))
    try check(abs(dot.x - 183) <= 1.5 && abs(dot.y - 159) <= 1.5 && lit.n > 120,
      String(format: "the picture is magnified about the corner: a dot 10 pixels off shows 60 pixels off (%.1f, %.1f)", dot.x, dot.y))
    // At the rim the glass bends the picture outward: the red column, 24–28 pixels out, is
    // beyond the 20 a flat magnifier would reach.
    let rim = pixel(bubble, 237, 130)
    try check(rim[0] - rim[1] > 0.4 && abs(rim[1] - rim[2]) < 0.05,
      String(format: "the rim reaches out past the plain magnification, as glass does (%.2f %.2f %.2f)", rim[0], rim[1], rim[2]))
    let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
    let corner = CGPoint(x: 600, y: 400), nearTop = CGPoint(x: 100, y: 80)
    let up = CropLens.frame(for: corner, in: bounds), down = CropLens.frame(for: nearTop, in: bounds)
    try check(up.maxX < corner.x && up.maxY < corner.y && down.minX > nearTop.x && down.minY > nearTop.y
      && bounds.contains(up) && bounds.contains(down),
      "the bubble sits above and to the left of the corner, out of the way, and goes across near the edges")
    let swell = stride(from: 0.0, through: 0.2, by: 0.01).map { CropLens.appearance(shownFor: $0, released: nil).scale }
    let first = CropLens.appearance(shownFor: 0, released: nil), settled = CropLens.appearance(shownFor: 0.3, released: nil)
    try check(first.scale < 0.7 && first.opacity == 0 && settled == (1, 1) && swell.max()! > 1.005 && swell.max()! < 1.05
      && CropLens.appearance(shownFor: 1, released: 0.2).opacity == 0,
      "it swells in a little past full size and settles, and fades when let go")

    // MARK: A library

    let lib = folder.appendingPathComponent("library", isDirectory: true)
    let legacy = folder.appendingPathComponent("library-legacy", isDirectory: true)
    let files = FileManager.default
    try? files.removeItem(at: lib)
    try? files.removeItem(at: legacy)
    func roll(_ root: URL, _ name: String) throws -> URL {
      let url = root.appendingPathComponent(name, isDirectory: true)
      try files.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }
    // A scanned roll: three frames on the overview, each its own colour.
    let colours: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.2, 0.1), (0.1, 0.8, 0.2), (0.2, 0.3, 0.9)]
    let scanned = try roll(lib, "2026-10-20_101500_abcd")
    let overview = image(600, 300) { c in
      c.setFillColor(red: 0.9, green: 0.6, blue: 0.35, alpha: 1)
      c.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
      for (i, k) in colours.enumerated() {
        c.setFillColor(red: k.0, green: k.1, blue: k.2, alpha: 1)
        c.fill(CGRect(x: 30 + i * 190, y: 90, width: 150, height: 100))
      }
    }
    let overviewURL = scanned.appendingPathComponent("overview.png")
    try pipe.savePNG(overview, to: overviewURL)
    let scannedFrames = (0..<3).map { i in
      FilmFrame(name: String(format: "%02d", i + 1),
        rect: NormalRect(x: Double(30 + i * 190) / 600, y: 90.0 / 300, width: 150.0 / 600, height: 100.0 / 300), format: "135")
    }
    var project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 150, physicalWidthMM: 100, physicalHeightMM: 50,
      filmName: "Kodak Portra 400", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: scannedFrames)
    project.rollName = "海边"
    project.notes = "Leica M6"
    try JSONEncoder().encode(project).write(to: scanned.appendingPathComponent(AppModel.projectFile))
    try files.createDirectory(at: scanned.appendingPathComponent("Exports"), withIntermediateDirectories: true)
    try Data([1]).write(to: scanned.appendingPathComponent("Exports/01.tif"))
    // An imported roll: two files of its own.
    let imported = try roll(lib, "2026-10-22_090000_ef01")
    var importedFrames = [FilmFrame]()
    for i in 0..<2 {
      let url = imported.appendingPathComponent("Originals-\(i).png")
      try pipe.savePNG(image(90, 60) { c in
        c.setFillColor(red: 0.3, green: 0.3, blue: 0.3 + 0.3 * CGFloat(i), alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: 90, height: 60))
      }, to: url)
      var f = FilmFrame(name: String(format: "%02d", i + 1), rect: .full, format: "导入")
      f.sourcePath = url.path
      importedFrames.append(f)
    }
    try JSONEncoder().encode(DeskProject(
      overviewPath: importedFrames[0].sourcePath!, overviewDPI: 300, physicalWidthMM: 36, physicalHeightMM: 24,
      filmName: "Kodak Gold 200", profile: FilmProfile.builtins[0], scanDPI: 300, frames: importedFrames)
    ).write(to: imported.appendingPathComponent(AppModel.projectFile))
    // Not rolls: a folder without a project, and one whose project cannot be read.
    _ = try roll(lib, "notes")
    let broken = try roll(lib, "2026-10-23_120000_0000")
    try Data("{".utf8).write(to: broken.appendingPathComponent(AppModel.projectFile))
    // An older roll in the old library, as Film Desk saved it.
    let old = try roll(legacy, "2026-10-10_080000_9999")
    try JSONEncoder().encode(DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 150, physicalWidthMM: 100, physicalHeightMM: 50,
      filmName: "Fujifilm C200", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: [scannedFrames[0]])
    ).write(to: old.appendingPathComponent("Session.filmdesk"))

    let entries = RollLibrary.scan([(lib, false), (legacy, true), (lib, false)])
    try check(entries.map(\.folder.lastPathComponent) == [imported, scanned, old].map(\.lastPathComponent),
      "the library lists every roll it can read, newest first, each once; folders without a readable project are left out")
    let sea = entries[1], gold = entries[0], c200 = entries[2]
    try check(sea.title == "海边" && sea.named && sea.notes == "Leica M6" && sea.film == "Kodak Portra 400"
      && sea.source == .scanner && sea.frames.count == 3 && sea.exported == 1 && sea.fullResolution == 0,
      "a roll shows its name, notes, film, frames and exports")
    try check(!gold.named && gold.title == RollLibrary.title(RollLibrary.started(imported.lastPathComponent)!)
      && gold.source == .files && gold.fullResolution == 2 && gold.frames.map { $0.file == nil } == [true, false],
      "an unnamed roll goes by when it was started; imported pictures are told by their frames")
    try check(c200.legacy && c200.project.lastPathComponent == "Session.filmdesk",
      "rolls from the folder older versions used are listed too, as they were saved")

    let negatives = RollLibrary.thumbnails(for: sea)
    let firstFrame = negatives[scannedFrames[0].id].map { pixel($0.image, $0.image.width / 2, $0.image.height / 2) } ?? []
    try check(negatives.count == 3 && negatives.values.allSatisfy { !$0.positive }
      && firstFrame.count == 4 && abs(firstFrame[0] - 0.9) < 0.06 && abs(firstFrame[1] - 0.2) < 0.06,
      "until the app has rendered a roll its pockets hold the frames as they are on the film")
    let green = image(60, 40) { c in
      c.setFillColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1)
      c.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
    }
    RollLibrary.storePositives([scannedFrames[0].id: green, scannedFrames[1].id: green], folder: scanned)
    let positives = RollLibrary.thumbnails(for: sea)
    let kept = RollLibrary.cacheFolder(for: scanned)
    try check(positives[scannedFrames[0].id]?.positive == true && positives[scannedFrames[2].id]?.positive == false
      && kept.path.hasPrefix(RollLibrary.cacheRoot.path) && kept != RollLibrary.cacheFolder(for: imported)
      && !files.fileExists(atPath: scanned.appendingPathComponent(".thumbnails").path),
      "the positives the app renders are kept in the caches, a folder per roll, and shown in its pockets")
    let upright = image(40, 60) { c in
      c.setFillColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1)
      c.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
    }
    try check(RollLibrary.across(upright).width == 60 && RollLibrary.across(green).width == 60,
      "upright frames lie across their pockets, as on the turned light table")
    RollLibrary.storePositives([scannedFrames[1].id: green], folder: scanned)
    try check(RollLibrary.thumbnails(for: sea)[scannedFrames[0].id]?.positive == false,
      "a frame no longer rendered loses its kept positive")

    // MARK: The modules, and opening a roll

    let model = AppModel(libraryURL: lib)
    try check(model.page == .capture && model.panelTab == .scan && model.libraryRoots.count == 1,
      "the window opens on ① 采集 with the scanner's panel; a library chosen elsewhere lists only itself")
    model.page = .convert
    try check(model.panelTab == .film, "② 去色罩 opens on film and presets")
    model.panelTab = .scan
    try check(model.page == .capture, "and the scanner's settings (⌘,) take the window back to ① 采集")
    model.page = .convert
    model.tool = .neutral
    model.page = .capture
    try check(model.tool == .select, "the pickers are put down on going back to capture")
    model.openRoll(sea)
    for _ in 0..<40 where model.rendering { settle(0.1) }
    try check(model.sessionURL?.standardizedFileURL == scanned.standardizedFileURL && model.page == .convert
      && model.rollName == "海边" && model.rollNotes == "Leica M6" && !model.showLibrary,
      "a roll opened from the library goes on to ② 去色罩 with its name and notes")
    model.rollName = "海边与天空"
    model.saveProject()
    try check(RollLibrary.entry(scanned.appendingPathComponent(AppModel.projectFile))?.title == "海边与天空",
      "a new name is saved with the roll")
    model.rollName = "x"
    let png = folder.appendingPathComponent("library-import.png")
    try pipe.savePNG(green, to: png)
    model.importURLs([png])
    settle()
    let after = RollLibrary.scan([(lib, false)])
    try check(model.rollName.isEmpty && after.count == 3 && after.contains { $0.source == .files && $0.frames.count == 1 && $0.folder != imported },
      "imported pictures make a new roll of their own, unnamed, which the library lists")

    // MARK: The bubble on the canvas

    model.openRoll(RollLibrary.scan([(lib, false)]).first { $0.folder.lastPathComponent == scanned.lastPathComponent }!)
    model.singleView = false
    model.preferences.showLoupe = false
    for _ in 0..<40 where model.rendering { settle(0.1) }
    let canvas = FilmCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = canvas
    canvas.model = model
    settle()
    func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    // A frame's crop is set on its own, with the crop tool.
    model.select(model.frames[1].id)
    model.singleView = true
    model.useTool(.crop)
    for _ in 0..<40 where model.rendering { settle(0.1) }
    canvas.display()
    guard let crop = model.canvasCrop else { throw DeskError.message("FAIL: the crop tool shows the frame's crop") }
    let handle = canvas.corners(crop.cg)[3], to = CGPoint(x: handle.x - 8, y: handle.y - 6)
    canvas.mouseDown(with: event(.leftMouseDown, handle))
    canvas.mouseDragged(with: event(.leftMouseDragged, to))
    canvas.display()
    let drawn = canvas.lensDrawn
    try check(canvas.lens != nil && drawn != nil && !drawn!.frame.contains(to) && canvas.bounds.contains(drawn!.frame),
      "dragging a crop's corner brings up the glass bubble beside it, clear of the pointer")
    canvas.mouseUp(with: event(.leftMouseUp, to))
    try check(canvas.lens == nil && canvas.lensFading != nil, "letting go, the bubble fades")
    settle(0.4)
    try check(canvas.lensFading == nil, "and is gone")
    for _ in 0..<40 where model.rendering { settle(0.1) }
    let middleOfFrame = canvas.screen((model.canvasCrop ?? crop).cg)
    let grab = CGPoint(x: middleOfFrame.midX, y: middleOfFrame.midY)
    canvas.mouseDown(with: event(.leftMouseDown, grab))
    canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: grab.x + 10, y: grab.y)))
    try check(canvas.lens == nil, "moving a whole crop brings no bubble")
    canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: grab.x + 10, y: grab.y)))
    window.contentView = nil
  }
}
