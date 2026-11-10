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

    // The sheet's films: the catalog is sound, and found by any word of what one calls a film.
    let stocks = FilmCatalog.stocks
    try check(stocks.count >= 80 && Set(stocks.map(\.id)).count == stocks.count
      && stocks.allSatisfy { $0.iso > 0 && !$0.gauges.isEmpty && !$0.note.isEmpty }
      && stocks.compactMap(\.preset).allSatisfy { id in FilmProfile.builtins.contains { $0.id == id } },
      "the catalog's \(stocks.count) films each have a speed, a gauge and a note, no two the same, and the presets they name are built in")
    func names(_ q: String) -> [String] { FilmCatalog.search(q).map(\.name) }
    let portra = names("portra 400"), fujiSlides = FilmCatalog.search("富士 正片"), speed = names("400"), bw120 = FilmCatalog.search("黑白 120")
    try check(portra.first == "Kodak Portra 400" && portra.contains("Kodak Ektacolor Pro 400")
      && !fujiSlides.isEmpty && fujiSlides.allSatisfy { $0.maker == "Fujifilm" && $0.kind == .slide } && fujiSlides.count == 3
      && speed.contains("Ilford HP5 Plus 400") && !speed.contains("Ilford Delta 3200") && names("320") == ["Foma Retropan 320 Soft"]
      && !bw120.isEmpty && bw120.allSatisfy { $0.kind == .blackWhite && $0.gauges.contains(.mm120) }
      && names("柯达 电影").allSatisfy { $0.hasPrefix("Kodak") } && names("柯达 电影").count == 5
      && names("hp5") == ["Ilford HP5 Plus 400"] && names("aerocolor").isEmpty,
      "the films are found by any word: 「portra 400」 puts Portra 400 first and finds its new name, 「富士 正片」 the three Fujifilm slides, 「400」 a speed whole (not Delta 3200), 「黑白 120」 black and white in 120, 「柯达 电影」 Kodak's cine films")
    try check(FilmCatalog.stock(named: "Kodak Portra 160 · 翻拍 · 2026-11-07 13:21")?.name == "Kodak Portra 160"
      && FilmCatalog.stock(named: "Kodak Ektar 100")?.preset == "ektar100" && FilmCatalog.stock(named: "Agfa Ultra 50") == nil,
      "a roll's film or a calibration made from it is found in the catalog, so the sheet starts on it")
    // A stock the app has no data for: its name kept with the roll, converted as the generic film.
    let generic = FilmProfile.builtins.first { $0.id == "generic" }!
    model.beginNewProject(profile: generic, filmName: "Fujifilm Velvia 50", reversal: true, format: .six7)
    try check(model.filmName == "Fujifilm Velvia 50" && model.profile.id == "generic" && model.reversalRoll && model.format == .six7,
      "a film without data is kept by its own name, converted as the generic film, its kind and format as chosen")

    // The shelf's films in 3D: a cassette and a roll come out drawn, standing clear of the corners.
    func drawn(_ image: NSImage?) -> (middle: Double, corner: Double)? {
      guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
      let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
      guard let data = ctx.data else { return nil }
      let px = data.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
      func alpha(_ x: Int, _ y: Int) -> Double { Double(px[(y * cg.width + x) * 4 + 3]) / 255 }
      return (alpha(cg.width / 3, cg.height / 2), alpha(1, 1))
    }
    let shelved = NewProjectSheet.Look(maker: "Kodak", name: "Portra 400", title: "Portra 400", iso: 400, kind: .colour)
    let cassette = drawn(FilmRender.renderNow(shelved, gauge: .mm135, pixels: CGSize(width: 140, height: 184)))
    let roll = drawn(FilmRender.renderNow(shelved, gauge: .mm120, pixels: CGSize(width: 140, height: 184)))
    try check(cassette.map { $0.middle > 0.9 && $0.corner < 0.05 } == true && roll.map { $0.middle > 0.9 && $0.corner < 0.05 } == true,
      "the shelf's films are rendered in 3D, a 135 cassette and a 120 roll, standing on a clear ground")
  }
}
