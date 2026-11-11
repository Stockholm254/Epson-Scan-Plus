import Foundation

/// Several frames chosen (⌘ or ⇧ on the strip or the light table): turning, mirroring, ticking,
/// deleting, resetting and syncing act on all of them, each as one edit; one frame chosen, or the
/// roll synced, as before.
enum MultiSelectTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("multi-select"), preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    model.frames = (1...5).map { FilmFrame(name: "0\($0)", rect: .full, format: "135") }
    model.frames[3].adjustments.rotation = 1
    let ids = model.frames.map(\.id)
    model.selectedID = ids[0]
    try check(!model.multiSelected && model.choose(ids[2], modifiers: .shift) && model.multiSelected && model.selection.map(\.id) == Array(ids[0...2]),
      "⇧ chooses the run from the frame shown to the one clicked")
    // Turning: the single view's keys and the light table's both turn the three chosen.
    model.singleView = true
    model.turn(clockwise: true)
    try check(model.frames.map(\.adjustments.rotation) == [1, 1, 1, 1, 0] && model.status.contains("所选的 3 张"),
      "with three chosen, the single view's turn turns the three, each from its own orientation")
    model.singleView = false
    model.turnRoll(clockwise: false)
    try check(model.frames.map(\.adjustments.rotation) == [0, 0, 0, 1, 0], "and the light table's turns the three, not the roll")
    model.mirrorRoll()
    try check(model.frames.map { $0.adjustments.flipHorizontal == true } == [true, true, true, false, false] && model.tableMirrored,
      "the light table's mirror mirrors the three, and its key shows them mirrored")
    model.mirrorRoll()
    try check(model.frames.allSatisfy { $0.adjustments.flipHorizontal != true } && !model.tableMirrored, "and again takes the three back")
    model.mirrorRoll()
    edits.undo()
    try check(model.frames.allSatisfy { $0.adjustments.flipHorizontal != true }, "one ⌘Z takes the three back")
    model.syncOrientation = true
    model.singleView = true
    model.turn(clockwise: true)
    try check(model.frames.map(\.adjustments.rotation) == [1, 1, 1, 2, 1], "the roll synced in the single view still turns the whole roll")
    model.syncOrientation = false
    // Ticking, resetting and syncing the three.
    model.setSelectionEnabled(false)
    try check(model.frames.map(\.enabled) == [false, false, false, true, true] && !model.selectionEnabled, "the three are unticked together")
    model.frames[0].adjustments.exposure = 0.5
    model.frames[1].adjustments.exposure = -0.3
    model.frames[4].adjustments.exposure = 0.8
    model.resetAdjustments()
    try check(model.frames.map(\.adjustments.exposure) == [0, 0, 0, 0, 0.8] && model.frames[0].adjustments.rotation == 1,
      "重置 sets the three back and keeps how each faces; a frame not chosen keeps its own")
    model.frames[0].adjustments.saturation = 1.4
    model.syncSettings()
    try check(model.frames.map(\.adjustments.saturation) == [1.4, 1.4, 1.4, 1, 1] && model.frames[4].adjustments.exposure == 0.8,
      "同步 takes the frame shown's settings to the frames chosen with it, not the roll")
    // Deleting the three: one edit, the frame after them shown.
    model.remove(model.selectionIDs)
    try check(model.frames.map(\.id) == [ids[3], ids[4]] && model.selectedID == ids[3] && !model.multiSelected,
      "删除 takes the three out at once, and the frame after them is shown")
    edits.undo()
    try check(model.frames.map(\.id) == ids, "one ⌘Z puts the three back")
    // One frame chosen: as before.
    model.alsoSelected = []
    model.selectedID = ids[4]
    model.singleView = true
    model.turn(clockwise: true)
    try check(model.frames.map(\.adjustments.rotation) == [1, 1, 1, 2, 2], "with one frame chosen a turn changes only that one, as before")
  }
}
