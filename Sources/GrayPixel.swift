import CoreGraphics
import Foundation

/// 找中性: where a colour negative's grey lies, found from the picture's gray pixels, as an
/// automatic 中性灰 pick.
///
/// A gray pixel is where light and shade change all three channels' log exposure alike while the
/// colour stays put: the edges and texture of white walls, concrete, roads, granite (Yang et al.
/// 2015; Qian et al., "Revisiting Gray Pixel" and the Grayness Index, 2018–19). Each pixel's
/// grayness is the change of its colour, red and blue against green, over the change of its
/// lightness, both read as the Laplacian of the smoothed log exposure; the flattest 2% are the grays.
///
/// Light and shade on a coloured surface pass the same test (a bridge's orange, dry grass, a yellow
/// wall), so the grays are looked for only within 0.15 log of where a neutral is expected: the
/// calibrated preset's neutral, else the picture's average colour. On the author's library, 23
/// frames with a grey picked by hand (2026-11-13): within the calibrated neutral, the median miss
/// was 3.3° against 4.2° for the calibrated neutral alone; unbounded gray pixels were as often far
/// off (up to 21°) as close; the black of each channel aligned, 13°.
enum GrayPixelNeutral {
  struct Found {
    /// A negative's linear reading whose balance is the grays': what a 中性灰 pick would read.
    var reading: RGB
    /// The neutral found and the one it was looked for near, as red and blue against green, in log
    /// exposure through the film's slopes.
    var neutral: (r: Double, b: Double)
    var prior: (r: Double, b: Double)
    /// Whether that was the calibrated neutral (else the picture's average).
    var calibrated: Bool
    /// How many gray pixels set it, and how many lay near the prior.
    var grays: Int
    var candidates: Int
    /// How far the light lies from the prior along daylight's warm–cool line (warmer positive),
    /// and across it (magenta positive), in log exposure.
    var warmer: Double { let d = Self.daylight; return (neutral.r - prior.r) * d.r + (neutral.b - prior.b) * d.b }
    var magenta: Double { let d = Self.daylight; return (neutral.r - prior.r) * -d.b + (neutral.b - prior.b) * d.r }
    /// Warmer light: more red against green, less blue, roughly as a blackbody's falls on three
    /// layers near 650, 545 and 445 nm.
    static let daylight: (r: Double, b: Double) = {
      let r = 1 / 0.545 - 1 / 0.65, b = -(1 / 0.445 - 1 / 0.545), n = (r * r + b * b).squareRoot()
      return (r / n, b / n)
    }()
  }
  /// How far from the prior a gray may lie, and the share of the flattest that count.
  static let reach = 0.15, flattest = 0.02
  /// Across how many pixels the picture is read.
  static let dimension = 1200

