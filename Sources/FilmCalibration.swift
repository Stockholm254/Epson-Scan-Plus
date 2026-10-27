import Foundation

/// A neutral patch picked for calibration: its raw negative value, with the film base and
/// encoding gamma the frame is converted with.
struct NeutralPoint: Equatable {
  var frame: UUID
  var value: RGB
  var base: RGB
  var gamma: Double
  /// Density above the film base, per channel.
  var density: [Double] {
    (0..<3).map { log10(max(1e-6, base.values[$0]) / max(1e-6, value.values[$0])) * gamma }
  }
}

/// Per-channel slopes and offsets from neutral points, after RawTherapee's film negative tool:
/// a neutral has one log exposure L in every channel, so each channel's density is
/// D_c = s_c·L + o_c. Green is the reference (o_g = 0, its slope from the starting preset),
/// so two neutrals of different brightness fix red and blue; more are fitted by least squares.
enum FilmCalibration {
  struct Fit: Equatable {
    var slopes: RGB
    /// In log exposure (density over slope): the kernel's own units.
    var offsets: RGB
    /// RMS misfit of red and blue, in density.
    var residual: Double
    /// Green density between the thinnest and densest point.
    var span: Double
  }
  static let minimumSpan = 0.3

  static func fit(_ points: [NeutralPoint], greenSlope: Double) throws -> Fit {
    guard points.count >= 2 else { throw DeskError.message("至少需要 2 个中性点。") }
    let d = points.map(\.density)
    let green = d.map { $0[1] }
    let span = green.max()! - green.min()!
    guard span >= minimumSpan else {
      throw DeskError.message(String(
        format: "中性点之间的明暗差太小：绿色密度只相差 %.2f。至少需要约 0.3（相当于 1 档曝光），最好在 0.6 以上。", span))
    }
    let exposure = green.map { $0 / greenSlope }
    let meanL = exposure.reduce(0, +) / Double(points.count)
    let varL = exposure.map { ($0 - meanL) * ($0 - meanL) }.reduce(0, +)
    var slopes = [Double](), offsets = [Double](), squares = 0.0
    for c in 0..<3 {
      guard c != 1 else {
        slopes.append(greenSlope)
        offsets.append(0)
        continue
      }
      let channel = d.map { $0[c] }
      let meanD = channel.reduce(0, +) / Double(points.count)
      let s = zip(exposure, channel).map { ($0 - meanL) * ($1 - meanD) }.reduce(0, +) / varL
      let o = meanD - s * meanL
      slopes.append(s)
      offsets.append(o / s)
      squares += zip(exposure, channel).map { pow($1 - (s * $0 + o), 2) }.reduce(0, +)
    }
    guard slopes.allSatisfy({ $0.isFinite && $0 >= 0.1 && $0 <= 2 }) else {
      throw DeskError.message(String(
        format: "解出的通道斜率超出合理范围（R %.2f · G %.2f · B %.2f）。请确认取的都是中性灰，没有过曝、没有落在片基或高光溢出处。",
        slopes[0], slopes[1], slopes[2]))
    }
    let residual = (squares / Double(2 * points.count)).squareRoot()
    // Two points always fit; from three on, an inconsistent point shows as misfit.
    guard points.count < 3 || residual <= maximumResidual else {
      throw DeskError.message(String(
        format: "中性点之间不一致（拟合残差 %.2f D）：可能有的点不是中性灰，或落在过曝处、阴影趾部。请清除后重新取点。", residual))
    }
    return Fit(slopes: RGB(slopes), offsets: RGB(offsets), residual: residual, span: span)
  }
  /// Grain and the film curve's gentle bend stay well under this; a tinted patch does not.
  static let maximumResidual = 0.08

  /// A preset for this scanner and film, named after the preset it started from.
  static func profile(from fit: Fit, basedOn base: FilmProfile, points: Int, scanner: String) -> FilmProfile {
    let date = Date().formatted(.iso8601.year().month().day())
    let film = base.id == "generic" ? "本机标定胶片" : base.name
    return FilmProfile(
      id: "\(base.id == "generic" ? "film" : base.id)-v850-\(UUID().uuidString.prefix(6).lowercased())",
      name: "\(film) · V850", aliases: [], iso: base.iso, process: base.process, sourceURL: "",
      publication: "本机标定 · \(scanner) · \(date) · \(points) 个中性点", slopes: fit.slopes,
      notes: String(
        format: "由 %d 个中性点反解红、蓝通道的斜率与中性偏移，绿色斜率沿用「%@」。拟合残差 %.3f D，绿色密度跨度 %.2f D。只适用于这台扫描仪和同一种胶片；自动白平衡关闭时按标定的中性偏移配平。",
        points, base.name, fit.residual, fit.span),
      offsets: fit.offsets)
  }
}
