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
    // Saturation is ③'s: 同步 there gives the grading.
    model.convertStep = .grade
    model.syncSettings()
    try check(model.frames.map(\.adjustments.saturation) == [1.4, 1.4, 1.4, 1, 1] && model.frames[4].adjustments.exposure == 0.8,
      "同步 takes the frame shown's settings to the frames chosen with it, not the roll")
    // Deleting the three: one edit, the frame after them shown.
    model.remove(model.selectionIDs)
    try check(model.frames.map(\.id) == [ids[3], ids[4]] && model.selectedID == ids[3] && !model.multiSelected,
      "删除 takes the three out at once, and the frame after them is shown")
    edits.undo()
    try check(model.frames.map(\.id) == ids, "one ⌘Z puts the three back")
    // 拷贝调整 and 粘贴调整: one frame's settings given to the frames chosen later, each keeping how
    // it faces, as one edit.
    model.alsoSelected = []
    model.selectedID = ids[4]
    model.frames[4].adjustments.exposure = 0.6
    model.frames[4].adjustments.warmth = -0.2
    model.copySettings()
    model.frames[4].adjustments.exposure = 0
    model.selectedID = ids[1]
    model.alsoSelected = [ids[2]]
    let rotationsBefore = model.frames.map(\.adjustments.rotation)
    model.pasteSettings()
    try check(model.frames[1].adjustments.exposure == 0.6 && model.frames[2].adjustments.warmth == -0.2
      && model.frames[3].adjustments.exposure == 0 && model.frames[4].adjustments.exposure == 0
      && model.frames.map(\.adjustments.rotation) == rotationsBefore,
      "粘贴调整 gives the copied settings, as they were copied, to the two chosen, each keeping how it faces")
    edits.undo()
    try check(model.frames[1].adjustments.exposure != 0.6 && model.frames[2].adjustments.warmth != -0.2, "one ⌘Z takes the paste back")
    model.alsoSelected = []
    model.pasteSettings()
    try check(model.frames[1].adjustments.exposure == 0.6 && model.frames[2].adjustments.exposure != 0.6,
      "with one frame chosen, it goes to the frame shown")
    // 自动同步: with several chosen, what an edit of the frame shown changes goes to the others
    // chosen, as it now is there; the rest of theirs, and frames not chosen, as they were.
    let page = model.page
    model.page = .convert
    model.convertStep = .grade
    model.selectedID = ids[0]
    model.alsoSelected = [ids[1]]
    model.frames[0].adjustments.exposure = 0.2
    model.frames[1].adjustments.exposure = -0.4
    model.frames[1].adjustments.saturation = 0.7
    let third = model.frames[2].adjustments
    model.change("饱和度") { $0.saturation = 1.1 }
    try check(model.frames[1].adjustments.saturation == 0.7, "自动同步 off, an edit changes the frame shown alone")
    model.autoSync = true
    model.change("饱和度", separate: true) { $0.saturation = 1.25 }
    model.change("白色") { $0.whitesAmount = -0.3 }
    try check(model.frames[1].adjustments.saturation == 1.25 && model.frames[1].adjustments.whites == -0.3
      && model.frames[1].adjustments.exposure == -0.4 && model.frames[2].adjustments == third,
      "自动同步 on, each edit goes to the other frame chosen as it is on the frame shown, its exposure its own, a frame not chosen untouched")
    edits.undo()
    try check(model.frames[0].adjustments.whites == nil && model.frames[1].adjustments.whites == nil && model.frames[1].adjustments.saturation == 1.25,
      "one ⌘Z takes the edit back from both")
    let turned = model.frames[1].adjustments.rotation
    model.change("旋转") { $0.rotation = ($0.rotation + 1) % 4 }
    model.change("自动调整", syncing: false) { $0.exposure = 0.9 }
    try check(model.frames[1].adjustments.rotation == turned && model.frames[1].adjustments.exposure == -0.4,
      "how a frame faces stays its own, and the wand adjusts the frame shown alone")
    edits.undo()
    edits.undo()
    model.autoSync = false
    model.page = page

    // One frame chosen: as before.
    model.alsoSelected = []
    model.selectedID = ids[4]
    model.singleView = true
    model.turn(clockwise: true)
    try check(model.frames.map(\.adjustments.rotation) == [1, 1, 1, 2, 2], "with one frame chosen a turn changes only that one, as before")
  }
}