  /// The grays' neutral in `image` (the frame as cropped, as `ImagePipeline.analyze` takes it);
  /// nil for a positive, a slide or black and white, or where too few grays lie near the prior.
  static func find(in image: CGImage, settings: Adjustments, profile: FilmProfile) -> Found? {
    guard settings.inputIsNegative, !settings.isSlide, !settings.isMonochrome else { return nil }
    let pipe = ImagePipeline.shared
    // The base the analysis takes (a picked or the roll's, else the part's own thinnest film), not
    // the whole analysis for it: some 60 ms on a copy.
    let base = settings.base ?? settings.rollBase ?? pipe.densities(image, settings: settings, maxDimension: 300).base
    let part = pipe.analysisPart(image, settings)
    let read = pipe.samples(part.image, maxDimension: dimension)
    let mx = Int(Double(read.width) * part.margin), my = Int(Double(read.height) * part.margin)
    let w = read.width - 2 * mx, h = read.height - 2 * my
    guard w > 20, h > 20 else { return nil }
    let (slopes, _) = ImagePipeline.slopes(settings, profile)
    let toe = ImagePipeline.toe(settings, profile)
    let gamma = settings.inputGamma
    let n = w * h
    var e0 = [Float](repeating: 0, count: n), e1 = e0, e2 = e0
    var valid = [Bool](repeating: false, count: n)
    let baseLight = (0..<3).map { max(1e-4, base.values[$0]) }, sl = slopes.values, widths = toe.values, rw = read.width
    // Row by row on every core, each pixel as before.
    read.values.withUnsafeBufferPointer { v in
      e0.withUnsafeMutableBufferPointer { p0 in
        e1.withUnsafeMutableBufferPointer { p1 in
          e2.withUnsafeMutableBufferPointer { p2 in
            valid.withUnsafeMutableBufferPointer { ok in
              DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                  let p = ((y + my) * rw + x + mx) * 4, i = y * w + x
                  var low = Double.infinity, high = 0.0
                  for c in 0..<3 {
                    let value = Double(v[p + c])
                    let d = log10(baseLight[c] / max(1e-4, value)) * gamma
                    low = min(low, d)
                    high = max(high, value)
                    let ex = Float(FilmToe.exposure(d / sl[c], width: widths[c]))
                    if c == 0 { p0[i] = ex } else if c == 1 { p1[i] = ex } else { p2[i] = ex }
                  }
                  // Clear of the base (unexposed film, sprocket holes) and of clipped light.
                  ok[i] = low > 0.03 && high < 0.98 && low.isFinite
                }
              }
            }
          }
        }
      }
    }
    let e = [e0, e1, e2]
    let smooth = e.map { blur($0, w, h) }
    var u = [Float](repeating: 0, count: n), b = u, l = u
    for i in 0..<n {
      u[i] = smooth[0][i] - smooth[1][i]
      b[i] = smooth[2][i] - smooth[1][i]
      l[i] = (smooth[0][i] + smooth[1][i] + smooth[2][i]) / 3
    }
    let lu = laplacian(blur(u, w, h), w, h), lb = laplacian(blur(b, w, h), w, h)
    let ll = laplacian(blur(l, w, h), w, h).map { abs($0) }
    // A gray pixel's neighbours are read too: all of a 5 × 5 around it must be.
    let around = box(valid.map { $0 ? Float(1) : 0 }, w, h, radius: 2)
    var ok = (0..<n).map { valid[$0] && around[$0] > 0.99 }
    let contrasts = (0..<n).filter { ok[$0] }.map { ll[$0] }
    guard contrasts.count > 1000 else { return nil }
    let lit = median(contrasts)
    for i in 0..<n where ok[i] && ll[i] <= lit { ok[i] = false }
    let grayness = box((0..<n).map { (lu[$0] * lu[$0] + lb[$0] * lb[$0]).squareRoot() / (ll[$0] + 1e-6) }, w, h, radius: 3)
    // The prior: the calibrated neutral, else the average colour, from the unsmoothed exposures.
    let calibrated = profile.offsets != nil
    let prior: (r: Double, b: Double)
    if let o = profile.offsets {
      prior = (o.r - o.g, o.b - o.g)
    } else {
      var sr = 0.0, sb = 0.0, k = 0.0
      for i in 0..<n where valid[i] { sr += Double(e[0][i] - e[1][i]); sb += Double(e[2][i] - e[1][i]); k += 1 }
      guard k > 0 else { return nil }
      prior = (sr / k, sb / k)
    }
    let near = (0..<n).filter { i in
      ok[i] && hypot(Double(u[i]) - prior.r, Double(b[i]) - prior.b) < reach
    }
    guard near.count >= max(200, n / 4000) else { return nil }
    let cut = quantile(near.map { grayness[$0] }, flattest)
    let grays = near.filter { grayness[$0] <= cut }
    guard grays.count >= 20 else { return nil }
    let neutral = (r: Double(median(grays.map { u[$0] })), b: Double(median(grays.map { b[$0] })))
    // A reading of a grey at the grays' middle lightness with that balance.
    let green = Double(median(grays.map { smooth[1][$0] }))
    let exposure = [green + neutral.r, green, green + neutral.b]
    let reading = RGB((0..<3).map { c in
      let d = slopes.values[c] * FilmToe.density(exposure[c], width: toe.values[c]) / max(0.1, gamma)
      return max(1e-6, base.values[c]) / pow(10, d)
    })
    return Found(reading: reading, neutral: neutral, prior: prior, calibrated: calibrated, grays: grays.count, candidates: near.count)
  }

  /// Each row of `out` from `a`, on every core: `row(y, a, out)` writes row y.
  private static func rows(_ a: [Float], _ h: Int, _ row: (Int, UnsafeBufferPointer<Float>, UnsafeMutableBufferPointer<Float>) -> Void) -> [Float] {
    var out = [Float](repeating: 0, count: a.count)
    a.withUnsafeBufferPointer { pa in
      out.withUnsafeMutableBufferPointer { po in
        DispatchQueue.concurrentPerform(iterations: h) { y in row(y, pa, po) }
      }
    }
    return out
  }
  /// Gaussian of σ 1 pixel, edges held. Rows on every core, each value summed as before (one
  /// thread took some 15 ms a pass on a copy's 1200 pixels).
  static func blur(_ a: [Float], _ w: Int, _ h: Int) -> [Float] {
    let taps: [Float] = [0.00443, 0.05400, 0.24203, 0.39905, 0.24203, 0.05400, 0.00443]
    let t = rows(a, h) { y, a, t in
      let row = y * w
      for x in 0..<w {
        var s: Float = 0
        for j in -3...3 { s += taps[j + 3] * a[row + min(w - 1, max(0, x + j))] }
        t[row + x] = s
      }
    }
    return rows(t, h) { y, t, out in
      for x in 0..<w {
        var s: Float = 0
        for j in -3...3 { s += taps[j + 3] * t[min(h - 1, max(0, y + j)) * w + x] }
        out[y * w + x] = s
      }
    }
  }
  static func laplacian(_ a: [Float], _ w: Int, _ h: Int) -> [Float] {
    rows(a, h) { y, a, out in
      for x in 0..<w {
        let i = y * w + x
        out[i] = a[y * w + max(0, x - 1)] + a[y * w + min(w - 1, x + 1)] + a[max(0, y - 1) * w + x] + a[min(h - 1, y + 1) * w + x] - 4 * a[i]
      }
    }
  }
  /// The mean over a (2r + 1)² square, edges held.
  static func box(_ a: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
    let size = Float(2 * r + 1)
    let t = rows(a, h) { y, a, t in
      let row = y * w
      for x in 0..<w {
        var s: Float = 0
        for j in -r...r { s += a[row + min(w - 1, max(0, x + j))] }
        t[row + x] = s / size
      }
    }
    return rows(t, h) { y, t, out in
      for x in 0..<w {
        var s: Float = 0
        for j in -r...r { s += t[min(h - 1, max(0, y + j)) * w + x] }
        out[y * w + x] = s / size
      }
    }
  }
  /// The value sorting `a` would put at `p` of the way along: picked out, not sorted (a copy's
  /// million contrasts took some 80 ms to sort).
  static func quantile(_ a: [Float], _ p: Double) -> Float {
    guard !a.isEmpty else { return 0 }
    return select(a, min(a.count - 1, Int(Double(a.count - 1) * p)))
  }
  /// The `k`th smallest of `a`, as `a.sorted()[k]` (`selectKth`).
  static func select(_ a: [Float], _ k: Int) -> Float { selectKth(a, k) }
  static func median(_ a: [Float]) -> Float { quantile(a, 0.5) }
}

