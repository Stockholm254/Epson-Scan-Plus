import CoreGraphics
import Foundation

/// Copy shots cropped to their pictures: inside the frame's edges and turned level with them, past
/// bare light and the base around the frame; a straight shadow as clear as the base, taken for an
/// edge, put right by the roll's other frames; and the crop made for a frame or a roll, undone.
enum FrameCropTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    let w = 1200, h = 800
    let base = [0.55, 0.32, 0.18]
    struct Picture { var tilt: Double, cx: Double, cy: Double, width: Double, height: Double }
    // A copy shot, linear 16-bit: bare light at the left past the film's end, the clear base round
    // the frame, and the picture turned `tilt` degrees clockwise, with a pattern denser than the
    // base. `shadow` lays a band as clear as the base along its bottom, ruled straight across.
    func shot(_ p: Picture, shadow: Bool = false) -> CGImage {
      let t = p.tilt * .pi / 180, c = cos(t), s = sin(t)
      let hw = p.width * Double(w) / 2, hh = p.height * Double(h) / 2
      var px = [UInt16](repeating: 0, count: w * h * 3)
      for y in 0..<h {
        for x in 0..<w {
          var v = base
          // Into the picture's own axes: turned back about its middle.
          let dx = Double(x) - p.cx * Double(w), dy = Double(y) - p.cy * Double(h)
          let u = dx * c + dy * s, q = -dx * s + dy * c
          if x < w / 50 {
            v = [1, 1, 1]
          } else if abs(u) < hw, abs(q) < hh {
            let d = shadow && q > hh * 0.7 ? 0.006 : 0.4 + 0.25 * sin(u / 23) * cos(q / 31) + 0.2 * (q + hh) / (2 * hh)
            v = base.map { $0 * pow(10, -d) }
          }
          for ch in 0..<3 { px[(y * w + x) * 3 + ch] = UInt16(min(65535, max(0, v[ch] * 65535))) }
        }
      }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6,
        space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    // What a crop shows, in the picture's own axes as a share of its half width and height: its
    // four corners turned back, how far the farthest is out, and how far a corner is in from the
    // picture's edge where it is farthest in (cut short of it).
    func shown(_ crop: PictureCrop, of p: Picture) -> (outmost: Double, inmost: Double) {
      let r = crop.rect, k = ImageGeometry.keep(crop.angle ?? 0, aspect: r.width * Double(w) / (r.height * Double(h)))
      let cx = (r.x + r.width / 2) * Double(w), cy = (r.y + r.height / 2) * Double(h)
      let a = r.width * Double(w) * k / 2, b = r.height * Double(h) * k / 2
      let phi = -(crop.angle ?? 0) * .pi / 180, t = p.tilt * .pi / 180
      let hw = p.width * Double(w) / 2, hh = p.height * Double(h) / 2
      var outmost = 0.0, inmost = 0.0
      for (sa, sb) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
        let x = cx + sa * a * cos(phi) - sb * b * sin(phi), y = cy + sa * a * sin(phi) + sb * b * cos(phi)
        let dx = x - p.cx * Double(w), dy = y - p.cy * Double(h)
        let u = abs(dx * cos(t) + dy * sin(t)) / hw, q = abs(-dx * sin(t) + dy * cos(t)) / hh
        outmost = max(outmost, u, q)
        inmost = max(inmost, 1 - u, 1 - q)
      }
      return (outmost, inmost)
    }
    let tilted = Picture(tilt: 0.4, cx: 0.51, cy: 0.49, width: 0.93, height: 0.9)
    guard let crop = pipe.pictureCrop(shot(tilted)) else { throw DeskError.message("FAIL: a copy shot's picture found") }
    let (out, gap) = shown(crop, of: tilted)
    try check(crop.edges == 4 && abs((crop.angle ?? 0) + 0.4) < 0.05 && out < 1 && gap < 0.02,
      String(format: "a copy shot is cropped inside its frame's edges, past bare light and the base round it, turned level with them: %+.2f° for a frame lying 0.40° clockwise, the corners %.1f%% inside",
        crop.angle ?? 0, gap * 100))

    // A frame whose bottom is a straight shadow as clear as the base: alone, its edge is taken
    // there; on a roll copied at one magnification, the others' size puts it right.
    let trap = Picture(tilt: -0.2, cx: 0.5, cy: 0.5, width: 0.93, height: 0.9)
    let alone = pipe.pictureCrop(shot(trap, shadow: true)).map { shown($0, of: trap) }
    let others = [Picture(tilt: 0.1, cx: 0.49, cy: 0.5, width: 0.93, height: 0.9), Picture(tilt: -0.3, cx: 0.5, cy: 0.51, width: 0.93, height: 0.9),
      Picture(tilt: 0.2, cx: 0.51, cy: 0.5, width: 0.93, height: 0.9)]
    let roll = FrameEdges.agreeing(([shot(trap, shadow: true)] + others.map { shot($0) }).map(pipe.frameEdges))
    let put = roll[0].flatMap { pipe.crop($0) }.map { shown($0, of: trap) }
    try check((alone?.inmost ?? 0) > 0.1 && (put?.outmost ?? 2) < 1 && (put?.inmost ?? 1) < 0.02,
      String(format: "a straight shadow as clear as the base is taken for the frame's edge alone (%.0f%% in), and put right by the roll's other frames (%.1f%%)",
        (alone?.inmost ?? 0) * 100, (put?.inmost ?? 1) * 100))

    // The model crops the selected copy, or the roll, as one edit; undo puts them back.
    let root = folder.appendingPathComponent("frame-crop", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: root.appendingPathComponent("library"), preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    for (n, p) in ([trap] + others).enumerated() {
      let url = root.appendingPathComponent("EPS0000\(n + 1).tif")
      try pipe.saveTIFF(shot(p, shadow: n == 0), to: url, dpi: 2400)
      model.addCapturedFrame(url, original: url, linear: true, sensor: false)
    }
    func cropped(roll: Bool) -> String? {
      var said: String?
      model.autoCrop(roll: roll) { said = $0 }
      for _ in 0..<400 where said == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
      return said
    }
    model.select(model.frames[0].id)
    let one = cropped(roll: false)
    let first = model.frames[0]
    try check(first.rect != .full && first.adjustments.angle != nil && model.frames.dropFirst().allSatisfy { $0.rect == .full }
      && one?.contains("已自动裁切") == true,
      "the selected copy is cropped and straightened, checked against the frames beside it; the others are left: \(one ?? "-")")
    let all = cropped(roll: true)
    try check(model.frames.allSatisfy { $0.rect != .full } && all?.contains("4 张") == true,
      "and the roll, every copy at once: \(all ?? "-")")
    edits.undo()
    try check(model.frames[0].rect == first.rect && model.frames.dropFirst().allSatisfy { $0.rect == .full && $0.adjustments.angle == nil },
      "undo takes the roll's crop back as one edit")
  }
}
