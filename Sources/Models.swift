import CoreGraphics
import Foundation

struct RGB: Codable, Equatable {
  var r: Double
  var g: Double
  var b: Double
  static let one = RGB(r: 1, g: 1, b: 1)
  static let zero = RGB(r: 0, g: 0, b: 0)
  var values: [Double] { [r, g, b] }
  init(r: Double, g: Double, b: Double) {
    self.r = r
    self.g = g
    self.b = b
  }
  init(_ v: [Double]) { self.init(r: v[0], g: v[1], b: v[2]) }
}

struct NormalRect: Codable, Equatable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  static let full = NormalRect(x: 0, y: 0, width: 1, height: 1)
  var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
  init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  init(_ rect: CGRect) {
    let r = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    self.init(
      x: r.isNull ? 0 : r.minX, y: r.isNull ? 0 : r.minY, width: r.isNull ? 0 : r.width,
      height: r.isNull ? 0 : r.height)
  }
  func pixels(_ size: CGSize) -> CGRect {
    let requested = CGRect(
      x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height
    ).intersection(CGRect(origin: .zero, size: size))
    guard !requested.isNull else { return .zero }
    // Outward integral rounding could put a bright seam pixel back into a crop.
    // Tolerance preserves exact integer edges after normalized-coordinate math.
    let left = ceil(requested.minX - 1e-7)
    let top = ceil(requested.minY - 1e-7)
    return CGRect(
      x: left, y: top, width: max(0, floor(requested.maxX + 1e-7) - left),
      height: max(0, floor(requested.maxY + 1e-7) - top))
  }
  func relative(to parent: NormalRect) -> NormalRect {
    NormalRect(
      x: (x - parent.x) / parent.width, y: (y - parent.y) / parent.height,
      width: width / parent.width, height: height / parent.height)
  }
  func mapped(into parent: NormalRect) -> NormalRect {
    NormalRect(
      x: parent.x + x * parent.width, y: parent.y + y * parent.height, width: width * parent.width,
      height: height * parent.height)
  }
  func contains(_ other: NormalRect, tolerance: Double = 0.000001) -> Bool {
    other.x >= x - tolerance && other.y >= y - tolerance
      && other.x + other.width <= x + width + tolerance
      && other.y + other.height <= y + height + tolerance
  }
  func expanded(by fraction: Double) -> NormalRect {
    NormalRect(cg.insetBy(dx: -width * fraction, dy: -height * fraction))
  }
}

