import AppKit
import Foundation

/// The canvas from the keyboard and mouse: tool keys, delete while picking points, and the light
/// table lying across; and a project opened only to read from.
enum CanvasTests {
  /// Scans by being told, so a test can say how far it has got.
  private final class HeadScanner: ScannerController {
    override func scan(rect: NormalRect, dpi: Int, directory: URL, name: String) throws {
      busy = true
      progress = 0
    }
    func finish() {
      busy = false
      progress = 1
      onFinished?(DeskError.message("stopped by the test"))
    }
  }
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let pipe = ImagePipeline.shared

    // Turning a picture a quarter turn: a mark in the top left corner of a 3 × 2 image.
    let ctx = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
      space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
    ctx.data!.storeBytes(of: UInt32(0xFF00_00FF).littleEndian, as: UInt32.self)  // row 0 is the top
    let marked = ctx.makeImage()!
    /// Where the red pixel is, from the top left.
    func mark(_ image: CGImage) -> (Int, Int, Int, Int) {
      let w = image.width, h = image.height
      var px = [UInt8](repeating: 0, count: w * h * 4)
      let read = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      read.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      let i = (0..<(w * h)).first { px[$0 * 4] > 200 } ?? -1
      return (w, h, i % w, i / w)
    }
    let cw = pipe.turned(marked, quarterTurns: 1)!, ccw = pipe.turned(marked, quarterTurns: 3)!
    try check(mark(cw) == (2, 3, 1, 0) && mark(ccw) == (2, 3, 0, 2) && mark(pipe.turned(marked, quarterTurns: 2)!) == (3, 2, 2, 1),
      "a quarter turn clockwise takes the top left corner to the top right, anticlockwise to the bottom left")
    let p = CGPoint(x: 0.2, y: 0.7)
    try check((0..<4).allSatisfy { t in
      let q = QuarterTurn(t), back = q.overview(q.shown(p))
      return abs(back.x - p.x) < 1e-12 && abs(back.y - p.y) < 1e-12
    } && QuarterTurn(1).shown(CGPoint(x: 0, y: 0)) == CGPoint(x: 1, y: 0) && QuarterTurn(3).shown(CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 1),
      "and the table's coordinates turn the same way, and back")

