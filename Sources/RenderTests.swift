import AppKit
import Combine
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The single frame's render while a slider moves: pictures as it moves, the analysis it keeps
/// over the print's own controls and redoes for the rest; and the statistics' sums, written for
/// speed, against the plain ones.
enum RenderTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let pipe = ImagePipeline.shared

    // How far highlights run, against the same sums channel by channel, an array for each sample.
    var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
    func next() -> Double {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Double(seed >> 11) / Double(UInt64(1) << 53)
    }
    let n = 4000
    let e = (0..<3).map { _ in (0..<n).map { _ in next() * 3 - 0.5 } }
    let weight = (0..<n).map { _ in next() }
    let gain = RGB(r: 1.1, g: 0.95, b: 1.3), balance = RGB(r: -0.1, g: 0.05, b: 0.2)
    func plainReach(_ w: [Double]?, _ saturation: Double) -> Double {
      let peaks = (0..<n).map { (i: Int) -> Double in
        let x = (0..<3).map { (c: Int) -> Double in e[c][i] * gain.values[c] + balance.values[c] * (w?[i] ?? 1) }
        let l = 0.2126 * x[0] + 0.7152 * x[1] + 0.0722 * x[2]
        return x.map { l + saturation * ($0 - l) }.max()!
      }
      return pipe.quantile(peaks, 0.999)
    }
    try check([nil, weight].allSatisfy { w in
      [1.0, 1.6].allSatisfy { pipe.reach(e, gain: gain, balance: balance, weight: w, saturation: $0) == plainReach(w, $0) }
    }, "how far highlights run comes out bit for bit as the plain sums give it, weighted or not")

    // An export rendered straight into a bitmap without alpha: the same values, the same way up,
    // as rendered with alpha and then drawn without it.
    func drawn(_ image: CGImage) -> [UInt16] {
      let w = image.width, h = image.height
      var px = [UInt16](repeating: 0, count: w * h * 4)
      px.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
          space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      }
      return px
    }
    let gradient = CIFilter(name: "CILinearGradient", parameters: [
      "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 37, y: 23),
      "inputColor0": CIColor(red: 0.9, green: 0.2, blue: 0.1), "inputColor1": CIColor(red: 0.1, green: 0.5, blue: 0.95),
    ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 41, height: 29))
    let corner = CIImage(color: CIColor(red: 1, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 25, width: 6, height: 4))
    let picture = corner.composited(over: gradient)
    try check([true, false].allSatisfy { sixteen in
      guard let straight = pipe.opaqueImage(picture, sixteenBit: sixteen, colorSpace: pipe.outputSpace),
        let withAlpha = pipe.context.createCGImage(picture, from: picture.extent, format: sixteen ? .RGBA16 : .RGBA8, colorSpace: pipe.outputSpace)
      else { return false }
      let dropped = pipe.opaque(withAlpha)
      return straight.alphaInfo == .noneSkipLast && drawn(straight) == drawn(dropped)
    }, "an export is rendered without alpha, 8 and 16 bits, to the values and the way up it had drawn without it")

    // A short scene's automatic ends: at least four stops apart, about the middle they had.
    func flatDensities(_ low: Double, _ high: Double) -> [[Double]] {
      (0..<3).map { c in (0..<2000).map { i in low + (high - low) * Double(i) / 1999 + 0.02 * Double(c) } }
    }
    let film = FilmProfile.builtins[0]
    let foggy = flatDensities(0.55, 0.85), sunny = flatDensities(0.15, 1.7)
    let foggyAsWas = pipe.analyze(base: .one, density: foggy, settings: Adjustments(), profile: film, shortestEnds: 0)
    let foggyNow = pipe.analyze(base: .one, density: foggy, settings: Adjustments(), profile: film)
    let sunnyAsWas = pipe.analyze(base: .one, density: sunny, settings: Adjustments(), profile: film, shortestEnds: 0)
    let sunnyNow = pipe.analyze(base: .one, density: sunny, settings: Adjustments(), profile: film)
    try check(foggyAsWas.high - foggyAsWas.low < ImagePipeline.shortestEnds
      && abs((foggyNow.high - foggyNow.low) - ImagePipeline.shortestEnds) < 1e-9
      && abs((foggyNow.high + foggyNow.low) - (foggyAsWas.high + foggyAsWas.low)) < 1e-9,
      String(format: "a foggy frame's ends open from %.2f to %.2f about the same middle, not pulled out to black and white",
        foggyAsWas.high - foggyAsWas.low, foggyNow.high - foggyNow.low))
    try check(sunnyNow.low == sunnyAsWas.low && sunnyNow.high == sunnyAsWas.high && sunnyNow.high - sunnyNow.low > ImagePipeline.shortestEnds,
      "and a sunny frame's ends stay as they were")

    // One large frame on a preview, so a render takes a while, as a real one does.
    let roll = folder.appendingPathComponent("render-throttle")
    try? FileManager.default.removeItem(at: roll)
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    let ow = 2400, oh = 1700
    let draw = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
      space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw.setFillColor(red: 0.95, green: 0.62, blue: 0.38, alpha: 1)
    draw.fill(CGRect(x: 0, y: 0, width: ow, height: oh))
    for i in 0..<24 {
      let t = Double(i) / 23
      draw.setFillColor(red: 0.85 - 0.6 * t, green: 0.5 - 0.38 * t, blue: 0.3 - 0.2 * t + 0.05 * sin(t * 9), alpha: 1)
      draw.fill(CGRect(x: 100 + i * 92, y: 100, width: 92, height: oh - 200))
    }
    let overviewURL = roll.appendingPathComponent("overview.png")
    try pipe.savePNG(draw.makeImage()!, to: overviewURL)
    let frame = FilmFrame(name: "01", rect: NormalRect(x: 0.03, y: 0.04, width: 0.94, height: 0.92), format: "135")
    let project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 600, physicalWidthMM: 101, physicalHeightMM: 72,
      filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: [frame])
    let projectURL = roll.appendingPathComponent("Session.epscan")
    try JSONEncoder().encode(project).write(to: projectURL)

    let model = AppModel(libraryURL: roll)
    model.readOnly = true
    model.loadProject(projectURL)
    for _ in 0..<60 where model.rendering { settle(0.1) }
    model.select(model.frames[0].id)
    model.showSingle(true)
    for _ in 0..<80 where model.rendering || model.displayed == nil { settle(0.1) }
    try check(model.displayed != nil && !model.rendering, "the frame renders alone")

    // A slider moved every 30 ms: put off until it stopped, as before, no picture came while it moved.
    var shown = 0
    model.pictureChanged = { shown += 1 }
    var finished = 0
    let finishing = model.$rendering.dropFirst().sink { if !$0 { finished += 1 } }
    for i in 1...16 {
      model.change("曝光") { $0.exposure = Double(i) * 0.04 }
      settle(0.03)
    }
    let whileMoving = shown, finishedMoving = finished
    let stopped = Date()
    for _ in 0..<80 where model.rendering { settle(0.02) }
    let caughtUp = Date().timeIntervalSince(stopped)
    settle(0.2)
    finishing.cancel()
    try check(whileMoving >= 2 && !model.rendering,
      "a slider dragged over the frame shows pictures as it moves (\(whileMoving) in half a second), and the last when it stops")
    // Beside the picture (histograms, film strip, the render's end) the window catches up twice a
    // second while it moves, and once it stops.
    try check(finishedMoving <= 1 && caughtUp < 0.6 && model.thumbnails[model.frames[0].id] != nil,
      "while it moves the window beside the picture is updated at most twice a second (\(finishedMoving) ends in half a second), and \(Int(caughtUp * 1000)) ms after it stops")
    // Each goes to the canvas alone: the window is updated for the slider's step, not again for its picture.
    var updates = 0
    let watching = model.objectWillChange.sink { updates += 1 }
    let last = model.displayed!
    let counted = shown
    model.showOnCanvas(last.cropping(to: CGRect(x: 0, y: 0, width: 8, height: 8))!)
    let quiet = (shown - counted, updates)
    model.pictureChanged = nil
    model.showOnCanvas(last)
    watching.cancel()
    try check(quiet == (1, 0) && updates == 1 && model.displayed === last,
      "a new picture of the frame is drawn by the canvas without updating the window (\(quiet)); with no canvas, the window is updated")

    // The analysis kept over the print's own controls is the one the frame's settings give: in ③,
    // where they are graded (② shows the frame de-masked only, its grading as new).
    model.convertStep = .grade
    for _ in 0..<80 where model.rendering { settle(0.05) }
    func same(_ a: ToneAnalysis?, _ b: ToneAnalysis) -> Bool {
      guard let a else { return false }
      return a.base == b.base && a.balance == b.balance && a.low == b.low && a.high == b.high && a.gain == b.gain
        && a.fade == b.fade && a.fadeAtGrey == b.fadeAtGrey && a.reach == b.reach
    }
    func fresh() throws -> ToneAnalysis {
      let f = model.selected!
      return pipe.analyze(try model.source(for: f), settings: f.adjustments, profile: model.profile)
    }
    model.change("对比度") { $0.contrast = 1.3; $0.warmth = 0.2; $0.black = 0.05; $0.rotation = 1 }
    for _ in 0..<80 where model.rendering { settle(0.05) }
    try check(same(model.toneAnalysis, try fresh()),
      "exposure, contrast, colour, levels and turns keep the analysis, which is the one the frame's settings give")
    let before = model.toneAnalysis
    model.change("饱和度") { $0.autoWhiteBalance = false; $0.saturation = 1.6 }
    for _ in 0..<80 where model.rendering { settle(0.05) }
    try check(same(model.toneAnalysis, try fresh()) && !same(before, model.toneAnalysis!),
      "what the analysis reads (auto white balance, saturation) analyses again")

    // Three frames on a holder's preview: the film strip and the light table keep what is the same.
    let strip = folder.appendingPathComponent("render-strip")
    try? FileManager.default.removeItem(at: strip)
    try FileManager.default.createDirectory(at: strip, withIntermediateDirectories: true)
    let sw = 1500, sh = 400
    let sheet = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
      space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sheet.setFillColor(red: 0.95, green: 0.62, blue: 0.38, alpha: 1)
    sheet.fill(CGRect(x: 0, y: 0, width: sw, height: sh))
    for i in 0..<3 {
      sheet.setFillColor(red: 0.6 - 0.15 * Double(i), green: 0.35, blue: 0.2 + 0.05 * Double(i), alpha: 1)
      sheet.fill(CGRect(x: 60 + i * 480, y: 60, width: 420, height: 280))
    }
    let stripOverview = strip.appendingPathComponent("overview.png")
    try pipe.savePNG(sheet.makeImage()!, to: stripOverview)
    let three = (0..<3).map { i in
      FilmFrame(name: "0\(i + 1)", rect: NormalRect(x: (60 + Double(i) * 480) / 1500, y: 0.15, width: 0.28, height: 0.7), format: "135")
    }
    let stripProject = strip.appendingPathComponent("Session.epscan")
    try JSONEncoder().encode(DeskProject(
      overviewPath: stripOverview.path, overviewDPI: 300, physicalWidthMM: 127, physicalHeightMM: 34,
      filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: three)).write(to: stripProject)
    let table = AppModel(libraryURL: strip)
    table.readOnly = true
    // Graded, in ③: a change of exposure is ③'s (② shows the frames de-masked only).
    table.convertStep = .grade
    table.loadProject(stripProject)
    for _ in 0..<100 where table.rendering || table.thumbnails.count < 3 { settle(0.1) }
    settle(0.5)
    let ids = table.frames.map(\.id)
    let first = ids.map { table.thumbnails[$0] }
    table.select(ids[1])
    table.change("曝光") { $0.exposure = 0.4 }
    table.updateThumbnails()
    for _ in 0..<60 where table.thumbnails[ids[1]] === first[1] { settle(0.05) }
    let second = ids.map { table.thumbnails[$0] }
    try check(first.allSatisfy { $0 != nil } && second[0] === first[0] && second[2] === first[2] && second[1] !== first[1],
      "after one frame changes, only its positive in the film strip is converted again")
    try check([first[0]!, second[1]!].allSatisfy { max($0.width, $0.height) <= AppModel.thumbnailDimension },
      "and the film strip keeps them no larger than \(AppModel.thumbnailDimension) pixels")
    for _ in 0..<80 where table.rendering { settle(0.05) }
    settle(0.3)
    let printed = table.displayed
    table.select(ids[2])
    table.refresh()
    try check(printed != nil && table.displayed === printed && !table.rendering,
      "another frame selected on the light table shows the print as it is, not printed again")
    table.change("曝光") { $0.exposure = -0.3 }
    for _ in 0..<80 where table.rendering { settle(0.05) }
    try check(table.displayed !== printed, "and a frame changed prints it again")

    // A full-resolution contact sheet's tiles sized from their files' headers, as reading them gives.
    let turned = strip.appendingPathComponent("turned.tif")
    let tall = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
      space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    tall.setFillColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1)
    tall.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
    let destination = CGImageDestinationCreateWithURL(turned as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, tall.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
    CGImageDestinationFinalize(destination)
    var own = FilmFrame(name: "09", rect: NormalRect(x: 0.1, y: 0.05, width: 0.7, height: 0.8), format: "135")
    own.sourcePath = turned.path
    let sized = (table.frames + [own]).map { f -> Bool in
      guard let known = table.fullSourceSize(for: f), let read = try? table.source(for: f, full: true) else { return false }
      return known == CGSize(width: read.width, height: read.height)
    }
    try check(sized.allSatisfy { $0 }, "a full-resolution sheet sizes each frame from its file's header, turned as the file says, as reading it gives")

    // The single frame's shadowed plate, made once and stretched to the picture, against drawing
    // it each time: a picture of the canvas's size, one zoomed far past it, and one too small to
    // stretch the plate to.
    func painted(_ rect: CGRect, _ draw: (CGRect) -> Void) -> [UInt8] {
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 640 * 4, bitsPerPixel: 32)!
      rep.size = CGSize(width: 320, height: 200)
      NSGraphicsContext.saveGraphicsState()
      let ctx = NSGraphicsContext(bitmapImageRep: rep)!
      NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
      ctx.cgContext.translateBy(x: 0, y: 200)
      ctx.cgContext.scaleBy(x: 1, y: -1)
      NSColor.gray.setFill()
      CGRect(x: 0, y: 0, width: 320, height: 200).fill()
      draw(rect)
      NSGraphicsContext.restoreGraphicsState()
      return Array(UnsafeBufferPointer(start: rep.bitmapData!, count: 640 * 400 * 4))
    }
    let canvas = FilmCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    var worst = 0
    for rect in [CGRect(x: 60, y: 40, width: 200, height: 120), CGRect(x: 40, y: 30, width: 9000, height: 6000),
      CGRect(x: -8800, y: -5900, width: 9000, height: 6000), CGRect(x: 130, y: 80, width: 60, height: 40)]
    {
      let each = painted(rect) { rect in
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: 5)
        shadow.set()
        NSColor.black.setFill()
        rect.insetBy(dx: -1, dy: -1).fill()
        NSGraphicsContext.restoreGraphicsState()
      }
      let kept = painted(rect) { canvas.drawShadowPlate(around: $0) }
      worst = max(worst, zip(each, kept).map { abs(Int($0) - Int($1)) }.max() ?? 255)
    }
    let made = canvas.shadowPlate?.parts.first
    _ = painted(CGRect(x: 0, y: 0, width: 4000, height: 3000)) { canvas.drawShadowPlate(around: $0) }
    try check(worst <= 1 && made != nil && canvas.shadowPlate?.parts.first === made && (made?.size.width ?? 999) < 100,
      "the single frame's plate and shadow, made once and stretched to any size, look as drawn each time (within \(worst) of 255)")
  }
}
