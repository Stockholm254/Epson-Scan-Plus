import Foundation

/// A film's calibrations listed as a table: each one's kind, device, day and points read from its
/// description, newest first, searchable, the table no taller than six rows.
enum CalibrationListTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let v850 = CalibrationRow(id: "a", title: "V850 标定", publication: "本机标定 · EPSON V800/V850 · GT-X980 · 2026-10-27 · 3 个中性点")
    let copy = CalibrationRow(id: "b", title: "翻拍标定 · 2026-11-11 20:13", publication: "翻拍标定 · ILCE-7RM4 · 2026-11-11 · 13 个中性点")
    let later = CalibrationRow(id: "c", title: "翻拍标定 · 2026-11-11 21:04", publication: "翻拍标定 · ILCE-7RM4 · 2026-11-11 · 7 个中性点")
    try check(v850.kind == "本机" && v850.device == "EPSON V800/V850 · GT-X980" && v850.date == "2026-10-27" && v850.points == 3
      && copy.kind == "翻拍" && copy.device == "ILCE-7RM4" && copy.points == 13 && copy.when == "2026-11-11 20:13",
      "a calibration's kind, scanner or camera, day and neutral points are read from its description")
    try check(CalibrationRow.sorted([v850, copy, later]).map(\.id) == ["c", "b", "a"],
      "the calibrations are listed newest first, by the time in their name within a day")
    try check(CalibrationRow.filtered([v850, copy, later], "7rm4 21:04").map(\.id) == ["c"] && CalibrationRow.filtered([v850, copy], "").count == 2,
      "the list is searched by every word typed, in its name, kind, device or day")
    // A hundred of them: the table stays six rows tall and scrolls.
    try check(CalibrationTable.height(100) == CalibrationTable.height(6) && CalibrationTable.height(2) < CalibrationTable.height(6),
      "with a hundred calibrations the table is no taller than six rows, and scrolls")
  }
}
