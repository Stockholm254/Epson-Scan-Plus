import CoreGraphics
import Foundation

/// Scanner calibration on an IT8.7/1 target: the reference file, finding the patches, and the
/// stray light and colour fit, on a synthetic target with known answers.
enum IT8Tests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    // A target whose patches have known linear transmissions; XYZ through sRGB's D50 matrix.
    let m0 = [0.4360747, 0.3850649, 0.1430804, 0.2225045, 0.7168786, 0.0606169, 0.0139322, 0.0971045, 0.7141733]
    var seed: UInt64 = 7
    func random() -> Double {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Double(seed >> 11) / Double(1 << 53)
    }
    var transmission = [String: [Double]]()
    for id in IT8Layout.grid { transmission[id] = (0..<3).map { _ in 0.005 + 0.85 * pow(random(), 1.6) } }
    for (i, id) in IT8Layout.grays.enumerated() {
      let t = 0.9 * pow(10, -2.7 * Double(i) / 23)
      transmission[id] = [t, t, t]
    }
    var text = "IT8.7/1\r\nDESCRIPTOR \"Synthetic IT8.7/1\"\r\nPROD_DATE \"2026:10\"\r\nNUMBER_OF_FIELDS 4\r\nBEGIN_DATA_FORMAT\r\nSAMPLE_ID XYZ_X XYZ_Y XYZ_Z\r\nEND_DATA_FORMAT\r\nBEGIN_DATA\r\n"
    for id in IT8Layout.grid + IT8Layout.grays {
      let t = transmission[id]!
      var xyz = [0.0, 0.0, 0.0]
      for r in 0..<3 {
        let row = m0[r * 3] * t[0] + m0[r * 3 + 1] * t[1] + m0[r * 3 + 2] * t[2]
        xyz[r] = row * 100
      }
      text += String(format: "%@ %.4f %.4f %.4f\r\n", id, xyz[0], xyz[1], xyz[2])
    }
    text += "END_DATA\r\n"
    let reference = try IT8Reference.parse(text, name: "synthetic")
    try check(reference.patches.count == 288 && reference.batch == "2026:10" && reference.name == "Synthetic IT8.7/1",
      "an IT8.7/1 reference file is read: 264 patches and 24 greys, with its batch")
    var rejected = false
    do { _ = try IT8Reference.parse(text.replacingOccurrences(of: "GS11 ", with: "XX11 "), name: "broken") } catch { rejected = true }
    try check(rejected, "a reference file missing a patch is refused")

    // Its scan: 40 px patches, linear, with each channel's white and stray light.
    let white = [0.92, 0.88, 0.85], flare = [0.004, 0.003, 0.006]
    let w = 1040, h = 700, pitch = 40.0
    let a01 = CGPoint(x: 100, y: 90), a22 = CGPoint(x: 100 + 21 * pitch, y: 96), l01 = CGPoint(x: 94, y: 90 + 11 * pitch)
    let l22 = CGPoint(x: 94 + 21 * pitch, y: 96 + 11 * pitch)
    let dmin = CGPoint(x: 94, y: 90 + 13 * pitch), dmax = CGPoint(x: 94 + 21 * pitch, y: 96 + 13 * pitch)
    let marks = [a01, a22, l01, l22, dmin, dmax].map { CGPoint(x: $0.x / Double(w), y: $0.y / Double(h)) }
    var samples = [UInt16](repeating: 0, count: w * h * 4)
    let centres = IT8Layout.centres(marks)
    for (id, c) in centres {
      let t = transmission[id]!, cx = Int(c.x * Double(w)), cy = Int(c.y * Double(h))
      for y in (cy - 15)..<(cy + 15) {
        for x in (cx - 15)..<(cx + 15) {
          for ch in 0..<3 { samples[(y * w + x) * 4 + ch] = UInt16(white[ch] * (t[ch] + flare[ch]) * 65535) }
          samples[(y * w + x) * 4 + 3] = 65535
        }
      }
    }
    let scan = CGImage(
      width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
      provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
    try check(IT8Layout.centres(Array(marks.prefix(4))).count == 264 && centres.count == 288,
      "four points place the 264 colour patches, two more the 24 greys")
    let readings = try IT8Layout.sample(scan, marks: marks)
    let a10 = readings["F10"]!, expected = (0..<3).map { white[$0] * (transmission["F10"]![$0] + flare[$0]) }
    try check((0..<3).allSatisfy { abs(a10.values[$0] - expected[$0]) < 0.002 }, "each patch is read at its centre")
    let calibration = try ScannerCalibration.measure(readings, reference: reference)
    try check((0..<3).allSatisfy { abs(calibration.flare.values[$0] - flare[$0]) < 0.0003 && abs(calibration.white.values[$0] / white[$0] - 1) < 0.01 },
      String(format: "the grey scale measures each channel's stray light: R %.3f%% · G %.3f%% · B %.3f%% (true 0.400 · 0.300 · 0.600)",
        calibration.flare.r * 100, calibration.flare.g * 100, calibration.flare.b * 100))
    try check(calibration.grayErrorBefore > 0.3 && calibration.grayError < 0.01,
      String(format: "taking it out, the grey scale's densest step goes from %.2f D off to %.3f D", calibration.grayErrorBefore, calibration.grayError))
    try check(calibration.meanDeltaE < 0.3 && zip(calibration.matrix, m0).allSatisfy { abs($0 - $1) < 0.01 },
      String(format: "the colour patches fit a 3×3 matrix to ΔE %.2f on average", calibration.meanDeltaE))

    // Where it applies: this app's linear scans and previews, not imports or 24-bit scans.
    let model = AppModel(libraryURL: folder)
    model.preferences.scannerCalibration = calibration
    var linear = FilmFrame(name: "01", rect: .full, format: "135")
    linear.adjustments.inputGamma = 1
    var imported = linear
    imported.sourcePath = "/tmp/elsewhere.tif"
    var encoded = linear
    encoded.adjustments.inputGamma = 2.2
    try check(model.flareOffset(linear) == calibration.offset && model.flareOffset(imported) == nil && model.flareOffset(encoded) == nil,
      "stray light comes out of this app's linear scans only")
    model.preferences.removeFlare = false
    try check(model.flareOffset(linear) == nil, "and not when turned off")
    let cleaned = pipe.removingFlare(calibration.offset, from: scan)
    let before = pipe.samples(try pipe.crop(scan, rect: NormalRect(x: 0.4, y: 0.4, width: 0.02, height: 0.02)), maxDimension: 10)
    let after = pipe.samples(try pipe.crop(cleaned, rect: NormalRect(x: 0.4, y: 0.4, width: 0.02, height: 0.02)), maxDimension: 10)
    try check(abs(Double(before.values[0] - after.values[0]) - calibration.offset.r) < 0.0005, "taking it out subtracts it from the raw reading")
    let suite = "local.filmdesk.mac.it8-test"
    UserDefaults().removePersistentDomain(forName: suite)
    let saved = Preferences(defaults: UserDefaults(suiteName: suite)!)
    saved.scannerCalibration = calibration
    saved.removeFlare = false
    let read = Preferences(defaults: UserDefaults(suiteName: suite)!)
    try check(read.scannerCalibration == calibration && !read.removeFlare, "the calibration is remembered")
    UserDefaults().removePersistentDomain(forName: suite)
  }
}