/// All crop, pick and orientation coordinates use a top-left origin, independent of CI's axes.
enum ImageGeometry {
  static func display(_ p: CGPoint, settings: Adjustments) -> CGPoint {
    var q: CGPoint
    switch ((settings.rotation % 4) + 4) % 4 {
    case 1: q = CGPoint(x: 1 - p.y, y: p.x)
    case 2: q = CGPoint(x: 1 - p.x, y: 1 - p.y)
    case 3: q = CGPoint(x: p.y, y: 1 - p.x)
    default: q = p
    }
    if settings.flipHorizontal == true { q.x = 1 - q.x }
    return q
  }
  static func raw(_ p: CGPoint, settings: Adjustments) -> CGPoint {
    var q = p
    if settings.flipHorizontal == true { q.x = 1 - q.x }
    switch ((settings.rotation % 4) + 4) % 4 {
    case 1: return CGPoint(x: q.y, y: 1 - q.x)
    case 2: return CGPoint(x: 1 - q.x, y: 1 - q.y)
    case 3: return CGPoint(x: 1 - q.y, y: q.x)
    default: return q
    }
  }
  static func transform(_ rect: NormalRect, settings: Adjustments, inverse: Bool = false)
    -> NormalRect
  {
    let corners = [
      CGPoint(x: rect.x, y: rect.y), CGPoint(x: rect.x + rect.width, y: rect.y),
      CGPoint(x: rect.x, y: rect.y + rect.height),
      CGPoint(x: rect.x + rect.width, y: rect.y + rect.height),
    ].map { inverse ? raw($0, settings: settings) : display($0, settings: settings) }
    let xs = corners.map(\.x)
    let ys = corners.map(\.y)
    return NormalRect(
      x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }
}

struct Adjustments: Codable, Equatable {
  var autoWhiteBalance = true
  var autoLevels = true
  var exposure = 0.0
  var warmth = 0.0
  var tint = 0.0
  var black = 0.0
  var white = 1.0
  var midtone = 1.0
  var contrast = 1.0
  var saturation = 1.0
  var inputGamma = 2.2
  var inputIsNegative = true
  var base: RGB? = nil
  /// The roll's film base, measured by the app between the frames; used when `base` is nil.
  var rollBase: RGB? = nil
  /// The roll's channel slopes, estimated by the app across all its frames; used unless the
  /// preset is calibrated for this scanner.
  var rollSlopes: RGB? = nil
  var manualBalance: RGB? = nil
  var rotation = 0
  var flipHorizontal: Bool? = nil
  // EV per channel; applied AFTER automatic estimation, never cancelled by it.
  var baseFine: RGB? = nil
  var neutralSample: RGB? = nil  // Encoded negative values, recalculated if the film/base changes.
  /// Deconvolution strength 0...1 from the scanner profile; nil uses the frame's default.
  var sharpening: Double? = nil
  /// RGB and per-channel tone curves, applied after conversion; nil leaves tones as they are.
  var curves: ToneCurves? = nil
  /// Turns the displayed picture 90°. Rotation is applied before the mirror, so a
  /// mirrored frame needs the opposite raw step to turn the same way on screen.
  mutating func turn(clockwise: Bool) {
    let step = clockwise == (flipHorizontal != true) ? 1 : 3
    rotation = ((rotation + step) % 4 + 4) % 4
  }
}

struct FilmProfile: Codable, Identifiable, Equatable {
  var id: String
  var name: String
  var aliases: [String]
  var iso: Int
  var process: String
  var sourceURL: String
  var publication: String
  var slopes: RGB
  var notes: String
  /// Calibrated presets only: each channel's neutral offset from green in log exposure, so a
  /// neutral reads the same in all channels. Used when auto white balance is off.
  var offsets: RGB? = nil
  /// Each channel's toe width in log exposure, where the density curve bends towards the base:
  /// D = D-min + slope · w · ln(1 + e^(x / w)), undone in the conversion. Only presets calibrated
  /// on this scanner from neutrals reaching into the shadows have one; nil keeps the straight line.
  var toe: RGB? = nil
  /// The toes of the Kodak data sheets' Status M curves, traced from their vector drawings (RMS
  /// under 0.03 D). Not applied as they are: on a V850 roll of Portra 160 the edges' channel ratios
  /// near the base did not follow them, and converting with them tinted the roll pink. Calibration
  /// takes green's from here and fits red's and blue's to the user's own neutrals.
  static let dataSheetToes: [String: RGB] = [
    "portra160": RGB(r: 0.160, g: 0.110, b: 0.150), "portra400": RGB(r: 0.165, g: 0.115, b: 0.145),
    "ektar100": RGB(r: 0.130, g: 0.100, b: 0.075),
  ]
  /// This film's data-sheet toe, also for a preset calibrated from it ("portra160-v850-…").
  var dataSheetToe: RGB? {
    Self.dataSheetToes[id] ?? Self.dataSheetToes.first { id.hasPrefix($0.key + "-v850-") }?.value
  }
  static let approximation = "使用官方特性曲线中段的人工读图近似；不是扫描仪 ICC 标定。片基与色阶由当前扫描估计。"
  static let builtins: [FilmProfile] = [
    FilmProfile(
      id: "portra160", name: "Kodak Portra 160", aliases: ["portra160", "portra 160", "柯达160"],
      iso: 160, process: "C-41 · 日光",
      sourceURL:
        "https://business.kodakmoments.com/sites/default/files/files/products/e4051_portra_160.pdf",
      publication: "Kodak E-4051 · 2016 · p.4", slopes: RGB(r: 0.52, g: 0.55, b: 0.62),
      notes: approximation),
    FilmProfile(
      id: "portra400", name: "Kodak Portra 400", aliases: ["portra400", "portra 400", "柯达400"],
      iso: 400, process: "C-41 · 日光",
      sourceURL:
        "https://imaging.kodakalaris.com/sites/default/files/files/resources/e4050_portra_400.pdf",
      publication: "Kodak E-4050 · 2016 · p.4", slopes: RGB(r: 0.55, g: 0.56, b: 0.64),
      notes: approximation),
    FilmProfile(
      id: "ektar100", name: "Kodak Ektar 100", aliases: ["ektar100", "ektar 100"], iso: 100,
      process: "C-41 · 日光",
      sourceURL:
        "https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4046_ektar_100.pdf",
      publication: "Kodak E-4046 · 2016 · p.4", slopes: RGB(r: 0.56, g: 0.57, b: 0.65),
      notes: approximation),
    FilmProfile(
      id: "generic", name: "通用彩色负片", aliases: ["generic", "通用"], iso: 0, process: "彩色负片",
      sourceURL: "", publication: "通用起点 · 未匹配文档", slopes: RGB(r: 0.55, g: 0.55, b: 0.55),
      notes: "未匹配到技术文档，使用相同通道斜率。可导入带来源链接的 JSON 胶片配置。"),
  ]
  /// A film's own slopes set each channel's contrast; only the generic preset, which has no film
  /// data, lets auto white balance stretch the channels to the scene instead.
  var setsChannelContrast: Bool { id != "generic" }
  func validate() throws {
    guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil, !name.isEmpty,
      slopes.values.allSatisfy({ $0.isFinite && $0 >= 0.1 && $0 <= 2.0 }),
      toe?.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 0.6 }) ?? true
    else { throw DeskError.message("胶片配置无效：ID 须为字母、数字、短横线或下划线，通道斜率须在 0.1–2.0，趾部宽度须在 0–0.6。") }
    if !sourceURL.isEmpty {
      guard let u = URL(string: sourceURL), ["https", "http"].contains(u.scheme ?? "") else {
        throw DeskError.message("技术文档链接必须为 http/https。")
      }
    }
  }
}

