import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Dust on synthetic negatives with known specks: each found where it is and nowhere in the grain;
/// a speck in one channel only, and the picture's own small bright thing (green above red, as the
/// film's layers go) in busy film, left alone while neutral dust beside it is found; filled back to
/// the grain with nothing made denser and nothing outside the spots touched; found at one size and
/// filled at another; kept in the project; filled as the frame is read; and back after undo.
enum DustTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let w = 600, h = 400
    var seed: UInt64 = 0x5EED
    func random() -> Double {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Double(seed >> 11) / Double(1 << 53)
    }
    func gauss() -> Double { (0..<4).map { _ in random() }.reduce(0, +) - 2 }
    // The film: densities above the base by channel, a gentle gradient, grain; busy grain on the
    // right third. Each speck adds density at a point, `excess` per channel, `radius` across.
    struct Speck { var x: Int, y: Int, radius: Double, excess: [Double] }
    func negative(_ specks: [Speck], busyFrom: Int = w, edgeFrom: Int = w) -> (image: CGImage, density: [[Double]]) {
      var d = [[Double]](repeating: [Double](repeating: 0, count: w * h), count: 3)
      let base = [0.35, 0.55, 0.75]
      for y in 0..<h {
        for x in 0..<w {
          let i = y * w + x, busy = x >= busyFrom
          let grain = gauss() * (busy ? 0.09 : 0.025)
          for c in 0..<3 { d[c][i] = base[c] + 0.2 * Double(x) / Double(w) + grain * (1 + 0.1 * Double(c)) + (x >= edgeFrom ? 0.8 : 0) }
        }
      }
      for s in specks {
        let r = Int(s.radius.rounded(.up)) + 1
        for y in max(0, s.y - r)...min(h - 1, s.y + r) {
          for x in max(0, s.x - r)...min(w - 1, s.x + r) {
            let dist = hypot(Double(x - s.x), Double(y - s.y))
            let cover = min(1, max(0, s.radius + 0.5 - dist))
            for c in 0..<3 { d[c][y * w + x] += s.excess[c] * cover }
          }
        }
      }
      var px = [UInt16](repeating: 0, count: w * h * 3)
      for i in 0..<(w * h) { for c in 0..<3 { px[i * 3 + c] = UInt16(max(1, min(65535, (65535 * pow(10, -d[c][i])).rounded()))) } }
      let image = CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6,
        space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
      return (image, d)
    }
    func densities(_ image: CGImage) -> [[Double]] {
      let px = DustPixels.rgba16(image, x: 0, y: 0, width: image.width, height: image.height)!
      return (0..<3).map { c in (0..<(image.width * image.height)).map { Double(DustPixels.density(px[$0 * 4 + c])) } }
    }
    func centre(_ m: DustMask) -> (Double, Double) {
      var sx = 0.0, sy = 0.0, n = 0.0
      for y in 0..<m.height { for x in 0..<m.width where m.cells[y * m.width + x] { sx += Double(m.x + x); sy += Double(m.y + y); n += 1 } }
      return (sx / n, sy / n)
    }
    func finds(_ masks: [DustMask], _ s: Speck) -> Bool {
      masks.contains { m in let c = centre(m); return abs(c.0 - Double(s.x)) < 3 && abs(c.1 - Double(s.y)) < 3 }
    }

    // Dust in plain grain: specks of a few sizes, neutral; and one dense in blue only.
    let dust = [
      Speck(x: 60, y: 60, radius: 2, excess: [0.9, 0.9, 0.9]), Speck(x: 150, y: 300, radius: 3, excess: [1.1, 1.1, 1.1]),
      Speck(x: 260, y: 120, radius: 2.5, excess: [0.7, 0.72, 0.7]), Speck(x: 330, y: 330, radius: 1.5, excess: [1.2, 1.2, 1.2]),
    ]
    let blueOnly = Speck(x: 100, y: 200, radius: 3, excess: [0, 0, 1.2])
    let (plain, _) = negative(dust + [blueOnly])
    let found = DustFinder.find(plain)
    try check(dust.allSatisfy { finds(found, $0) } && found.count == dust.count,
      "dust found where it lies on the film and nowhere in the grain (\(found.count) of \(dust.count))")
    try check(!finds(found, blueOnly), "a speck dense in one channel only is not dust")

    // Busy film: the picture's small bright thing goes with the film's layers (green over red 1.28)
    // and stays; neutral dust beside it is found.
    let picture = Speck(x: 470, y: 120, radius: 3, excess: [0.55, 0.7, 0.8])
    let inBusy = Speck(x: 500, y: 280, radius: 3, excess: [1.2, 1.2, 1.2])
    let (busy, _) = negative([picture, inBusy], busyFrom: 400)
    let busyFound = DustFinder.find(busy)
    try check(finds(busyFound, inBusy) && !finds(busyFound, picture),
      "in busy film, dust is found and the picture's own bright speck (green over red as the film's layers) is left")

    // Filled: back to the grain at every speck; nothing denser; nothing outside the spots changed.
    let spots = found.map { $0.spot(in: .full, width: w, height: h) }
    let filled = DustFill.apply(spots, to: plain, rect: .full)
    let after = densities(filled), before = densities(plain)
    let back = dust.allSatisfy { s in
      let i = s.y * w + s.x
      return (0..<3).allSatisfy { c in abs(after[c][i] - (0.35 + 0.2 * Double(c) + 0.2 * Double(s.x) / Double(w))) < 0.15 }
    }
    try check(back, "each speck filled back to the film around it")
    var denser = 0.0, outside = 0
    let covered = Set(spots.flatMap { s -> [Int] in
      guard let m = s.pixels(in: .full, width: w, height: h) else { return [] }
      return (0..<(m.width * m.height)).filter { m.cells[$0] }.map { (m.y + $0 / m.width) * w + m.x + $0 % m.width }
    })
    for i in 0..<(w * h) {
      for c in 0..<3 {
        denser = max(denser, after[c][i] - before[c][i])
        if !covered.contains(i), abs(after[c][i] - before[c][i]) > 1e-6 { outside += 1 }
      }
    }
    try check(denser < 1e-6 && outside == 0, "the fill only takes density away, and only inside the spots")
    // The grain goes on through a filled speck: not a smooth patch.
    let big = dust[1]
    var inner = [Double]()
    for y in (big.y - 2)...(big.y + 2) { for x in (big.x - 2)...(big.x + 2) { inner.append(after[1][y * w + x]) } }
    let mean = inner.reduce(0, +) / Double(inner.count)
    let spread = sqrt(inner.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(inner.count))
    try check(spread > 0.008, "a filled speck keeps the film's grain (spread \(String(format: "%.3f", spread)) D)")

    // Found at full size, filled at half: the spots follow the picture.
    let half = ImagePipeline.shared.scaled(plain, maxDimension: w / 2)
    let halfFilled = densities(DustFill.apply(spots, to: half, rect: .full)), halfBefore = densities(half)
    let followed = dust.allSatisfy { s in
      let i = (s.y / 2) * half.width + s.x / 2
      return halfBefore[1][i] - halfFilled[1][i] > 0.2
    }
    try check(followed, "spots found at one size fill the frame at another")

    // Kept in the project: a spot coded and read back is the same, cells and all.
    let coded = try JSONDecoder().decode(DustState.self, from: JSONEncoder().encode(DustState(on: true, spots: spots, sensitivity: .medium)))
    try check(coded.spots == spots && coded.spots.first?.mask == spots.first?.mask, "spots kept in the project as found")

    // Read through the app: a frame of its own file comes out filled, and undo brings its dust back.
    let roll = folder.appendingPathComponent("dust-roll", isDirectory: true)
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    let file = roll.appendingPathComponent("EPS00001.tif")
    let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, plain, nil)
    guard CGImageDestinationFinalize(destination) else { throw DeskError.message("FAIL: test file written") }
    let model = AppModel(libraryURL: roll)
    model.readOnly = true
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.undoManager = undo
    var frame = FilmFrame(name: "01", rect: .full, format: "135")
    frame.sourcePath = file.path
    frame.sourceBits = 16
    frame.adjustments.inputGamma = 1
    frame.dust = DustState(on: true, spots: spots, sensitivity: .medium)
    model.frames = [frame]
    model.selectedID = frame.id
    let read = densities(try model.source(for: frame, maxDimension: w))
    let speck = dust[0].y * w + dust[0].x
    try check(before[1][speck] - read[1][speck] > 0.5, "the frame is read with its dust filled")
    model.clearDust()
    try check(model.frames[0].dust == nil, "dust cleared")
    undo.undo()
    try check(model.frames[0].dust?.spots == spots, "undo brings the frame's dust back")
    var off = model.frames[0]
    off.dust?.on = false
    try check(abs(densities(try model.source(for: off, maxDimension: w))[1][speck] - before[1][speck]) < 1e-3,
      "with its dust left in, the frame is read as it is")
    // A copy shot's dust is looked for before its unmix, which would make a speck fainter in green;
    // the frame itself is still read unmixed.
    var copy = model.frames[0]
    copy.crosstalk = .measured
    copy.dust = nil
    let clean = 10 * w + 10
    let looked = densities(try model.dustFreeSource(for: copy, full: true))
    let unmixed = densities(try model.source(for: copy, full: true))
    try check(abs(looked[1][speck] - before[1][speck]) < 1e-3 && abs(looked[1][clean] - before[1][clean]) < 1e-3
      && abs(unmixed[1][clean] - before[1][clean]) > 0.05,
      "a copy's dust is looked for before its unmix, and the frame is still read unmixed")

    // A click with the dust tool where nothing stands out: a round spot on plain film; none across
    // two films (a pale wall against a dark post), which its fill would carry one into the other.
    let (edged, _) = negative([], edgeFrom: w / 2)
    let edgeFile = roll.appendingPathComponent("EPS00002.tif")
    let second = CGImageDestinationCreateWithURL(edgeFile as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(second, edged, nil)
    guard CGImageDestinationFinalize(second) else { throw DeskError.message("FAIL: test file written") }
    var edgeFrame = FilmFrame(name: "02", rect: .full, format: "135")
    edgeFrame.sourcePath = edgeFile.path
    edgeFrame.sourceBits = 16
    edgeFrame.adjustments.inputGamma = 1
    model.frames = [edgeFrame]
    model.selectedID = edgeFrame.id
    model.markDust(at: CGPoint(x: 0.5, y: 0.5))
    let acrossEdge = model.frames[0].dust?.spots.count ?? 0
    model.markDust(at: CGPoint(x: 0.25, y: 0.5))
    try check(acrossEdge == 0 && model.frames[0].dust?.spots.count == 1,
      "a click marks a spot on plain film, and none across two films")

    // A click on a wide speck (dust on the base side, out of focus), wider than the opening: all of
    // it filled, not only its thin parts.
    let wide = Speck(x: 150, y: 200, radius: 9, excess: [0.35, 0.35, 0.35])
    let (wideImage, _) = negative([wide])
    let wideFile = roll.appendingPathComponent("EPS00003.tif")
    let third = CGImageDestinationCreateWithURL(wideFile as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(third, wideImage, nil)
    guard CGImageDestinationFinalize(third) else { throw DeskError.message("FAIL: test file written") }
    var wideFrame = FilmFrame(name: "03", rect: .full, format: "135")
    wideFrame.sourcePath = wideFile.path
    wideFrame.sourceBits = 16
    wideFrame.adjustments.inputGamma = 1
    model.frames = [wideFrame]
    model.selectedID = wideFrame.id
    model.markDust(at: CGPoint(x: Double(wide.x) / Double(w), y: Double(wide.y) / Double(h)))
    let wideRead = densities(try model.source(for: model.frames[0], maxDimension: w))
    let wideBack = [(0, 0), (6, 0), (0, -6), (-5, 5)].allSatisfy { dx, dy in
      let x = wide.x + dx, i = (wide.y + dy) * w + x
      return abs(wideRead[1][i] - (0.55 + 0.2 * Double(x) / Double(w))) < 0.12
    }
    try check(wideBack, "a click takes all of a wide speck, not only its thin parts")
  }
}
