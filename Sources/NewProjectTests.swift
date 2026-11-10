import AppKit

/// 新建工程: the open roll saved and left in the library, the window emptied, and the next import
/// (or preview, or camera picture) a roll of its own; an unused new project leaves no folder.
enum NewProjectTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let root = folder.appendingPathComponent("new-project", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let library = root.appendingPathComponent("library", isDirectory: true)
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: library, preferences: Preferences(defaults: defaults))
    let ctx = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
    let first = try model.makeSession()
    let decoded = first.appendingPathComponent("Decoded", isDirectory: true)
    try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
    let picture = decoded.appendingPathComponent("EPS00001.tif")
    try ImagePipeline.shared.saveTIFF(ctx.makeImage()!, to: picture, dpi: 300)
    model.addCapturedFrame(picture, original: picture, linear: false)
    model.rollName = "旧卷"
    model.newProject()
    let saved = (try? Data(contentsOf: first.appendingPathComponent(AppModel.projectFile)))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let rolls = { (try? FileManager.default.contentsOfDirectory(atPath: library.path))?.filter { !$0.hasPrefix(".") } ?? [] }
    try check(model.frames.isEmpty && model.sessionURL == nil && model.rollName == "" && model.selectedID == nil
      && (saved?["frames"] as? [Any])?.count == 1 && rolls() == [first.lastPathComponent] && model.status.contains("新建工程"),
      "新建工程 saves the open roll, which stays in the library, empties the window, and makes no folder yet: \(model.status)")
    model.importURLs([picture])
    try check(model.sessionURL != nil && model.sessionURL != first && model.frames.count == 1 && rolls().count == 2,
      "the next import after it is a roll of its own")

    // From the library or the menu, 新建工程 asks first which film the roll is, negative or slide,
    // and its format; the roll open is saved as it was.
    let imported = model.sessionURL!
    let film = FilmProfile.builtins.first { $0.name.contains("400") } ?? FilmProfile.builtins[0]
    model.askNewProject()
    let asked = model.askingNewProject
    model.beginNewProject(profile: film, reversal: false, format: .six6)
    let importedFilm = (try? JSONDecoder().decode(DeskProject.self, from: Data(contentsOf: imported.appendingPathComponent(AppModel.projectFile))))?.filmName
    try check(asked && !model.askingNewProject && model.sessionURL == nil && model.frames.isEmpty
      && model.profile.id == film.id && model.filmName == film.name && model.format == .six6 && !model.reversalRoll
      && importedFilm != nil && importedFilm != film.name,
      "新建工程 asks for the roll's film, negative or slide, and format first, and begins the roll with them, the roll before saved as it was: \(model.status)")
    // A copy's size on the film follows the format: its picture's short side is 120's 56 mm (here
    // the whole of a 96 × 64 picture, so 84 × 56 mm); without one, its long side is 135's 36 mm.
    let copyRoll = try model.makeSession()
    let copies = copyRoll.appendingPathComponent("Decoded", isDirectory: true)
    try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
    let copy = copies.appendingPathComponent("EPS00002.tif")
    try ImagePipeline.shared.saveTIFF(ctx.makeImage()!, to: copy, dpi: 300)
    model.addCapturedFrame(copy, original: copy, linear: false)
    let shot = model.frames[0]
    let six = model.frameMM(shot) ?? .zero
    model.setFormat(.auto)
    let unknown = model.frameMM(shot) ?? .zero
    model.setFormat(.six6)
    var inner = shot
    inner.adjustments.analysisRegion = NormalRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    let framed = model.frameMM(inner) ?? .zero
    try check(abs(six.width - 84) < 0.5 && abs(six.height - 56) < 0.5 && abs(max(unknown.width, unknown.height) - 36) < 0.5
      && abs(framed.height - 70) < 0.5 && model.formatDPI(shot).map { abs($0 - 64 / 56 * 25.4) < 0.1 } == true,
      String(format: "a copy's size on the film follows the roll's format: %.1f × %.1f mm as 6×6, its 去色罩区域 taken as the picture (%.1f mm with the crop round it); %.1f × %.1f mm, 36 mm long, without one",
        six.width, six.height, framed.height, unknown.width, unknown.height))
    // The format is kept with the roll; a roll saved before it was opens as 自动.
    model.saveProject()
    let kept = (try? Data(contentsOf: copyRoll.appendingPathComponent(AppModel.projectFile)))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["format"] as? String
    model.loadProject(first.appendingPathComponent(AppModel.projectFile))
    let older = model.format
    model.loadProject(copyRoll.appendingPathComponent(AppModel.projectFile))
    try check(kept == FilmFormat.six6.rawValue && older == .auto && model.format == .six6,
      "the roll keeps its format and opens with it again; a roll saved before the format was kept opens as 自动")
    // A new roll of slides: its first copy is a slide.
    model.beginNewProject(profile: film, reversal: true, format: .mm135)
    _ = try model.makeSession()
    model.addCapturedFrame(copy, original: copy, linear: false)
    try check(model.frames.first?.adjustments.isSlide == true && model.reversalRoll && model.format == .mm135,
      "a new roll begun as slides takes its first copy as a slide")
  }
}
