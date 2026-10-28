import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Where a roll's pictures came from.
enum RollSource: String, CaseIterable {
  case scanner = "扫描"
  case camera = "翻拍"
  case files = "导入"
}

/// A roll in the library: a project folder, as its project file describes it.
struct RollEntry: Identifiable, Equatable {
  struct Frame: Equatable {
    let id: UUID
    let name: String
    let rect: NormalRect
    /// The frame's own file, for pictures imported one by one; nil for frames on the overview.
    let file: URL?
  }
  var id: String { project.path }
  let folder: URL
  let project: URL
  /// Its name, else when it was started.
  let title: String
  let named: Bool
  let film: String
  let date: Date
  let source: RollSource
  let frames: [Frame]
  /// Frames scanned (or imported) at full resolution.
  let fullResolution: Int
  /// Files in its Exports folder.
  let exported: Int
  let overview: URL?
  let notes: String
  /// In the folder versions before 0.4.9 used.
  let legacy: Bool
}

/// The library: every roll in the library folder, each a project folder as the app has always
/// saved them, read where it lies. Nothing is written into the library for it; the thumbnails the
/// app has rendered of a roll's positives are kept in the user's caches.
enum RollLibrary {
  static let projectExtensions = ["epscan", "filmdesk"]
  /// Where rendered positives are kept, a folder per roll; tests point it elsewhere.
  static var cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("local.epscan.mac").appendingPathComponent("Rolls")

