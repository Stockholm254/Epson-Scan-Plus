import CoreGraphics
import Foundation

/// What a frame was last exported with, kept with the roll and not with the frame's settings, so
/// ⌘Z never takes it back. The strip marks each frame exported as it is now, or changed since: an
/// export again would write it differently.
struct ExportStamp: Codable, Equatable {
  var at: Date
  /// The file written.
  var file: String
  /// The frame's own settings when it was written.
  var settings: Adjustments
  /// The preset it was converted with (`FilmProfile.id`).
  var film: String
}

/// A frame as the strip marks it for exporting.
enum ExportMark: Hashable {
  /// Never exported.
  case notExported
  /// Asked for, not yet written.
  case waiting
  case writing
  /// Written with the settings it has now.
  case exported
  /// Written, then changed: an export again would differ.
  case changed
}

/// The exports running, all together: frames written of all asked, the one being written and
/// those still to come. Its numbers go back to nothing once the last export ends.
struct ExportProgress: Equatable {
  var total = 0
  var done = 0
  var writing: UUID?
  var writingName: String?
  var waiting = Set<UUID>()
  /// A contact sheet is being put together: `done` counts its frames.
  var sheet = false
  var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
  /// What the Dock icon says while several frames go out.
  var badge: String? { total >= 2 ? "\(done)/\(total)" : nil }
  var label: String {
    let count = "\(min(done + (writing == nil ? 0 : 1), total)) / \(total)"
    if sheet { return "接触表 · " + count }
    return "导出 " + count + (writingName.map { " · 第 \($0) 张" } ?? "")
  }
}

/// Asked to stop by the main thread, read between frames on the export queue.
final class StopFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var stopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func stop() {
    lock.lock()
    value = true
    lock.unlock()
  }
}

/// Thrown between frames when the export was asked to stop.
struct ExportStopped: Error {}

/// How big an export comes out, before it is written.
enum ExportEstimate {
  /// Bytes of one file of `pixels` in `format`: exact for TIFF, which is written uncompressed; PNG
  /// and JPEG as film scans usually compress (grain does not compress well).
  static func bytes(_ pixels: CGSize, format: ExportFormat, quality: Double) -> Double {
    let n = Double(pixels.width * pixels.height)
    switch format {
    case .tiff: return n * 6
    case .tiff8: return n * 3
    case .png: return n * 6 * 0.62
    case .jpeg: return n * 3 * (0.05 + 0.32 * pow(max(0, min(1, quality)), 6))
    }
  }
  static func text(_ bytes: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
  /// The space free on the volume `folder` is on, or on the nearest folder above it that is there.
  static func freeSpace(at folder: URL) -> Double? {
    var at = folder
    while !FileManager.default.fileExists(atPath: at.path), at.pathComponents.count > 1 { at = at.deletingLastPathComponent() }
    let values = try? at.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage.map(Double.init)
  }
}

/// When something was done, as a Chinese sentence says it, whatever language the system's is:
/// 刚才, 5 分钟前, 今天 14:20, 昨天 09:05, 11 月 3 日.
enum WhenSaid {
  static func ago(_ date: Date, now: Date = Date()) -> String {
    let s = now.timeIntervalSince(date)
    if s < 60 { return "刚才" }
    if s < 3600 { return "\(Int(s / 60)) 分钟前" }
    let calendar = Calendar(identifier: .gregorian)
    let hm = calendar.dateComponents([.hour, .minute], from: date)
    let clock = String(format: "%02d:%02d", hm.hour ?? 0, hm.minute ?? 0)
    if calendar.isDate(date, inSameDayAs: now) { return "今天 " + clock }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天 " + clock }
    let md = calendar.dateComponents([.year, .month, .day], from: date)
    let thisYear = calendar.component(.year, from: now) == md.year
    return (thisYear ? "" : "\(md.year ?? 0) 年 ") + "\(md.month ?? 0) 月 \(md.day ?? 0) 日"
  }
}
