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

/// The film's toe: below the straight part of the curve, density bends towards the base. With
/// u = density / slope and the toe width w, u = w · ln(1 + e^(x / w)), so the log exposure is
/// x = u + w · ln(1 − e^(−u / w)). The kernel computes the same. Within about 4 w of the base the
/// expansion stops, so grain on unexposed film is not blown up.
enum FilmToe {
  static let floor = 0.02
  /// Density over slope for log exposure `x`: the film's curve, for synthetic negatives.
  static func density(_ x: Double, width w: Double) -> Double {
    guard w > 0 else { return x }
    return max(x, 0) + w * log(1 + exp(-abs(x) / w))
  }
  static func exposure(_ u: Double, width w: Double) -> Double {
    guard w > 0 else { return u }
    return u + w * log(max(1 - exp(-u / w), floor))
  }
  /// d exposure / d u: how much the toe stretches a density step there.
  static func stretch(_ u: Double, width w: Double) -> Double {
    guard w > 0 else { return 1 }
    let k = 1 - exp(-u / w)
    return k > floor ? 1 / k : 1
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
    /// Each channel's toe width, when the neutrals reached into the shadows.
    var toe: RGB? = nil
  }
  static let minimumSpan = 0.3
  /// Neutrals needed to fit red's and blue's toes, and how near the base green must reach.
  static let toePoints = 4, toeDensity = 0.25

  /// `curve` is the film's data-sheet toe, whose green is taken as it is.
  static func fit(_ points: [NeutralPoint], greenSlope: Double, curve: RGB? = nil) throws -> Fit {
    guard points.count >= 2 else { throw DeskError.message("至少需要 2 个中性点。") }
    let d = points.map(\.density)
    let green = d.map { $0[1] }
    let span = green.max()! - green.min()!
    guard span >= minimumSpan else {
      throw DeskError.message(String(
        format: "中性点之间的明暗差太小：绿色密度只相差 %.2f。至少需要约 0.3（相当于 1 档曝光），最好在 0.6 以上。", span))
    }
    if let curve, points.count >= toePoints, green.min()! < toeDensity {
      return try fit(d, span: span, greenSlope: greenSlope, greenToe: curve.g)
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
  /// Neutrals reaching into the shadows also show where red and blue bend from their straight lines.
  /// Green follows the data sheet's toe; for red and blue the slope and toe width are searched
  /// together, for the pair whose exposures run parallel to green's, offset by o.
  private static func fit(_ d: [[Double]], span: Double, greenSlope: Double, greenToe: Double) throws -> Fit {
    let exposure = d.map { FilmToe.exposure($0[1] / greenSlope, width: greenToe) }
    var slopes = [Double](), offsets = [Double](), widths = [Double](), squares = 0.0
    for c in 0..<3 {
      guard c != 1 else {
        slopes.append(greenSlope)
        offsets.append(0)
        widths.append(greenToe)
        continue
      }
      func misfit(_ s: Double, _ w: Double) -> (error: Double, offset: Double) {
        let e = d.map { FilmToe.exposure($0[c] / s, width: w) }
        let o = zip(e, exposure).map { $0 - $1 }.reduce(0, +) / Double(d.count)
        // In density, as the straight-line fit reports it.
        return (zip(e, exposure).map { pow(($0 - $1 - o) * s, 2) }.reduce(0, +), o)
      }
      var best = (s: 0.0, w: 0.0, error: Double.infinity, offset: 0.0)
      for w in stride(from: 0.0, through: 0.5, by: 0.01) {
        for s in stride(from: 0.1, through: 2.0, by: 0.004) {
          let m = misfit(s, w)
          if m.error < best.error { best = (s, w, m.error, m.offset) }
        }
      }
      for w in stride(from: max(0, best.w - 0.01), through: best.w + 0.01, by: 0.001) {
        for s in stride(from: best.s - 0.004, through: best.s + 0.004, by: 0.0001) where s > 0.1 {
          let m = misfit(s, w)
          if m.error < best.error { best = (s, w, m.error, m.offset) }
        }
      }
      slopes.append(best.s)
      offsets.append(best.offset)
      widths.append(best.w)
      squares += best.error
    }
    guard slopes.allSatisfy({ $0.isFinite && $0 > 0.1 && $0 < 2 }) else {
      throw DeskError.message(String(
        format: "解出的通道斜率超出合理范围（R %.2f · G %.2f · B %.2f）。请确认取的都是中性灰，没有过曝、没有落在片基或高光溢出处。",
        slopes[0], slopes[1], slopes[2]))
    }
    let residual = (squares / Double(2 * d.count)).squareRoot()
    guard d.count < 3 || residual <= maximumResidual else {
      throw DeskError.message(String(
        format: "中性点之间不一致（拟合残差 %.2f D）：可能有的点不是中性灰，或落在过曝处。请清除后重新取点。", residual))
    }
    return Fit(slopes: RGB(slopes), offsets: RGB(offsets), residual: residual, span: span, toe: RGB(widths))
  }
  /// Grain and the film curve's gentle bend stay well under this; a tinted patch does not.
  static let maximumResidual = 0.08

  /// A preset for this scanner and film, named after the preset it started from.
  /// The preset made from a fit: for the V850, or with `copyStand` for the camera and its copy light,
  /// `scanner` then naming the camera.
  static func profile(from fit: Fit, basedOn base: FilmProfile, points: Int, scanner: String, copyStand: Bool = false) -> FilmProfile {
    let date = Date().formatted(.iso8601.year().month().day())
    let film = base.id == "generic" ? "本机标定胶片" : base.name
    let applies = copyStand
      ? "只适用于这台相机、这组翻拍灯和同一种胶片；灯的亮度配比怎么调都不影响。标定时去串色是开着的，用时也开着"
      : "只适用于这台扫描仪和同一种胶片"
    return FilmProfile(
      id: "\(base.id == "generic" ? "film" : base.id)-\(copyStand ? "copy" : "v850")-\(UUID().uuidString.prefix(6).lowercased())",
      name: "\(film) · \(copyStand ? "翻拍" : "V850")", aliases: [], iso: base.iso, process: base.process, sourceURL: "",
      publication: "\(copyStand ? "翻拍标定" : "本机标定") · \(scanner) · \(date) · \(points) 个中性点", slopes: fit.slopes,
      notes: String(
        format: "由 %d 个中性点反解红、蓝通道的斜率与中性偏移，绿色斜率沿用「%@」。拟合残差 %.3f D，绿色密度跨度 %.2f D。%@；自动白平衡关闭时按标定的中性偏移配平。",
        points, base.name, fit.residual, fit.span, applies)
        + (fit.toe.map {
          String(format: "中性点深入暗部，同时拟合了趾部宽度：R %.2f · G %.2f（数据表）· B %.2f，转换时据此还原暗部。", $0.r, $0.g, $0.b)
        } ?? ""),
      offsets: fit.offsets, toe: fit.toe)
  }
}
