import CoreGraphics
import Foundation
import ImageIO

enum SharpeningTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    // A synthetic target: bright squares tilted 3° on a dark ground, blurred by an isotropic
    // Gaussian of σ = 2.5 px, written as a linear 16-bit TIFF at 4000 dpi.
    let w = 1400, h = 1000, sigma = 2.5, dpi = 4000.0
    let tilt = 3 * Double.pi / 180, side = 220.0
    let centres = [(300.0, 280.0), (760.0, 300.0), (1100.0, 700.0), (420.0, 720.0)]
    func phi(_ x: Double) -> Double { 0.5 * (1 + erf(x / (sigma * 2.0.squareRoot()))) }
    var samples = [UInt16](repeating: 65535, count: w * h * 4)
    for y in 0..<h {
      for x in 0..<w {
        var v = 0.03
        for (cx, cy) in centres {
          let dx = Double(x) - cx, dy = Double(y) - cy
          let u = dx * cos(tilt) + dy * sin(tilt), t = -dx * sin(tilt) + dy * cos(tilt)
          let a = side / 2
          v += 0.87 * (phi(u + a) - phi(u - a)) * (phi(t + a) - phi(t - a))
        }
        for c in 0..<3 { samples[(y * w + x) * 4 + c] = UInt16(min(1, v) * 65535) }
      }
    }
    let image = CGImage(
      width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
      provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
    let target = folder.appendingPathComponent("sharpening-target.tif")
    try? FileManager.default.removeItem(at: target)
    let dest = CGImageDestinationCreateWithURL(target as CFURL, "public.tiff" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [
      kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: "Epson Scan plus · epson2 RGB48 · identity gamma"],
    ] as CFDictionary)
    try check(CGImageDestinationFinalize(dest), "synthetic target written")

    let profile = try TargetMeasurement.measure(target)
    // A Gaussian's MTF50 is √(ln2/2)/(πσ) cycles per pixel.
    let expected = (log(2.0) / 2).squareRoot() / (.pi * sigma) * dpi / 25.4
    let h50 = SharpeningProfile.crossing(profile.horizontal, 0.5), v50 = SharpeningProfile.crossing(profile.vertical, 0.5)
    try check(profile.horizontalEdges >= 4 && profile.verticalEdges >= 4 && profile.targetGamma == 1,
      "target measurement finds the squares' edges and reads the file as linear (\(profile.horizontalEdges) + \(profile.verticalEdges) edges)")
    try check(abs(h50 / expected - 1) < 0.1 && abs(v50 / expected - 1) < 0.1,
      String(format: "measured MTF50 matches the known blur: %.2f / %.2f lp/mm, expected %.2f", h50, v50, expected))

    // The kernel keeps unit gain, has negative lobes, and switches off at strength 0.
    guard let kernel = profile.sharpener(dpi: dpi, strength: Sharpening.defaultStrength, gamma: 1) else {
      throw DeskError.message("FAIL: a kernel exists at the target's resolution")
    }
    let sum = kernel.kernel.reduce(0, +)
    try check(abs(sum - 1) < 1e-4 && kernel.kernel.contains { $0 < 0 } && profile.sharpener(dpi: dpi, strength: 0, gamma: 1) == nil,
      "deconvolution kernel: unit gain, negative lobes, off at strength 0")

    // Deconvolving the target sharpens its edges and leaves flat areas unchanged.
    let sharpened = try ImagePipeline.shared.sharpen(image, with: kernel)
    func edge(_ image: CGImage) throws -> (mtf50: Double, flat: Double) {
      let plane = try TargetMeasurement.GreenPlane(image, gamma: 1)
      // The left edge of the first square, and the middle of that square.
      let roi = plane.region(300 - 110 - 25, 230, 50, 100, transposed: false)
      guard let e = TargetMeasurement.sfr(roi.values, rows: roi.rows, cols: roi.cols) else {
        throw DeskError.message("FAIL: edge measured")
      }
      let flat = (260..<300).flatMap { y in (280..<320).map { plane[$0, y] } }
      return (e.mtf50 * dpi / 25.4, flat.reduce(0, +) / Double(flat.count))
    }
    let before = try edge(image), after = try edge(sharpened)
    try check(after.mtf50 > before.mtf50 * 1.4 && abs(after.flat / before.flat - 1) < 0.005,
      String(format: "deconvolution raises MTF50 %.1f → %.1f lp/mm, flat areas unchanged (%.4f → %.4f)", before.mtf50, after.mtf50, before.flat, after.flat))

    // Own scans are sharpened by default; imported images and previews are not.
    var scan = FilmFrame(name: "01", rect: .full, format: "135")
    scan.scanPath = target.path
    scan.scanDPI = Int(dpi)
    scan.adjustments.inputGamma = 1
    var imported = scan
    imported.scanPath = nil
    imported.sourcePath = target.path
    let preview = FilmFrame(name: "02", rect: .full, format: "135")
    try check(Sharpening.sharpener(profile, frame: scan, maxDimension: nil) != nil
      && Sharpening.sharpener(profile, frame: imported, maxDimension: nil) == nil
      && Sharpening.sharpener(profile, frame: preview, maxDimension: nil) == nil
      && Sharpening.sharpener(nil, frame: scan, maxDimension: nil) == nil,
      "own scans are sharpened by default; imports, previews and a missing profile are not")
    imported.adjustments.sharpening = 0.6
    scan.adjustments.sharpening = 0
    try check(Sharpening.sharpener(profile, frame: imported, maxDimension: nil) != nil
      && Sharpening.sharpener(profile, frame: scan, maxDimension: nil) == nil,
      "per-frame strength turns sharpening on for an import and off for a scan")
    // A reduced preview gets a kernel for its own, lower resolution.
    scan.adjustments.sharpening = nil
    let reduced = Sharpening.sharpener(profile, frame: scan, maxDimension: 350)
    try check(reduced == nil || reduced!.radius <= kernel.radius, "a reduced preview uses a smaller kernel")

    // The profile survives a restart.
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    Preferences(defaults: defaults).sharpening = profile
    try check(Preferences(defaults: defaults).sharpening == profile, "the sharpening profile is kept in settings")
    let cleared = Preferences(defaults: defaults)
    cleared.sharpening = nil
    try check(Preferences(defaults: defaults).sharpening == nil, "removing the profile clears it from settings")
  }
}
