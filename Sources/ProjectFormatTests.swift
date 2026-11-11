import AppKit
import Foundation

/// The project file (Session.epscan) as a format that stays: every key added since the first
/// version may be missing from an older file, which still opens; only the keys every project has
/// had are required. An edit is on disk at once, or 0.4 s after a drag, so a crash keeps it.
enum ProjectFormatTests {
  /// The keys a project cannot open without, by where they are. A key added later must decode
  /// when it is missing, or older projects stop opening: this list only ever shrinks.
  /// As of 0.19.8; every project in the library then opened with them.
  static let required: [String: Set<String>] = [
    "project": ["version", "overviewPath", "overviewDPI", "physicalWidthMM", "physicalHeightMM", "filmName", "profile", "scanDPI", "frames"],
    "frame": ["id", "name", "rect", "enabled", "format", "adjustments"],
    "adjustments": ["exposure", "contrast", "warmth", "tint", "saturation", "black", "white", "midtone", "autoLevels", "autoWhiteBalance",
      "inputGamma", "inputIsNegative", "rotation"],
    "profile": ["id", "name", "iso", "process", "publication", "slopes", "notes", "aliases", "sourceURL"],
  ]

  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let root = folder.appendingPathComponent("project-format")
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // A roll of one imported picture, as the app saves it.
    let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
    ctx.setFillColor(red: 0.3, green: 0.2, blue: 0.15, alpha: 1)
    ctx.fill(CGRect(x: 60, y: 40, width: 180, height: 120))
    let png = root.appendingPathComponent("picture.png")
    try ImagePipeline.shared.savePNG(ctx.makeImage()!, to: png)
    let library = root.appendingPathComponent("library")
    let model = AppModel(libraryURL: library)
    model.importChosen([png])
    for _ in 0..<40 where model.rendering { settle(0.1) }
    guard let session = model.sessionURL else { throw DeskError.message("FAIL: the picture makes a roll") }
    let file = session.appendingPathComponent(AppModel.projectFile)
    let saved = try Data(contentsOf: file)
    guard let json = try JSONSerialization.jsonObject(with: saved) as? [String: Any],
      let frames = json["frames"] as? [[String: Any]], let frame = frames.first
    else { throw DeskError.message("FAIL: the project is read as JSON") }

    // Every key, taken out of the file in turn: those it will not open without.
    func decodes(_ object: [String: Any]) -> Bool {
      guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
      return (try? JSONDecoder().decode(DeskProject.self, from: data)) != nil
    }
    var needed = [String: Set<String>]()
    for key in json.keys {
      var less = json
      less[key] = nil
      if !decodes(less) { needed["project", default: []].insert(key) }
    }
    for key in frame.keys {
      var less = json, f = frame
      f[key] = nil
      less["frames"] = [f]
      if !decodes(less) { needed["frame", default: []].insert(key) }
    }
    if let adjustments = frame["adjustments"] as? [String: Any] {
      for key in adjustments.keys {
        var less = json, f = frame, a = adjustments
        a[key] = nil
        f["adjustments"] = a
        less["frames"] = [f]
        if !decodes(less) { needed["adjustments", default: []].insert(key) }
      }
    }
    if let profile = json["profile"] as? [String: Any] {
      for key in profile.keys {
        var less = json, p = profile
        p[key] = nil
        less["profile"] = p
        if !decodes(less) { needed["profile", default: []].insert(key) }
      }
    }
    if ProcessInfo.processInfo.environment["EPSCAN_PRINT_REQUIRED"] != nil { print("required now:", needed.mapValues { $0.sorted() }) }
    let newlyRequired = needed.flatMap { place, keys in keys.subtracting(required[place] ?? []).map { "\(place).\($0)" } }.sorted()
    try check(newlyRequired.isEmpty,
      "every key a project file holds may be missing from an older one, which still opens; only those projects have always had are required"
        + (newlyRequired.isEmpty ? "" : " (now also required: \(newlyRequired.joined(separator: ", ")))"))

    // The oldest kind of project: only the required keys, its files by absolute path.
    var oldest = [String: Any]()
    for key in required["project"]! { oldest[key] = json[key] }
    var bare = [String: Any]()
    for key in needed["frame"] ?? [] { bare[key] = frame[key] }
    if let a = frame["adjustments"] as? [String: Any] {
      var kept = [String: Any]()
      for key in needed["adjustments"] ?? [] { kept[key] = a[key] }
      if bare["adjustments"] != nil || needed["frame"]?.contains("adjustments") == true { bare["adjustments"] = kept }
    }
    if bare["id"] == nil { bare["id"] = frame["id"] }
    if bare["name"] == nil { bare["name"] = frame["name"] }
    if bare["sourcePath"] == nil { bare["sourcePath"] = frame["sourcePath"] }
    if bare["rect"] == nil { bare["rect"] = frame["rect"] }
    oldest["frames"] = [bare]
    let oldFile = session.appendingPathComponent("Oldest.epscan")
    try JSONSerialization.data(withJSONObject: oldest, options: [.prettyPrinted]).write(to: oldFile)
    let reader = AppModel(libraryURL: library)
    reader.readOnly = true
    reader.loadProject(oldFile)
    try check(reader.errorText == nil && reader.frames.count == 1 && reader.frames.first?.id == model.frames.first?.id && reader.filmName == model.filmName,
      "a project with only the keys the first versions wrote opens, its frame and film as saved")
    // A version from the future is refused, plainly, not misread.
    var future = json
    future["version"] = 3
    let futureFile = session.appendingPathComponent("Future.epscan")
    try JSONSerialization.data(withJSONObject: future).write(to: futureFile)
    let refusing = AppModel(libraryURL: library)
    refusing.readOnly = true
    refusing.loadProject(futureFile)
    try check(refusing.errorText?.contains("不支持的工程版本") == true && refusing.frames.isEmpty,
      "a project from a newer version is refused with a message, not opened half-read")

    // An edit is in the file at once; a drag's steps 0.4 s after the last, without a save asked for.
    func onDisk() throws -> Double? {
      try JSONDecoder().decode(DeskProject.self, from: Data(contentsOf: file)).frames.first?.adjustments.exposure
    }
    model.change("曝光") { $0.exposure = 0.7 }
    let atOnce = try onDisk()
    model.change("曝光") { $0.exposure = 0.8 }
    model.change("曝光") { $0.exposure = 0.9 }
    model.change("曝光") { $0.exposure = 1.0 }
    settle(0.7)
    let afterDrag = try onDisk()
    try check(atOnce == 0.7 && afterDrag == 1.0,
      "an edit is written to the project at once and a drag's last step soon after, so quitting or a crash keeps them (\(atOnce ?? -1), \(afterDrag ?? -1))")
    // Written whole or not at all: no temporary file left beside it.
    let left = try FileManager.default.contentsOfDirectory(atPath: session.path).filter { $0.hasPrefix(".") && $0.contains("epscan") }
    try check(left.isEmpty, "the project is replaced in one step, never half written")
  }
}