extension AppModel {
  /// Whether a frame's gray pixels are being looked for, off the main thread; frames whose
  /// picture could not be read, not looked at again until the app runs anew.
  private static var findingNeutral = false
  private static var unreadable = Set<UUID>()
  /// What was found for each frame, for the assistant's report, and who waits for a frame's.
  private static var foundNeutrals = [UUID: GrayPixelNeutral.Found]()
  private static var neutralWaiters = [UUID: [(GrayPixelNeutral.Found?) -> Void]]()
  /// Off in the self-test but where a test turns it on: frames made there keep the balance their
  /// checks expect.
  static var findsAutoNeutrals = !CommandLine.arguments.contains("--self-test")

  /// Whether `f`'s 自动 is waiting for its gray pixels: a colour negative on 自动, no grey picked,
  /// not printed with the roll's balance.
  static func wantsAutoNeutral(_ f: FilmFrame) -> Bool {
    let a = f.adjustments
    return a.autoNeutral == .pending && a.autoWhiteBalance && a.neutralSample == nil && a.balancesByGrays
      && a.sharedBalance != true && !unreadable.contains(f.id)
  }
  /// What the found neutral was read from: changed meanwhile, it is looked for again.
  private static func neutralKey(_ f: FilmFrame) -> String {
    let a = f.adjustments
    return "\(f.rect)|\(String(describing: a.base))|\(String(describing: a.rollBase))|\(String(describing: a.analysisRegion))|\(a.inputGamma)|\(String(describing: f.crosstalk))|\(f.flatID ?? "")|\(String(describing: a.leakFix != nil))"
  }

