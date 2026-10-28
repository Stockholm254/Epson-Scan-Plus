import CoreGraphics
import Foundation

/// Scanning a row of the holder in one pass: the timing measured on the V850, which frames go
/// together, and a pass cut back into each frame's own original.
enum RowScanTests {
  /// The 48-bit interface, scanning by being told; it hands back whatever picture it is given.
  private final class RowScanner: ScannerController {
    override var backendID: String { "epson2-linear-v1" }
    var area: CGRect?
    override var actualScanAreaMM: CGRect? { area }
    var requests = [(rect: NormalRect, name: String, directory: URL)]()
    override func scan(rect: NormalRect, dpi: Int, directory: URL, name: String) throws {
      requests.append((rect, name, directory))
      busy = true
      progress = 0
    }
    /// The pass comes back as `image`, read over `mm` of the bed.
    func deliver(_ image: CGImage, mm: CGRect, dpi: Int) throws {
      let request = requests.last!
      let url = request.directory.appendingPathComponent(request.name).appendingPathExtension("tiff")
      try ImagePipeline.shared.saveTIFF(image, to: url, dpi: dpi)
      area = mm
      onScan?(url)
      busy = false
      progress = 1
      onFinished?(nil)
    }
  }

  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    // The seven passes timed on the V850 at 2400 dpi (width × height in mm, seconds).
    let measured: [(String, Double, Double, Double)] = [
      ("frame 09", 23.37, 35.75, 47.0), ("again", 23.37, 35.75, 41.8), ("again", 23.37, 35.75, 41.7), ("again", 23.37, 35.75, 43.8),
      ("strip 08–10", 23.37, 111.82, 113.8), ("row 03/09/15", 127.34, 36.76, 91.6), ("row again", 127.34, 36.76, 91.3),
    ]
    let errors = measured.map { m in ScanTiming.seconds(widthMM: m.1, heightMM: m.2, dpi: 2400, bytesPerPixel: 6) / m.3 - 1 }
    try check(errors.allSatisfy { abs($0) < 0.08 },
      "the timing model gives the seven measured passes to within " + String(format: "%.0f%%", errors.map(abs).max()! * 100)
        + ": a narrow window waits on the head, a wide one on the data")

    // The hardware-test roll as it lies in the holder: three strips of six.
    let bed = CGSize(width: 149.69, height: 246.34)
    let layout: [(Double, Double, Double, Double)] = [
      (12.19, 6.95, 22.18, 35.24), (12.19, 45.74, 22.18, 35.92), (12.19, 83.52, 22.18, 35.92), (12.19, 121.81, 22.18, 35.75),
      (12.19, 159.76, 22.18, 35.92), (12.19, 199.07, 22.18, 35.41), (63.67, 6.61, 23.37, 35.92), (63.67, 44.56, 23.37, 35.92),
      (63.67, 82.68, 23.37, 35.75), (63.67, 120.46, 23.37, 35.92), (63.67, 158.58, 23.37, 35.92), (63.67, 196.53, 23.37, 36.09),
      (115.65, 6.82, 23.88, 36.22), (115.65, 45.24, 23.88, 35.75), (115.99, 83.19, 23.54, 35.75), (115.99, 120.97, 23.54, 35.92),
      (116.16, 159.09, 23.37, 35.92), (116.33, 197.04, 23.20, 35.75),
    ]
    let roll = layout.enumerated().map { i, l in
      FilmFrame(name: String(format: "%02d", i + 1),
        rect: NormalRect(x: l.0 / bed.width, y: l.1 / bed.height, width: l.2 / bed.width, height: l.3 / bed.height), format: "135")
    }
    func passes(_ names: [String], dpi: Int = 2400, rows: Bool = true) -> [[String]] {
      ScanPasses.group(roll.filter { names.contains($0.name) }, physicalMM: bed, dpi: dpi, bytesPerPixel: 6, rows: rows)
        .map { $0.map(\.name) }
    }
    let all = roll.map(\.name)
    let holder = passes(all)
    let byRow = ScanPasses.group(roll, physicalMM: bed, dpi: 2400, bytesPerPixel: 6, rows: true)
    let rowTime = byRow.map { ScanPasses.seconds($0, physicalMM: bed, dpi: 2400, bytesPerPixel: 6) }.reduce(0, +)
    let frameTime = roll.map { ScanPasses.seconds([$0], physicalMM: bed, dpi: 2400, bytesPerPixel: 6) }.reduce(0, +)
    try check(holder.count == 6 && holder.allSatisfy { $0.count == 3 } && holder[0] == ["01", "07", "13"] && holder[2] == ["03", "09", "15"],
      String(format: "a full holder goes row by row, three frames a pass: %.1f min instead of %.1f", rowTime / 60, frameTime / 60))
    try check(passes(["07", "08", "09", "10", "11", "12"]) == [["07"], ["08"], ["09"], ["10"], ["11"], ["12"]],
      "one strip on its own is scanned frame by frame, as before")
    try check(passes(["03", "15"]) == [["03"], ["15"]] && passes(["03", "09"]) == [["03", "09"]] && passes(["09"]) == [["09"]],
      "two frames with a strip between them are quicker apart; two neighbours go together")
    try check(passes(all, rows: false) == all.map { [$0] }, "with row scanning off, every frame on its own in the order ticked")
    let fine = ScanPasses.group(roll, physicalMM: bed, dpi: 4800, bytesPerPixel: 6, rows: true)
    try check(fine.allSatisfy { $0.count == 1 || ScanPasses.bytes($0, physicalMM: bed, dpi: 4800, bytesPerPixel: 6) <= ScanPasses.maxBytes }
      && fine.contains { $0.count < 3 },
      "at 4800 dpi a pass stays under 700 MB, so a row of three is split: \(fine.map(\.count))")

