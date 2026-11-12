import CoreImage
import Foundation

/// Lightroom's colour mixer (HSL): eight hues, each moved in hue (up to 30° either way), saturation
/// and luminance (−1 to 1), as `Kernels.mixer` applies them to the picture as shown, greys left
/// alone. `values` holds band by band hue, saturation, luminance.
struct ColourMixer: Codable, Equatable {
  /// The bands' names and their hues in degrees, as Lightroom places them.
  static let bands: [(name: String, hue: Double)] = [
    ("红", 0), ("橙", 30), ("黄", 60), ("绿", 120), ("浅绿", 180), ("蓝", 240), ("紫", 270), ("洋红", 300),
  ]
  static let kinds = ["色相", "饱和度", "明度"]
  var values = [Double](repeating: 0, count: 24)
  var isIdentity: Bool { values.allSatisfy { $0 == 0 } }
  /// The three moves at `hue` degrees, between the two bands it lies between, eased.
  func at(_ hue: Double) -> (hue: Double, saturation: Double, luminance: Double) {
    let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    let centres = Self.bands.map(\.hue) + [360]
    let i = (0..<Self.bands.count).last { centres[$0] <= h } ?? 0
    let j = (i + 1) % Self.bands.count
    var t = (h - centres[i]) / (centres[i + 1] - centres[i])
    t = t * t * (3 - 2 * t)
    func v(_ band: Int, _ kind: Int) -> Double { values[band * 3 + kind] }
    return ((1 - t) * v(i, 0) + t * v(j, 0), (1 - t) * v(i, 1) + t * v(j, 1), (1 - t) * v(i, 2) + t * v(j, 2))
  }
  /// The moves for `Kernels.mixer`, a degree a step: red the hue's turn in whole turns (30° at 1),
  /// green the saturation, blue the luminance.
  func table() -> CIImage? {
    var px = [Float](repeating: 0, count: 360 * 4)
    for d in 0..<360 {
      let m = at(Double(d))
      (px[d * 4], px[d * 4 + 1], px[d * 4 + 2], px[d * 4 + 3]) = (Float(m.hue * 30 / 360), Float(m.saturation), Float(m.luminance), 1)
    }
    return CIImage(bitmapData: Data(bytes: px, count: px.count * 4), bytesPerRow: 360 * 16, size: CGSize(width: 360, height: 1),
      format: .RGBAf, colorSpace: nil)
  }
}

/// Lightroom's colour grading: the shadows, the midtones and the highlights each tinted towards a
/// hue (degrees) by an amount (0 to 1), the lightness kept; `balance` (−1 to 1) moves where the
/// shadows end and the highlights begin, `blending` (0 to 1) how far they overlap.
struct ColourGrading: Codable, Equatable {
  var shadowHue = 0.0, shadowAmount = 0.0
  var midHue = 0.0, midAmount = 0.0
  var highHue = 0.0, highAmount = 0.0
  var balance = 0.0, blending = 0.5
  var isIdentity: Bool { shadowAmount == 0 && midAmount == 0 && highAmount == 0 }
  /// A wheel's setting in figures: its hue in degrees and its amount out of 100; a dash at the middle.
  static func readout(hue: Double, amount: Double) -> String {
    let a = Int((amount * 100).rounded())
    guard a > 0 else { return "—" }
    return "\(Int(((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360).rounded()) % 360)° · \(a)"
  }
  /// A hue's colour with its lightness taken out, scaled by `amount` to at most 0.12: what is added
  /// to every pixel of the part, so the lightness stays.
  static func tint(_ hue: Double, _ amount: Double) -> CIVector {
    let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
    let rgb: [Double] = switch Int(h) {
    case 0: [1, x, 0]
    case 1: [x, 1, 0]
    case 2: [0, 1, x]
    case 3: [0, x, 1]
    case 4: [x, 0, 1]
    default: [1, 0, x]
    }
    let l = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    let k = 0.12 * max(0, min(1, amount))
    return CIVector(x: (rgb[0] - l) * k, y: (rgb[1] - l) * k, z: (rgb[2] - l) * k)
  }
}

extension ImagePipeline {
  /// Lightroom's presence, colour mixer and colour grading on the picture as shown, after the
  /// conversion and before the curves (`output`): texture against the picture smoothed over 0.12%
  /// of its longer side, clarity against it over 1.2%, dehaze by its darkest channel smoothed over
  /// 3% (`Kernels.presence`); then the mixer (`Kernels.mixer`) and the grading (`Kernels.grade`).
  /// Each step only when it does something, so a frame with none of them comes out as before.
  func looks(_ image: CIImage, _ s: Adjustments) -> CIImage {
    var out = image
    let extent = image.extent, long = Double(max(extent.width, extent.height))
    if s.textureAmount != 0 || s.clarityAmount != 0 || s.dehazeAmount != 0, let k = Kernels.presence {
      let clamped = out.clampedToExtent()
      let fine = clamped.applyingGaussianBlur(sigma: max(0.6, 0.0012 * long)).cropped(to: extent)
      let broad = clamped.applyingGaussianBlur(sigma: max(2, 0.012 * long)).cropped(to: extent)
      let haze = s.dehazeAmount == 0 ? out
        : out.applyingFilter("CIMinimumComponent").clampedToExtent().applyingGaussianBlur(sigma: max(4, 0.03 * long)).cropped(to: extent)
      out = k.apply(extent: extent, arguments: [out, fine, broad, haze,
        CIVector(x: s.textureAmount, y: s.clarityAmount, z: s.dehazeAmount, w: 0)]) ?? out
    }
    if let mixer = s.mixer, !mixer.isIdentity, let k = Kernels.mixer, let table = mixer.table() {
      out = k.apply(extent: extent, roiCallback: { i, r in i == 0 ? r : table.extent }, arguments: [out, table]) ?? out
    }
    if let g = s.grading, !g.isIdentity, let k = Kernels.grade {
      out = k.apply(extent: extent, arguments: [out, ColourGrading.tint(g.shadowHue, g.shadowAmount), ColourGrading.tint(g.midHue, g.midAmount),
        ColourGrading.tint(g.highHue, g.highAmount), CIVector(x: g.balance, y: g.blending, z: 0, w: 0)]) ?? out
    }
    return out
  }
}