  /// 自动's neutral for the frames waiting for it (`wantsAutoNeutral`), the one shown first, one at
  /// a time off the main thread, each on a copy 1200 pixels across (some 0.3 s): found, or `.none`
  /// where too few gray pixels lie near the prior, 自动 then as before. Not an edit of its own
  /// (⌘Z takes back the choice of 自动 that asked for it). Called with every refresh.
  /// The frame shown alone is left to its render, which looks for them as it reads it (`rendersGrays`);
  /// `shownToo` looks for it here all the same (the assistant's 找中性 in the self-test).
  func resolveAutoNeutrals(shownToo: Bool = false) {
    guard Self.findsAutoNeutrals, !Self.findingNeutral else { return }
    let waiting = frames.filter { Self.wantsAutoNeutral($0) && (shownToo || !rendersGrays($0)) }
    guard let next = waiting.first(where: { $0.id == selectedID }) ?? waiting.first else { return }
    Self.findingNeutral = true
    let profile = conversionProfile, key = Self.neutralKey(next)
    DispatchQueue.global(qos: .utility).async { [weak self] in
      // A model gone meanwhile (a test's) leaves the finder free for the next.
      guard let self else { return DispatchQueue.main.async { AppModel.findingNeutral = false } }
      var read = true
      let found = autoreleasepool { () -> GrayPixelNeutral.Found? in
        guard let src = try? self.source(for: next, maxDimension: GrayPixelNeutral.dimension) else { read = false; return nil }
        return GrayPixelNeutral.find(in: src, settings: next.adjustments, profile: profile)
      }
      DispatchQueue.main.async {
        Self.findingNeutral = false
        guard let i = self.frames.firstIndex(where: { $0.id == next.id }) else { return self.resolveAutoNeutrals() }
        guard read else {
          Self.unreadable.insert(next.id)
          Self.neutralWaiters.removeValue(forKey: next.id)?.forEach { $0(nil) }
          return self.resolveAutoNeutrals()
        }
        // Still waiting, and read from the same picture: kept. Else looked for again, or, no longer
        // wanted (a grey picked meanwhile, 原片), left; whoever waited for it told so.
        guard Self.wantsAutoNeutral(self.frames[i]) else {
          Self.neutralWaiters.removeValue(forKey: next.id)?.forEach { $0(nil) }
          return self.resolveAutoNeutrals()
        }
        guard Self.neutralKey(self.frames[i]) == key else { return self.resolveAutoNeutrals() }
        self.frames[i].adjustments.autoNeutral = found.map { Adjustments.AutoNeutral.found($0.reading) } ?? Adjustments.AutoNeutral.none
        Self.foundNeutrals[next.id] = found
        Self.neutralWaiters.removeValue(forKey: next.id)?.forEach { $0(found) }
        if self.frames.contains(where: Self.wantsAutoNeutral) {
          if next.id == self.selectedID { self.refresh() } else { self.resolveAutoNeutrals() }
        } else {
          if next.id == self.selectedID { self.refresh() }
          self.saveProject()
          self.updateThumbnails()
        }
      }
    }
  }

