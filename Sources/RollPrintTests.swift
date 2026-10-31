import CoreGraphics
import Foundation

/// A roll printed as one: its frames share one white balance, each lit as on its own; and one pair
/// of ends, so a scene shot two stops under comes out darker than the same scene shot right, as on a
/// lab's print, where each frame on its own lifts it back. A frame's own grey stays its own.
enum RollPrintTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    let portra = FilmProfile.builtins.first { $0.id == "portra160" }!
    let w = 160, h = 110
    let base = RGB(r: 0.85, g: 0.57, b: 0.38)
    // A scene of greys and a little colour, on Portra 160's slopes, `under` log exposure short, its
    // light `blue` bluer.
    func negative(under: Double, blue: Double) -> CGImage {
      var samples = [UInt16](repeating: 65535, count: w * h * 4)
      for y in 0..<h {
        for x in 0..<w {
          let exposure = 0.2 + 1.2 * Double(x) / Double(w - 1) - under
          let tint = [0.0, y < h / 2 ? 0.05 : 0.0, blue]
          for c in 0..<3 {
            let v = base.values[c] * pow(10, -portra.slopes.values[c] * max(0, exposure + tint[c]) / 2.2)
            samples[(y * w + x) * 4 + c] = UInt16(v * 65535)
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
    let root = folder.appendingPathComponent("roll-print", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var urls = [URL]()
    for (n, scene) in [(0.0, 0.0), (0.6, 0.0), (0.0, 0.12)].enumerated() {
      let url = root.appendingPathComponent("p\(n).tif")
      try pipe.saveTIFF(negative(under: scene.0, blue: scene.1), to: url, dpi: 2400)
      urls.append(url)
    }
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: root.appendingPathComponent("library"), preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    model.importURLs(urls)
    model.setPoolPictures(true)
    model.chooseProfile(portra)
    func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    var slopesDone = false
    model.updateRollSlopes { slopesDone = true }
    for _ in 0..<200 where !slopesDone { settle(0.05) }
    func analysis(_ i: Int) throws -> ToneAnalysis {
      pipe.analyze(try model.source(for: model.frames[i], maxDimension: 300), settings: model.frames[i].adjustments, profile: model.profile)
    }
    func lightness(_ i: Int) throws -> Double {
      let f = model.frames[i]
      let r = pipe.raster(try pipe.preview(try model.source(for: f, maxDimension: 300), settings: f.adjustments, profile: model.profile), maxDimension: 300)
      var sum = 0.0
      for y in 0..<r.height { for x in 0..<r.width { sum += r.pixel(x, y).g } }
      return sum / Double(r.width * r.height) * 255
    }
    let apart = (try lightness(0), try lightness(1), try lightness(2))
    // One white balance: the same for every frame, each lit as on its own.
    model.select(model.frames[0].id)
    model.setSharedBalance(true)
    for _ in 0..<200 where model.frames.contains(where: { $0.adjustments.rollPrint == nil }) { settle(0.05) }
    let balanced = try (0..<3).map(analysis)
    let oneBalance = balanced.dropFirst().allSatisfy { $0.balance == balanced[0].balance }
    let lit = (try lightness(0), try lightness(1), try lightness(2))
    try check(model.frames.allSatisfy { $0.adjustments.sharedBalance == true && $0.adjustments.rollPrint != nil } && oneBalance
      && abs(lit.0 - apart.0) < 6 && abs(lit.1 - apart.1) < 6,
      String(format: "with one white balance for the roll, its frames share it and each is lit as on its own: %.0f, %.0f, was %.0f, %.0f", lit.0, lit.1, apart.0, apart.1))
    // One pair of ends: a scene shot two stops under stays darker than the same scene shot right.
    model.setSharedLevels(true)
    for _ in 0..<200 where model.frames.contains(where: { $0.adjustments.rollPrint == nil }) { settle(0.05) }
    let a = try (0..<3).map(analysis)
    let shared = a.dropFirst().allSatisfy { $0.balance == a[0].balance && $0.low == a[0].low && $0.high == a[0].high }
    let together = (try lightness(0), try lightness(1))
    try check(shared && together.0 - together.1 > (apart.0 - apart.1) + 10,
      String(format: "with one pair of ends as well, a scene two stops under comes out darker (%.0f against %.0f), where each frame alone lifted it to %.0f against %.0f",
        together.1, together.0, apart.1, apart.0))
    // A grey picked on one frame stays that frame's own.
    model.select(model.frames[2].id)
    model.change("中性") { $0.neutralSample = RGB(r: 0.3, g: 0.2, b: 0.12) }
    let own = try analysis(2), others = try analysis(0)
    try check(own.balance != others.balance && others.balance == a[0].balance,
      "a grey picked on one frame balances that frame by it; the others keep the roll's")
    model.setSharedLevels(false)
    model.setSharedBalance(false)
    let off = model.frames.allSatisfy { !$0.adjustments.printsWithRoll }
    edits.undo()
    try check(off && model.frames.allSatisfy { $0.adjustments.sharedBalance == true && $0.adjustments.sharedLevels == nil },
      "each turned off for the roll on its own, and undone one at a time")
  }
}
