import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The window shots in doc/images, taken from the app's own views: `Screenshots <images folder>`.
/// Tools/screenshots.sh builds it from Sources (all but EpsonScanPlus.swift, whose app it replaces);
/// .githooks/pre-push runs that before main goes to GitHub.
///
/// - The pictures are one roll of the user's library, opened read-only, with the user's
///   preferences copied into a scratch suite and the layout ones pinned: nothing in the library,
///   its caches or the app's settings changes, and every run lays the window out the same way.
/// - The window server draws the window: two points of it are on screen, the rest past the right
///   edge, behind every other window and deaf to the mouse, and `screencapture -l` takes it. With
///   the screen locked, or without the screen-recording permission, there is no picture and the
///   run fails.
/// - A shot that looks like the file already there (a mean difference under 1/255) leaves that
///   file as it is, so a rebuild does not rewrite every JPEG.
/// - The close-ups (the scan head, the loupes, the crop glass) are drawn by hand and not taken here.
/// - The README's features each have a picture: the film shelf, ① with the scanner, a copy roll's
///   light table, the two crops, dust, the curves and the shortcuts, cut from the window where only
///   a part of it says what the feature is. The copy roll is the user's Phoenix 6×6 roll.
final class ShotWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
  override var canBecomeKey: Bool { true }
}

struct ShotFailure: Error { let message: String }

@main enum Screenshots {
  static let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures/epscan")
  /// The roll the window shows: Harman Phoenix II 200 in 6×6, copied on the A7R IV: bridges, hills
  /// and sky. No roll with people in it is shown anywhere (the user keeps those out of the README):
  /// not the sea roll the V850 scanned, nor the cross-processed Portra.
  static let roll = "2026-11-07_132152_9EA1"
  /// Its frame on the light table under the loupe, in the single view and on the leak page.
  static let frame = "06"
  /// The library's sleeves: the copy rolls with no people in them (Phoenix 6×6, Portra 160 and
  /// Ektar frames of lakes, bridges, signs and test charts), so the films on their labels differ.
  static let shelf = [
    "2026-11-07_132152_9EA1", "2026-11-07_125356_8778", "2026-10-30_194132_3146", "2026-10-30_091410_A34F",
    "2026-10-28_220205_CF4A", "2026-10-31_220844_7A73", "2026-10-28_203123_8045",
  ]
  /// A copy roll from the A7R IV: Harman Phoenix II 200 in 6×6, with dust found on its first frame.
  static let copyRoll = "2026-11-07_132152_9EA1"
  static let size = NSSize(width: 1440, height: 920)

  static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

  static func main() {
    let args = CommandLine.arguments
    guard args.count > 1 else {
      print("用法：Screenshots <doc/images 文件夹>")
      exit(64)
    }
    do {
      let changed = try run(URL(fileURLWithPath: args[1]))
      print(changed.isEmpty ? "截图和上次的一样" : "更新了：" + changed.joined(separator: " "))
      exit(0)
    } catch {
      let text = (error as? ShotFailure)?.message ?? "\(error)"
      FileHandle.standardError.write(Data((text + "\n").utf8))
      exit(1)
    }
  }

