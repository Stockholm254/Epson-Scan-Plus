import CoreImage
import Foundation

/// Capture One's picker under its curve, one key with a menu of two modes; the mode last chosen is
/// kept (`Preferences.curvePick`).
enum CurvePick: String, CaseIterable {
  /// Pick RGB Curve Point: a point added on the curve taken, where the colour clicked lies on it.
  case point
  /// Pick Neutralize Point: the red, green and blue curves each given a point that takes the colour
  /// clicked to grey at its own brightness, the ends left where they are.
  case neutral
  var title: String { self == .point ? "取曲线点" : "取中性点" }
  var symbol: String { self == .point ? "point.bottomleft.forward.to.point.topright.scurvepath" : "dot.viewfinder" }
}

extension ToneCurves {
  /// A pick within this of a point already on a curve takes that point rather than adding one
  /// beside it, as a click on the plot does.
  static let pickSpacing = 0.02
  /// What a colour before the curves comes into each channel's own curve as: after the parametric
  /// and RGB curves.
  func channelInputs(_ input: RGB) -> [Double] {
    let first = firstStage
    return input.values.map { rgb.value(first?.value($0) ?? $0) }
  }
  /// The curves with a point added on curve `channel` (0 RGB, 1 red, 2 green, 3 blue) where `input`,
  /// a colour before the curves, lies on it (`target`): on the curve, so the picture stays as it is
  /// until the point is dragged. Nil where a point already lies within `pickSpacing`, or the place
  /// is beyond the curve's end points.
  func pickedPoint(_ input: RGB, channel: Int) -> (curves: ToneCurves?, x: Double) {
    let x = target(input, channel: channel, parametric: false)
    var curve = self[channel]
    guard !curve.points.contains(where: { abs($0.x - x) < Self.pickSpacing }),
      let at = curve.points.firstIndex(where: { $0.x > x }), at > 0
    else { return (nil, x) }
    curve.points.insert(CurvePoint(x: x, y: curve.value(x)), at: at)
    var out = self
    out[channel] = curve
    return (out, x)
  }
  /// The curves with the red, green and blue curves each given a point where `input`, a colour
  /// before the curves, comes into them, all three at its brightness after the curves (0.2126 R +
  /// 0.7152 G + 0.0722 B, as the targeted adjustment reads brightness): there it comes out grey,
  /// as light or dark as it was. A point already within `pickSpacing` moves there instead. The end
  /// points stay, so black and white do; nil where a channel comes in that near an end.
  func neutralized(_ input: RGB) -> (curves: ToneCurves, target: Double, at: [Double])? {
    let at = channelInputs(input)
    let target = Self.brightness(RGB((0..<3).map { self[$0 + 1].value(at[$0]) }))
    var out = self
    for c in 0..<3 {
      var curve = self[c + 1]
      let x = at[c]
      guard let first = curve.points.first, let last = curve.points.last,
        x - first.x >= Self.pickSpacing, last.x - x >= Self.pickSpacing
      else { return nil }
      let inner = curve.points.indices.dropFirst().dropLast()
      if let near = inner.min(by: { abs(curve.points[$0].x - x) < abs(curve.points[$1].x - x) }),
        abs(curve.points[near].x - x) < Self.pickSpacing
      {
        // The nearest of the points about it, moved to it: it stays between its neighbours.
        curve.points[near] = CurvePoint(x: x, y: target)
      } else if let i = curve.points.firstIndex(where: { $0.x > x }) {
        curve.points.insert(CurvePoint(x: x, y: target), at: i)
      }
      out[c + 1] = curve
    }
    return (out, target, at)
  }
}

