import AppKit
import Foundation
import ImageIO

enum SmokeTests {
  static func run() {
    do {
      let pipe = ImagePipeline.shared
      let folder = URL(
        fileURLWithPath: CommandLine.arguments.drop(while: { $0 != "--test-output" }).dropFirst()
          .first ?? NSTemporaryDirectory() + "FilmDesk-tests")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      func check(_ success: Bool, _ message: String) throws {
        guard success else { throw DeskError.message("FAIL: " + message) }
        print("PASS: " + message)
      }
      let w = 256
      let h = 128
      var pixels = [UInt8](repeating: 255, count: w * h * 4)
      for y in 0..<h {
        for x in 0..<w {
          let i = (y * w + x) * 4
          pixels[i] = UInt8(x)
          pixels[i + 1] = UInt8(y * 2)
          pixels[i + 2] = 32
        }
      }
      let data = Data(pixels)
      let input = CGImage(
        width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)!
      let raster = pipe.raster(input, maxDimension: 256)
      try check(raster.pixel(20, 5).g < raster.pixel(20, 120).g, "top-left raster orientation")
      let cropped = try pipe.crop(input, rect: NormalRect(x: 0, y: 0, width: 0.5, height: 0.25))
      try check(cropped.width == 128 && cropped.height == 32, "normalized crop dimensions")
      let cr = pipe.raster(cropped)
      try check(cr.pixel(10, 10).g < 0.15, "crop selects top, not bottom")
      var positive = Adjustments()
      positive.inputIsNegative = false
      let pass = try pipe.preview(input, settings: positive, profile: FilmProfile.builtins[0])
      let pr = pipe.raster(pass)
      try check(abs(pr.pixel(80, 30).r - raster.pixel(80, 30).r) < 0.02, "positive passthrough")
      positive.rotation = 1
      let rotated = try pipe.preview(input, settings: positive, profile: FilmProfile.builtins[0])
      try check(rotated.width == h && rotated.height == w, "90-degree rotation dimensions")
      var neg = Adjustments()
      neg.autoLevels = false
      neg.autoWhiteBalance = false
      neg.base = .one
      let converted = try pipe.preview(input, settings: neg, profile: FilmProfile.builtins.last!)
      let nr = pipe.raster(converted)
      try check(nr.pixel(70, 50).r > nr.pixel(220, 50).r, "negative density inversion is monotonic")
      let tif = folder.appendingPathComponent("depth-test.tif")
      try pipe.export(
        input, settings: neg, profile: FilmProfile.builtins[0], url: tif, format: .tiff, dpi: 2400)
      let info = pipe.info(tif)
      try check(
        info.bits == 16 && info.width == w && Int(info.dpi) == 2400, "16-bit TIFF + DPI metadata")
      var highSamples = [UInt16]()
      for _ in 0..<4 {
        for x in 0..<1024 {
          let v = UInt16(6500 + x * 50)
          highSamples.append(contentsOf: [v, v, v, 65535])
        }
      }
      let highData = highSamples.withUnsafeBytes { Data($0) }
      let highInput = CGImage(
        width: 1024, height: 4, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 8192,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: highData as CFData)!, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)!
      let highURL = folder.appendingPathComponent("high-precision-test.tif")
      var direct = Adjustments()
      direct.inputIsNegative = false
      try pipe.export(
        highInput, settings: direct, profile: FilmProfile.builtins[0], url: highURL, format: .tiff,
        dpi: 2400)
      let highOut = try pipe.load(highURL)
      let rawData = highOut.dataProvider!.data! as Data
      let stride = highOut.bitsPerPixel / 8
      var values = Set<UInt16>()
      for x in 0..<1024 {
        values.insert(UInt16(rawData[x * stride]) << 8 | UInt16(rawData[x * stride + 1]))
      }
      try check(
        highOut.bitsPerComponent == 16 && values.count > 512,
        "16-bit input retains >512 distinct tones (\(values.count))")
      let jpg = folder.appendingPathComponent("jpeg-test.jpg")
      try pipe.export(
        input, settings: positive, profile: FilmProfile.builtins[0], url: jpg, format: .jpeg,
        dpi: 1200)
      try check(pipe.info(jpg).width == h, "JPEG with rotation")
      var mirrored = Adjustments()
      mirrored.inputIsNegative = false
      mirrored.flipHorizontal = true
      let mirrorRaster = pipe.raster(
        try pipe.preview(input, settings: mirrored, profile: FilmProfile.builtins[0]))
      try check(
        abs(mirrorRaster.pixel(30, 20).r - raster.pixel(w - 1 - 30, 20).r) < 0.02,
        "horizontal mirror preserves coordinates")
      for profile in FilmProfile.builtins { try profile.validate() }
      var invalid = FilmProfile.builtins[0]
      invalid.slopes.r = 0
      var rejected = false
      do { try invalid.validate() } catch { rejected = true }
      try check(rejected, "invalid film profile rejected")
      // Synthetic medium-format strips with known physical aperture sizes.
      for (frameHeight, expected, format) in [
        (56, 3, FilmFormat.auto), (42, 4, .auto), (69, 3, .six7), (84, 2, .auto),
      ] {
        let sw = 600
        let sh = 1000
        let ppm = 4
        var bytes = [UInt8](repeating: 0, count: sw * sh * 4)
        for y in 0..<sh {
          for x in 0..<sw {
            let i = (y * sw + x) * 4
            bytes[i + 3] = 255
            let row = y - 40
            if x >= 80 && x < 80 + 56 * ppm && row >= 0
              && row < (frameHeight * expected + 2 * (expected - 1)) * ppm
            {
              let gap = row % ((frameHeight + 2) * ppm) >= frameHeight * ppm
              bytes[i] = gap ? 210 : UInt8(130 + (x / 9 + y / 17) % 70)
              bytes[i + 1] = gap ? 130 : UInt8(45 + (x / 9 + y / 17) % 65)
              bytes[i + 2] = gap ? 70 : UInt8(20 + (x / 9 + y / 17) % 30)
            }
          }
        }
        let chart = CGImage(
          width: sw, height: sh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: sw * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
          provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
          shouldInterpolate: false, intent: .defaultIntent)!
        let found = FrameDetector.detect(
          chart, physicalMM: CGSize(width: 150, height: 250), format: format)
        try check(
          found.count == expected,
          "120 \(frameHeight) mm / \(format.rawValue) detects \(expected) frames (got \(found.count))"
        )
        var turn = Adjustments()
        turn.inputIsNegative = false
        turn.rotation = 1
        let sideways = try pipe.preview(chart, settings: turn, profile: FilmProfile.builtins[0])
        let horizontal = FrameDetector.detect(
          sideways, physicalMM: CGSize(width: 250, height: 150), format: format)
        try check(
          horizontal.count == expected,
          "horizontal 120 \(frameHeight) mm detects \(expected) frames")
      }
      if let index = CommandLine.arguments.firstIndex(of: "--overview"),
        index + 1 < CommandLine.arguments.count
      {
        let overview = try pipe.load(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        let frames = FrameDetector.detect(
          overview, physicalMM: CGSize(width: 149.86, height: 246.38), format: .auto)
        try check(frames.count == 18, "real V850 overview detects 18 frames (got \(frames.count))")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(frames).write(to: folder.appendingPathComponent("detected-frames.json"))
        for frame in frames {
          try pipe.savePNG(
            try pipe.crop(overview, rect: frame.rect),
            to: folder.appendingPathComponent("detected-" + frame.name + ".png"))
        }
        let first = try pipe.crop(overview, rect: frames[0].rect)
        try pipe.savePNG(
          try pipe.preview(first, settings: Adjustments(), profile: FilmProfile.builtins[0]),
          to: folder.appendingPathComponent("first-positive.png"))
        let project = DeskProject(
          overviewPath: CommandLine.arguments[index + 1], overviewDPI: 150, physicalWidthMM: 149.86,
          physicalHeightMM: 246.38, filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0],
          scanDPI: 2400, frames: frames)
        let encoded = try enc.encode(project)
        try encoded.write(to: folder.appendingPathComponent("Session.filmdesk"))
        let decoded = try JSONDecoder().decode(DeskProject.self, from: encoded)
        try check(
          decoded.frames.count == 18 && decoded.frames[0].rect == frames[0].rect,
          "project round-trip")
      }
      try RegressionTests.run(folder: folder)
      print("ALL TESTS PASSED")
      exit(0)
    } catch {
      fputs("\(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
}
