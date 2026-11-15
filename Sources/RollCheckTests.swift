import CoreGraphics
import Foundation

/// The roll's slope estimate kept frame by frame, what it reads of each frame for the roll's check,
/// the check itself, and which frame's gray pixels its render looks for.
enum RollCheckTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared

    // A frame's edges for the estimate are kept by what they are read from: its base and region,
    // not its print, balance or slopes.
    let plain = FilmFrame(name: "01", rect: .full, format: "135")
    func key(_ f: FilmFrame) -> String { AppModel.edgesKey(f, flare: nil, preview: "-", format: .auto) }
    var printed = plain
    (printed.adjustments.warmth, printed.adjustments.exposure, printed.adjustments.saturation) = (0.3, 0.5, 1.4)
    printed.adjustments.neutralSample = RGB(r: 0.3, g: 0.2, b: 0.1)
    printed.adjustments.rollSlopes = RGB(r: 0.4, g: 0.6, b: 0.6)
    printed.adjustments.autoNeutral = .found(RGB(r: 0.3, g: 0.2, b: 0.1))
    var based = plain
    based.adjustments.rollBase = RGB(r: 0.8, g: 0.5, b: 0.3)
    var region = plain
    region.adjustments.analysisRegion = NormalRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
    try check(key(printed) == key(plain) && key(based) != key(plain) && key(region) != key(plain) && key(based) != key(region),
      "the estimate keeps a frame's edges while only its print, balance or slopes change; a base or region reads it again")

    // What the check reads of a frame: its darkest film above the base, and the share clearer than it.
    let w = 96, h = 64
    func image(_ value: (Int, Int) -> Double) -> CGImage {
      var samples = [UInt16](repeating: 65535, count: w * h * 4)
      for y in 0..<h {
        for x in 0..<w {
          let v = value(x, y)
          for c in 0..<3 { samples[(y * w + x) * 4 + c] = UInt16(max(0, min(1, v * [1.0, 0.7, 0.45][c])) * 65535) }
        }
      }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    // Blocks of thinner and denser film, for edges; the base measured as the thinner film's reading
    // 0.45 D lighter, then as 0.2 D darker (a base picked on exposed film). Smoothed 3 × 3, a block's
    // inner 6 × 6 stays clearer than that base: some 28% of the film.
    let film = image { x, y in (x / 8 + y / 8) % 2 == 0 ? 0.5 : 0.15 }
    let thinner = pipe.samples(image { _, _ in 0.5 }, maxDimension: 240).pixel(4, 4)
    var settings = Adjustments()
    settings.inputGamma = 1
    settings.base = RGB(thinner.values.map { $0 * pow(10, 0.45) })
    let lifted = pipe.edgeRatios(film, settings: settings)
    settings.base = RGB(thinner.values.map { $0 * pow(10, -0.2) })
    let dense = pipe.edgeRatios(film, settings: settings)
    try check(lifted.darkest.map { $0.values.allSatisfy { abs($0 - 0.45) < 0.04 } } == true && lifted.clearer < 0.001
      && dense.clearer > 0.2 && lifted.count > 0 && lifted.own != nil,
      String(format: "a frame's darkest film above its base and the share clearer than it are read with its edges (%.2f %.2f %.2f D, %.0f%%; %.0f%% against a denser base)",
        lifted.darkest?.r ?? -1, lifted.darkest?.g ?? -1, lifted.darkest?.b ?? -1, lifted.clearer * 100, dense.clearer * 100))
    // Kept by frame, the estimate is the same as read from the pictures.
    let frames = [(image: film, settings: settings), (image: image { x, y in (x / 6 + y / 10) % 2 == 0 ? 0.45 : 0.12 }, settings: settings)]
    let fromPictures = pipe.rollSlopeEstimate(frames, greenSlope: 0.6), fromEdges = pipe.rollSlopeEstimate(frames.map { pipe.edgeRatios($0.image, settings: $0.settings) }, greenSlope: 0.6)
    try check(fromPictures.slopes == fromEdges.slopes && fromPictures.why == fromEdges.why,
      "the roll's estimate from each frame's kept edges is the one read from the pictures")

    // The roll's check.
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("roll-check"), preferences: Preferences(defaults: defaults))
    model.frames = (1...4).map { FilmFrame(name: "0\($0)", rect: .full, format: "135") }
    func figures(darkest: RGB, clearer: Double = 0, measured: Bool = true) -> [UUID: FrameFigures] {
      Dictionary(model.frames.map { ($0.id, FrameFigures(darkest: darkest, clearer: clearer, own: nil, measuredBase: measured)) }, uniquingKeysWith: { a, _ in a })
    }
    model.frameFigures = figures(darkest: RGB(r: 0.08, g: 0.05, b: 0.07))
    let quiet = model.rollCheck.isEmpty
    model.frameFigures = figures(darkest: RGB(r: 0.62, g: 0.31, b: 0.51))
    let clearerBase = model.rollCheck.first { $0.id == "base-clearer" }
    model.frameFigures = figures(darkest: RGB(r: 0.62, g: 0.31, b: 0.51), measured: false)
    let guessed = model.rollCheck.isEmpty
    try check(quiet && clearerBase?.fix == .pickBase(model.frames[0].id) && clearerBase?.detail.contains("齿孔") == true && guessed,
      "the roll's check says when every frame's darkest lies far above a measured base, and where to pick it; quiet otherwise, or with the base guessed")
    model.frameFigures = figures(darkest: RGB(r: 0.08, g: 0.05, b: 0.07))
    model.frameFigures[model.frames[2].id]?.clearer = 0.06
    let denser = model.rollCheck.first { $0.id == "base-denser" }
    try check(denser?.fix == .pickBase(model.frames[2].id) && denser?.detail.contains("03") == true,
      "and when a frame has film clearer than its base, naming it")
    model.frameFigures = figures(darkest: RGB(r: 0.08, g: 0.05, b: 0.07))
    let sheet = model.conversionProfile.slopes
    for i in model.frames.indices { model.frames[i].adjustments.rollSlopes = RGB(r: sheet.r * 1.3, g: sheet.g, b: sheet.b) }
    let far = model.rollCheck.first { $0.id == "estimate-far" }
    for i in model.frames.indices { model.frames[i].adjustments.rollSlopes = RGB(r: sheet.r * 1.05, g: sheet.g, b: sheet.b * 0.97) }
    let near = model.rollCheck.isEmpty
    try check(model.conversionProfile.setsChannelContrast ? far?.detail.contains("+30%") == true && near : near,
      "and when the roll's estimate lies far from the data sheet (\(far?.detail.prefix(24) ?? "—")), not when near it")
    model.applyCheckFix(.pickBase(model.frames[1].id))
    try check(model.selectedID == model.frames[1].id && model.tool == .base, "a check's key goes to the frame with 取片基")

    // The frame shown alone, its 自动 waiting for its gray pixels: its render looks for them, the
    // finder the others.
    let wasOn = AppModel.findsAutoNeutrals
    model.frameFigures = [:]
    // In ③, as the check's key left it in ②'s de-masked picture, which balances nothing.
    model.convertStep = .grade
    model.useTool(.select)
    model.selectedID = model.frames[0].id
    model.singleView = true
    AppModel.findsAutoNeutrals = true
    let shownByRender = model.rendersGrays(model.frames[0]) && !model.rendersGrays(model.frames[1])
      && model.graysForRender(model.frames[0]) != nil
    model.frames[0].adjustments.neutralSample = RGB(r: 0.3, g: 0.2, b: 0.1)
    let picked = !model.rendersGrays(model.frames[0])
    AppModel.findsAutoNeutrals = wasOn
    model.singleView = false
    try check(shownByRender && picked && !model.rendersGrays(model.frames[1]),
      "the frame shown alone has its gray pixels looked for by its render, not a frame with a grey picked nor one not shown (page \(model.page), step \(model.convertStep), single \(model.singleView))")
  }
}
