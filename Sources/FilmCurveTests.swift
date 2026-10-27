import CoreGraphics
import Foundation

/// The film's toe: the data-sheet widths, the inverse in the conversion, and calibrating it.
enum FilmCurveTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    let portra = FilmProfile.builtins.first { $0.id == "portra160" }!
    let sheet = portra.dataSheetToe!
    try check(FilmProfile.builtins.allSatisfy { $0.toe == nil }
      && FilmProfile.builtins.filter { $0.dataSheetToe != nil }.count == 3,
      "the Kodak presets record their data sheets' toes but convert with the straight line")
    try check(FilmProfile(
      id: "portra160-v850-abc123", name: "n", aliases: [], iso: 160, process: "", sourceURL: "", publication: "",
      slopes: portra.slopes, notes: "").dataSheetToe == sheet, "a preset calibrated from a film finds its data sheet's toe")
    let roundTrip = stride(from: -0.1, through: 2.0, by: 0.05).map { x in
      abs(FilmToe.exposure(FilmToe.density(x, width: 0.16), width: 0.16) - x)
    }.max()!
    try check(roundTrip < 1e-9, String(format: "the toe and its inverse agree to %.0e in log exposure", roundTrip))
    try check(abs(FilmToe.exposure(1.5, width: 0.16) - 1.5) < 1e-4 && abs(FilmToe.density(1.5, width: 0.16) - 1.5) < 1e-4,
      "on the straight part nothing changes")
    let atBase = FilmToe.exposure(0, width: 0.16), below = FilmToe.exposure(-0.2, width: 0.16) - FilmToe.exposure(-0.1, width: 0.16)
    try check(abs(atBase - 0.16 * log(FilmToe.floor)) < 1e-9 && abs(below + 0.1) < 1e-9,
      String(format: "at the base the expansion stops at %.2f, and goes on one to one below it, so grain is not blown up", atBase))
    var bad = portra
    bad.toe = RGB(r: 0.16, g: -0.1, b: 0.15)
    var rejected = false
    do { try bad.validate() } catch { rejected = true }
    try check(rejected, "a preset with an impossible toe is refused")

    // A film whose red and blue toes are wider than its data sheet says, as on a V850 roll.
    let truth = RGB(r: 0.50, g: 0.55, b: 0.66), widths = RGB(r: 0.22, g: sheet.g, b: 0.30)
    let base = RGB(r: 0.80, g: 0.52, b: 0.33)
    var film = portra
    film.toe = widths
    // A grey ramp on it down into the toe, scanned linear.
    func ramp(_ low: Double, _ high: Double) -> CGImage {
      let w = 200, h = 40
      var samples = [UInt16](repeating: 65535, count: w * h * 4)
      for y in 0..<h {
        for x in 0..<w {
          let l = low + (high - low) * Double(x) / Double(w - 1)
          for c in 0..<3 {
            let v = base.values[c] * pow(10, -truth.values[c] * FilmToe.density(l, width: widths.values[c]))
            samples[(y * w + x) * 4 + c] = UInt16(max(0, min(1, v)) * 65535)
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
    var measured = Adjustments()
    measured.inputGamma = 1
    measured.rollBase = base
    measured.rollSlopes = truth
    let shadows = ramp(-0.2, 1.2)
    func render(_ p: FilmProfile) throws -> Raster { pipe.raster(try pipe.preview(shadows, settings: measured, profile: p), maxDimension: 200) }
    /// The largest channel spread from the shadows up, in 8-bit levels. With the straight line the
    /// toe's bend reaches here too: white balance lines up black points the toe has moved.
    func rampCast(_ r: Raster) -> Double {
      (60..<180).map { x -> Double in let p = r.pixel(x, 20).values; return (p.max()! - p.min()!) * 255 }.max()!
    }
    /// Two shadow tones 0.21 log exposure apart (left is less exposure), in 8-bit levels.
    func step(_ r: Raster) -> Double { (r.pixel(50, 20).g - r.pixel(20, 20).g) * 255 }
    let bentOut = try render(film), straightOut = try render(portra)
    try check(rampCast(bentOut) < 1.5 && rampCast(straightOut) > rampCast(bentOut) + 3,
      String(format: "converting with the film's own toe keeps a grey ramp grey: %.1f levels of cast, %.1f with the straight line",
        rampCast(bentOut), rampCast(straightOut)))
    try check(step(bentOut) > step(straightOut) * 1.2,
      String(format: "and opens the shadows: a shadow step of %.1f levels, %.1f with the straight line", step(bentOut), step(straightOut)))
    var guessed = measured
    guessed.rollBase = nil
    try check(ImagePipeline.toe(guessed, film) == .zero && ImagePipeline.toe(measured, film) == widths,
      "the toe bends only from a measured film base, not one guessed from the frame")

    // Calibrating it: neutrals from a grey card bracket, the darkest two in the toe.
    let offsets = RGB(r: 0.04, g: 0, b: -0.05)
    func neutrals(_ exposures: [Double]) -> [NeutralPoint] {
      exposures.map { l in
        let value = RGB((0..<3).map { c in
          base.values[c] * pow(10, -truth.values[c] * FilmToe.density(l + offsets.values[c], width: widths.values[c]))
        })
        return NeutralPoint(frame: UUID(), value: value, base: base, gamma: 1)
      }
    }
    let bracket = try FilmCalibration.fit(neutrals([0.02, 0.18, 0.5, 0.9, 1.4]), greenSlope: truth.g, curve: sheet)
    try check(abs(bracket.slopes.r - truth.r) < 0.01 && abs(bracket.slopes.b - truth.b) < 0.01
      && abs(bracket.toe!.r - widths.r) < 0.02 && abs(bracket.toe!.b - widths.b) < 0.02 && bracket.residual < 0.01,
      String(format: "neutrals reaching into the shadows calibrate the toes too: R %.3f / %.2f · B %.3f / %.2f (true %.2f / %.2f · %.2f / %.2f)",
        bracket.slopes.r, bracket.toe!.r, bracket.slopes.b, bracket.toe!.b, truth.r, widths.r, truth.b, widths.b))
    let preset = FilmCalibration.profile(from: bracket, basedOn: portra, points: 5, scanner: "EPSON V800/V850")
    try check(preset.toe == bracket.toe && preset.notes.contains("趾部"), "and the preset converts with them")
    let midtones = try FilmCalibration.fit(neutrals([0.5, 0.9, 1.4]), greenSlope: truth.g, curve: sheet)
    try check(midtones.toe == nil, "three mid-tone neutrals calibrate the straight line, as before")
  }
}
