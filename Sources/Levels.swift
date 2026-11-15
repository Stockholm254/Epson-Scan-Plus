import CoreGraphics
import Foundation

/// 色阶 as Photoshop's Levels has it, on the picture as shown, before the curves: for the composite
/// RGB and for each of red, green and blue, an input black, midtone and white and an output black
/// and white. Each channel goes through its own levels and then the composite's, as GIMP, built to
/// Photoshop's, does it. Values 0–1 (the panel shows them 0–255); the midtone is Photoshop's gamma,
/// 0.10–9.99, over 1 lighter. Nil leaves the picture as it is.
struct Levels: Codable, Equatable {
  struct Channel: Codable, Equatable {
    var black = 0.0
    var white = 1.0
    var gamma = 1.0
    var outBlack = 0.0
    var outWhite = 1.0
    var isIdentity: Bool { black == 0 && white == 1 && gamma == 1 && outBlack == 0 && outWhite == 1 }
    /// `x` through the input ends, the midtone and the output ends.
    func value(_ x: Double) -> Double {
      let t = min(1, max(0, (x - black) / max(white - black, 1e-6)))
      return outBlack + pow(t, 1 / gamma) * (outWhite - outBlack)
    }
    /// What gives `y`: past the output ends, the input end it was cut at.
    func input(_ y: Double) -> Double {
      let span = outWhite - outBlack
      let t = abs(span) < 1e-6 ? 0.5 : min(1, max(0, (y - outBlack) / span))
      return black + pow(t, gamma) * (white - black)
    }
    /// Where the midtone puts the middle of the output: Photoshop's grey slider,
    /// `black + 0.5^gamma · (white − black)`.
    var midPoint: Double { black + pow(0.5, gamma) * (white - black) }
    /// The midtone that puts the middle of the output at `x`.
    func gamma(at x: Double) -> Double {
      let t = min(0.999, max(0.001, (x - black) / max(white - black, 1e-6)))
      return Levels.clampGamma(log(t) / log(0.5))
    }
  }
  var rgb = Channel()
  var red = Channel()
  var green = Channel()
  var blue = Channel()
  var isIdentity: Bool { rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity }
  /// 0 the composite, 1 red, 2 green, 3 blue, as the panel's keys are.
  subscript(_ i: Int) -> Channel {
    get { [rgb, red, green, blue][max(0, min(3, i))] }
    set {
      switch i {
      case 1: red = newValue
      case 2: green = newValue
      case 3: blue = newValue
      default: rgb = newValue
      }
    }
  }
  /// Channel `c` (0 red, 1 green, 2 blue) of `x`: its own levels, then the composite's.
  func value(_ x: Double, _ c: Int) -> Double { rgb.value(self[c + 1].value(x)) }
  /// What gives `y` in channel `c`.
  func input(_ y: Double, _ c: Int) -> Double { self[c + 1].input(rgb.input(y)) }
  static func clampGamma(_ g: Double) -> Double { min(9.99, max(0.10, g)) }
  /// Nil for no change, as the frame keeps it.
  var normalized: Levels? { isIdentity ? nil : self }
}

/// The picture before 色阶, as the levels panel shows and reads it: each channel's counts in 256
/// steps, as Photoshop's histogram has them, the composite the three together; and a sample of its
/// colours for the automatic options and 对齐中性中间调.
struct LevelsHistogram: Equatable {
  var counts: [[Double]]
  var samples: [RGB]
  static let empty = LevelsHistogram(counts: [[Double]](repeating: [Double](repeating: 0, count: 256), count: 3), samples: [])
  /// Of the composite (channel 0): the three summed; of a channel (1–3): its own.
  func shown(_ channel: Int) -> [Double] {
    guard channel == 0 else { return counts[max(0, min(2, channel - 1))] }
    return (0..<256).map { counts[0][$0] + counts[1][$0] + counts[2][$0] }
  }
  /// From a picture before 色阶; with `curves` (and `levels`) it is the picture as shown, read back
  /// through them, a value the levels cut to black or white put at their input end.
  init(_ image: CGImage, curves: ToneCurves? = nil, levels: Levels? = nil) {
    let r = ImagePipeline.shared.raster(image, maxDimension: 300)
    let inverse = CurveInverse(curves)
    var counts = [[Double]](repeating: [Double](repeating: 0, count: 256), count: 3)
    var samples = [RGB]()
    samples.reserveCapacity(r.width * r.height / 2 + 1)
    for y in 0..<r.height {
      for x in 0..<r.width {
        let shown = r.pixel(x, y)
        var c = inverse?.input(shown) ?? shown
        if let levels, !levels.isIdentity { c = RGB(r: levels.input(c.r, 0), g: levels.input(c.g, 1), b: levels.input(c.b, 2)) }
        for i in 0..<3 { counts[i][min(255, max(0, Int((c.values[i] * 255).rounded())))] += 1 }
        if (x + y) % 2 == 0 { samples.append(c) }
      }
    }
    self.counts = counts
    self.samples = samples
  }
  init(counts: [[Double]], samples: [RGB]) { (self.counts, self.samples) = (counts, samples) }
}

