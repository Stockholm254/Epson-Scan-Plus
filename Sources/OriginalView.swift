import CoreGraphics
import CoreImage
import Foundation

/// How a picture was exposed, read off its pixels as they came from the sensor or the scanner,
/// before anything is done to them: whether its brightest film reaches the top of the range
/// (overexposed, the thinnest film losing its gradation), stays far under it (underexposed, the
/// range unused and the dense film in the noise), or lies between.
///
/// Bare light, every channel at the top, is passed over: on the copy stand it is the light box
/// round the film, and on a holder an empty place. What is left is the film, whose brightest part
/// is a negative's thinnest film (its base) or a slide's clearest.
struct ExposureReading: Equatable {
  enum Verdict: Equatable { case over, under, good }
  var verdict: Verdict
  /// The film's brightest 0.5%, in its brightest channel, as a share of the top of the range.
  var brightest: Double
  /// The share of the film with a channel at the top.
  var clipped: Double
  /// Stops from the brightest to the top.
  var headroom: Double
  /// The share of the picture that is bare light.
  var bare: Double

  /// A channel this close to the top is taken as at it.
  static let top = 0.98
  /// More than this share of the film at the top is overexposed: past a speck or two of a highlight.
  static let tooMuchAtTop = 0.005
  /// A brightest film under this share of the top is underexposed: two stops or more unused. A
  /// negative's base reads about half the top on the V850, and 0.35–0.45 on the copy stand.
  static let tooDark = 0.25

  /// In a line, for the bar under the picture.
  var short: String {
    switch verdict {
    case .over: return String(format: "过曝 · %.1f%% 到顶", clipped * 100)
    case .under: return String(format: "欠曝 · 还差 %.1f 档", headroom)
    case .good: return String(format: "曝光合适 · 余 %.1f 档", headroom)
    }
  }
  /// The whole of it, for its help.
  var text: String {
    let top = String(format: "最亮的胶片在满量程的 %.0f%%，离到顶 %.1f 档", brightest * 100, headroom)
    let bareNote = bare > 0.001 ? String(format: "；%.0f%% 是裸光（三个通道都到顶），不算在内", bare * 100) : ""
    switch verdict {
    case .over:
      return String(format: "过曝：%.1f%% 的胶片有通道到顶，那里没有层次了（负片是最薄的地方：片基和暗部；反转片是最亮处）。减少曝光。", clipped * 100)
        + top + bareNote + "。"
    case .under:
      return "欠曝：" + top + "，读数的范围有一大半没用上，密的地方会落进噪点里。可以增加曝光，到最亮的胶片接近满量程又不到顶" + bareNote + "。"
    case .good:
      return "曝光合适：" + top + "，没有到顶的胶片" + bareNote + "。"
    }
  }
}

/// How the film base reads in each of the camera's channels, as the sensor read it: for setting a
/// narrowband light's three lights so that the base, the brightest film, comes near the top in all
/// three alike and each channel's range is used to its full.
struct BaseBalance: Equatable {
  /// The base's reading in each channel, a share of the top of the range.
  var level: RGB
  /// Where it was read, in words: the film at the frame's edges, a base picked by hand, or the
  /// brightest film.
  var source: String
  /// Channels this close in stops count as even.
  static let even = 0.15
  /// Stops each channel lies under the brightest of the three.
  var under: [Double] {
    let top = level.values.max() ?? 1
    return level.values.map { log2(top / max($0, 1e-4)) }
  }
  /// Red's and blue's stops against green.
  var red: Double { log2(max(level.r, 1e-4) / max(level.g, 1e-4)) }
  var blue: Double { log2(max(level.b, 1e-4) / max(level.g, 1e-4)) }
  var isEven: Bool { (under.max() ?? 0) < Self.even }
  /// In a line, for the bar under the picture.
  var short: String { String(format: "片基 红 %+.1f · 蓝 %+.1f 档", red, blue) }
  /// The whole of it, and what to turn, for its help.
  var text: String {
    let names = ["红", "绿", "蓝"]
    let levels = (0..<3).map { String(format: "%@ %.0f%%", names[$0], level.values[$0] * 100) }.joined(separator: " · ")
    let room = (0..<3).map { String(format: "%@ %.1f", names[$0], max(0, log2(ExposureReading.top / max(level.values[$0], 1e-4)))) }.joined(separator: " · ")
    var said = "片基（\(source)）的读数，占满量程：\(levels)；离到顶：\(room) 档。"
      + String(format: "对绿：红 %+.2f 档，蓝 %+.2f 档。", red, blue)
    if isEven {
      said += "三个通道差不到 \(String(format: "%.2f", Self.even)) 档，灯的配比合适。"
    } else {
      let turns = (0..<3).filter { under[$0] >= Self.even }.map { String(format: "%@灯调亮约 %.1f 档", names[$0], under[$0]) }
      said += "要让三个通道一样亮：" + turns.joined(separator: "、") + "（或把最亮的那盏调暗同样多），再拍一张看。"
    }
    said += "\n\n目的：片基是负片上最亮的地方，三个通道都把它放在接近满量程、又不到顶的地方，每个通道的读数范围都用满，密的地方离噪点最远。读的是传感器原样的读数（不去串色、不除平场）：蓝灯有约三分之一读进绿通道，调蓝灯时绿也会跟着变一点，调完再拍一张看。整体太亮或太暗用曝光调，看左边的曝光指示。"
    return said
  }
}

