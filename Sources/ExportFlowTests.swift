import AppKit
import Foundation

/// The output tab's export: straight into the folder it shows, frame by frame with progress and
/// a stop, each frame stamped with what it was written with, so the strip can mark it exported
/// or changed since; the stamps saved with the roll and kept through ⌘Z.
enum ExportFlowTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.1) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let fm = FileManager.default
    let root = folder.appendingPathComponent("export-flow", isDirectory: true)
    try? fm.removeItem(at: root)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let pipe = ImagePipeline.shared
    func image(_ w: Int, _ h: Int) -> CGImage {
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.setFillColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1)
      ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
      return ctx.makeImage()!
    }
    // A roll of three frames on a 600 × 400 preview.
    let roll = root.appendingPathComponent("roll", isDirectory: true)
    try fm.createDirectory(at: roll, withIntermediateDirectories: true)
    let overview = roll.appendingPathComponent("overview.png")
    try pipe.savePNG(image(600, 400), to: overview)
    let frames = (0..<3).map { i in
      FilmFrame(name: String(format: "%02d", i + 1), rect: NormalRect(x: 0.03 + Double(i) * 0.32, y: 0.2, width: 0.28, height: 0.5), format: "135")
    }
    var project = DeskProject(
      overviewPath: overview.path, overviewDPI: 150, physicalWidthMM: 101.6, physicalHeightMM: 67.7,
      filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: frames)
    project.overviewFile = "overview.png"
    let file = roll.appendingPathComponent(AppModel.projectFile)
    try JSONEncoder().encode(project).write(to: file)

    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    // Held here: a model holds its undo manager weakly.
    let edits = UndoManager()
    edits.groupsByEvent = false
    func model() -> AppModel {
      let m = AppModel(libraryURL: root, preferences: Preferences(defaults: defaults))
      m.undoManager = edits
      m.loadProject(file)
      return m
    }
    let m = model()
    let ids = m.frames.map(\.id)
    try check(m.frames.count == 3 && m.exportStamps.isEmpty && m.frames.allSatisfy { m.exportMark($0) == .notExported },
      "a roll never exported has no marks")

    // Where it goes, and how big.
    try check(m.exportsIntoRoll && m.exportFolder?.standardizedFileURL.path == roll.appendingPathComponent("Exports").standardizedFileURL.path,
      "the output tab exports into the roll's own Exports to begin with: \(m.exportFolder?.lastPathComponent ?? "-")")
    let own = root.appendingPathComponent("everything", isDirectory: true)
    try fm.createDirectory(at: own, withIntermediateDirectories: true)
    m.preferences.lastExportFolder = own.path
    try check(!m.exportsIntoRoll && m.exportFolder?.standardizedFileURL.path == own.standardizedFileURL.path,
      "a folder of its own chosen, every roll exports there")
    m.exportIntoRoll()
    try check(m.exportsIntoRoll, "and back to each roll's own Exports")
    try check(m.exportPixels(m.frames[1]) == CGSize(width: 168, height: 200), "a frame's export size is its crop of the picture: \(m.exportPixels(m.frames[1]) ?? .zero)")
    m.frames[1].adjustments.rotation = 1
    try check(m.exportPixels(m.frames[1]) == CGSize(width: 200, height: 168), "turned a quarter, the other way round")
    m.frames[1].adjustments.angle = 3
    try check((m.exportPixels(m.frames[1])?.width ?? 999) < 200, "straightened, a little smaller")
    m.frames[1].adjustments.rotation = 0
    m.frames[1].adjustments.angle = nil
    try check(ExportEstimate.bytes(CGSize(width: 100, height: 100), format: .tiff, quality: 1) == 60_000
      && ExportEstimate.bytes(CGSize(width: 100, height: 100), format: .tiff8, quality: 1) == 30_000
      && ExportEstimate.bytes(CGSize(width: 100, height: 100), format: .jpeg, quality: 0.97) < 15_000,
      "file sizes: 16-bit TIFF 6 bytes a pixel, 8-bit 3, JPEG far less")
    let p = ExportProgress(total: 12, done: 2, writing: ids[2], writingName: "03")
    try check(p.label == "导出 3 / 12 · 第 03 张" && abs(p.fraction - 2.0 / 12) < 1e-9, "the progress says which of how many is being written: \(p.label)")

    // Exporting two: each stamped, the third not.
    let out = root.appendingPathComponent("out", isDirectory: true)
    var done = false
    m.export(items: [m.frames[0], m.frames[1]], to: out) { done = true }
    try check(m.exporting && m.exportProgress.total == 2 && m.exportProgress.waiting.count + (m.exportProgress.writing == nil ? 0 : 1) <= 2,
      "while it runs the progress counts the two")
    for _ in 0..<200 where !done { settle() }
    try check(done && !m.exporting && m.exportProgress == ExportProgress(), "when it ends the progress goes back to nothing")
    try check(m.exportMark(m.frames[0]) == .exported && m.exportMark(m.frames[1]) == .exported && m.exportMark(m.frames[2]) == .notExported
      && m.exportStamps[ids[0]].map { fm.fileExists(atPath: $0.file) } == true,
      "the two exported are marked exported, with the files they wrote")
    try check(m.status.contains("已导出 2 张"), "and the status says so: \(m.status)")

    // Changed since, and ⌘Z.
    m.selectedID = ids[0]
    m.change { $0.exposure = 0.4 }
    try check(m.exportMark(m.frames[0]) == .changed && m.changedSinceExport.map(\.id) == [ids[0]] && m.exportItems(.changed).map(\.id) == [ids[0]],
      "changed after its export, a frame is marked changed, and 改过 exports just it")
    m.undoManager?.undo()
    func differences(_ a: Adjustments, _ b: Adjustments) -> String {
      let x = Mirror(reflecting: a).children, y = Array(Mirror(reflecting: b).children)
      return zip(x, y).compactMap { l, r in "\(l.value)" == "\(r.value)" ? nil : "\(l.label ?? "?"): \(l.value) → \(r.value)" }.joined(separator: "; ")
    }
    try check(m.exportMark(m.frames[0]) == .exported && m.exportStamps.count == 2,
      "⌘Z takes the change back, not the export: exported again" + (m.exportStamps[ids[0]].map { differences($0.settings, m.frames[0].adjustments) }.map { $0.isEmpty ? "" : " (\($0))" } ?? " (no stamp)"))
    try check(m.exportItems(.ticked).count == 3 && m.exportItems(.chosen).map(\.id) == [ids[0]], "勾选 exports the ticked, 当前 the frame shown")

    // Saved with the roll.
    m.saveProject()
    let reopened = model()
    try check(reopened.exportStamps.count == 2 && reopened.exportMark(reopened.frames[0]) == .exported && reopened.exportMark(reopened.frames[2]) == .notExported,
      "the marks are saved with the roll and read back")

    // 停止: after the frame being written, the files written kept.
    let stopped = root.appendingPathComponent("stopped", isDirectory: true)
    done = false
    m.export(items: m.frames, to: stopped) { done = true }
    m.stopExports()
    for _ in 0..<200 where !done { settle() }
    let written = ((try? fm.contentsOfDirectory(atPath: stopped.path)) ?? []).filter { $0.hasSuffix(".tif") }
    try check(done && written.count <= 1 && m.status.contains("已停止") && !m.exporting && m.exportProgress == ExportProgress(),
      "停止 stops after the frame being written: \(written.count) written, \(m.status)")

    // A contact sheet stopped writes nothing.
    let sheetURL = root.appendingPathComponent("sheet.jpg")
    var sheetError: Error?
    var sheetDone = false
    m.composeContactSheet(ids: ids, to: sheetURL, format: .jpeg, fromPreview: true) { sheetError = $0; sheetDone = true }
    m.stopExports()
    for _ in 0..<200 where !sheetDone { settle() }
    try check(sheetDone && sheetError is ExportStopped && !fm.fileExists(atPath: sheetURL.path) && m.status.contains("已停止生成接触表")
      && m.exportProgress == ExportProgress(), "a contact sheet stopped writes nothing and says so")
    // And one let run comes out, with its frames counted on the way.
    sheetDone = false
    sheetError = nil
    m.composeContactSheet(ids: ids, to: sheetURL, format: .jpeg, fromPreview: true) { sheetError = $0; sheetDone = true }
    try check(m.exportProgress.total == 3 && m.exportProgress.sheet, "a contact sheet counts its frames as it draws them")
    for _ in 0..<300 where !sheetDone { settle() }
    try check(sheetDone && sheetError == nil && fm.fileExists(atPath: sheetURL.path) && m.exportProgress == ExportProgress(),
      "and let run, it is written")

    // A slider's drag saves the roll once it stops, not with each step.
    func saved() -> Double? {
      (try? JSONDecoder().decode(DeskProject.self, from: Data(contentsOf: file)))?.frames.first { $0.id == ids[0] }?.adjustments.exposure
    }
    m.selectedID = ids[0]
    m.change { $0.exposure = 0.05 }
    for k in 1...12 {
      m.change { $0.exposure = 0.05 + Double(k) * 0.05 }
      settle(1.0 / 60)
    }
    let during = saved()
    settle(0.7)
    try check(during.map { abs($0 - 0.65) > 1e-9 } == true && saved().map { abs($0 - 0.65) < 1e-9 } == true,
      "a drag is saved once it stops, with its last step: \(during ?? -1) during, \(saved() ?? -1) after")
  }
}
