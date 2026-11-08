import CoreGraphics
import Foundation

/// Module ①'s picture: the raw file's readings in a linear response, nothing inverted, taken off
/// or balanced; and how it was exposed, over, under or right, bare light passed over.
enum OriginalViewTests {
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
    func srgb(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    // A negative as the copy stand reads it: the orange base in a band (its thinnest film), the
    // picture denser, and the light box round it.
    let base = RGB(r: 0.5, g: 0.23, b: 0.14)
    func negative(base b: RGB, scale: Double = 1, clipRed: Double = 0, bare: Bool = false) -> CGImage {
      linear(200, 150) { x, y in
        if bare && (x < 20 || x >= 180) { return RGB(r: 1, g: 1, b: 1) }
        if Double(x) / 200 < clipRed && y < 20 { return RGB(r: 1, g: b.g * scale, b: b.b * scale) }
        let d = y < 30 ? 0 : 0.2 + 0.8 * Double(x % 50) / 50
        return RGB((0..<3).map { b.values[$0] * scale * pow(10, -d) })
      }
    }
    let good = pipe.exposure(negative(base: base))
    try check(good?.verdict == .good && abs((good?.headroom ?? 0) - log2(0.98 / 0.5)) < 0.1 && (good?.clipped ?? 1) == 0,
      String(format: "a negative whose base reads half the range is exposed right, a stop to spare: %@", good?.short ?? "-"))
    let over = pipe.exposure(negative(base: base, clipRed: 0.3))
    try check(over?.verdict == .over && (over?.clipped ?? 0) > 0.02, "film with a channel at the top is overexposed: \(over?.short ?? "-")")
    let under = pipe.exposure(negative(base: base, scale: 0.3))
    try check(under?.verdict == .under && abs((under?.headroom ?? 0) - log2(0.98 / 0.15)) < 0.1,
      "film whose brightest reads 15% of the range is underexposed: \(under?.short ?? "-")")
    let boxed = pipe.exposure(negative(base: base, bare: true))
    try check(boxed?.verdict == .good && abs((boxed?.bare ?? 0) - 0.2) < 0.01,
      "the light box round the film, every channel at the top, is passed over: \(boxed?.short ?? "-"), \(Int((boxed?.bare ?? 0) * 100))% bare")

    // The raw picture: light for light, encoded for the screen, the orange as it is.
    var s = Adjustments()
    s.inputGamma = 1
    s.base = RGB(r: 0.6, g: 0.3, b: 0.2)
    let raw = linear(40, 30) { x, _ in x < 20 ? base : RGB(r: 0.18, g: 0.18, b: 0.18) }
    let shown = pipe.original(raw, settings: s, oriented: true).map { pipe.raster($0) }
    let orange = shown?.pixel(10, 15), grey = shown?.pixel(30, 15)
    let orangeWant = RGB(base.values.map(srgb))
    try check(orange.map { o in zip(o.values, orangeWant.values).allSatisfy { abs($0 - $1) < 0.01 } } == true
      && grey.map { abs($0.g - srgb(0.18)) < 0.01 && abs($0.r - $0.b) < 0.005 } == true,
      "the raw picture is its readings in a linear response, a picked base not divided out: the orange \(orange.map { String(format: "%.3f %.3f %.3f", $0.r, $0.g, $0.b) } ?? "-")")

    // In the app: module ① shows the raw picture of the single frame with its exposure, and ② its
    // conversion; nothing to turn in ①.
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("original-library"), preferences: Preferences(defaults: defaults))
    let decoded = folder.appendingPathComponent("original-library/Decoded", isDirectory: true)
    try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
    for n in 1...2 {
      let url = decoded.appendingPathComponent("COPY000\(n).tif")
      try pipe.saveTIFF(negative(base: base, scale: n == 1 ? 1 : 0.3), to: url, dpi: 2400)
      model.addCapturedFrame(url, original: url, linear: true)
    }
    func settle(_ done: () -> Bool) {
      let deadline = Date().addingTimeInterval(15)
      while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    model.select(model.frames[0].id)
    model.page = .capture
    model.singleView = true
    model.refresh()
    settle { !model.rendering && model.exposureReading != nil }
    let rawShown = model.displayed.map { pipe.raster($0) }
    let topLeft = rawShown?.pixel(5, 5)
    let first = model.exposureReading
    try check(model.showsNegative && model.showsOriginal && first?.verdict == .good
      && topLeft.map { abs($0.r - srgb(0.5)) < 0.02 && abs($0.b - srgb(0.14)) < 0.02 } == true,
      "module ① shows the single frame raw, the orange base as read, with how it was exposed: \(first?.short ?? "-")")
    model.select(model.frames[1].id)
    model.refresh()
    settle { !model.rendering && model.exposureReading != first }
    try check(model.exposureReading?.verdict == .under, "the next frame, a darker copy, reads underexposed: \(model.exposureReading?.short ?? "-")")
    model.page = .convert
    settle { !model.rendering }
    let converted = model.displayed.map { pipe.raster($0) }?.pixel(5, 5)
    try check(model.exposureReading == nil && !model.showsNegative && converted.map { abs($0.r - srgb(0.5)) > 0.1 || abs($0.b - srgb(0.14)) > 0.1 } == true,
      "module ② shows its conversion, the exposure left to ①")
  }
}
