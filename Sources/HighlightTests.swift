import CoreImage
import CoreGraphics
import Foundation

/// Highlights past the white keep their gradation on screen: the shoulder reaches as far as the
/// frame's brightest, the midtones as they were, a frame with nothing past white as before; the
/// shoulder rolls off the light and leaves the detail in it, with no rim at a sharp edge;
/// highlights −1 takes it further; a bright colour the saturation takes past white eases into it
/// instead of losing a channel; and a roll printed as one reaches as far as its brightest frame.
enum HighlightTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    let portra = FilmProfile.builtins.first { $0.id == "portra160" }!
    let base = RGB(r: 0.85, g: 0.57, b: 0.38)
    // A neutral scene on Portra 160: log exposure ramps across, 0.15 to 1.4; with `strip`, a band
    // two rows deep and 75 columns long, about 0.5% of the frame, runs on from 1.4 to 2.0, two
    // stops more, so the frame's white (its brightest 0.5%) falls at the band's start.
    let w = 300, h = 120, stripRow = 56, stripStart = 110, stripLength = 75
    func negative(strip: Bool) -> CGImage {
      var samples = [UInt16](repeating: 65535, count: w * h * 4)
      for y in 0..<h {
        for x in 0..<w {
          var exposure = 0.15 + 1.25 * Double(x) / Double(w - 1)
          if strip, (stripRow..<stripRow + 2).contains(y), (stripStart..<stripStart + stripLength).contains(x) {
            exposure = 1.4 + 0.6 * Double(x - stripStart) / Double(stripLength - 1)
          }
          for c in 0..<3 {
            samples[(y * w + x) * 4 + c] = UInt16(base.values[c] * pow(10, -portra.slopes.values[c] * exposure / 2.2) * 65535)
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
    let bright = negative(strip: true), plain = negative(strip: false)
    func render(_ image: CGImage, _ s: Adjustments = Adjustments()) throws -> Raster {
      pipe.raster(try pipe.preview(image, settings: s, profile: portra), maxDimension: w)
    }
    /// As before the shoulder reached: held at the white.
    func short<T>(_ body: () throws -> T) rethrows -> T {
      let kept = ImagePipeline.reachStops
      ImagePipeline.reachStops = 0
      defer { ImagePipeline.reachStops = kept }
      return try body()
    }
    func strip(_ r: Raster) -> [Double] { (stripStart..<stripStart + stripLength).map { r.pixel($0, stripRow).g * 255 } }
    func rising(_ v: [Double]) -> Bool { zip(v, v.dropFirst()).allSatisfy { $1 >= $0 - 0.5 } }
    let reached = try render(bright), held = try short { try render(bright) }
    let now = strip(reached), before = strip(held)
    // From one stop past white (half way along the band) to two.
    let half = stripLength / 2
    let graded = now.last! - now[half], flat = before.last! - before[half]
    // A band two pixels deep is partly its own surroundings' detail, which the shoulder keeps only
    // as far as it fits under white: its last stop a little tighter than the shoulder alone gives it.
    try check(graded > 4 && flat < 3 && now.last! < 254.5 && rising(now),
      String(format: "highlights two stops past white keep their gradation: the second stop spans %.0f levels (%.0f…%.0f), where a shoulder held at white gave it %.0f",
        graded, now[half], now.last!, flat))
    // The ramp's tones up to about three quarters as they were; past white the gradation comes
    // from there.
    let midtones = (0..<w).filter { held.pixel($0, 10).g < 0.75 }
    let moved = midtones.map { abs(reached.pixel($0, 10).g - held.pixel($0, 10).g) * 255 }.max() ?? 99
    try check(midtones.count > w / 2 && moved <= 1,
      String(format: "the midtones stay where they were (%d columns, at most %.0f level apart)", midtones.count, moved))
    let alone = try render(plain), aloneHeld = try short { try render(plain) }
    let unchanged = zip(alone.bytes, aloneHeld.bytes).allSatisfy { $0 == $1 }
    let a = pipe.analyze(plain, settings: Adjustments(), profile: portra)
    try check(unchanged && ImagePipeline.shoulder(Adjustments(), a).w == 0,
      "a frame with nothing past its white comes out exactly as before")

    // Highlights −1 brings the bright areas down before the ends: the white itself comes in; the
    // band, the frame's brightest, still graded and short of white, the shoulder taking it from
    // where it now lies.
    var lower = Adjustments()
    lower.highlights = -1
    let top = alone.pixel(w - 20, 10).g * 255, pulled = try render(plain, lower).pixel(w - 20, 10).g * 255
    let lowered = strip(try render(bright, lower))
    try check(pulled < top - 15 && lowered.last! < 254.5 && rising(lowered) && lowered.last! - lowered[half] > 4,
      String(format: "highlights −1 brings the white in (%.0f → %.0f), the band still graded and short of white (%.0f…%.0f)",
        top, pulled, lowered[half], lowered.last!))
    var cut = lower
    cut.softEnds = false
    try check(ImagePipeline.shoulder(cut, a).w == 0, "cut straight at the ends, the shoulder never reaches past white")

    // The shoulder rolls off the light, not the detail in it. A sunlit white (a sign, a lit metal
    // pole) at the frame's white, its texture 0.03 log exposure either way, beside a ramp from the
    // shadows up: with the detail kept the texture shows as on the straight line, where the
    // shoulder alone flattened it; the patch as a whole as light as the shoulder alone made it.
    func scene(_ exposure: (Int, Int) -> Double) -> CGImage {
      var samples = [UInt16](repeating: 65535, count: w * h * 4)
      for y in 0..<h {
        for x in 0..<w {
          let e = exposure(x, y)
          for c in 0..<3 { samples[(y * w + x) * 4 + c] = UInt16(base.values[c] * pow(10, -portra.slopes.values[c] * e / 2.2) * 65535) }
        }
      }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    // The local lightness smooths a texture to its mean and keeps a step as it is: a guided filter
    // on itself (Core Image's own CIGuidedFilter leaves a picture guided by itself unsmoothed).
    do {
      let gw = 80, gh = 20
      var px = [Float](repeating: 1, count: gw * gh * 4)
      for y in 0..<gh { for x in 0..<gw {
        let v = Float((x < 40 ? 0.3 : 0.95) + 0.03 * sin(Double(x) * 1.3) * cos(Double(y) * 1.1))
        for c in 0..<3 { px[(y * gw + x) * 4 + c] = v }
      } }
      let light = CIImage(bitmapData: Data(bytes: px, count: px.count * 4), bytesPerRow: gw * 16, size: CGSize(width: gw, height: gh), format: .RGBAf, colorSpace: nil)
      guard let smooth = ImagePipeline.guided(light, radius: 3, eps: ImagePipeline.detailEdge) else { throw DeskError.message("FAIL: the guided filter runs") }
      var out = [Float](repeating: 0, count: gw * gh * 4)
      out.withUnsafeMutableBytes { pipe.context.render(smooth, toBitmap: $0.baseAddress!, rowBytes: gw * 16, bounds: light.extent, format: .RGBAf, colorSpace: nil) }
      // A row where the texture runs at nearly its full ±0.03 (cos 6.6 ≈ 0.95).
      func at(_ a: [Float], _ x: Int) -> Double { Double(a[(6 * gw + x) * 4]) }
      let flat = (8..<32).map { abs(at(out, $0) - 0.3) }.max()! , flatBright = (48..<72).map { abs(at(out, $0) - 0.95) }.max()!
      let texture = (8..<32).map { abs(at(px, $0) - 0.3) }.max()!
      let edge = [38, 39, 40, 41].map { abs(at(out, $0) - at(px, $0)) }.max()!
      try check(texture > 0.02 && flat < texture * 0.4 && flatBright < texture * 0.4 && edge < 0.12,
        String(format: "the local lightness smooths a texture of ±%.3f to within %.3f of its mean and keeps a step of 0.65 to within %.3f", texture, max(flat, flatBright), edge))
    }
    func withoutDetail<T>(_ body: () throws -> T) rethrows -> T {
      let kept = ImagePipeline.detailReach
      ImagePipeline.detailReach = 0
      defer { ImagePipeline.detailReach = kept }
      return try body()
    }
    let textured = scene { x, y in
      x < 180 ? 0.15 + 1.1 * Double(x) / 179 : 1.32 + 0.03 * sin(Double(x) * .pi / 4) * sin(Double(y) * .pi / 4)
    }
    func patch(_ r: Raster) -> (mean: Double, spread: Double) {
      var v = [Double]()
      for y in 30..<90 { for x in 195..<275 { let p = r.pixel(x, y); v.append((0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b) * 255) } }
      let mean = v.reduce(0, +) / Double(v.count)
      return (mean, (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot())
    }
    var cutAtEnds = Adjustments()
    cutAtEnds.softEnds = false
    let kept = patch(try render(textured)), rolled = try withoutDetail { patch(try render(textured)) }
    let line = patch(try render(textured, cutAtEnds))
    try check(kept.spread > line.spread * 0.85 && kept.spread > rolled.spread * 1.1 && abs(kept.mean - rolled.mean) < 3,
      String(format: "a sunlit white at the frame's white keeps its texture under the shoulder: spread %.1f levels, %.1f on the straight line, %.1f with the shoulder alone; as light as that (%.0f, %.0f)",
        kept.spread, line.spread, rolled.spread, kept.mean, rolled.mean))
    // A smooth ramp has no detail to keep: as the shoulder alone has it.
    let rampKept = try render(bright), rampRolled = try withoutDetail { try render(bright) }
    let rampMoved = (0..<w).map { abs(rampKept.pixel($0, 10).g - rampRolled.pixel($0, 10).g) * 255 }.max() ?? 99
    try check(rampMoved <= 1, String(format: "a smooth ramp comes out as with the shoulder alone (at most %.1f level apart)", rampMoved))
    // A sharp step from dark leaves into the white: no bright rim beside it, the white's inside as before.
    let step = scene { x, _ in x < 150 ? 0.4 : 1.4 }
    let stepKept = try render(step), stepRolled = try withoutDetail { try render(step) }
    let inside = stepKept.pixel(230, 60).g * 255
    let rim = (151..<170).map { stepKept.pixel($0, 60).g * 255 }.max() ?? 0
    try check(rim - inside < 2.5 && abs(inside - stepRolled.pixel(230, 60).g * 255) < 0.5,
      String(format: "a sharp edge into the white leaves no bright rim (%.1f beside it, %.1f inside) and the white as the shoulder alone made it", rim, inside))

    // A bright, saturated blue, as a positive ramp at saturation 1.6 under the soft shoulder.
    let n = 32
    var blue = [Float](repeating: 1, count: n * 4)
    for i in 0..<n { (blue[i * 4], blue[i * 4 + 1], blue[i * 4 + 2]) = (0.55, 0.75, 0.9 + 0.1 * Float(i) / Float(n - 1)) }
    let greys = [Float](repeating: 0.97, count: n * 4)
    func ramp(_ px: [Float]) -> CIImage {
      CIImage(bitmapData: Data(bytes: px, count: px.count * 4), bytesPerRow: n * 16, size: CGSize(width: n, height: 1), format: .RGBAf, colorSpace: nil)
    }
    func out(_ kernel: CIColorKernel?, _ image: CIImage) -> [Float] {
      let one = CIVector(x: 1, y: 1, z: 1), none = CIVector(x: 0, y: 0, z: 0)
      let args: [Any] = [
        image, image, one, one, none, one, none, CIVector(x: 0, y: 1, z: 0, w: 1), CIVector(x: 0, y: 1, z: 1, w: 1.6),
        CIVector(x: 0, y: 0, z: 0, w: 1), CIVector(x: 0, y: 0.9, z: 0, w: 0), 0.0, CIVector(x: 0, y: 1, z: 0, w: 0), CIVector(x: 0, y: 0, z: 0, w: 0),
        CIVector(x: 0, y: 0, z: 0, w: 0), 1.0, CIVector(x: 0, y: 0, z: 0, w: 0),
      ]
      guard let result = kernel?.apply(extent: image.extent, arguments: args) else { return [] }
      var px = [Float](repeating: 0, count: n * 4)
      px.withUnsafeMutableBytes { pipe.context.render(result, toBitmap: $0.baseAddress!, rowBytes: n * 16, bounds: image.extent, format: .RGBAf, colorSpace: nil) }
      return px
    }
    let eased = out(Kernels.negative, ramp(blue)), wide = out(Kernels.negativeUnclipped, ramp(blue))
    let b = (0..<n).map { eased[$0 * 4 + 2] }, past = (0..<n).filter { wide[$0 * 4 + 2] > 1 }.count
    let atWhite = b.filter { $0 >= 254.5 / 255 }.count
    try check(b.count == n && past > n / 2 && atWhite <= n / 4 && zip(b, b.dropFirst()).allSatisfy { $1 > $0 },
      String(format: "a bright blue the saturation takes past white (%d of %d steps) eases into it, every step brighter than the last (%.3f…%.3f), %d at white where it was cut flat; a wide export keeps it",
        past, n, b.first ?? 0, b.last ?? 0, atWhite))
    let neutral = out(Kernels.negative, ramp(greys)), neutralWide = out(Kernels.negativeUnclipped, ramp(greys))
    try check(!neutral.isEmpty && zip(neutral, neutralWide).allSatisfy { abs($0 - $1) < 1e-6 },
      "a bright grey is as it was")

    // A roll printed as one reaches as far as its brightest frame, though it is a seventh of the roll.
    let frames = Array(repeating: (image: plain, settings: Adjustments()), count: 6) + [(image: bright, settings: Adjustments())]
    let roll = pipe.rollPrint(frames, profile: portra), dull = pipe.rollPrint(Array(frames.prefix(6)), profile: portra)
    let own = pipe.rollPrint([(image: bright, settings: Adjustments())], profile: portra)
    if let r = roll?.reach, let d = dull?.reach, let o = own?.reach {
      try check(abs(r - o) < 0.05 && r > d + 0.3,
        String(format: "a roll printed as one reaches as far as its brightest frame: %.2f, that frame alone %.2f, the others %.2f", r, o, d))
    } else {
      try check(false, "a roll printed as one has a reach")
    }
    // Thin bright lines, as a sign's white between its letters, two stops past white over 0.3% of a
    // frame 3000 across: the 300-pixel samples average them into the ramp; counted 1500 across they
    // keep their light, and the shoulder reaches them.
    let across = 3000, tall = 1200
    var lines = [UInt16](repeating: 65535, count: across * tall * 4)
    for y in 0..<tall {
      for x in 0..<across {
        let exposure = (500..<700).contains(y) && (1000..<1600).contains(x) && x % 40 < 4 ? 1.9 : 0.15 + 1.15 * Double(x) / Double(across - 1)
        for c in 0..<3 { lines[(y * across + x) * 4 + c] = UInt16(base.values[c] * pow(10, -portra.slopes.values[c] * exposure / 2.2) * 65535) }
      }
    }
    let lined = CGImage(
      width: across, height: tall, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: across * 8,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
      provider: CGDataProvider(data: Data(bytes: lines, count: lines.count * 2) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
    let measured = pipe.analyze(lined, settings: Adjustments(), profile: portra)
    let counting = ImagePipeline.reachDimension
    ImagePipeline.reachDimension = 0
    let sampled = pipe.analyze(lined, settings: Adjustments(), profile: portra)
    ImagePipeline.reachDimension = counting
    if let c = measured.reach, let s = sampled.reach {
      try check(c > s + 0.3 && ImagePipeline.shoulder(Adjustments(), measured).w > 0 && ImagePipeline.shoulder(Adjustments(), sampled).w == 0,
        String(format: "thin bright lines are counted at 1500 across: they reach %.2f past the white there, %.2f on the 300-pixel samples, and the shoulder reaches them",
          c - measured.high, s - sampled.high))
    } else {
      try check(false, "a frame with thin bright lines has a reach")
    }
    let old = try JSONDecoder().decode(RollPrint.self, from: Data(#"{"balance":{"r":0,"g":0,"b":0},"gain":{"r":1,"g":1,"b":1},"low":0.1,"high":1.5}"#.utf8))
    try check(old.reach == nil && old.high == 1.5, "a roll print kept before it had a reach still reads, without one")

    // The histogram over more than the screen shows: the band's top two stops past the white,
    // its brightest 0.1% about one and a half.
    let ab = pipe.analyze(bright, settings: Adjustments(), profile: portra)
    guard let range = pipe.toneRange(bright, settings: Adjustments(), profile: portra, analysis: ab),
      let heldRange = short({ pipe.toneRange(bright, settings: Adjustments(), profile: portra, analysis: ab) }),
      let white = range.white, let heldWhite = heldRange.white, let stop = range.stop
    else { return try check(false, "a frame's tone range is worked out") }
    let stops = (range.brightest - 1) / stop
    try check(range.pastWhite > 0.003 && stops > 1.2 && stops < 1.9,
      String(format: "the tone range sees past the white: %.2f%% of the frame, its brightest 0.1%% %.1f stops past", range.pastWhite * 100, stops))
    // What it says shows white or black on screen is what does.
    func shares(_ r: Raster) -> (white: Double, black: Double) {
      let all = Double(r.width * r.height)
      let px = (0..<(r.width * r.height)).map { Array(r.bytes[$0 * 4..<$0 * 4 + 3]) }
      return (Double(px.filter { $0.max()! == 255 }.count) / all, Double(px.filter { $0.min()! == 0 }.count) / all)
    }
    let seen = shares(reached), heldSeen = shares(held)
    try check(abs(range.atWhite - seen.white) < 0.001 && abs(heldRange.atWhite - heldSeen.white) < 0.001
      && abs(range.atBlack - seen.black) < 0.001 && heldRange.atWhite > range.atWhite + 0.001,
      String(format: "the screen's white in the tone range is where the picture turns white: %.2f%% said, %.2f%% shown; with the shoulder held at white %.2f%% said, %.2f%% shown",
        range.atWhite * 100, seen.white * 100, heldRange.atWhite * 100, heldSeen.white * 100))
    let heldPicture = try short { try pipe.preview(bright, settings: Adjustments(), profile: portra) }
    let counted = pipe.screenShares(heldPicture)
    try check(abs(counted.white - heldSeen.white) < 1e-5 && abs(counted.black - heldSeen.black) < 1e-5,
      String(format: "counted on the picture as shown, %.3f%% shows white and %.3f%% black, as its pixels have it", counted.white * 100, counted.black * 100))
    try check(white > range.brightest && heldWhite < 1.35 && white > heldWhite + 0.2,
      String(format: "the shoulder takes the screen's white past the frame's brightest (%.2f against %.2f), where held at white it came at %.2f", white, range.brightest, heldWhite))
    var straight = Adjustments()
    straight.softEnds = false
    let cutRange = pipe.toneRange(bright, settings: straight, profile: portra, analysis: pipe.analyze(bright, settings: straight, profile: portra))
    try check(cutRange?.white.map { abs($0 - 1) < 0.01 } == true && (cutRange?.black ?? -1) >= -0.005,
      String(format: "cut straight at the ends, the screen shows from the levels' black to their white (%.3f…%.3f)", cutRange?.black ?? .nan, cutRange?.white ?? .nan))
    var dimmed = Adjustments(), curves = ToneCurves()
    curves.rgb.points[1].y = 0.9
    dimmed.curves = curves
    let dimRange = pipe.toneRange(bright, settings: dimmed, profile: portra, analysis: ab)
    try check(dimRange != nil && dimRange?.white == nil && dimRange?.atWhite == 0,
      "with a curve that takes white down to 0.9, nothing shows white on screen")

    // The curves' marks and histograms stand on the curves' own axis: a colour as shown, in 8 bits,
    // is taken back through them to what it was before them.
    var bent = ToneCurves()
    bent.rgb.points.insert(CurvePoint(x: 0.3, y: 0.38), at: 1)
    bent.red.points.insert(CurvePoint(x: 0.6749, y: 0.5436), at: 1)
    func through(_ x: Double) -> RGB {
      let v = bent.rgb.value(x)
      return RGB([bent.red.value(v), bent.green.value(v), bent.blue.value(v)].map { ($0 * 255).rounded() / 255 })
    }
    let inverse = CurveInverse(bent)
    var worstBack = 0.0
    for i in 1..<20 {
      let x = Double(i) / 20, back = inverse?.input(through(x)) ?? .zero
      worstBack = max(worstBack, abs(back.r - x), abs(back.g - x), abs(back.b - x))
    }
    var clipped = ToneCurves()
    clipped.rgb.points.insert(CurvePoint(x: 0.2, y: 0), at: 1)
    let black = CurveInverse(clipped)?.span(0, 0)
    try check(CurveInverse(ToneCurves()) == nil && CurveInverse(nil) == nil && inverse != nil && worstBack < 0.006
      && black.map { $0.lowerBound == 0 && (0.2...0.24).contains($0.upperBound) } == true,
      String(format: "a colour as shown is taken back through the curves to within %.4f, and black from a curve that clips the shadows stands for all it took (%.3f…%.3f)",
        worstBack, black?.lowerBound ?? .nan, black?.upperBound ?? .nan))
    let grey = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: pipe.outputSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let middle = through(0.5)
    grey.setFillColor(red: middle.r, green: middle.g, blue: middle.b, alpha: 1)
    grey.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    func peaks(_ curves: ToneCurves?) -> [Int] {
      AppModel.histograms(grey.makeImage()!, curves: curves).1.map { h in h.indices.max { h[$0] < h[$1] } ?? -1 }
    }
    let onAxis = peaks(bent), asShown = peaks(nil)
    // Lightroom's parametric curve: each zone moves its own tones, black and white stay, and the
    // curve never falls, whichever way the zones beside are pulled.
    var lifted = ParametricCurve()
    lifted.shadows = 1
    let shadowLift = lifted.curve.value(0.125) - 0.125, highlightsKept = abs(lifted.curve.value(0.875) - 0.875)
    var rising = true
    for signs in 0..<16 {
      var p = ParametricCurve()
      p.amounts = (0..<4).map { signs >> $0 & 1 == 1 ? 1 : -1 }
      p.splits = signs % 3 == 0 ? [0.1, 0.5, 0.9] : [0.25, 0.5, 0.75]
      let c = p.curve, v = (0...200).map { c.value(Double($0) / 200) }
      if zip(v, v.dropFirst()).contains(where: { $1 < $0 - 1e-9 }) || abs(v[0]) > 1e-9 || abs(v[200] - 1) > 1e-9 { rising = false }
    }
    let curvesBefore = #"{"rgb":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"red":{"points":[{"x":0,"y":0},{"x":0.5,"y":0.4},{"x":1,"y":1}]},"green":{"points":[{"x":0,"y":0},{"x":1,"y":1}]},"blue":{"points":[{"x":0,"y":0},{"x":1,"y":1}]}}"#
    let read = try? JSONDecoder().decode(ToneCurves.self, from: Data(curvesBefore.utf8))
    var withParametric = ToneCurves()
    withParametric.parametric = lifted
    let firstThenRGB = withParametric.table(1025)[512 * 4] - Float(lifted.curve.value(0.5))
    try check(shadowLift > 0.1 && highlightsKept < 0.002 && rising && read?.parametric == nil && read?.red.points.count == 3
      && abs(firstThenRGB) < 1e-4 && ParametricCurve().isIdentity,
      String(format: "the parametric curve lifts its shadows by %.3f at full, leaves the highlights (%.4f), never falls with zones pulled apart, comes first, and a project from before it reads with none", shadowLift, highlightsKept))
    // The targeted adjustment: a point curve takes a point where the colour lies, or moves the one
    // there; the parametric curve moves the zone it lies in.
    let once = ToneCurves().targeted(at: 0.5, channel: 0, parametric: false, by: 0.1)
    let twice = once.targeted(at: 0.51, channel: 0, parametric: false, by: -0.05)
    let zoned = ToneCurves().targeted(at: 0.1, channel: 0, parametric: true, by: 0.25)
    var splitOnly = ToneCurves()
    splitOnly.parametric = ParametricCurve(splits: [0.3, 0.5, 0.75])
    let tried = RGB(r: 0.3, g: 0.5, b: 0.7)
    try check(once.rgb.points.count == 3 && abs(once.rgb.points[1].y - 0.6) < 1e-9 && twice.rgb.points.count == 3
      && abs(twice.rgb.points[1].y - 0.55) < 1e-9 && zoned.parametric?.shadows == 0.5 && zoned.parametric?.darks == 0
      && ToneCurves().normalized == nil && splitOnly.normalized != nil
      && abs(ToneCurves().target(tried, channel: 0, parametric: false) - ToneCurves.brightness(tried)) < 1e-9
      && abs(ToneCurves().target(tried, channel: 3, parametric: false) - 0.7) < 1e-9,
      "the targeted adjustment takes a point where the colour lies on the curve, moves the one already there, and on the parametric curve moves the zone the colour lies in")
    // A preset or 重置 moves the drawn curve value by value: half way, each value is half way.
    let fromLine = CurveSamples(values: [0, 0.25, 0.5, 1]), toLine = CurveSamples(values: [0, 0.35, 0.6, 1])
    var halfWay = toLine - fromLine
    halfWay.scale(by: 0.5)
    let halfLine = fromLine + halfWay
    try check(zip(halfLine.values, [0, 0.3, 0.55, 1.0]).allSatisfy { abs($0 - $1) < 1e-12 } && (CurveSamples.zero + toLine) == toLine
      && abs((toLine - fromLine).magnitudeSquared - 0.02) < 1e-12,
      "a curve's drawn values animate value by value, so a preset or 重置 moves the curve to it")
    try check(onAxis == [31, 31, 31] && asShown[0] != 31 && asShown[1] != 31,
      "the curves' histograms count a picture as it was before them, on their axis: a grey printed at 0.5 and bent by the curves peaks at 0.5 (\(onAxis), as shown \(asShown))")
  }
}
