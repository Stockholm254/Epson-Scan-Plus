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