  static func run(_ out: URL) throws -> [String] {
    let files = FileManager.default
    let rollURL = library.appendingPathComponent(roll)
    guard files.fileExists(atPath: rollURL.appendingPathComponent(AppModel.projectFile).path) else {
      throw ShotFailure(message: "找不到截图用的那一卷：\(rollURL.path)")
    }
    let work = files.temporaryDirectory.appendingPathComponent("epscan-shots-\(getpid())")
    try files.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: work) }

    // The library shown: a folder of its own whose rolls are folders of links to the real ones'
    // files, and a cache of their positives copied from the app's.
    let shelfURL = work.appendingPathComponent("library")
    let cache = work.appendingPathComponent("cache")
    var shelved = [(real: URL, shown: URL)]()
    for name in shelf {
      let real = library.appendingPathComponent(name), shown = shelfURL.appendingPathComponent(name)
      guard let items = try? files.contentsOfDirectory(atPath: real.path) else { continue }
      try files.createDirectory(at: shown, withIntermediateDirectories: true)
      for item in items where !item.hasPrefix(".") {
        try files.createSymbolicLink(at: shown.appendingPathComponent(item), withDestinationURL: real.appendingPathComponent(item))
      }
      shelved.append((real, shown))
    }
    let realCaches = shelved.map { RollLibrary.cacheFolder(for: $0.real) }
    RollLibrary.cacheRoot = cache
    for (i, roll) in shelved.enumerated() where files.fileExists(atPath: realCaches[i].path) {
      try? files.createDirectory(at: cache, withIntermediateDirectories: true)
      try? files.copyItem(at: realCaches[i], to: RollLibrary.cacheFolder(for: roll.shown))
    }

    // The user's settings, copied; the window's own laid out as a new install has them.
    let suite = "local.epscan.screenshots"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.setPersistentDomain(UserDefaults.standard.persistentDomain(forName: "local.epscan.mac") ?? [:], forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    // The scanner set for colour negatives, as a new install has it, whatever the user scanned last.
    for key in ["leftWidth", "rightWidth", "loupeStyle", "loupeField", "contactLandscape", "loupeShown", "scanReversal"] {
      defaults.removeObject(forKey: key)
    }
    // The views' own switches live in this tool's standard defaults; set here, removed after.
    let standard = UserDefaults.standard
    let switches: [String: Bool] = ["convertSidebarShown": false, "libraryStacks": false]
    for (key, value) in switches { standard.set(value, forKey: key) }
    defer { for key in switches.keys { standard.removeObject(forKey: key) } }

    // Never the saved OpenAI key: this tool is a stranger to its keychain item, so macOS would ask,
    // and the push would wait on the dialog. A service of its own holds nothing.
    LeakKeychain.defaultService = "local.epscan.screenshots.\(UUID().uuidString)"
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .darkAqua)
    let model = AppModel(libraryURL: library, preferences: Preferences(defaults: defaults))
    model.readOnly = true

    let host = NSHostingController(rootView: ContentView(m: model))
    host.sceneBridgingOptions = [.toolbars, .title]
    let window = ShotWindow(contentViewController: host)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.title = "Epson Scan plus"
    window.appearance = NSAppearance(named: .darkAqua)
    window.setContentSize(size)
    let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 2560, height: 1440)
    window.setFrameOrigin(NSPoint(x: screen.maxX - 2, y: screen.minY))
    window.ignoresMouseEvents = true
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    window.orderFront(nil)
    pump(1.5)

    func settle(_ extra: Double = 1.2) {
      pump(0.6)
      var waited = 0.0
      while (model.rendering || model.leak.busy != nil) && waited < 40 {
        pump(0.25)
        waited += 0.25
      }
      pump(extra)
    }
    func select(_ name: String) {
      if let f = model.frames.first(where: { $0.name == name }) { model.select(f.id) }
    }
    /// The status line shown again, as it is for a few seconds after each change.
    func freshStatus() {
      let text = model.status
      model.status = ""
      pump(0.05)
      model.status = text
      pump(0.4)
    }
    /// The inspector's sections opened or folded for a shot (their own switches, in this tool's
    /// standard defaults), and put back after.
    func sections(_ open: [String: Bool]) -> () -> Void {
      let was = open.keys.map { ($0, standard.object(forKey: "panelSection." + $0)) }
      for (key, on) in open { standard.set(on, forKey: "panelSection." + key) }
      return { for (key, value) in was { if let value { standard.set(value, forKey: "panelSection." + key) } else { standard.removeObject(forKey: "panelSection." + key) } } }
    }
    /// The middle of the window and the inspector beside it, below the window's own buttons.
    func workArea(_ c: Picture.Columns) -> CGRect {
      let right = c.inspector?.maxX ?? c.middle.maxX
      return CGRect(x: c.middle.minX, y: 46, width: right - c.middle.minX, height: c.middle.height - 46)
    }
    var changed = [String]()
    func save(_ image: CGImage, _ name: String, width: Int) throws {
      if try Picture.save(image, to: out.appendingPathComponent(name), width: width) { changed.append(name) }
    }

    model.preferences.contactLandscape = true
    model.preferences.showLoupe = false

    // ① capture, with the scanner, for a new roll: its left panel and the empty light table with
    // the preview's key. The only rolls the scanner made are the sea roll's, whose frames show the
    // user. Nothing is saved (`readOnly`), and a new project makes no folder before its first preview.
    model.startNewProject()
    model.page = .capture
    model.captureSource = .scanner
    model.showSingle(false)
    settle()
    let capturePanel = try Picture.capture(window, work: work)
    let captureColumns = Picture.columns(window)
    try save(capturePanel, "capture.jpg", width: 1600)

    model.loadProject(rollURL.appendingPathComponent(AppModel.projectFile))
    guard !model.frames.isEmpty else { throw ShotFailure(message: "截图用的那一卷打不开：\(rollURL.path)") }

    // ② taking the mask off: the light table, the loupe on the frame; the light table cut out.
    model.page = .convert
    model.panelTab = .calibration
    settle(3)
    // Every frame converted, not the first few over black cells.
    var converting = 0.0
    while (model.positivesLoading != nil || model.frames.contains { model.thumbnails[$0.id] == nil }) && converting < 120 {
      pump(0.5)
      converting += 0.5
    }
    settle(2)
    select(frame)
    model.toggleLoupe(true)
    settle(2)
    freshStatus()
    let main = try Picture.capture(window, work: work)
    try save(main, "main-window.jpg", width: 1600)
    if let cut = Picture.crop(main, to: workArea(Picture.columns(window)), window: window) { try save(cut, "loupe.jpg", width: 1400) }

    // The same with the left panel open, the areas numbered.
    standard.set(true, forKey: "convertSidebarShown")
    settle(1.5)
    freshStatus()
    let whole = try Picture.capture(window, work: work)
    let columns = Picture.columns(window)
    try save(Picture.numbered(whole, window: window, columns: columns), "main-annotated.jpg", width: 2000)

    // The left panel's pages, side by side: ① V850, ② 预设标定, ② 输出.
    model.panelTab = .output
    settle()
    let outputPanel = try Picture.capture(window, work: work)
    // Each from below the window's buttons.
    func panel(_ rect: CGRect?) -> CGRect? { rect.map { CGRect(x: $0.minX, y: 46, width: $0.width, height: $0.maxY - 46) } }
    let panels = [
      Picture.crop(capturePanel, to: panel(captureColumns.sidebar), window: window),
      Picture.crop(whole, to: panel(columns.sidebar), window: window),
      Picture.crop(outputPanel, to: panel(Picture.columns(window).sidebar), window: window),
    ].compactMap { $0 }
    if panels.count == 3, let row = Picture.sideBySide(panels) { try save(row, "panels.jpg", width: 1600) }
    standard.set(false, forKey: "convertSidebarShown")
    model.panelTab = .calibration

    // The single view, the same frame.
    model.toggleLoupe(false)
    model.showSingle(true)
    settle(2)
    try save(try Picture.capture(window, work: work), "single-view.jpg", width: 1600)

    // The curves open over the frame's histograms, the sections above them folded.
    let curvesBack = sections(["balance": false, "tone": false, "levels": false, "colour": false, "dust": false, "curves": true])
    let keptCurves = model.settings.curves
    let medium = CurveEditor.presets.first { $0.name == "中对比" }?.levels ?? []
    model.change("曲线") { $0.curves = ToneCurves(rgb: CurveEditor.preset(medium)) }
    settle(2)
    let curves = try Picture.capture(window, work: work)
    if let cut = Picture.crop(curves, to: workArea(Picture.columns(window)), window: window) { try save(cut, "curves.jpg", width: 1400) }
    model.change("曲线") { $0.curves = keptCurves }
    curvesBack()
    settle()

    // The keys, in their sheet.
    model.showShortcuts = true
    settle(1.5)
    if let sheet = window.attachedSheet { try save(try Picture.capture(sheet, work: work), "shortcuts.jpg", width: 1400) }
    model.showShortcuts = false
    settle()
    model.showSingle(false)
    settle()

    // A copy roll: its light table, the two crops on a frame, and the dust found on another.
    let copyURL = library.appendingPathComponent(copyRoll).appendingPathComponent(AppModel.projectFile)
    if files.fileExists(atPath: copyURL.path) {
      model.loadProject(copyURL)
      model.page = .convert
      settle(3)
      // Every frame converted, not the first few over black cells.
      var waited = 0.0
      while model.positivesLoading != nil && waited < 120 { pump(0.5); waited += 0.5 }
      settle(2)
      try save(try Picture.capture(window, work: work), "copy-table.jpg", width: 1600)
      select("03")
      model.showSingle(true)
      settle(2)
      model.preferences.showDustMarks = false
      model.tool = .region
      settle(1.5)
      let region = try Picture.capture(window, work: work)
      if let cut = Picture.crop(region, to: workArea(Picture.columns(window)), window: window) { try save(cut, "crop-region.jpg", width: 1400) }
      model.tool = .select
      model.preferences.showDustMarks = true
      let dustBack = sections(["balance": false, "tone": false, "levels": false, "colour": false, "dust": true])
      select("01")
      settle(3)
      let dust = try Picture.capture(window, work: work)
      if let cut = Picture.crop(dust, to: workArea(Picture.columns(window)), window: window) { try save(cut, "dust.jpg", width: 1400) }
      dustBack()
      model.showSingle(false)
      // Back to the window's roll for the library and the leak page.
      model.loadProject(rollURL.appendingPathComponent(AppModel.projectFile))
      model.page = .convert
      settle(2)
    }

    // The library, the window's first tab, of the shelf's rolls only; the library, the module and
    // the status line put back after.
    let status = model.status
    model.setLibrary(shelfURL)
    model.page = .library
    settle(3)
    guard model.page == .library else { throw ShotFailure(message: "库没有打开") }
    try save(try Picture.capture(window, work: work), "library.jpg", width: 1600)
    // 新建工程's film shelf, over the library.
    let keptProfiles = model.profiles
    model.profiles = FilmProfile.builtins
    model.askNewProject()
    settle(3)
    // Its top, as wide against as high as the window's shots beside it in the README: the search,
    // the recent films, the first maker's shelf and the film chosen.
    if let sheet = window.attachedSheet {
      let shelf = try Picture.capture(sheet, work: work)
      let top = CGRect(x: 0, y: 0, width: shelf.width, height: min(shelf.height, Int(Double(shelf.width) / 1.57)))
      try save(shelf.cropping(to: top) ?? shelf, "shelf.jpg", width: 1400)
    }
    model.askingNewProject = false
    model.profiles = keptProfiles
    settle()
    model.page = .convert
    model.setLibrary(library)
    model.status = status
    settle()

    // Last, and never left: leaving the 去漏光 page saves its job into Application Support.
    select(frame)
    if let id = model.selectedID { model.openInLeak(id) }
    settle(4)
    try save(try Picture.capture(window, work: work), "leak-page.jpg", width: 1600)
    window.orderOut(nil)
    return changed
  }
}

