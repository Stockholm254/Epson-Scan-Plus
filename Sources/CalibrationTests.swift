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
    try check(calibrated < 1.5 && aligned > calibrated * 3,
      String(format: "with auto white balance and unexposed film as the darkest part, the calibrated preset keeps the grey grey: %.1f levels of cast, %.1f aligning the black", calibrated, aligned))
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
    // Warmth and tint are white balance too, and fade in with it: a warm or cool print keeps the
    // unexposed film a neutral black, while the greys above it take them in full.
    (settings.warmth, settings.tint) = (0.3, -0.2)
    let warmBlack = try cast(made, in: shadowed, row: h * 7 / 8), warmGrey = try cast(made, in: shadowed, row: h / 4)
    (settings.warmth, settings.tint) = (0, 0)
    try check(warmBlack < 1.5 && warmGrey > 12,
      String(format: "warmth 0.3 and tint −0.2 leave the unexposed film a neutral black (%.1f levels of cast) and warm the greys above it (%.1f)", warmBlack, warmGrey))

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
    model.deleteCustomProfiles([model.profile.id])
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
    // The preset keeps what each point read, so its calibration can be taken up again: the points
    // come back as picked, one more is added, and making it again replaces it.
    let picked = [(0.4, 0.2), (0.9, 0.5), (1.4, 0.8)].map { e, x -> NeutralPoint in
      var p = point(e)
      p.at = CGPoint(x: x, y: 0.3)
      p.name = "07"
      return p
    }
    copying.calibrationPoints = picked
    copying.makeScannerPreset()
    let first = copying.profile
    try check(copying.calibrationPoints.isEmpty && first.spots?.count == 3 && first.spots?.allSatisfy { $0.value != nil && $0.base != nil && $0.name == "07" } == true
      && copying.resumableCalibration == 3,
      "a preset keeps each neutral point's reading and spot, also for a frame of another roll, and can be taken up again")
    try check(copying.profile.id.contains("-copy-") && copying.exportFilmKey == "portra160",
      "a roll on its copy calibration exports as its film (\(copying.exportFilmKey)), not as the preset's id")
    // With none picked, 3D shows the points the preset in use was made from, on the line it was fitted to.
    let theirs = copying.presetNeutralPoints, theirFit = copying.presetNeutralFit
    try check(theirs.map(\.value) == picked.map(\.value) && theirs.map(\.at) == picked.map(\.at)
      && theirFit.map { abs($0.slopes.r - first.slopes.r) < 1e-6 && abs($0.slopes.b - first.slopes.b) < 1e-6 } == true,
      "the preset's own points come back for 3D without picking, on the slopes it was made with")
    // In 2D each point's three readings sit at the exposure its green gives, red and blue on their
    // curves for neutrals the preset makes grey; green on its own by construction.
    let placedNeutrals = NeutralCurvesView.placed(theirs, fit: theirFit)
    let curve = theirFit.map { f in placedNeutrals.map { p in Plots3D.line(f, from: p.x, to: p.x, steps: 1)[0] } } ?? []
    try check(placedNeutrals.count == 3 && curve.count == 3
      && zip(placedNeutrals, curve).allSatisfy { p, c in (0..<3).allSatisfy { abs(p.d[$0] - c[$0]) < 0.005 } && p.off.allSatisfy { $0 < 0.005 } }
      && placedNeutrals.map(\.x) == placedNeutrals.map(\.x).sorted(),
      "the 2D view puts each neutral's red, green and blue on the preset's curves at the exposure its green gives")
    // The points marked on their frame in ② only, where the calibration is: not in ③, and in ②
    // while picking or with 「标出」 on.
    var marked = FilmFrame(name: "07", rect: .full, format: "135")
    marked.id = theirs[0].frame
    let was = (copying.page, copying.convertStep, copying.showCalibrationPoints)
    copying.page = .convert
    copying.convertStep = .demask
    copying.showCalibrationPoints = true
    let inDemasking = copying.neutralMarks(on: marked).count
    copying.convertStep = .grade
    let inGrading = copying.neutralMarks(on: marked).count
    copying.convertStep = .demask
    copying.showCalibrationPoints = false
    let switchedOff = copying.neutralMarks(on: marked).count
    copying.useTool(.calibrate)
    let picking = copying.neutralMarks(on: marked).count
    copying.useTool(.select)
    (copying.page, copying.convertStep, copying.showCalibrationPoints) = was
    try check(inDemasking == 1 && inGrading == 0 && switchedOff == 0 && picking == 1,
      "the neutral points are marked in ② with 「标出」 on or while picking, never over ③'s picture")
    // The panel lists them, a row each with its green density and how far off the line it lies;
    // taking one out takes the calibration up without it, and 「清除」 then starts from none.
    let rows = copying.calibrationRows
    try check(rows.count == 3 && rows.allSatisfy { $0.green != nil && ($0.off ?? 1) < 0.005 && $0.name == "07" }
      && rows.map(\.green!) == picked.map { $0.density[1] },
      "the calibration's points are listed, each with its density and how far it lies off the line")
    copying.removeCalibrationPoint(at: 0)
    try check(copying.calibrationPoints == Array(picked.dropFirst()) && copying.calibrationRows.count == 2,
      "taking one of the preset's points out takes the calibration up without it (the two left too close to make it again)")
    // Picking on: a point added to the calibration in use makes the preset again with it, the
    // picker kept for the next.
    copying.useTool(.calibrate)
    if copying.calibrationPoints.isEmpty, copying.resumableCalibration != nil { copying.resumeCalibration() }
    var added = point(0.35)
    added.at = CGPoint(x: 0.4, y: 0.7)
    copying.calibrationPoints.append(added)
    copying.calibrateAsPicked()
    try check(copying.calibrationPoints.isEmpty && copying.profile.spots?.count == 3 && copying.tool == .calibrate,
      "取点后自动生成: a point added makes the preset again from all of them, and picking goes on")
    copying.useTool(.select)
    copying.clearCalibration()
    try check(copying.calibrationPoints.isEmpty && copying.resumableCalibration == nil && copying.calibrationRows.isEmpty
      && copying.presetNeutralPoints.isEmpty,
      "「清除」 lets the preset's points go: calibrating starts from none")
    copying.chooseProfile(first)
    try check(copying.resumableCalibration == 3, "until the preset is chosen again")
    copying.resumeCalibration()
    try check(copying.calibrationPoints == picked && copying.resumableCalibration == nil && copying.status.contains("接着"),
      "taking the calibration up again brings its points back as they were picked")
    var more = point(1.1)
    more.at = CGPoint(x: 0.6, y: 0.6)
    copying.calibrationPoints.append(more)
    copying.makeScannerPreset()
    let grown = copying.profile
    try check(copying.errorText == nil && grown.spots?.count == 4 && grown.publication.hasSuffix("4 个中性点") && grown.id != first.id
      && copying.preferences.customProfiles.filter { $0.offsets != nil } == [grown],
      "a point added to it makes the preset again from all four, which replaces the one taken up")
    // Another copy session's preset, chosen from the menu, is not taken up: making it here would
    // name it after this session. Neither is one whose points it cannot read again.
    var otherSession = grown
    otherSession.name = "Kodak Portra 160 · 翻拍 · 2026-10-29 21:00"
    copying.chooseProfile(otherSession)
    let foreign = copying.resumableCalibration
    var spotsOnly = grown
    spotsOnly.spots = grown.spots?.map { CalibrationSpot(frame: $0.frame, name: $0.name, x: $0.x, y: $0.y) }
    copying.chooseProfile(spotsOnly)
    copying.resumeCalibration()
    try check(foreign == nil && copying.calibrationPoints.isEmpty && copying.status.contains("读不回来"),
      "another session's preset is not taken up, and points kept only as spots on frames elsewhere are said to be left out")
    // The presets table shows each calibrated preset's points and takes one up on this roll.
    var counted = portra
    counted.offsets = RGB(r: 0.1, g: 0, b: 0.2)
    counted.publication = "翻拍标定 · A7R IV · 2026-10-01 · 5 个中性点"
    let lines = PresetTable.pointLines(grown), legacy = PresetTable.pointLines(spotsOnly)
    try check(PresetTable.pointCount(grown) == 4 && PresetTable.pointCount(counted) == 5 && PresetTable.pointCount(portra) == nil
      && lines.count == 4 && lines.allSatisfy { $0.contains("偏离") } && lines.allSatisfy { line in
        line.split(separator: "偏离").last.map { $0.split(separator: " ").compactMap { Double($0) }.allSatisfy { abs($0) < 0.002 } } ?? false }
      && legacy.count == 4 && legacy.allSatisfy { $0.contains("只记了位置") },
      "the presets table counts a calibrated preset's points and lists each, on its line: \(lines.first ?? "")")
    try check(copying.whyNotTakenUp(otherSession)?.contains("另一次翻拍") == true && copying.whyNotTakenUp(portra) != nil
      && copying.whyNotTakenUp(grown) == nil,
      "only this copy session's calibrated preset can be taken up on its roll, and the table says why not")
    copying.chooseProfile(portra)
    copying.takeUpCalibration(grown)
    try check(copying.profile == grown && copying.calibrationPoints.count == 4 && copying.tool == .calibrate,
      "taking it up from the table puts the roll on it, brings its points back and turns the picker on")
    copying.clearCalibration()
    // The roll's calibration switched off: it converts as the film the preset came from (its roll
    // estimate first, then the data sheet, no neutral, no toe), the preset itself still the roll's.
    let edits = UndoManager()
    edits.groupsByEvent = false
    copying.undoManager = edits
    copying.setUseCalibration(false)
    let plain = copying.conversionProfile
    var estimated = Adjustments()
    estimated.rollSlopes = RGB(r: 0.8, g: 0.55, b: 0.7)
    try check(copying.profile == grown && !copying.useCalibration && plain.id == "portra160" && plain.offsets == nil && plain.toe == nil
      && ImagePipeline.slopes(Adjustments(), plain).slopes == portra.slopes && ImagePipeline.slopes(estimated, plain).slopes == estimated.rollSlopes
      && ImagePipeline.slopes(estimated, grown).slopes == grown.slopes && copying.status.contains("先不用标定"),
      "with the calibration off the roll converts as its film: the roll's estimate, else the data sheet; the preset stays chosen")
    edits.undo()
    try check(copying.useCalibration && copying.conversionProfile == grown, "turning the calibration off is undone with ⌘Z")
    copying.setUseCalibration(false)
    copying.chooseProfile(grown)
    try check(copying.useCalibration && copying.conversionProfile == grown, "choosing a calibrated preset again uses its calibration")
    var fromGeneric = grown, orphan = grown
    fromGeneric.id = "generic-v850-0a1b2c"
    orphan.id = "gone-copy-0a1b2c"
    try check(AppModel.uncalibrated(fromGeneric, among: copying.profiles).id == "generic"
      && AppModel.uncalibrated(orphan, among: copying.profiles).id == "generic" && AppModel.uncalibrated(portra, among: copying.profiles) == portra,
      "a preset calibrated from the generic one, or from a film no longer listed, converts as the generic preset when switched off")
    // Kept with the roll: a project saved with it off opens with it off; one from before, on.
    let switchRoot = folder.appendingPathComponent("calibration-switch")
    try FileManager.default.createDirectory(at: switchRoot, withIntermediateDirectories: true)
    try ImagePipeline.shared.savePNG(ramp, to: switchRoot.appendingPathComponent("overview.png"))
    var saved = DeskProject(
      overviewPath: switchRoot.appendingPathComponent("overview.png").path, overviewDPI: 150, physicalWidthMM: 36, physicalHeightMM: 24,
      filmName: grown.name, profile: grown, scanDPI: 2400, frames: [FilmFrame(name: "01", rect: .full, format: "135")])
    saved.useCalibration = false
    try JSONEncoder().encode(saved).write(to: switchRoot.appendingPathComponent("off.epscan"))
    saved.useCalibration = nil
    try JSONEncoder().encode(saved).write(to: switchRoot.appendingPathComponent("before.epscan"))
    let reopened = AppModel(libraryURL: switchRoot, preferences: Preferences(defaults: copyDefaults))
    reopened.loadProject(switchRoot.appendingPathComponent("off.epscan"))
    let wasOff = !reopened.useCalibration && reopened.conversionProfile.id == "portra160" && reopened.profile == grown
    reopened.loadProject(switchRoot.appendingPathComponent("before.epscan"))
    try check(wasOff && reopened.useCalibration && reopened.conversionProfile == grown,
      "the switch is kept with the roll; rolls saved before it convert with their calibration")
    try check(reopened.filmName == "Kodak Portra 160",
      "a roll that kept its calibrated preset's name as its film's opens as the film: \(reopened.filmName)")

    // The preset follows the roll's film; the film stays the roll's, whatever preset converts it.
    let linkSuite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let linkDefaults = UserDefaults(suiteName: linkSuite)!
    defer { linkDefaults.removePersistentDomain(forName: linkSuite) }
    let linked = AppModel(libraryURL: folder.appendingPathComponent("calibration-linked"), preferences: Preferences(defaults: linkDefaults))
    linked.rollSource = .camera
    linked.sessionURL = folder.appendingPathComponent("calibration-linked").appendingPathComponent("2026-10-30_194132_3146")
    linked.chooseProfile(portra)
    linked.calibrationPoints = [point(0.4), point(0.9), point(1.4)]
    linked.makeScannerPreset()
    let session = linked.profile
    try check(linked.filmName == "Kodak Portra 160" && session.name == "Kodak Portra 160 · 翻拍 · 2026-10-30 19:41"
      && linked.rollPresets.contains { $0.id == session.id } && linked.rollPresets.contains { $0.id == portra.id }
      && !linked.otherPresets.contains { $0.id == session.id } && linked.status.hasPrefix("已生成预设"),
      "calibrating keeps the roll's film name, not the preset's; the film's presets come first in the menu, its calibration with them")
    // On the shelf the film's data sheet and its calibration are each a choice: what is picked is taken.
    linked.chooseProfile(session)
    linked.applyFilm(profile: portra, filmName: "Kodak Portra 160", reversal: false, format: linked.format)
    let sheetTaken = linked.profile.id == portra.id
    linked.applyFilm(profile: session, filmName: "Kodak Portra 160", reversal: false, format: linked.format)
    try check(sheetTaken && linked.profile.id == session.id && linked.filmName == "Kodak Portra 160" && linked.calibration(for: "Kodak Portra 160")?.id == session.id,
      "on the shelf the film's data sheet picked on its calibrated roll is taken, and the calibration picked is taken too")
    // 全卷斜率估计 under a calibration: the slopes are the calibration's, so it converts nothing;
    // on the data sheet it sets the slopes.
    let underCalibration = linked.slopeEstimateApplies
    linked.chooseProfile(portra)
    let underSheet = linked.slopeEstimateApplies
    linked.chooseProfile(session)
    try check(!underCalibration && underSheet,
      "全卷斜率估计 says it converts nothing under the calibration, and sets the slopes on the data sheet")
    // A calibration is drawn as its film, a tab saying where it was calibrated; the plain can is for one of no known film.
    let drawn = NewProjectSheet.look(.preset(session.id), m: linked)
    let stockID = FilmCatalog.stock(named: "Kodak Portra 160")!.id
    let asFilm = NewProjectSheet.look(.stock(stockID), m: linked)
    try check(drawn.maker == "Kodak" && drawn.name == asFilm.name && drawn.renderKey == asFilm.renderKey && !drawn.calibrated
      && drawn.calibration == "翻拍 · 2026-10-30 19:41" && NewProjectSheet.calibrationTab(drawn.calibration!) == "翻拍"
      && asFilm.calibration == nil && NewProjectSheet.sheet(.preset(session.id), m: linked) != nil,
      "a calibration on the shelf is its film's own cassette with a 翻拍 tab, and has the film's data sheet")
    let ektar = FilmProfile.builtins.first { $0.id == "ektar100" }!
    linked.chooseProfile(ektar)
    try check(linked.filmName == "Kodak Ektar 100" && linked.otherPresets.contains { $0.id == session.id } && !linked.rollPresets.contains { $0.id == session.id },
      "a preset of another film takes the roll to that film, the first film's calibration then under 其他胶片")
    linked.chooseProfile(session)
    try check(linked.filmName == "Kodak Portra 160", "and choosing that calibration takes it back to its film")
    linked.calibrationPoints = [point(0.4), point(0.9), point(1.4)]
    linked.makeScannerPreset()
    try check(linked.status.hasPrefix("已更新预设「Kodak Portra 160 · 翻拍 · 2026-10-30 19:41」，替换了") && linked.profile.name == session.name,
      "making this session's preset again says it replaced the one before, the menu showing the same name: \(linked.status)")
    // Calibrated from the generic preset, the preset takes the roll's film's name and is listed with it.
    linked.chooseProfile(FilmProfile.builtins.first { $0.id == "generic" }!)
    linked.filmName = "Harman Phoenix II 200"
    linked.calibrationPoints = [point(0.4), point(0.9), point(1.4)]
    linked.makeScannerPreset()
    let phoenix = linked.profile
    try check(phoenix.name == "Harman Phoenix II 200 · 翻拍 · 2026-10-30 19:41" && AppModel.film(of: phoenix) == "Harman Phoenix II 200"
      && linked.rollPresets.contains { $0.id == phoenix.id } && linked.filmName == "Harman Phoenix II 200"
      && AppModel.film(of: FilmProfile.builtins.first { $0.id == "generic" }!) == nil,
      "a calibration from the generic preset is named after the roll's film and listed as its preset")
    // A preset calibrated from the generic one before, named 本机标定胶片, is no film's: it leaves the roll's film.
    var unnamed = phoenix
    unnamed.id = "film-copy-0a0b0c"
    unnamed.name = "本机标定胶片 · 翻拍 · 2026-10-30 19:41"
    linked.keepProfile(unnamed)
    linked.chooseProfile(unnamed)
    try check(AppModel.film(of: unnamed) == nil && linked.filmName == "Harman Phoenix II 200" && linked.rollPresets.contains { $0.id == unnamed.id },
      "an older calibration of no named film keeps the roll's film, and this session's is listed with it")
    let plainCan = NewProjectSheet.look(.preset(unnamed.id), m: linked), outside = NewProjectSheet.look(.preset(phoenix.id), m: linked)
    try check(plainCan.calibrated && plainCan.maker == "本机标定" && plainCan.calibration != nil
      && outside.maker == FilmCatalog.stock(named: "Harman Phoenix II 200").map { $0.maker } ?? "目录外" && !outside.calibrated,
      "only a calibration of no known film is the plain 本机标定 can; one of a named film is drawn as that film")
    let notes = [true, false, nil].map { FilmCalibration.profile(from: fit, basedOn: portra, points: 3, scanner: "A7R IV", copyStand: true, unmixed: $0).notes }
    try check(notes[0].contains("标定时去串色是开着的") && notes[1].contains("标定时没有去串色") && notes[2].contains("有的去了串色、有的没有"),
      "a copy-stand preset says how its points were read, crosstalk taken out or not, as its slopes hold for that")
    let old = try JSONDecoder().decode(FilmProfile.self, from: JSONEncoder().encode(portra))
    try check(old == portra && old.offsets == nil, "presets saved without offsets still load")
  }
}