    // A pass cut back into each frame's original, through the app.
    let root = folder.appendingPathComponent("row-scan")
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let scanner = RowScanner()
    scanner.bits = 16
    let plate = CGSize(width: scanner.physicalMM.width, height: scanner.physicalMM.height)
    let overviewCtx = CGContext(data: nil, width: 300, height: 493, bitsPerComponent: 8, bytesPerRow: 0,
      space: ImagePipeline.shared.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    overviewCtx.setFillColor(gray: 0.6, alpha: 1)
    overviewCtx.fill(CGRect(x: 0, y: 0, width: 300, height: 493))
    let overviewURL = root.appendingPathComponent("overview.png")
    try ImagePipeline.shared.savePNG(overviewCtx.makeImage()!, to: overviewURL)
    // Frames 03, 09 and 15 side by side, and 10 below them.
    let picked = [2, 8, 14, 9].map { i -> FilmFrame in
      let l = layout[i]
      return FilmFrame(name: String(format: "%02d", i + 1),
        rect: NormalRect(x: l.0 / plate.width, y: l.1 / plate.height, width: l.2 / plate.width, height: l.3 / plate.height), format: "135")
    }
    let project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 50, physicalWidthMM: plate.width, physicalHeightMM: plate.height,
      filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 300, frames: picked, scanBackendID: "epson2-linear-v1")
    let projectURL = root.appendingPathComponent("Session.epscan")
    try JSONEncoder().encode(project).write(to: projectURL)
    let model = AppModel(libraryURL: root, scanner: scanner)
    model.loadProject(projectURL)
    for _ in 0..<40 where model.rendering { settle(0.1) }
    model.dpi = 300
    model.scanEnabled()
    let row = ScanPasses.union(Array(model.frames.prefix(3)))
    try check(scanner.requests.count == 1 && scanner.requests[0].name.hasPrefix("row-03-09-15_300dpi")
      && abs(scanner.requests[0].rect.x - row.x) < 1e-9 && abs(scanner.requests[0].rect.width - row.width) < 1e-9
      && model.scanningRect == row && model.scanningFrames.count == 3,
      "the three frames of the row are scanned in one pass across them")
    scanner.progress = 0.5
    try check(model.scanProgressLabel.hasPrefix("第 1–3 / 4 张 · 本行"), "progress counts the row's three frames together: \(model.scanProgressLabel)")
    // The pass: each pixel says where it is, red across and green down.
    let ppmm = 300 / 25.4
    let mm = CGRect(x: row.x * plate.width, y: row.y * plate.height, width: row.width * plate.width, height: row.height * plate.height)
    let pw = Int((mm.width * ppmm).rounded()), ph = Int((mm.height * ppmm).rounded())
    var samples = [UInt16](repeating: 0, count: pw * ph * 3)
    for y in 0..<ph {
      for x in 0..<pw {
        samples[(y * pw + x) * 3] = UInt16(x * 16)
        samples[(y * pw + x) * 3 + 1] = UInt16(y * 64)
        samples[(y * pw + x) * 3 + 2] = 30000
      }
    }
    let pass = CGImage(
      width: pw, height: ph, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: pw * 6,
      space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
      provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
    try scanner.deliver(pass, mm: mm, dpi: 300)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: model.sessionURL!.appendingPathComponent("Originals").path)) ?? []
    /// The first pixel of a frame's original: where in the pass it came from.
    func origin(_ path: String) -> (Int, Int, Int, Int) {
      let image = try! ImagePipeline.shared.load(URL(fileURLWithPath: path))
      var px = [UInt16](repeating: 0, count: 4)
      let read = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 16, bytesPerRow: 8,
        space: image.colorSpace!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
      read.draw(image, in: CGRect(x: 0, y: -(image.height - 1), width: image.width, height: image.height))
      return (Int(px[0]) / 16, Int(px[1]) / 64, image.width, image.height)
    }
    let three = Array(model.frames.prefix(3))
    var placed = true
    for f in three {
      guard let path = f.scanPath else { placed = false; continue }
      let o = origin(path)
      let x0 = Int(floor((f.rect.x - row.x) / row.width * Double(pw))), y0 = Int(floor((f.rect.y - row.y) / row.height * Double(ph)))
      let expectedWidth = Int(ceil((f.rect.x + f.rect.width - row.x) / row.width * Double(pw))) - x0
      placed = placed && o.0 == x0 && o.1 == y0 && abs(o.2 - expectedWidth) <= 1 && f.captureRect.contains(f.rect) && f.scanDPI == 300
    }
    try check(placed && Set(three.compactMap(\.scanPath)).count == 3 && files.filter { $0.hasPrefix("row-") }.isEmpty
      && files.filter { $0.hasSuffix(".tiff") }.count == 3,
      "the pass is cut into each frame's own original, from where the frame lies in it, and then removed")
    let saved = try JSONDecoder().decode(DeskProject.self, from: Data(contentsOf: model.sessionURL!.appendingPathComponent(model.projectFileName)))
    try check(saved.frames.prefix(3).allSatisfy { $0.scanPath != nil }, "the project records the three originals")
    for _ in 0..<20 where scanner.requests.count < 2 { settle(0.1) }
    try check(scanner.requests.count == 2 && scanner.requests[1].name.hasPrefix("10_300dpi") && model.scanBatch.completed == 3,
      "then the frame below is scanned on its own")
    let lone = model.frames[3].rect
    let loneMM = CGRect(x: lone.x * plate.width, y: lone.y * plate.height, width: lone.width * plate.width, height: lone.height * plate.height)
    let loneCtx = CGContext(data: nil, width: 277, height: 422, bitsPerComponent: 16, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.linearSRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    try scanner.deliver(loneCtx.makeImage()!, mm: loneMM, dpi: 300)
    try check(model.scanBatch.phase == .completed && model.scanBatch.completed == 4 && model.frames.allSatisfy { $0.scanPath != nil },
      "and the batch finishes: four frames in two passes")

    // A pass that cannot be cut up is kept, and says why.
    let failing = RowScanner()
    failing.bits = 16
    let broken = AppModel(libraryURL: root, scanner: failing)
    broken.loadProject(projectURL)
    for _ in 0..<40 where broken.rendering { settle(0.1) }
    broken.dpi = 300
    broken.frames.removeLast()
    broken.scanEnabled()
    let far = CGRect(x: 0, y: 0, width: 10, height: 10)
    try failing.deliver(pass, mm: far, dpi: 300)
    let left = (try? FileManager.default.contentsOfDirectory(atPath: broken.sessionURL!.appendingPathComponent("Originals").path)) ?? []
    try check(broken.scanBatch.phase == .failed && broken.errorText?.contains("整行扫描保留在 Originals") == true
      && left.contains { $0.hasPrefix("row-") },
      "a pass that cannot be cut into its frames stays on disk, and the batch stops saying so")
  }
}