struct FilmFrame: Identifiable, Codable {
  var id = UUID()
  var name: String
  var rect: NormalRect
  var format: String
  var enabled = true
  var adjustments = Adjustments()
  var scanPath: String? = nil
  var scanRect: NormalRect? = nil  // Physical footprint of the immutable original scan.
  var initialRect: NormalRect? = nil
  // Imported full source; rect is applied non-destructively. scanPath is already cropped.
  var sourcePath: String? = nil
  var scanDPI: Int? = nil
  var sourceBits: Int? = nil
  /// `scanPath` and `sourcePath` relative to the project folder, written only in saved projects.
  var scanFile: String? = nil
  var sourceFile: String? = nil
  var captureRect: NormalRect { scanRect ?? rect }
  var hasFullResolution: Bool {
    sourcePath != nil || (scanPath != nil && captureRect.contains(rect))
  }
  var needsRescan: Bool { scanPath != nil && sourcePath == nil && !captureRect.contains(rect) }
}

struct DeskProject: Codable {
  var version = 1
  var overviewPath: String
  var overviewDPI: Double
  var physicalWidthMM: Double
  var physicalHeightMM: Double
  var filmName: String
  var profile: FilmProfile
  var scanDPI: Int
  var frames: [FilmFrame]
  var scanBackendID: String? = nil
  var overviewInputGamma: Double? = nil
  /// `overviewPath` relative to the project folder.
  var overviewFile: String? = nil
}

/// A project names its files by absolute path, which older versions read, and relative to its
/// folder, so the folder can be moved or renamed.
enum ProjectFiles {
  /// `path` relative to `folder`, when it lies inside it.
  static func relative(_ path: String, to folder: URL) -> String? {
    let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    guard file.hasPrefix(base + "/") else { return nil }
    return String(file.dropFirst(base.count + 1))
  }
  /// The file inside the folder under its relative name, else the saved absolute path, else, for
  /// an older project that was moved, the same trailing path components inside the folder.
  static func resolve(_ path: String, relative: String?, in folder: URL) -> String {
    let files = FileManager.default
    if let relative {
      let inside = folder.appendingPathComponent(relative).path
      if files.fileExists(atPath: inside) { return inside }
    }
    if files.fileExists(atPath: path) { return path }
    let parts = URL(fileURLWithPath: path).pathComponents
    for n in stride(from: min(3, parts.count - 1), through: 1, by: -1) {
      let inside = folder.appendingPathComponent(parts.suffix(n).joined(separator: "/")).path
      if files.fileExists(atPath: inside) { return inside }
    }
    return path
  }
}

enum DeskError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let s) = self { return s }
    return nil
  }
}

enum CanvasTool: String, CaseIterable {
  case select = "选择"
  case crop = "画框"
  case base = "片基"
  case neutral = "中性灰"
  case loupe = "放大镜"
  case calibrate = "标定中性点"
  case it8 = "IT8 色卡"

  /// Each tool's SF Symbol. The two samplers differ in glyph and carry a label as well: the
  /// film base is the orange mask, the neutral a grey in the picture.
  var symbol: String {
    switch self {
    case .select: return "cursorarrow"
    case .crop: return "crop"
    case .base: return "eyedropper.full"
    case .neutral: return "eyedropper"
    case .calibrate: return "target"
    case .loupe: return "magnifyingglass"
    case .it8: return "squareshape.split.3x3"
    }
  }
  /// Shown next to the symbol in the toolbar.
  var label: String? {
    switch self {
    case .base: return "片基"
    case .neutral: return "中性灰"
    default: return nil
    }
  }
  /// The key that picks the tool while the canvas has focus, as in other image editors.
  var shortcut: String? {
    switch self {
    case .select: return "v"
    case .crop: return "c"
    case .base: return "b"
    case .neutral: return "n"
    case .loupe: return "z"
    case .calibrate, .it8: return nil
    }
  }
  var help: String {
    let what: String
    switch self {
    case .select: what = "选择：点选、移动画框，双击进入单张"
    case .crop: what = "画框：在接触表上拖出新画框；单张中裁切"
    case .base: what = "取片基：点未曝光的橙色片基，作为去色罩的基准"
    case .neutral: what = "取中性灰：点画面中应为灰色的地方，校正白平衡"
    case .loupe: what = "放大镜：把鼠标处放大查看"
    case .calibrate: what = "标定中性点：点选灰卡等中性灰，生成本机预设"
    case .it8: what = "IT8 色卡：按提示点色卡上的 6 个点"
    }
    return what + (shortcut.map { " · \($0.uppercased())" } ?? "")
  }
}
enum FilmFormat: String, CaseIterable {
  case auto = "自动"
  case mm135 = "135"
  case medium = "120"
  case six45 = "120 · 6×4.5"
  case six6 = "120 · 6×6"
  case six7 = "120 · 6×7"
  case six9 = "120 · 6×9"
}

func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, x)) }

extension CGRect {
  var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
