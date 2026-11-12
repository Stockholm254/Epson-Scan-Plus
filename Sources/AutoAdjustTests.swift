import AppKit

/// 自动调整: the white balance and levels automatic again, the rest of the print and what was
/// measured kept; shade lit by the sky warmed to neutral
/// and a blue thing in the dark tones left blue; a frame dark all over lifted, a low key with light
/// in it and a frame in the usual range left as they are; and the wand in the app, one edit undone
/// with ⌘Z.
enum AutoAdjustTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    let portra = FilmProfile.builtins.first { $0.id == "portra160" }!
    let base = RGB(r: 0.85, g: 0.57, b: 0.38)
    let w = 300, h = 120
    /// A negative on Portra 160 whose column `x` took `exposure(x)` (log exposure) in each channel,
    /// plus `offset(x)` per channel: a light's or a thing's colour.
    func negative(_ exposure: (Int) -> Double, offset: (Int) -> RGB = { _ in .zero }) -> CGImage {
      var samples = [UInt16](repeating: 65535, count: w * h * 4)
      for x in 0..<w {
        let e = exposure(x), o = offset(x)
        for y in 0..<h {
          for c in 0..<3 {
            let v = base.values[c] * pow(10, -portra.slopes.values[c] * max(0, e + o.values[c]) / 2.2)
            samples[(y * w + x) * 4 + c] = UInt16(min(1, v) * 65535)
          }
        }
      }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    var plain = Adjustments()
    plain.base = base

    // What it takes back and what it keeps.
    var edited = plain
    (edited.exposure, edited.warmth, edited.tint, edited.saturation, edited.contrast) = (0.4, 0.3, -0.1, 1.3, 1.1)
    (edited.shadowWarmth, edited.whites, edited.midtone, edited.black) = (0.2, -0.5, 1.1, 0.02)
    edited.shadowTint = -0.3
    edited.manualBalance = RGB(r: 0.01, g: 0, b: -0.01)
    edited.autoLevels = false
    edited.neutralSample = RGB(r: 0.4, g: 0.3, b: 0.2)
    edited.curves = ToneCurves()
    edited.colourNoise = 0.6
    edited.rotation = 1
    edited.analysisRegion = NormalRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    edited.sharedBalance = true
    let cleared = AutoAdjust.cleared(edited)
    try check(
      cleared.exposure == 0 && cleared.warmth == 0 && cleared.tint == 0 && cleared.shadowWarmth == nil && cleared.shadowTint == nil && cleared.midtone == 1
        && cleared.black == 0 && cleared.manualBalance == nil && cleared.autoLevels && cleared.autoWhiteBalance,
      "自动调整 sets the white balance and levels automatic again: warmth, tint, a balance set by hand, the shadow tint, the ends and the midtone, with exposure and shadow warmth read anew")
    try check(
      cleared.saturation == 1.3 && cleared.contrast == 1.1 && cleared.whites == -0.5
        && cleared.neutralSample == edited.neutralSample && cleared.base == base && cleared.curves == edited.curves
        && cleared.colourNoise == 0.6 && cleared.rotation == 1 && cleared.analysisRegion == edited.analysisRegion
        && cleared.sharedBalance == true,
      "and keeps the rest of the print (saturation, contrast, the press, the curves) and what was measured or chosen: the grey picked, the base, the colour noise, the turn, the de-masking region, the roll's shared balance")
    var slide = Adjustments()
    slide.setReversal(true)
    try check(!AutoAdjust.cleared(slide).autoWhiteBalance, "a slide keeps its own colour: auto white balance stays off")

    // Sun and shade: a neutral black at the left, greys in the shade lit by the sky in the middle
    // (red down, blue up, green where it was), sunlit greys at the right.
    func scene(shade: RGB) -> CGImage {
      negative({ x in
        x < 40 ? 0.1 + 0.1 * Double(x) / 40 : x < 150 ? 0.35 + 0.25 * Double(x - 40) / 110 : 0.85 + 0.55 * Double(x - 150) / 150
      }, offset: { x in x >= 40 && x < 150 ? shade : .zero })
    }
    /// The shade's colour, R − B, on the screen, in the middle of its columns.
    func shadeWarm(_ image: CGImage, _ s: Adjustments) throws -> Double {
      let out = pipe.samples(try pipe.preview(image, settings: s, profile: portra), maxDimension: w)
      var sum = 0.0, n = 0.0
      for x in 70..<120 {
        for y in 30..<90 {
          let p = out.pixel(x * out.width / w, y * out.height / h)
          sum += p.r - p.b
          n += 1
        }
      }
      return sum / n
    }
    let skylit = scene(shade: RGB(r: -0.09, g: 0, b: 0.1))
    let shaded = try AutoAdjust.estimate(skylit, settings: plain, profile: portra)
    let before = try shadeWarm(skylit, AutoAdjust.cleared(plain)), after = try shadeWarm(skylit, shaded.adjustments)
    try check(
      shaded.shadowWarmth >= 0.1 && shaded.shadowWarmth <= AutoAdjust.mostShadowWarmth && abs(after) < abs(before) / 2,
      String(format: "greys in the shade lit by the sky are warmed towards neutral: shadow warmth %+.2f, R − B %+.3f to %+.3f", shaded.shadowWarmth, before, after))
    let violet = scene(shade: RGB(r: -0.12, g: -0.08, b: 0.1))
    let blue = try AutoAdjust.estimate(violet, settings: plain, profile: portra)
    try check(blue.shadowWarmth == 0,
      String(format: "a blue thing in the dark tones (green under red and blue, as a sky or the sea) is left blue: shade R − B %+.3f", blue.shadeCast ?? .nan))
    let even = try AutoAdjust.estimate(scene(shade: .zero), settings: plain, profile: portra)
    try check(even.shadowWarmth == 0, "neutral shade is left as it is")

    // The exposure.
    let darkAll = negative { x in x < 240 ? 0.1 + 0.35 * Double(x) / 240 : 0.45 + 0.95 * Double(x - 240) / 60 }
    let lifted = try AutoAdjust.estimate(darkAll, settings: plain, profile: portra)
    let now = AutoAdjust.read(pipe.samples(try pipe.preview(darkAll, settings: lifted.adjustments, profile: portra), maxDimension: 300)).middle
    try check(
      lifted.middle < AutoAdjust.middleRange.lowerBound && lifted.exposure > 0.05 && lifted.exposure <= AutoAdjust.mostExposure
        && now > lifted.middle,
      String(format: "a frame dark all over is lifted: middle %.2f, exposure %+.2f, middle after %.2f", lifted.middle, lifted.exposure, now))
    let lowKey = negative { x in x < 170 ? 0.01 * Double(x) / 170 : 0.6 + 0.8 * Double(x - 170) / 130 }
    let kept = try AutoAdjust.estimate(lowKey, settings: plain, profile: portra)
    try check(kept.middle < AutoAdjust.middleRange.lowerBound && kept.exposure == 0,
      String(format: "a low key with light in it (half black, half lit) keeps its exposure: middle %.2f", kept.middle))
    let ramp = try AutoAdjust.estimate(negative { x in 0.1 + 1.3 * Double(x) / Double(w - 1) }, settings: plain, profile: portra)
    try check(AutoAdjust.middleRange.contains(ramp.middle) && ramp.exposure == 0 && ramp.shadowWarmth == 0,
      String(format: "a frame in the usual range keeps its exposure: middle %.2f", ramp.middle))

    // In the app: the wand sets it as one edit, says what it set, and ⌘Z takes it back.
    let root = folder.appendingPathComponent("auto-adjust", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let decoded = root.appendingPathComponent("roll/Decoded", isDirectory: true)
    try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: root.appendingPathComponent("library"), preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    let url = decoded.appendingPathComponent("EPS00001.tif")
    try pipe.saveTIFF(skylit, to: url, dpi: 300)
    model.addCapturedFrame(url, original: url, linear: false)
    model.select(model.frames[0].id)
    model.page = .convert
    model.change("冷暖") { $0.warmth = 0.4 }
    let mine = model.frames[0].adjustments
    model.autoAdjust()
    let waited = Date()
    while !model.status.hasPrefix("已自动调整"), !model.status.hasPrefix("自动调整没有"), Date().timeIntervalSince(waited) < 30 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let set = model.frames[0].adjustments
    try check(
      model.status.hasPrefix("已自动调整第 01 张") && model.status.contains("⌘Z") && (model.canvasNote ?? "").hasPrefix("自动调整 · ")
        && set.warmth == 0 && set.shadowWarmthAmount > 0.05 && set.autoWhiteBalance && set.autoLevels,
      "the wand adjusts the selected frame and says what it set: " + model.status)
    edits.undo()
    try check(model.frames[0].adjustments == mine, "⌘Z takes the auto adjustment back in one step, the warmth set by hand with it")
  }
}