extension ImagePipeline {
  /// The film base's reading in `image` (a frame's pixels as the sensor read it, cropped): the mean
  /// over `areas` (normalised in the image) where given, else over the brightest film, the top
  /// hundredth of it in its brightest channel, bare light left out. Nil with no film.
  func baseBalance(_ image: CGImage, areas: [CGRect], source: String) -> BaseBalance? {
    let s = samples(image, maxDimension: 800)
    var sum = [0.0, 0.0, 0.0], n = 0.0
    for a in areas {
      let x0 = max(0, Int(a.minX * Double(s.width))), x1 = min(s.width, Int(ceil(a.maxX * Double(s.width))))
      let y0 = max(0, Int(a.minY * Double(s.height))), y1 = min(s.height, Int(ceil(a.maxY * Double(s.height))))
      guard x1 > x0, y1 > y0 else { continue }
      for y in y0..<y1 {
        for x in x0..<x1 {
          let p = s.pixel(x, y).values
          guard p.min()! < ExposureReading.top else { continue }
          for c in 0..<3 { sum[c] += p[c] }
          n += 1
        }
      }
    }
    if n > 0 { return BaseBalance(level: RGB(sum.map { $0 / n }), source: source) }
    var film = [[Double]]()
    for y in 0..<s.height { for x in 0..<s.width {
      let p = s.pixel(x, y).values
      if p.min()! < ExposureReading.top { film.append(p) }
    } }
    guard !film.isEmpty else { return nil }
    let peaks = film.map { $0.max()! }
    let cut = quantile(peaks, 0.99)
    let brightest = film.filter { $0.max()! >= cut }
    guard !brightest.isEmpty else { return nil }
    return BaseBalance(level: RGB((0..<3).map { c in brightest.map { $0[c] }.reduce(0, +) / Double(brightest.count) }), source: "最亮的胶片")
  }
  /// How `image` (a frame's pixels as read, linear or as encoded) was exposed; nil with no film
  /// in it at all.
  func exposure(_ image: CGImage) -> ExposureReading? {
    let s = samples(image, maxDimension: 800)
    var peaks = [Double]()
    peaks.reserveCapacity(s.width * s.height)
    var bare = 0, atTop = 0
    for y in 0..<s.height {
      for x in 0..<s.width {
        let p = s.pixel(x, y).values
        if p.min()! >= ExposureReading.top {
          bare += 1
          continue
        }
        let peak = p.max()!
        if peak >= ExposureReading.top { atTop += 1 }
        peaks.append(peak)
      }
    }
    let all = s.width * s.height
    guard !peaks.isEmpty, all > 0 else { return nil }
    let brightest = max(1e-4, quantile(peaks, 0.995))
    let clipped = Double(atTop) / Double(peaks.count)
    let headroom = max(0, log2(ExposureReading.top / brightest))
    let verdict: ExposureReading.Verdict =
      clipped > ExposureReading.tooMuchAtTop ? .over : brightest < ExposureReading.tooDark ? .under : .good
    return ExposureReading(verdict: verdict, brightest: brightest, clipped: clipped, headroom: headroom, bare: Double(bare) / Double(all))
  }

  /// `image` as it came, for module ①: its readings in a linear response, light for light, encoded
  /// for the screen as sRGB; nothing taken off, balanced or curved, a negative's orange mask as it
  /// is. A file encoded for the screen already is shown as encoded. `oriented` turns, mirrors and
  /// straightens it as the frame is, for the single view; the light table has it as it lies.
  /// With `gains`, each channel of a linear file multiplied by its own, for the screen only.
  func original(_ image: CGImage, settings s: Adjustments, oriented: Bool, gains: RGB? = nil) -> CGImage? {
    var ci = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    if let g = gains {
      ci = ci.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: g.r, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: g.g, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: g.b, w: 0),
      ])
    }
    ci = Self.baseNeutral(ci, base: nil, gamma: s.inputGamma)
    if oriented {
      ci = Self.straightened(ci, degrees: s.angle ?? 0)
      ci = ci.oriented(forExifOrientation: [1, 6, 3, 8][((s.rotation % 4) + 4) % 4])
      if s.flipHorizontal == true { ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
      ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
    }
    let linear = abs(s.inputGamma - 1) < 1e-6
    return context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: linear ? outputSpace : image.colorSpace ?? outputSpace)
  }
}
