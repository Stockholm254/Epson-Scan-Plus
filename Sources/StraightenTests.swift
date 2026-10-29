import AppKit
import Foundation

/// A frame straightened: turned about its middle by a free angle and cut to the largest rectangle
/// of its shape inside, in the picture, in the points picked on it, in a part of it rendered on
/// its own, on the light table, and on the leak page's crop.
enum StraightenTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared, profile = FilmProfile.builtins[0]
    try check(ImageGeometry.keep(0, aspect: 1.5) == 1 && abs(ImageGeometry.keep(5, aspect: 1.5) - 0.8874) < 0.0005
      && abs(ImageGeometry.keep(-5, aspect: 1.5) - ImageGeometry.keep(5, aspect: 1 / 1.5)) < 1e-12,
      "a 3:2 frame straightened 5° keeps 88.7% of its width and height, either way and on its side alike")

    // A smooth ramp, red across and green down, so where a pixel came from can be read off it.
    let width = 300, height = 200
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        bytes[i] = UInt8((Double(x) / Double(width - 1) * 255).rounded())
        bytes[i + 1] = UInt8((Double(y) / Double(height - 1) * 255).rounded())
        bytes[i + 2] = 128
      }
    }
    let ramp = CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let source = pipe.raster(ramp)
    let aspect = Double(width) / Double(height)
    let points = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.85, y: 0.3), CGPoint(x: 0.2, y: 0.9)]
    var mapped = true, sized = true, read = true, parts = true
    for angle in [4.0, -9.0] {
      for rotation in 0..<4 {
        for mirror in [false, true] {
          var s = Adjustments()
          s.rotation = rotation
          s.flipHorizontal = mirror
          s.angle = angle
          for p in points {
            let back = ImageGeometry.raw(ImageGeometry.display(p, settings: s, aspect: aspect), settings: s, aspect: aspect)
            if hypot(back.x - p.x, back.y - p.y) > 1e-9 { mapped = false }
          }
          guard let out = pipe.render(ramp, settings: s, profile: profile, analysis: nil, negative: true) else {
            sized = false
            continue
          }
          let k = ImageGeometry.keep(angle, aspect: aspect)
          let expected = rotation % 2 == 1 ? (Double(height) * k, Double(width) * k) : (Double(width) * k, Double(height) * k)
          if abs(Double(out.width) - expected.0) > 2 || abs(Double(out.height) - expected.1) > 2 { sized = false }
          let shown = pipe.raster(out)
          for p in points {
            let q = ImageGeometry.raw(p, settings: s, aspect: aspect)
            let want = source.pixel(Int(q.x * Double(width)), Int(q.y * Double(height))).values
            let got = shown.pixel(Int(p.x * Double(shown.width)), Int(p.y * Double(shown.height))).values
            if !zip(want, got).allSatisfy({ abs($0 - $1) < 0.025 }) { read = false }
          }
          // A part on its own is that part of the whole.
          let region = NormalRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5)
          if let part = pipe.render(ramp, region: region, settings: s, profile: profile, analysis: nil, negative: true) {
            let whole = pipe.raster(out, maxDimension: 1000), piece = pipe.raster(part.image, maxDimension: 1000)
            let ox = Int((part.region.x * Double(out.width)).rounded()), oy = Int((part.region.y * Double(out.height)).rounded())
            let near = abs(part.region.x - region.x) < 2 / Double(out.width) && abs(part.region.width - region.width) < 2 / Double(out.width)
            let same = [(3, 3), (piece.width / 2, piece.height / 2), (piece.width - 4, piece.height - 4)].allSatisfy { x, y in
              zip(whole.pixel(ox + x, oy + y).values, piece.pixel(x, y).values).allSatisfy { abs($0 - $1) < 0.01 }
            }
            if !near || !same { parts = false }
          } else {
            parts = false
          }
        }
      }
    }
    try check(mapped, "a point maps onto the straightened picture and back, every turn and mirror")
    try check(sized, "the straightened picture is the frame's shape, smaller by what turning cuts off")
    try check(read, "each pixel of the straightened picture comes from where the mapping says, so picks land on what is clicked")
    try check(parts, "a part rendered on its own (the zoom, the loupe) is that part of the straightened whole")

    // The model: clockwise on the screen whether or not the frame is mirrored; kept by a reset,
    // and each frame's own when the roll is synced; a grid while it changes.
    let model = AppModel(libraryURL: folder.appendingPathComponent("straighten-offline"))
    model.frames = (1...2).map { FilmFrame(name: "0\($0)", rect: NormalRect(x: 0.1, y: 0.1, width: 0.36, height: 0.24), format: "135") }
    model.frames[0].adjustments.flipHorizontal = true
    model.selectedID = model.frames[0].id
    model.straighten(2.5)
    try check(model.frames[0].adjustments.angle == -2.5 && model.screenAngle == 2.5 && model.straightening,
      "straightening a mirrored frame clockwise on the screen turns it the other way as it lies, with the grid shown")
    model.change { $0.warmth = 0.4 }
    model.resetAdjustments()
    try check(model.settings.angle == -2.5 && model.settings.warmth == 0, "resetting the adjustments keeps the straightening, as it keeps the turn")
    model.applyToRoll()
    try check(model.frames[1].adjustments.angle == nil, "syncing the roll leaves each frame's straightening its own")
    model.singleView = true
    model.tool = .select
    let aspectShown = model.shownAspect(model.frames[0])
    model.tool = .crop
    try check(aspectShown.map { abs($0 - 0.36 * model.physicalMM.width / (0.24 * model.physicalMM.height)) < 1e-9 } == true
      && model.shownAspect(model.frames[0]) == nil,
      "the single view maps points straightened, but not while the crop is edited on the frame as it lies")
    model.tool = .select
    model.straighten(0)
    try check(model.settings.angle == nil, "back to 0° it is not straightened at all")

    // The light table shows the film as it lies: a straightened frame does not turn the paper.
    var straight = FilmFrame(name: "01", rect: NormalRect(x: 0.1, y: 0.1, width: 0.4, height: 0.5), format: "135")
    var tilted = straight
    tilted.adjustments.angle = 8
    straight.adjustments.angle = nil
    if let a = pipe.contactPrint(ramp, frames: [straight], profile: profile), let b = pipe.contactPrint(ramp, frames: [tilted], profile: profile) {
      let ra = pipe.raster(a), rb = pipe.raster(b)
      try check(a.width == b.width && a.height == b.height
        && zip(ra.pixel(250, 150).values, rb.pixel(250, 150).values).allSatisfy { abs($0 - $1) < 0.01 },
        "the contact print around a straightened frame is the same paper")
    } else {
      try check(false, "the contact print renders with a straightened frame")
    }

    // The leak page: its crop straightened the same way.
    var data = [UInt16](repeating: 0, count: width * height * 3)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 3
        data[i] = UInt16(x * 200)
        data[i + 1] = UInt16(y * 300)
        data[i + 2] = 30000
      }
    }
    let leak = LeakImage(width: width, height: height, data: data)
    let crop = LeakCrop(x: 0.1, y: 0.1, w: 0.8, h: 0.8, angle: 6)
    let cut = LeakEngine.cropped(leak, rotation: 0, crop: crop)
    let k = ImageGeometry.keep(6, aspect: 240.0 / 160.0)
    let mid = cut.rgb((cut.height / 2 * cut.width + cut.width / 2))
    let corner = ImageGeometry.straightened(CGPoint(x: 0.02, y: 0.02), degrees: 6, aspect: 1.5, inverse: true)
    let cornerAt = cut.rgb(Int(0.02 * Double(cut.height)) * cut.width + Int(0.02 * Double(cut.width)))
    let wantX = (30 + corner.x * 240) * 200, wantY = (20 + corner.y * 160) * 300
    try check(abs(Double(cut.width) - 240 * k) <= 1 && abs(Double(cut.height) - 160 * k) <= 1
      && abs(mid.x * 65535 - 150 * 200) < 400 && abs(mid.y * 65535 - 100 * 300) < 600
      && abs(cornerAt.x * 65535 - wantX) < 500 && abs(cornerAt.y * 65535 - wantY) < 700,
      "the leak page's crop straightens about its middle and keeps the largest rectangle of its shape")
    let old = try JSONDecoder().decode(LeakCrop.self, from: Data(#"{"x":0.1,"y":0,"w":0.9,"h":1}"#.utf8))
    let written = String(decoding: try JSONEncoder().encode(LeakCrop(x: 0, y: 0, w: 1, h: 1)), as: UTF8.self)
    try check(old.angle == nil && old.w == 0.9 && !written.contains("angle"),
      "a FilmLightLab crop without an angle reads as not straightened, and one not straightened is written as before")
  }
}
