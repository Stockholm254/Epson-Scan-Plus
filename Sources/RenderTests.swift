import Combine
import CoreGraphics
import Foundation

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
    let watching = model.$displayed.dropFirst().sink { _ in shown += 1 }
    for i in 1...16 {
      model.change("曝光") { $0.exposure = Double(i) * 0.04 }
      settle(0.03)
    }
    let whileMoving = shown
    for _ in 0..<80 where model.rendering { settle(0.05) }
    settle(0.2)
    watching.cancel()
    try check(whileMoving >= 2 && !model.rendering,
      "a slider dragged over the frame shows pictures as it moves (\(whileMoving) in half a second), and the last when it stops")

    // The analysis kept over the print's own controls is the one the frame's settings give.
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
  }
}
