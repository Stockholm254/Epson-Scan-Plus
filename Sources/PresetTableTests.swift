import AppKit
import Foundation
import SwiftUI

/// The presets table: which rolls in the library convert with each preset, the one the open roll
/// uses now, deleting presets made here while the rolls keep their copies, and what MCP reads of
/// the presets, the library and the conversion.
enum PresetTableTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func preset(_ id: String, _ name: String, calibrated: Bool) -> FilmProfile {
      var p = FilmProfile.builtins[0]
      p.id = id
      p.name = name
      p.publication = "测试 · \(id)"
      if calibrated { p.offsets = RGB(r: -0.1, g: 0, b: -0.05) }
      return p
    }
    let copy = preset("portra160-copy-aaaaaa", "Kodak Portra 160 · 翻拍 · 测试", calibrated: true)
    let scanner = preset("portra160-v850-bbbbbb", "Kodak Portra 160 · V850 · 测试", calibrated: true)
    let imported = preset("gold200-mine", "Kodak Gold 200 · 自己的", calibrated: false)
    let gone = preset("portra160-copy-cccccc", "Kodak Portra 160 · 翻拍 · 删掉的", calibrated: true)

    // A library of three rolls: one with the copy preset, one with the data sheet's, one with a
    // preset no longer in the list.
    let library = folder.appendingPathComponent("preset-table", isDirectory: true)
    try? FileManager.default.removeItem(at: library)
    var projects = [URL]()
    for (i, profile) in [copy, FilmProfile.builtins[0], gone].enumerated() {
      let roll = library.appendingPathComponent(String(format: "2026-10-0%d_120000_TEST", i + 1), isDirectory: true)
      try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
      let draw = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: ImagePipeline.shared.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      draw.setFillColor(red: 0.85, green: 0.55, blue: 0.32, alpha: 1)
      draw.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
      for b in 0..<5 {
        draw.setFillColor(red: 0.6 - Double(b) * 0.08, green: 0.35 - Double(b) * 0.05, blue: 0.2 - Double(b) * 0.02, alpha: 1)
        draw.fill(CGRect(x: 50 + b * 40, y: 50, width: 40, height: 100))
      }
      let overview = roll.appendingPathComponent("overview.png")
      try ImagePipeline.shared.savePNG(draw.makeImage()!, to: overview)
      let frame = FilmFrame(name: "01", rect: NormalRect(x: 0.15, y: 0.2, width: 0.7, height: 0.6), format: "135")
      var project = DeskProject(
        overviewPath: overview.path, overviewDPI: 150, physicalWidthMM: 50.8, physicalHeightMM: 33.9,
        filmName: profile.name, profile: profile, scanDPI: 2400, frames: [frame])
      project.rollName = "测试卷 \(i + 1)"
      let url = roll.appendingPathComponent(AppModel.projectFile)
      try JSONEncoder().encode(project).write(to: url)
      projects.append(url)
    }
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: library, preferences: Preferences(defaults: defaults))
    for p in [copy, scanner, imported] { model.keepProfile(p) }
    // The second roll open, switched to the copy preset and not yet saved.
    model.loadProject(projects[1])
    for _ in 0..<40 where model.rendering { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    model.select(model.frames[0].id)
    // Data sheets and calibrations apart: the table's filter, the menu's sections and the tag.
    let portraSheet = FilmProfile.builtins.first { $0.id == "portra160" }!, genericSheet = FilmProfile.builtins.first { $0.id == "generic" }!
    try check(PresetTable.origin(portraSheet) == .dataSheet && PresetTable.origin(copy) == .calibrated
      && PresetTable.symbol(portraSheet) == "doc.text" && PresetTable.symbol(copy) == "camera" && PresetTable.symbol(genericSheet) == "circle.dashed"
      && PresetTable.tag(portraSheet).hasPrefix("数据表 · Kodak E-4051") && PresetTable.tag(copy) == copy.publication
      && PresetTable.tag(genericSheet).hasPrefix("通用"),
      "a preset says at a glance whether its slopes come from a data sheet or were calibrated here: \(PresetTable.tag(portraSheet))")
    model.chooseProfile(copy)
    let rolls = RollLibrary.scan(model.libraryRoots)
    func row(_ id: String, _ rows: [PresetRow]) -> PresetRow? { rows.first { $0.id == id } }
    var rows = model.presetRows(rolls)
    try check(rolls.count == 3 && rolls.allSatisfy { !$0.profile.id.isEmpty }, "the library reads which preset each roll converts with")
    try check(row(copy.id, rows).map { $0.kind == .copy && $0.current && $0.rolls.count == 2 && $0.deletable } == true
      && row(FilmProfile.builtins[0].id, rows).map { $0.kind == .builtin && $0.rolls.isEmpty && !$0.deletable } == true
      && row(scanner.id, rows)?.kind == .scanner && row(imported.id, rows)?.kind == .imported,
      "the table counts the open roll as it is now: the copy preset in use on two rolls, the data sheet's on none; built-ins cannot be deleted")
    try check(row(gone.id, rows).map { $0.kind == .rollOnly && $0.rolls.count == 1 && !$0.deletable } == true
      && rows.last?.id == gone.id,
      "a preset deleted from the list but kept by a roll shows after the list, only in that roll")

    // Deleting the preset in use: the rolls keep it, and it can be put back.
    model.deleteCustomProfiles([copy.id])
    rows = model.presetRows(rolls)
    let kept = row(copy.id, rows)
    let warning = PresetManagerSheet.consequence([PresetRow(profile: copy, kind: .copy, rolls: kept?.rolls ?? [], current: true)])
    try check(!model.profiles.contains { $0.id == copy.id } && model.profile.id == copy.id
      && kept.map { $0.kind == .rollOnly && $0.current && $0.rolls.count == 2 } == true && warning.contains("保留一份"),
      "deleting the preset in use takes it off the list; the open roll and the other keep their copies, as the warning says")
    model.keepProfile(kept!.profile)
    try check(row(copy.id, model.presetRows(rolls))?.kind == .copy, "a roll's copy is put back in the list")
    // A data sheet's preset can't be deleted, built in or imported; a calibration can.
    let importedRow = row(imported.id, model.presetRows(rolls))
    try check(importedRow.map { $0.kind == .imported && !$0.deletable } == true
      && model.presetRows(rolls).filter { $0.profile.offsets == nil }.allSatisfy { !$0.deletable },
      "data sheet presets, built in or imported, cannot be deleted")
    // Clearing the calibrations no roll uses: the unused V850 calibration goes; the imported data
    // sheet preset, unused too, stays with its channel slopes, and every built-in data sheet with it.
    let sheetsBefore = model.profiles.filter { $0.offsets == nil }.map { ($0.id, $0.slopes) }
    let unused = PresetManagerSheet.unusedCalibrations(model.presetRows(rolls))
    let gonePresets = PresetManagerSheet.consequence(unused)
    model.deleteCustomProfiles(Set(unused.map(\.id)))
    let sheetsAfter = model.profiles.filter { $0.offsets == nil }.map { ($0.id, $0.slopes) }
    try check(Set(unused.map(\.id)) == [scanner.id] && model.preferences.customProfiles.map(\.id) == [imported.id, copy.id]
      && sheetsAfter.count == sheetsBefore.count && zip(sheetsBefore, sheetsAfter).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
      && gonePresets.contains("删除后就没有了"),
      "clearing the calibrations no roll uses deletes only those calibrated here; every data sheet's preset, built in or imported, keeps its channel slopes")

    // What MCP reads.
    func call(_ name: String) -> Any? {
      let r = MCPTools.call(name, [:], model: model)
      return (r.content.first?["text"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }
    let presets = call("list_presets") as? [[String: Any]]
    let listedCopy = presets?.first { $0["id"] as? String == copy.id }
    try check(listedCopy?["in_use"] as? Bool == true && listedCopy?["rolls_using"] as? Int == 2 && listedCopy?["kind"] as? String == "翻拍标定"
      && presets?.contains { $0["id"] as? String == gone.id && $0["kind"] as? String == "只在卷里" } == true,
      "MCP's list_presets says which rolls use each preset, its kind, and the presets only rolls keep")
    let listedRolls = call("list_rolls") as? [[String: Any]]
    try check(listedRolls?.count == 3 && listedRolls?.filter { $0["open"] as? Bool == true }.count == 1
      && listedRolls?.contains { $0["preset_id"] as? String == gone.id } == true,
      "MCP's list_rolls reads the library: each roll's preset, and which one is open")
    let state = call("get_state") as? [String: Any]
    let frame = state?["frame"] as? [String: Any], tone = state?["tone"] as? [String: Any]
    try check((state?["slopes_in_use"] as? [String: Any])?["from"] as? String == "calibrated preset"
      && (state?["analysis"] as? [String: Any])?["levels_white_log_exposure"] != nil && state?["roll"] != nil
      && (frame?["crop"] as? [String: Any])?["width"] != nil && frame?["picked"] != nil
      && tone?["highlights"] != nil && tone?["shadows"] != nil && (state?["preset"] as? [String: Any])?["notes"] != nil,
      "MCP's get_state reads the slopes in use and where they come from, the analysis, the roll's settings, the crop and the tone")

    // The table lays out.
    let host = NSHostingView(rootView: PresetManagerSheet(m: model))
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
    host.layoutSubtreeIfNeeded()
    try check(host.fittingSize.width >= 860, "the presets table lays out at its size")
  }
}
