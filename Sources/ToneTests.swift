import CoreImage
import CoreGraphics
import Foundation

enum ToneTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    let portra = FilmProfile.builtins.first { $0.id == "portra160" }!
    let ektar = FilmProfile.builtins.first { $0.id == "ektar100" }!
    let generic = FilmProfile.builtins.first { $0.id == "generic" }!
    // A negative exposed on a film with Portra 160's slopes: log exposure ramps across, the top
    // band is neutral, the others tinted. Tints are not negative, so the channels share a black point.
    let w = 240, h = 160
    let base = RGB(r: 0.85, g: 0.57, b: 0.38)
    var samples = [UInt16](repeating: 65535, count: w * h * 4)
    for y in 0..<h {
      for x in 0..<w {
        let exposure = 0.15 + 1.4 * Double(x) / Double(w - 1)
        let tint = [[0.0, 0.0, 0.0], [0.25, 0.0, 0.05], [0.0, 0.15, 0.25], [0.1, 0.2, 0.0]][y * 4 / h]
        for c in 0..<3 {
          let v = base.values[c] * pow(10, -portra.slopes.values[c] * (exposure + tint[c]) / 2.2)
          samples[(y * w + x) * 4 + c] = UInt16(v * 65535)
        }
      }
    }
    let negative = CGImage(
      width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
      provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
    func render(_ s: Adjustments, _ p: FilmProfile) throws -> Raster {
      pipe.raster(try pipe.preview(negative, settings: s, profile: p), maxDimension: w)
    }
    func meanDifference(_ a: Raster, _ b: Raster) -> Double {
      zip(a.bytes, b.bytes).enumerated().filter { $0.offset % 4 != 3 }
        .map { abs(Double($0.element.0) - Double($0.element.1)) }.reduce(0, +) / Double(w * h * 3)
    }
    /// Average channel spread across the neutral band, in 8-bit levels.
    func cast(_ r: Raster) -> Double {
      var total = 0.0, count = 0.0
      for y in 2..<(h / 4 - 2) {
        for x in (w / 10)..<(w * 9 / 10) {
          let v = r.pixel(x, y).values.map { $0 * 255 }
          total += v.max()! - v.min()!
          count += 1
        }
      }
      return total / count
    }
    let defaults = Adjustments()
    let matching = try render(defaults, portra)
    try check(meanDifference(matching, try render(defaults, generic)) > 1,
      "a named film preset changes the default (auto white balance) conversion")
    let castMatching = cast(matching), castOther = cast(try render(defaults, ektar))
    let castGeneric = cast(try render(defaults, generic))
    try check(castMatching < 2 && castMatching < castOther && castMatching < castGeneric,
      String(format: "the matching preset keeps neutrals neutral: %.1f vs %.1f other film, %.1f generic", castMatching, castOther, castGeneric))

    // Exposure is a print exposure in density, applied before clipping. The red-tinted band's
    // red channel holds the frame's brightest values, so it is what clips at 0 EV.
    func highlights(_ r: Raster) -> [Double] { (w - 12..<w).map { r.pixel($0, h * 3 / 8).r * 255 } }
    // Cut straight at the ends, as before the soft shoulder.
    var straight = defaults
    straight.softEnds = false
    let even = highlights(try render(straight, portra))
    var darker = straight
    darker.exposure = -1
    let recovered = highlights(try render(darker, portra))
    try check(even.last! > 254.5 && recovered.last! < 250 && recovered.last! > recovered.first! + 3,
      String(format: "−1 EV recovers clipped highlights with gradation: %.0f…%.0f, was %.0f…%.0f",
        recovered.first!, recovered.last!, even.first!, even.last!))
    let shouldered = highlights(matching)
    try check(shouldered.last! < 254 && shouldered.last! > shouldered.first! + 2 && shouldered.first! > even.first! - 12,
      String(format: "with soft ends the same highlights roll off short of white, graded, at 0 EV: %.0f…%.0f",
        shouldered.first!, shouldered.last!))
    // The shoulder keeps a bright colour: the red-tinted band's red rolls off as before, and green
    // and blue stay as far below it instead of closing up towards white; the neutral band is the
    // same either way.
    func redOverGreen(_ r: Raster) -> Double { (w - 12..<w).map { (r.pixel($0, h * 3 / 8).r - r.pixel($0, h * 3 / 8).g) * 255 }.reduce(0, +) / 12 }
    let keeping = ImagePipeline.highlightColour
    ImagePipeline.highlightColour = 0
    let closed = try render(defaults, portra)
    ImagePipeline.highlightColour = keeping
    let neutralShift = (w - 12..<w).map { abs(matching.pixel($0, 4).g - closed.pixel($0, 4).g) * 255 }.max()!
    try check(redOverGreen(matching) > redOverGreen(closed) + 4 && abs(highlights(closed).last! - shouldered.last!) < 1.5 && neutralShift < 1.5,
      String(format: "the shoulder keeps a bright red's distance from white: red over green %.0f, channel by channel %.0f; the neutral band moves %.1f",
        redOverGreen(matching), redOverGreen(closed), neutralShift))
    // Lifted back part of the way towards the lightness it has rolled off channel by channel, the
    // blue band (a sky's colour, far past white in its blue) keeps its hue: blue stays brightest,
    // and green and red stay in the same proportion below it; the neutral band is as it was.
    func skyEnd(_ r: Raster) -> (luma: Double, ratio: Double, blueTop: Bool) {
      let px = (w - 12..<w).map { r.pixel($0, h * 5 / 8) }
      let red = px.map { $0.r }.reduce(0, +) / 12, green = px.map { $0.g }.reduce(0, +) / 12, blue = px.map { $0.b }.reduce(0, +) / 12
      return ((0.2126 * red + 0.7152 * green + 0.0722 * blue) * 255, (blue - green) / max(blue - red, 0.001), blue > green && blue > red)
    }
    let lifting = ImagePipeline.highlightLightness
    ImagePipeline.highlightLightness = 0
    let deep = try render(defaults, portra)
    ImagePipeline.highlightLightness = lifting
    let liftedSky = skyEnd(matching), deepSky = skyEnd(deep)
    let liftNeutral = (w - 12..<w).map { abs(matching.pixel($0, 4).g - deep.pixel($0, 4).g) * 255 }.max()!
    try check(liftedSky.luma > deepSky.luma + 2 && liftedSky.blueTop && abs(liftedSky.ratio - deepSky.ratio) < 0.08 && liftNeutral < 1,
      String(format: "a blue far past white is lifted %.1f levels towards its rolled-off lightness, blue still brightest, green over red below it %.2f (was %.2f); the neutral band moves %.1f",
        liftedSky.luma - deepSky.luma, liftedSky.ratio, deepSky.ratio, liftNeutral))
    var brighter = defaults
    brighter.exposure = 1
    let mid = matching.pixel(w / 2, 4).g * 255, lifted = try render(brighter, portra).pixel(w / 2, 4).g * 255
    try check(lifted > mid + 20, String(format: "+1 EV brightens the midtones: %.0f → %.0f", mid, lifted))
    // Shadows and highlights move their own tones along the neutral ramp, the black held, the ramp
    // still rising.
    func ramp(_ s: Adjustments) throws -> [Double] {
      let r = try render(s, portra)
      return (0..<w).map { r.pixel($0, 4).g * 255 }
    }
    let plain = try ramp(straight)
    func at(_ v: [Double], _ share: Double) -> Double { v[Int(Double(w - 1) * share)] }
    // Where the plain ramp is a quarter and three quarters of the way up.
    let dark = plain.firstIndex { $0 > 64 }.map { Double($0) / Double(w - 1) } ?? 0.25
    let light = plain.firstIndex { $0 > 191 }.map { Double($0) / Double(w - 1) } ?? 0.75
    var lifted2 = straight
    lifted2.shadows = 1
    var held = straight
    held.highlights = -1
    var both = straight
    both.shadows = -1
    both.highlights = 1
    let up = try ramp(lifted2), down = try ramp(held), crossed = try ramp(both)
    func rising(_ v: [Double]) -> Bool { zip(v, v.dropFirst()).allSatisfy { $1 >= $0 - 1 } }
    try check(at(up, dark) > at(plain, dark) + 8 && abs(at(up, light) - at(plain, light)) < (at(up, dark) - at(plain, dark)) / 2
      && at(down, light) < at(plain, light) - 8 && abs(at(down, dark) - at(plain, dark)) < (at(plain, light) - at(down, light)) / 2
      && abs(up[0] - plain[0]) < 2 && plain[0] < 1 && rising(up) && rising(down) && rising(crossed),
      String(format: "shadows +1 lifts the dark tones (%.0f → %.0f) more than the light, highlights −1 lowers the light (%.0f → %.0f) more than the dark; black stays, and the ramp keeps rising",
        at(plain, dark), at(up, dark), at(plain, light), at(down, light)))
    // Shadow warmth warms the dark greys and leaves the light ones and black: red over blue on the
    // neutral ramp where it is a quarter of the way up, nothing where it is three quarters or black.
    func warmer(_ s: Adjustments, _ share: Double) throws -> Double {
      let p = try render(s, portra).pixel(Int(Double(w - 1) * share), 4)
      return (p.r - p.b) * 255
    }
    var warmed = straight
    warmed.shadowWarmth = 1
    var none = straight
    none.shadowWarmthAmount = 0
    let warmDark = try warmer(warmed, dark) - warmer(straight, dark), warmLight = try warmer(warmed, light) - warmer(straight, light)
    let warmBlack = try warmer(warmed, 0) - warmer(straight, 0)
    try check(warmDark > 25 && abs(warmLight) < 1.5 && abs(warmBlack) < 1.5 && none.shadowWarmth == nil
      && meanDifference(try render(none, portra), try render(straight, portra)) == 0,
      String(format: "shadow warmth +1 warms the dark greys (red over blue +%.0f levels) and leaves the light ones (%+.1f) and black (%+.1f); at 0 it changes nothing",
        warmDark, warmLight, warmBlack))
    // Shadow tint −1 greens dark greys with a magenta cast and leaves the light ones and black;
    // dark greys already green, and neutral ones, it leaves: it only takes out the opposite cast.
    func greener(_ s: Adjustments, _ share: Double) throws -> Double {
      let p = try render(s, portra).pixel(Int(Double(w - 1) * share), 4)
      return (p.g - (p.r + p.b) / 2) * 255
    }
    var magentaCast = straight
    magentaCast.tint = 0.5
    var greened = magentaCast
    greened.shadowTint = -1
    var greenCast = straight
    greenCast.tint = -0.5
    var greenOnGreen = greenCast, greenOnGrey = straight
    (greenOnGreen.shadowTint, greenOnGrey.shadowTint) = (-1, -1)
    var untinted = straight
    untinted.shadowTintAmount = 0
    let greenDark = try greener(greened, dark) - greener(magentaCast, dark), greenLight = try greener(greened, light) - greener(magentaCast, light)
    let greenBlack = try greener(greened, 0) - greener(magentaCast, 0)
    let onGreen = try greener(greenOnGreen, dark) - greener(greenCast, dark), onGrey = try greener(greenOnGrey, dark) - greener(straight, dark)
    try check(greenDark > 25 && abs(greenLight) < 1.5 && abs(greenBlack) < 1.5 && abs(onGreen) < 1.5 && abs(onGrey) < 3
      && untinted.shadowTint == nil && meanDifference(try render(untinted, portra), try render(straight, portra)) == 0,
      String(format: "shadow tint −1 greens magenta dark greys (+%.0f levels) and leaves the light ones (%+.1f), black (%+.1f), green dark greys (%+.1f) and grey ones (%+.1f); at 0 it changes nothing",
        greenDark, greenLight, greenBlack, onGreen, onGrey))
    // The shadow neutral picker: a dark grey cast by warmth and tint comes back to grey with the
    // shadow warmth and tint it solves from the point's reading; a light grey is out of its reach.
    var castDark = straight
    (castDark.warmth, castDark.tint) = (0.35, -0.3)
    let darkX = Int(Double(w - 1) * dark), readings = pipe.samples(negative, maxDimension: w)
    let solved = ImagePipeline.shadowBalance(
      readings.pixel(darkX, 4), settings: castDark, profile: portra, analysis: pipe.analyze(negative, settings: castDark, profile: portra))
    var balanced = castDark
    if let solved { (balanced.shadowWarmth, balanced.shadowTint) = (solved.warmth, solved.tint) }
    func spread(_ s: Adjustments, _ x: Int) throws -> Double {
      let v = try render(s, portra).pixel(x, 4).values.map { $0 * 255 }
      return v.max()! - v.min()!
    }
    let castSpread = try spread(castDark, darkX), balancedSpread = try spread(balanced, darkX)
    let tooLight = ImagePipeline.shadowBalance(
      readings.pixel(w - 3, 4), settings: castDark, profile: portra, analysis: pipe.analyze(negative, settings: castDark, profile: portra))
    try check(solved?.reached == true && castSpread > 10 && balancedSpread < 3 && tooLight == nil,
      String(format: "the shadow neutral picker takes a cast dark grey (%.0f levels apart) back to grey (%.1f) with shadow warmth %+.2f and tint %+.2f, and leaves a light grey alone",
        castSpread, balancedSpread, solved?.warmth ?? .nan, solved?.tint ?? .nan))
    // Whites −1 lowers the top end, the light greys and white with them, leaves the dark ones, and
    // keeps a bright red at least as far from green (brought down out of the shoulder, it is less
    // rolled off); 压高光 saved before is read as it.
    var pressed = defaults
    pressed.whites = -1
    var old = Adjustments()
    old.pressHighlights = 0.6
    let oldDecoded = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(old))
    try check(old.whitesAmount == -0.6 && oldDecoded.whitesAmount == -0.6,
      "压高光 0.6 saved before whites is read as whites −0.6")
    var reset = old
    reset.whitesAmount = 0
    try check(reset.whites == nil && reset.pressHighlights == nil && reset.whitesAmount == 0, "setting whites clears the old 压高光")
    try check(sliderText("%+.2f", Adjustments().whitesAmount) == "+0.00" && sliderText("%+.2f", -0.004) == "+0.00"
      && sliderText("%+.2f", -0.3) == "-0.30" && sliderText("%.1f%%", -0.02) == "0.0%",
      "a slider at zero reads +0.00, not -0.00 (whites with nothing saved, or a value rounding to zero)")
    let press = try render(pressed, portra)
    let pressedLight = matching.pixel(Int(Double(w - 1) * light), 4).g * 255 - press.pixel(Int(Double(w - 1) * light), 4).g * 255
    let pressedDark = matching.pixel(Int(Double(w - 1) * dark), 4).g * 255 - press.pixel(Int(Double(w - 1) * dark), 4).g * 255
    let pressedWhite = (0..<w).map { press.pixel($0, 4).g * 255 }.max()!
    try check(pressedLight > 8 && abs(pressedDark) < 1 && pressedWhite < 0.87 * 255 && redOverGreen(press) > redOverGreen(matching) - 2,
      String(format: "whites −1 lowers the light greys by %.0f levels and white to %.0f, the dark greys by %.1f, and a bright red keeps its colour, no closer to green (red over green %.0f, was %.0f)",
        pressedLight, pressedWhite, pressedDark, redOverGreen(press), redOverGreen(matching)))
    // Blacks: +1 lifts the bottom end, black with it, −1 takes more of it to black; the light greys stay.
    var lifted3 = defaults
    lifted3.blacks = 1
    var deeper = defaults
    deeper.blacks = -1
    let liftedRamp = try render(lifted3, portra), deeperRamp = try render(deeper, portra)
    func atBlack(_ r: Raster) -> Int { (0..<w).filter { r.pixel($0, 4).g * 255 < 0.5 }.count }
    let blackLifted = liftedRamp.pixel(0, 4).g * 255 - matching.pixel(0, 4).g * 255
    let lightKept = abs(liftedRamp.pixel(Int(Double(w - 1) * light), 4).g - matching.pixel(Int(Double(w - 1) * light), 4).g) * 255
    try check(blackLifted > 15 && atBlack(deeperRamp) > atBlack(matching) + 3 && lightKept < 1,
      String(format: "blacks +1 lifts black by %.0f levels, −1 takes %d more steps to black (%d before), and the light greys stay (%.1f)",
        blackLifted, atBlack(deeperRamp) - atBlack(matching), atBlack(matching), lightKept))
    // Positive input scales the linear value: one stop at input gamma 2.2 multiplies by 2^(1/2.2).
    let grey = CGImage(
      width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: Data([UInt8](repeating: 102, count: 256).enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element }) as CFData)!,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    var positive = Adjustments()
    positive.inputIsNegative = false
    positive.exposure = 1
    let stop = pipe.raster(try pipe.preview(grey, settings: positive, profile: generic)).pixel(4, 4).g * 255
    try check(abs(stop - 102 * pow(2, 1 / 2.2)) < 2.5, String(format: "+1 EV on positive input: 102 → %.0f", stop))

    // Colour noise smoothed: a grey with speckles of colour, and of lightness, on it. The colour goes,
    // the lightness (the grain) stays where it was, to the last level.
    let side = 160
    var speckled = [Float](repeating: 1, count: side * side * 4)
    var seed: UInt32 = 7
    func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
    for i in 0..<(side * side) {
      let grain = 0.5 + 0.1 * noise(), tint = (r: 0.08 * noise(), b: 0.08 * noise())
      let g = grain - 0.2126 * tint.r - 0.0722 * tint.b
      speckled[i * 4] = grain + tint.r - 0.2126 * tint.r - 0.0722 * tint.b
      speckled[i * 4 + 1] = g
      speckled[i * 4 + 2] = grain + tint.b - 0.2126 * tint.r - 0.0722 * tint.b
    }
    let field = CIImage(
      bitmapData: speckled.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: side * 16,
      size: CGSize(width: side, height: side), format: .RGBAf, colorSpace: nil)
    func readout(_ image: CIImage) -> [Float] {
      var px = [Float](repeating: 0, count: side * side * 4)
      px.withUnsafeMutableBytes { pipe.context.render(image, toBitmap: $0.baseAddress!, rowBytes: side * 16, bounds: image.extent, format: .RGBAf, colorSpace: nil) }
      return px
    }
    let before = readout(field), after = readout(pipe.colourSmoothed(field, radius: 2))
    func luma(_ p: [Float], _ i: Int) -> Float { 0.2126 * p[i * 4] + 0.7152 * p[i * 4 + 1] + 0.0722 * p[i * 4 + 2] }
    func spread(_ p: [Float], _ c: Int) -> Float {
      let v = (0..<(side * side)).map { p[$0 * 4 + c] - luma(p, $0) }
      let m = v.reduce(0, +) / Float(v.count)
      return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(v.count)).squareRoot()
    }
    let lumaKept = (0..<(side * side)).allSatisfy { abs(luma(after, $0) - luma(before, $0)) < 1.0 / 1000 }
    try check(lumaKept && spread(after, 0) < spread(before, 0) / 3 && spread(after, 2) < spread(before, 2) / 3,
      String(format: "colour noise smoothed away, the lightness (the grain) kept exactly: red speckle %.3f → %.3f, blue %.3f → %.3f",
        spread(before, 0), spread(after, 0), spread(before, 2), spread(after, 2)))

    // 色阶's histogram: a frame of one tone at 0.5 before the black and white points comes out at
    // (0.5 - black) / (white - black) past them, as `ToneRange` counts it; put back, it is at 0.5
    // whatever the points. The midtone's mark is where it makes mid-grey, and drags back to it.
    func range(_ q: Double) -> ToneRange {
      let n = 400, d = -1.0...3.0
      var counts = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
      let i = Int((q - d.lowerBound) / (d.upperBound - d.lowerBound) * Double(n))
      for c in 0..<3 { counts[c][i] = 1 }
      return ToneRange(counts: counts, domain: d, black: nil, white: nil, stop: nil, pastWhite: 0, atWhite: 0, atBlack: 0, brightest: q)
    }
    let peaks = [(0.0, 1.0), (0.1, 0.9), (0.3, 0.7)].map { b, wh -> Int in
      let c = LevelsHistogram.counts(range((0.5 - b) / (wh - b)), black: b, white: wh)[1]
      return c.firstIndex(of: c.max()!)!
    }
    let midMark = LevelsHistogram.midPoint(black: 0.1, white: 0.9, midtone: 1.4)
    try check(peaks.allSatisfy { abs($0 - LevelsHistogram.bins / 2) <= 1 }
      && abs(pow((midMark - 0.1) / 0.8, 1 / 1.4) - 0.5) < 1e-9
      && abs(LevelsHistogram.midtone(at: midMark, black: 0.1, white: 0.9) - 1.4) < 1e-9
      && LevelsHistogram.midtone(at: 0.99, black: 0.1, white: 0.9) == 0.4,
      "色阶's histogram shows a tone where it lies before the black and white points, whatever they are; the midtone's mark is its mid-grey and drags back to the same midtone")
    // An even spread of tones from black to white: the coarse counts (120 steps across about three
    // times black to white, as `ToneRange` keeps them) leave every other bar empty; the fine ones
    // the GPU made (2048 steps over −1 to 3) leave none.
    func spread(coarse: Bool) -> ToneRange {
      let fineDomain = -1.0...3.0, n = 2048
      let fine = (0..<3).map { _ in (0..<n).map { i -> Double in
        let q = fineDomain.lowerBound + (Double(i) + 0.5) * 4 / Double(n)
        return (0...1).contains(q) ? 1 : 0
      } }
      let domain = -0.3...2.7, bins = 120
      var counts = [[Double]](repeating: [Double](repeating: 0, count: bins), count: 3)
      for c in 0..<3 { for i in 0..<n where fine[c][i] > 0 {
        let q = fineDomain.lowerBound + (Double(i) + 0.5) * 4 / Double(n)
        counts[c][min(bins - 1, Int((q - domain.lowerBound) / 3 * Double(bins)))] += fine[c][i]
      } }
      return ToneRange(counts: counts, domain: domain, black: nil, white: nil, stop: nil, pastWhite: 0, atWhite: 0, atBlack: 0, brightest: 1,
        fine: coarse ? [] : fine, fineDomain: fineDomain)
    }
    let inside = 2..<(LevelsHistogram.bins - 2)
    let combed = LevelsHistogram.counts(spread(coarse: true), black: 0, white: 1)[1], smooth = LevelsHistogram.counts(spread(coarse: false), black: 0, white: 1)[1]
    let empty = inside.filter { combed[$0] == 0 }.count
    // 512 fine steps from black to white over 128 bars: four each.
    try check(empty > 20 && inside.allSatisfy { abs(smooth[$0] - 4) < 0.01 },
      "色阶's histogram is drawn from the fine counts: an even spread of tones fills every bar (from the coarse ones \(empty) of \(inside.count) were empty)")

    do {
      // Lightroom's presence, mixer and grading, on the picture as shown (`ImagePipeline.looks`).
      func patch(_ draw: (Int, Int) -> (Double, Double, Double), _ s: Adjustments) -> (CIImage, CIImage) {
        let n = 64
        var px = [Float](repeating: 1, count: n * n * 4)
        for y in 0..<n { for x in 0..<n { let c = draw(x, y); (px[(y * n + x) * 4], px[(y * n + x) * 4 + 1], px[(y * n + x) * 4 + 2]) = (Float(c.0), Float(c.1), Float(c.2)) } }
        let image = CIImage(bitmapData: Data(bytes: px, count: px.count * 4), bytesPerRow: n * 16, size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: nil)
        return (image, pipe.looks(image, s))
      }
      func values(_ image: CIImage) -> [[Float]] {
        let e = image.extent, n = Int(e.width)
        var px = [Float](repeating: 0, count: n * Int(e.height) * 4)
        px.withUnsafeMutableBytes { pipe.context.render(image, toBitmap: $0.baseAddress!, rowBytes: n * 16, bounds: e, format: .RGBAf, colorSpace: nil) }
        return stride(from: 0, to: px.count, by: 4).map { Array(px[$0..<$0 + 3]) }
      }
      func lumaSD(_ v: [[Float]]) -> Double {
        let l = v.map { 0.2126 * Double($0[0]) + 0.7152 * Double($0[1]) + 0.0722 * Double($0[2]) }
        let mean = l.reduce(0, +) / Double(l.count)
        return (l.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(l.count)).squareRoot()
      }
      var crisp = Adjustments()
      (crisp.clarity, crisp.texture) = (1, 1)
      let (grey, crisped) = patch({ x, y in let v = 0.5 + 0.04 * sin(Double(x) * 0.6) * cos(Double(y) * 0.5); return (v, v, v) }, crisp)
      let before = values(grey), after = values(crisped)
      let neutral = after.allSatisfy { (p: [Float]) -> Bool in
        let rg: Float = abs(p[0] - p[1]), gb: Float = abs(p[1] - p[2])
        return rg < 1e-4 && gb < 1e-4
      }
      try check(lumaSD(after) > lumaSD(before) * 1.2 && neutral,
        String(format: "clarity and texture +1 raise a grey texture's local contrast (%.3f → %.3f) and leave a grey grey", lumaSD(before), lumaSD(after)))
      var clear = Adjustments()
      clear.dehaze = 1
      let (hazy, cleared) = patch({ x, _ in let v = 0.45 + (x % 8 < 4 ? 0.25 : 0); return (v, v * 0.98, v * 0.95) }, clear)
      let hazyMin = values(hazy).map { $0.min()! }.min()!, clearedMin = values(cleared).map { $0.min()! }.min()!
      try check(clearedMin < hazyMin - 0.05 && lumaSD(values(cleared)) > lumaSD(values(hazy)),
        String(format: "dehaze +1 takes a veil off: the darkest from %.2f to %.2f, the contrast up", hazyMin, clearedMin))
      var mixed = Adjustments()
      mixed[mixer: 5, kind: 1] = -1
      let (colours, remixed) = patch({ x, _ in x < 21 ? (0.2, 0.3, 0.8) : x < 42 ? (0.8, 0.25, 0.2) : (0.5, 0.5, 0.5) }, mixed)
      let c0 = values(colours), c1 = values(remixed)
      func spread(_ v: [Float]) -> Float { v.max()! - v.min()! }
      try check(spread(c1[32 * 64 + 10]) < spread(c0[32 * 64 + 10]) * 0.6 && abs(spread(c1[32 * 64 + 30]) - spread(c0[32 * 64 + 30])) < 0.02
        && spread(c1[32 * 64 + 55]) < 1e-4,
        String(format: "the mixer's blue saturation −1 takes the blue towards grey (spread %.2f → %.2f), leaves a red and a grey as they were", spread(c0[32 * 64 + 10]), spread(c1[32 * 64 + 10])))
      var graded = Adjustments()
      graded.grading = ColourGrading(shadowHue: 240, shadowAmount: 1)
      let (ramp, tinted) = patch({ x, _ in let v = Double(x) / 63; return (v, v, v) }, graded)
      let dark = values(tinted)[32 * 64 + 10], light = values(tinted)[32 * 64 + 60], darkWas = values(ramp)[32 * 64 + 10]
      let darkLuma = 0.2126 * dark[0] + 0.7152 * dark[1] + 0.0722 * dark[2], wasLuma = 0.2126 * darkWas[0] + 0.7152 * darkWas[1] + 0.0722 * darkWas[2]
      try check(dark[2] > dark[0] + 0.03 && abs(darkLuma - wasLuma) < 0.002 && spread(light) < 0.01,
        String(format: "grading the shadows blue turns a dark grey blue (red %.3f, blue %.3f), its lightness kept, and leaves a light grey grey", dark[0], dark[2]))
      var vivid = Adjustments()
      vivid.vibrance = 1
      let plainBands = try render(defaults, portra), vividBands = try render(vivid, portra)
      func chroma(_ r: Raster, _ y: Int) -> Double { let p = r.pixel(w / 2, y); return (max(p.r, p.g, p.b) - min(p.r, p.g, p.b)) * 255 }
      try check(chroma(vividBands, h * 5 / 8) > chroma(plainBands, h * 5 / 8) + 2 && chroma(vividBands, 4) < chroma(plainBands, 4) + 1,
        String(format: "vibrance +1 adds colour to a tinted band (%.0f → %.0f) and leaves the neutral one neutral", chroma(plainBands, h * 5 / 8), chroma(vividBands, h * 5 / 8)))
    }
  }
}
