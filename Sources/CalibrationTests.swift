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
    func picture(_ samples: [UInt16]) -> CGImage {
      CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    let ramp = picture(samples)
    var settings = Adjustments()
    settings.inputGamma = 1
    settings.autoWhiteBalance = false
    settings.base = base
    func cast(_ profile: FilmProfile, in image: CGImage, row: Int) throws -> Double {
      let r = ImagePipeline.shared.raster(try ImagePipeline.shared.preview(image, settings: settings, profile: profile), maxDimension: w)
      let spreads = (w / 10..<w * 9 / 10).map { x -> Double in let v = r.pixel(x, row).values.map { $0 * 255 }; return v.max()! - v.min()! }
      return spreads.reduce(0, +) / Double(spreads.count)
    }
    let portra = FilmProfile.builtins.first { $0.id == "portra160" }!
    let fit = try FilmCalibration.fit([point(0.4), point(0.9), point(1.4)], greenSlope: portra.slopes.g)
    let made = FilmCalibration.profile(from: fit, basedOn: portra, points: 3, scanner: "EPSON V800/V850")
    try made.validate()
    let before = try cast(portra, in: ramp, row: h / 2), after = try cast(made, in: ramp, row: h / 2)
    try check(after < 1.5 && after < before / 3,
      String(format: "the calibrated preset keeps a neutral ramp neutral: %.1f levels of cast, %.1f with the data-sheet preset", after, before))
    // Auto white balance on, and the darkest part of the picture unexposed film: a calibrated preset
    // balances by its neutral, so the grey stays grey. Aligning that black, as the same slopes do
    // without the neutral, takes the layers' differing speeds for a cast. A Dmax highlight on the
    // grey then stretches it from that neutral, keeping the tones between neutral.
    var unexposed = samples
    for y in h * 3 / 4..<h {
      for x in 0..<w { for c in 0..<3 { unexposed[(y * w + x) * 4 + c] = UInt16(base.values[c] * 65535) } }
    }
    let shadowed = picture(unexposed)
    var slopesOnly = made
    slopesOnly.offsets = nil
    settings.autoWhiteBalance = true
    let calibrated = try cast(made, in: shadowed, row: h / 4), aligned = try cast(slopesOnly, in: shadowed, row: h / 4)
    settings.highlightSample = value(1.5)
    let stretched = try cast(made, in: shadowed, row: h / 4)
    settings.highlightSample = nil
    try check(calibrated < 1.5 && aligned > calibrated * 3 && stretched < 1.5,
      String(format: "with auto white balance and unexposed film as the darkest part, the calibrated preset keeps the grey grey: %.1f levels of cast (%.1f with a Dmax highlight), %.1f aligning the black", calibrated, stretched, aligned))
    // The unexposed film itself took no light: black, and neutral, not the purple the neutral's
    // balance would make of it on the straight line.
    let black = try cast(made, in: shadowed, row: h * 7 / 8)
    let fade = ImagePipeline.unexposedFade
    ImagePipeline.unexposedFade = 0
    let purple = try cast(made, in: shadowed, row: h * 7 / 8)
    ImagePipeline.unexposedFade = fade
    settings.autoWhiteBalance = false
    try check(black < 1.5 && purple > black + 6,
      String(format: "and the unexposed film comes out a neutral black: %.1f levels of cast, %.1f with the balance applied evenly", black, purple))

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
    // On the copy stand the same points make a preset for the camera and its light in this copy
    // session, named after it; neither the film's next copy rolls nor a scanned roll take it unasked.
    let copySuite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let copyDefaults = UserDefaults(suiteName: copySuite)!
    defer { copyDefaults.removePersistentDomain(forName: copySuite) }
    let copying = AppModel(libraryURL: folder.appendingPathComponent("calibration-copy"), preferences: Preferences(defaults: copyDefaults))
    copying.rollSource = .camera
    copying.sessionURL = folder.appendingPathComponent("calibration-copy").appendingPathComponent("2026-10-30_194132_3146")
    copying.chooseProfile(portra)
    copying.calibrationPoints = [point(0.4), point(0.9), point(1.4)]
    copying.makeScannerPreset()
    let copyPreset = copying.profile
    let scanned = AppModel(libraryURL: folder.appendingPathComponent("calibration-scanned"), preferences: Preferences(defaults: copyDefaults))
    try check(copying.errorText == nil && copyPreset.name == "Kodak Portra 160 · 翻拍 · 2026-10-30 19:41"
      && copyPreset.id.hasPrefix("portra160-copy-") && copyPreset.publication.hasPrefix("翻拍标定 · A7R IV")
      && copyPreset.dataSheetToe != nil && copyPreset.offsets != nil && copyPreset.notes.contains("新开的卷不会自动用它")
      && copying.calibrated(for: portra) == nil && scanned.calibrated(for: portra) == nil,
      "on a copy roll the neutral points make a preset named after the copy session, which no roll takes unasked")
    // Calibrating the session again, from that preset, replaces it under the same name, not
    // "… · 翻拍 · 翻拍"; a preset named so before is still known by its film.
    copying.calibrationPoints = [point(0.4), point(0.9), point(1.4)]
    copying.makeScannerPreset()
    let again = copying.profile
    var doubled = again
    doubled.id += "-copy-20f880"
    doubled.name = "Kodak Portra 160 · 翻拍 · 翻拍"
    let copies = copying.preferences.customProfiles.filter { $0.offsets != nil }
    try check(copying.errorText == nil && again.name == copyPreset.name && again.id.count == "portra160-copy-".count + 6
      && again.id.hasPrefix("portra160-copy-") && again != copyPreset && copies == [again]
      && FilmCalibration.calibratedFrom(doubled) == ("Kodak Portra 160", "portra160")
      && FilmCalibration.calibratedFrom(again) == ("Kodak Portra 160", "portra160"),
      "calibrating the copy session again replaces its preset, named after the film and the session, not piled on")
    let notes = [true, false, nil].map { FilmCalibration.profile(from: fit, basedOn: portra, points: 3, scanner: "A7R IV", copyStand: true, unmixed: $0).notes }
    try check(notes[0].contains("标定时去串色是开着的") && notes[1].contains("标定时没有去串色") && notes[2].contains("有的去了串色、有的没有"),
      "a copy-stand preset says how its points were read, crosstalk taken out or not, as its slopes hold for that")
    let old = try JSONDecoder().decode(FilmProfile.self, from: JSONEncoder().encode(portra))
    try check(old == portra && old.offsets == nil, "presets saved without offsets still load")
  }
}
