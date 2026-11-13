import Foundation

/// The window's gate (`WindowGate`): a change on its own reaches the window at once; a slider's
/// steps, 60 a second, reach it about ten times a second, the last of them always.
enum WindowGateTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("window-gate"), preferences: Preferences(defaults: defaults))
    model.frames = (1...3).map { FilmFrame(name: "0\($0)", rect: .full, format: "135") }
    model.selectedID = model.frames[0].id
    let gate = model.windowGate
    pump(0.3)
    var sent = gate.sent
    model.change { $0.exposure = 0.2 }
    try check(gate.sent > sent && !model.adjustingContinuously, "a change on its own reaches the window at once")
    pump(0.3)
    sent = gate.sent
    let held = gate.held
    // A drag: 30 steps at 60 a second, or as fast as they go.
    let began = Date()
    for k in 0..<30 {
      model.change { $0.exposure = Double(k) * 0.02 }
      // The first step goes at once, its several changes in one update of the window: counted
      // from the second.
      if k == 0 { sent = gate.sent }
      pump(1.0 / 60)
    }
    let during = gate.sent - sent, took = Date().timeIntervalSince(began)
    try check(model.adjustingContinuously && gate.held > held, "steps of a drag are held back")
    // The last step held goes with the gate's next turn, at most an interval later.
    pump(WindowGate.interval + 0.15)
    let all = gate.sent - sent
    try check(Double(during) <= took / WindowGate.interval + 2 && during < 25 && all >= during + 1,
      String(format: "a drag reaches the window twice a second, not with each of its 30 steps: %d during %.2f s, %d in all", during, took, all))
    try check(!model.adjustingContinuously && model.frames[0].adjustments.exposure == 29 * 0.02,
      "and once it stops the window has the last step")
    // A change after the drag reaches the window at once again.
    sent = gate.sent
    model.change { $0.exposure = 0 }
    try check(gate.sent > sent, "a change after the drag goes at once again")
    // A curve's point dragged: the window waits for the whole drag and is updated once let go;
    // a drag whose end never came lets go by itself.
    pump(0.6)
    sent = gate.sent
    for k in 0..<45 {
      gate.hold()
      model.change { $0.exposure = Double(k) * 0.01 }
      pump(1.0 / 60)
    }
    let whileHeld = gate.sent - sent
    gate.release()
    let onRelease = gate.sent - sent
    pump(0.1)
    sent = gate.sent
    gate.hold()
    model.change { $0.exposure = 0.3 }
    pump(WindowGate.holdStep + 0.15)
    try check(whileHeld == 0 && onRelease == 1 && gate.sent - sent == 1 && !gate.holding,
      "a curve's point dragged holds the window until it is let go, then updates it once; an unfinished drag lets go by itself")
  }
}
