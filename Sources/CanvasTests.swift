import AppKit
import Combine
import SwiftUI
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
    // A picture taken of the canvas (what a change of view zooms, what the loupe looks at) has the
    // canvas as it draws now, not what its picture's layer last held: on the way back to the table
    // the layer still held the single frame, large, and the table drew back with it on it (0.19.0).
    let red = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
      space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    red.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    red.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    canvas.pictureLayer.contents = red.makeImage()
    canvas.pictureLayer.frame = canvas.bounds
    canvas.pictureLayer.isHidden = false
    CATransaction.commit()
    // A size not snapshotted before, so the picture is taken now.
    canvas.setFrameSize(NSSize(width: 901, height: 600))
    func reddest(_ image: CGImage?) -> Int {
      guard let image else { return -1 }
      let w = 64, h = max(1, image.height * 64 / max(1, image.width))
      var px = [UInt8](repeating: 0, count: w * h * 4)
      let read = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      read.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return (0..<(w * h)).filter { px[$0 * 4] > 200 && px[$0 * 4 + 1] < 60 && px[$0 * 4 + 2] < 60 }.count
    }
    let staleTaken = reddest(canvas.tableSnapshot())
    let layerShown = !canvas.pictureLayer.isHidden
    canvas.setFrameSize(NSSize(width: 900, height: 600))
    canvas.needsDisplay = true
    canvas.displayIfNeeded()
    try check(staleTaken == 0 && layerShown,
      "a picture taken of the canvas has what it draws now, not what its picture's layer last held (\(staleTaken) red points), and leaves the layer shown")
    func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    let third = CGPoint(x: strip[2].midX, y: strip[2].midY)
    let back = canvas.normal(third)
    canvas.mouseDown(with: event(.leftMouseDown, third))
    canvas.mouseUp(with: event(.leftMouseUp, third))
    try check(model.selectedID == frames[2].id && frames[2].rect.cg.contains(back) && model.singleView,
      "a click on the turned table opens the frame under it")
    model.singleView = false
    for _ in 0..<40 where model.rendering { settle(0.1) }
    // Dragging the frame's (max x, max y) corner, wherever the turn puts it on screen, or the frame.
    let corner = canvas.corners(frames[2].rect.cg)[3], drop = CGPoint(x: corner.x + 10, y: corner.y - 12)
    canvas.mouseDown(with: event(.leftMouseDown, corner))
    canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: corner.x + 5, y: corner.y - 6)))
    canvas.mouseDragged(with: event(.leftMouseDragged, drop))
    canvas.mouseUp(with: event(.leftMouseUp, drop))
    let grip = CGPoint(x: strip[2].midX, y: strip[2].midY), moved = CGPoint(x: grip.x + 30, y: grip.y + 20)
    canvas.mouseDown(with: event(.leftMouseDown, grip))
    canvas.mouseDragged(with: event(.leftMouseDragged, moved))
    canvas.mouseUp(with: event(.leftMouseUp, moved))
    try check(model.frames[2].rect == frames[2].rect && model.selectedID == frames[2].id && !model.singleView,
      "on the light table a frame's box neither resizes by its corner nor moves, and a drag opens nothing: its crop is set on its own")

    // Over the single frame with the crop tool, an edge drags on its own: the right edge 40 points
    // in, the other three where they were.
    let toolBefore = model.tool
    model.singleView = true
    model.useTool(.crop)
    for _ in 0..<40 where model.rendering || model.canvasCrop == nil { settle(0.1) }
    if let before = model.canvasCrop {
      let c = canvas.corners(before.cg), right = CGPoint(x: (c[1].x + c[3].x) / 2, y: (c[1].y + c[3].y) / 2)
      let hold = canvas.cropHold(before.cg, at: CGPoint(x: right.x + 5, y: right.y))
      canvas.mouseDown(with: event(.leftMouseDown, right))
      canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: right.x - 20, y: right.y + 6)))
      canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: right.x - 40, y: right.y + 9)))
      canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: right.x - 40, y: right.y + 9)))
      for _ in 0..<40 where model.rendering { settle(0.1) }
      let after = model.canvasCrop ?? before, shrunk = Double(40 / canvas.imageRect.width)
      try check(hold.edge == 3 && hold.corner == nil && abs(after.x - before.x) < 0.002 && abs(after.y - before.y) < 0.002
        && abs(after.height - before.height) < 0.002 && abs(before.width - after.width - shrunk) < 0.004,
        String(format: "in single view the crop's right edge drags on its own, %.3f narrower, the other edges where they were", before.width - after.width))
    } else {
      try check(false, "the single frame shows a crop to drag")
    }
    model.setRect(frames[2].id, rect: frames[2].rect)
    model.useTool(toolBefore)
    model.singleView = false
    for _ in 0..<40 where model.rendering { settle(0.1) }
    let perMM = canvas.imageRect.height / 135.5
    try check(abs(canvas.loupeRadius(for: .pentax) - min(110, max(44, CGFloat(LoupeStyle.pentax.baseMM / 2) * perMM))) < 0.5,
      "the loupe keeps the film's scale on the turned table")
    canvas.setZoom(3, anchor: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
    try check(model.zoom == 1, "the light table does not zoom: it always shows the whole roll")
    // The table turned to lie across, or back: the loupe goes back on its frame at the new scale.
    model.toggleLoupe(true)
    canvas.updateLoupe()
    model.preferences.contactLandscape = false
    canvas.updateLoupe()
    let selectedBox = model.contactFrames.first { $0.id == model.selectedID }.map { canvas.screen($0.rect.cg) } ?? .zero
    try check(canvas.loupe.center.map { selectedBox.contains($0) } == true && canvas.loupe.center == canvas.loupe.homeCenter,
      "when the table turns upright, the loupe goes back on its frame")
    model.preferences.contactLandscape = true
    canvas.updateLoupe()
    model.toggleLoupe(false)
    canvas.updateLoupe()
    for i in model.frames.indices { model.frames[i].adjustments.rotation = i == 0 ? 1 : 3 }
    try check(model.contactTurn == 3, "turned the way most frames are turned, so they stand upright")
    model.preferences.contactLandscape = false
    try check(model.contactTurn == 0, "and upright again when turned off")
    model.preferences.contactLandscape = true
    model.singleView = true
    try check(model.contactTurn == 0, "single view is never turned")
    model.zoom = 2
    model.singleView = false
    try check(model.zoom == 1, "back on the light table the zoom is undone")
    for i in model.frames.indices { model.frames[i].adjustments.rotation = 0 }

    // Keys on the canvas.
    func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
      canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)!)
    }
    // Capturing has only the frame tools; the pickers belong to taking the mask off.
    model.page = .capture
    key("b", code: 11)
    key("n", code: 45)
    try check(model.tool == .select, "in ① capturing, B and N pick nothing, as its tool bar has no pickers")
    model.page = .convert
    key("b", code: 11)
    try check(model.tool == .base, "B picks the film base sampler")
    key("z", code: 6, flags: .command)
    try check(model.tool == .base, "but not with ⌘ held, which is undo")
    key("n", code: 45)
    try check(model.tool == .neutral && model.singleView, "N the neutral sampler, on the single frame")
    try check(canvas.samplingCursor != nil, "the neutral sampler shows an eyedropper over the picture")
    key("w", code: 13)
    try check(model.tool == .neutral, "W picks no tool: the highlight (Dmax) sampler is gone")
    key("v", code: 9)
    try check(model.tool == .select && canvas.samplingCursor == nil, "V goes back to selecting, and to the arrow")
    model.page = .capture
    model.singleView = false
    key("c", code: 8)
    try check(model.tool == .crop && CanvasTool.allCases.compactMap(\.shortcut).count == 5 && CanvasTool.base.help.hasSuffix("· B"),
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
    try check(model.selectedID == model.frames[1].id && model.singleView && zip(mirroredStrip, mirroredStrip.dropFirst()).allSatisfy { $1.minX > $0.maxX - 1 },
      "a mirrored table still opens the frame under the mouse, the strip now reading from the left")
    model.singleView = false
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

    // Zoomed into a picture larger than the one shown: the part in view at its own resolution,
    // turned as the frame is, and a new part when the view moves.
    let big = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 16, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.linearSRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for i in 0..<60 {
      big.setFillColor(red: Double(i % 3) / 2, green: Double(i % 5) / 4, blue: 0.5, alpha: 1)
      big.fill(CGRect(x: i * 100, y: 0, width: 100, height: 4000))
    }
    let bigURL = folder.appendingPathComponent("zoom-source.tif")
    try pipe.saveTIFF(big.makeImage()!, to: bigURL, dpi: 4000)
    let zoomed = AppModel(libraryURL: folder.appendingPathComponent("zoom-lib"))
    try zoomed.startCameraRoll()
    zoomed.addCapturedFrame(bigURL, original: bigURL, linear: true)
    zoomed.turn(clockwise: true)
    // Graded, in ③: the curves below bend the picture there (② shows it de-masked only).
    zoomed.convertStep = .grade
    zoomed.singleView = true
    zoomed.refresh()
    for _ in 0..<400 where zoomed.rendering { settle(0.05) }
    let zoomCanvas = FilmCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let zoomWindow = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    zoomWindow.contentView = zoomCanvas
    zoomCanvas.model = zoomed
    zoomed.preferences.showLoupe = false
    zoomCanvas.setZoom(16, anchor: CGPoint(x: 450, y: 300))
    // The render queue may still be busy with earlier tests' work: up to half a minute.
    for _ in 0..<600 where zoomCanvas.zoomDetail == nil { zoomCanvas.display(); settle(0.05) }
    let part = zoomCanvas.zoomDetail
    let shownWidth = Double(zoomed.displayed?.width ?? 1)
    // Turned a quarter, the shown picture is 4000 across from the source's 4000 rows.
    let perPart = part.map { Double($0.image.width) / ($0.region.width * 4000) } ?? 0
    try check(zoomed.zoom == 16 && part != nil && shownWidth < 4000 && abs(perPart - 1) < 0.02 && (part?.image.height ?? 0) > (part?.image.width ?? 0) / 4,
      "zoomed in, the part in view is drawn from the frame's own pixels, turned as it is shown: \(part.map { "\($0.image.width) × \($0.image.height)" } ?? "none") for \(shownWidth) shown (analysed \(zoomed.toneAnalysis != nil), single \(zoomed.singleView), rendering \(zoomed.rendering), view \(zoomCanvas.imageRect), \(zoomCanvas.zoomDetailState), loupe \(zoomed.preferences.showLoupe))")
    let first = part?.region
    zoomCanvas.pan.x += 400
    zoomCanvas.needsDisplay = true
    for _ in 0..<600 where zoomCanvas.zoomDetail?.region == first { zoomCanvas.display(); settle(0.05) }
    try check(zoomCanvas.zoomDetail.map { $0.region != first } == true, "moving the view brings the part now in view")
    zoomCanvas.setZoom(1, anchor: CGPoint(x: 450, y: 300))
    zoomCanvas.display()
    try check(zoomCanvas.zoomDetail == nil, "and back at the whole frame it is let go")
    // Zoomed past the picture shown but short of the frame's own pixels: the part has as many as
    // the screen shows, a tenth more, not the frame's own; zoomed further, a finer one.
    let backing = Double(zoomWindow.backingScaleFactor), fitPixels = Double(zoomCanvas.imageRect.width) * backing
    func screenAcross() -> Double { Double(zoomCanvas.imageRect.width) * backing }
    func density(_ d: AppModel.Detail?) -> Double { d.map { Double($0.image.width) / ($0.region.width * screenAcross()) } ?? 0 }
    func waitForPart(_ ok: (AppModel.Detail) -> Bool) {
      for _ in 0..<600 where !(zoomCanvas.zoomDetail.map(ok) ?? false) { zoomCanvas.display(); settle(0.05) }
    }
    let low = 1.2 * shownWidth / fitPixels
    zoomCanvas.setZoom(low, anchor: CGPoint(x: 450, y: 300))
    waitForPart { _ in true }
    let coarse = zoomCanvas.zoomDetail, coarseDensity = density(coarse), coarseAcross = screenAcross()
    zoomCanvas.setZoom(low * 1.3, anchor: CGPoint(x: 450, y: 300))
    waitForPart { $0.scale > (coarse?.scale ?? 1) + 0.01 }
    let finer = zoomCanvas.zoomDetail, finerDensity = density(finer)
    // Finer, up to the frame's own pixels, then as many as it has.
    try check(coarseAcross * 1.1 < 4000 && (coarse?.scale ?? 1) < 0.9 && coarseDensity > 0.98 && coarseDensity < 1.3
      && (finer?.scale ?? 0) > (coarse?.scale ?? 1) * 1.1 && ((finer?.scale ?? 0) >= 0.999 || finerDensity > 0.98 && finerDensity < 1.3),
      "zoomed short of the frame's own pixels, the part in view has as many as the screen shows: scale \(coarse.map { String(format: "%.2f", $0.scale) } ?? "none"), \(String(format: "%.2f", coarseDensity)) a screen pixel, then \(finer.map { String(format: "%.2f", $0.scale) } ?? "none"), \(String(format: "%.2f", finerDensity)) zoomed a third again (fit \(Int(fitPixels)) px, shown \(Int(shownWidth)))")
    zoomCanvas.setZoom(1, anchor: CGPoint(x: 450, y: 300))
    zoomCanvas.display()
    // A pinch's every step and 「适合」 change the canvas alone: nothing is published, so the window
    // is neither updated nor measured again for them, and the zoom's figure follows on its own. The
    // loupe and the scan head are placed by their frames, out of Auto Layout.
    zoomed.zoomChanged = { [weak zoomCanvas] in zoomCanvas?.zoomChanged() }
    var published = 0
    let watch = zoomed.objectWillChange.sink { _ in published += 1 }
    let fitted = zoomCanvas.imageRect
    for k in 1...11 { zoomCanvas.setZoom(1 + Double(k) * 0.3, anchor: CGPoint(x: 600, y: 200)) }
    let pinched = zoomCanvas.imageRect, figure = zoomed.zoomReadout.text, panned = zoomCanvas.pan
    zoomed.fitView()
    watch.cancel()
    try check(published == 0 && pinched.width > fitted.width * 4 && figure == "4.3×" && panned != .zero
      && zoomCanvas.imageRect == fitted && zoomCanvas.pan == .zero && zoomed.zoomReadout.text == "1.0×"
      && !zoomCanvas.loupe.translatesAutoresizingMaskIntoConstraints && !zoomCanvas.scanHead.translatesAutoresizingMaskIntoConstraints,
      "a pinch and 「适合」 change the canvas alone, publishing nothing (\(published) published, \(figure) shown at 4.3×, back to \(zoomCanvas.imageRect) from \(fitted))")
    // A glide zooms about the one point that stays put: the picture's point under the anchor stays
    // under it all the way, the zoom by equal ratios; it lands on the zoom and pan asked for. Near
    // the middle, as the picture kept over the canvas does not move the point there.
    let anchor = CGPoint(x: fitted.midX + 30, y: fitted.midY + 20), underAnchor = zoomCanvas.shownNormal(anchor)
    zoomCanvas.glideZoom(to: 3, about: anchor)
    let landed = (zoom: zoomed.zoom, pan: zoomCanvas.pan, at: zoomCanvas.shownNormal(anchor))
    let glide = ZoomGlide(from: (1, .zero), to: (landed.zoom, landed.pan))
    var drift = 0.0, glideZooms: [Double] = []
    for s in stride(from: 0.0, through: 1.0, by: 0.125) {
      let step = glide.at(s)
      zoomCanvas.place(zoom: step.zoom, pan: step.pan)
      let q = zoomCanvas.shownNormal(anchor)
      drift = max(drift, Double(hypot(q.x - underAnchor.x, q.y - underAnchor.y)))
      glideZooms.append(step.zoom)
    }
    let ratios = zip(glideZooms, glideZooms.dropFirst()).map { $1 / $0 }
    try check(landed.zoom == 3 && hypot(landed.at.x - underAnchor.x, landed.at.y - underAnchor.y) < 1e-3 && drift < 1e-3
      && (ratios.max() ?? 0) - (ratios.min() ?? 0) < 1e-6 && glide.at(1).zoom == 3 && glide.at(1).pan == landed.pan
      && ZoomGlide.progress(0) == 0 && ZoomGlide.progress(0.25) > 0.9 && ZoomGlide.progress(ZoomGlide.settles) == 1,
      "a zoom glides about the point under the pointer, which stays under it (drift \(drift)), by equal ratios, and lands where asked")
    // Zoomed in by a corner, the picture still covers the canvas: it lands no further off the middle
    // than it can be moved.
    zoomCanvas.glideZoom(to: 1, about: nil)
    zoomCanvas.glideZoom(to: 3, about: CGPoint(x: fitted.minX + 4, y: fitted.minY + 4))
    let cornerLimit = zoomCanvas.panLimit(zoom: 3), cornerPan = zoomCanvas.pan
    try check(zoomed.zoom == 3 && abs(cornerPan.x) <= cornerLimit.width + 0.01 && abs(cornerPan.y) <= cornerLimit.height + 0.01 && cornerPan.x > 0,
      "zoomed in by a corner, the picture is kept over the canvas (pan \(cornerPan), at most \(cornerLimit))")
    // 「适合」 from the key glides back; off screen, at once.
    zoomed.glideZoom = { [weak zoomCanvas] zoom, anchor in zoomCanvas?.glideZoom(to: zoom, about: anchor) }
    zoomed.fitView(animated: true)
    try check(zoomed.zoom == 1 && zoomCanvas.pan == .zero && zoomCanvas.imageRect == fitted && zoomCanvas.zoomGlide == nil,
      "「适合」 brings the whole frame back in the middle")
    // A double click on the single frame zooms in about the point and again back out; a double
    // click whose first click opened the frame from the table does not.
    func click(_ p: CGPoint, clicks: Int, at time: TimeInterval) {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let e = NSEvent.mouseEvent(with: type, location: zoomCanvas.convert(p, to: nil), modifierFlags: [], timestamp: time,
          windowNumber: zoomWindow.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        type == .leftMouseDown ? zoomCanvas.mouseDown(with: e) : zoomCanvas.mouseUp(with: e)
      }
    }
    let point = CGPoint(x: fitted.midX - 25, y: fitted.midY - 15), pointAt = zoomCanvas.shownNormal(point)
    click(point, clicks: 2, at: 100)
    let unpaired = zoomed.zoom
    click(point, clicks: 1, at: 200)
    click(point, clicks: 2, at: 200.2)
    let doubled = (zoom: zoomed.zoom, at: zoomCanvas.shownNormal(point))
    click(point, clicks: 1, at: 300)
    click(point, clicks: 2, at: 300.2)
    try check(unpaired == 1 && doubled.zoom == FilmCanvasView.doubleClickZoom && hypot(doubled.at.x - pointAt.x, doubled.at.y - pointAt.y) < 1e-3
      && zoomed.zoom == 1 && zoomCanvas.imageRect == fitted,
      "a double click zooms in \(FilmCanvasView.doubleClickZoom)× about the point and back out to fit; one begun on the table does not (\(unpaired)×)")
    // While a fader is dragged its pictures come at once; a change made at once fades in.
    let undo = UndoManager()
    undo.groupsByEvent = false
    zoomed.undoManager = undo
    zoomed.resetAdjustments()
    let afterReset = zoomed.picturesFade
    zoomed.change("曝光") { $0.exposure += 0.1 }
    zoomed.change("曝光") { $0.exposure += 0.1 }
    let dragged = zoomed.picturesFade
    undo.undo()
    let undone = zoomed.picturesFade
    zoomed.undoManager = nil
    zoomed.cancelPictureFade()
    for _ in 0..<400 where zoomed.rendering { settle(0.05) }
    try check(afterReset && !dragged && undone, "重置 and ⌘Z fade the new picture in; a fader dragged does not (\(afterReset), \(dragged), \(undone))")
    // The zoom's figure keeps its own size in the bars under the picture, however much room they
    // are given: an AppKit view hugs loosely, and stretched, it took the glass bar round it up over
    // half the picture (0.16.0).
    let bars = NSHostingView(rootView: ContentView(m: zoomed).bottomBars(compact: false).frame(width: 1500, height: 900))
    let barWindow = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 1500, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    barWindow.contentView = bars
    bars.layoutSubtreeIfNeeded()
    settle(0.2)
    func zoomFigure(in view: NSView) -> ZoomFigure? {
      if let found = view as? ZoomFigure { return found }
      return view.subviews.lazy.compactMap { zoomFigure(in: $0) }.first
    }
    let barFigure = zoomFigure(in: bars)
    let own: CGSize = barFigure?.intrinsicContentSize ?? .zero, given: CGSize = barFigure?.frame.size ?? .zero
    let keepsOwn = barFigure != nil && abs(given.width - own.width) < 0.5 && abs(given.height - own.height) < 0.5
    try check(keepsOwn,
      "the zoom's figure keeps its own size in the bars under the picture: \(barFigure == nil ? "not shown" : "\(given)") for \(own) (single \(zoomed.singleView), original \(zoomed.showsOriginal))")
    barWindow.contentView = nil

    // The single frame is a layer of its own, which the window server scales and colour-matches on
    // the GPU, where the canvas shows it; a picture taken of the canvas has it drawn in.
    zoomCanvas.needsDisplay = true
    zoomCanvas.display()
    let onLayer = (zoomCanvas.pictureLayer.contents as AnyObject?) === zoomCanvas.shown && !zoomCanvas.pictureLayer.isHidden
      && zoomCanvas.pictureLayer.frame == zoomCanvas.imageRect
    var litOnLayer = 0, looked = 0
    if let rep = zoomCanvas.bitmapImageRepForCachingDisplay(in: zoomCanvas.bounds) {
      zoomCanvas.cacheDisplay(in: zoomCanvas.bounds, to: rep)
      let k = CGFloat(rep.pixelsWide) / zoomCanvas.bounds.width, r = zoomCanvas.imageRect.insetBy(dx: 4, dy: 4)
      for y in stride(from: Int(r.minY * k), to: Int(r.maxY * k), by: 9) {
        for x in stride(from: Int(r.minX * k), to: Int(r.maxX * k), by: 9) {
          looked += 1
          // The plate under the picture is black.
          if let c = rep.colorAt(x: x, y: y), c.redComponent + c.greenComponent + c.blueComponent > 0.05 { litOnLayer += 1 }
        }
      }
    }
    try check(onLayer && looked > 0 && litOnLayer > looked / 2,
      "the single frame is a layer the GPU composites, where the canvas shows it, and a picture taken of the canvas has it drawn in (\(litOnLayer) of \(looked) samples lit)")

    // The curves mark the colour under the pointer as it was before them. Off the picture the mark
    // stays; a curve then bends the picture, which is read again at the same place, and the mark
    // stands where it stood, its dot where the curve now takes it.
    // Where the picture's colour lies furthest from black and white in every channel, so a curve moves it.
    var probe: CGPoint?, probeRoom = -1.0
    if let plate = zoomCanvas.shown {
      let span = zoomCanvas.imageRect.intersection(zoomCanvas.bounds).insetBy(dx: 8, dy: 8)
      for y in stride(from: span.minY, to: span.maxY, by: 23) {
        for x in stride(from: span.minX, to: span.maxX, by: 11) {
          let p = CGPoint(x: x, y: y)
          guard let c = FilmCanvasView.colour(in: plate, at: zoomCanvas.shownNormal(p)) else { continue }
          let room = c.values.map { min($0, 1 - $0) }.min() ?? 0
          if room > probeRoom { (probe, probeRoom) = (p, room) }
        }
      }
    }
    zoomCanvas.hover = probe
    zoomCanvas.readPointer()
    let plainReading = zoomed.curveState.reading
    zoomCanvas.hover = nil
    zoomCanvas.readPointer()
    let kept = zoomed.curveState.reading
    // Black and white lifted and lowered, so even a colour near either end moves.
    var bend = ToneCurves()
    bend.rgb.points = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 0.5, y: 0.4), CurvePoint(x: 1, y: 0.9)]
    let unbent = zoomed.displayed
    zoomed.change("曲线") { $0.curves = bend }
    for _ in 0..<400 where zoomed.displayed === unbent || zoomed.rendering { settle(0.05) }
    zoomCanvas.modelChanged()
    let bentReading = zoomed.curveState.reading
    let bentShown = zoomCanvas.shown.flatMap { plate in probe.flatMap { FilmCanvasView.colour(in: plate, at: zoomCanvas.shownNormal($0)) } }
    let marks = bentReading.map { CurveEditor.pointerMarks($0, curves: bend, channel: 0) } ?? []
    let stood = plainReading.flatMap { p in bentReading.map { b in (0..<3).map { abs(p.input.values[$0] - b.input.values[$0]) }.max() ?? 1 } } ?? 1
    let dotOff = bentShown.map { s in marks.map { abs($0.y - s.values[$0.channel - 1]) }.max() ?? 1 } ?? 1
    let bentBy = plainReading.flatMap { p in bentShown.map { s in (0..<3).map { abs(p.input.values[$0] - s.values[$0]) }.max() ?? 0 } } ?? 0
    try check(probe != nil && plainReading?.over == true && kept?.over == false && kept?.input == plainReading?.input
      && bentReading?.over == false && stood < 0.012 && marks.count == 3 && dotOff < 0.012 && bentBy > 0.03,
      String(format: "the curves mark the colour under the pointer as it was before them, and keep it off the picture through a curve that bent it by %.3f: it moved %.4f, its dots %.4f from the picture", bentBy, stood, dotOff)
        + " (probe \(probe.map { "\($0)" } ?? "none") room \(String(format: "%.2f", probeRoom)), read \(plainReading.map { "\($0.input)" } ?? "nil"), kept \(kept?.over.description ?? "nil"), bent \(bentReading.map { "\($0.input) over \($0.over)" } ?? "nil"), shown \(bentShown.map { "\($0)" } ?? "nil"), single \(zoomed.singleView), tool \(zoomed.tool), rect \(zoomCanvas.imageRect))")
    // The targeted adjustment on the picture: down at the probe lowers the RGB curve where the colour
    // there lies, on the curves the frame keeps.
    let bentFirst = zoomed.displayed
    zoomed.change("曲线") { $0.curves = nil }
    for _ in 0..<400 where zoomed.displayed === bentFirst || zoomed.rendering { settle(0.05) }
    zoomed.tool = .curve
    zoomed.curveState.parametric = false
    zoomed.curveState.channel = 0
    if let probe {
      zoomCanvas.beginCurveTarget(at: probe)
      zoomCanvas.dragCurveTarget(to: CGPoint(x: probe.x, y: probe.y + 30))
      zoomCanvas.dragCurveTarget(to: CGPoint(x: probe.x, y: probe.y + 60))
    }
    let targeted = zoomed.settings.curves?.rgb.points ?? []
    let lifted = targeted.count == 3 ? targeted[1].y - targeted[1].x : 0
    zoomed.tool = .select
    try check(targeted.count == 3 && abs(lifted + 0.2) < 0.01,
      "the targeted adjustment on the picture lowers the RGB curve where the colour under it lies: a point at \(targeted.count == 3 ? String(format: "%.3f → %.3f", targeted[1].x, targeted[1].y) : "none") for 60 points down")
    // Left off for a while, the curves leave the picture shown, not the frame's settings or its film-strip copy.
    for _ in 0..<400 where zoomed.rendering { settle(0.05) }
    let stripCopy = zoomed.selected.flatMap { zoomed.thumbnails[$0.id] }
    let withCurves = zoomed.displayed
    zoomed.curvesBypassed = true
    for _ in 0..<400 where zoomed.displayed === withCurves || zoomed.rendering { settle(0.05) }
    let plainAgain = zoomed.displayed.flatMap { plate in probe.flatMap { FilmCanvasView.colour(in: plate, at: zoomCanvas.shownNormal($0)) } }
    let offBy = plainReading.flatMap { p in plainAgain.map { a in (0..<3).map { abs(p.input.values[$0] - a.values[$0]) }.max() ?? 1 } } ?? 1
    let keptSettings = zoomed.settings.curves != nil, keptCopy = zoomed.selected.flatMap { zoomed.thumbnails[$0.id] } === stripCopy
    zoomed.curvesBypassed = false
    for _ in 0..<400 where zoomed.rendering { settle(0.05) }
    try check(offBy < 0.02 && keptSettings && keptCopy && zoomed.shownCurves != nil,
      String(format: "left off for a while, the curves leave the picture as it was without them (%.4f off), and the frame's curves and film-strip copy as they were", offBy))
    let bentPicture2 = zoomed.displayed
    zoomed.change("曲线") { $0.curves = nil }
    for _ in 0..<400 where zoomed.displayed === bentPicture2 || zoomed.rendering { settle(0.05) }
    let bentPicture = zoomed.displayed
    zoomed.change("曲线") { $0.curves = nil }
    for _ in 0..<400 where zoomed.displayed === bentPicture || zoomed.rendering { settle(0.05) }
    zoomed.selectedID = nil
    let cleared = zoomed.curveState.reading == nil
    zoomed.selectedID = zoomed.frames.first?.id
    for _ in 0..<400 where zoomed.rendering { settle(0.05) }
    try check(cleared, "another frame clears the curves' mark")

    // A row with a full and a compact layout keeps the one shown, with its controls, through the
    // window's updates; it changes as its room does. ViewThatFits, laid out again at the window's
    // smallest for its minimum size, took the compact one and then the full one again at every update,
    // and built their controls anew: under the single frame a dozen buttons and two segmented controls
    // at each slider step.
    final class Steps: ObservableObject { @Published var n = 0 }
    struct Row: View {
      @ObservedObject var steps: Steps
      var body: some View {
        WidthFit {
          HStack {
            Picker("", selection: .constant(0)) { Text("完整").tag(0); Text("甲").tag(1) }.pickerStyle(.segmented).frame(width: 120)
            Text(String(repeating: "步", count: 20 + steps.n))
          }
        } compact: {
          Picker("", selection: .constant(0)) { Text("紧凑").tag(0); Text("乙").tag(1) }.pickerStyle(.segmented).frame(width: 120)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    let steps = Steps()
    let rowHost = NSHostingView(rootView: Row(steps: steps).windowMinimum(width: 200, height: 40))
    rowHost.sizingOptions = [.minSize]
    let rowWindow = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 800, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
    rowWindow.contentView = rowHost
    func laidOut() { for _ in 0..<3 { rowHost.layoutSubtreeIfNeeded(); settle(0.05) } }
    func switches(_ v: NSView) -> [NSSegmentedControl] { ((v as? NSSegmentedControl).map { [$0] } ?? []) + v.subviews.flatMap { switches($0) } }
    func shown() -> [String] { switches(rowHost).map { $0.label(forSegment: 0) ?? "" } }
    laidOut()
    let fullKey = switches(rowHost).first { $0.label(forSegment: 0) == "完整" }
    for k in 1...5 {
      steps.n = k
      laidOut()
    }
    let stillKey = switches(rowHost).first { $0.label(forSegment: 0) == "完整" }
    rowWindow.setContentSize(NSSize(width: 260, height: 60))
    laidOut()
    let narrow = shown()
    rowWindow.setContentSize(NSSize(width: 800, height: 60))
    laidOut()
    let wide = shown()
    try check(fullKey != nil && fullKey === stillKey && narrow == ["紧凑"] && wide == ["完整"],
      "a row's full layout keeps its controls through the window's updates, the compact one takes its place when narrow and gives it back when wide (\(narrow), \(wide), kept \(fullKey != nil && fullKey === stillKey))")
    rowWindow.contentView = nil
  }
}
