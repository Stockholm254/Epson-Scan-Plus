import Foundation

enum OrientationTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    // Clockwise on screen moves the picture's top-left corner to top-right, then on round.
    let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    func corner(_ s: Adjustments) -> Int? {
      let p = ImageGeometry.display(.zero, settings: s)
      return corners.firstIndex { abs($0.x - p.x) < 1e-9 && abs($0.y - p.y) < 1e-9 }
    }
    let turns = (0..<4).flatMap { rotation in
      [false, true].map { mirror -> Bool in
        var s = Adjustments()
        s.rotation = rotation
        s.flipHorizontal = mirror
        guard let before = corner(s) else { return false }
        var cw = s, ccw = s
        cw.turn(clockwise: true)
        ccw.turn(clockwise: false)
        return corner(cw) == (before + 1) % 4 && corner(ccw) == (before + 3) % 4
          && cw.flipHorizontal == mirror && ccw.flipHorizontal == mirror
      }
    }
    try check(turns.allSatisfy { $0 }, "quarter turns follow the screen direction for every rotation, mirrored or not")

    let model = AppModel(libraryURL: folder.appendingPathComponent("orientation-offline"))
    model.frames = (1...3).map { FilmFrame(name: "0\($0)", rect: .full, format: "135") }
    model.frames[1].adjustments.rotation = 1  // a portrait frame
    model.frames[2].adjustments.flipHorizontal = true
    model.selectedID = model.frames[0].id
    model.turn(clockwise: true)
    try check(model.frames.map(\.adjustments.rotation) == [1, 1, 0],
      "without sync, a turn changes only the current frame")
    model.syncOrientation = true
    model.turn(clockwise: false)
    try check(model.frames.map(\.adjustments.rotation) == [0, 0, 1],
      "sync turns every frame from its own orientation; portrait frames stay portrait")
    model.toggleMirror()
    try check(model.frames.allSatisfy { $0.adjustments.flipHorizontal == true },
      "sync mirror sets one value for the whole roll")
    model.syncOrientation = false
    model.toggleMirror()
    try check(model.frames.map { $0.adjustments.flipHorizontal == true } == [false, true, true],
      "without sync, mirror changes only the current frame")
  }
}