  /// Whether the single frame's render looks for `f`'s gray pixels itself, as it reads the frame:
  /// shown alone and balanced (not ①'s raw picture, ②'s de-masked one or the before), its 自动
  /// waiting for them. It then shows once, balanced by them, where it showed by the old 自动 first
  /// and again some 0.3 s later, when the finder had found them (until 0.23.8).
  func rendersGrays(_ f: FilmFrame) -> Bool {
    Self.findsAutoNeutrals && singleView && f.id == selectedID && !showsOriginal && !showsDemasked && !showsBefore
      && Self.wantsAutoNeutral(f)
  }
  /// What the render keeps the gray pixels it finds by (`neutralKey`), when it is to look for them.
  func graysForRender(_ f: FilmFrame) -> String? { rendersGrays(f) ? Self.neutralKey(f) : nil }
  /// Off the main thread: `f`'s gray pixels, as the finder looks for them; `read` false where its
  /// picture could not be read.
  func findGrays(_ f: FilmFrame, profile: FilmProfile) -> (found: GrayPixelNeutral.Found?, read: Bool) {
    var read = true
    let found = autoreleasepool { () -> GrayPixelNeutral.Found? in
      guard let src = try? source(for: f, maxDimension: GrayPixelNeutral.dimension) else { read = false; return nil }
      return GrayPixelNeutral.find(in: src, settings: f.adjustments, profile: profile)
    }
    return (found, read)
  }
  /// Back on the main thread: what the render found kept for its frame, as the finder keeps it,
  /// while the frame still waits and is read from the same picture. Not shown again: the render
  /// already balanced by it. The finder then goes on with the frames still waiting.
  func keepRenderedGrays(_ id: UUID, found: GrayPixelNeutral.Found?, read: Bool, key: String) {
    defer { resolveAutoNeutrals() }
    guard let i = frames.firstIndex(where: { $0.id == id }) else { return }
    guard read else {
      Self.unreadable.insert(id)
      Self.neutralWaiters.removeValue(forKey: id)?.forEach { $0(nil) }
      return
    }
    guard Self.wantsAutoNeutral(frames[i]), Self.neutralKey(frames[i]) == key else { return }
    frames[i].adjustments.autoNeutral = found.map { Adjustments.AutoNeutral.found($0.reading) } ?? Adjustments.AutoNeutral.none
    Self.foundNeutrals[id] = found
    Self.neutralWaiters.removeValue(forKey: id)?.forEach { $0(found) }
    if !frames.contains(where: Self.wantsAutoNeutral) {
      saveProject()
      updateThumbnails()
    }
  }

  /// For an export: the frames still waiting for their gray pixels, with what each is read from.
  func exportGrayKeys(_ items: [FilmFrame]) -> [UUID: String] {
    guard Self.findsAutoNeutrals else { return [:] }
    return Dictionary(items.filter(Self.wantsAutoNeutral).map { ($0.id, Self.neutralKey($0)) }, uniquingKeysWith: { a, _ in a })
  }
  /// On the export's queue: the frame with its gray pixels looked for, as the finder looks.
  func withGrays(_ f: FilmFrame, profile: FilmProfile) -> (frame: FilmFrame, found: GrayPixelNeutral.Found?) {
    let found = autoreleasepool { () -> GrayPixelNeutral.Found? in
      guard let src = try? source(for: f, maxDimension: GrayPixelNeutral.dimension) else { return nil }
      return GrayPixelNeutral.find(in: src, settings: f.adjustments, profile: profile)
    }
    var g = f
    g.adjustments.autoNeutral = found.map { Adjustments.AutoNeutral.found($0.reading) } ?? Adjustments.AutoNeutral.none
    return (g, found)
  }
  /// Back on the main thread: what the export found kept for its frame, as the finder would keep
  /// it, while the frame still waits and is read from the same picture.
  func keepExportedGrays(_ f: FilmFrame, found: GrayPixelNeutral.Found?, key: String) {
    guard let i = frames.firstIndex(where: { $0.id == f.id }), Self.wantsAutoNeutral(frames[i]),
      Self.neutralKey(frames[i]) == key else { return }
    frames[i].adjustments.autoNeutral = f.adjustments.autoNeutral
    Self.foundNeutrals[f.id] = found
    Self.neutralWaiters.removeValue(forKey: f.id)?.forEach { $0(found) }
    if f.id == selectedID { refresh() }
  }

