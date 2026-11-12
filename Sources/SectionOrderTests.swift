import Foundation

/// The side columns' sections in the user's order: kept, read back, dropped into place, moved up
/// and down among those shown, and put back to the app's own.
enum SectionOrderTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let grade = SectionColumn.grade.defaults
    try check(SectionOrder.order(saved: "", defaults: grade) == grade,
      "a column never arranged shows its sections in the app's own order")
    // Saved: colour first, tone after levels; a key it no longer has dropped, one it gained since
    // (sharpening, not saved) put after the one the app's own order has before it.
    let saved = "colour,balance,levels,tone,curves,gone"
    try check(SectionOrder.order(saved: saved, defaults: grade) == ["colour", "balance", "levels", "tone", "curves", "sharpening"],
      "a saved order is read back, keys no longer there left out and new ones put where the app's own order has them")
    // Dragged: tone from above onto curves goes after it; curves from below onto balance before it.
    let order = grade
    try check(SectionOrder.place("tone", at: "curves", in: order) == ["balance", "levels", "colour", "curves", "tone", "sharpening"]
      && SectionOrder.place("curves", at: "balance", in: order) == ["curves", "balance", "tone", "levels", "colour", "sharpening"]
      && SectionOrder.place("tone", at: "tone", in: order) == order,
      "a section dragged over another takes its place: after it coming from above, before it from below")
    // Moved by its menu among those shown: on a slide the film column shows no calibration or
    // base, so the frame's extent moved up goes above the film, past the hidden ones.
    let film = SectionColumn.film.defaults
    let up = SectionOrder.move("frame", by: -1, in: film, shown: ["film", "frame"])
    try check(up.firstIndex(of: "frame")! < up.firstIndex(of: "film")! && SectionOrder.move("film", by: -1, in: film, shown: film) == film,
      "上移 moves a section past the one above it among those shown; the top one stays")
    // Kept where the app keeps its settings: written, read back, and cleared to the default.
    let suite = "local.epscan.section-order-test"
    UserDefaults().removePersistentDomain(forName: suite)
    let defaults = UserDefaults(suiteName: suite)!
    let arranger = SectionArranger(column: .grade, shown: grade, read: { defaults.string(forKey: SectionColumn.grade.storageKey) ?? "" },
      write: { defaults.set($0, forKey: SectionColumn.grade.storageKey) })
    arranger.move("colour", by: -1)
    arranger.place("sharpening", at: "balance")
    let kept = SectionOrder.order(saved: defaults.string(forKey: SectionColumn.grade.storageKey) ?? "", defaults: grade)
    try check(kept == ["sharpening", "balance", "tone", "colour", "levels", "curves"] && !arranger.isDefault,
      "the order is kept as it is changed")
    arranger.reset()
    try check(arranger.isDefault && arranger.order == grade, "恢复默认顺序 puts the column back in the app's own order")
    UserDefaults().removePersistentDomain(forName: suite)
  }
}
