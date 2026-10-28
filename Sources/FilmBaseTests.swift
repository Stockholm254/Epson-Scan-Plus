import CoreGraphics
import Foundation

enum FilmBaseTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    let portra = FilmProfile.builtins.first { $0.id == "portra160" }!
    let base = RGB(r: 0.80, g: 0.52, b: 0.33)
    func image16(_ w: Int, _ h: Int, _ value: (Int, Int) -> RGB) -> CGImage {
      var samples = [UInt16](repeating: 65535, count: w * h * 4)
      for y in 0..<h {
        for x in 0..<w {
          let v = value(x, y).values
          for c in 0..<3 { samples[(y * w + x) * 4 + c] = UInt16(max(0, min(1, v[c])) * 65535) }
        }
      }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }

    // A linear negative whose highlights, in the middle of the frame, reach 1.7–2.0 D: every
    // channel falls below 0.025 there, which the old 8-bit threshold dropped from the statistics.
    let w = 240, h = 60
    let dense = image16(w, h) { x, _ in
      let exposure = 0.1 + 3.2 * (1 - abs(Double(x) - Double(w / 2)) / Double(w / 2))
      return RGB((0..<3).map { base.values[$0] * pow(10, -portra.slopes.values[$0] * exposure) })
    }
    var linear = Adjustments()
    linear.inputGamma = 1
    let out = pipe.raster(try pipe.preview(dense, settings: linear, profile: portra), maxDimension: w)
    let top = (w / 2 - 12..<w / 2).map { out.pixel($0, h / 2).g * 255 }
    let clipped = (0..<w).filter { out.pixel($0, h / 2).g * 255 > 254.5 }.count
    try check(clipped <= w / 100 + 1 && top.last! > top.first! + 3,
      String(format: "a linear scan's densest highlights keep gradation: %d of %d columns clipped, top %.0f…%.0f", clipped, w, top.first!, top.last!))

    // A strip on the overview: holder, film base, four frames with 20 px gaps between them.
    func overview(gapFill: RGB?) -> CGImage {
      image16(1500, 800) { x, y in
        guard x >= 60, x < 1440, y >= 260, y < 540 else { return RGB(r: 0.02, g: 0.02, b: 0.02) }
        for i in 0..<4 {
          let x0 = 90 + i * 340
          if x >= x0, x < x0 + 320, y >= 293, y < 507 {
            let d = 0.4 + 0.8 * Double((x - x0) % 80) / 80
            return RGB((0..<3).map { base.values[$0] * pow(10, -d * portra.slopes.values[$0]) })
          }
          if let gapFill, x >= x0 + 320, x < x0 + 340, y >= 293, y < 507 { return gapFill }
        }
        return base
      }
    }
    let frames = (0..<4).map { i in
      FilmFrame(name: "0\(i + 1)", rect: NormalRect(x: (90 + Double(i) * 340) / 1500, y: 293.0 / 800,
        width: 320.0 / 1500, height: 214.0 / 800), format: "135")
    }
    guard let measured = pipe.rollBase(overview(gapFill: nil), frames: frames) else {
      throw DeskError.message("FAIL: roll base measured between frames")
    }
    try check((0..<3).allSatisfy { abs(measured.values[$0] / base.values[$0] - 1) < 0.01 },
      String(format: "roll base read from the gaps between frames: %.3f %.3f %.3f", measured.r, measured.g, measured.b))
    var overlapping = frames
    for i in overlapping.indices { overlapping[i].rect.width += 30.0 / 1500 }
    try check(pipe.rollBase(overview(gapFill: nil), frames: overlapping) == nil,
      "no roll base when the frames leave no gap")
    try check(pipe.rollBase(overview(gapFill: RGB(r: 0.02, g: 0.02, b: 0.02)), frames: frames) == nil,
      "no roll base when the gaps are holder, denser than the film")

    // Priority: a picked base, then the roll base, then the frame's own estimate.
    let crop = try pipe.crop(overview(gapFill: nil), rect: frames[0].rect)
    var settings = Adjustments()
    settings.rollBase = measured
    try check(pipe.analyze(crop, settings: settings, profile: portra).base == measured, "analysis uses the roll base")
    settings.base = RGB(r: 0.7, g: 0.5, b: 0.3)
    try check(pipe.analyze(crop, settings: settings, profile: portra).base == settings.base, "a picked base wins over the roll base")

    // Projects: 48-bit previews share the roll base; a reset keeps it; other projects are untouched.
    let roll = folder.appendingPathComponent("roll-base", isDirectory: true)
    try? FileManager.default.removeItem(at: roll)
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    let overviewURL = roll.appendingPathComponent("overview.png")
    try pipe.savePNG(overview(gapFill: nil), to: overviewURL)
    func load(_ backend: String?) throws -> AppModel {
      var p = DeskProject(
        overviewPath: overviewURL.path, overviewDPI: 150, physicalWidthMM: 254, physicalHeightMM: 135.5,
        filmName: portra.name, profile: portra, scanDPI: 2400, frames: frames)
      p.scanBackendID = backend
      let url = roll.appendingPathComponent("\(backend ?? "none").epscan")
      try JSONEncoder().encode(p).write(to: url)
      let model = AppModel(libraryURL: roll)
      model.loadProject(url)
      return model
    }
    let sane = try load("epson2-linear-v1")
    try check(sane.frames.allSatisfy { f in
      guard let b = f.adjustments.rollBase else { return false }
      return (0..<3).allSatisfy { abs(b.values[$0] / base.values[$0] - 1) < 0.02 }
    }, "frames of a 48-bit preview share the roll base when the project opens")
    sane.change { $0 = Adjustments() }
    try check(sane.selected?.adjustments.rollBase != nil, "resetting the adjustments keeps the roll base")
    try check(try load(nil).frames.allSatisfy { $0.adjustments.rollBase == nil },
      "projects without a 48-bit preview keep their per-frame base")
  }
}
