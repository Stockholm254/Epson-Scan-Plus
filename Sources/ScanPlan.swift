import Foundation

/// What a batch scan will take, shown before it starts: frames, pixels, time and disk space, so a
/// roll at 4800 dpi does not fill the disk or the afternoon by surprise. The time comes from this
/// scanner's own scans at that resolution once there are some.
struct ScanPlan: Equatable {
  var frames: Int
  /// Frames that already have a scan; it stays, and the new one is added next to it.
  var rescans: Int
  var dpi: Int
  /// The largest frame, in pixels, and whether the others are about the same size.
  var width: Int, height: Int
  var uniform: Bool
  var bitsPerChannel: Int
  var originalBytes: Double
  var exportBytes: Double
  var export: ExportFormat?
  var seconds: Double
  /// Whether the time comes from scans on this computer rather than the default rate.
  var measured: Bool
  var available: Double?

  var totalBytes: Double { originalBytes + exportBytes }
  /// With a little room to spare for the project file and thumbnails.
  var fits: Bool { available.map { totalBytes * 1.05 + 50e6 < $0 } ?? true }

  /// Per frame, a fixed part (positioning, lamp) and a part that grows with the pixels: a V850 on
  /// epson2 scans a 7.5 MP 35 mm frame at 2400 dpi in about 45 s.
  static let overhead = 8.0, defaultRate = 4.9
  static func rateKey(backend: String, dpi: Int) -> String { "\(backend)@\(dpi)" }
  /// Seconds per megapixel shown by one scan, after the fixed part.
  static func rate(seconds: Double, megapixels: Double) -> Double? {
    guard megapixels > 0.05, seconds.isFinite, seconds > 0 else { return nil }
    return max(0.2, (seconds - overhead) / megapixels)
  }

  static func make(
    _ frames: [FilmFrame], physicalMM: CGSize, dpi: Int, bitsPerChannel: Int, export: ExportFormat?,
    rate: Double?, available: Double?
  ) -> ScanPlan {
    let sizes = frames.map { f -> (Int, Int) in
      (Int((f.rect.width * physicalMM.width / 25.4 * Double(dpi)).rounded()),
        Int((f.rect.height * physicalMM.height / 25.4 * Double(dpi)).rounded()))
    }
    let pixels = sizes.map { Double($0.0 * $0.1) }
    let largest = sizes.max { $0.0 * $0.1 < $1.0 * $1.1 } ?? (0, 0)
    let biggest = pixels.max() ?? 0
    let total = pixels.reduce(0, +)
    let perSecond = rate ?? defaultRate
    return ScanPlan(
      frames: frames.count, rescans: frames.filter(\.hasFullResolution).count, dpi: dpi,
      width: largest.0, height: largest.1, uniform: pixels.allSatisfy { $0 > biggest * 0.95 },
      bitsPerChannel: bitsPerChannel,
      originalBytes: total * Double(bitsPerChannel * 3) / 8,
      exportBytes: export.map { total * $0.estimatedBytesPerPixel } ?? 0, export: export,
      seconds: Double(frames.count) * overhead + total / 1e6 * perSecond,
      measured: rate != nil, available: available)
  }

  static func duration(_ seconds: Double) -> String {
    if seconds < 90 { return "约 \(max(10, Int((seconds / 10).rounded()) * 10)) 秒" }
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 { return "约 \(minutes) 分钟" }
    return minutes % 60 == 0 ? "约 \(minutes / 60) 小时" : "约 \(minutes / 60) 小时 \(minutes % 60) 分钟"
  }
  static func bytes(_ value: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
  }

  /// The confirmation's text, one fact per line.
  var summary: String {
    var lines = [String]()
    if !fits, let available {
      lines.append("磁盘空间不足：需要约 \(Self.bytes(totalBytes))，只剩 \(Self.bytes(available))。")
    }
    lines.append("\(uniform ? "每张约" : "每张最大约") \(width) × \(height) 像素 · \(bitsPerChannel * 3)-bit 原始负片")
    if rescans > 0 {
      lines.append(rescans == frames ? "这些画面都已扫描过，会再扫一次；旧文件保留。" : "其中 \(rescans) 张已扫描过，会再扫一次；旧文件保留。")
    }
    lines.append("预计用时：\(Self.duration(seconds))" + (measured ? "（按本机 \(dpi) dpi 的实测）" : "（粗略估计，扫过之后按本机实测）"))
    lines.append(
      "占用空间：约 \(Self.bytes(totalBytes))"
        + (export.map { "（原始负片 \(Self.bytes(originalBytes)) + 自动导出的 \($0.title) 正片 \(Self.bytes(exportBytes))）" } ?? ""))
    if let available, fits { lines.append("可用空间：\(Self.bytes(available))") }
    return lines.joined(separator: "\n")
  }
}

extension ExportFormat {
  /// As measured on a 2400 dpi 35 mm frame: 16-bit TIFF uncompressed, 8-bit TIFF with LZW,
  /// PNG, and JPEG at the default quality.
  var estimatedBytesPerPixel: Double {
    switch self {
    case .tiff: return 6
    case .tiff8: return 1.9
    case .png: return 5.1
    case .jpeg: return 0.3
    }
  }
}
