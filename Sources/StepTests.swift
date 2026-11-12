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
    // A frame with settings of both steps: its base fine-tuned and its region drawn (②), its
    // exposure and curves (③).
    func both(_ i: Int) {
      model.frames[i].adjustments.baseFine = RGB(r: 0.1, g: 0, b: -0.1)
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
    try check(b.exposure == 0.5 && b.saturation == 1.3 && b.baseFine == nil && b.inputGamma == Adjustments().inputGamma,
      "③'s settings are the grading: exposure, colour, curves; not the base or how the film is read")
    a.takeDemasking(from: Adjustments())
    try check(a.exposure == 0.5 && a.baseFine == nil && a.inputGamma == Adjustments().inputGamma, "②'s are the rest")

    // ② shows the frame de-masked only: its base and how the film is read, none of ③'s grading
    // or a light-leak repair; ③ as it is set.
    model.frames[0].adjustments.leakFix = LeakFix(file: "/nonexistent.leakfix", job: "j", made: Date(), meanError: 0.4, worstError: 1)
    model.convertStep = .demask
    let inDemasking = model.asShown(model.frames[0]).adjustments
    model.convertStep = .grade
    let inGrading = model.asShown(model.frames[0]).adjustments
    model.frames[0].adjustments.leakFix = nil
    try check(model.showsDemasked == false && inDemasking.exposure == 0 && inDemasking.saturation == Adjustments().saturation
      && inDemasking.curves == nil && inDemasking.leakFix == nil && inDemasking.baseFine == RGB(r: 0.1, g: 0, b: -0.1)
      && inDemasking.inputGamma == 1.8 && inDemasking.autoWhiteBalance == Adjustments().autoWhiteBalance
      && inGrading.exposure == 0.5 && inGrading.saturation == 1.3 && inGrading.leakFix != nil,
      "② shows the frame de-masked only (its base and reading, no grading, no repair), ③ as it is graded")

    // 重置 in ③ leaves ②'s, in ② leaves ③'s.
    model.convertStep = .grade
    try check(model.stepScope == .grading, "in ③ the keys act on the grading")
    model.resetAdjustments(model.stepScope)
    try check(model.frames[0].adjustments.exposure == 0 && model.frames[0].adjustments.curves == nil
      && model.frames[0].adjustments.baseFine == RGB(r: 0.1, g: 0, b: -0.1) && model.frames[0].adjustments.inputGamma == 1.8,
      "③'s 重置 sets the grading back and leaves the base and how the film is read")
    edits.undo()
    model.convertStep = .demask
    try check(model.stepScope == .demasking, "in ② on the de-masking")
    model.resetAdjustments(model.stepScope)
    try check(model.frames[0].adjustments.baseFine == nil && model.frames[0].adjustments.exposure == 0.5 && model.frames[0].adjustments.saturation == 1.3,
      "②'s 重置 sets the base back and leaves the grading")
    edits.undo()

    // 同步 and 粘贴 the same way.
    model.convertStep = .grade
    model.syncSettings()
    try check(model.frames[1].adjustments.exposure == 0.5 && model.frames[1].adjustments.baseFine == nil && model.frames[2].adjustments.inputGamma == Adjustments().inputGamma,
      "③'s 同步 gives the roll the grading, not the base")
    edits.undo()
    model.convertStep = .demask
    model.frames[0].adjustments.flipHorizontal = true
    model.syncSettings()
    try check(model.frames[1].adjustments.baseFine == RGB(r: 0.1, g: 0, b: -0.1) && model.frames[1].adjustments.exposure == 0
      && model.frames[1].adjustments.flipHorizontal != true,
      "②'s 同步 gives the roll the base, not the grading, nor how the frame shown faces")
    model.frames[0].adjustments.flipHorizontal = nil
    edits.undo()
    model.copySettings()
    model.selectedID = ids[2]
    model.convertStep = .grade
    model.pasteSettings(model.stepScope)
    try check(model.frames[2].adjustments.saturation == 1.3 && model.frames[2].adjustments.baseFine == nil, "③'s 粘贴 pastes the grading")
    edits.undo()
    model.pasteSettings()
    try check(model.frames[2].adjustments.saturation == 1.3 && model.frames[2].adjustments.baseFine == RGB(r: 0.1, g: 0, b: -0.1),
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
    (full.autoWhiteBalance, full.manualBalance, full.neutralSample) = (false, RGB(r: 1.1, g: 1, b: 0.9), RGB(r: 0.3, g: 0.4, b: 0.5))
    (full.neutralPicked, full.warmth, full.tint) = (NormalRect(x: 0.4, y: 0.4, width: 0.01, height: 0.01), 0.1, -0.1)
    (full.shadowWarmth, full.shadowTint, full.sharedBalance, full.sharedLevels) = (0.2, -0.2, true, true)
    full.rollPrint = RollPrint(balance: RGB(r: 1, g: 1, b: 1), gain: RGB(r: 1, g: 1, b: 1), low: 0.1, high: 2)
    (full.exposure, full.contrast, full.highlights, full.pressHighlights, full.shadows) = (0.5, 1.2, -0.3, 0.2, 0.3)
    (full.whites, full.blacks, full.autoLevels, full.black, full.white, full.midtone) = (-0.1, 0.1, false, 0.02, 0.95, 1.1)
    (full.saturation, full.colourNoise, full.softEnds, full.curves, full.sharpening) = (1.3, 0.5, true, ToneCurves(), 0.4)
    full.curves?.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)])
    (full.texture, full.clarity, full.dehaze, full.vibrance) = (0.2, 0.3, 0.1, 0.4)
    full[mixer: 5, kind: 1] = -0.5
    full.grading = ColourGrading(shadowHue: 220, shadowAmount: 0.3)
    (full.baseFine, full.base, full.inputGamma, full.filmEdges) = (RGB(r: 0.1, g: 0, b: 0), RGB(r: 0.5, g: 0.3, b: 0.2), 1.0, .rebate)
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
    model.pasteSettings(model.stepScope, only: [.exposure, .curves, .baseFine])
    let picked = model.frames[1].adjustments
    try check(picked.exposure == 0.5 && picked.curves != nil && picked.saturation == 0.8 && picked.baseFine == nil
      && model.status.contains("曝光、曲线"),
      "选择性粘贴 in ③ pastes the groups ticked of the grading alone, the frame's other settings kept")
    edits.undo()
    model.convertStep = .demask
    model.pasteSettings(model.stepScope, only: [.baseFine, .exposure])
    try check(model.frames[1].adjustments.baseFine == RGB(r: 0.1, g: 0, b: -0.1) && model.frames[1].adjustments.exposure == 0
      && model.frames[1].adjustments.inputGamma == Adjustments().inputGamma && model.frames[1].adjustments.saturation == 0.8,
      "and in ② the ticked of the de-masking: the base fine-tuning, not how the film is read, nor ③'s exposure")
    edits.undo()
    try check(model.frames[1].adjustments.baseFine == nil && model.frames[1].adjustments.saturation == 0.8, "one edit, undone with ⌘Z")
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
      && model.frames[2].adjustments.baseFine == nil && model.status.contains("上一张（第 01 张）"),
      "粘贴上一张 gives the frame shown the grading of the frame shown before it, not its base")
    edits.undo()

    // A tool of the other step takes the window there.
    model.convertStep = .demask
    model.useTool(.neutral)
    try check(model.convertStep == .grade && model.tool == .neutral, "the grey picker in ② takes the window to ③, where it belongs")
    model.useTool(.crop)
    try check(model.convertStep == .demask && model.tool == .crop, "the crop in ③ takes it back to ②")
    model.convertStep = .grade
    try check(model.tool == .select, "and a step's tool is put down when the window leaves it")
  }
}
