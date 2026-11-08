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
  }
}
