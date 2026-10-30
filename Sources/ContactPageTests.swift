import AppKit
import Foundation

/// The light table's pages: frames of their own files laid out as a contact sheet, 36 to a page,
/// the page following the frame selected, and the film strip's pick for the loupe.
enum ContactPageTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    // A page's layout: six strips of six, in reading order, each frame 3:2 inside the page.
    let full = AppModel.sheetLayout(count: 36, pages: 2)
    let inside = full.cells.allSatisfy { CGRect(origin: .zero, size: full.size).contains($0) }
    let order = zip(full.cells, full.cells.dropFirst()).allSatisfy { a, b in b.minY > a.minY || (b.minY == a.minY && b.minX > a.maxX) }
    let short = AppModel.sheetLayout(count: 4, pages: 2), alone = AppModel.sheetLayout(count: 4, pages: 1)
    try check(full.cells.count == 36 && full.strips.count == 6 && inside && order
      && full.cells.allSatisfy { abs($0.width / $0.height - 1.5) < 0.01 },
      "a contact sheet page holds six strips of six frames, 3:2, in reading order")
    try check(short.size == full.size && short.cells.count == 4 && alone.size.height < full.size.height,
      "every page of a longer roll keeps the full page's size, so turning keeps the scale; a roll of one page is as tall as its strips")

    // A roll of 40 pictures a file each, as a camera or an import brings them.
    let pictures = folder.appendingPathComponent("contact-pages", isDirectory: true)
    try? FileManager.default.removeItem(at: pictures)
    try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
    var urls = [URL]()
    for i in 0..<40 {
      let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: ImagePipeline.shared.outputSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.5, blue: CGFloat(i) / 40, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
      let url = pictures.appendingPathComponent(String(format: "p%02d.png", i))
      try ImagePipeline.shared.savePNG(ctx.makeImage()!, to: url)
      urls.append(url)
    }
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("contact-pages-library"), preferences: Preferences(defaults: defaults))
    model.importURLs(urls)
    model.singleView = false
    try check(model.contactPages == [.sheet(0), .sheet(1)] && model.onSheetPage && model.contactFrames.count == 36,
      "40 pictures a file each lie on two contact sheet pages, 36 on the first")
    let last = model.frames[38]
    model.select(last.id)
    let cell = model.contactRect(last), layout = AppModel.sheetLayout(count: 4, pages: 2)
    try check(model.contactPage == 1 && model.contactFrames.count == 4 && model.contactFrames.contains { $0.id == last.id }
      && abs(cell.x - layout.cells[2].minX / layout.size.width) < 1e-9 && abs(cell.y - layout.cells[2].minY / layout.size.height) < 1e-9,
      "selecting the 39th turns the table to the second page, where it lies third")
    model.showContactPage(5)
    let clamped = model.contactPage == 1
    model.showContactPage(0)
    model.open(model.frames[3].id)
    try check(clamped && model.contactPage == 0 && model.selectedID == model.frames[3].id && model.singleView,
      "the pages turn no further than there are; a pick in the film strip selects it and, with no canvas, shows it on its own at once")
    model.singleView = false

    // On the table: the loupe magnifies a frame of the page, and the pick grows to the middle.
    func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    for _ in 0..<50 where model.displayed == nil || model.rendering { settle(0.1) }
    let canvas = FilmCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = canvas
    canvas.model = model
    // As the App's canvas does when it is made.
    model.frameOpener = { [weak canvas] id in canvas?.open(id) }
    model.viewWillChange = { [weak canvas] change in canvas?.viewWillChange(change) }
    defer {
      model.frameOpener = nil
      model.viewWillChange = nil
    }
    canvas.display()
    model.preferences.showLoupe = true
    canvas.updateLoupe()
    settle(0.3)
    let box = canvas.screen(model.contactRect(model.frames[3]).cg)
    try check(!canvas.loupe.isHidden && (canvas.loupe.magnification ?? 0) > 2 && canvas.loupeField * 2 >= box.width,
      "on a contact sheet page the loupe magnifies, a frame's whole width in its field")
    model.preferences.showLoupe = false
    canvas.updateLoupe()
    let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    try check(still || canvas.rippleCount == 36 && canvas.rippleShare(35) < 1 || canvas.rippleStart == nil && canvas.drawnFrameIDs.count == 40,
      "a new roll's frames come in on the table one after another")
    for _ in 0..<20 where canvas.rippleRunning { settle(0.1) }
    model.showSingle(true)
    let growing = canvas.opening, start = (growing?.picture.animation(forKey: "position") as? CABasicAnimation)?.fromValue as? NSValue
    let middle = CGPoint(x: canvas.openRect.midX, y: canvas.openRect.midY)
    try check(model.singleView && model.selectedID == model.frames[3].id && growing != nil
      && growing.map { abs($0.picture.frame.midX - middle.x) < 1 && abs($0.picture.frame.midY - middle.y) < 1 && $0.picture.frame.width > box.width * 3 } == true
      && (still || start.map { box.contains($0.pointValue) } == true)
      && (still || growing.map { $0.cover.animation(forKey: "transform.scale") != nil && abs($0.cover.frame.width / canvas.bounds.width - $0.picture.frame.width / box.width) < 0.01 } == true),
      "the view switch closes in on the frame selected: the table grows about it as much as it grows, to the middle of the canvas")
    for _ in 0..<50 where model.rendering { settle(0.1) }
    settle(0.8)
    canvas.settleOpening()
    try check(canvas.opening == nil, "once the frame's own picture is here it takes the place of what grew")
    // Turned in single view: the picture as it was turns into the new one.
    let unturned = model.frames[3].adjustments.rotation
    model.turn(clockwise: true)
    let turning = canvas.change
    for _ in 0..<50 where model.rendering { settle(0.1) }
    canvas.settleOpening()
    let spun = canvas.change?.cover.animation(forKey: "transform.rotation.z") != nil
    settle(0.7)
    canvas.settleOpening()
    try check(turning?.hold == true && (still || spun) && canvas.change == nil && model.frames[3].adjustments.rotation == (unturned + 1) % 4,
      "a frame turned in single view turns over into its new picture, the canvas drawing none under it meanwhile")
    model.turn(clockwise: false)
    for _ in 0..<50 where model.rendering { settle(0.1) }
    settle(0.7)
    canvas.settleOpening()
    // Into the crop and out of it.
    model.useTool(.crop)
    let entering = canvas.change
    for _ in 0..<50 where model.rendering { settle(0.1) }
    canvas.settleOpening()
    let settling = canvas.change?.started == true
    settle(0.7)
    canvas.settleOpening()
    model.useTool(.select)
    let leaving = canvas.change
    for _ in 0..<50 where model.rendering { settle(0.1) }
    canvas.settleOpening()
    settle(0.7)
    canvas.settleOpening()
    var enteringKind = false, leavingKind = false
    if case .edit(true, _)? = entering?.kind { enteringKind = true }
    if case .edit(false, _)? = leaving?.kind { leavingKind = true }
    try check(enteringKind && settling && leavingKind && canvas.change == nil && model.tool == .select,
      "into a frame's crop it settles among its surroundings, and out of it the crop grows to fill the view")
    func press(_ key: UInt16) {
      canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)!)
    }
    canvas.display()
    press(124)
    let inSingle = model.selectedID == model.frames[4].id
    let before = model.displayed
    for _ in 0..<50 where model.rendering || model.displayed === before { settle(0.1) }
    canvas.display()
    // A layer keeps its transition under kCATransition, whatever key it was added with.
    let slid = (canvas.layer?.animation(forKey: kCATransition) as? CATransition).map { still ? $0.type == .fade : $0.type == .push && $0.subtype == .fromRight } == true
    try check(slid, "in single view the next frame slides in from the side it lies on")
    // Back to the table: the view draws back from the frame.
    model.showSingle(false)
    let closing = canvas.change
    for _ in 0..<50 where model.rendering { settle(0.1) }
    canvas.settleOpening()
    let drawingBack = canvas.change?.started == true && (still || canvas.change?.layers.first?.animation(forKey: "transform.scale") != nil)
    settle(0.8)
    canvas.settleOpening()
    var closeKind = false
    if case .close? = closing?.kind { closeKind = true }
    try check(closeKind && drawingBack && canvas.change == nil && !model.singleView,
      "back on the light table the view draws back from the frame to the whole page")
    model.select(model.frames[35].id)
    press(124)
    let across = model.selectedID == model.frames[36].id && model.contactPage == 1 && !model.singleView
    press(123)
    try check(inSingle && across && model.selectedID == model.frames[35].id && model.contactPage == 0,
      "← → go to the frame before or after in single view and on the table, where the page turns with it")

    // A preview being read shows on the light table; the single view waits for it.
    model.singleView = true
    let partial = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: ImagePipeline.shared.outputSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    model.scanner.previewSoFar = partial
    let leftSingle = !model.singleView
    model.showSingle(true)
    model.open(model.frames[2].id)
    model.singleView = true
    try check(leftSingle && !model.singleView && canvas.opening == nil && model.previewShowing,
      "while a preview comes in it shows on the light table: the single view can't be entered by its switch, a pick or a tool")
    model.scanner.previewSoFar = nil
    model.showSingle(true)
    try check(model.singleView, "once the preview is read the single view opens again")
    settle(0.8)
    canvas.settleOpening()
    window.contentView = nil
    model.singleView = true
    try check(!model.onSheetPage && model.contactTurn == 0, "the single frame is not a page of the contact sheet")
  }
}
