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

extension ImagePipeline {
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
  func original(_ image: CGImage, settings s: Adjustments, oriented: Bool) -> CGImage? {
    var ci = Self.baseNeutral(CIImage(cgImage: image, options: [.colorSpace: NSNull()]), base: nil, gamma: s.inputGamma)
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