    // An upright holder: four 135 frames down one strip, as the V850's holder lies on the bed.
    let roll = folder.appendingPathComponent("canvas-turn")
    try? FileManager.default.removeItem(at: roll)
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    let ow = 800, oh = 1500
    let draw = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
      space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw.setFillColor(red: 0.95, green: 0.6, blue: 0.35, alpha: 1)
    draw.fill(CGRect(x: 0, y: 0, width: ow, height: oh))
    let frames = (0..<4).map { i in
      FilmFrame(name: String(format: "%02d", i + 1),
        rect: NormalRect(x: 293.0 / 800, y: (90 + Double(i) * 340) / 1500, width: 214.0 / 800, height: 320.0 / 1500), format: "135")
    }
    for f in frames {
      draw.setFillColor(red: 0.3, green: 0.2, blue: 0.15, alpha: 1)
      let r = f.rect.pixels(CGSize(width: ow, height: oh))
      draw.fill(CGRect(x: r.minX, y: CGFloat(oh) - r.maxY, width: r.width, height: r.height))
    }
    let overviewURL = roll.appendingPathComponent("overview.png")
    try pipe.savePNG(draw.makeImage()!, to: overviewURL)
    let project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 150, physicalWidthMM: 135.5, physicalHeightMM: 254,
      filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: frames)
    let projectURL = roll.appendingPathComponent("turn.epscan")
    try JSONEncoder().encode(project).write(to: projectURL)

    // Opened only to read from, nothing it does writes the project back.
    let saved = try Data(contentsOf: projectURL)
    let reader = AppModel(libraryURL: roll)
    reader.readOnly = true
    reader.loadProject(projectURL)
    for _ in 0..<40 where reader.rendering { settle(0.1) }
    reader.select(reader.frames[0].id)
    reader.change { $0.exposure = 0.5 }
    reader.saveProject()
    settle()
    try check(try Data(contentsOf: projectURL) == saved && reader.frames[0].adjustments.exposure == 0.5,
      "a project opened only to read from, as the command-line export opens it, is left as it was")

    let scanner = HeadScanner()
    let model = AppModel(libraryURL: roll, scanner: scanner)
    model.loadProject(projectURL)
    for _ in 0..<40 where model.rendering { settle(0.1) }
    let canvas = FilmCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = canvas
    canvas.model = model
    model.preferences.showLoupe = false
    settle()
    let upright = model.displayed.map { [$0.width, $0.height] }
    try check(model.contactTurn == 1 && canvas.shown.map { [$0.height, $0.width] } == upright,
      "an upright holder lies across the light table, turned clockwise when no frame is turned")
    let across = canvas.imageRect
    model.preferences.contactLandscape = false
    let along = canvas.imageRect
    model.preferences.contactLandscape = true
    try check(across.width * across.height > along.width * along.height * 1.5,
      String(format: "on a wide canvas it shows %.1f× larger", across.width * across.height / (along.width * along.height)))
    let strip = frames.map { canvas.screen($0.rect.cg) }
    try check(zip(strip, strip.dropFirst()).allSatisfy { $1.maxX < $0.minX + 1 && abs($1.midY - $0.midY) < 1 } && strip[0].width > strip[0].height,
      "and the strip runs across, frame 01 at the right end as on a holder turned clockwise")
    func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    let third = CGPoint(x: strip[2].midX, y: strip[2].midY)
    canvas.mouseDown(with: event(.leftMouseDown, third))
    canvas.mouseUp(with: event(.leftMouseUp, third))
    let back = canvas.normal(third)
    try check(model.selectedID == frames[2].id && frames[2].rect.cg.contains(back),
      "a click on the turned table picks the frame under it")
    for _ in 0..<40 where model.rendering { settle(0.1) }
    // Dragging the frame's (max x, max y) corner, wherever the turn puts it on screen.
    let corner = canvas.corners(frames[2].rect.cg)[3], drop = CGPoint(x: corner.x + 10, y: corner.y - 12)
    canvas.mouseDown(with: event(.leftMouseDown, corner))
    canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: corner.x + 5, y: corner.y - 6)))
    canvas.mouseDragged(with: event(.leftMouseDragged, drop))
    canvas.mouseUp(with: event(.leftMouseUp, drop))
    let before = frames[2].rect, after = model.frames[2].rect, end = canvas.normal(drop)
    try check(abs(after.x - before.x) < 1e-6 && abs(after.y - before.y) < 1e-6
      && abs(after.x + after.width - end.x) < 1e-6 && abs(after.y + after.height - end.y) < 1e-6 && after != before,
      String(format: "dragging a corner moves that corner to the mouse and keeps the opposite one, in the overview: %.3f × %.3f → %.3f × %.3f",
        before.width, before.height, after.width, after.height))
    let perMM = canvas.imageRect.height / 135.5
    try check(abs(canvas.loupeRadius(for: .pentax) - min(110, max(44, CGFloat(LoupeStyle.pentax.baseMM / 2) * perMM))) < 0.5,
      "the loupe keeps the film's scale on the turned table")
    for i in model.frames.indices { model.frames[i].adjustments.rotation = i == 0 ? 1 : 3 }
    try check(model.contactTurn == 3, "turned the way most frames are turned, so they stand upright")
    model.preferences.contactLandscape = false
    try check(model.contactTurn == 0, "and upright again when turned off")
    model.preferences.contactLandscape = true
    model.singleView = true
    try check(model.contactTurn == 0, "single view is never turned")
    model.singleView = false
    for i in model.frames.indices { model.frames[i].adjustments.rotation = 0 }

    // Keys on the canvas.
    func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
      canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)!)
    }
    key("b", code: 11)
    try check(model.tool == .base, "B picks the film base sampler")
    key("z", code: 6, flags: .command)
    try check(model.tool == .base, "but not with ⌘ held, which is undo")
    key("n", code: 45)
    try check(model.tool == .neutral && model.singleView, "N the neutral sampler, on the single frame")
    key("v", code: 9)
    try check(model.tool == .select, "V goes back to selecting")
    model.singleView = false
    key("c", code: 8)
    try check(model.tool == .crop && CanvasTool.allCases.compactMap(\.shortcut).count == 4 && CanvasTool.base.help.hasSuffix("· B"),
      "C too, each named in its button's tooltip")
    let loupeShown = model.preferences.showLoupe
    key("z", code: 6)
    try check(model.preferences.showLoupe != loupeShown && model.tool == .crop, "Z shows or puts away the loupe, whatever the tool")
    key("z", code: 6)
    try check(model.preferences.showLoupe == loupeShown, "and Z again turns it back")
    model.useTool(.select)

    model.select(frames[1].id)
    model.useTool(.it8)
    model.it8Marks = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1)]
    key("\u{7F}", code: 51)
    try check(model.it8Marks.count == 1 && model.frames.count == 4 && model.toolHint?.contains("⌫") == true,
      "delete while marking the IT8 target takes back the last point, not the frame")
    key("\u{7F}", code: 51)
    key("\u{7F}", code: 51)
    try check(model.it8Marks.isEmpty && model.frames.count == 4, "and with no point left it does nothing")
    model.useTool(.calibrate)
    model.calibrationPoints = [
      NeutralPoint(frame: frames[1].id, value: RGB(r: 0.4, g: 0.3, b: 0.2), base: RGB(r: 0.8, g: 0.5, b: 0.3), gamma: 1),
      NeutralPoint(frame: frames[1].id, value: RGB(r: 0.2, g: 0.1, b: 0.05), base: RGB(r: 0.8, g: 0.5, b: 0.3), gamma: 1),
    ]
    key("\u{7F}", code: 51)
    try check(model.calibrationPoints.count == 1 && model.frames.count == 4, "the same while picking neutrals for a preset")
    model.useTool(.select)
    model.singleView = false
    key("\u{7F}", code: 51)
    try check(model.frames.count == 3, "otherwise delete removes the selected frame, as before")

    // The loupe: no strip of its own; shown by its key, it lies on the selected frame.
    model.useTool(.select)
    model.singleView = false
    model.toggleLoupe(false)
    canvas.updateLoupe()
    let whole = canvas.imageRect
    guard let chosen = model.frames.last else { throw DeskError.message("FAIL: no frame to put the loupe on") }
    model.select(chosen.id)
    model.toggleLoupe()
    canvas.updateLoupe()
    settle()
    let home = canvas.screen(chosen.rect.cg), placed = canvas.loupe.center ?? .zero
    try check(!canvas.loupe.isHidden && canvas.imageRect == whole && abs(placed.x - home.midX) < 1 && abs(placed.y - home.midY) < 1,
      "shown, the loupe lies on the selected frame, and the film keeps the whole table")
    model.toggleLoupe()
    canvas.updateLoupe()
    try check(canvas.loupe.isHidden && !model.preferences.showLoupe && canvas.imageRect == whole, "pressed again, it is put away")
    model.preferences.showLoupe = true
    // Panels and bars floating over the canvas: the picture fits between them, centred there.
    let open = NSEdgeInsets(top: 54, left: 240, bottom: 54, right: 270)
    canvas.reserved = open
    let between = canvas.imageRect, size = canvas.bounds.size
    try check(between.minX >= open.left - 0.5 && between.maxX <= size.width - open.right + 0.5
      && between.minY >= open.top - 0.5 && between.maxY <= size.height - open.bottom + 0.5
      && abs(between.midX - (open.left + (size.width - open.left - open.right) / 2)) < 1 && between.width < whole.width,
      "with panels and bars floating over it, the picture fits between them and the table runs underneath")
    canvas.reserved = NSEdgeInsets()
    try check(canvas.imageRect == whole, "and takes the whole canvas again without them")

    // The whole roll turned and mirrored from the contact view, and the table with it.
    let mirroredMark = pipe.turned(marked, quarterTurns: 1, mirrored: true)!
    try check(mark(pipe.turned(marked, quarterTurns: 0, mirrored: true)!) == (3, 2, 2, 0) && mark(mirroredMark) == (2, 3, 0, 0)
      && QuarterTurn(1, mirrored: true).shown(CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 0)
      && (0..<4).allSatisfy { t in let q = QuarterTurn(t, mirrored: true), b = q.overview(q.shown(p)); return abs(b.x - p.x) < 1e-12 && abs(b.y - p.y) < 1e-12 },
      "a mirrored table turns first and then mirrors, as a frame does, in pixels and coordinates alike")
    model.syncOrientation = false
    model.turnRoll(clockwise: false)
    try check(model.frames.allSatisfy { $0.adjustments.rotation == 3 } && model.contactTurn == 3,
      "the contact view's key turns every frame, not only the selected one, and the table follows")
    model.turnRoll(clockwise: true)
    model.turnRoll(clockwise: true)
    model.mirrorRoll()
    try check(model.frames.allSatisfy { $0.adjustments.rotation == 1 && $0.adjustments.flipHorizontal == true }
      && model.contactTurn == 1 && model.contactMirrored && canvas.turn == QuarterTurn(1, mirrored: true),
      "and mirrors the whole roll, the table mirrored with it")
    for _ in 0..<40 where model.rendering { settle(0.1) }
    let mirroredStrip = model.frames.map { canvas.screen($0.rect.cg) }
    let second = CGPoint(x: mirroredStrip[1].midX, y: mirroredStrip[1].midY)
    canvas.mouseDown(with: event(.leftMouseDown, second))
    canvas.mouseUp(with: event(.leftMouseUp, second))
    try check(model.selectedID == model.frames[1].id && zip(mirroredStrip, mirroredStrip.dropFirst()).allSatisfy { $1.minX > $0.maxX - 1 },
      "a mirrored table still picks the frame under the mouse, the strip now reading from the left")
    model.mirrorRoll()
    try check(!model.contactMirrored && model.frames.allSatisfy { $0.adjustments.flipHorizontal == false }, "mirroring again undoes it")

    // The scan head over the frame being scanned.
    for _ in 0..<40 where model.rendering { settle(0.1) }
    model.select(model.frames[1].id)
    for _ in 0..<40 where model.rendering { settle(0.1) }
    model.scanSelected()
    scanner.progress = 0.5
    canvas.updateScanHead()
    settle()
    let scanned = model.frames[1].rect
    func onCanvas(_ y: Double) -> CGPoint { canvas.canvasPoint(overview: CGPoint(x: scanned.x + scanned.width / 2, y: scanned.y + scanned.height * y))! }
    guard let headPose = canvas.scanHead.pose else { throw DeskError.message("FAIL: a scan shows the scan head") }
    let line = headPose.line, middle = CGPoint(x: (line.0.x + line.1.x) / 2, y: (line.0.y + line.1.y) / 2)
    try check(model.scanningFrames.map(\.id) == [model.frames[1].id] && !canvas.scanHead.isHidden
      && hypot(middle.x - onCanvas(0.5).x, middle.y - onCanvas(0.5).y) < 0.5 && headPose.length > canvas.screen(scanned.cg).height,
      "while a frame is scanned the head lies across it, at the line the scanner has reached")
    var lit = 0, lamp = 0
    if let image = canvas.scanHead.image {
      let w = image.width, h = image.height
      var px = [UInt8](repeating: 0, count: w * h * 4)
      let read = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      read.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      for i in 0..<(w * h) where px[i * 4 + 3] > 0 {
        lit += 1
        if px[i * 4] > 235 && px[i * 4 + 1] > 235 && px[i * 4 + 2] > 235 { lamp += 1 }
      }
    }
    try check(lit > 1000 && lamp > 20, "it is rendered with its lamp alight: \(lit) pixels drawn, \(lamp) of them at full brightness")
    scanner.progress = 0.8
    canvas.updateScanHead()
    for _ in 0..<40 where canvas.scanHead.progress < 0.799 { settle(0.05) }
    let later = canvas.scanHead.pose!.line, laterMiddle = CGPoint(x: (later.0.x + later.1.x) / 2, y: (later.0.y + later.1.y) / 2)
    let ahead = (laterMiddle.x - middle.x) * headPose.travel.dx + (laterMiddle.y - middle.y) * headPose.travel.dy
    let reached = onCanvas(canvas.scanHead.progress)
    try check(abs(canvas.scanHead.progress - 0.8) < 0.002 && ahead > 0 && hypot(laterMiddle.x - reached.x, laterMiddle.y - reached.y) < 0.5,
      String(format: "and glides on as the scan goes, %.0f pt further along", ahead))
    model.singleView = true
    model.refresh()
    for _ in 0..<40 where model.rendering { settle(0.1) }
    canvas.scanHead.renderNow()
    let single = canvas.scanHead.pose
    try check(single != nil && single!.length > headPose.length * 1.5 && !canvas.scanHead.isHidden,
      "in single view it passes over the frame shown there, at its size")
    model.singleView = false
    scanner.finish()
    canvas.updateScanHead()
    try check(model.scanningFrames.isEmpty && canvas.scanHead.isHidden && canvas.scanHead.pose == nil, "and goes when the scan ends")
  }
}