extension ImagePipeline {
  /// `image`'s positive about `point` (normalised in the picture as converted and turned, from the
  /// top left) as the conversion leaves it before the curves, on the curves' axis: in floating
  /// point, a few pixels each way averaged.
  func beforeCurves(_ image: CGImage, settings: Adjustments, profile: FilmProfile, analysis: ToneAnalysis?, at point: CGPoint) throws -> RGB {
    var s = settings
    s.curves = nil
    guard let colour = mean(try output(image, settings: s, profile: profile, analysis: analysis), at: point) else {
      throw DeskError.message("这一点不在画面里。")
    }
    return colour
  }
  /// A picture's colour about `point` (normalised, from the top left), in floating point: a few of
  /// its pixels each way averaged, 0.3% of its shorter side (1 to 4).
  func mean(_ ci: CIImage, at point: CGPoint) -> RGB? {
    let e = ci.extent
    guard e.width >= 1, e.height >= 1 else { return nil }
    let radius = max(1, min(4, Int((min(e.width, e.height) * 0.003).rounded())))
    let x = min(Int(e.width) - 1, max(0, Int(point.x * e.width))), y = min(Int(e.height) - 1, max(0, Int((1 - point.y) * e.height)))
    let rect = CGRect(x: e.minX + CGFloat(x - radius), y: e.minY + CGFloat(y - radius), width: CGFloat(2 * radius + 1), height: CGFloat(2 * radius + 1))
      .intersection(e).integral
    guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
    let w = Int(rect.width), h = Int(rect.height)
    var values = [Float](repeating: 0, count: w * h * 4)
    values.withUnsafeMutableBytes { p in
      context.render(ci, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: nil)
    }
    var sum = [0.0, 0.0, 0.0]
    for i in 0..<(w * h) { for c in 0..<3 { sum[c] += Double(values[i * 4 + c]) } }
    return RGB(sum.map { min(1, max(0, $0 / Double(w * h))) })
  }
}

extension AppModel {
  /// The single frame's positive about `point` (as the single view shows it, normalised from the
  /// top left) before the curves: from the picture the canvas shows, as its render left the
  /// conversion, in floating point rather than read back from the screen's 8 bits.
  func positiveBeforeCurves(at point: CGPoint) -> RGB? {
    guard singleView, let frame = selected, let input = samplingInput, let analysis = toneAnalysis else { return nil }
    return try? ImagePipeline.shared.beforeCurves(input, settings: frame.adjustments, profile: conversionProfile, analysis: analysis, at: point)
  }
  /// A click with the curves' picker on the single frame, in the mode last chosen: a point on the
  /// curve taken (on the RGB curve from the parametric one, whose page turns to it), or a neutral
  /// point on red, green and blue. The tool stays for the next point.
  func pickOnCurves(at point: CGPoint) {
    guard let input = positiveBeforeCurves(at: point) else { return }
    let mode = preferences.curvePick
    if mode == .point, curveState.parametric {
      curveState.parametric = false
      curveState.channel = 0
    }
    pickOnCurves(input, mode: mode, channel: curveState.channel)
  }
  /// `input`, a colour before the curves, picked on the curves in `mode` (`channel` the curve a
  /// point goes on: 0 RGB, 1 red, 2 green, 3 blue), as one edit that ⌘Z takes back. What was done,
  /// or why nothing was, in the status; true when the curves changed.
  @discardableResult
  func pickOnCurves(_ input: RGB, mode: CurvePick, channel: Int) -> Bool {
    func level(_ v: Double) -> String { String(Int((v * 255).rounded())) }
    let curves = settings.curves ?? ToneCurves()
    switch mode {
    case .point:
      let picked = curves.pickedPoint(input, channel: channel)
      let name = CurveEditor.names[channel]
      guard let next = picked.curves else {
        status = curves[channel].points.contains(where: { abs($0.x - picked.x) < ToneCurves.pickSpacing })
          ? "\(name) 曲线在输入 \(level(picked.x)) 已经有控制点：在「曲线」里直接拖它"
          : "这一点在 \(name) 曲线的端点以外（输入 \(level(picked.x))），加不了点"
        return false
      }
      change("取曲线点", separate: true) { $0.curves = next.normalized }
      curveState.edits &+= 1
      status = "已在 \(name) 曲线上加点：输入 \(level(picked.x)) → 输出 \(level(next[channel].value(picked.x)))，照片不变，在「曲线」里拖它 · ⌘Z 撤销"
      return true
    case .neutral:
      guard let found = curves.neutralized(input) else {
        status = "这一点太暗或太亮，离曲线的端点太近：取中性点只在两端之间加点，两端不动。点亮一些或暗一些的灰"
        return false
      }
      change("取中性点", separate: true) { $0.curves = found.curves.normalized }
      curveState.edits &+= 1
      fadeInNextPicture()
      status = "已取中性点：R、G、B 曲线在输入 \(found.at.map(level).joined(separator: " / ")) 各加一点，这里输出都是 \(level(found.target))，别的亮度渐渐不受影响 · ⌘Z 撤销"
      return true
    }
  }
}
