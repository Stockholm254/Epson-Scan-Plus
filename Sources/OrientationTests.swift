import CoreGraphics
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

    // A picture turned or mirrored is the one it had, turned (`ImagePipeline.refaced`): the turns
    // and the mirror are the pipeline's last steps, after straightening and ③'s crop, so the film
    // strip turns its positives rather than converting each frame again.
    let pipe = ImagePipeline.shared
    let w = 90, h = 60
    let paint = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in stride(from: 0, to: w, by: 6) {
      for y in stride(from: 0, to: h, by: 5) {
        let red: CGFloat = 0.35 + 0.5 * CGFloat(x) / CGFloat(w)
        let green: CGFloat = 0.3 + 0.3 * CGFloat((x + y) % 7) / 7
        let blue: CGFloat = 0.2 + 0.5 * CGFloat(y) / CGFloat(h)
        paint.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        paint.fill(CGRect(x: x, y: y, width: 6, height: 5))
      }
    }
    let negative = paint.makeImage()!
    func bytes(_ image: CGImage) -> [UInt8] {
      let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    var plain = Adjustments()
    plain.angle = 2.5
    plain.composition = NormalRect(x: 0.1, y: 0.05, width: 0.8, height: 0.85)
    let facings = (0..<4).flatMap { r in [false, true].map { Facing(rotation: r, mirrored: $0) } }
    let direct = try facings.map { f -> CGImage in
      var s = plain
      (s.rotation, s.flipHorizontal) = (f.rotation, f.mirrored ? true : nil)
      return try pipe.preview(negative, settings: s, profile: FilmProfile.builtins[0])
    }
    var worst = 0
    for (i, from) in facings.enumerated() {
      for (j, to) in facings.enumerated() {
        guard let turned = pipe.refaced(direct[i], from: from, to: to), turned.width == direct[j].width, turned.height == direct[j].height else {
          worst = 255
          continue
        }
        worst = max(worst, zip(bytes(turned), bytes(direct[j])).map { abs(Int($0) - Int($1)) }.max() ?? 0)
      }
    }
    try check(worst == 0, "a straightened, cropped picture turned or mirrored from any facing to any other is, pixel for pixel, the one converted so (worst \(worst))")
  }
}
