import Foundation

/// The presets read off the makers' data sheets: each one a film of the catalog, linked from its
/// stock and found again by its name, with the shelf's own data-sheet link as its source.
enum DataSheetTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let builtins = FilmProfile.builtins, sheets = FilmDataSheets.presets
    try check(sheets.count == 18 && builtins.count == 23 && builtins.first?.id == "portra160" && builtins.last?.id == "generic"
      && Set(builtins.map(\.id)).count == builtins.count,
      "18 more films from their data sheets and Phoenix II from a chart: Portra 160 still first, the generic film last, every id once")
    var invalid = [String]()
    for p in builtins { do { try p.validate() } catch { invalid.append(p.id) } }
    try check(invalid.isEmpty && sheets.allSatisfy { p in p.slopes.values.allSatisfy { $0 > 0.3 && $0 < 1.6 } && p.toe == nil && p.offsets == nil },
      "every built-in preset is valid, the new ones slopes only (no toe, no neutral): \(invalid)")
    // Each one is its catalog film, by the stock's name, and the stock links back to it.
    let unlinked = sheets.filter { p in
      guard let s = FilmCatalog.stocks.first(where: { $0.name == p.name }) else { return true }
      return s.preset != p.id || FilmCatalog.stock(named: p.name)?.id != s.id
    }
    try check(unlinked.isEmpty, "each data-sheet preset is named as its film in the catalog, and the film links to it: \(unlinked.map(\.id))")
    let dangling = FilmCatalog.stocks.compactMap { s in s.preset.flatMap { id in builtins.contains { $0.id == id } ? nil : "\(s.name) → \(id)" } }
    try check(dangling.isEmpty && FilmCatalog.stock(named: "Kodak Ektacolor Pro 800")?.preset == "portra800",
      "every film's preset is a built-in one; Ektacolor Pro 800, Portra 800's new name, converts as Portra 800: \(dangling)")
    // The source is the data sheet the shelf links to.
    let elsewhere = sheets.filter { p in FilmSheets.of(p.name)?.sheet?.absoluteString != p.sourceURL }
    try check(elsewhere.isEmpty && sheets.allSatisfy { $0.notes.hasPrefix(FilmDataSheets.traced) && !$0.publication.isEmpty },
      "each preset cites the data sheet the film shelf opens, and says how its slopes were read: \(elsewhere.map(\.id))")
    // Films with no curves on their sheets stay generic; Phoenix II is not Phoenix 200.
    let generic = ["Harman Red 125", "Harman Switch Azure 125", "Lomography Color Negative 400", "CineStill 800T"]
    try check(generic.allSatisfy { FilmCatalog.stock(named: $0)?.preset == nil } && FilmCatalog.stock(named: "Harman Phoenix 200")?.preset == "phoenix200",
      "films whose sheets print no usable curve (Red, Switch Azure, Lomography's guides) or none at all (CineStill) keep the generic conversion")
    // Phoenix II's sheet prints no curve either: its slopes were measured off an IT8.7/2 chart's
    // grey scale shot on it, green far flatter than red and blue, and it says so.
    let phoenix2 = builtins.first { $0.id == "phoenix2-200" }
    try check(FilmCatalog.stock(named: "Harman Phoenix II 200")?.preset == "phoenix2-200" && phoenix2?.chartMeasured == true
      && phoenix2?.slopesSource == "色卡实测" && FilmCatalog.stock(named: "Harman Phoenix 200")?.preset == "phoenix200"
      && phoenix2.map { $0.slopes.g < 0.45 && $0.slopes.r > 0.5 && $0.slopes.b > 0.5 && $0.setsChannelContrast && $0.offsets == nil } == true
      && builtins.first { $0.id == "portra160" }?.slopesSource == "数据表",
      "Phoenix II converts with its chart-measured slopes (green 0.40 against red 0.60 and blue 0.59), named as measured, not as a data sheet")
    let p800 = builtins.first { $0.id == "portra800" }!, p400 = builtins.first { $0.id == "portra400" }!
    try check(p800.slopes.g > p400.slopes.g && p800.slopes.b > p800.slopes.g && p800.slopes.g > p800.slopes.r && p800.setsChannelContrast,
      "Portra 800's sheet is steeper than Portra 400's, blue over green over red as on every Status M sheet, and sets each channel's contrast")
  }
}