  /// The assistant's 找中性: 自动 chosen for the frame shown (and the others chosen, as 自动 is
  /// given them), its gray pixels looked for, and `done` told in a line what came of it, with the figures.
  func findNeutral(done: @escaping (String) -> Void) {
    guard let shown = selected else { return done("没有选中的画面。") }
    let a = shown.adjustments
    guard a.inputIsNegative, !a.isSlide, !a.isMonochrome else {
      return done("自动的灰像素只用于彩色负片；反转片和黑白负片用 pick_neutral 点一处应为灰的地方。")
    }
    if a.sharedBalance == true { return done("这一卷开着「整卷同一白平衡」，每张按整卷统计的白平衡，不按自己的灰像素；要用灰像素先关掉它（adjust shared_balance false）。") }
    let name = shown.name, calibrated = conversionProfile.offsets != nil
    func report(_ found: GrayPixelNeutral.Found?) {
      guard let r = found else {
        return done("第 \(name) 张：白平衡已是自动，但找不到足够的灰像素（画面多半是有颜色的东西，或没有\(calibrated ? "接近标定中性" : "接近整张平均")的灰），自动按\(calibrated ? "标定的中性" : "各通道的黑")配平；可以用 pick_neutral 点一处应为灰的地方。")
      }
      let light = r.calibrated ? "，" + Self.lightWords(r) : "（没有标定，在整张的平均附近找）"
      done(String(format: "第 %@ 张：白平衡为自动，按 %d 处灰像素配平%@。[先验附近 %d 处，先验 %@ R−G %+.3f B−G %+.3f，找到 R−G %+.3f B−G %+.3f（对数曝光），偏暖 %+.3f、偏洋红 %+.3f] 可用 undo 撤销。",
        name, r.grays, light, r.candidates, r.calibrated ? "标定的中性" : "整张平均", r.prior.r, r.prior.b, r.neutral.r, r.neutral.b, r.warmer, r.magenta))
    }
    setBalanceMode(.auto)
    guard let now = selected else { return done("没有选中的画面。") }
    switch now.adjustments.autoNeutral {
    case .some(.found):
      if let r = Self.foundNeutrals[now.id] { report(r) } else { done("第 \(name) 张：白平衡已是自动，按之前在这张里找到的灰像素配平。要重新找，先用 adjust 关掉 auto_white_balance 再打开。") }
    case .some(.none): report(nil)
    default:
      Self.unreadable.remove(now.id)
      Self.neutralWaiters[now.id, default: []].append(report)
      // In the self-test the finder runs for this frame alone: started here, it stops when done.
      // Shown alone with the finder on, the frame's render looks for them (`rendersGrays`).
      let wasOn = Self.findsAutoNeutrals
      Self.findsAutoNeutrals = true
      resolveAutoNeutrals(shownToo: !wasOn)
      Self.findsAutoNeutrals = wasOn
    }
  }
  /// How the light the grays were under lies from the calibrated one, in words.
  static func lightWords(_ r: GrayPixelNeutral.Found) -> String {
    let warm = r.warmer, tint = r.magenta
    var words = [String]()
    if abs(warm) >= 0.015 { words.append(warm > 0 ? (warm > 0.05 ? "暖不少" : "暖一点") : (warm < -0.05 ? "冷不少" : "冷一点")) }
    if abs(tint) >= 0.015 { words.append(tint > 0 ? "偏洋红" : "偏绿") }
    return words.isEmpty ? "这张的光和标定时差不多" : "这张的光比标定时" + words.joined(separator: "、")
  }
}
