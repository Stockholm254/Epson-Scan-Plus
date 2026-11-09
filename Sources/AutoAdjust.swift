import CoreGraphics
import Foundation

/// 自动调整, the wand by the title: one frame's colour and tone set from its own picture, on this
/// Mac. Nothing is sent anywhere and nothing is learnt; it is the app's own automatic white balance
/// and levels, with an exposure and a shadow warmth read off the picture they give.
///
/// What it sets is the white balance and the levels, back to automatic: warmth and tint, a balance
/// set by hand, the ends and the midtone; and the exposure and shadow warmth it reads. What it
/// keeps is the rest of the print as the user made it (contrast, saturation, shadows, highlights,
/// the press, the curves), and what was measured or chosen about the film and the picture: the
/// base, a grey picked on the frame (a measurement of the scene's light, which nothing here reads
/// better), the preset, the crop and turn, the colour noise, the roll's shared balance and levels.
enum AutoAdjust {
  struct Outcome: Equatable {
    var adjustments: Adjustments
    /// The exposure and shadow warmth it set.
    var exposure: Double
    var shadowWarmth: Double
    /// The frame's median lightness on the screen (0–1) with the balance and levels automatic,
    /// before the exposure.
    var middle: Double
    /// The shade's colour off neutral, R − B, before the shadow warmth (nil: too little shade).
    var shadeCast: Double?
  }

  /// `s` with its white balance and levels automatic again, and its exposure and shadow warmth
  /// cleared for the estimates.
  static func cleared(_ s: Adjustments) -> Adjustments {
    var a = s
    (a.exposure, a.warmth, a.tint, a.shadowWarmth) = (0, 0, 0, nil)
    (a.black, a.white, a.midtone) = (0, 1, 1)
    a.manualBalance = nil
    a.autoLevels = true
    // A slide's colour, or a positive file's, is its picture: its balance stays as it was
    // (`Adjustments.setReversal`).
    if a.inputIsNegative { a.autoWhiteBalance = true }
    return a
  }

  // MARK: The estimates

  /// The shadow warmth set at most: past it the dark tones' own colours go (a red letter, a brown).
  static let mostShadowWarmth = 0.5
  /// The middle grey's usual range on the screen: a frame whose median lightness lies outside is
  /// brought `exposureShare` of the way back to it, by at most `mostExposure` stops. Within it the
  /// frame keeps the exposure the film and the levels give it. Its top is high, as light frames are
  /// mostly left light (of the author's own edits, exposure went up on six frames and down on two).
  static let middleRange = 0.33...0.72
  static let exposureShare = 0.6
  static let mostExposure = 0.6
  /// How light a dark frame's light tones (its 90th percentile) may come out when it is brightened:
  /// a low key with light in it, trees against a bright sky or a sunset, stays a low key, and only
  /// a frame dark all over is lifted.
  static let lightestUpper = 0.85
  /// How dark a light frame's dark tones (its 10th percentile) may come out when it is darkened.
  static let darkestLower = 0.04
  /// A low key with light in it, whose exposure stays: a fifth of the frame or more near black and
  /// its light tones (the 90th percentile) over a half, as trees against a bright sky or cliffs
  /// against a sunset. Lifted, its blacks only turn grey. A frame dark all over is lifted.
  static func lowKey(_ r: Reading) -> Bool { r.dark >= 0.2 && r.upper >= 0.5 }

  /// Whether `shade` is greys lit by the sky: bluer than neutral, by little enough to be a light's
  /// colour and not a blue thing's; blue against red only, as skylight leaves green where it was
  /// (a blue sky or the sea leans violet, green under the red and blue); a good share of the dark
  /// tones; and bluer than the light tones, so it is the shade's light, not the whole frame's.
  static func skylit(_ shade: (warm: Double, green: Double, share: Double), light: (warm: Double, green: Double, share: Double)?) -> Bool {
    guard let light else { return false }
    return shade.warm <= -0.06 && shade.warm >= -0.3 && abs(shade.green) <= 0.03 && shade.share >= 0.12
      && light.warm - shade.warm >= 0.06
  }

