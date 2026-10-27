import CoreGraphics
import CoreImage
import Foundation

/// The no-preset fallback (channel slopes estimated across the roll), RGB curves, and the
/// settings that moved into the main window.
enum RollCurveTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    let portra = FilmProfile.builtins.first { $0.id == "portra160" }!
    let generic = FilmProfile.builtins.first { $0.id == "generic" }!
    let base = RGB(r: 0.80, g: 0.52, b: 0.33)
    // A film whose channel slopes differ from the Portra 160 data sheet, as a real scanner's do.
    let truth = RGB(r: 0.51, g: 0.55, b: 0.65)
    func image16(_ w: Int, _ h: Int, _ value: (Int, Int) -> RGB) -> CGImage {
      var samples = [UInt16](repeating: 65535, count: w * h * 4)
      for y in 0..<h {
        for x in 0..<w {
          let v = value(x, y).values
          for c in 0..<3 { samples[(y * w + x) * 4 + c] = UInt16(max(0, min(1, v[c])) * 65535) }
        }
      }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    /// Grey scenes on that film: log exposure from `low` to `high` across the frame, bent by `toe`
    /// near the base when given, as a real film's curve is.
    func neutral(_ low: Double, _ high: Double, toe: RGB? = nil) -> CGImage {
      image16(200, 140) { x, y in
        let l = low + (high - low) * (Double(x) / 199 * 0.8 + Double(y % 7) / 6 * 0.2)
        return RGB((0..<3).map { base.values[$0] * pow(10, -truth.values[$0] * FilmToe.density(l, width: toe?.values[$0] ?? 0)) })
      }
    }
    var linear = Adjustments()
    linear.inputGamma = 1
    linear.rollBase = base

    // A roll of frames that each cover part of the tonal range.
    let roll = [neutral(0.2, 0.9), neutral(0.6, 1.5), neutral(1.1, 2.0)].map { (image: $0, settings: linear) }
    guard let estimated = pipe.rollSlopes(roll, greenSlope: truth.g) else {
      throw DeskError.message("FAIL: channel slopes estimated across the roll")
    }
    try check(abs(estimated.r / truth.r - 1) < 0.03 && abs(estimated.b / truth.b - 1) < 0.03 && estimated.g == truth.g,
      String(format: "roll estimate recovers the film's channel slopes: R %.3f · B %.3f (true %.2f · %.2f)",
        estimated.r, estimated.b, truth.r, truth.b))
    try check(pipe.rollSlopes(Array(roll.prefix(1)), greenSlope: truth.g) == nil, "no roll estimate from a single frame")
    let flat = [neutral(0.8, 0.85), neutral(0.8, 0.85)].map { (image: $0, settings: linear) }
    try check(pipe.rollSlopes(flat, greenSlope: truth.g) == nil, "no roll estimate from frames without detail")
    // Scene colour that goes with brightness, as on a seaside roll: a bright blue sky over darker,
    // warmer ground, each with its own shading. Global statistics read the sky's blue as blue
    // contrast; local gradients do not.
    func seaside(_ shift: Double) -> CGImage {
      image16(200, 140) { x, y in
        let shading = 0.18 * sin(Double(x) / 5 + shift) * cos(Double(y) / 7) + 0.06 * Double((x / 9 + y / 11) % 3)
        let sky = y < 60
        let l = (sky ? 1.6 : 0.5) + shading + shift * 0.1
        let cast = sky ? [-0.05, 0, 0.12] : [0.08, 0, -0.1]  // log exposure per channel
        return RGB((0..<3).map { base.values[$0] * pow(10, -truth.values[$0] * (l + cast[$0])) })
      }
    }
    let coast = (0..<4).map { (image: seaside(Double($0)), settings: linear) }
    guard let fromEdges = pipe.rollSlopes(coast, greenSlope: truth.g) else {
      throw DeskError.message("FAIL: channel slopes estimated on a seaside roll")
    }
    try check(abs(fromEdges.r / truth.r - 1) < 0.03 && abs(fromEdges.b / truth.b - 1) < 0.03,
      String(format: "a blue sky over warm ground does not bias the roll estimate: R %.3f · B %.3f (true %.2f · %.2f)",
        fromEdges.r, fromEdges.b, truth.r, truth.b))

    // Precedence: a preset calibrated on this scanner, then the roll estimate, then the data sheet.
    let calibrated = FilmCalibration.profile(
      from: FilmCalibration.Fit(slopes: truth, offsets: RGB(r: 0.02, g: 0, b: -0.03), residual: 0.01, span: 1.2),
      basedOn: portra, points: 3, scanner: "EPSON V800/V850")
    var withRoll = linear
    withRoll.rollSlopes = RGB(r: 0.6, g: 0.55, b: 0.6)
    try check(ImagePipeline.slopes(withRoll, calibrated) == (calibrated.slopes, true), "a calibrated preset wins over the roll estimate")
    try check(ImagePipeline.slopes(withRoll, portra) == (withRoll.rollSlopes!, true), "the roll estimate wins over the data sheet")
    try check(ImagePipeline.slopes(linear, portra) == (portra.slopes, true), "without an estimate the data sheet sets channel contrast")
    try check(!ImagePipeline.slopes(linear, generic).fixed, "only generic without an estimate stretches each frame")

    // On a film with a toe (Portra 160's data sheet, as a calibrated preset could have), the
    // estimate weighs each edge by the toe's stretch there.
    let sheet = portra.dataSheetToe
    let toeRoll = [neutral(0.05, 0.9, toe: sheet), neutral(0.4, 1.5, toe: sheet), neutral(1.0, 2.0, toe: sheet)]
      .map { (image: $0, settings: linear) }
    guard let bent = pipe.rollSlopes(toeRoll, greenSlope: truth.g, toe: sheet),
      let straight = pipe.rollSlopes(toeRoll, greenSlope: truth.g)
    else { throw DeskError.message("FAIL: channel slopes estimated on a roll with a toe") }
    try check(abs(bent.r / truth.r - 1) < 0.03 && abs(bent.b / truth.b - 1) < 0.03,
      String(format: "with the film's toe the roll estimate still recovers the slopes: R %.3f · B %.3f (straight line R %.3f · B %.3f, true %.2f · %.2f)",
        bent.r, bent.b, straight.r, straight.b, truth.r, truth.b))

    // What the estimate is for: a grey ramp converted with it stays grey.
    func cast(_ settings: Adjustments) throws -> Double {
      let out = pipe.raster(try pipe.preview(neutral(0.3, 1.7), settings: settings, profile: portra), maxDimension: 200)
      return (20..<180).map { x -> Double in
        let p = out.pixel(x, 70).values
        return (p.max()! - p.min()!) * 255
      }.max()!
    }
    var estimatedSettings = linear
    estimatedSettings.rollSlopes = estimated
    let before = try cast(linear), after = try cast(estimatedSettings)
    try check(after < 2.5 && after <= before,
      String(format: "the roll estimate keeps a grey ramp grey: %.1f levels of cast, %.1f with the data sheet", after, before))

    // A film calibrated on this scanner is picked by name, without opening the preset menu.
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("roll-offline"), preferences: Preferences(defaults: defaults))
    model.keepProfile(calibrated)
    model.filmName = portra.name
    model.matchFilm()
    try check(model.profile == calibrated, "typing the film name picks its V850 preset")
    model.chooseProfile(portra)
    try check(model.profile == portra, "the data-sheet preset can still be chosen by hand")

    // Curves: identity, monotone through their points, and the RGB curve before the channels.
    var curves = ToneCurves()
    let identity = curves.table(256)
    try check(curves.isIdentity && (0..<256).allSatisfy { i in (0..<3).allSatisfy { abs(Double(identity[i * 4 + $0]) - Double(i) / 255) < 1e-5 } },
      "the default curves leave every level unchanged")
    curves.rgb.points.insert(CurvePoint(x: 0.4, y: 0.55), at: 1)
    let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { curves.rgb.value($0) }
    try check(abs(curves.rgb.value(0.4) - 0.55) < 1e-9 && zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 },
      "a lifted RGB curve passes through its point and never turns back")
    curves.red.points.insert(CurvePoint(x: 0.5, y: 0.4), at: 1)
    let table = curves.table(1024)
    let at = Int((0.4 * 1023).rounded())
    try check(abs(Double(table[at * 4]) - curves.red.value(curves.rgb.value(Double(at) / 1023))) < 1e-5
      && abs(Double(table[at * 4 + 1]) - curves.rgb.value(Double(at) / 1023)) < 1e-5,
      "channel curves apply after the RGB curve")
    func pixel(_ image: CIImage) -> [Float] {
      var p = [Float](repeating: 0, count: 4)
      pipe.context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
      return p
    }
    let grey = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    let curved = pixel(pipe.applyCurves(curves, to: grey))
    try check(abs(Double(curved[1]) - 0.55) < 0.004 && abs(Double(curved[0]) - curves.red.value(0.55)) < 0.004
      && abs(Double(curved[2]) - 0.55) < 0.004,
      String(format: "the curve kernel follows the curves: grey 0.40 → R %.3f G %.3f B %.3f", curved[0], curved[1], curved[2]))
    let untouched = pixel(pipe.applyCurves(ToneCurves(), to: grey))
    try check(untouched.prefix(3).allSatisfy { abs($0 - 0.4) < 1e-4 }, "identity curves leave the image untouched")

    // In the conversion the curves act on the finished positive, level for level.
    var plainSettings = linear
    plainSettings.rollSlopes = estimated
    var curvedSettings = plainSettings
    curvedSettings.curves = curves
    let ramp = neutral(0.3, 1.7)
    let plain = pipe.raster(try pipe.preview(ramp, settings: plainSettings, profile: portra), maxDimension: 200)
    let shaped = pipe.raster(try pipe.preview(ramp, settings: curvedSettings, profile: portra), maxDimension: 200)
    let worst = stride(from: 20, to: 180, by: 8).map { x -> Double in
      let p = plain.pixel(x, 70), q = shaped.pixel(x, 70)
      let g = curves.rgb.value(p.g), r = curves.red.value(curves.rgb.value(p.r))
      return max(abs(q.g - g), abs(q.r - r)) * 255
    }.max()!
    try check(worst < 3, String(format: "curves apply to the converted positive: within %.1f levels", worst))
    let decoded = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(curvedSettings))
    try check(decoded == curvedSettings, "curves and roll slopes are kept in the project")

    // Settings now in the main window: automatic export and the panel widths.
    try check(Preferences(defaults: defaults).autoExport, "scans are exported as positives unless turned off")
    let saved = Preferences(defaults: defaults)
    saved.autoExport = false
    saved.leftWidth = 300
    saved.rightWidth = 360
    let reloaded = Preferences(defaults: defaults)
    try check(!reloaded.autoExport && reloaded.leftWidth == 300 && reloaded.rightWidth == 360,
      "turning automatic export off and the panel widths persist")
    defaults.set(9999.0, forKey: "leftWidth")
    defaults.set(1.0, forKey: "rightWidth")
    let clamped = Preferences(defaults: defaults)
    try check(clamped.leftWidth == Preferences.leftWidths.upperBound && clamped.rightWidth == Preferences.rightWidths.lowerBound,
      "stored panel widths are kept within range")
    let fresh = Preferences()
    try check(!fresh.autoExport && fresh.leftWidth == 230 && fresh.rightWidth == 258,
      "in-memory settings never export on their own")
  }
}
