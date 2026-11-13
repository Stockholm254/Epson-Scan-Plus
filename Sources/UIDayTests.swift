import Foundation

/// The day's interface changes: the dust rings switched once for the toolbar and the 除尘 section
/// and kept; a section's ⟲ setting back only that section; ①'s empty light table with its preview key; the library's label leaving out a full
/// resolution every frame has, and a medium format's 120.
enum UIDayTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let suite = "local.epscan.uiday-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("uiday", isDirectory: true), preferences: Preferences(defaults: defaults))
    try check(model.showDust, "dust is ringed on the single view to begin with")
    model.showDust = false
    try check(!model.preferences.showDustMarks && defaults.object(forKey: "dustMarksShown") as? Bool == false,
      "the toolbar's 除尘标出 and the section's 标出 are one switch, kept in the preferences")
    try check(!Preferences(defaults: defaults).showDustMarks, "and it is off again at the next launch")
    // A new roll on ① with the scanner shows its preview key; with the camera, or on ②, it does not.
    model.startNewProject()
    model.page = .capture
    model.captureSource = .scanner
    try check(model.emptyScannerTable, "a new roll on ① with the scanner, nothing previewed, is the empty light table with its 预览 key")
    model.captureSource = .camera
    let camera = model.emptyScannerTable
    model.captureSource = .scanner
    model.page = .convert
    try check(!camera && !model.emptyScannerTable, "with the camera, or on ②, it is not")

    // A section's ⟲: that section back as a new frame has it, the rest as it was.
    var a = Adjustments()
    (a.warmth, a.shadowWarmth, a.exposure, a.autoLevels, a.saturation) = (0.3, 0.2, 0.5, false, 1.3)
    let balance = AppModel.reset(.balance, of: a, copyShot: false)
    try check(balance.warmth == 0 && balance.shadowWarmth == nil && balance.exposure == 0.5 && !balance.autoLevels && balance.saturation == 1.3,
      "白平衡's ⟲ sets back only white balance: exposure, levels and colour stay")
    let levels = AppModel.reset(.levels, of: a, copyShot: false), colour = AppModel.reset(.colour, of: a, copyShot: false)
    try check(levels.autoLevels && levels.warmth == 0.3 && colour.saturation == 1 && colour.exposure == 0.5,
      "色阶's sets back auto levels, 色彩's the saturation, each leaving the others")
    var slide = Adjustments()
    slide.setReversal(true)
    slide.autoWhiteBalance = true
    try check(!AppModel.reset(.balance, of: slide, copyShot: false).autoWhiteBalance,
      "a slide's white balance goes back to its own colour, auto off, as a new slide has it")
    var copyShot = Adjustments()
    copyShot.colourNoise = 1
    try check(AppModel.reset(.colour, of: copyShot, copyShot: true) == copyShot && AppModel.reset(.colour, of: copyShot, copyShot: false).colourNoise == nil,
      "a copy shot's colour noise reduction is its default, so a copy shot as it came in shows no ⟲")
    // The shortcuts sheet names every tool's own key, as the tools are set now.
    let listed = Set(Shortcuts.groups.flatMap(\.keys).map(\.keys))
    try check(CanvasTool.allCases.compactMap(\.shortcut).allSatisfy { listed.contains($0.uppercased()) }
      && Shortcuts.groups.flatMap(\.keys).contains { $0.keys.contains(AppModel.loupeShortcut.uppercased()) },
      "the shortcuts sheet lists each canvas tool's key and the loupe's")
    func roll(frames: Int, full: Int) -> RollEntry {
      RollEntry(folder: folder, project: folder.appendingPathComponent("Session.epscan"), title: "t", named: false, film: "Kodak Portra 160",
        date: Date(), source: .camera,
        frames: (0..<frames).map { RollEntry.Frame(id: UUID(), name: String(format: "%02d", $0 + 1), rect: NormalRect(x: 0, y: 0, width: 1, height: 1), file: nil) },
        fullResolution: full, exported: 0, overview: nil, notes: "", profile: FilmProfile.builtins[0])
    }
    let copy = RollSleeve.details(roll(frames: 22, full: 22)), scanned = RollSleeve.details(roll(frames: 18, full: 3))
    try check(!copy.contains("全分辨率") && copy.contains("22 张"), "a roll whose every frame is full resolution does not say so: \(copy)")
    try check(scanned.contains("全分辨率 3"), "a scanned roll part scanned says how many are: \(scanned)")
    var square = roll(frames: 12, full: 12)
    square.format = FilmFormat.six6.rawValue
    try check(RollSleeve.details(square) == "Kodak Portra 160 · 6×6 · 12 张", "a 6×6 roll's label names its frame, not 120 as well: \(RollSleeve.details(square))")
    try check(RollSleeve.detailsOnTwoLines(square) == "Kodak Portra 160\n6×6 · 12 张",
      "a roll's label puts the film on a line of its own and the rest under it")
    // Each roll in the library shows its own film, as the shelf draws it.
    let film35 = RollSleeve.film(roll(frames: 3, full: 3), model: model), film120 = RollSleeve.film(square, model: model)
    var own = roll(frames: 1, full: 1)
    own = RollEntry(folder: own.folder, project: own.project, title: "t", named: false, film: "Grandpa's Mystery 64", date: own.date, source: .files,
      frames: own.frames, fullResolution: 1, exported: 0, overview: nil, notes: "", profile: FilmProfile.builtins[0])
    try check(film35?.look.maker == "Kodak" && film35?.look.name.contains("Portra") == true && film35?.gauge == .mm135 && film120?.gauge == .mm120,
      "a roll's label shows its film from the catalog: Portra 160 as its cassette, in a 6×6 roll as its 120 roll")
    try check(RollSleeve.film(own, model: model)?.look.named == true, "a film the catalog does not know shows its own name on a plain can")
    // The cassettes as the real ones are printed now: Kodacolor and ColorPlus each their own, and
    // Tri-X's 120 paper reading 400TX as its cassette does.
    func shelf(_ name: String) -> NewProjectSheet.Look? {
      FilmCatalog.stock(named: name).map { NewProjectSheet.look(.stock($0.id), m: model) }
    }
    let names = ["Kodak Kodacolor 100", "Kodak ColorPlus 200", "Kodak Gold 200", "Kodak Tri-X 400"]
    try check(names.allSatisfy { shelf($0).flatMap(FilmPrint.design) != nil }
      && shelf("Kodak Tri-X 400").map(Roll120Print.stockName) == "400TX" && shelf("Kodak Portra 400").map(Roll120Print.stockName)?.contains("Portra") == true,
      "Kodacolor, ColorPlus, Gold and Tri-X each have a print of their own; Tri-X's 120 paper reads 400TX")
  }
}