  /// The frame's auto adjustment from `source`, its picture as cropped (a small copy will do:
  /// 600–1000 pixels across), with `settings` as they are now.
  static func estimate(
    _ source: CGImage, settings: Adjustments, profile: FilmProfile, pipeline: ImagePipeline = .shared
  ) throws -> Outcome {
    var s = cleared(settings)
    // Read unturned, where the de-masking region lies (`Adjustments.analysisRegion`). The trial
    // exposure and warmth are the print's own controls, so the frame is analysed once for them all.
    func unturned(_ t: Adjustments) -> Adjustments {
      var u = t
      (u.rotation, u.flipHorizontal, u.angle) = (0, nil, nil)
      return u
    }
    let analysis = pipeline.analyze(source, settings: unturned(s), profile: profile)
    func shown(_ t: Adjustments) throws -> Samples {
      let ci = try pipeline.output(source, settings: unturned(t), profile: profile, analysis: analysis)
      guard let image = pipeline.context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: pipeline.outputSpace) else {
        throw DeskError.message("无法生成预览。")
      }
      return pipeline.samples(image, maxDimension: 400)
    }
    let m = ImagePipeline.statisticsMargin(s)
    let part = s.analysisRegion ?? NormalRect(x: m, y: m, width: 1 - 2 * m, height: 1 - 2 * m)
    let plain = try shown(s)
    let first = read(plain, part: part)
    // The shade's greys warmed to neutral, or only as far as the light tones' greys where those are
    // cool too, so the shade never comes out warmer than the sun: measured on the pixels of that
    // colour without and with a trial warmth, the kernel's softness and the print's saturation in
    // the dark tones taken as they come.
    var warmth = 0.0
    if s.inputIsNegative, let shade = first.shade, let light = first.light, skylit(shade, light: light) {
      let picked = pixels(plain, part: part, near: shade)
      let trial = 0.5, aim = min(0, light.warm)
      var t = s
      t.shadowWarmth = trial
      if let before = meanWarm(plain, picked), let after = meanWarm(try shown(t), picked), after - before > 0.02 {
        warmth = min(mostShadowWarmth, max(0, (aim - before) * trial / (after - before)))
      }
    }
    warmth = (warmth * 20).rounded() / 20
    s.shadowWarmth = warmth > 0 ? warmth : nil
    // The middle grey: read with the warmth in, then a trial exposure for how far a stop moves it
    // and the light (or dark) tones with it.
    let now = warmth > 0 ? read(try shown(s), part: part) : first
    let middle = now.middle
    var exposure = 0.0
    let target = min(middleRange.upperBound, max(middleRange.lowerBound, middle))
    if target != middle, !(target > middle && lowKey(now)) {
      let trial = middle < target ? 0.5 : -0.5
      var t = s
      t.exposure = trial
      let moved = read(try shown(t), part: part)
      if abs(moved.middle - middle) > 0.005 {
        exposure = (target - middle) * trial / (moved.middle - middle) * exposureShare
        if trial > 0, moved.upper - now.upper > 0.005 {
          exposure = min(exposure, max(0, (max(now.upper, lightestUpper) - now.upper) * trial / (moved.upper - now.upper)))
        } else if trial < 0, now.lower - moved.lower > 0.005 {
          exposure = max(exposure, min(0, (min(now.lower, darkestLower) - now.lower) * trial / (moved.lower - now.lower)))
        }
        exposure = min(mostExposure, max(-mostExposure, exposure))
      }
    }
    exposure = (exposure * 20).rounded() / 20
    s.exposure = exposure
    return Outcome(
      adjustments: s, exposure: exposure, shadowWarmth: warmth, middle: middle,
      shadeCast: first.shade.map { $0.warm })
  }

  /// The pixels within 0.04 of `colour` among the dark tones, by index into `samples`, each with
  /// the weight the shadow warmth gives it.
  static func pixels(_ samples: Samples, part: NormalRect, near colour: (warm: Double, green: Double, share: Double)) -> [(Int, Double)] {
    var found = [(Int, Double)]()
    let x0 = Int((part.x * Double(samples.width)).rounded()), x1 = Int(((part.x + part.width) * Double(samples.width)).rounded())
    let y0 = Int((part.y * Double(samples.height)).rounded()), y1 = Int(((part.y + part.height) * Double(samples.height)).rounded())
    for y in max(0, y0)..<min(samples.height, max(y0 + 1, y1)) {
      for x in max(0, x0)..<min(samples.width, max(x0 + 1, x1)) {
        let p = samples.pixel(x, y)
        let l = 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b
        let w = shadeWeight(l)
        let dw = p.r - p.b - colour.warm, dg = p.g - (p.r + p.b) / 2 - colour.green
        if w > 0.3, dw * dw + dg * dg <= 0.04 * 0.04 { found.append((y * samples.width + x, w)) }
      }
    }
    return found
  }
  /// The weighted mean of R − B over `pixels` of `samples`; nil for none.
  static func meanWarm(_ samples: Samples, _ pixels: [(Int, Double)]) -> Double? {
    var sum = 0.0, weight = 0.0
    for (i, w) in pixels {
      let p = samples.pixel(i % samples.width, i / samples.width)
      sum += (p.r - p.b) * w
      weight += w
    }
    return weight > 0 ? sum / weight : nil
  }

  // MARK: Reading the picture

  /// What the estimates read of a positive: its middle grey and how its shade and its light lean.
  struct Reading {
    /// The median lightness (Rec. 709 luma of the screen's values), its 10th and 90th percentiles,
    /// and the share near black and near white.
    var middle: Double
    var lower = 0.0, upper = 1.0
    var dark: Double
    var bright: Double
    /// The commonest colour of the dark tones (where the shadow warmth works) and of the light ones,
    /// as (R − B, G − (R + B) / 2), among the pixels not strongly coloured; nil with too few.
    var shade: (warm: Double, green: Double, share: Double)?
    var light: (warm: Double, green: Double, share: Double)?
  }

  static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = clamp((x - a) / (b - a))
    return t * t * (3 - 2 * t)
  }
  /// How much the shadow warmth works at lightness `l`, as the kernel weighs it (`Kernels.toned`).
  static func shadeWeight(_ l: Double) -> Double { smoothstep(0.03, 0.2, l) * (1 - smoothstep(0.2, 0.55, l)) }
  /// The light tones: sunlit greys and whites, short of what has run into white.
  static func lightWeight(_ l: Double) -> Double { smoothstep(0.5, 0.65, l) * (1 - smoothstep(0.88, 0.97, l)) }

  /// `samples`, a positive as the screen takes it, read over `part` (normalised, top left at 0).
  static func read(_ samples: Samples, part: NormalRect = .full) -> Reading {
    let x0 = Int((part.x * Double(samples.width)).rounded()), x1 = Int(((part.x + part.width) * Double(samples.width)).rounded())
    let y0 = Int((part.y * Double(samples.height)).rounded()), y1 = Int(((part.y + part.height) * Double(samples.height)).rounded())
    var lumas = [Double]()
    let n = 61, reach = 0.3, step = 2 * reach / Double(n - 1)
    var shadeBins = [Double](repeating: 0, count: n * n), lightBins = shadeBins
    var shadeTotal = 0.0, lightTotal = 0.0
    for y in max(0, y0)..<min(samples.height, max(y0 + 1, y1)) {
      for x in max(0, x0)..<min(samples.width, max(x0 + 1, x1)) {
        let p = samples.pixel(x, y)
        let l = 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b
        lumas.append(l)
        let warm = p.r - p.b, green = p.g - (p.r + p.b) / 2
        let ws = shadeWeight(l), wl = lightWeight(l)
        shadeTotal += ws
        lightTotal += wl
        guard abs(warm) <= reach, abs(green) <= reach else { continue }
        let i = Int(((green + reach) / step).rounded()) * n + Int(((warm + reach) / step).rounded())
        shadeBins[i] += ws
        lightBins[i] += wl
      }
    }
    guard !lumas.isEmpty else { return Reading(middle: 0.5, dark: 0, bright: 0) }
    lumas.sort()
    let count = Double(lumas.count)
    /// The densest colour, the bins smoothed over a few hundredths, and the share of the band's
    /// weight within 0.04 of it.
    func peak(_ bins: [Double], total: Double) -> (warm: Double, green: Double, share: Double)? {
      guard total > count * 0.03 else { return nil }
      var smooth = [Double](repeating: 0, count: n * n)
      let kernel = (-3...3).map { exp(-Double($0 * $0) / (2 * 1.5 * 1.5)) }
      var across = smooth
      for r in 0..<n {
        for c in 0..<n {
          var v = 0.0
          for k in -3...3 where c + k >= 0 && c + k < n { v += bins[r * n + c + k] * kernel[k + 3] }
          across[r * n + c] = v
        }
      }
      for r in 0..<n {
        for c in 0..<n {
          var v = 0.0
          for k in -3...3 where r + k >= 0 && r + k < n { v += across[(r + k) * n + c] * kernel[k + 3] }
          smooth[r * n + c] = v
        }
      }
      guard let top = smooth.indices.max(by: { smooth[$0] < smooth[$1] }) else { return nil }
      let (pr, pc) = (top / n, top % n)
      var near = 0.0
      for r in 0..<n {
        for c in 0..<n where Double((r - pr) * (r - pr) + (c - pc) * (c - pc)) * step * step <= 0.04 * 0.04 {
          near += bins[r * n + c]
        }
      }
      return (Double(pc) * step - reach, Double(pr) * step - reach, near / total)
    }
    return Reading(
      middle: lumas[Int((count - 1) * 0.5)], lower: lumas[Int((count - 1) * 0.1)], upper: lumas[Int((count - 1) * 0.9)],
      dark: Double(lumas.prefix { $0 < 0.05 }.count) / count,
      bright: Double(lumas.count - (lumas.firstIndex { $0 > 0.95 } ?? lumas.count)) / count,
      shade: peak(shadeBins, total: shadeTotal), light: peak(lightBins, total: lightTotal))
  }
}

