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

    // Rested on, a film turns once round in a view wider than its picture: all the way round the
    // leader stays inside that view, and turned to the front its middle is the still picture.
    func alphas(_ image: NSImage?) -> (w: Int, h: Int, a: [Double])? {
      guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
      let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
      guard let data = ctx.data else { return nil }
      let px = data.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
      return (cg.width, cg.height, (0..<(cg.width * cg.height)).map { Double(px[$0 * 4 + 3]) / 255 })
    }
    let cell = CGSize(width: 140, height: 184)
    var edgeMost = 0.0, middleOff = 1.0
    for gauge in [FilmStock.Gauge.mm135, .mm120] {
      let widen = FilmRender.turnWiden(gauge, aspect: cell.width / cell.height)
      for step in 0..<8 {
        guard let t = alphas(FilmRender.renderNow(shelved, gauge: gauge, pixels: cell, turn: CGFloat(step) * .pi / 4, widen: widen)) else { edgeMost = 1; continue }
        // The film itself (not the soft shadow on the floor) at the sides of the view.
        for y in 0..<t.h { edgeMost = max(edgeMost, t.a[y * t.w], t.a[y * t.w + t.w - 1]) }
        if step == 0, gauge == .mm135, let still = alphas(FilmRender.renderNow(shelved, gauge: gauge, pixels: cell)) {
          let x0 = (t.w - still.w) / 2, y0 = (t.h - still.h) / 2
          var off = 0.0
          for y in 0..<still.h { for x in 0..<still.w { off += abs(still.a[y * still.w + x] - t.a[(y + y0) * t.w + x + x0]) } }
          middleOff = off / Double(still.w * still.h)
        }
      }
    }
    try check(edgeMost < 0.35 && middleOff < 0.04,
      String(format: "a film turns once round inside its wider view (most at its sides %.2f), and starts from its still picture (%.3f apart)", edgeMost, middleOff))

    // ②'s film section opens the same shelf on the open roll: its film, kind and format change together.
    model.loadProject(copyRoll.appendingPathComponent(AppModel.projectFile))
    let opened = NewProjectSheet.current(model)
    let portra400 = FilmProfile.builtins.first { $0.id == "portra400" }!
    model.applyFilm(profile: portra400, filmName: "Kodak Ektacolor Pro 400", reversal: false, format: .six45)
    let negativeRoll = (model.profile.id, model.filmName, model.format, model.frames.contains { $0.adjustments.isSlide })
    model.applyFilm(profile: generic, filmName: "Fujifilm Velvia 50", reversal: true, format: .six7)
    try check(opened == .stock("Kodak Portra 400")
      && negativeRoll.0 == "portra400" && negativeRoll.1 == "Kodak Ektacolor Pro 400" && negativeRoll.2 == .six45 && !negativeRoll.3
      && model.profile.id == "generic" && model.filmName == "Fujifilm Velvia 50" && model.format == .six7
      && !model.frames.isEmpty && model.frames.allSatisfy { $0.adjustments.isSlide } && NewProjectSheet.current(model) == .stock("Fujifilm Velvia 50"),
      "the open roll's film changes from the shelf: its preset, its own name, negative or slide and its format together")
    // One ⌘Z puts all of it back.
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.undoManager = undo
    let before = (model.profile.id, model.filmName, model.format, model.frames.allSatisfy { $0.adjustments.isSlide }, model.filmEdges)
    model.applyFilm(profile: portra400, filmName: "Kodak Ektacolor Pro 400", reversal: false, format: .six45, edges: .rebate)
    let changed = model.profile.id == "portra400" && model.format == .six45 && !model.reversalRoll && model.filmEdges == .rebate
      && model.frames.allSatisfy { $0.adjustments.filmEdges == .rebate }
    undo.undo()
    let after = (model.profile.id, model.filmName, model.format, model.frames.allSatisfy { $0.adjustments.isSlide }, model.filmEdges)
    model.undoManager = nil
    try check(changed && after == before && model.frames.allSatisfy { $0.adjustments.filmEdges == nil },
      "one ⌘Z puts the roll's film, its name, negative or slide, its format and its film edge back as they were: \(after)")
    // What the makers publish: every catalog film has its entry, on the maker's own site over
    // https (never filmferrania.it, now someone else's), with what it is for in a line or two.
    let missing = FilmCatalog.stocks.filter { FilmSheets.of($0.name) == nil }.map(\.name)
    let links = FilmSheets.byName.values.flatMap { [$0.sheet, $0.page].compactMap { $0 } }
    try check(missing.isEmpty && FilmSheets.byName.count == FilmCatalog.stocks.count
      && links.allSatisfy { $0.scheme == "https" && $0.host?.hasSuffix("filmferrania.it") == false }
      && FilmSheets.byName.values.allSatisfy { !$0.about.isEmpty && $0.about.count <= 120 && $0.specs.count <= 6 },
      "every film on the shelf has the maker's data sheet or page, over https, and a short note (\(FilmSheets.byName.count) films; missing: \(missing))")
    // A copy's size by the film's real width where it takes in the edge: 35 mm across a 135 crop
    // (its short side), 61.5 mm across a 120 one (its long side for 6×6, short for 6×7); the
    // picture's 24 or 56 mm where it does not; a de-masking region set is the picture either way.
    let dpi = { (w: CGFloat, h: CGFloat, f: FilmFormat, e: PictureEdges, r: NormalRect?) in AppModel.formatDPI(crop: CGSize(width: w, height: h), region: r, format: f, edges: e) ?? 0 }
    let at = 25.4 / 35 * 3500
    try check(abs(dpi(3800, 3500, .mm135, .rebate, nil) - at) < 0.01 && abs(dpi(3600, 2400, .mm135, .picture, nil) - 2540) < 0.01
      && abs(dpi(3600, 2400, .mm135, .auto, nil) - 2540) < 0.01
      && abs(dpi(5800, 6150, .six6, .rebate, nil) - 2540) < 0.01 && abs(dpi(7100, 6150, .six7, .rebate, nil) - 2540) < 0.01
      && abs(dpi(3800, 3500, .mm135, .rebate, NormalRect(x: 0.05, y: 0.16, width: 0.9, height: 2400.0 / 3500)) - 2540) < 0.01
      && AppModel.formatDPI(crop: CGSize(width: 3800, height: 3500), region: nil, format: .auto, edges: .rebate) == nil,
      "a copy taking in the film's edge is sized by the film's width (35 mm on 135, 61.5 mm across 120), one of the picture alone by the picture's")
    // 「120 其他」 is offered no more, but a roll that has it keeps it.
    try check(!FilmFormat.offered(keeping: .auto).contains(.medium) && !FilmFormat.offered(keeping: .six6).contains(.medium)
      && FilmFormat.offered(keeping: .medium).contains(.medium) && FilmFormat.offered(keeping: .auto).count == FilmFormat.allCases.count - 1,
      "the formats offered leave out 120 of a length not given, but a roll already so keeps it")
    // 6×4.5 lies 41.5 mm along the film by 56 across: drawn narrower than 6×6, not as its square.
    try check(FormatPiece.size(.six45).width < FormatPiece.size(.six6).width && FormatPiece.size(.six6).width < FormatPiece.size(.six7).width
      && abs(FormatPiece.size(.six45).width / FormatPiece.size(.six45).height - 49.5 / 61.5) < 0.01,
      "the format pieces lie as the frames do on the film: 6×4.5 41.5 mm along, narrower than 6×6, 6×7 longer")
    try check(NewProjectSheet.edgesNote(.rebate, format: .mm135).contains("35 mm") && NewProjectSheet.edgesNote(.rebate, format: .six7).contains("56×69.5")
      && NewProjectSheet.edgesNote(.picture, format: .six45).contains("56×41.5"),
      "the shelf says what the film's edge means in millimetres for the format chosen")
    // Exports are named after the roll's own film, not the generic preset it converts with.
    let named = model.exportName(for: model.frames.first)
    let velviaKey = model.exportFilmKey
    model.applyFilm(profile: portra400, filmName: portra400.name, reversal: false, format: .mm135)
    try check(velviaKey == "velvia50" && named.hasPrefix("velvia50_") && model.exportFilmKey == "portra400",
      "exports are named after the roll's own film (\(named)), a preset's id where the roll is that film (\(model.exportFilmKey))")
    // The library's search finds rolls by what their film is, as the shelf finds films.
    func entry(_ film: String, format: String? = nil, hoursAgo: Double = 0, profile: FilmProfile = FilmProfile.builtins[0]) -> RollEntry {
      RollEntry(folder: root, project: root.appendingPathComponent(AppModel.projectFile), title: "卷", named: false, film: film,
        date: Date(timeIntervalSinceNow: -hoursAgo * 3600), source: .camera, frames: [], fullResolution: 0, exported: 0, overview: nil,
        notes: "", profile: profile, legacy: false, format: format)
    }
    let velviaRoll = entry("Fujifilm Velvia 50", format: FilmFormat.six7.rawValue), hp5Roll = entry("Ilford HP5 Plus 400"), ownRoll = entry("Aerocolor 100")
    try check(RollLibrary.matches(velviaRoll, "富士") && RollLibrary.matches(velviaRoll, "正片") && RollLibrary.matches(velviaRoll, "6×7")
      && !RollLibrary.matches(velviaRoll, "黑白") && RollLibrary.matches(hp5Roll, "黑白 400") && RollLibrary.matches(hp5Roll, "依尔福")
      && RollLibrary.matches(ownRoll, "aero") && !RollLibrary.matches(ownRoll, "富士"),
      "the library finds rolls by what their film is: 「富士」「正片」 a Velvia roll, 「黑白 400」「依尔福」 an HP5 one, 「6×7」 by its format")
    // The shelf's first row: the films of the rolls last begun, newest first, each once; a preset of
    // this Mac as itself, a film outside the catalog by its name, the generic film's own name not.
    var own = FilmProfile.builtins[0]
    own.id = "test-own-\(UUID().uuidString.prefix(6))"
    own.name = "Kodak Portra 160 · 翻拍 · 2026-11-07 13:21"
    let lately = NewProjectSheet.recent([
      entry("Ilford HP5 Plus 400", hoursAgo: 2), entry("Fujifilm Velvia 50", format: FilmFormat.six7.rawValue, hoursAgo: 1),
      entry("Fujifilm Velvia 50", format: FilmFormat.six6.rawValue, hoursAgo: 2.5), entry("Fujifilm Velvia 50", hoursAgo: 3),
      entry(own.name, hoursAgo: 4, profile: own), entry(generic.name, hoursAgo: 5, profile: generic), entry("Aerocolor 100", hoursAgo: 6),
      entry("Kodak Gold 200", hoursAgo: 7)], profiles: FilmProfile.builtins + [own], limit: 5)
    let velviaID = FilmCatalog.stock(named: "Fujifilm Velvia 50")?.id ?? "", hp5ID = FilmCatalog.stock(named: "Ilford HP5 Plus 400")?.id ?? ""
    // A roll with nothing in it yet changed to slides: its first copy or import is a slide.
    model.beginNewProject(profile: portra400, reversal: false, format: .mm135)
    model.applyFilm(profile: generic, filmName: "Fujifilm Velvia 50", reversal: true, format: .six7)
    try check(model.frames.isEmpty && model.reversalRoll && model.format == .six7,
      "a roll with nothing in it yet changed to a slide film comes in as slides")
    // The next new roll is a negative again, whatever the last was: the sheet opens on 负片 (on 反转片
    // only for a slide film), changing the film keeps the roll's kind.
    let slidesOpen = model.reversalRoll
    model.beginNewProject(profile: portra400, filmName: "Kodak Portra 400", reversal: true, format: .mm135)
    let crossProcessed = model.reversalRoll
    model.lastCapture = folder.appendingPathComponent("last-roll-EPS00010.ARW")
    model.newProject()
    try check(model.lastCapture == nil && model.lastShotBalance == nil,
      "a new roll forgets the last roll's last picture: its focus check and base cast are not this roll's")
    try check(slidesOpen && crossProcessed && !model.reversalRoll && !model.preferences.scanReversal
      && !NewProjectSheet.startsAsSlides(.stock(FilmCatalog.stock(named: "Kodak Portra 400")?.id ?? ""), changing: false, m: model)
      && !NewProjectSheet.startsAsSlides(.named("Aerocolor 100"), changing: false, m: model)
      && NewProjectSheet.startsAsSlides(.stock(velviaID), changing: false, m: model),
      "after a roll read as slides, a new roll starts as a negative: the sheet on 负片 but for a slide film, the scanner on negatives")
    model.beginNewProject(profile: portra400, filmName: "Kodak Portra 400", reversal: true, format: .mm135)
    try check(NewProjectSheet.startsAsSlides(.stock(FilmCatalog.stock(named: "Kodak Portra 400")?.id ?? ""), changing: true, m: model),
      "changing the film of a roll read as slides keeps it slides")
    let portra160ID = FilmCatalog.stock(named: "Kodak Portra 160")?.id ?? ""
    try check(lately.map(\.choice) == [.stock(velviaID), .stock(hp5ID), .stock(velviaID), .stock(portra160ID), .named("Aerocolor 100")]
      && lately.map(\.format) == [.six7, nil, nil, nil, nil] && lately.map(\.calibration) == [nil, nil, nil, own.id, nil],
      "the shelf starts with the films of the rolls last begun, newest first, each once in 120 (in its newest roll's format) and once in 135, a calibration of this Mac as its film with the calibration taken along: \(lately.map { "\($0.choice) \($0.format?.rawValue ?? "-")" })")
    // A film's calibrations are listed under it once it is chosen, not on the shelf as films: the
    // calibration under its film, a preset of no film as itself.
    var nameless = own
    nameless.id = "test-nameless-\(UUID().uuidString.prefix(6))"
    nameless.name = "本机标定胶片 · 翻拍 · 2026-10-30 19:41"
    let mine = FilmProfile.builtins + [own, nameless]
    try check(NewProjectSheet.shelved(own) == .stock(portra160ID) && NewProjectSheet.calibrations(of: .stock(portra160ID), among: mine).map(\.id) == [own.id]
      && NewProjectSheet.shelved(nameless) == .preset(nameless.id) && NewProjectSheet.calibrations(of: .stock(velviaID), among: mine).isEmpty,
      "a calibration is listed under the film it is of, one of no known film stands as itself")
  }
}
