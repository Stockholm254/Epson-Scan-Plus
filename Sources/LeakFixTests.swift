import AppKit
import CoreImage
import Foundation

/// 去漏光's repair taken into ③ 调色 (`LeakFix`): the conversion with a correction of nothing is
/// the conversion without one; a repair is measured back as the change it made; and a correction
/// lands where it was measured on the picture as shown, however the frame is turned and mirrored.
enum LeakFixTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let root = folder.appendingPathComponent("leak-fix", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let pipe = ImagePipeline.shared
    let profile = FilmProfile.builtins[0]
    // A negative of 300 × 200: an orange mask, a gradient and some texture under it.
    func negative(_ w: Int, _ h: Int, flat: Bool = false) -> CGImage {
      let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
      for y in 0..<h {
        for x in 0..<w {
          let g = flat ? 0.5 : 0.25 + 0.5 * Double(x) / Double(w) + 0.05 * sin(Double(x * 7 + y * 3))
          let i = (y * w + x) * 4
          data[i] = UInt8(min(255, max(0, 255 * (0.85 - 0.35 * g))))
          data[i + 1] = UInt8(min(255, max(0, 255 * (0.6 - 0.3 * g))))
          data[i + 2] = UInt8(min(255, max(0, 255 * (0.4 - 0.25 * g))))
          data[i + 3] = 255
        }
      }
      return ctx.makeImage()!
    }
    func pixels(_ image: CGImage) -> [UInt8] {
      let w = image.width, h = image.height
      let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    }
    func rendered(_ image: CGImage, _ s: Adjustments) throws -> CGImage {
      let ci = try pipe.output(image, settings: s, profile: profile)
      return pipe.context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: pipe.outputSpace)!
    }
    let picture = negative(300, 200)

    // A correction of nothing: the picture as without one.
    let none = LeakFixField(width: 30, height: 20, a: [Float](repeating: 1, count: 600 * 3), d: [Float](repeating: 0, count: 600 * 3))
    let noneURL = root.appendingPathComponent("none.leakfix")
    try none.write(to: noneURL)
    let read = try LeakFixField(contentsOf: noneURL)
    try check(read == none, "a correction is written and read back as it was")
    let plain = Adjustments()
    var fixed = plain
    fixed.leakFix = LeakFix(file: noneURL.path, job: nil, made: Date())
    let a = pixels(try rendered(picture, plain)), b = pixels(try rendered(picture, fixed))
    try check(a.count == b.count && zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 0 },
      "a frame with a correction of nothing converts exactly as without one (the repaired kernels run)")
    // ③'s statistics read the repaired picture: with a correction of nothing, as without one.
    let plainAnalysis = pipe.analyze(picture, settings: plain, profile: profile), fixedAnalysis = pipe.analyze(picture, settings: fixed, profile: profile)
    try check(plainAnalysis.balance == fixedAnalysis.balance && plainAnalysis.gain == fixedAnalysis.gain
      && plainAnalysis.low == fixedAnalysis.low && plainAnalysis.high == fixedAnalysis.high,
      "auto white balance and levels with a correction of nothing are as without one")
    // And with one: a sample under it is corrected, one outside it not.
    let half = LeakFixField(width: 30, height: 20, a: [Float](repeating: 1, count: 600 * 3),
      d: (0..<600).flatMap { i -> [Float] in i % 30 < 15 ? [0.2, 0.2, 0.2] : [0, 0, 0] })
    let halfURL = root.appendingPathComponent("half.leakfix")
    try half.write(to: halfURL)
    var halved = plain
    halved.leakFix = LeakFix(file: halfURL.path, job: nil, made: Date())
    let part = pipe.analysisPart(picture, halved)
    if let correct = pipe.leakCorrection(halved, profile: profile, part: part, width: 100, height: 60) {
      let d = [0.6, 0.7, 0.8]
      let left = correct(10, 30, d), right = correct(90, 30, d)
      try check(left.indices.allSatisfy { left[$0] > d[$0] + 0.05 } && right.indices.allSatisfy { abs(right[$0] - d[$0]) < 1e-9 },
        "a sample where the repair adds exposure (lifts the picture) reads denser, one outside it as it was")
    } else {
      try check(false, "a frame with a repair corrects its statistics")
    }
    let neutral = try pipe.neutral(picture, settings: plain, profile: profile)
    try check(neutral.image.extent.size == CGSize(width: 300, height: 200) && neutral.scale.negative && neutral.scale.high > neutral.scale.low,
      "去漏光's picture is the frame taken off its mask, on a scale it can be read back from")
    try check(abs(neutral.scale.straight(neutral.scale.shown(0.37)) - 0.37) < 1e-9, "and the scale goes there and back")

    // A repair measured back: a smooth warm patch taken out of a textured picture.
    let w = 120, h = 80
    var before = [Float](repeating: 0, count: w * h * 3), after = before
    for y in 0..<h {
      for x in 0..<w {
        let base = 0.35 + 0.25 * Double(x) / Double(w) + 0.04 * sin(Double(x * 5 + y * 11))
        let blob = 0.12 * exp(-(pow(Double(x) - 40, 2) + pow(Double(y) - 30, 2)) / (2 * 15 * 15))
        for c in 0..<3 {
          let v = base + (c == 0 ? 0.03 : 0)
          before[(y * w + x) * 3 + c] = Float(v + (c == 0 ? blob : blob * 0.3))
          after[(y * w + x) * 3 + c] = Float(v)
        }
      }
    }
    let scale = LeakNeutralScale(negative: true, low: -0.2, high: 1.1, encode: 1, gain: [1.3, 1.0, 0.8], balance: [0.1, 0, -0.05])
    let fit = LeakFix.measure(before: before, after: after, width: w, height: h, scale: scale, radius: 4)
    let centre = (30 * w + 40) * 3
    try check(fit.mean < 0.8 && fit.worst < 3, String(format: "a repair is measured back to within %.2f / 255 on average (%.2f at the 99th percentile)", fit.mean, fit.worst))
    func corrected(_ i: Int) -> Double { scale.shown(reading: Double(fit.a[i]) * scale.reading(Double(before[i]), i % 3) + Double(fit.d[i]), i % 3) }
    let far = (5 * w + 110) * 3
    try check(abs(corrected(centre) - Double(after[centre])) < 0.01 && abs(corrected(far) - Double(before[far])) < 0.005,
      String(format: "the correction takes the patch's red out where it was (%.3f for %.3f), and leaves the picture far from it", corrected(centre), after[centre]))

    // Where it lands: a correction measured in the top left of the picture as shown comes out in
    // the top left of the frame as shown, on a frame as it lies and on one turned a quarter and mirrored.
    try placed(Adjustments(), shown: (300, 200))
    var turned = Adjustments()
    turned.rotation = 1
    turned.flipHorizontal = true
    try placed(turned, shown: (200, 300))
    func placed(_ turned: Adjustments, shown: (Int, Int)) throws {
    let shownW = shown.0 / 5, shownH = shown.1 / 5
    var lift = [Float](repeating: 0, count: shownW * shownH * 3)
    for y in 0..<(shownH / 2) { for x in 0..<(shownW / 2) { for c in 0..<3 { lift[(y * shownW + x) * 3 + c] = 0.3 } } }
    let place = { (p: CGPoint) in ImageGeometry.display(p, settings: turned, aspect: 1.5) }
    let gw = 60, gh = 40
    let field = LeakFixField(width: gw, height: gh, a: [Float](repeating: 1, count: gw * gh * 3),
      d: LeakFix.resampled(lift, width: shownW, height: shownH, to: gw, gh, place: place))
    let liftURL = root.appendingPathComponent("lift.leakfix")
    try field.write(to: liftURL)
    let flat = negative(300, 200, flat: true)
    var lifted = turned
    lifted.autoLevels = false
    lifted.autoWhiteBalance = false
    lifted.leakFix = LeakFix(file: liftURL.path, job: nil, made: Date())
    var unlifted = lifted
    unlifted.leakFix = nil
    let out = try rendered(flat, lifted), ref = pixels(try rendered(flat, unlifted)), got = pixels(out)
    let qw = out.width / 2, qh = out.height / 2
    func gain(_ x0: Int, _ y0: Int) -> Double {
      var sum = 0.0
      for y in (y0 + qh / 8)..<(y0 + qh * 7 / 8) { for x in (x0 + qw / 8)..<(x0 + qw * 7 / 8) {
        let i = (y * out.width + x) * 4
        sum += Double(got[i + 1]) - Double(ref[i + 1])
      } }
      return sum / Double((qh * 3 / 4) * (qw * 3 / 4))
    }
    try check(out.width == shown.0 && out.height == shown.1, "the frame shows \(shown.0) × \(shown.1)")
    let topLeft = gain(0, 0), topRight = gain(qw, 0), bottomLeft = gain(0, qh), bottomRight = gain(qw, qh)
    try check(topLeft > 8 && abs(topRight) < 2 && abs(bottomLeft) < 2 && abs(bottomRight) < 2,
      String(format: "a correction measured in the top left of the picture as shown lifts the top left there (turned %d, mirrored %@): %.1f, %.1f, %.1f, %.1f",
        turned.rotation, turned.flipHorizontal == true ? "yes" : "no", topLeft, topRight, bottomLeft, bottomRight))
    guard turned.rotation == 0 else { return }
    // ③'s white balance after it: the repair lifts the same, it lies before the balance.
    var warmer = lifted, warmerPlain = unlifted
    (warmer.warmth, warmerPlain.warmth) = (0.4, 0.4)
    let warmOut = try rendered(flat, warmer), warmRef = pixels(try rendered(flat, warmerPlain)), warmGot = pixels(warmOut)
    var warmLift = 0.0
    for y in (qh / 8)..<(qh * 7 / 8) { for x in (qw / 8)..<(qw * 7 / 8) {
      let i = (y * warmOut.width + x) * 4
      warmLift += Double(warmGot[i + 1]) - Double(warmRef[i + 1])
    } }
    warmLift /= Double((qh * 3 / 4) * (qw * 3 / 4))
    try check(abs(warmLift - topLeft) < 1.5,
      String(format: "③'s white balance changed after the repair, the repair lifts the same (%.1f, was %.1f): it lies before the balance", warmLift, topLeft))
    }

    // The whole way: a frame of a roll opened in 去漏光, a patch repaired with a region, 用到 ③ 调色,
    // and the frame's own conversion, graded as any, has the repair; ⌘Z and 去掉修复 take it out.
    let roll = root.appendingPathComponent("roll", isDirectory: true)
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    let overview = roll.appendingPathComponent("overview.png")
    let leaked: CGImage = {
      let w = 300, h = 200
      let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(negative(w, h), in: CGRect(x: 0, y: 0, width: w, height: h))
      // A patch the light reached through a gap: denser in green and blue on the negative, so red in the positive.
      ctx.setFillColor(red: 0.7, green: 0.3, blue: 0.2, alpha: 0.6)
      ctx.fillEllipse(in: CGRect(x: 60, y: 200 - 120, width: 70, height: 60))
      return ctx.makeImage()!
    }()
    try pipe.savePNG(leaked, to: overview)
    let frame = FilmFrame(name: "01", rect: .full, format: "135")
    var project = DeskProject(
      overviewPath: overview.path, overviewDPI: 150, physicalWidthMM: 50.8, physicalHeightMM: 33.9,
      filmName: "Kodak Portra 160", profile: profile, scanDPI: 2400, frames: [frame])
    project.overviewFile = "overview.png"
    let file = roll.appendingPathComponent(AppModel.projectFile)
    try JSONEncoder().encode(project).write(to: file)
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let m = AppModel(libraryURL: root, preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    m.undoManager = edits
    let lab = LeakLab(root: root.appendingPathComponent("jobs"))
    lab.renderFrame = { [unowned m] in try m.leakPositive($0) }
    lab.renderNeutral = { [unowned m] in try m.leakNeutral($0, longest: $1) }
    m.leak = lab
    m.loadProject(file)
    func settle(_ s: Double = 0.2) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    let id = m.frames[0].id
    m.openInLeak(id)
    lab.wait()
    settle()
    try check(m.page == .leak && lab.hasBase && lab.job?.origin?.neutral == true && lab.whyNotIntoGrading == "还没有去漏光",
      "a frame opened in 去漏光 is the picture as ② leaves it, and waits for a repair before it can go into ③")
    // Its turn and crop are ②'s: turning or cutting it here, by the assistant too, is refused.
    let (turnedBefore, cropBefore) = (lab.params.rotation, lab.params.crop)
    lab.rotate(by: 90)
    lab.setCrop(LeakCrop(x: 0.1, y: 0.1, w: 0.8, h: 0.6))
    let refusedTurn = MCPTools.call("leak_rotate", ["quarter_turns": 1], model: m)
    try check(lab.params.rotation == turnedBefore && lab.params.crop == cropBefore && refusedTurn.isError
      && lab.whyNotIntoGrading == "还没有去漏光",
      "a frame of the roll is not turned or cropped on the 去漏光 page, nor by the assistant: that is ②'s, and it can still go into ③")
    lab.addRegion(x: 0.32, y: 0.4, rx: 0.14, ry: 0.17)
    lab.setReference(LeakPoint(x: 0.8, y: 0.75))
    lab.wait()
    lab.start()
    lab.wait()
    settle()
    try check(lab.repaired && lab.whyNotIntoGrading == nil, "with a region it is repaired, and can go into ③")
    try check(m.leakJobs[id] == lab.job.map { LeakLab.FrameJob(id: $0.id, neutral: true, modified: $0.modified!) },
      "the job written marks its frame at once: ③ can point to a repair it does not use yet")
    let unrepaired = try rendered(try m.source(for: m.frames[0], full: true), m.frames[0].adjustments)
    m.applyLeakRepair()
    lab.wait()
    for _ in 0..<50 where m.frames[0].adjustments.leakFix == nil { settle(0.1) }
    let fix = m.frames[0].adjustments.leakFix
    try check(fix.map { FileManager.default.fileExists(atPath: $0.file) && $0.file.hasPrefix(roll.path) } == true
      && m.page == .convert && m.convertStep == .grade,
      "用到 ③ 调色 keeps the repair in the roll's Repairs folder, sets it on the frame and goes to ③")
    try check((fix?.meanError ?? 99) < 1.5, String(format: "the correction gives 去漏光's repair back to within %.2f / 255", fix?.meanError ?? -1))
    let repaired = try rendered(try m.source(for: m.frames[0], full: true), m.frames[0].adjustments)
    let was = pixels(unrepaired), now = pixels(repaired)
    func change(_ x: Int, _ y: Int) -> Int {
      let i = (y * repaired.width + x) * 4
      return (0..<3).map { abs(Int(now[i + $0]) - Int(was[i + $0])) }.max()!
    }
    try check(change(95, 80) > 6 && change(250, 170) <= 1,
      "the frame's own conversion has the repair in the patch (\(change(95, 80))) and nothing far from it (\(change(250, 170)))")
    // Graded after it: ③'s exposure works on the repaired picture.
    m.selectedID = id
    m.change { $0.exposure = 0.5 }
    try check(m.frames[0].adjustments.leakFix == fix, "grading in ③ keeps the repair")
    edits.undo()
    edits.undo()
    try check(m.frames[0].adjustments.leakFix == nil, "⌘Z takes the repair out again")
    edits.redo()
    try check(m.frames[0].adjustments.leakFix == fix, "and ⇧⌘Z puts it back")
    m.removeLeakRepair(id)
    try check(m.frames[0].adjustments.leakFix == nil, "去掉修复 takes it out")
    edits.undo()
    // Synced or pasted settings never carry another frame's repair.
    m.frames.append(FilmFrame(name: "02", rect: .full, format: "135"))
    m.selectedID = id
    m.applyToRoll()
    try check(m.frames[0].adjustments.leakFix == fix && m.frames[1].adjustments.leakFix == nil, "同步 leaves each frame's own repair, and gives none to another")

    // Jobs kept before: found when the roll opens, the latest of a frame's, and only this roll's.
    let jobs = lab.root, path = file.path, other = UUID()
    func keep(_ frame: UUID, project: String, neutral: Bool?, ago: TimeInterval, base: Bool = true) throws -> String {
      var o = LeakJob.Origin(project: project, frame: frame, frameName: "02", adjustments: Adjustments(), profile: profile)
      o.neutral = neutral
      var j = LeakJob(id: UUID().uuidString.lowercased(), sourceName: "第 02 张", origin: o)
      j.base = base ? "base.tif" : nil
      j.modified = Date().addingTimeInterval(-ago)
      let folder = jobs.appendingPathComponent(j.id)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try JSONEncoder().encode(j).write(to: folder.appendingPathComponent("job.json"))
      return j.id
    }
    let graded = try keep(other, project: path, neutral: nil, ago: 86_400)
    _ = try keep(other, project: path, neutral: true, ago: 90_000)
    _ = try keep(id, project: path, neutral: true, ago: 3_600)
    _ = try keep(UUID(), project: path, neutral: true, ago: 0, base: false)
    _ = try keep(UUID(), project: path + "-other", neutral: true, ago: 0)
    let kept = LeakLab.frameJobs(in: jobs, project: path)
    try check(kept.count == 2 && kept[other]?.id == graded && kept[other]?.neutral == false && kept[id]?.id == lab.job?.id,
      "a roll's kept jobs: the latest of each frame, an old one of the graded picture told apart; none of another roll, none without a picture")
    try check(lab.existing(project: path, frame: other) == graded, "去漏光 opens a frame's latest job")
    m.loadProject(file)
    for _ in 0..<50 where m.leakJobs.count < 2 { settle(0.1) }
    try check(m.leakJobs == kept, "opening the roll finds its frames' jobs again, off the main thread")
    let bare = FilmFrame(name: "02", rect: .full, format: "135")
    var withFix = bare
    withFix.adjustments.leakFix = fix
    try check(MCPTools.leakState(withFix, job: kept[id])?["state"] as? String == "applied"
      && MCPTools.leakState(bare, job: kept[other])?["state"] as? String == "old_job_of_graded_picture"
      && MCPTools.leakState(bare, job: kept[id])?["state"] as? String == "job_not_applied" && MCPTools.leakState(bare, job: nil) == nil,
      "the assistant's state tells a repair used, a job not used yet and an old job of the graded picture apart")

    // The colour map between two renderings of one picture (`LeakGradeMap`): a known grade undone,
    // colours the picture never showed taken along, and another picture not taken for this one.
    func leakPicture(_ w: Int, _ h: Int, _ f: (Double, Double) -> SIMD3<Double>) -> LeakImage {
      var d = [UInt16](repeating: 0, count: w * h * 3)
      for y in 0..<h { for x in 0..<w {
        let q = f(Double(x) / Double(w - 1), Double(y) / Double(h - 1))
        for c in 0..<3 { d[(y * w + x) * 3 + c] = UInt16((min(max(q[c], 0), 1) * 65535).rounded()) }
      } }
      return LeakImage(width: w, height: h, data: d)
    }
    let scene = leakPicture(240, 160) { x, y in
      SIMD3(0.2 + 0.6 * x, 0.15 + 0.5 * y + 0.1 * sin(x * 9), 0.3 + 0.4 * (1 - x) * y + 0.05 * cos(y * 13))
    }
    func grade(_ q: SIMD3<Double>) -> SIMD3<Double> {
      let warm = SIMD3(1.08, 1.0, 0.9) * q, grey = SIMD3(repeating: (warm.x + warm.y + warm.z) / 3)
      let s = grey + 1.3 * (warm - grey)
      return SIMD3(pow(max(s.x, 0), 0.85), pow(max(s.y, 0), 0.85), pow(max(s.z, 0), 0.85))
    }
    func regraded(_ image: LeakImage) -> LeakImage { leakPicture(image.width, image.height) { x, y in grade(image.at(x, y)) } }
    func apart(_ a: LeakImage, _ b: LeakImage, where wanted: (Double, Double) -> Bool = { _, _ in true }) -> Double {
      var sum = 0.0, n = 0.0
      for j in 0..<100 { for i in 0..<100 {
        let u = (Double(i) + 0.5) / 100, v = (Double(j) + 0.5) / 100
        guard wanted(u, v) else { continue }
        let d = a.at(u, v) - b.at(u, v)
        sum += (abs(d.x) + abs(d.y) + abs(d.z)) / 3
        n += 1
      } }
      return sum / max(1, n) * 255
    }
    let undo = LeakGradeMap.fit(from: regraded(scene), to: scene)
    try check(undo.usable && undo.apart * 255 > 8 && undo.error * 255 < 1,
      String(format: "a grade is undone by the map fitted between the graded picture and the plain one (%.1f / 255 apart, %.2f after)", undo.apart * 255, undo.error * 255))
    // A reference: the picture cleaned, its top a sky of a colour the picture never had.
    let clean = leakPicture(240, 160) { x, y in y < 0.3 ? SIMD3(0.35, 0.5, 0.75) : scene.at(x, y) }
    let back = undo.apply(regraded(clean))
    let skyMissed = apart(back, clean) { _, v in v < 0.28 }, restMissed = apart(back, clean) { _, v in v > 0.32 }
    try check(restMissed < 1 && skyMissed < 4,
      String(format: "a clean reference of the graded picture is taken back to the plain one's colours (%.2f / 255; %.1f where its colours were never in the picture)", restMissed, skyMissed))
    // A photograph's colours come back all over it, unlike `scene`'s, which a colour table could
    // even take for a turned picture: grain on it, then turned.
    func grain(_ x: Double, _ y: Double) -> Double { let s = sin(x * 3117.6 + y * 12_517.3) * 43_758.5453; return s - s.rounded(.down) }
    let grainy = leakPicture(240, 160) { x, y in scene.at(x, y) + SIMD3(repeating: 0.2 * (grain(x, y) - 0.5)) }
    let mirrored = leakPicture(240, 160) { x, y in grainy.at(1 - x, y) }
    let wrong = LeakGradeMap.fit(from: regraded(mirrored), to: grainy), same = LeakGradeMap.fit(from: scene, to: scene)
    try check(wrong.verdict == .mismatch && same.verdict == .slight && same.apart < LeakGradeMap.negligible,
      String(format: "nor is the map used between two different pictures (%.1f / 255 after), or two the same", wrong.error * 255))

    // An old job of the graded picture whose reference is a clean version of it, reloaded from
    // ②'s result: the reference is taken to ②'s colours, the old one kept; ⌘Z puts it all back.
    let oldLab = LeakLab(root: root.appendingPathComponent("old-jobs"))
    oldLab.renderFrame = { [unowned m] in try m.leakPositive($0) }
    oldLab.renderNeutral = { [unowned m] in try m.leakNeutral($0, longest: $1) }
    let labEdits = UndoManager()
    labEdits.groupsByEvent = false
    oldLab.undoManager = labEdits
    m.leak = oldLab
    guard var gradedOrigin = m.leakOrigin(m.frames[0]), let plainOrigin = m.leakOrigin(m.frames[0]) else {
      throw DeskError.message("FAIL: the roll's frame has no 去漏光 origin")
    }
    gradedOrigin.neutral = nil
    gradedOrigin.adjustments.exposure = 0.3
    gradedOrigin.adjustments.saturation = 1.35
    gradedOrigin.adjustments.warmth = 0.25
    oldLab.open(origin: gradedOrigin)
    oldLab.wait()
    settle()
    let placeholder = root.appendingPathComponent("placeholder.png")
    try pipe.savePNG(negative(30, 20), to: placeholder)
    oldLab.importReference(placeholder)
    oldLab.wait()
    settle()
    guard let oldFolder = oldLab.folder, let gradedBase = oldLab.job?.base else { throw DeskError.message("FAIL: the old job was not kept") }
    // The graded picture itself as the reference: a clean version of a picture without a leak.
    oldLab.importReference(oldFolder.appendingPathComponent(gradedBase))
    oldLab.wait()
    settle()
    let firstGuide = oldLab.job?.guide
    oldLab.reload(origin: plainOrigin)
    oldLab.wait()
    settle()
    oldLab.wait()
    guard let reloaded = oldLab.job, let newBase = reloaded.base, let newGuide = reloaded.guide, let oldGuide = firstGuide else {
      throw DeskError.message("FAIL: the reloaded job has no base or reference")
    }
    let plainBase = try LeakImage(contentsOf: oldFolder.appendingPathComponent(newBase))
    let mappedGuide = try LeakImage(contentsOf: oldFolder.appendingPathComponent(newGuide))
    let gradedGuide = try LeakImage(contentsOf: oldFolder.appendingPathComponent(oldGuide))
    let wasApart = apart(gradedGuide, plainBase), nowApart = apart(mappedGuide, plainBase)
    try check(reloaded.origin?.neutral == true && newGuide.hasPrefix("guide-regraded-") && newGuide != oldGuide && wasApart > 5 && nowApart < 1.5,
      String(format: "an old job reloaded from ② takes its reference to ②'s colours (%.1f / 255 from ②'s picture, was %.1f), the old reference kept", nowApart, wasApart))
    labEdits.undo()
    settle()
    try check(oldLab.job?.guide == firstGuide && oldLab.job?.origin?.neutral != true && oldLab.job?.base == gradedBase,
      "⌘Z puts the job, its picture and its reference back as they were")
  }
}
