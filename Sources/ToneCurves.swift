import Foundation

struct CurvePoint: Codable, Equatable {
  var x: Double
  var y: Double
}

/// A tone curve through control points in 0...1: a monotone cubic (Fritsch–Carlson) between them,
/// so it never overshoots between points. The end points stay at x = 0 and x = 1.
struct ToneCurve: Codable, Equatable {
  var points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
  var isIdentity: Bool { points.allSatisfy { abs($0.x - $0.y) < 1e-6 } }
  func value(_ x: Double) -> Double {
    let p = points
    guard p.count > 1 else { return x }
    if x <= p[0].x { return p[0].y }
    if x >= p[p.count - 1].x { return p[p.count - 1].y }
    let n = p.count
    let secant = (0..<(n - 1)).map { (p[$0 + 1].y - p[$0].y) / max(1e-9, p[$0 + 1].x - p[$0].x) }
    var tangent = (0..<n).map { i -> Double in
      i == 0 ? secant[0] : i == n - 1 ? secant[n - 2] : secant[i - 1] * secant[i] <= 0 ? 0 : (secant[i - 1] + secant[i]) / 2
    }
    for i in 0..<(n - 1) {
      if secant[i] == 0 {
        tangent[i] = 0
        tangent[i + 1] = 0
        continue
      }
      let a = tangent[i] / secant[i], b = tangent[i + 1] / secant[i]
      if a * a + b * b > 9 {
        let t = 3 / (a * a + b * b).squareRoot()
        tangent[i] = t * a * secant[i]
        tangent[i + 1] = t * b * secant[i]
      }
    }
    let i = (0..<(n - 1)).last { p[$0].x <= x } ?? 0
    let h = p[i + 1].x - p[i].x, t = (x - p[i].x) / h
    let t2 = t * t, t3 = t2 * t
    let y = (2 * t3 - 3 * t2 + 1) * p[i].y + (t3 - 2 * t2 + t) * h * tangent[i]
      + (-2 * t3 + 3 * t2) * p[i + 1].y + (t3 - t2) * h * tangent[i + 1]
    return min(1, max(0, y))
  }
}

/// The first of the curves, as Lightroom's parametric curve: the tones in four zones, split at three
/// points, each zone lifted (above 0) or lowered by its own amount, −1 to 1; black and white stay.
struct ParametricCurve: Codable, Equatable {
  var shadows = 0.0
  var darks = 0.0
  var lights = 0.0
  var highlights = 0.0
  /// Where the shadows meet the darks, the darks the lights, the lights the highlights.
  var splits = [0.25, 0.5, 0.75]
  /// The zones' names, darkest first.
  static let names = ["阴影", "暗部", "亮部", "高光"]
  /// The amounts, darkest zone first.
  var amounts: [Double] {
    get { [shadows, darks, lights, highlights] }
    set { (shadows, darks, lights, highlights) = (newValue[0], newValue[1], newValue[2], newValue[3]) }
  }
  var isIdentity: Bool { amounts.allSatisfy { abs($0) < 1e-6 } }
  /// How far a zone's middle moves at a full amount, as a share of the zone's width: as far as
  /// keeps the curve rising when the zones beside it are pulled the other way.
  static let reach = 0.45
  /// The zones' edges, black to white.
  var edges: [Double] { [0] + splits + [1] }
  /// The zone a tone lies in, 0 the shadows.
  func zone(_ x: Double) -> Int { splits.firstIndex { x < $0 } ?? 3 }
  /// Through each zone's middle, moved by its amount, and each split, moved by the mean of the two
  /// zones beside it; a monotone cubic between them, never falling.
  var curve: ToneCurve {
    let e = edges, a = amounts
    let lift = (0..<4).map { a[$0] * Self.reach * (e[$0 + 1] - e[$0]) }
    var points = [CurvePoint(x: 0, y: 0)]
    for k in 0..<4 {
      let middle = (e[k] + e[k + 1]) / 2
      points.append(CurvePoint(x: middle, y: middle + lift[k]))
      if k < 3 { points.append(CurvePoint(x: e[k + 1], y: e[k + 1] + (lift[k] + lift[k + 1]) / 2)) }
    }
    points.append(CurvePoint(x: 1, y: 1))
    for i in 1..<points.count { points[i].y = min(1, max(points[i].y, points[i - 1].y)) }
    return ToneCurve(points: points)
  }
}

