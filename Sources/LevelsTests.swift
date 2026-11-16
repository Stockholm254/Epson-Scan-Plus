import CoreGraphics
import CoreImage
import Foundation

/// 色阶 as Photoshop's Levels: input ends, midtone and output ends per channel and for the
/// composite after them; before the curves, in the table they share; its histogram, its 自动
/// options, its grey eyedropper, what ⌥ shows it cuts; given by 粘贴 and 同步 with 色阶; and
/// projects from before it open without it.
enum LevelsTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func close(_ a: Double, _ b: Double, _ e: Double = 1e-6) -> Bool { abs(a - b) <= e }
    // One channel: ends, midtone, output, and back.
    var c = Levels.Channel(black: 0.2, white: 0.8, gamma: 1, outBlack: 0, outWhite: 1)
    try check(Levels.Channel().isIdentity && close(Levels.Channel().value(0.37), 0.37)
      && close(c.value(0.2), 0) && close(c.value(0.8), 1) && close(c.value(0.5), 0.5) && close(c.value(0.1), 0) && close(c.value(0.95), 1),
      "a channel's input ends go to black and white, what lies past them cut, between them straight")
    c.gamma = 2
    try check(close(c.value(c.midPoint), 0.5) && c.value(0.5) > 0.5 && close(c.input(c.value(0.43)), 0.43, 1e-9)
      && close(c.gamma(at: c.midPoint), 2, 1e-9) && Levels.clampGamma(20) == 9.99 && Levels.clampGamma(0.01) == 0.10,
      "the midtone is Photoshop's gamma: over 1 lighter, its grey point where the output's middle falls; 0.10 to 9.99")
    c.outBlack = 0.1
    c.outWhite = 0.9
    try check(close(c.value(0), 0.1) && close(c.value(1), 0.9) && close(c.input(c.value(0.6)), 0.6, 1e-9),
      "the output ends set what black and white print as")
    // Each channel through its own levels, then the composite's.
    var l = Levels()
    l.red.white = 0.5
    l.rgb.outWhite = 0.8
    try check(close(l.value(0.25, 0), 0.4) && close(l.value(0.25, 1), 0.2) && close(l.input(0.4, 0), 0.25, 1e-9)
      && l.normalized != nil && Levels().normalized == nil,
      "red's own levels first, then the composite's (red 0.25 → 0.5 → 0.4; green straight to 0.2), as Photoshop and GIMP do")
    // In the curves' table: the levels, then the curves.
    var curves = ToneCurves()
    curves.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.4, y: 0.6), CurvePoint(x: 1, y: 1)])
    let n = 1025, table = curves.table(n, levels: l), plain = ToneCurves().table(n, levels: l)
    let at = 256  // x = 0.25
    try check(close(Double(plain[at * 4]), 0.4, 1e-4) && close(Double(plain[at * 4 + 1]), 0.2, 1e-4)
      && close(Double(table[at * 4]), curves.rgb.value(0.4), 1e-4) && close(Double(table[at * 4 + 1]), curves.rgb.value(0.2), 1e-4),
      "in the curves' table the levels come first, the curves after them on what they give")
    // On a picture: a grey through the kernels with the composite's black point raised.
    let pipe = ImagePipeline.shared
    let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
      .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    var raised = Levels()
    raised.rgb.black = 0.25
    func pixel(_ image: CIImage) -> [Float] {
      var px = [Float](repeating: 0, count: 4)
      px.withUnsafeMutableBytes {
        pipe.context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16 * 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
      }
      return px
    }
    let before = pixel(grey), after = pixel(pipe.applyCurves(nil, levels: raised, to: grey))
    try check(close(Double(after[0]), raised.value(Double(before[0]), 0), 2e-3) && after[0] < before[0] - 0.05
      && pixel(pipe.applyCurves(nil, levels: Levels(), to: grey)) == before,
      String(format: "on the picture the black point raised to 64 takes a grey from %.3f to %.3f; no levels leave it as it was", before[0], after[0]))

    // 自动, as Photoshop's options set it, on a histogram: red 20–200, green 40–220, blue 60–240.
    var counts = [[Double]](repeating: [Double](repeating: 0, count: 256), count: 3)
    for (ch, lo, hi) in [(0, 20, 200), (1, 40, 220), (2, 60, 240)] { for v in lo...hi { counts[ch][v] = 10 } }
    let h = LevelsHistogram(counts: counts, samples: (0..<400).map { i in
      let t = Double(i) / 399
      return RGB(r: (20 + 180 * t) / 255, g: (40 + 180 * t) / 255, b: (60 + 180 * t) / 255)
    })
    var o = LevelsAutoOptions()
    o.shadowClip = 0
    o.highlightClip = 0
    let each = Levels.auto(h, options: o)
    o.algorithm = .monochromatic
    let mono = Levels.auto(h, options: o)
    o.algorithm = .darkAndLight
    let darkLight = Levels.auto(h, options: o)
    try check(close(each.red.black * 255, 20, 1) && close(each.green.white * 255, 220, 1) && close(each.blue.black * 255, 60, 1) && each.rgb.isIdentity
      && close(mono.rgb.black * 255, 20, 1) && close(mono.rgb.white * 255, 240, 1) && mono.red.isIdentity
      && close(darkLight.red.black * 255, 20, 2) && close(darkLight.blue.white * 255, 240, 2),
      "自动: each channel's own ends (增强每通道的对比度), the three's together on the composite (增强单色对比度), the darkest and lightest colours (查找深色与浅色)")
    o.algorithm = .brightness
    let bright = Levels.auto(h, options: o)
    try check(!bright.rgb.isIdentity && bright.red.isIdentity && bright.rgb.gamma != 1,
      "增强亮度和对比度 sets the composite's ends by lightness and its midtone")
    // 灰场 / 对齐中性中间调: a warm grey made neutral, its lightness kept.
    var neutral = Levels()
    let warm = RGB(r: 0.62, g: 0.5, b: 0.38)
    neutral.setNeutral(warm)
    let made = (0..<3).map { neutral.value(warm.values[$0], $0) }
    try check(close(made[0], made[1], 2e-3) && close(made[1], made[2], 2e-3) && close(made[1], ToneCurves.brightness(warm), 3e-3) && neutral.rgb.isIdentity,
      String(format: "the grey eyedropper makes a warm grey neutral by each channel's midtone, its lightness kept (%.3f/%.3f/%.3f)", made[0], made[1], made[2]))
    // What ⌥ shows on the black point: white where nothing is cut, black where all is.
    var cut = Levels()
    cut.rgb.black = 0.3
    var bytes = [UInt8](repeating: 255, count: 2 * 1 * 4)
    (bytes[0], bytes[1], bytes[2]) = (20, 20, 20)       // cut in every channel
    (bytes[4], bytes[5], bytes[6]) = (200, 200, 200)    // not cut
    let tiny = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(bytes) as CFData)!,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    // The picture as printed with the levels: what they made of those two.
    let shown = pipe.raster(tiny, maxDimension: 2)
    let printed = (0..<2).map { x -> RGB in let p = shown.pixel(x, 0); return RGB(r: cut.value(p.r, 0), g: cut.value(p.g, 1), b: cut.value(p.b, 2)) }
    var out = [UInt8](repeating: 255, count: 8)
    for x in 0..<2 { for ch in 0..<3 { out[x * 4 + ch] = UInt8((printed[x].values[ch] * 255).rounded()) } }
    let printedImage = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(out) as CFData)!,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let map = pipe.raster(pipe.levelsClipping(printedImage, curves: nil, levels: cut, .black(0)), maxDimension: 2)
    let whiteMap = pipe.raster(pipe.levelsClipping(printedImage, curves: nil, levels: cut, .white(0)), maxDimension: 2)
    try check(map.pixel(0, 0).r == 0 && map.pixel(1, 0).r == 1 && whiteMap.pixel(0, 0).g == 0 && whiteMap.pixel(1, 0).g == 0,
      "with ⌥ on the black point, what it cuts shows black and the rest white; on the white point, black where nothing is cut")
    // The histogram: 256 steps a channel, the composite the three summed.
    let hist = LevelsHistogram(tiny)
    try check(hist.counts.count == 3 && hist.counts[0].count == 256 && hist.counts[0].reduce(0, +) == 2 && hist.counts[0][20] == 1
      && hist.shown(0)[200] == 3 && hist.shown(2)[20] == 1,
      "色阶's histogram counts each channel in 256 steps, the composite the three together")
    // 粘贴 and 同步 with 色阶 give it; a frame with none has none.
    var a = Adjustments(), b = Adjustments()
    b.levels = raised
    SettingsGroup.levels.take(&a, from: b)
    var graded = Adjustments()
    graded.takeGrading(from: b)
    var unset = Adjustments()
    unset.levels = Levels()
    try check(a.levels == raised && graded.levels == raised && SettingsGroup.levels.isSet(in: b) && !SettingsGroup.levels.isSet(in: unset)
      && SettingsGroup.levels.summary(of: b).contains("色阶调过"),
      "粘贴 / 同步 with 色阶 chosen give the levels; levels that change nothing count as none")
    // A project from before: no levels.
    var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Adjustments())) as! [String: Any]
    saved["levels"] = nil
    let old = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: saved))
    let kept = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(b))
    try check(old.levels == nil && kept.levels == raised, "a project from before 色阶 opens without levels; one with them keeps them")

    // One thing takes the picture's clicks: the eyedropper and the tool bar's tools put each other down.
    let suite = "local.epscan.levels-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("levels", isDirectory: true), preferences: Preferences(defaults: defaults))
    model.levelsPicker = .white
    model.tool = .neutral
    let toolWins = model.levelsPicker == nil && model.tool == .neutral
    model.levelsPicker = .grey
    let pickerWins = model.levelsPicker == .grey && model.tool == .select
    model.tool = .select
    try check(toolWins && pickerWins && model.levelsPicker == .grey,
      "中性灰 taken up puts 色阶's white eyedropper down, so the click goes to it; an eyedropper picked up puts the tool down; 选择 leaves the eyedropper held")
  }
}