extension AppModel {
  /// The frame being auto adjusted, while its picture is read off the main thread.
  private static var autoAdjusting: UUID?

  /// 自动调整 the selected frame (`AutoAdjust`): read on a small copy off the main thread, set as one
  /// edit, undone with ⌘Z, and said in a line over the picture.
  func autoAdjust() {
    guard let frame = selected, !isWorking, Self.autoAdjusting == nil else { return }
    let profile = conversionProfile
    Self.autoAdjusting = frame.id
    status = "正在自动调整第 \(frame.name) 张…"
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let result = Result(catching: { () throws -> AutoAdjust.Outcome in
        let source = try self.source(for: frame, maxDimension: 900)
        return try AutoAdjust.estimate(source, settings: frame.adjustments, profile: profile)
      })
      DispatchQueue.main.async {
        Self.autoAdjusting = nil
        switch result {
        case .failure(let error):
          self.status = "自动调整没有完成：" + error.localizedDescription
        case .success(let outcome):
          // Another frame chosen, or this one changed, in the meantime: nothing is set over it.
          guard let i = self.selectedIndex, self.frames[i].id == frame.id, self.frames[i].adjustments == frame.adjustments else {
            self.status = "第 \(frame.name) 张在自动调整时改过或换了画面，没有改动"
            return
          }
          let line = Self.autoAdjustLine(outcome, calibrated: profile.offsets != nil)
          if outcome.adjustments == frame.adjustments {
            self.status = "第 \(frame.name) 张已是自动调整的结果"
            self.noteOnCanvas("已是自动调整的结果")
            return
          }
          let kept = outcome.adjustments
          self.change("自动调整") { $0 = kept }
          self.status = "已自动调整第 \(frame.name) 张：" + line + " · ⌘Z 撤销"
          self.noteOnCanvas("自动调整 · " + line)
        }
      }
    }
  }
  /// What the auto adjustment set, in a few words: the balance it went by (a grey picked, a
  /// calibrated preset's neutral, as `ImagePipeline.measure` takes them first, or auto), and the
  /// exposure and shadow warmth it read.
  static func autoAdjustLine(_ o: AutoAdjust.Outcome, calibrated: Bool) -> String {
    let s = o.adjustments
    var parts = [String]()
    if s.neutralSample != nil {
      parts.append("白平衡按取的中性灰 · 自动色阶")
    } else if calibrated && s.inputIsNegative {
      parts.append("白平衡按标定预设的中性 · 自动色阶")
    } else if s.inputIsNegative {
      parts.append("自动白平衡和色阶")
    } else {
      parts.append("自动色阶")
    }
    parts.append(o.exposure == 0 ? "曝光不变" : String(format: "曝光 %+.2f", o.exposure))
    if o.shadowWarmth > 0 { parts.append(String(format: "阴影冷暖 %+.2f", o.shadowWarmth)) }
    return parts.joined(separator: " · ")
  }
}
