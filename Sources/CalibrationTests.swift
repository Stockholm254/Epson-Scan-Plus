import CoreGraphics
import Foundation

enum CalibrationTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    // The film as this scanner sees it: slopes and neutral offsets (density, green 0) differ from Portra's sheet.
    let slopes = [0.50, 0.55, 0.66], offsets = [0.06, 0.0, -0.09]
    let base = RGB(r: 0.80, g: 0.52, b: 0.33)
    func value(_ exposure: Double, noise: [Double] = [0, 0, 0]) -> RGB {
      RGB((0..<3).map { base.values[$0] * pow(10, -(slopes[$0] * exposure + offsets[$0] + noise[$0])) })
    }
    func point(_ exposure: Double, noise: [Double] = [0, 0, 0]) -> NeutralPoint {
      NeutralPoint(frame: UUID(), value: value(exposure, noise: noise), base: base, gamma: 1)
    }
    for exposures in [[0.4, 1.4], [0.4, 0.9, 1.4]] {
      let fit = try FilmCalibration.fit(exposures.map { point($0) }, greenSlope: 0.55)
      try check((0..<3).allSatisfy { abs(fit.slopes.values[$0] - slopes[$0]) < 1e-9 && abs(fit.offsets.values[$0] - offsets[$0] / slopes[$0]) < 1e-9 }
        && fit.residual < 1e-9, "\(exposures.count) neutral points recover each channel's slope and offset exactly")
    }
    // Five points with ±0.01 D of noise still land close.
    let noise: [[Double]] = [[0.01, -0.01, 0.0], [-0.01, 0.0, 0.01], [0.0, 0.01, -0.01], [0.01, 0.0, 0.01], [-0.01, -0.01, 0.0]]
    let noisy = try FilmCalibration.fit(zip([0.3, 0.6, 0.9, 1.2, 1.5], noise).map { point($0, noise: $1) }, greenSlope: 0.55)
    try check((0..<3).allSatisfy { abs(noisy.slopes.values[$0] / slopes[$0] - 1) < 0.03 },
      String(format: "noisy points: R %.3f · B %.3f, residual %.3f D", noisy.slopes.r, noisy.slopes.b, noisy.residual))
    func fails(_ points: [NeutralPoint]) -> Bool { (try? FilmCalibration.fit(points, greenSlope: 0.55)) == nil }
    // Two points always fit, so a tinted patch only shows once there are three.
    var tinted = point(1.4)
    tinted.value.r *= 0.2
    try check(fails([point(0.8)]) && fails([point(0.8), point(0.95)]) && fails([point(0.3), point(0.9), tinted])
      && !fails([point(0.3), tinted]),
      "calibration refuses one point, a span under 0.3 D, and a tinted patch among three")

    // End to end: a neutral ramp from this film, auto white balance off.
    let w = 240, h = 40
    var samples = [UInt16](repeating: 65535, count: w * h * 4)
    for y in 0..<h {
      for x in 0..<w {
        let v = value(0.2 + 1.4 * Double(x) / Double(w - 1)).values
        for c in 0..<3 { samples[(y * w + x) * 4 + c] = UInt16(v[c] * 65535) }
      }
    }
    let ramp = CGImage(
      width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
      provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
    var settings = Adjustments()
    settings.inputGamma = 1
    settings.autoWhiteBalance = false
    settings.base = base
    func cast(_ profile: FilmProfile) throws -> Double {
      let r = ImagePipeline.shared.raster(try ImagePipeline.shared.preview(ramp, settings: settings, profile: profile), maxDimension: w)
      let spreads = (w / 10..<w * 9 / 10).map { x -> Double in let v = r.pixel(x, h / 2).values.map { $0 * 255 }; return v.max()! - v.min()! }
      return spreads.reduce(0, +) / Double(spreads.count)
    }
    let portra = FilmProfile.builtins.first { $0.id == "portra160" }!
    let fit = try FilmCalibration.fit([point(0.4), point(0.9), point(1.4)], greenSlope: portra.slopes.g)
    let made = FilmCalibration.profile(from: fit, basedOn: portra, points: 3, scanner: "EPSON V800/V850")
    try made.validate()
    let before = try cast(portra), after = try cast(made)
    try check(after < 1.5 && after < before / 3,
      String(format: "the calibrated preset keeps a neutral ramp neutral: %.1f levels of cast, %.1f with the data-sheet preset", after, before))

    // Making, keeping, applying and deleting a preset through the model.
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("calibration-offline"), preferences: Preferences(defaults: defaults))
    model.calibrationPoints = [point(0.9)]
    model.makeScannerPreset()
    try check(model.errorText != nil && model.preferences.customProfiles.isEmpty, "one point is not enough to make a preset")
    model.errorText = nil
    model.calibrationPoints = [point(0.4), point(0.9), point(1.4)]
    model.makeScannerPreset()
    let kept = Preferences(defaults: defaults).customProfiles
    try check(model.errorText == nil && model.profile.offsets != nil && model.profile.name == "Kodak Portra 160 · V850"
      && model.profiles.contains(model.profile) && kept == [model.profile] && model.calibrationPoints.isEmpty,
      "the made preset is applied, listed and kept in settings")
    model.deleteCustomProfile(model.profile.id)
    try check(Preferences(defaults: defaults).customProfiles.isEmpty && !model.profiles.contains { $0.offsets != nil },
      "deleting a preset removes it from the list and from settings")
    let old = try JSONDecoder().decode(FilmProfile.self, from: JSONEncoder().encode(portra))
    try check(old == portra && old.offsets == nil, "presets saved without offsets still load")
  }
}