/// Photoshop's 自动颜色校正选项 for 色阶's 自动 button.
struct LevelsAutoOptions: Codable, Equatable {
  enum Algorithm: String, Codable, CaseIterable, Identifiable {
    /// The three channels' darkest and lightest together, set on the composite: the colour stays.
    case monochromatic
    /// Each channel's own darkest and lightest, on the channels: casts in the ends go.
    case perChannel
    /// The mean colour of the darkest and of the lightest pixels set as black and white.
    case darkAndLight
    /// The lightness's ends on the composite, and the midtone so the median lightness prints mid-grey.
    case brightness
    var id: String { rawValue }
    var name: String {
      switch self {
      case .monochromatic: return "增强单色对比度"
      case .perChannel: return "增强每通道的对比度"
      case .darkAndLight: return "查找深色与浅色"
      case .brightness: return "增强亮度和对比度"
      }
    }
  }
  var algorithm = Algorithm.perChannel
  /// Clipped at each end, in percent: Photoshop's default 0.1.
  var shadowClip = 0.1
  var highlightClip = 0.1
  /// 对齐中性中间调: a nearly neutral colour in the middle tones made neutral, by each channel's midtone.
  var snapNeutralMidtones = false
}

extension Levels {
  /// `h` set by `options`, as Photoshop's 自动 does it: what it sets starts from no levels; the
  /// output ends are kept.
  static func auto(_ h: LevelsHistogram, options o: LevelsAutoOptions, keepingOutput from: Levels? = nil) -> Levels {
    var l = Levels()
    if let from { for i in 0..<4 { (l[i].outBlack, l[i].outWhite) = (from[i].outBlack, from[i].outWhite) } }
    func quantile(_ counts: [Double], _ p: Double) -> Double {
      let total = counts.reduce(0, +)
      guard total > 0 else { return p < 0.5 ? 0 : 1 }
      // The first step holding any of them where it reaches `p` (with nothing clipped, the first
      // and last steps anything lies in, not an empty end).
      var run = 0.0
      for (i, v) in counts.enumerated() where v > 0 {
        run += v
        if run >= total * p { return Double(i) / 255 }
      }
      return 1
    }
    let lo = o.shadowClip / 100, hi = 1 - o.highlightClip / 100
    func ends(_ black: Double, _ white: Double) -> (Double, Double) {
      let b = min(black, 253 / 255), w = max(white, b + 2 / 255)
      return (b, min(1, w))
    }
    switch o.algorithm {
    case .monochromatic:
      let all = h.shown(0)
      (l.rgb.black, l.rgb.white) = ends(quantile(all, lo), quantile(all, hi))
    case .perChannel:
      for c in 0..<3 { (l[c + 1].black, l[c + 1].white) = ends(quantile(h.counts[c], lo), quantile(h.counts[c], hi)) }
    case .darkAndLight:
      let sorted = h.samples.sorted { ToneCurves.brightness($0) < ToneCurves.brightness($1) }
      guard !sorted.isEmpty else { break }
      let n = sorted.count, k0 = max(1, Int(Double(n) * max(lo, 0.0005))), k1 = max(1, Int(Double(n) * max(1 - hi, 0.0005)))
      func mean(_ s: ArraySlice<RGB>) -> RGB { RGB((0..<3).map { c in s.reduce(0) { $0 + $1.values[c] } / Double(s.count) }) }
      let dark = mean(sorted.prefix(k0)), light = mean(sorted.suffix(k1))
      for c in 0..<3 { (l[c + 1].black, l[c + 1].white) = ends(dark.values[c], light.values[c]) }
    case .brightness:
      var lightness = [Double](repeating: 0, count: 256)
      for s in h.samples { lightness[min(255, max(0, Int((ToneCurves.brightness(s) * 255).rounded())))] += 1 }
      (l.rgb.black, l.rgb.white) = ends(quantile(lightness, lo), quantile(lightness, hi))
      // The median lightness to mid-grey on screen (sRGB 118, Photoshop's 18 % grey).
      let median = quantile(lightness, 0.5)
      let t = (median - l.rgb.black) / max(l.rgb.white - l.rgb.black, 1e-6)
      if t > 0.02, t < 0.98 { l.rgb.gamma = clampGamma(log(t) / log(118.0 / 255)) }
    }
    if o.snapNeutralMidtones { l.snapNeutral(h.samples) }
    return l
  }
  /// 对齐中性中间调: the mean of the nearly neutral colours in the middle tones (after these
  /// levels), made neutral by each channel's midtone at its own lightness.
  mutating func snapNeutral(_ samples: [RGB]) {
    var sum = RGB(r: 0, g: 0, b: 0), n = 0.0
    for s in samples {
      let v = RGB(r: value(s.r, 0), g: value(s.g, 1), b: value(s.b, 2))
      let l = ToneCurves.brightness(v), spread = max(v.r, v.g, v.b) - min(v.r, v.g, v.b)
      guard l > 0.2, l < 0.8, spread < 0.12 else { continue }
      sum = RGB(r: sum.r + v.r, g: sum.g + v.g, b: sum.b + v.b)
      n += 1
    }
    guard n >= 20 else { return }
    let grey = RGB(r: sum.r / n, g: sum.g / n, b: sum.b / n)
    setNeutral(grey)
  }
  /// The channels' midtones set so `v`, a colour after these levels, comes out a grey of its own
  /// lightness (灰场吸管 and 对齐中性中间调): each channel's own midtone moved to put it there.
  mutating func setNeutral(_ v: RGB) {
    let target = ToneCurves.brightness(v)
    for c in 0..<3 {
      // In the channel's own levels: what it reads before them, and what the composite needs out of them.
      let before = self[c + 1].input(rgb.input(v.values[c]))
      let wanted = rgb.input(target)
      var ch = self[c + 1]
      let t = (before - ch.black) / max(ch.white - ch.black, 1e-6)
      let out = (wanted - ch.outBlack) / max(ch.outWhite - ch.outBlack, 1e-6)
      guard t > 0.001, t < 0.999, out > 0.001, out < 0.999 else { continue }
      ch.gamma = Levels.clampGamma(log(t) / log(out))
      self[c + 1] = ch
    }
  }
}

