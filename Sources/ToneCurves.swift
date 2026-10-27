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

/// The RGB curve and one curve per channel; each channel's curve applies after the RGB curve.
struct ToneCurves: Codable, Equatable {
  var rgb = ToneCurve()
  var red = ToneCurve()
  var green = ToneCurve()
  var blue = ToneCurve()
  var isIdentity: Bool { rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity }
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
  /// `count` RGBA entries for 0...1: each channel's curve applied to the RGB curve's output.
  func table(_ count: Int) -> [Float] {
    var out = [Float](repeating: 1, count: count * 4)
    for i in 0..<count {
      let v = rgb.value(Double(i) / Double(count - 1))
      out[i * 4] = Float(red.value(v))
      out[i * 4 + 1] = Float(green.value(v))
      out[i * 4 + 2] = Float(blue.value(v))
    }
    return out
  }
}
