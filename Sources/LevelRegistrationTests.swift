import CoreGraphics
import Foundation

/// Scans put on their preview's scale: measuring a scan's levels against the preview, refusing
/// a scan that no longer matches it, and conversion reading scans on that scale.
enum LevelRegistrationTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    // A smooth picture over the bed, the same at any resolution: what both scans read.
    func scene(_ x: Double, _ y: Double) -> SIMD3<Double> {
      let a = 0.5 + 0.35 * sin(x * 9 + 0.3) * cos(y * 7), b = 0.5 + 0.3 * sin(x * 5 - y * 11)
      return SIMD3(0.12 + 0.3 * a, 0.05 + 0.18 * b, 0.015 + 0.08 * (a * b))
    }
    func image(width: Int, height: Int, covering r: NormalRect, gain: SIMD3<Double> = .one, offset: SIMD3<Double> = .zero,
               shift: CGPoint = .zero, flat: Bool = false) -> CGImage {
      var samples = [UInt16](repeating: 0, count: width * height * 3)
      for j in 0..<height {
        for i in 0..<width {
          let x = r.x + (Double(i) + 0.5) / Double(width) * r.width + shift.x, y = r.y + (Double(j) + 0.5) / Double(height) * r.height + shift.y
          let v = (flat ? SIMD3(0.3, 0.12, 0.04) : scene(x, y)) * gain + offset
          for c in 0..<3 { samples[(j * width + i) * 3 + c] = UInt16(max(0, min(1, v[c])) * 65535) }
        }
      }
      return CGImage(
        width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
        space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    // A 600 dpi preview of the bed and a 2400 dpi scan of one frame on it, the scan's blue 11% up.
    let preview = image(width: 600, height: 980, covering: .full)
    let frame = NormalRect(x: 0.40, y: 0.30, width: 0.16, height: 0.15)
    // Four scan pixels to a preview pixel, the footprint exactly the scan's pixels as a scan's is.
    let scanSize = (408, 627)
    let footprint = NormalRect(x: 0.395, y: 0.295, width: Double(scanSize.0) / 2400, height: Double(scanSize.1) / 3920)
    let gain = SIMD3(0.998, 1.003, 1.115), offset = SIMD3(-0.002, -0.0002, -0.0003)
    let scan = image(width: scanSize.0, height: scanSize.1, covering: footprint, gain: gain, offset: offset)
    guard let l = LevelRegistration.measure(scan: scan, footprint: footprint, preview: preview, region: frame) else {
      throw DeskError.message("FAIL: a scan is measured against its preview")
    }
    try check(l.usable && (0..<3).allSatisfy { abs(l.gain.values[$0] - gain[$0]) < 0.003 && abs(l.offset.values[$0] - offset[$0]) < 0.0004 },
      String(format: "a scan's levels are measured against the preview: blue gain %.4f (true %.4f), fit %.4f", l.gain.b, gain[2], l.fit))
    // Placed a third of a preview pixel off, as the head repeats to a few scan pixels.
    let nudged = image(width: scanSize.0, height: scanSize.1, covering: footprint, gain: gain, offset: offset,
      shift: CGPoint(x: 0.33 / 600, y: -0.4 / 980))
    let n = LevelRegistration.measure(scan: nudged, footprint: footprint, preview: preview, region: frame)
    try check(n?.usable == true && abs((n?.gain.b ?? 0) - gain[2]) < 0.004, "and still when the scan sits a fraction of a preview pixel off")
    let moved = image(width: scanSize.0, height: scanSize.1, covering: footprint, gain: gain, offset: offset, shift: CGPoint(x: 8.0 / 600, y: 0))
    let m = LevelRegistration.measure(scan: moved, footprint: footprint, preview: preview, region: frame)
    try check(m.map { !$0.usable } ?? true, String(format: "a scan of film moved since the preview is refused (fit %.3f)", m?.fit ?? 0))
    let flatPreview = image(width: 600, height: 980, covering: .full, flat: true)
    let flatScan = image(width: scanSize.0, height: scanSize.1, covering: footprint, gain: gain, offset: offset, flat: true)
    let f = LevelRegistration.measure(scan: flatScan, footprint: footprint, preview: flatPreview, region: frame)
    try check(f.map { !$0.usable } ?? true, "so is a picture too flat to tell gain from offset")
    let corrected = ImagePipeline.shared.leveled(scan, scale: l.scale, bias: l.bias)
    let on = ImagePipeline.shared.raster(corrected, maxDimension: 200), plain = ImagePipeline.shared.raster(scan, maxDimension: 200)
    let truth = scene(footprint.x + 0.5 * footprint.width, footprint.y + 0.5 * footprint.height)
    let mid = on.pixel(on.width / 2, on.height / 2).values
    try check((0..<3).allSatisfy { abs(mid[$0] - truth[$0]) < 0.002 } && abs(plain.pixel(plain.width / 2, plain.height / 2).b - truth[2]) > 0.003,
      "putting the scan on the preview's scale undoes its levels")

    // Through the app: an older project's scan is measured when the project opens.
    let root = folder.appendingPathComponent("level-registration")
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Originals"), withIntermediateDirectories: true)
    let overviewURL = root.appendingPathComponent("overview.tif"), scanURL = root.appendingPathComponent("Originals/01_2400dpi.tiff")
    try ImagePipeline.shared.saveTIFF(preview, to: overviewURL, dpi: 600)
    try ImagePipeline.shared.saveTIFF(scan, to: scanURL, dpi: 2400)
    var scanned = FilmFrame(name: "01", rect: frame, format: "135")
    scanned.scanPath = scanURL.path
    scanned.scanRect = footprint
    scanned.scanDPI = 2400
    scanned.adjustments.inputGamma = 1
    let project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 600, physicalWidthMM: 149.86, physicalHeightMM: 246.38,
      filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: [scanned], scanBackendID: "epson2-linear-v1")
    let projectURL = root.appendingPathComponent("Session.filmdesk")
    try JSONEncoder().encode(project).write(to: projectURL)
    let model = AppModel(libraryURL: root)
    model.loadProject(projectURL)
    for _ in 0..<60 where model.frames.first?.levels == nil { settle(0.1) }
    for _ in 0..<40 where model.rendering { settle(0.1) }
    let measured = model.frames.first?.levels
    let source = ImagePipeline.shared.raster(try model.source(for: model.frames[0]), maxDimension: 200)
    let center = source.pixel(source.width / 2, source.height / 2).values
    let expected = scene(frame.x + 0.5 * frame.width, frame.y + 0.5 * frame.height)
    try check(measured?.usable == true && (0..<3).allSatisfy { abs(center[$0] - expected[$0]) < 0.003 } && model.status.contains("对齐到预览"),
      "opening a project from before measures its scans, and conversion reads them on the preview's scale")
    let saved = try JSONDecoder().decode(DeskProject.self, from: Data(contentsOf: projectURL))
    try check(saved.frames[0].levels == measured, "the measurement is kept in the project, so it is made once")
    let raw = ImagePipeline.shared.raster(try model.source(for: model.frames[0], raw: true), maxDimension: 200)
    try check(abs(raw.pixel(raw.width / 2, raw.height / 2).b - center[2]) > 0.003, "measuring the scanner itself (IT8) still reads the raw scan")
    // The command-line export measures before it exports, and writes nothing back.
    var older = project
    older.frames[0].levels = nil
    try JSONEncoder().encode(older).write(to: projectURL)
    let before = try Data(contentsOf: projectURL)
    let exporter = AppModel(libraryURL: root)
    exporter.readOnly = true
    exporter.loadProject(projectURL)
    exporter.registerMissingLevels(wait: true)
    try check(exporter.frames[0].levels?.usable == true && (try Data(contentsOf: projectURL)) == before,
      "the command-line export measures the scans first and leaves the project as it was")
  }
}
