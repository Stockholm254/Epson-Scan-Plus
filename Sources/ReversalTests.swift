import CoreGraphics
import Foundation

/// Reversal film, slides, on the scanner: the reading is the picture already, shown through its own
/// white balance and ends and encoded for the screen; frames found where light comes through, not
/// where the orange mask is; the roll switched as one edit, the next preview following; and nothing
/// a negative's mask needs looked for.
enum ReversalTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    // Linear 16-bit, as the scanner reads film: the light through it, 1 the bare lamp.
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

    // A slide of twelve patches, four across and three down: greys from the clearest film to near
    // its densest, and colours, each patch 50 pixels square.
    let patches: [RGB] = [
      RGB(r: 0.6, g: 0.6, b: 0.6), RGB(r: 0.35, g: 0.35, b: 0.35), RGB(r: 0.18, g: 0.18, b: 0.18), RGB(r: 0.09, g: 0.09, b: 0.09),
      RGB(r: 0.03, g: 0.03, b: 0.03), RGB(r: 0.15, g: 0.3, b: 0.55), RGB(r: 0.5, g: 0.06, b: 0.04), RGB(r: 0.08, g: 0.22, b: 0.05),
      RGB(r: 0.45, g: 0.3, b: 0.2), RGB(r: 0.6, g: 0.5, b: 0.05), RGB(r: 0.004, g: 0.004, b: 0.005), RGB(r: 0.012, g: 0.012, b: 0.012),
    ]
    func slide(_ read: (RGB) -> RGB = { $0 }) -> CGImage { linear(200, 150) { x, y in read(patches[min(2, y / 50) * 4 + min(3, x / 50)]) } }
    func shown(_ image: CGImage, _ s: Adjustments, patch: Int) throws -> RGB {
      let r = pipe.raster(try pipe.preview(image, settings: s, profile: FilmProfile.builtins[0]))
      let (col, row) = (patch % 4, patch / 4)
      var sum = [0.0, 0.0, 0.0]
      for dy in -4...4 { for dx in -4...4 { let p = r.pixel(col * 50 + 25 + dx, row * 50 + 25 + dy).values; for c in 0..<3 { sum[c] += p[c] } } }
      return RGB(sum.map { $0 / 81 })
    }
    func neutral(_ v: RGB, _ e: Double = 0.008) -> Bool { abs(v.r - v.g) < e && abs(v.b - v.g) < e }
    let encode = 1 / ImagePipeline.slideEncoding
    var s = Adjustments()
    s.inputGamma = 1
    s.setReversal(true)
    try check(s.isSlide && !s.inputIsNegative && !s.autoWhiteBalance && s.autoLevels,
      "a slide is read as it is: not inverted, its own colour kept (auto white balance off), its ends found")

    // The ends left alone: the bare lamp is white, and the light through the slide is encoded for
    // the screen, colour as it is. A file already positive comes through as it came.
    var plain = s
    plain.autoLevels = false
    let image = slide()
    let grey = try shown(image, plain, patch: 2), red = try shown(image, plain, patch: 6)
    let redWant = RGB(patches[6].values.map { pow($0, encode) })
    try check(abs(grey.g - pow(0.18, encode)) < 0.01 && neutral(grey) && zip(red.values, redWant.values).allSatisfy { abs($0 - $1) < 0.01 },
      "with the ends left alone a slide shows as on a light box, its linear light encoded for the screen: 18% grey at \(text(grey)), the red \(text(red))")
    var already = Adjustments()
    already.inputIsNegative = false
    already.inputGamma = 1
    let asCame = try shown(image, already, patch: 2)
    try check(abs(asCame.g - 0.18) < 0.01, "a file already positive, not a slide, still comes through as it came: \(text(asCame))")
    var brighter = plain
    brighter.exposure = 1
    let lifted = try shown(image, brighter, patch: 2)
    try check(abs(lifted.g - pow(0.36, encode)) < 0.012 && neutral(lifted), "a stop more exposure is twice the light: \(text(lifted))")

    // Auto levels: the darkest 0.5% black, the brightest white, one pair for every channel.
    let top = try shown(image, s, patch: 0), mid = try shown(image, s, patch: 2), redAuto = try shown(image, s, patch: 6)
    let want = pow((0.18 - 0.004) / (0.6 - 0.004), encode)
    func light(_ q: Double) -> Double { pow(q, 1 / encode) }
    let redRatio = light(redAuto.r) / max(0.001, light(redAuto.g))
    let redRatioWant = (0.5 - 0.004) / (0.06 - 0.004)
    try check(top.values.allSatisfy { $0 > 0.985 } && abs(mid.g - want) < 0.015 && neutral(mid) && abs(redRatio / redRatioWant - 1) < 0.12,
      String(format: "auto levels put a slide's clearest film at white (%@) and its densest at black, one pair for all three channels: the grey %@, the red's red to green %.2f where it was %.2f", text(top), text(mid), redRatio, redRatioWant))

    // Shot in lamplight: each channel scaled by the light's colour. A grey picked comes out grey,
    // and every other grey with it.
    let cast = RGB(r: 1, g: 0.8, b: 0.55)
    let warm = slide { (v: RGB) -> RGB in RGB((0..<3).map { (c: Int) -> Double in v.values[c] * cast.values[c] }) }
    var picked = s
    picked.neutralSample = RGB((0..<3).map { 0.18 * cast.values[$0] })
    picked.autoWhiteBalance = true
    let warmGrey = try shown(warm, s, patch: 1), pickedGrey = try shown(warm, picked, patch: 1), pickedDark = try shown(warm, picked, patch: 3)
    try check(!neutral(warmGrey, 0.05) && neutral(pickedGrey) && neutral(pickedDark),
      "a slide's colour is kept unless asked (warm light stays warm, \(text(warmGrey))); a grey picked makes every grey grey: \(text(pickedGrey))")

    // Faded, as old slides go magenta: the cyan and yellow dyes lost density, red and blue come
    // through with a black of their own. Auto white balance takes each channel from its own
    // darkest to its own brightest.
    let gains = [0.9, 0.5, 0.75], blacks = [0.08, 0.0, 0.04]
    let faded = slide { (v: RGB) -> RGB in RGB((0..<3).map { (c: Int) -> Double in v.values[c] * gains[c] + blacks[c] }) }
    var auto = s
    auto.autoWhiteBalance = true
    let fadedGrey = try shown(faded, s, patch: 2), restored = try shown(faded, auto, patch: 2), restoredDark = try shown(faded, auto, patch: 3)
    try check(!neutral(fadedGrey, 0.05) && neutral(restored, 0.012) && neutral(restoredDark, 0.012),
      "auto white balance takes each channel of a faded slide from its own black to its own white: the grey \(text(fadedGrey)) comes back \(text(restored))")

    // Frames on a preview, 150 dpi on a bed 120 × 160 mm: three mounted slides and an empty slot in
    // a holder, and a strip of three frames of reversal film, black between them.
    let dpi = 150.0, mm = dpi / 25.4
    let bed = CGSize(width: 120, height: 160)
    let pw = Int(bed.width * mm), ph = Int(bed.height * mm)
    let mounted = [CGRect(x: 8, y: 10, width: 35, height: 23), CGRect(x: 8, y: 45, width: 35, height: 23), CGRect(x: 8, y: 80, width: 35, height: 23)]
    let empty = CGRect(x: 8, y: 115, width: 35, height: 23)
    let strip = [CGRect(x: 70, y: 10, width: 24, height: 36), CGRect(x: 70, y: 48, width: 24, height: 36), CGRect(x: 70, y: 86, width: 24, height: 36)]
    let pictures = mounted + strip
    let overview = linear(pw, ph) { x, y in
      let p = CGPoint(x: (Double(x) + 0.5) / mm, y: (Double(y) + 0.5) / mm)
      if empty.contains(p) { return RGB(r: 0.98, g: 0.98, b: 0.98) }
      guard let f = pictures.first(where: { $0.contains(p) }) else {
        // The holder, and the black film round and between the strip's frames.
        return (68...96).contains(p.x) && (8...124).contains(p.y) ? RGB(r: 0.0004, g: 0.0003, b: 0.0004) : RGB(r: 0.0006, g: 0.0005, b: 0.0005)
      }
      let u = (p.y - f.minY) / f.height, v = (p.x - f.minX) / f.width
      // Sky over dark ground, a sun clipped in it, the ground darker to one side.
      if hypot(v - 0.7, u - 0.2) < 0.06 { return RGB(r: 1, g: 1, b: 1) }
      return u < 0.55 ? RGB(r: 0.2 + 0.2 * v, g: 0.35, b: 0.6) : RGB(r: 0.03 * (1.2 - v), g: 0.025 * (1.2 - v), b: 0.02)
    }
    let found = FrameDetector.detect(overview, physicalMM: bed, format: .auto, reversal: true)
    func inMM(_ r: NormalRect) -> CGRect { CGRect(x: r.x * bed.width, y: r.y * bed.height, width: r.width * bed.width, height: r.height * bed.height) }
    let off = zip(found.map { inMM($0.rect) }, pictures).map { a, b in
      [abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY)].max()!
    }
    try check(found.count == 6 && off.allSatisfy { $0 < 0.6 },
      "slides are found where light comes through: three mounted and three on a strip with black between, the empty slot's bare light passed over, each within 0.6 mm (\(found.count) found, off by \(off.map { String(format: "%.2f", $0) }) mm)")
    let asNegatives = FrameDetector.detect(overview, physicalMM: bed, format: .auto)
    try check(asNegatives.count != 6, "read as negatives the same holder is not found right (\(asNegatives.count) frames): the film matters")
    // A black and white strip: grey film, no orange mask, clear base between its frames, the holder
    // black round it. Found as B&W; looked for by its orange it is not.
    // 135 in the holder: its window 26 mm across the strip (the rebate under it), a frame each 38 mm.
    let bwFrames = [CGRect(x: 43.5, y: 10, width: 24, height: 36), CGRect(x: 43.5, y: 48, width: 24, height: 36), CGRect(x: 43.5, y: 86, width: 24, height: 36)]
    let bwStrip = CGRect(x: 42.5, y: 8, width: 26, height: 116)
    let silver = linear(pw, ph) { x, y in
      let p = CGPoint(x: (Double(x) + 0.5) / mm, y: (Double(y) + 0.5) / mm)
      guard bwStrip.contains(p) else { return RGB(r: 0.0005, g: 0.0005, b: 0.0005) }
      guard let f = bwFrames.first(where: { $0.contains(p) }) else { return RGB(r: 0.72, g: 0.72, b: 0.72) }
      let u = (p.y - f.minY) / f.height, v = (p.x - f.minX) / f.width
      let d = u < 0.5 ? 0.12 + 0.1 * v : 0.35 + 0.2 * (1 - v)
      return RGB(r: d, g: d, b: d)
    }
    let bw = FrameDetector.detect(silver, physicalMM: bed, format: .auto, monochrome: true)
    let byOrange = FrameDetector.detect(silver, physicalMM: bed, format: .auto)
    let bwOff = zip(bw.map { inMM($0.rect) }, bwFrames).map { a, b in [abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY)].max()! }
    try check(bw.count == 3 && bwOff.allSatisfy { $0 < 1.5 } && byOrange.isEmpty,
      "a black and white strip's frames are found without an orange mask (\(bw.count), off by \(bwOff.map { String(format: "%.2f", $0) }) mm); looked for by orange, none (\(byOrange.count))")

    // The scanner set to reversal film: the preview's frames found and read as slides; switched to
    // negatives before any is scanned, found again as negatives, and back.
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = Preferences(defaults: defaults)
    try check(!preferences.scanReversal, "the scanner starts on negatives")
    preferences.scanReversal = true
    let model = AppModel(libraryURL: folder.appendingPathComponent("reversal-library"), preferences: preferences)
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    func settle(_ done: () -> Bool) {
      let deadline = Date().addingTimeInterval(15)
      while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    model.receiveOverview(overview, size: bed, dpi: dpi)
    settle { !model.rendering && !model.frames.isEmpty }
    try check(model.frames.count == 6 && model.frames.allSatisfy { $0.adjustments.isSlide && !$0.adjustments.autoWhiteBalance } && model.reversalRoll,
      "a preview with the scanner on reversal film finds its slides and reads them as slides (\(model.frames.count) frames)")
    model.setReversal(false)
    settle { !model.rendering }
    let againAsNegatives = model.frames.count
    try check(!preferences.scanReversal && !model.frames.contains { $0.adjustments.isSlide } && againAsNegatives != 6,
      "switched to negatives before anything is scanned, the preview's frames are found again as negatives (\(againAsNegatives)), and the next preview follows")
    model.setReversal(true)
    settle { !model.rendering && model.frames.count == 6 }
    try check(preferences.scanReversal && model.frames.count == 6 && model.reversalRoll, "and back to reversal film, the slides again")
    try check(Preferences(defaults: defaults).scanReversal, "the scanner's film is kept for the next time the app opens")

    // A roll whose pictures are files already: switched as one edit, undone as one; a slide's
    // edges are not looked at for a mask, a reset keeps it a slide, and a recalculated balance
    // goes back to its own colour.
    let files = AppModel(libraryURL: folder.appendingPathComponent("reversal-files"), preferences: Preferences(defaults: defaults))
    let fileEdits = UndoManager()
    fileEdits.groupsByEvent = false
    files.undoManager = fileEdits
    let decoded = folder.appendingPathComponent("reversal-files/Decoded", isDirectory: true)
    try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
    for n in 1...2 {
      let url = decoded.appendingPathComponent("EPS0000\(n).tif")
      try pipe.saveTIFF(slide(), to: url, dpi: 2400)
      files.addCapturedFrame(url, original: url, linear: true)
    }
    files.measureEdgeBases(wait: true)
    files.frames.indices.forEach { files.frames[$0].edgeBase = nil }
    files.setReversal(true)
    files.measureEdgeBases(wait: true)
    let switched = files.frames.allSatisfy { $0.adjustments.isSlide && $0.edgeBase == nil }
    files.select(files.frames[0].id)
    files.change("曝光") { $0.exposure = 0.5 }
    files.resetAdjustments()
    let stillSlide = files.frames[0].adjustments.isSlide && !files.frames[0].adjustments.autoWhiteBalance
    files.setNeutral(RGB(r: 0.2, g: 0.2, b: 0.2))
    files.clearBalanceSamples()
    let ownColour = !files.frames[0].adjustments.autoWhiteBalance && files.frames[0].adjustments.neutralSample == nil
    // The switch, the exposure, the reset, the grey and the recalculation.
    for _ in 0..<5 { fileEdits.undo() }
    let undone = !files.frames.contains { $0.adjustments.isSlide }
    try check(switched && stillSlide && ownColour && undone,
      "a roll of files switches to reversal film as one edit, its edges not looked at for a mask; a reset keeps a slide a slide, a recalculated balance its own colour; undone, negatives again")

    // Switched from the film section as from the scanner's panel: a picture copied into the roll
    // after joins its film, a slide among slides and a negative among negatives.
    var joined = [Bool]()
    for (n, slides) in [(3, true), (4, false)] {
      files.setReversal(slides)
      let url = decoded.appendingPathComponent("EPS0000\(n).tif")
      try pipe.saveTIFF(slide(), to: url, dpi: 2400)
      files.addCapturedFrame(url, original: url, linear: true)
      let new = files.frames.last!.adjustments
      joined.append(new.isSlide == slides && new.autoWhiteBalance != slides)
    }
    let copied = files.frames.count == 4 && joined == [true, true]
    try check(copied, "a picture copied into a roll of slides is a slide, into a roll of negatives a negative")
  }
}
