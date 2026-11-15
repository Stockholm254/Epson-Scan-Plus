import AppKit

/// 找中性 (`GrayPixelNeutral`): a negative of grey stone and an orange wall, both lit and shaded,
/// under warm light; the grays' neutral is the light's, the orange's shading kept out by the prior.
enum GrayPixelTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    var film = FilmProfile.builtins.first { $0.id == "portra160" }!
    film.toe = nil
    let base = RGB(r: 0.80, g: 0.52, b: 0.33)
    // The light, as red and blue against green in log exposure, and the orange's own colour.
    let light = (r: 0.08, b: -0.10), orange = (r: 0.30, b: -0.40)
    let w = 360, h = 240
    func image16(_ value: (Int, Int) -> RGB) -> CGImage {
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
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    // A pixel's log exposure: blocks of stone of several greys, or the wall, under a light that
    // falls off across the frame, with a little grain.
    func negative(orangeShare: Double) -> CGImage {
      image16 { x, y in
        let bx = x / 24, by = y / 24
        let stone = 0.5 + Double((bx * 7 + by * 13) % 9) * 0.15
        let shade = 0.25 * sin(Double(x) / 37) + 0.2 * cos(Double(y) / 29)
        let grain = Double((x * 73 + y * 151) % 17) / 17 * 0.006
        let wall = Double(x) / Double(w) < orangeShare
        let e = (wall ? 1.1 + 0.3 * sin(Double(x + 2 * y) / 11) : stone) + shade + grain
        let o = wall ? orange : (r: 0.0, b: 0.0)
        let ex = [e + light.r + o.r, e, e + light.b + o.b]
        return RGB((0..<3).map { c in base.values[c] / pow(10, film.slopes.values[c] * ex[c]) })
      }
    }
    var settings = Adjustments()
    settings.inputGamma = 1
    settings.base = base
    func miss(_ f: GrayPixelNeutral.Found) -> Double { hypot(f.neutral.r - light.r, f.neutral.b - light.b) }

    // Calibrated in light a little cooler than this frame's: the grays are found near it.
    var calibrated = film
    calibrated.offsets = RGB(r: 0.03, g: 0, b: -0.04)
    let mixed = negative(orangeShare: 0.4)
    guard let found = GrayPixelNeutral.find(in: mixed, settings: settings, profile: calibrated) else {
      throw DeskError.message("FAIL: grays found in a frame of stone and an orange wall")
    }
    try check(miss(found) < 0.02 && miss(found) < hypot(0.03 - light.r, -0.04 - light.b) / 2,
      String(format: "the grays' neutral is the light's (missed by %.3f log), not the calibrated one", miss(found)))
    try check(found.calibrated && found.warmer > 0.02, String(format: "it reads the light as warmer than the calibration's (%+.3f)", found.warmer))
    // Picked as a grey, the reading balances a grey of the scene.
    var picked = settings
    picked.neutralSample = found.reading
    picked.autoWhiteBalance = true
    let a = ImagePipeline.shared.analyze(mixed, settings: picked, profile: calibrated)
    let grey = [1.0 + light.r, 1.0, 1.0 + light.b].enumerated().map { $0.element + a.balance.values[$0.offset] }
    try check((grey.max()! - grey.min()!) < 0.02, String(format: "taken as the grey picked, a grey of the scene comes out grey (%.3f apart)", grey.max()! - grey.min()!))

    // Without a calibration, near the frame's average colour: the wall, a quarter of the frame,
    // pulls the average 0.12 off, and the grays still set the neutral.
    var fixed = settings
    fixed.rollSlopes = film.slopes
    guard let plain = GrayPixelNeutral.find(in: negative(orangeShare: 0.25), settings: fixed, profile: film) else {
      throw DeskError.message("FAIL: grays found without a calibration")
    }
    try check(!plain.calibrated && miss(plain) < 0.03,
      String(format: "without a calibration, near the average, the grays' neutral is the light's (missed by %.3f)", miss(plain)))

    // All orange wall, calibrated: no grays near the neutral, so nothing is set.
    try check(GrayPixelNeutral.find(in: negative(orangeShare: 1.1), settings: settings, profile: calibrated) == nil,
      "a frame with nothing grey in it finds no neutral")
    // Not for a slide or black and white.
    var slide = settings
    slide.inputIsNegative = false
    slide.reversal = true
    var mono = settings
    mono.monochrome = true
    try check(GrayPixelNeutral.find(in: mixed, settings: slide, profile: calibrated) == nil
      && GrayPixelNeutral.find(in: mixed, settings: mono, profile: calibrated) == nil, "slides and black and white negatives are left to the grey picked by hand")

    // 自动 by the gray pixels: the neutral found is the balance, as a grey picked would be.
    var auto = settings
    auto.autoNeutral = .found(found.reading)
    let byGrays = ImagePipeline.shared.analyze(mixed, settings: auto, profile: calibrated)
    try check(byGrays.balance == a.balance, "自动 with gray pixels found balances as the grey they found, picked, does")
    var older = settings
    older.autoNeutral = nil
    var waiting = settings
    waiting.autoNeutral = .pending
    var noGrays = settings
    noGrays.autoNeutral = Adjustments.AutoNeutral.none
    let before = ImagePipeline.shared.analyze(mixed, settings: older, profile: calibrated).balance
    try check(ImagePipeline.shared.analyze(mixed, settings: waiting, profile: calibrated).balance == before
      && ImagePipeline.shared.analyze(mixed, settings: noGrays, profile: calibrated).balance == before && before != byGrays.balance,
      "an older frame, one still waiting and one with none found keep 自动 as it was")
    var overridden = auto
    overridden.neutralSample = RGB(r: 0.3, g: 0.2, b: 0.15)
    var plainPick = older
    plainPick.neutralSample = overridden.neutralSample
    var off = auto
    off.autoWhiteBalance = false
    var offOld = older
    offOld.autoWhiteBalance = false
    try check(ImagePipeline.shared.analyze(mixed, settings: overridden, profile: calibrated).balance
      == ImagePipeline.shared.analyze(mixed, settings: plainPick, profile: calibrated).balance
      && ImagePipeline.shared.analyze(mixed, settings: off, profile: calibrated).balance
      == ImagePipeline.shared.analyze(mixed, settings: offOld, profile: calibrated).balance,
      "a grey picked wins over the gray pixels, and 原片 leaves them out")
    var slideFound = auto
    slideFound.inputIsNegative = false
    slideFound.reversal = true
    var monoFound = auto
    monoFound.monochrome = true
    try check(slideFound.balancingNeutral == nil && monoFound.balancingNeutral == nil, "a slide and a black and white negative have no gray pixels' neutral")

    // Saved and opened: an older project's frames have none, a new frame waits, a found one is kept.
    let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Adjustments())) as! [String: Any]
    let opened = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: oldJSON.filter { $0.key != "autoNeutral" }))
    let kept = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(auto))
    try check(opened.autoNeutral == nil && Adjustments().autoNeutral == .pending && kept.autoNeutral == auto.autoNeutral,
      "a frame saved before 0.23.3 opens with its old 自动, a new frame waits for its gray pixels, a found neutral is saved")
    // Another frame's found neutral is not this one's: given over, it is looked for again.
    var other = settings
    other.autoNeutral = .found(RGB(r: 0.1, g: 0.1, b: 0.1))
    var taken = other
    taken.takeGrading(from: auto)
    var own = auto
    own.takeGrading(from: auto)
    var pasted = other
    SettingsGroup.whiteBalance.take(&pasted, from: auto)
    var fromOld = other
    fromOld.takeGrading(from: older)
    try check(taken.autoNeutral == .pending && own.autoNeutral == auto.autoNeutral && pasted.autoNeutral == .pending && fromOld.autoNeutral == nil,
      "another frame's grading or white balance taken: its gray pixels' kind, looked for in this picture; the same frame's kept")

    // The menu: an older frame shows 自动（旧）; choosing 自动 again starts the gray pixels, one ⌘Z back.
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("gray-pixel"), preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    model.frames = (1...3).map { FilmFrame(name: "0\($0)", rect: .full, format: "135") }
    for i in 0..<3 { model.frames[i].adjustments.autoNeutral = nil }
    model.selectedID = model.frames[0].id
    try check(model.balanceMode == .auto && model.balanceIsOldAuto, "a frame from before shows its 自动 as 自动（旧）")
    model.setBalanceMode(.auto)
    try check(model.frames[0].adjustments.autoNeutral == .pending && !model.balanceIsOldAuto && model.frames[1].adjustments.autoNeutral == nil,
      "choosing 自动 again starts its gray pixels, the other frames left as they were")
    edits.undo()
    try check(model.frames[0].adjustments.autoNeutral == nil, "and ⌘Z takes it back")
    model.frames[0].adjustments.autoNeutral = .found(found.reading)
    model.frames[1].adjustments.autoNeutral = nil
    _ = model.choose(model.frames[1].id, modifiers: .command)
    model.convertStep = .grade
    model.syncSettings()
    try check(model.frames[1].adjustments.autoNeutral == .pending && model.frames[0].adjustments.autoNeutral == .found(found.reading),
      "同步 gives an older frame chosen the new 自动, to look for its own gray pixels")

    // The white balance sets the colour, not how light the frame prints: a grey picked, the gray
    // pixels or 原片 print as light as 自动 (until 0.23.5 the ends moved with the channels).
    func lightness(_ image: CGImage, _ s: Adjustments, _ p: FilmProfile) throws -> Double {
      let out = try ImagePipeline.shared.preview(image, settings: s, profile: p)
      let w = out.width, h = out.height
      var px = [UInt8](repeating: 0, count: w * h * 4)
      let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(out, in: CGRect(x: 0, y: 0, width: w, height: h))
      var sum = 0.0
      for i in 0..<(w * h) { sum += 0.2126 * Double(px[i * 4]) + 0.7152 * Double(px[i * 4 + 1]) + 0.0722 * Double(px[i * 4 + 2]) }
      return sum / Double(w * h)
    }
    var onAuto = settings
    onAuto.autoNeutral = Adjustments.AutoNeutral.none
    var onPick = onAuto
    onPick.neutralSample = RGB(r: found.reading.r * 1.08, g: found.reading.g, b: found.reading.b * 0.9)
    var onGrays = onAuto
    onGrays.autoNeutral = .found(found.reading)
    var plainAuto = fixed
    plainAuto.autoNeutral = Adjustments.AutoNeutral.none
    var plainGrey = plainAuto
    plainGrey.neutralSample = found.reading
    var plainRaw = plainAuto
    plainRaw.autoWhiteBalance = false
    let lit = try [lightness(mixed, onAuto, calibrated), lightness(mixed, onPick, calibrated), lightness(mixed, onGrays, calibrated),
      lightness(mixed, plainAuto, film), lightness(mixed, plainGrey, film), lightness(mixed, plainRaw, film)]
    try check(abs(lit[1] - lit[0]) < 1.5 && abs(lit[2] - lit[0]) < 1.5 && abs(lit[4] - lit[3]) < 1.5 && abs(lit[5] - lit[3]) < 1.5,
      String(format: "a grey picked, the gray pixels and 原片 print as light as 自动 (%.1f, %.1f against %.1f; %.1f, %.1f against %.1f /255)",
        lit[1], lit[2], lit[0], lit[4], lit[5], lit[3]))
    // So with the auto levels off: 自动's ends are the fixed ones, and a grey picked, the gray pixels
    // and 原片 print as light as it does there.
    let manual = try [onAuto, onPick, onGrays, plainAuto, plainGrey, plainRaw].enumerated().map { i, s -> Double in
      var s = s
      s.autoLevels = false
      return try lightness(mixed, s, i < 3 ? calibrated : film)
    }
    try check(abs(manual[1] - manual[0]) < 1.5 && abs(manual[2] - manual[0]) < 1.5 && abs(manual[4] - manual[3]) < 1.5 && abs(manual[5] - manual[3]) < 1.5,
      String(format: "with the auto levels off, a grey picked, the gray pixels and 原片 print as light as 自动 (%.1f, %.1f against %.1f; %.1f, %.1f against %.1f /255)",
        manual[1], manual[2], manual[0], manual[4], manual[5], manual[3]))
    var oldPick = onPick
    oldPick.autoNeutral = nil
    var oldAuto = onAuto
    oldAuto.autoNeutral = nil
    let analysed = [oldPick, onPick, oldAuto, onAuto].map { ImagePipeline.shared.analyze(mixed, settings: $0, profile: calibrated) }
    try check(analysed[0].balance == analysed[1].balance && (analysed[0].low != analysed[1].low || analysed[0].high != analysed[1].high)
      && analysed[2] == analysed[3],
      String(format: "a frame from before keeps the ends its grey gave it (%.3f–%.3f, now %.3f–%.3f); 自动 is as it was",
        analysed[0].low, analysed[0].high, analysed[1].low, analysed[1].high))
    // A slide: its grey picked prints as light as 自动 too.
    let slideImage = image16 { x, y in
      let bx = x / 24, by = y / 24
      let v = 0.08 + Double((bx * 7 + by * 13) % 9) * 0.1
      return RGB(r: v * 0.75, g: v, b: v * 1.15)
    }
    var slideAuto = Adjustments()
    (slideAuto.inputIsNegative, slideAuto.reversal, slideAuto.inputGamma) = (false, true, 1)
    var slidePick = slideAuto
    slidePick.neutralSample = RGB(r: 0.48 * 0.75, g: 0.48, b: 0.48 * 1.15)
    let slideLit = try [lightness(slideImage, slideAuto, film), lightness(slideImage, slidePick, film)]
    var oldSlide = slidePick
    oldSlide.autoNeutral = nil
    let oldSlideLit = try lightness(slideImage, oldSlide, film)
    try check(abs(slideLit[1] - slideLit[0]) < 1.5,
      String(format: "a slide's grey picked prints as light as 自动 (%.1f against %.1f /255; from before, %.1f)", slideLit[1], slideLit[0], oldSlideLit))
    // Set again on a frame from before, the white balance keeps it as light as 自动 from then on.
    model.frames[2].adjustments.autoNeutral = nil
    model.selectedID = model.frames[2].id
    model.setNeutral(RGB(r: 0.3, g: 0.2, b: 0.15))
    let pickedAgain = model.frames[2].adjustments.autoNeutral == .pending && model.frames[2].adjustments.balanceKeepsLightness
    edits.undo()
    let undone = model.frames[2].adjustments.autoNeutral == nil
    model.setBalanceMode(.asShot)
    try check(pickedAgain && undone && model.frames[2].adjustments.autoNeutral == .pending && !model.frames[2].adjustments.autoWhiteBalance,
      "a grey picked or 原片 chosen on a frame from before keeps it as light as 自动 from then on, ⌘Z back as it was")
  }
}