/// Taking, cutting, numbering and saving the window's pictures.
enum Picture {
  /// The window as the window server draws it, without its shadow.
  static func capture(_ window: NSWindow, work: URL) throws -> CGImage {
    // A sheet is drawn inside its window (macOS 27): `screencapture -l` of the sheet gives the
    // whole window, so the sheet is cut from the window's picture where it lies.
    if let parent = window.sheetParent {
      let whole = try capture(parent, work: work)
      let k = parent.backingScaleFactor, f = window.frame, p = parent.frame
      // Screen points, from the bottom left, to the picture's pixels, from the top left.
      let rect = CGRect(x: (f.minX - p.minX) * k, y: (p.maxY - f.maxY) * k, width: f.width * k, height: f.height * k)
        .integral.intersection(CGRect(x: 0, y: 0, width: whole.width, height: whole.height))
      guard rect.width >= f.width * k - 4, let sheet = whole.cropping(to: rect) else {
        throw ShotFailure(message: "截不到面板：\(Int(f.width))×\(Int(f.height)) pt 的面板不在窗口的截图里。")
      }
      return sheet
    }
    let url = work.appendingPathComponent("window-\(window.windowNumber)-\(UUID().uuidString).png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
    try task.run()
    task.waitUntilExit()
    let expected = window.frame.width * window.backingScaleFactor
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      abs(CGFloat(image.width) - expected) < 4
    else {
      throw ShotFailure(message: "截不到窗口：屏幕锁着，或者运行它的程序（终端或 Claude）没有「屏幕录制」权限。")
    }
    return image
  }

  /// The window's columns, in points from its top left: the sidebar, the middle and the inspector.
  struct Columns {
    var sidebar: CGRect?
    var middle: CGRect
    var inspector: CGRect?
    /// The loupe on the light table, where it is shown.
    var loupe: CGRect?
  }
  static func columns(_ window: NSWindow) -> Columns {
    let height = window.frame.height
    func flipped(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }
    var found = [CGRect]()
    var loupe: CGRect?
    func walk(_ view: NSView) {
      if view is LoupeView, !view.isHiddenOrHasHiddenAncestor, view.frame.width > 1 {
        loupe = flipped(view.convert(view.bounds, to: nil))
      }
      if let split = view as? NSSplitView, split.isVertical {
        for item in split.arrangedSubviews where !item.isHidden && item.frame.width > 1 {
          found.append(flipped(item.convert(item.bounds, to: nil)))
        }
      }
      view.subviews.forEach(walk)
    }
    if let root = window.contentView?.superview { walk(root) }
    // Nested splits list the outer items and the inner ones; keep the narrowest covering each x.
    let full = CGRect(x: 0, y: 0, width: window.frame.width, height: height)
    let sidebar = found.filter { $0.minX < 2 && $0.width < full.width * 0.4 }.min { $0.width < $1.width }
    let inspector = found.filter { abs($0.maxX - full.width) < 2 && $0.width < full.width * 0.4 }.min { $0.width < $1.width }
    let left = sidebar?.maxX ?? 0, right = inspector?.minX ?? full.width
    return Columns(
      sidebar: sidebar, middle: CGRect(x: left, y: 0, width: right - left, height: height), inspector: inspector, loupe: loupe)
  }

  static func crop(_ image: CGImage, to rect: CGRect?, window: NSWindow) -> CGImage? {
    guard let rect else { return nil }
    let s = CGFloat(image.width) / window.frame.width
    return image.cropping(to: CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s).integral)
  }

