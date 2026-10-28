import Foundation

/// How long one pass of the scan head takes, as measured on the V850 over epson2 at 2400 dpi
/// (seven scans: one frame, a strip of three, a row of three): a fixed part for positioning and
/// calibration, longer for a wider window, then the lines, read at about 102 a second, or the
/// data, about 3.5 MB a second, whichever is slower. A narrow window is held up by the head, a
/// wide one by the data.
enum ScanTiming {
  static let lineRate = 102.0, byteRate = 3.5e6
  static func fixed(widthMM: Double) -> Double { 8.5 + 0.085 * widthMM }
  static func seconds(widthMM: Double, heightMM: Double, dpi: Int, bytesPerPixel: Double) -> Double {
    let pixels = widthMM / 25.4 * Double(dpi), lines = heightMM / 25.4 * Double(dpi)
    return fixed(widthMM: widthMM) + max(lines / lineRate, pixels * lines * bytesPerPixel / byteRate)
  }
}

/// Frames scanned together in one pass of the head: neighbours side by side in a row of the
/// holder, when one pass across them is quicker than one each. A pass is cut into each frame's
/// own original afterwards, so a frame scanned this way is kept as if scanned alone.
enum ScanPasses {
  /// Under the helper's 768 MB limit for one pass, with room to spare.
  static let maxBytes = 700.0 * 1024 * 1024
  /// Frames whose heights overlap by more than this share of the shorter lie in one row.
  static let rowOverlap = 0.6

  static func union(_ frames: [FilmFrame]) -> NormalRect {
    let r = frames.map(\.rect.cg).reduce(CGRect.null) { $0.union($1) }
    return NormalRect(r)
  }
  static func seconds(_ pass: [FilmFrame], physicalMM: CGSize, dpi: Int, bytesPerPixel: Double) -> Double {
    let r = union(pass)
    return ScanTiming.seconds(
      widthMM: r.width * physicalMM.width, heightMM: r.height * physicalMM.height, dpi: dpi, bytesPerPixel: bytesPerPixel)
  }
  static func bytes(_ pass: [FilmFrame], physicalMM: CGSize, dpi: Int, bytesPerPixel: Double) -> Double {
    let r = union(pass), ppmm = Double(dpi) / 25.4
    return (r.width * physicalMM.width * ppmm) * (r.height * physicalMM.height * ppmm) * bytesPerPixel
  }
  /// The batch's passes, top row first. Without `rows`, one pass a frame in the order given.
  static func group(_ frames: [FilmFrame], physicalMM: CGSize, dpi: Int, bytesPerPixel: Double, rows: Bool) -> [[FilmFrame]] {
    guard rows, frames.count > 1 else { return frames.map { [$0] } }
    func overlap(_ a: NormalRect, _ b: NormalRect) -> Double {
      let shared = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
      return shared / max(1e-9, min(a.height, b.height))
    }
    var rest = frames.sorted { $0.rect.y < $1.rect.y }
    var passes = [[FilmFrame]]()
    while let first = rest.first {
      let row = rest.filter { overlap(first.rect, $0.rect) > rowOverlap }
      rest.removeAll { f in row.contains { $0.id == f.id } }
      passes += quickest(row.sorted { $0.rect.x < $1.rect.x }, physicalMM: physicalMM, dpi: dpi, bytesPerPixel: bytesPerPixel)
    }
    return passes
  }
  /// The row cut into runs of neighbours that scan it soonest; a run only when it is quicker.
  private static func quickest(_ row: [FilmFrame], physicalMM: CGSize, dpi: Int, bytesPerPixel: Double) -> [[FilmFrame]] {
    var best = [0.0] + Array(repeating: Double.infinity, count: row.count), from = Array(repeating: 0, count: row.count + 1)
    for end in 1...row.count {
      for start in 0..<end {
        let run = Array(row[start..<end])
        guard run.count == 1 || bytes(run, physicalMM: physicalMM, dpi: dpi, bytesPerPixel: bytesPerPixel) <= maxBytes else { continue }
        // A single frame wins a tie: the run has to be strictly quicker.
        let t = best[start] + seconds(run, physicalMM: physicalMM, dpi: dpi, bytesPerPixel: bytesPerPixel) + (run.count > 1 ? 0.5 : 0)
        if t < best[end] {
          best[end] = t
          from[end] = start
        }
      }
    }
    var runs = [[FilmFrame]](), end = row.count
    while end > 0 {
      runs.insert(Array(row[from[end]..<end]), at: 0)
      end = from[end]
    }
    return runs
  }
}

/// What a batch scan will take, shown before it starts: frames, pixels, time and disk space, so a
/// roll at 4800 dpi does not fill the disk or the afternoon by surprise. The time comes from this
/// scanner's own scans at that resolution once there are some.
struct ScanPlan: Equatable {
  var frames: Int
  /// Passes of the scan head: fewer than frames when rows are scanned together.
  var passes: Int
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

  static func speedKey(backend: String, dpi: Int) -> String { "\(backend)@\(dpi)" }
  /// How this scanner's pass compared with `ScanTiming`: actual over predicted, kept sane.
  static func speed(seconds: Double, predicted: Double) -> Double? {
    guard seconds.isFinite, seconds > 0, predicted > 1 else { return nil }
    return min(3, max(0.3, seconds / predicted))
  }

  /// `speed` is this scanner's measured speed against `ScanTiming` at the resolution, if known.
  static func make(
    _ passes: [[FilmFrame]], physicalMM: CGSize, dpi: Int, bitsPerChannel: Int, export: ExportFormat?,
    speed: Double?, available: Double?
  ) -> ScanPlan {
    let frames = passes.flatMap { $0 }
    let bytesPerPixel = Double(bitsPerChannel * 3) / 8
    let seconds = passes.map { ScanPasses.seconds($0, physicalMM: physicalMM, dpi: dpi, bytesPerPixel: bytesPerPixel) }.reduce(0, +)
    let sizes = frames.map { f -> (Int, Int) in
      (Int((f.rect.width * physicalMM.width / 25.4 * Double(dpi)).rounded()),
        Int((f.rect.height * physicalMM.height / 25.4 * Double(dpi)).rounded()))
    }
    let pixels = sizes.map { Double($0.0 * $0.1) }
    let largest = sizes.max { $0.0 * $0.1 < $1.0 * $1.1 } ?? (0, 0)
    let biggest = pixels.max() ?? 0
    let total = pixels.reduce(0, +)
    return ScanPlan(
      frames: frames.count, passes: passes.count, rescans: frames.filter(\.hasFullResolution).count, dpi: dpi,
      width: largest.0, height: largest.1, uniform: pixels.allSatisfy { $0 > biggest * 0.95 },
      bitsPerChannel: bitsPerChannel,
      originalBytes: total * bytesPerPixel,
      exportBytes: export.map { total * $0.estimatedBytesPerPixel } ?? 0, export: export,
      seconds: seconds * (speed ?? 1), measured: speed != nil, available: available)
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
    if passes < frames { lines.append("按行合并扫描：\(frames) 张分 \(passes) 次扫完，扫完后分成每张的原始文件。") }
    lines.append("预计用时：\(Self.duration(seconds))" + (measured ? "（按本机 \(dpi) dpi 的实测）" : "（按 V850 实测估计，扫过之后按本机校准）"))
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