/// The parametric curve, then the RGB curve, then one curve per channel, as in Lightroom: each
/// applies to what the one before it gives.
struct ToneCurves: Codable, Equatable {
  var rgb = ToneCurve()
  var red = ToneCurve()
  var green = ToneCurve()
  var blue = ToneCurve()
  /// Missing from projects before it, so read as none.
  var parametric: ParametricCurve?
  var isIdentity: Bool {
    (parametric?.isIdentity ?? true) && rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
  }
  /// As a frame keeps them: none when they change nothing, unless the parametric splits were moved,
  /// which the zones' sliders still want.
  var normalized: ToneCurves? {
    isIdentity && (parametric.map { $0.splits == ParametricCurve().splits } ?? true) ? nil : self
  }
  /// The parametric curve when it changes anything.
  var firstStage: ToneCurve? { parametric.flatMap { $0.isIdentity ? nil : $0.curve } }
  /// 0 RGB, 1 red, 2 green, 3 blue.
  subscript(channel: Int) -> ToneCurve {
    get { [rgb, red, green, blue][channel] }
    set {
      switch channel {
      case 1: red = newValue
      case 2: green = newValue
      case 3: blue = newValue
      default: rgb = newValue
      }
    }
  }
  /// `count` RGBA entries for 0...1: the parametric curve, the RGB curve after it, and each
  /// channel's curve after that.
  func table(_ count: Int) -> [Float] {
    var out = [Float](repeating: 1, count: count * 4)
    let first = firstStage
    for i in 0..<count {
      let x = Double(i) / Double(count - 1)
      let v = rgb.value(first?.value(x) ?? x)
      out[i * 4] = Float(red.value(v))
      out[i * 4 + 1] = Float(green.value(v))
      out[i * 4 + 2] = Float(blue.value(v))
    }
    return out
  }
}

/// Lightroom's targeted adjustment: a place on the picture held and dragged up or down moves the
/// curve taken where that place's colour lies on it.
extension ToneCurves {
  static func brightness(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
  /// Where a colour, as it was before the curves, lies on the curve taken: on the parametric curve
  /// its brightness; on the RGB curve its brightness after the parametric one; on one channel's
  /// curve that channel after the curves before it.
  func target(_ input: RGB, channel: Int, parametric onParametric: Bool) -> Double {
    let first = firstStage
    func before(_ v: Double) -> Double { first?.value(v) ?? v }
    if onParametric { return Self.brightness(input) }
    if channel == 0 { return Self.brightness(RGB(input.values.map(before))) }
    return rgb.value(before(input.values[channel - 1]))
  }
  /// These curves with the curve taken moved at tone `x` by `amount`, a share of the plot's height,
  /// up lighter: on the parametric curve, the amount of x's zone, twice as far, since a zone's middle
  /// moves less than its amount; on a point curve, the point at x (within 0.02, the end points too),
  /// or one added there on the curve.
  func targeted(at x: Double, channel: Int, parametric onParametric: Bool, by amount: Double) -> ToneCurves {
    var out = self
    if onParametric {
      var p = parametric ?? ParametricCurve()
      var a = p.amounts
      let k = p.zone(x)
      a[k] = min(1, max(-1, a[k] + amount * 2))
      p.amounts = a
      out.parametric = p
      return out
    }
    var curve = self[channel]
    let i: Int
    if let near = curve.points.indices.first(where: { abs(curve.points[$0].x - x) < 0.02 }) {
      i = near
    } else {
      guard let at = curve.points.firstIndex(where: { $0.x > x }), at > 0 else { return self }
      curve.points.insert(CurvePoint(x: x, y: curve.value(x)), at: at)
      i = at
    }
    curve.points[i].y = min(1, max(0, curve.points[i].y + amount))
    out[channel] = curve
    return out
  }
}

/// What came before the curves, for each of the 256 values a picture shows in a channel (8 bits):
/// the span of values the curves take to it, or the nearest such span where none comes out at that
/// value (a steep curve skips some). Where a curve runs flat, a span is wide: all of it shows alike.
/// A curve bent back down takes two places to one value; its span then reaches over both.
struct CurveInverse {
  private let spans: [[ClosedRange<Double>]]
  /// Nil for no curves, or straight ones: a picture's values are then what came before them.
  init?(_ curves: ToneCurves?) {
    guard let curves, !curves.isIdentity else { return nil }
    let n = 2048
    let table = curves.table(n + 1)
    var found = [[ClosedRange<Double>?]](repeating: [ClosedRange<Double>?](repeating: nil, count: 256), count: 3)
    for i in 0...n {
      let x = Double(i) / Double(n)
      for c in 0..<3 {
        let v = min(255, max(0, Int((Double(table[i * 4 + c]) * 255).rounded())))
        found[c][v] = found[c][v].map { min($0.lowerBound, x)...max($0.upperBound, x) } ?? x...x
      }
    }
    spans = found.map { channel in
      (0..<256).map { v in
        for d in 0..<256 {
          if v - d >= 0, let s = channel[v - d] { return s }
          if v + d < 256, let s = channel[v + d] { return s }
        }
        return Double(v) / 255...Double(v) / 255
      }
    }
  }
  /// The span before the curves of channel `c` (0 red, 1 green, 2 blue) showing `shown`.
  func span(_ c: Int, _ shown: Double) -> ClosedRange<Double> {
    spans[c][min(255, max(0, Int((shown * 255).rounded())))]
  }
  /// A colour as shown, as it was before the curves: the middle of each channel's span.
  func input(_ shown: RGB) -> RGB {
    RGB((0..<3).map { c in
      let s = span(c, shown.values[c])
      return (s.lowerBound + s.upperBound) / 2
    })
  }
}