  static func context(_ width: Int, _ height: Int) -> CGContext? {
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  }

  /// Pictures in a row on the window's dark grey, a gap between them.
  static func sideBySide(_ images: [CGImage]) -> CGImage? {
    let gap = 24, height = images.map(\.height).max() ?? 0
    let width = images.map(\.width).reduce(0, +) + gap * (images.count + 1)
    guard let ctx = context(width, height + 2 * gap) else { return nil }
    ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height + 2 * gap))
    var x = gap
    for image in images {
      ctx.draw(image, in: CGRect(x: x, y: gap + height - image.height, width: image.width, height: image.height))
      x += image.width + gap
    }
    return ctx.makeImage()
  }

  /// The areas the interface guide numbers, marked where they are in this layout.
  static func numbered(_ image: CGImage, window: NSWindow, columns c: Columns) -> CGImage {
    let w = window.frame.width, h = window.frame.height, s = CGFloat(image.width) / w
    let side = c.sidebar ?? CGRect(x: 0, y: 0, width: 0, height: h)
    let mid = c.middle
    let ins = c.inspector ?? CGRect(x: w, y: 0, width: 0, height: h)
    // The loupe's mark on its rim, up and to the right; without a loupe, none.
    let loupe = c.loupe.map { r in CGPoint(x: r.midX + r.width * 0.36, y: r.midY - r.height * 0.36) }
    let marks: [(Int, CGPoint)] = [
      (1, CGPoint(x: mid.maxX - 120, y: 26)),
      (2, CGPoint(x: side.midX + side.width * 0.25, y: 120)),
      (3, CGPoint(x: mid.midX, y: 89)),
      (4, CGPoint(x: mid.minX + mid.width * 0.62, y: mid.minY + (h - 170) * 0.40)),
      (6, CGPoint(x: ins.midX + ins.width * 0.1, y: 120)),
      (7, CGPoint(x: mid.minX + mid.width * 0.5, y: h - 66)),
      (8, CGPoint(x: mid.minX + mid.width * 0.5, y: h - 14)),
      (9, CGPoint(x: mid.maxX - 85, y: h - 217)),
    ] + (loupe.map { [(5, $0)] } ?? [])
    guard let ctx = context(image.width, image.height) else { return image }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.translateBy(x: 0, y: CGFloat(image.height))
    ctx.scaleBy(x: s, y: -s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    let font = NSFont.systemFont(ofSize: 17, weight: .bold)
    for (n, p) in marks {
      let r: CGFloat = 16
      let disc = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
      ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: CGColor(gray: 0, alpha: 0.5))
      ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.69, blue: 0.20, alpha: 1))
      ctx.fillEllipse(in: disc)
      ctx.setShadow(offset: .zero, blur: 0, color: nil)
      ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
      ctx.setLineWidth(2)
      ctx.strokeEllipse(in: disc.insetBy(dx: 1, dy: 1))
      let text = NSAttributedString(string: "\(n)", attributes: [.font: font, .foregroundColor: NSColor(white: 0.08, alpha: 1)])
      let size = text.size()
      text.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2))
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage() ?? image
  }

  static func scaled(_ image: CGImage, width: Int) -> CGImage? {
    let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
    guard let ctx = context(width, height) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
  }

  /// The mean difference of two pictures of one size, 0–255, read at a quarter of the size.
  static func difference(_ a: CGImage, _ b: CGImage) -> Double {
    let w = max(1, a.width / 4), h = max(1, a.height / 4)
    func pixels(_ image: CGImage) -> [UInt8] {
      var data = [UInt8](repeating: 0, count: w * h * 4)
      data.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
          data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      }
      return data
    }
    let pa = pixels(a), pb = pixels(b)
    var sum = 0
    for i in 0..<pa.count where i % 4 != 3 { sum += abs(Int(pa[i]) - Int(pb[i])) }
    return Double(sum) / Double(w * h * 3)
  }

  /// Writes `image` as a JPEG `width` pixels wide, unless the file there already looks the same.
  /// True when it wrote.
  static func save(_ image: CGImage, to url: URL, width: Int) throws -> Bool {
    guard let small = scaled(image, width: min(width, image.width)) else { throw ShotFailure(message: "缩小不了 \(url.lastPathComponent)") }
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let old = CGImageSourceCreateImageAtIndex(source, 0, nil),
      old.width == small.width, old.height == small.height, difference(old, small) < 1
    {
      return false
    }
    guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw ShotFailure(message: "写不了 \(url.path)")
    }
    CGImageDestinationAddImage(out, small, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(out) else { throw ShotFailure(message: "写不了 \(url.path)") }
    return true
  }
}
