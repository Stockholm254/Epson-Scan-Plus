import AppKit
import Foundation

/// One roll whatever took it: pictures a file each (as a camera takes them) measured together
/// when asked, and a film base picked once and shared with the roll.
enum RollGroupTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let pipe = ImagePipeline.shared

    // Which frames go together.
    func frame(_ path: String?, gamma: Double = 1, bits: Int = 16) -> FilmFrame {
      var f = FilmFrame(name: "x", rect: .full, format: path == nil ? "135" : "导入")
      f.sourcePath = path
      f.sourceBits = path == nil ? nil : bits
      f.adjustments.inputGamma = gamma
      return f
    }
    let mixed = [frame(nil), frame(nil), frame("/strip.tif"), frame("/strip.tif"),
      frame("/a.tif"), frame("/b.tif"), frame("/c.tif"), frame("/d.jpg", gamma: 2.2, bits: 8)]
    let apart = AppModel.rollGroups(mixed, poolPictures: false).map(\.count)
    let pooled = AppModel.rollGroups(mixed, poolPictures: true).map(\.count)
    try check(apart == [2, 2, 1, 1, 1, 1] && pooled == [2, 2, 3, 1],
      "scanned frames go together, a strip file on its own; pictures a file each go together only when asked, and only those read alike")

    // A roll of three pictures, a file each, on a film whose slopes are not the data sheet's.
    let base = RGB(r: 0.80, g: 0.52, b: 0.33)
    let truth = RGB(r: 0.51, g: 0.55, b: 0.65)
    func picture(_ low: Double, _ high: Double) -> CGImage {
      let w = 200, h = 140
      var samples = [UInt16](repeating: 65535, count: w * h * 4)
      for y in 0..<h {
        for x in 0..<w {
          let l = low + (high - low) * (Double(x) / 199 * 0.8 + Double(y % 7) / 6 * 0.2)
          for c in 0..<3 { samples[(y * w + x) * 4 + c] = UInt16(max(0, min(1, base.values[c] * pow(10, -truth.values[c] * l))) * 65535) }
        }
      }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    let lib = folder.appendingPathComponent("roll-groups", isDirectory: true)
    try? FileManager.default.removeItem(at: lib)
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    var urls = [URL]()
    for (i, range) in [(0.2, 0.9), (0.6, 1.5), (1.1, 2.0)].enumerated() {
      let url = lib.appendingPathComponent("capture-\(i + 1).png")
      try pipe.savePNG(picture(range.0, range.1), to: url)
      urls.append(url)
    }
    let model = AppModel(libraryURL: lib)
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.undoManager = undo
    model.importURLs(urls)
    // Decoded camera files are linear.
    for f in model.frames {
      model.select(f.id)
      model.change("输入设置") { $0.inputGamma = 1 }
    }
    func estimate() {
      var done = false
      model.updateRollSlopes { done = true }
      for _ in 0..<200 where !done { settle(0.05) }
      for _ in 0..<40 where model.rendering { settle(0.05) }
    }
    estimate()
    try check(model.frames.count == 3 && model.hasSinglePictures && !model.poolPictures
      && model.frames.allSatisfy { $0.adjustments.rollSlopes == nil },
      "pictures imported a file each are each apart until asked: no roll estimate, as before")
    model.setPoolPictures(true)
    estimate()
    let slopes = model.frames.compactMap(\.adjustments.rollSlopes)
    try check(slopes.count == 3 && slopes.allSatisfy { abs($0.r / truth.r - 1) < 0.04 && abs($0.b / truth.b - 1) < 0.04 },
      String(format: "measured together they give the roll estimate, as the scanned frames do: R %.3f · B %.3f (true %.2f · %.2f)",
        slopes.first?.r ?? 0, slopes.first?.b ?? 0, truth.r, truth.b))

    // The base picked once, on the leader, for the whole roll.
    model.select(model.frames[0].id)
    model.setFilmBase(base)
    model.shareFilmBase()
    estimate()
    try check(model.frames.allSatisfy { $0.adjustments.rollBase == base && $0.adjustments.rollBasePicked == true },
      "a base picked on one frame is shared with every frame of its roll")
    model.select(model.frames[2].id)
    model.change("曝光") { $0.exposure = 0.3 }
    try check(model.frames[2].adjustments.rollBase == base && model.frames[2].adjustments.rollBasePicked == true,
      "editing a frame keeps the shared base")
    let reopened = AppModel(libraryURL: lib)
    reopened.loadProject(model.projectURL!)
    for _ in 0..<40 where reopened.rendering { settle(0.05) }
    // The first picture is also the overview, whose gaps (there are none) would otherwise clear it.
    try check(reopened.poolPictures && reopened.frames.allSatisfy { $0.adjustments.rollBase == base && $0.adjustments.rollBasePicked == true },
      "the shared base and measuring together are kept in the project, and the overview's gaps do not clear the base")
    undo.undo()
    undo.undo()
    try check(model.frames.allSatisfy { $0.adjustments.rollBasePicked != true && $0.adjustments.rollBase == nil },
      "sharing the base is undone like any edit")
    undo.redo()
    undo.redo()
    try check(model.frames.allSatisfy { $0.adjustments.rollBase == base && $0.adjustments.rollBasePicked == true },
      "and redone")
    model.unshareFilmBase()
    try check(model.frames.allSatisfy { $0.adjustments.rollBasePicked != true && $0.adjustments.rollBase == nil },
      "taking the shared base back leaves each frame to the base measured or estimated for it")
  }
}
