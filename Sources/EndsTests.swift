import CoreGraphics
import Foundation

/// The automatic ends from 0.23.15 (`Adjustments.ends`): the white by luminance, so a saturated
/// blue past the lightest grey no longer sets it; the black at the film base, so a frame whose
/// darkest took light prints it above black; a short scene its black at the base; new frames
/// so, a project from before keeping the old way on frames set by hand.
enum EndsTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    // Which frames find their ends which way.
    var touched = Adjustments()
    touched.exposure = 0.4
    var whites = Adjustments()
    whites.whites = -0.2
    var manual = Adjustments()
    manual.autoLevels = false
    var levelled = Adjustments()
    levelled.levels = Levels(rgb: Levels.Channel(white: 0.7))
    var curved = Adjustments()
    curved.curves = ToneCurves(rgb: ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]))
    var straight = Adjustments()
    straight.curves = ToneCurves()
    let fresh = FilmFrame(name: "01", rect: .full, format: "翻拍")
    var reset = touched
    reset.ends = 1
    reset = AppModel.reset(.levels, of: reset, copyShot: false)
    try check(fresh.adjustments.ends == 2 && Adjustments().ends == nil && AppModel.endsForSaved(Adjustments()) == 2
      && AppModel.endsForSaved(touched) == 1 && AppModel.endsForSaved(whites) == 1 && AppModel.endsForSaved(manual) == 1 && reset.ends == 2
      && AppModel.endsForSaved(levelled) == 1 && AppModel.endsForSaved(curved) == 1 && AppModel.endsForSaved(straight) == 2,
      "a new frame finds its ends the new way; one saved before keeps the old way where its exposure, whites, blacks, levels or curves were set by hand, the new where it was left; 色阶 reset gives the new way")
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Adjustments.newFrame)) as! [String: Any]
    old["ends"] = nil
    let decoded = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: old))
    var pasted = Adjustments()
    SettingsGroup.levels.take(&pasted, from: Adjustments.newFrame)
    try check(decoded.ends == nil && pasted.ends == 2, "a frame from before reads with no way of its own (made one as it opens); 色阶 pasted carries the way")
    // 两端定法's three ways (0.24.1, the 自动两端 switch folded into it).
    var way = Adjustments.newFrame
    let first = way.endsWay
    way.endsWay = .old
    let oldWay = way.autoLevels && way.ends == 1 && way.endsWay == .old
    way.endsWay = .none
    let noWay = !way.autoLevels && way.endsWay == .none
    way.endsWay = .byLight
    try check(first == .byLight && oldWay && noWay && way.autoLevels && way.ends == 2,
      "两端定法 sets the automatic ends' way and whether there are any as one choice: the new way, the old, or none")
    var kept = Adjustments.newFrame
    kept.ends = 1
    var slide = Adjustments.newFrame
    slide.setReversal(true)
    let named = [Adjustments.newFrame, kept, manual, slide].map { SettingsGroup.levels.summary(of: $0) }
    try check(named[0].contains(Adjustments.endsNames.new) && named[1].contains(Adjustments.endsNames.old)
      && !named[2].contains("（") && !named[3].contains("（"),
      "选择性粘贴 names which way a negative's automatic ends are found (\(named[0]) · \(named[1])), not where they are off or on a slide")

    // A negative on Portra 160: a grey ramp across, from 0.3 log exposure (the darkest took light,
    // a stop over the base) to 1.3; along the bottom a band of deep blue sky, its blue 1.8, red and
    // green 0.9 (a twelfth of the frame).
    let pipe = ImagePipeline.shared
    let portra = FilmProfile.builtins.first { $0.id == "portra160" }!
    let base = RGB(r: 0.85, g: 0.57, b: 0.38)
    func reading(_ e: [Double]) -> [Double] { (0..<3).map { base.values[$0] * pow(10, -portra.slopes.values[$0] * e[$0] / 2.2) } }
    func negative(from lo: Double, to hi: Double, sky: Bool) -> CGImage {
      let w = 240, h = 120
      var samples = [UInt16](repeating: 65535, count: w * h * 4)
      for y in 0..<h {
        for x in 0..<w {
          var e = Array(repeating: lo + (hi - lo) * Double(x) / Double(w - 1), count: 3)
          if sky, y >= 100 { e = [0.9, 0.9, 1.8] }
          let v = reading(e)
          for c in 0..<3 { samples[(y * w + x) * 4 + c] = UInt16(min(1, v[c]) * 65535) }
        }
      }
      return CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    func settings(_ ends: Int?) -> Adjustments {
      var s = Adjustments()
      s.base = base
      s.neutralSample = RGB(reading([0.8, 0.8, 0.8]))
      s.ends = ends
      return s
    }
    let skyFrame = negative(from: 0.3, to: 1.3, sky: true)
    let before = pipe.analyze(skyFrame, settings: settings(nil), profile: portra)
    let now = pipe.analyze(skyFrame, settings: settings(2), profile: portra)
    try check(abs(now.low) < 0.03 && before.low > 0.25,
      String(format: "the black at the film base (%.2f; the darkest's own was %.2f): a frame whose darkest took light prints it above black", now.low, before.low))
    try check(now.high < before.high - 0.3 && abs(now.high - 1.3) < 0.08,
      String(format: "the white by luminance at the lightest grey (%.2f), not the sky's blue (%.2f before)", now.high, before.high))
    // A base read denser than the film that took no light (the darkest a tenth of a stop clearer):
    // the black at the frame's darkest, nothing of the picture cut to black for it.
    let clearFrame = negative(from: -0.1, to: 1.3, sky: false)
    let clearer = pipe.analyze(clearFrame, settings: settings(2), profile: portra)
    let clearerBefore = pipe.analyze(clearFrame, settings: settings(nil), profile: portra)
    try check(clearer.low < -0.01 && abs(clearer.low - clearerBefore.low) < 0.005,
      String(format: "a base read denser than the frame's darkest puts the black at the darkest (%.3f, as before %.3f), not over it", clearer.low, clearerBefore.low))
    // A short scene (fog): its black at the base, its white its own lightest, not lifted; a near
    // blank one not stretched to white.
    let fog = pipe.analyze(negative(from: 0.3, to: 0.8, sky: false), settings: settings(2), profile: portra)
    let blank = pipe.analyze(negative(from: 0.1, to: 0.3, sky: false), settings: settings(2), profile: portra)
    try check(abs(fog.low) < 0.03 && abs(fog.high - 0.8) < 0.06 && abs(blank.high - blank.low - ImagePipeline.shortestEndsAtBase) < 0.01,
      String(format: "a short scene keeps its black at the base and its white at its own lightest (%.2f); a near blank one spans %.2f, not stretched to white", fog.high, blank.high - blank.low))
  }
}