/// What 色阶's points show while dragged with ⌥ held, as Photoshop's Levels does: the black point
/// (or white) of the composite (0) or of red, green or blue (1–3).
enum LevelsClipping: Equatable {
  case black(Int)
  case white(Int)
}

/// 色阶's eyedroppers, as Photoshop's: the black, grey and white point picked off the picture.
enum LevelsPicker: Equatable {
  case black, grey, white
}

extension ImagePipeline {
  /// `shown`, the picture as printed with `levels` and `curves`, as Photoshop's Levels shows it
  /// while its black or white point is dragged with ⌥ held: for the black point white where
  /// nothing is cut, black where every channel is, the colour of the channels left where some are;
  /// for the white point black where nothing is cut, white where all are. On one channel, that
  /// channel alone, in grey. Read back through the curves to what came out of the levels.
  func levelsClipping(_ shown: CGImage, curves: ToneCurves?, levels: Levels?, _ mode: LevelsClipping) -> CGImage {
    let r = raster(shown, maxDimension: max(shown.width, shown.height))
    let inverse = CurveInverse(curves), l = levels ?? Levels(), eps = 0.75 / 255
    let lows = (0..<3).map { l.value(0, $0) }, highs = (0..<3).map { l.value(1, $0) }
    var px = [UInt8](repeating: 255, count: r.width * r.height * 4)
    for y in 0..<r.height {
      for x in 0..<r.width {
        let s = r.pixel(x, y), a = inverse?.input(s) ?? s
        var lit = [Bool](repeating: false, count: 3)
        for c in 0..<3 {
          switch mode {
          case .black: lit[c] = a.values[c] > lows[c] + eps
          case .white: lit[c] = a.values[c] >= highs[c] - eps
          }
        }
        let i = (y * r.width + x) * 4
        switch mode {
        case .black(let ch) where ch > 0, .white(let ch) where ch > 0:
          let v: UInt8 = lit[ch - 1] ? 255 : 0
          (px[i], px[i + 1], px[i + 2]) = (v, v, v)
        default:
          (px[i], px[i + 1], px[i + 2]) = (lit[0] ? 255 : 0, lit[1] ? 255 : 0, lit[2] ? 255 : 0)
        }
      }
    }
    let data = Data(px) as CFData
    guard let provider = CGDataProvider(data: data),
      let image = CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
        space: shown.colorSpace ?? outputSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return shown }
    return image
  }
}
