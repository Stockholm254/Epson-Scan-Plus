import CoreGraphics
import Foundation

/// The de-masking region while it follows the picture: copies cropped wide, with the film's edge
/// round the photograph (a 120 negative's rebate and edge print, a 135 strip's sprocket holes, a
/// slide's Dmax rebate round a night frame), are read only inside it; a picture cropped tight,
/// with a straight edge in the scene and a shade nearly as clear as the base beyond it, is read as
/// before, all but its outer 5%.
enum FollowedRegionTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    /// A copy's crop, linear 16-bit, `value` giving each pixel's light from its position (0–1 across
    /// and down).
    func picture(_ w: Int, _ h: Int, _ value: (Double, Double) -> [Double]) -> CGImage {
      var px = [UInt16](repeating: 0, count: w * h * 3)
      for y in 0..<h {
        for x in 0..<w {
          let v = value((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h))
          for c in 0..<3 { px[(y * w + x) * 3 + c] = UInt16(min(65535, max(0, v[c] * 65535))) }
        }
      }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6,
        space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    let base = [0.55, 0.32, 0.18]
    func dense(_ d: Double) -> [Double] { base.map { $0 * pow(10, -d) } }
    // A scene: a pattern well denser than the base, a lighter band, and a shade nearly as clear.
    func scene(_ u: Double, _ v: Double) -> Double {
      let pattern = 0.45 + 0.3 * sin(u * 40) * cos(v * 31) + 0.25 * v
      return u < 0.3 && v < 0.25 ? 0.08 + 0.02 * sin(u * 90) : pattern
    }
    func inside(_ r: NormalRect?, _ picture: (left: Double, top: Double, right: Double, bottom: Double)) -> Bool {
      guard let r else { return false }
      return r.x >= picture.left && r.y >= picture.top && r.x + r.width <= picture.right && r.y + r.height <= picture.bottom
    }
    func text(_ r: NormalRect?) -> String {
      r.map { String(format: "left %.3f top %.3f right %.3f bottom %.3f", $0.x, $0.y, 1 - $0.x - $0.width, 1 - $0.y - $0.height) } ?? "none"
    }
    var negative = Adjustments()
    negative.inputGamma = 1

    // A 120 copy cropped wide: bare light past the film at the left, the rebate on all four sides
    // (6% at the left and bottom, 2% at the top and right), dense edge print (numbers, a ▼) in the
    // bottom and left rebate, a rim of unclipped light at the film's cut edge along the bottom, and a
    // shade nearly as clear as the base reaching the top. The photograph is 0.06–0.98 across and
    // 0.02–0.94 down.
    let photo120 = (left: 0.06, top: 0.02, right: 0.98, bottom: 0.94)
    func copy120(_ u: Double, _ v: Double) -> [Double] {
      if u < 0.02 { return [1, 1, 1] }
      if v > 0.996 { return [0.8, 0.8, 0.8] }
      if u >= photo120.left, u < photo120.right, v >= photo120.top, v < photo120.bottom {
        return dense(scene((u - photo120.left) / 0.92, (v - photo120.top) / 0.92))
      }
      // Print: blocks a character high along the bottom, every 9%, three in four of them there.
      let along = (u * 100).truncatingRemainder(dividingBy: 9)
      if v > 0.955, v < 0.972, along > 2, along < 6.5, Int(u * 100 / 9) % 4 != 3 { return dense(0.7) }
      if u > 0.03, u < 0.045, v > 0.4, v < 0.5, abs(v - 0.45) < (0.045 - u) * 3 { return dense(0.6) }
      return dense(0)
    }
    let wide120 = picture(900, 900, copy120)
    var known = negative
    known.rollBase = RGB(base)
    let region120 = pipe.followedRegion(wide120, settings: known)
    try check(inside(region120, photo120) && region120.map { $0.x < 0.09 && 1 - $0.y - $0.height < 0.09
      && abs($0.y - 0.05) < 1e-9 && abs(1 - $0.x - $0.width - 0.05) < 1e-9 } == true,
      "a 120 copy cropped with its rebate and edge print is read inside the film's edge, 1.5% in, and its outer 5% where the edge lies nearer: \(text(region120))")
    // Read at half the size, within 1%; with no base picked or known for the roll, as before: the
    // clearest film stands for the base badly (the rim of light is clearer still).
    let smaller = pipe.followedRegion(picture(450, 450, copy120), settings: known)
    try check(smaller.map { s in region120.map { r in
      abs(s.x - r.x) < 0.01 && abs(s.y - r.y) < 0.01 && abs(s.width - r.width) < 0.01 && abs(s.height - r.height) < 0.01 } == true } == true
      && pipe.followedRegion(wide120, settings: negative) == nil,
      "so read at half the size within 1% (\(text(smaller))), and with no base known all but its outer 5% as before")

    // Read there only: the same as that part with a region drawn on it.
    let profile = FilmProfile.builtins[0]
    var drawn = known
    drawn.analysisRegion = region120
    let followed = pipe.analyze(wide120, settings: known, profile: profile), byHand = pipe.analyze(wide120, settings: drawn, profile: profile)
    var oldMargin = known
    oldMargin.analysisRegion = NormalRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    let before = pipe.analyze(wide120, settings: oldMargin, profile: profile)
    func near(_ a: RGB, _ b: RGB, _ e: Double) -> Bool { zip(a.values, b.values).allSatisfy { abs($0 - $1) < e } }
    try check(followed.followed == region120 && near(followed.balance, byHand.balance, 1e-9) && abs(followed.low - byHand.low) < 1e-9
      && abs(followed.high - byHand.high) < 1e-9 && (abs(before.high - followed.high) > 0.02 || !near(before.balance, followed.balance, 0.01)),
      String(format: "its balance and ends are those of that part alone, not of the crop less 5%% with the print in it: high %.3f against %.3f", followed.high, before.high))

    // A 135 strip copied whole across: bare-light sprocket holes 2.79 mm deep from 2 mm in, 1.98 mm
    // long every 4.75 mm, the frame 5.5–29.5 mm across the 35 mm film, print outside the holes, the
    // gaps to the next frames at either end.
    let mm = 1 / 35.0
    let photo135 = (left: 0.03, top: 5.5 * mm, right: 0.97, bottom: 29.5 * mm)
    func strip(_ u: Double, _ v: Double, slide: Bool, frame: (Double, Double) -> [Double]) -> [Double] {
      let alongMM = u * 54, across = v / mm
      let hole = (2.0...4.79).contains(across) || (30.21...33.0).contains(across)
      if hole, alongMM.truncatingRemainder(dividingBy: 4.75) < 1.98 { return [1, 1, 1] }
      if u >= photo135.left, u < photo135.right, v >= photo135.top, v < photo135.bottom { return frame(u, v) }
      let rebate = slide ? [0.012, 0.014, 0.011] : dense(0)
      if across > 0.6, across < 1.6, alongMM.truncatingRemainder(dividingBy: 11) < 5 { return slide ? [0.3, 0.25, 0.08] : dense(0.65) }
      return rebate
    }
    let negative135 = picture(1200, 800) { u, v in
      strip(u, v, slide: false) { u, v in dense(scene((u - 0.03) / 0.94, (v - photo135.top) / (24 * mm))) }
    }
    let region135 = pipe.followedRegion(negative135, settings: known)
    var alone = known
    alone.filmEdges = .picture
    try check(pipe.followedRegion(negative135, settings: alone) == nil,
      "a roll copied without the film's edge (片边 不带) looks for none: the crop is the picture")
    try check(inside(region135, photo135) && region135.map { $0.y < photo135.top + 0.04 && 1 - $0.y - $0.height < 1 - photo135.bottom + 0.04 } == true,
      String(format: "a 135 negative with its sprocket holes and print is read inside the frame (%.3f–%.3f down): ", photo135.top, photo135.bottom) + text(region135))
    // With no base known the holes alone put it inside, and the base is still the crop's thinnest
    // film, as before (here the holes' rims, shrunk).
    let byHoles = pipe.followedRegion(negative135, settings: negative)
    let thinnest = pipe.analyze(negative135, settings: negative, profile: profile)
    // As the crop was read before: the whole of it at 300 pixels, its outer 5% left out.
    let thinnestBefore = pipe.densities(pipe.samples(negative135, maxDimension: 300), settings: negative, margin: 0.05)
    try check(inside(byHoles, photo135) && thinnest.followed == byHoles && near(thinnest.base, thinnestBefore.base, 1e-9),
      String(format: "with no base known the sprocket holes alone put it inside (%@), the base still the crop's thinnest film as before: G %.3f against %.3f",
        text(byHoles), thinnest.base.g, thinnestBefore.base.g))

    // A slide of the night sky, as dark as its Dmax rebate everywhere but a bright patch in the middle:
    // no step at its edges to find, the holes put it inside.
    var slide = Adjustments()
    slide.setReversal(true)
    slide.inputGamma = 1
    let night = picture(1200, 800) { u, v in
      strip(u, v, slide: true) { u, v in
        let r = hypot((u - 0.5) * 1.5, v - 0.5)
        return r < 0.15 ? [0.5, 0.55, 0.6] : [0.014, 0.016, 0.013]
      }
    }
    let regionNight = pipe.followedRegion(night, settings: slide)
    try check(inside(regionNight, (photo135.left - 0.03, photo135.top, photo135.right + 0.03, photo135.bottom)),
      String(format: "a dark slide's frame, as dark as its rebate, is put inside the sprocket holes (frame %.3f–%.3f down): ", photo135.top, photo135.bottom) + text(regionNight))
    // A slide's black is the picture's darkest, not the rebate's Dmax.
    let lit = picture(1200, 800) { u, v in
      strip(u, v, slide: true) { u, v in
        let t = 0.06 + 0.5 * (0.5 + 0.5 * sin(u * 30) * cos(v * 23))
        return [t, t * 0.95, t * 0.9]
      }
    }
    var slideOld = slide
    slideOld.analysisRegion = NormalRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    var slideTight = slide
    slideTight.analysisRegion = NormalRect(x: 0.05, y: photo135.top + 0.02, width: 0.9, height: photo135.bottom - photo135.top - 0.04)
    let slideAfter = pipe.analyze(lit, settings: slide, profile: profile), slideBefore = pipe.analyze(lit, settings: slideOld, profile: profile)
    let slideInside = pipe.analyze(lit, settings: slideTight, profile: profile)
    try check(slideAfter.followed != nil && abs(slideAfter.low - slideInside.low) < 0.02 && abs(slideBefore.low - slideInside.low) > 0.03,
      String(format: "a lit slide's black is its picture's (%.3f; inside %.3f), not the rebate's (%.3f with the crop less 5%%)", slideAfter.low, slideInside.low, slideBefore.low))

    // Cropped tight: a straight line across the scene near its bottom with a shade below it nearly
    // as clear as the base (0.08 D), and a lighter band at the top: no film edge, read as before.
    let tight = picture(800, 1100) { u, v in
      if v > 0.93 { return dense(0.08 + 0.004 * sin(u * 50)) }
      return dense(scene(u, v))
    }
    let tightRegion = pipe.followedRegion(tight, settings: known)
    let tightAnalysis = pipe.analyze(tight, settings: known, profile: profile)
    try check(tightRegion == nil && tightAnalysis.followed == nil,
      "a picture cropped tight, a straight shade nearly as clear as the base along its bottom, has no film edge found: read all but its outer 5%, as before")
    // A positive has no film edge looked for.
    var positive = Adjustments()
    positive.inputIsNegative = false
    try check(pipe.followedRegion(wide120, settings: positive) == nil, "a positive file is read as before")
  }
}
