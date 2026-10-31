import CoreImage
import CoreGraphics
import Foundation

/// Highlights past the white keep their gradation on screen: the shoulder reaches as far as the
/// frame's brightest, the midtones as they were, a frame with nothing past white as before;
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
      let kept = (ImagePipeline.reachStops, ImagePipeline.highlightsReach)
      (ImagePipeline.reachStops, ImagePipeline.highlightsReach) = (0, 0)
      defer { (ImagePipeline.reachStops, ImagePipeline.highlightsReach) = kept }
      return try body()
    }
    func strip(_ r: Raster) -> [Double] { (stripStart..<stripStart + stripLength).map { r.pixel($0, stripRow).g * 255 } }
    func rising(_ v: [Double]) -> Bool { zip(v, v.dropFirst()).allSatisfy { $1 >= $0 - 0.5 } }
    let reached = try render(bright), held = try short { try render(bright) }
    let now = strip(reached), before = strip(held)
    // From one stop past white (half way along the band) to two.
    let half = stripLength / 2
    let graded = now.last! - now[half], flat = before.last! - before[half]
    try check(graded > 6 && flat < 3 && now.last! < 254.5 && rising(now),
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

    // Highlights −1 reaches two stops further: the white itself comes in, the band still graded.
    var lower = Adjustments()
    lower.highlights = -1
    let top = alone.pixel(w - 20, 10).g * 255, pulled = try render(plain, lower).pixel(w - 20, 10).g * 255
    let lowered = strip(try render(bright, lower))
    try check(pulled < top - 15 && lowered.last! < now.last! && rising(lowered) && lowered.last! - lowered[half] > 4,
      String(format: "highlights −1 brings the white in (%.0f → %.0f) and the band down with it, still graded (%.0f…%.0f)",
        top, pulled, lowered[half], lowered.last!))
    var cut = lower
    cut.softEnds = false
    try check(ImagePipeline.shoulder(cut, a).w == 0, "cut straight at the ends, the shoulder never reaches past white")

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
        image, one, one, none, one, none, CIVector(x: 0, y: 1, z: 0, w: 1), CIVector(x: 0, y: 1, z: 1, w: 1.6),
        CIVector(x: 0, y: 0, z: 0, w: 1), CIVector(x: 0, y: 0.9, z: 0, w: 0), 0.0, CIVector(x: 0, y: 1), CIVector(x: 0, y: 0),
        CIVector(x: 0, y: 0, z: 0, w: 0),
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
    let old = try JSONDecoder().decode(RollPrint.self, from: Data(#"{"balance":{"r":0,"g":0,"b":0},"gain":{"r":1,"g":1,"b":1},"low":0.1,"high":1.5}"#.utf8))
    try check(old.reach == nil && old.high == 1.5, "a roll print kept before it had a reach still reads, without one")
  }
}
