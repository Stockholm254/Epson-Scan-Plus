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
    var brighter = defaults
    brighter.exposure = 1
    let mid = matching.pixel(w / 2, 4).g * 255, lifted = try render(brighter, portra).pixel(w / 2, 4).g * 255
    try check(lifted > mid + 20, String(format: "+1 EV brightens the midtones: %.0f → %.0f", mid, lifted))
    // Shadows and highlights move their own tones along the neutral ramp, black and white held,
    // the ramp still rising.
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
      && abs(up[0] - plain[0]) < 2 && plain[0] < 1 && highlights(try render(held, portra)).last! > 254.5 && rising(up) && rising(down) && rising(crossed),
      String(format: "shadows +1 lifts the dark tones (%.0f → %.0f) more than the light, highlights −1 lowers the light (%.0f → %.0f) more than the dark; black and white stay, and the ramp keeps rising",
        at(plain, dark), at(up, dark), at(plain, light), at(down, light)))
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
  }
}
