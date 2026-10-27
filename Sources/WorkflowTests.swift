import AppKit
import Foundation

/// Undo and redo, projects that move, and what exports carry: colour space, metadata and names.
enum WorkflowTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.2) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let pipe = ImagePipeline.shared
    let root = folder.appendingPathComponent("workflow", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func image(_ w: Int, _ h: Int, _ color: (CGFloat, CGFloat, CGFloat)) -> CGImage {
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
      ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
      return ctx.makeImage()!
    }
    // A project folder: an overview, and one frame with its own scan in Originals.
    func makeProject(_ name: String, relative: Bool) throws -> URL {
      let dir = root.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(at: dir.appendingPathComponent("Originals"), withIntermediateDirectories: true)
      let overview = dir.appendingPathComponent("overview.png"), scan = dir.appendingPathComponent("Originals/01_scan.tiff")
      try pipe.savePNG(image(600, 400, (0.6, 0.4, 0.3)), to: overview)
      try pipe.saveTIFF(image(240, 160, (0.55, 0.35, 0.25)), to: scan, dpi: 2400)
      var frames = (0..<3).map { i in
        FilmFrame(name: String(format: "%02d", i + 1), rect: NormalRect(x: 0.05 + Double(i) * 0.31, y: 0.2, width: 0.28, height: 0.5), format: "135")
      }
      frames[0].scanPath = scan.path
      frames[0].scanDPI = 2400
      var project = DeskProject(
        overviewPath: overview.path, overviewDPI: 150, physicalWidthMM: 101.6, physicalHeightMM: 67.7,
        filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: frames)
      if relative {
        project.overviewFile = "overview.png"
        project.frames[0].scanFile = "Originals/01_scan.tiff"
      }
      let url = dir.appendingPathComponent("Session.filmdesk")
      try JSONEncoder().encode(project).write(to: url)
      return url
    }

    // Undo and redo.
    let model = AppModel(libraryURL: root)
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.undoManager = undo
    model.loadProject(try makeProject("undo", relative: true))
    for _ in 0..<30 where model.rendering { settle(0.1) }
    try check(!undo.canUndo, "a project opens with no edits to undo")
    let first = model.frames[0].id
    model.select(first)
    model.change("曝光 · EV") { $0.exposure = 0.5 }
    model.change("曝光 · EV") { $0.exposure = 0.8 }
    try check(undo.undoActionName == "曝光 · EV", "the Edit menu names the edit: \(undo.undoActionName)")
    let estimate = RGB(r: 0.42, g: 0.55, b: 0.61)
    model.frames[0].adjustments.rollSlopes = estimate
    undo.undo()
    try check(model.frames[0].adjustments.exposure == 0, "dragging one fader is one step to undo")
    try check(model.frames[0].adjustments.rollSlopes == estimate, "undo keeps the roll estimate measured since")
    undo.redo()
    try check(model.frames[0].adjustments.exposure == 0.8, "and redo brings the edit back")
    let rect = model.frames[1].rect
    var moved = rect
    moved.x += 0.02
    model.setRect(model.frames[1].id, rect: moved)
    undo.undo()
    try check(model.frames[1].rect == rect, "undo puts a frame box back")
    model.select(model.frames[2].id)
    let removed = model.frames[2].id
    model.removeSelected()
    try check(model.frames.count == 2, "a frame is deleted")
    undo.undo()
    try check(model.frames.count == 3 && model.frames[2].id == removed, "undo brings a deleted frame back")
    model.addFrame(NormalRect(x: 0.1, y: 0.75, width: 0.2, height: 0.2))
    undo.undo()
    try check(model.frames.count == 3, "undo takes an added frame away")
    model.setAllEnabled(false)
    undo.undo()
    try check(model.frames.allSatisfy(\.enabled), "undo restores the ticks")
    model.select(first)
    model.change("输入设置") {
      $0.inputGamma = 1
      $0.rotation = 1
    }
    model.change("曝光 · EV") { $0.exposure = 0.5 }
    model.resetAdjustments()
    let reset = model.frames[0].adjustments
    try check(reset.exposure == 0 && reset.inputGamma == 1 && reset.rotation == 1 && reset.rollSlopes == estimate,
      "reset clears the settings but keeps the input gamma, the orientation and the roll estimate")
    undo.undo()
    try check(model.frames[0].adjustments.exposure == 0.5, "and can be undone")
    let preset = model.profile
    model.chooseProfile(FilmProfile.builtins[1])
    undo.undo()
    try check(model.profile == preset && model.filmName == preset.name, "undo puts the film preset back")
    model.loadProject(try makeProject("undo-2", relative: true))
    try check(!undo.canUndo, "opening another project clears the history")

    // Projects that move.
    let saved = try makeProject("saved", relative: false)
    let saver = AppModel(libraryURL: root)
    saver.loadProject(saved)
    saver.saveProject()
    let written = try JSONDecoder().decode(DeskProject.self, from: Data(contentsOf: saved))
    try check(written.overviewFile == "overview.png" && written.frames[0].scanFile == "Originals/01_scan.tiff",
      "projects also save their files relative to the folder")
    try check(written.overviewPath.hasPrefix("/") && written.frames[0].scanPath?.hasPrefix("/") == true,
      "and keep the absolute paths older versions read")
    for (name, relative) in [("moved-new", true), ("moved-old", false)] {
      let made = try makeProject(name, relative: relative)
      let away = root.appendingPathComponent(name + "-elsewhere", isDirectory: true)
      try FileManager.default.moveItem(at: made.deletingLastPathComponent(), to: away)
      let opened = AppModel(libraryURL: root)
      opened.loadProject(away.appendingPathComponent("Session.filmdesk"))
      let scan = opened.frames.first?.scanPath ?? ""
      let inside = scan.hasPrefix(away.resolvingSymlinksInPath().path) || scan.hasPrefix(away.path)
      try check(opened.errorText == nil && opened.overview != nil && inside,
        relative ? "a moved project finds its files by their relative names" : "an older moved project finds its files by name")
      try check(FileManager.default.fileExists(atPath: scan) && opened.status.contains("已移动"), "and says it was moved")
    }

    // Colour spaces: a red that the saturation control pushes beyond sRGB.
    var vivid = Adjustments()
    vivid.inputIsNegative = false
    vivid.autoLevels = false
    vivid.autoWhiteBalance = false
    vivid.inputGamma = 1
    vivid.saturation = 1.5
    let red = image(8, 8, (0.8, 0.05, 0.05))
    func exported(_ space: ExportColorSpace, _ format: ExportFormat = .tiff) throws -> URL {
      let url = root.appendingPathComponent("vivid-\(space.rawValue).\(format.fileExtension)")
      try? FileManager.default.removeItem(at: url)
      try pipe.export(red, settings: vivid, profile: FilmProfile.builtins[0], url: url, format: format, dpi: 300, colorSpace: space)
      return url
    }
    /// The exported pixel as extended sRGB, through its embedded profile.
    func readBack(_ url: URL) -> [Double] {
      let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
      let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)!
      var px = [Float](repeating: 0, count: 4)
      let ctx = CGContext(
        data: &px, width: 1, height: 1, bitsPerComponent: 32, bytesPerRow: 16,
        space: CGColorSpace(name: CGColorSpace.extendedSRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)!
      ctx.draw(cg, in: CGRect(x: -3, y: -3, width: cg.width, height: cg.height))
      return px.prefix(3).map(Double.init)
    }
    func profileName(_ url: URL) -> String {
      let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
      return props[kCGImagePropertyProfileName] as? String ?? ""
    }
    let narrow = readBack(try exported(.sRGB)), wide = readBack(try exported(.proPhoto))
    try check(narrow[1] >= -0.002 && wide[1] < -0.01,
      String(format: "ProPhoto keeps a red beyond sRGB (green %.3f; clipped to %.3f in sRGB)", wide[1], narrow[1]))
    for space in [ExportColorSpace.displayP3, .adobeRGB, .proPhoto] {
      let name = profileName(try exported(space))
      try check(!name.isEmpty && name != profileName(try exported(.sRGB)), "\(space.title) exports carry their own ICC profile: \(name)")
    }
    let plain = image(8, 8, (0.5, 0.4, 0.3))
    var straight = vivid
    straight.saturation = 1
    func pixel(_ space: ExportColorSpace, _ format: ExportFormat) throws -> [Double] {
      let url = root.appendingPathComponent("plain-\(space.rawValue).\(format.fileExtension)")
      try? FileManager.default.removeItem(at: url)
      try pipe.export(plain, settings: straight, profile: FilmProfile.builtins[0], url: url, format: format, dpi: 300, colorSpace: space)
      return readBack(url)
    }
    let reference = try pixel(.sRGB, .tiff)
    for space in [ExportColorSpace.displayP3, .adobeRGB, .proPhoto] {
      let p = try pixel(space, .tiff)
      try check(zip(p, reference).allSatisfy { abs($0 - $1) < 1.5 / 255 }, "a colour inside sRGB looks the same in \(space.title)")
    }
    try check(zip(try pixel(.displayP3, .jpeg), reference).allSatisfy { abs($0 - $1) < 3 / 255 }, "also in a Display P3 JPEG")

    // Metadata and names.
    let tagged = root.appendingPathComponent("tagged.jpg")
    try pipe.export(
      plain, settings: straight, profile: FilmProfile.builtins[0], url: tagged, format: .jpeg, dpi: 2400,
      metadata: ExportMetadata(
        title: "Kodak Portra 160 · 09", description: "Kodak Portra 160 · 第 09 张 · 2400 dpi", keywords: ["Kodak Portra 160", "135"],
        scanner: ("EPSON", "Perfection V800/V850"), scanned: Date(timeIntervalSince1970: 1_793_000_000), software: "Epson Scan plus 0.4.8"))
    let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(tagged as CFURL, nil)!, 0, nil) as? [CFString: Any] ?? [:]
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
    try check(tiff[kCGImagePropertyTIFFMake] as? String == "EPSON" && (tiff[kCGImagePropertyTIFFModel] as? String)?.contains("V850") == true
      && (tiff[kCGImagePropertyTIFFSoftware] as? String)?.hasPrefix("Epson Scan plus") == true, "exports name the scanner and the app")
    try check((exif[kCGImagePropertyExifDateTimeDigitized] as? String)?.hasPrefix("2026:") == true && exif[kCGImagePropertyExifDateTimeOriginal] == nil,
      "and the scan date, but not a capture date they cannot know")
    try check((iptc[kCGImagePropertyIPTCKeywords] as? [String])?.contains("Kodak Portra 160") == true
      && (iptc[kCGImagePropertyIPTCCaptionAbstract] as? String)?.contains("第 09 张") == true, "the film and frame are keywords and caption")
    try check(ExportNaming.name("{name} {frame} {date}", film: "portra160", name: "Kodak Portra 160", frame: "09", roll: "r", date: Date(timeIntervalSince1970: 1_793_000_000))
      == "Kodak Portra 160 09 20261026" && ExportNaming.name("{roll}/{frame}", film: "f", name: "n", frame: "09", roll: "a:b", date: nil) == "a_b_09"
      && ExportNaming.name("  ", film: "portra160", name: "n", frame: "09", roll: "", date: nil) == "portra160_09",
      "file names fill the template and never make folders")
    let exporter = AppModel(libraryURL: root)
    exporter.loadProject(try makeProject("names", relative: true))
    let out = root.appendingPathComponent("names-out", isDirectory: true)
    var done = 0
    for _ in 0..<2 { exporter.export(items: [exporter.frames[0]], to: out) { done += 1 } }
    for _ in 0..<100 where done < 2 { settle(0.1) }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path))?.filter { $0.hasSuffix(".tif") }.sorted() ?? []
    let id = FilmProfile.builtins[0].id
    try check(files == ["\(id)_01-2.tif", "\(id)_01.tif"], "a second export of a frame gets a number, never overwriting: \(files)")
  }
}
