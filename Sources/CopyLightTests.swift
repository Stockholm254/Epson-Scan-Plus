import CoreGraphics
import Foundation

/// The copy light measured from three blank frames, each light alone: its crosstalk and its fall-off
/// across the frame found again from synthetic frames made with known ones, in any order; a negative
/// lit unevenly read evenly once both are taken out; and the next copies coming in with them.
enum CopyLightTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    let w = 360, h = 240
    let mix = Crosstalk.measured
    // Each light falls off by its own amount, red least, blue most, from a point off the middle both
    // ways, so a field turned over or mirrored would not fit.
    let falls = [0.25, 0.35, 0.5]
    func lit(_ light: Int, _ x: Int, _ y: Int) -> Double {
      let dx = (Double(x) / Double(w) - 0.45) * 2, dy = (Double(y) / Double(h) - 0.4) * 2
      return 1 - falls[light] * (dx * dx + dy * dy) / 2
    }
    func picture(_ value: (Int, Int) -> [Double]) -> CGImage {
      var px = [UInt16](repeating: 0, count: w * h * 3)
      for y in 0..<h { for x in 0..<w { for (c, v) in value(x, y).enumerated() { px[(y * w + x) * 3 + c] = UInt16(min(65535, max(0, v * 65535))) } } }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6,
        space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    // A blank frame with one light on: that light, as each camera channel reads it.
    func blank(_ light: Int, _ level: Double) -> CGImage {
      picture { x, y in (0..<3).map { c in mix.m[3 * c + light] * level * lit(light, x, y) } }
    }
    let frames = [blank(2, 0.6), blank(0, 0.7), blank(1, 0.5)]
    guard let (light, exposure) = pipe.lightCalibration(frames) else { throw DeskError.message("FAIL: light calibrated") }
    let matrixFound = zip(light.crosstalk.m, mix.m).allSatisfy { abs($0 - $1) < 0.01 }
    let corner = light.flat.value(at: CGPoint(x: 0.02, y: 0.03)), middle = light.flat.value(at: CGPoint(x: 0.45, y: 0.4))
    let expected = (0..<3).map { lit($0, w * 2 / 100, h * 3 / 100) }
    try check(matrixFound && (0..<3).allSatisfy { abs(corner.values[$0] - expected[$0]) < 0.04 && abs(middle.values[$0] - 1) < 0.03 }
      && abs(exposure.r - 0.7) < 0.1 && abs(exposure.b - 0.6) < 0.1,
      String(format: "three blank frames, one light each in any order, give the light's crosstalk and how each light falls off: corner %.2f · %.2f · %.2f, made %.2f · %.2f · %.2f",
        corner.r, corner.g, corner.b, expected[0], expected[1], expected[2]))
    try check(pipe.lightCalibration([blank(0, 0.7), blank(0, 0.6), blank(1, 0.5)]) == nil,
      "two frames of the same light do not make a calibration")

    // A blank film base under all three lights, lit unevenly, reads evenly once corrected.
    let film = [0.6, 0.35, 0.25]
    let negative = picture { x, y in (0..<3).map { c in (0..<3).map { j in mix.m[3 * c + j] * 0.8 * lit(j, x, y) * film[j] }.reduce(0, +) } }
    let even = pipe.samples(pipe.corrected(negative, crosstalk: light.crosstalk, flat: light.flat), maxDimension: w)
    let plain = pipe.samples(pipe.corrected(negative, crosstalk: light.crosstalk, flat: nil), maxDimension: w)
    func spread(_ s: Samples) -> Double {
      (0..<3).map { c in
        let v = [(12, 10), (w / 2, h / 2), (w - 12, h - 10), (w - 12, 10), (12, h - 10)].map { s.pixel($0.0, $0.1).values[c] }
        return (v.max()! - v.min()!) / v.max()!
      }.max()!
    }
    try check(spread(even) < 0.04 && spread(plain) > 0.2,
      String(format: "a film base lit unevenly reads the same in the corners as in the middle once the light is taken out: %.0f%% apart, %.0f%% before",
        spread(even) * 100, spread(plain) * 100))

    // The next copies come in read through it; turned off for the roll, as the sensor read them.
    let root = folder.appendingPathComponent("copy-light", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let decoded = root.appendingPathComponent("Decoded", isDirectory: true)
    try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: root.appendingPathComponent("library"), preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    for (n, frame) in frames.enumerated() {
      let url = decoded.appendingPathComponent("EPS0000\(n + 1).tif")
      try pipe.saveTIFF(frame, to: url, dpi: 300)
      model.addCapturedFrame(url, original: url, linear: true, sensor: true)
    }
    model.calibrateLight()
    for _ in 0..<100 where model.preferences.lightCalibration == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    let kept = Preferences(defaults: defaults).lightCalibration
    try check(kept.map { zip($0.crosstalk.m, mix.m).allSatisfy { abs($0 - $1) < 0.01 } } == true
      && model.frames.allSatisfy { $0.crosstalk == kept?.crosstalk && $0.flatField == kept?.flat }
      && model.lightDescription.contains("漏进"),
      "the roll's last three frames calibrate the light, kept for the copies to come, and the roll is read through it")
    let url = decoded.appendingPathComponent("EPS00004.tif")
    try pipe.saveTIFF(negative, to: url, dpi: 300)
    model.addCapturedFrame(url, original: url, linear: true, sensor: true)
    let next = model.frames[3]
    model.removeCrosstalk(false)
    try check(next.crosstalk == kept?.crosstalk && next.flatField == kept?.flat
      && model.frames.allSatisfy { $0.crosstalk == nil && $0.flatField == nil },
      "a copy that comes in next is read through the calibrated light; turned off for the roll, every frame is read as the sensor read it")
    edits.undo()
    try check(model.frames.allSatisfy { $0.flatField == kept?.flat }, "and undo reads them through it again")
  }
}