  /// Every roll in `roots`, a folder each one level down, newest first. Folders without a project
  /// the app can read are left out; a folder in two roots is listed once.
  static func scan(_ roots: [(url: URL, legacy: Bool)]) -> [RollEntry] {
    let files = FileManager.default
    var seen = Set<String>()
    var entries = [RollEntry]()
    for root in roots {
      guard let folders = try? files.contentsOfDirectory(
        at: root.url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      else { continue }
      for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        let key = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard !seen.contains(key), let project = project(in: folder), let entry = entry(project, legacy: root.legacy)
        else { continue }
        seen.insert(key)
        entries.append(entry)
      }
    }
    return entries.sorted { $0.date > $1.date }
  }
  /// The folder's project: `Session.epscan` first, then any other this app or Film Desk saved.
  static func project(in folder: URL) -> URL? {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for preferred in [AppModel.projectFile, "Session.filmdesk"] where names.contains(preferred) {
      return folder.appendingPathComponent(preferred)
    }
    for ext in projectExtensions {
      if let name = names.sorted().first(where: { ($0 as NSString).pathExtension == ext && !$0.hasPrefix(".") }) {
        return folder.appendingPathComponent(name)
      }
    }
    return nil
  }
  static func entry(_ projectURL: URL, legacy: Bool = false) -> RollEntry? {
    guard let data = try? Data(contentsOf: projectURL),
      let p = try? JSONDecoder().decode(DeskProject.self, from: data), p.version == 1
    else { return nil }
    let folder = projectURL.deletingLastPathComponent()
    let files = FileManager.default
    let overview = ProjectFiles.resolve(p.overviewPath, relative: p.overviewFile, in: folder)
    let frames = p.frames.map { f -> RollEntry.Frame in
      let own = f.sourcePath.map { ProjectFiles.resolve($0, relative: f.sourceFile, in: folder) }
      return RollEntry.Frame(
        id: f.id, name: f.name, rect: f.rect,
        file: own.flatMap { $0 == overview ? nil : URL(fileURLWithPath: $0) })
    }
    let modified = (try? projectURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    let date = started(folder.lastPathComponent) ?? modified
    let name = p.rollName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let source: RollSource =
      p.source.flatMap(RollSource.init(rawValue:))
      ?? (!p.frames.isEmpty && p.frames.allSatisfy { $0.format == "导入" } ? .files : .scanner)
    let exports = folder.appendingPathComponent("Exports")
    let exported = ((try? files.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).count
    return RollEntry(
      folder: folder, project: projectURL, title: name.isEmpty ? Self.title(date) : name, named: !name.isEmpty,
      film: p.filmName, date: date, source: source, frames: frames,
      fullResolution: p.frames.filter(\.hasFullResolution).count, exported: exported,
      overview: files.fileExists(atPath: overview) ? URL(fileURLWithPath: overview) : nil,
      notes: p.notes ?? "", legacy: legacy)
  }
  /// When a roll was started, from the folder name new rolls get (`2026-10-25_174913_…`).
  static func started(_ folderName: String) -> Date? {
    guard folderName.count >= 17 else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd_HHmmss"
    return f.date(from: String(folderName.prefix(17)))
  }
  static func title(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "yyyy 年 M 月 d 日 HH:mm"
    return f.string(from: date)
  }

  // MARK: Thumbnails

  /// The cache folder for the roll in `folder`, named for where the roll is.
  static func cacheFolder(for folder: URL) -> URL {
    let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
    let digest = SHA256.hash(data: Data(path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    return cacheRoot.appendingPathComponent(digest)
  }
  /// Keeps the positives the app has rendered of the roll in `folder`, small, for the library to
  /// show; frames no longer in the roll are dropped.
  static func storePositives(_ images: [UUID: CGImage], folder: URL) {
    guard !images.isEmpty else { return }
    let dir = cacheFolder(for: folder)
    let files = FileManager.default
    try? files.createDirectory(at: dir, withIntermediateDirectories: true)
    let keep = Set(images.keys.map { $0.uuidString + ".jpg" })
    for name in (try? files.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(name) {
      try? files.removeItem(at: dir.appendingPathComponent(name))
    }
    for (id, image) in images {
      guard let small = scaled(image, maxPixels: 240) else { continue }
      let url = dir.appendingPathComponent(id.uuidString + ".jpg")
      guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
      CGImageDestinationAddImage(out, small, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
      CGImageDestinationFinalize(out)
    }
  }
  /// A picture of each of the roll's first `limit` frames: the positive the app last rendered of
  /// it, else the frame as it is on the film, a negative. Upright ones are laid across, turned
  /// clockwise as the light table turns an upright holder, so each fills its pocket of the strip.
  static func thumbnails(for entry: RollEntry, limit: Int = 36, maxPixels: Int = 160) -> [UUID: (image: CGImage, positive: Bool)] {
    var result = [UUID: (image: CGImage, positive: Bool)]()
    let cache = cacheFolder(for: entry.folder)
    var overview: CGImage?
    var loadedOverview = false
    for frame in entry.frames.prefix(limit) {
      let cached = cache.appendingPathComponent(frame.id.uuidString + ".jpg")
      if let src = CGImageSourceCreateWithURL(cached as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        result[frame.id] = (across(image), true)
        continue
      }
      let picture: CGImage?
      if let file = frame.file {
        picture = thumbnail(file, maxPixels: maxPixels * 3)
      } else {
        if !loadedOverview {
          overview = entry.overview.flatMap { thumbnail($0, maxPixels: 1600) }
          loadedOverview = true
        }
        picture = overview
      }
      guard let picture else { continue }
      let r = frame.rect
      let crop = CGRect(
        x: r.x * Double(picture.width), y: r.y * Double(picture.height),
        width: r.width * Double(picture.width), height: r.height * Double(picture.height)
      ).integral.intersection(CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
      guard !crop.isNull, crop.width >= 1, crop.height >= 1, let part = picture.cropping(to: crop),
        let small = scaled(part, maxPixels: maxPixels)
      else { continue }
      result[frame.id] = (across(small), false)
    }
    return result
  }
  /// `image` lying across: turned a quarter clockwise if it stands upright.
  static func across(_ image: CGImage) -> CGImage {
    guard image.height > image.width else { return image }
    return ImagePipeline.shared.turned(image, quarterTurns: 1, mirrored: false) ?? image
  }
  static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(src, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ] as CFDictionary)
  }
  static func scaled(_ image: CGImage, maxPixels: Int) -> CGImage? {
    let k = min(1, Double(maxPixels) / Double(max(image.width, image.height)))
    let w = max(1, Int((Double(image.width) * k).rounded())), h = max(1, Int((Double(image.height) * k).rounded()))
    if w == image.width && h == image.height && image.bitsPerComponent == 8 { return image }
    guard let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: ImagePipeline.shared.outputSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
  }
}
