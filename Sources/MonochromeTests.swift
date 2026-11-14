import CoreGraphics
import Foundation

/// Black and white negatives: one layer of silver on a base that may be stained or tinted. Read as
/// one channel, the base divided out, the picture comes out grey whatever the stain, the film
/// preset's channel calibration and the colour settings left out; the roll switched between colour,
/// black and white and slides as one edit each, and a picture copied in after joins its film.
enum MonochromeTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    func linear(_ w: Int, _ h: Int, _ value: (Int, Int) -> RGB) -> CGImage {
      var px = [UInt16](repeating: 0, count: w * h * 3)
      for y in 0..<h {
        for x in 0..<w {
          let v = value(x, y)
          for c in 0..<3 { px[(y * w + x) * 3 + c] = UInt16((min(1, max(0, v.values[c])) * 65535).rounded()) }
        }
      }
      let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6,
        space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    func text(_ v: RGB) -> String { v.values.map { String(format: "%.3f", $0) }.joined(separator: " ") }

    // A strip of B&W film on a yellowed base, clear film down the left; six patches of silver, thin
    // to dense, three across and two down, each 60 by 75 pixels. Silver is near neutral but not
    // quite, and the stain is the base's: read as colour, neither is neutral.
    let base = RGB(r: 0.72, g: 0.6, b: 0.41), silver = [0.96, 1.0, 1.07]
    let densities = [0.15, 0.35, 0.55, 0.75, 0.95, 1.15]
    let negative = linear(200, 150) { x, y in
      guard x >= 20 else { return base }
      let d = densities[min(1, y / 75) * 3 + min(2, (x - 20) / 60)]
      return RGB((0..<3).map { base.values[$0] * pow(10, -d * silver[$0]) })
    }
    func shown(_ s: Adjustments, _ profile: FilmProfile = FilmProfile.builtins[0], patch: Int) throws -> RGB {
      let r = pipe.raster(try pipe.preview(negative, settings: s, profile: profile))
      let (col, row) = (patch % 3, patch / 3)
      var sum = [0.0, 0.0, 0.0]
      for dy in -5...5 { for dx in -5...5 { let p = r.pixel(20 + col * 60 + 30 + dx, row * 75 + 37 + dy).values; for c in 0..<3 { sum[c] += p[c] } } }
      return RGB(sum.map { $0 / 121 })
    }
    func grey(_ v: RGB, _ e: Double = 0.006) -> Bool { abs(v.r - v.g) < e && abs(v.b - v.g) < e }

    var s = Adjustments()
    s.inputGamma = 1
    s.setMonochrome(true)
    var plain = Adjustments()
    plain.autoWhiteBalance = false
    plain.warmth = 0.2
    var roundTrip = plain
    roundTrip.setMonochrome(true)
    let wasMono = roundTrip.isMonochrome
    roundTrip.setMonochrome(false)
    var fromSlide = Adjustments()
    fromSlide.setReversal(true)
    fromSlide.setMonochrome(true)
    try check(s.isMonochrome && s.inputIsNegative && !s.isSlide && wasMono && roundTrip == plain
      && fromSlide.isMonochrome && !fromSlide.isSlide && fromSlide.autoWhiteBalance,
      "a black and white negative is a negative read as one layer; colour, black and white and colour again is as it was, and from a slide a negative's auto white balance")
    // Colour settings left over from a colour roll, or turned by mistake, do nothing to it.
    s.warmth = 0.4
    s.tint = -0.2
    s.shadowWarmth = 0.3
    // And a grey picked while the roll was read as colour: a colour reading, which balanced the one
    // layer by it (a green picture, found on a real roll).
    s.neutralSample = RGB((0..<3).map { base.values[$0] * pow(10, -0.55 * silver[$0]) * [1.12, 0.9, 1.0][$0] })
    let tones = try (0..<6).map { try shown(s, patch: $0) }
    let ordered = zip(tones, tones.dropFirst()).allSatisfy { $1.g > $0.g + 0.02 }
    try check(tones.allSatisfy { grey($0) } && ordered,
      "on a stained base every patch comes out grey, thin to dense dark to light, the warmth, tint and colour grey left over doing nothing: \(tones.map(text).joined(separator: " | "))")
    var colour = s
    colour.monochrome = nil
    let asColour = try (0..<6).map { try shown(colour, patch: $0) }
    try check(asColour.contains { !grey($0, 0.02) }, "read as colour the same negative is not grey: \(asColour.map(text).joined(separator: " | "))")
    // The film preset's per-channel contrast and toes are a colour film's: a black and white
    // negative comes out the same under any.
    let ektar = FilmProfile.builtins.first { $0.name.contains("Ektar") } ?? FilmProfile.builtins[1]
    let underEktar = try (0..<6).map { try shown(s, ektar, patch: $0) }
    let apart = zip(tones, underEktar).map { a, b in zip(a.values, b.values).map { abs($0 - $1) }.max()! }.max()!
    try check(apart < 0.006, String(format: "the film preset's channel calibration is left out: under Ektar at most %.4f apart", apart))
    // Its base picked on the clear film, as on a colour roll: the same.
    var picked = s
    picked.base = base
    let pickedTones = try (0..<6).map { try shown(picked, patch: $0) }
    try check(pickedTones.allSatisfy { grey($0) }, "a base picked on the clear film keeps every patch grey: \(pickedTones.map(text).joined(separator: " | "))")

    // A roll of files switched from colour to black and white, to slides and back, each one edit;
    // a picture copied in after joins its film.
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("monochrome-files"), preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    let decoded = folder.appendingPathComponent("monochrome-files/Decoded", isDirectory: true)
    try? FileManager.default.removeItem(at: decoded)
    try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
    for n in 1...2 {
      let url = decoded.appendingPathComponent("BW0000\(n).tif")
      try pipe.saveTIFF(negative, to: url, dpi: 2400)
      model.addCapturedFrame(url, original: url, linear: true)
    }
    let startsColour = model.rollKind == .colour && !model.frames.contains { $0.adjustments.isMonochrome }
    model.setRollKind(.monochrome)
    let toMono = model.rollKind == .monochrome && model.frames.allSatisfy { $0.adjustments.isMonochrome }
    edits.undo()
    let undone = model.rollKind == .colour && !model.frames.contains { $0.adjustments.isMonochrome }
    edits.redo()
    let url = decoded.appendingPathComponent("BW00003.tif")
    try pipe.saveTIFF(negative, to: url, dpi: 2400)
    model.addCapturedFrame(url, original: url, linear: true)
    let joined = model.frames.count == 3 && model.frames.last!.adjustments.isMonochrome
    model.setRollKind(.slide)
    let toSlides = model.rollKind == .slide && model.frames.allSatisfy { $0.adjustments.isSlide && !$0.adjustments.isMonochrome }
    model.setRollKind(.monochrome)
    let back = model.rollKind == .monochrome && model.frames.allSatisfy { $0.adjustments.isMonochrome && !$0.adjustments.isSlide }
    // A reset keeps it black and white, as it keeps a slide a slide.
    model.select(model.frames[0].id)
    model.change("曝光") { $0.exposure = 0.5 }
    model.resetAdjustments()
    let kept = model.settings.isMonochrome
    try check(startsColour && toMono && undone && joined && toSlides && back && kept,
      "a roll switches colour → black and white (one edit, undone as one) → slides → black and white; a picture copied in after joins it, and a reset keeps it black and white")
  }
}
