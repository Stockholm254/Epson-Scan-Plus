import CoreImage
import Foundation

/// ② 去色罩 and ③ 调色 kept apart: each step's 重置, 同步 and 粘贴 act on its own settings only,
/// and a tool of the other step takes the window there rather than working where it is.
enum StepTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("steps"), preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    model.frames = (1...3).map { FilmFrame(name: "0\($0)", rect: .full, format: "135") }
    let ids = model.frames.map(\.id)
    // A frame with settings of both steps: its base picked and its region drawn (②), its
    // exposure and curves (③).
    func both(_ i: Int) {
      model.frames[i].adjustments.base = RGB(r: 0.5, g: 0.3, b: 0.2)
      model.frames[i].adjustments.inputGamma = 1.8
      model.frames[i].adjustments.exposure = 0.5
      model.frames[i].adjustments.saturation = 1.3
      model.frames[i].adjustments.curves = ToneCurves()
    }
    both(0)
    model.selectedID = ids[0]
    model.page = .convert

    // The split itself.
    var a = model.frames[0].adjustments, b = Adjustments()
    b.takeGrading(from: a)
    try check(b.exposure == 0.5 && b.saturation == 1.3 && b.base == nil && b.inputGamma == Adjustments().inputGamma,
      "③'s settings are the grading: exposure, colour, curves; not the base or how the film is read")
    a.takeDemasking(from: Adjustments())
    try check(a.exposure == 0.5 && a.base == nil && a.inputGamma == Adjustments().inputGamma, "②'s are the rest")

    // ② shows the frame de-masked only: its base and how the film is read, none of ③'s grading
    // or a light-leak repair; ③ as it is set.
    model.frames[0].adjustments.leakFix = LeakFix(file: "/nonexistent.leakfix", job: "j", made: Date(), meanError: 0.4, worstError: 1)
    model.convertStep = .demask
    let inDemasking = model.asShown(model.frames[0]).adjustments
    model.convertStep = .grade
    let inGrading = model.asShown(model.frames[0]).adjustments
    model.frames[0].adjustments.leakFix = nil
    try check(model.showsDemasked == false && inDemasking.exposure == 0 && inDemasking.saturation == Adjustments().saturation
      && inDemasking.curves == nil && inDemasking.leakFix == nil && inDemasking.base == RGB(r: 0.5, g: 0.3, b: 0.2)
      && inDemasking.inputGamma == 1.8 && inDemasking.autoWhiteBalance == Adjustments().autoWhiteBalance
      && inGrading.exposure == 0.5 && inGrading.saturation == 1.3 && inGrading.leakFix != nil,
      "② shows the frame de-masked only (its base and reading, no grading, no repair), ③ as it is graded")

    // 重置 in ③ leaves ②'s, in ② leaves ③'s.
    model.convertStep = .grade
    try check(model.stepScope == .grading, "in ③ the keys act on the grading")
    model.resetAdjustments(model.stepScope)
    try check(model.frames[0].adjustments.exposure == 0 && model.frames[0].adjustments.curves == nil
      && model.frames[0].adjustments.base == RGB(r: 0.5, g: 0.3, b: 0.2) && model.frames[0].adjustments.inputGamma == 1.8,
      "③'s 重置 sets the grading back and leaves the base and how the film is read")
    edits.undo()
    model.convertStep = .demask
    try check(model.stepScope == .demasking, "in ② on the de-masking")
    model.resetAdjustments(model.stepScope)
    try check(model.frames[0].adjustments.base == nil && model.frames[0].adjustments.exposure == 0.5 && model.frames[0].adjustments.saturation == 1.3,
      "②'s 重置 sets the base back and leaves the grading")
    edits.undo()

    // 同步 and 粘贴 the same way.
    model.convertStep = .grade
    model.syncSettings()
    try check(model.frames[1].adjustments.exposure == 0.5 && model.frames[1].adjustments.base == nil && model.frames[2].adjustments.inputGamma == Adjustments().inputGamma,
      "③'s 同步 gives the roll the grading, not the base")
    edits.undo()
    model.convertStep = .demask
    model.frames[0].adjustments.flipHorizontal = true
    model.syncSettings()
    try check(model.frames[1].adjustments.base == RGB(r: 0.5, g: 0.3, b: 0.2) && model.frames[1].adjustments.exposure == 0
      && model.frames[1].adjustments.flipHorizontal != true,
      "②'s 同步 gives the roll the base, not the grading, nor how the frame shown faces")
    model.frames[0].adjustments.flipHorizontal = nil
    edits.undo()
    model.copySettings()
    model.selectedID = ids[2]
    model.convertStep = .grade
    model.pasteSettings(model.stepScope)
    try check(model.frames[2].adjustments.saturation == 1.3 && model.frames[2].adjustments.base == nil, "③'s 粘贴 pastes the grading")
    edits.undo()
    model.pasteSettings()
    try check(model.frames[2].adjustments.saturation == 1.3 && model.frames[2].adjustments.base == RGB(r: 0.5, g: 0.3, b: 0.2),
      "and called from elsewhere (an assistant's tools, the tests) it pastes everything, as before")

    // The crop kept to a ratio: the largest box of it inside, about the middle, in its own orientation.
    let squareIn32 = AppModel.fitted(CGRect(x: 0, y: 0, width: 1, height: 1), long: 1, aspect: 1.5)
    let portrait45 = AppModel.fitted(CGRect(x: 0, y: 0, width: 1, height: 1), long: 1.25, aspect: 1)
    try check(abs(squareIn32.width - 2.0 / 3) < 1e-9 && squareIn32.height == 1 && abs(squareIn32.midX - 0.5) < 1e-9
      && abs(portrait45.width - 1) < 1e-9 && abs(portrait45.height - 0.8) < 1e-9 && abs(portrait45.midY - 0.5) < 1e-9
      && AppModel.CropRatio.free.long == nil && AppModel.CropRatio.twoThree.long == 1.5,
      "a crop kept to a ratio is the largest box of it inside, about the middle: 1:1 in a 3:2 picture, 5:4 on a square one")
    // 选择性粘贴: the groups together are the step's settings, and only those ticked are pasted.
    var full = Adjustments()
    (full.autoWhiteBalance, full.neutralSample) = (false, RGB(r: 0.3, g: 0.4, b: 0.5))
    (full.neutralPicked, full.warmth, full.tint) = (NormalRect(x: 0.4, y: 0.4, width: 0.01, height: 0.01), 0.1, -0.1)
    (full.shadowWarmth, full.shadowTint, full.sharedBalance, full.sharedLevels) = (0.2, -0.2, true, true)
    full.rollPrint = RollPrint(balance: RGB(r: 1, g: 1, b: 1), gain: RGB(r: 1, g: 1, b: 1), low: 0.1, high: 2)
    (full.exposure, full.contrast, full.highlights, full.pressHighlights, full.shadows) = (0.5, 1.2, -0.3, 0.2, 0.3)
    (full.whites, full.blacks, full.autoLevels) = (-0.1, 0.1, false)
    (full.saturation, full.colourNoise, full.softEnds, full.curves, full.sharpening) = (1.3, 0.5, true, ToneCurves(), 0.4)
    full.curves?.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)])
    (full.texture, full.clarity, full.dehaze, full.vibrance) = (0.2, 0.3, 0.1, 0.4)
    full[mixer: 5, kind: 1] = -0.5
    full.grading = ColourGrading(shadowHue: 220, shadowAmount: 0.3)
    (full.base, full.inputGamma, full.filmEdges) = (RGB(r: 0.5, g: 0.3, b: 0.2), 1.0, .rebate)
    var grouped = Adjustments(), whole = Adjustments(), rest = Adjustments()
    for g in SettingsGroup.of(.grading) { g.take(&grouped, from: full) }
    whole.takeGrading(from: full)
    SettingsGroup.otherGrading.take(&rest, from: full)
    try check(grouped == whole && rest == Adjustments() && SettingsGroup.of(.grading).allSatisfy { $0 == .otherGrading || $0.isSet(in: full) }
      && SettingsGroup.exposure.summary(of: full) == "+0.50 EV" && SettingsGroup.whitesBlacks.summary(of: full).hasPrefix("白色 −0.10")
      && { var straight = Adjustments(); straight.curves = ToneCurves(); return !SettingsGroup.curves.isSet(in: straight) }(),
      "选择性粘贴's groups together are ③'s settings, each grading setting in a named one (其他调色 empty), each told in a few words; straight curves are none")
    model.frames[1].adjustments = Adjustments()
    model.frames[1].adjustments.saturation = 0.8
    model.selectedID = ids[0]
    model.convertStep = .grade
    model.copySettings()
    model.selectedID = ids[1]
    model.pasteSettings(model.stepScope, only: [.exposure, .curves, .base])
    let picked = model.frames[1].adjustments
    try check(picked.exposure == 0.5 && picked.curves != nil && picked.saturation == 0.8 && picked.base == nil
      && model.status.contains("曝光、曲线"),
      "选择性粘贴 in ③ pastes the groups ticked of the grading alone, the frame's other settings kept")
    edits.undo()
    model.convertStep = .demask
    model.pasteSettings(model.stepScope, only: [.base, .exposure])
    try check(model.frames[1].adjustments.base == RGB(r: 0.5, g: 0.3, b: 0.2) && model.frames[1].adjustments.exposure == 0
      && model.frames[1].adjustments.inputGamma == Adjustments().inputGamma && model.frames[1].adjustments.saturation == 0.8,
      "and in ② the ticked of the de-masking: the base fine-tuning, not how the film is read, nor ③'s exposure")
    edits.undo()
    try check(model.frames[1].adjustments.base == nil && model.frames[1].adjustments.saturation == 0.8, "one edit, undone with ⌘Z")
    model.pasteChosen = [.exposure, .curves]
    try check(model.preferences.pasteLeftOut.contains("whiteBalance") && !model.preferences.pasteLeftOut.contains("exposure")
      && model.pasteChosen.contains(.exposure) && !model.pasteChosen.contains(.saturation) && !model.pasteGroups(.grading).contains(.otherGrading),
      "the sheet remembers what was left unticked, so a group added later starts ticked; 其他调色 listed only when there is some")

    // 选择性同步: the frame shown's ticked settings alone, to the roll.
    model.selectedID = ids[0]
    model.convertStep = .grade
    let exposure1 = model.frames[1].adjustments.exposure
    model.syncSettings(only: [.saturation])
    try check(model.frames[1].adjustments.saturation == 1.3 && model.frames[2].adjustments.saturation == 1.3
      && model.frames[1].adjustments.exposure == exposure1 && model.status.contains("饱和度") && model.status.contains("本卷"),
      "选择性同步 gives the roll the frame shown's ticked settings alone")
    edits.undo()

    // 调色预设: the frame shown's grading of the groups ticked, kept under a name without the grey
    // picked on its picture, the roll's own shared print left out; given to another in one step.
    model.selectedID = ids[0]
    model.convertStep = .grade
    model.frames[0].adjustments.neutralSample = RGB(r: 0.3, g: 0.4, b: 0.5)
    model.frames[0].adjustments.warmth = 0.15
    model.saveGradingPreset(named: "暖一点", groups: [.whiteBalance, .saturation, .rollShared])
    model.frames[0].adjustments.neutralSample = nil
    model.frames[0].adjustments.warmth = 0
    let preset = model.preferences.gradingPresets.last
    let kept = Preferences(defaults: defaults).gradingPresets
    model.selectedID = ids[1]
    model.frames[1].adjustments = Adjustments()
    model.frames[1].adjustments.exposure = 0.7
    if let preset { model.applyGradingPreset(preset) }
    let given = model.frames[1].adjustments
    try check(preset?.groups == ["whiteBalance", "saturation"] && preset?.adjustments.neutralSample == nil && kept == model.preferences.gradingPresets
      && given.warmth == 0.15 && given.saturation == 1.3 && given.exposure == 0.7 && given.neutralSample == nil && model.status.contains("暖一点"),
      "a 调色预设 keeps the ticked grading without the grey picked on its picture, and gives just that to another frame")
    edits.undo()
    // And by the assistant's tools: listed, given by name (in part), a frame's snapshot taken and
    // gone back to.
    func reply(_ name: String, _ arguments: [String: Any] = [:]) -> String {
      (MCPTools.call(name, arguments, model: model).content.first?["text"] as? String) ?? ""
    }
    let listed = reply("list_grading_presets")
    let applied = reply("apply_grading_preset", ["name": "暖"])
    let warmed = model.frames[1].adjustments.warmth == 0.15
    edits.undo()
    _ = reply("take_snapshot", ["name": "试一下"])
    model.frames[1].adjustments.saturation = 0.5
    let back = reply("restore_snapshot", ["name": "试"])
    let shots = reply("restore_snapshot")
    try check(listed.contains("暖一点") && listed.contains("白平衡") && applied.contains("暖一点") && warmed
      && back.contains("试一下") && model.frames[1].adjustments.saturation == Adjustments().saturation && shots.contains("试一下"),
      "the assistant lists the presets, applies one by name, takes a snapshot of the frame's grading and goes back to it")
    edits.undo()
    _ = reply("take_snapshot")
    _ = reply("take_snapshot")
    let unnamed = model.shownSnapshots.map(\.name)
    try check(unnamed.count == 3 && Set(unnamed).count == 3 && unnamed.dropFirst().allSatisfy { $0.hasPrefix("快照 ") },
      "snapshots taken without a name in the same minute are numbered, not put over one another: \(unnamed)")
    model.gradeSnapshots = [:]
    model.saveGradingPreset(named: "暖一点", groups: [.exposure])
    let replaced = model.preferences.gradingPresets
    model.deleteGradingPreset(replaced[0])
    try check(model.frames[1].adjustments.warmth == 0 && replaced.count == 1 && replaced[0].groups == ["exposure"]
      && model.status.contains("删除") && model.preferences.gradingPresets.isEmpty,
      "undone in one step; a preset saved under the same name replaces it, and one deleted is gone")

    // 粘贴上一张: the frame shown before gives its settings, nothing copied first.
    model.convertStep = .grade
    model.selectedID = ids[0]
    model.selectedID = ids[2]
    model.frames[2].adjustments = Adjustments()
    model.pastePrevious(model.stepScope)
    try check(model.previousFrame?.id == ids[0] && model.frames[2].adjustments.exposure == 0.5 && model.frames[2].adjustments.saturation == 1.3
      && model.frames[2].adjustments.base == nil && model.status.contains("上一张（第 01 张）"),
      "粘贴上一张 gives the frame shown the grading of the frame shown before it, not its base")
    edits.undo()

    // White balance as Lightroom's menu: 原片, 自动, 自定义; a grey picked or 冷暖 moved is 自定义,
    // and 原片 or 自动 chosen sets 冷暖 and 绿 / 洋红 back to 0 and lets the grey go.
    model.selectedID = ids[1]
    model.frames[1].adjustments = Adjustments()
    let wasAuto = model.balanceMode
    model.change("冷暖") { $0.warmth = 0.3 }
    let movedIsCustom = model.balanceMode == .custom
    model.setBalanceMode(.asShot)
    let asShot = model.frames[1].adjustments
    model.setNeutral(RGB(r: 0.4, g: 0.5, b: 0.6))
    let pickedIsCustom = model.balanceMode == .custom
    model.setBalanceMode(.auto)
    let auto = model.frames[1].adjustments
    model.setFilmBase(RGB(r: 0.8, g: 0.5, b: 0.3))
    try check(wasAuto == .auto && movedIsCustom && !asShot.autoWhiteBalance && asShot.warmth == 0 && pickedIsCustom
      && auto.autoWhiteBalance && auto.neutralSample == nil && auto.warmth == 0 && model.balanceMode == .auto,
      "white balance as Lightroom's: 自动 by default, 冷暖 moved or a grey picked is 自定义, 原片 and 自动 set it back; picking the base leaves it 自动")
    edits.undo()

    // A tool of the other step takes the window there.
    model.convertStep = .demask
    model.useTool(.neutral)
    try check(model.convertStep == .grade && model.tool == .neutral, "the grey picker in ② takes the window to ③, where it belongs")
    // ③'s own crop, as Lightroom's in Develop: the picture cropped and turned inside the frame ②
    // cut, the de-masking reading ②'s, so the colours stay.
    model.selectedID = ids[1]
    model.frames[1].adjustments = Adjustments()
    model.useTool(.crop)
    let composingThere = model.convertStep == .grade && model.tool == .crop && model.composing && !model.editingSingle && model.singleView
    guard let aspect = model.selected.flatMap(model.frameAspect) else { throw DeskError.message("FAIL: no frame shape") }
    let colours = model.analysisKey(model.frames[1])
    // Wide, near the picture's edge: it does not fit once the picture turns.
    let box = NormalRect(x: 0.02, y: 0.05, width: 0.9, height: 0.6)
    model.setComposition(box)
    try check(composingThere && model.frames[1].adjustments.composition == box && model.analysisKey(model.frames[1]) == colours,
      "the crop in ③ stays in ③ and crops the picture there, the de-masking (its analysis) as it was")
    // Turned, the box stays on the picture: of its shape about its middle, as large as fits.
    model.straighten(10)
    let turned = model.frames[1].adjustments.composition
    let fitsTurned = turned.map { ImageGeometry.fits($0, degrees: 10, aspect: aspect) } == true
    let sameShape = turned.map { abs($0.width / $0.height - box.width / box.height) < 1e-3 && $0.width < box.width } == true
    try check(fitsTurned && sameShape && !ImageGeometry.fits(box, degrees: 10, aspect: aspect),
      "turned 10°, ③'s crop is kept on the picture, of its shape about its middle: \(turned.map { "\($0)" } ?? "-")")
    // The mapping both ways, and the picture's own box with none.
    let p = CGPoint(x: 0.3, y: 0.6)
    let there = ImageGeometry.straightened(p, degrees: 10, aspect: aspect, composition: turned)
    let returned = ImageGeometry.straightened(there, degrees: 10, aspect: aspect, inverse: true, composition: turned)
    let keptBox = ImageGeometry.composed(nil, degrees: 10, aspect: aspect)
    let k = ImageGeometry.keep(10, aspect: aspect)
    try check(hypot(returned.x - p.x, returned.y - p.y) < 1e-9 && keptBox.map { abs($0.width - k) < 1e-12 && abs($0.x - (0.5 - k / 2)) < 1e-12 } == true,
      "a point maps through ③'s crop and back, and with none the largest box of the picture's shape is kept as before")
    // The pipeline cuts the same box out of the turned picture.
    let picture = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 1200 / aspect))
    let cut = ImagePipeline.straightened(picture, degrees: 10, composition: turned).extent
    if let o = turned {
      try check(abs(cut.width - CGFloat(o.width) * 1200) <= 2 && abs(cut.height - CGFloat(o.height) * 1200 / CGFloat(aspect)) <= 2,
        "the picture is cut to ③'s crop: \(Int(cut.width)) × \(Int(cut.height))")
    }
    model.swapCompositionOrientation()
    let swapped = model.frames[1].adjustments.composition
    model.resetComposition()
    try check(swapped.map { s in turned.map { t in (s.width * aspect > s.height) != (t.width * aspect > t.height) } ?? false } == true
      && model.frames[1].adjustments.composition == nil && model.frames[1].adjustments.angle == nil,
      "X swaps the crop's long side and short; 还原 takes it and the straightening back")
    // ③'s crop key on the picture's tool bar: back on the light table the crop ends (there the tool
    // would draw new frames), and with no frame chosen there is none to crop.
    model.useTool(.crop)
    model.singleView = false
    let endedOnTable = model.tool == .select
    let chosen = model.selectedID
    model.selectedID = nil
    model.useTool(.crop)
    try check(endedOnTable && model.tool == .select && !model.singleView,
      "③'s crop ends on the light table, and with no frame chosen its key does nothing")
    model.selectedID = chosen
    model.useTool(.crop)
    // ②'s crop is the frame's extent on the film, as before.
    model.convertStep = .demask
    try check(model.tool == .select, "and a step's tool is put down when the window leaves it")
    model.useTool(.crop)
    try check(model.convertStep == .demask && model.tool == .crop && !model.composing && model.editingSingle,
      "the crop in ② crops the frame on the film, on its surroundings as they lie")
    model.useTool(.select)
    // A base read on one linear copy, as it reads on another shot a stop more: twice as bright;
    // with an exposure not known, as read.
    var shotA = FilmFrame(name: "A", rect: .full, format: "120"), shotB = FilmFrame(name: "B", rect: .full, format: "120")
    for (i, path) in ["/tmp/epscan-test-a.tif", "/tmp/epscan-test-b.tif"].enumerated() {
      var f = i == 0 ? shotA : shotB
      (f.sensorRead, f.sourcePath, f.adjustments.inputGamma) = (true, path, 1)
      if i == 0 { shotA = f } else { shotB = f }
    }
    model.setCopyExposure("/tmp/epscan-test-a.tif", 1.0 / 60 * 100 / 64)
    model.setCopyExposure("/tmp/epscan-test-b.tif", 1.0 / 30 * 100 / 64)
    let read = RGB(r: 0.4, g: 0.3, b: 0.2), onB = model.base(read, readOn: shotA, as: shotB)
    model.setCopyExposure("/tmp/epscan-test-b.tif", nil)
    let unknown = model.base(read, readOn: shotA, as: shotB)
    try check(abs(onB.r - 0.8) < 1e-9 && abs(onB.b - 0.4) < 1e-9 && unknown == read,
      "a base borrowed by a copy shot a stop more reads twice as bright there; with its exposure unknown, as read")
  }
}
