import CoreGraphics
import Foundation
import ImageIO

/// What is exported is what was shown: a negative too large to preview at its own size is
/// converted for the window from its 3000-pixel copy and exported from all its pixels, measured
/// each time on its own; the two agree to within a level, in tone and in colour.
enum PreviewExportTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    let root = folder.appendingPathComponent("preview-export")
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // A colour negative of a scene: sky, a horizon, ground, a red and a blue thing; the orange base.
    let w = 4500, h = 3000
    var samples = [UInt16](repeating: 0, count: w * h * 4)
    let base = [0.86, 0.52, 0.26], gamma = [0.62, 0.6, 0.56]
    for y in 0..<h {
      for x in 0..<w {
        let u = Double(x) / Double(w), v = Double(y) / Double(h)
        var e = v < 0.45 ? [0.35, 0.45, 0.7] : [0.12 + 0.08 * u, 0.16, 0.07]
        if (u - 0.3) * (u - 0.3) + (v - 0.6) * (v - 0.6) < 0.01 { e = [0.6, 0.08, 0.06] }
        if (u - 0.7) * (u - 0.7) + (v - 0.65) * (v - 0.65) < 0.008 { e = [0.05, 0.1, 0.5] }
        let shade = 0.6 + 0.4 * (1 - v)
        for c in 0..<3 {
          let t = base[c] * pow(max(0.02, e[c] * shade) / 0.02, -gamma[c])
          samples[(y * w + x) * 4 + c] = UInt16(min(65535, max(0, pow(t, 1 / 2.2) * 65535)))
        }
        samples[(y * w + x) * 4 + 3] = 65535
      }
    }
    let negative = CGImage(
      width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
      provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
    let profile = FilmProfile.builtins.first { $0.id == "portra400" } ?? FilmProfile.builtins[0]
    var settings = Adjustments()
    settings.inputGamma = 2.2
    // The window's: from the copy it loads, measured on that.
    let shownFrom = pipe.scaled(negative, maxDimension: 3000)
    let analysis = pipe.analyze(shownFrom, settings: settings, profile: profile)
    guard let shown = pipe.render(shownFrom, settings: settings, profile: profile, analysis: analysis, negative: false) else {
      throw DeskError.message("FAIL: the preview renders")
    }
    // The export's: all the pixels, measured again on them, written and read back.
    let url = root.appendingPathComponent("export.tif")
    try pipe.export(negative, settings: settings, profile: profile, url: url, format: .tiff, dpi: 300)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let written = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw DeskError.message("FAIL: the export is read back")
    }
    let exported = pipe.scaled(written, maxDimension: 3000)
    // Both as 8-bit sRGB at the preview's size, compared over a grid.
    func rgba(_ image: CGImage) -> [UInt8] {
      var px = [UInt8](repeating: 0, count: shown.width * shown.height * 4)
      let ctx = CGContext(data: &px, width: shown.width, height: shown.height, bitsPerComponent: 8, bytesPerRow: shown.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.interpolationQuality = .high
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: shown.width, height: shown.height))
      return px
    }
    let a = rgba(shown), b = rgba(exported)
    var mean = [0.0, 0.0, 0.0], shift = [0.0, 0.0, 0.0], n = 0.0
    for y in stride(from: 4, to: shown.height - 4, by: 7) {
      for x in stride(from: 4, to: shown.width - 4, by: 7) {
        let i = (y * shown.width + x) * 4
        for c in 0..<3 {
          let d = Double(b[i + c]) - Double(a[i + c])
          mean[c] += abs(d)
          shift[c] += d
        }
        n += 1
      }
    }
    mean = mean.map { $0 / n }
    shift = shift.map { $0 / n }
    try check(exported.width == shown.width && mean.allSatisfy { $0 < 1.2 } && shift.allSatisfy { abs($0) < 0.6 },
      String(format: "the export of a large negative is the picture the window showed: off by %.2f · %.2f · %.2f levels, shifted %+.2f · %+.2f · %+.2f",
        mean[0], mean[1], mean[2], shift[0], shift[1], shift[2]))
  }
}
