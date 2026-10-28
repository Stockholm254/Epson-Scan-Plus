import AppKit
import Foundation

enum LoupeTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func image(_ w: Int, _ h: Int, _ paint: (CGContext) -> Void) -> CGImage {
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      // Paint in the flipped canvas's terms: y down.
      ctx.translateBy(x: 0, y: CGFloat(h))
      ctx.scaleBy(x: 1, y: -1)
      paint(ctx)
      return ctx.makeImage()!
    }
    func fill(_ ctx: CGContext, _ r: CGRect, _ c: (CGFloat, CGFloat, CGFloat)) {
      ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
      ctx.fill(r)
    }
    // The renderer, on a grey table with a film that is red left of x = 200, blue right of it,
    // with a 6 pt white stripe from 200 to 206.
    let size = CGSize(width: 400, height: 300)
    let table = image(400, 300) { fill($0, CGRect(x: 0, y: 0, width: 400, height: 300), (0.85, 0.85, 0.85)) }
    let film = image(400, 300) { ctx in
      fill(ctx, CGRect(x: 0, y: 0, width: 200, height: 300), (0.8, 0.1, 0.1))
      fill(ctx, CGRect(x: 200, y: 0, width: 200, height: 300), (0.1, 0.2, 0.8))
      fill(ctx, CGRect(x: 200, y: 0, width: 6, height: 300), (1, 1, 1))
    }
    let scene = LoupeRenderer.Scene(table: table, canvas: size, film: film, filmRect: CGRect(origin: .zero, size: size))
    let centre = CGPoint(x: 203, y: 150), r: CGFloat = 50
    let view = CGRect(x: centre.x - 105, y: centre.y - 105, width: 210, height: 210)
    func pose(_ style: LoupeStyle, lift: CGFloat = 0, eye: SIMD3<Float> = SIMD3(203, 150, 4000)) -> LoupeRenderer.Pose {
      LoupeRenderer.Pose(style: style, center: centre, radius: r, lift: lift, eye: eye)
    }
    let renderer = LoupeRenderer()
    let started = Date()
    guard let pentax = renderer.render(frame: view, scale: 2, pose: pose(.pentax), scene: scene) else {
      throw DeskError.message("FAIL: the loupe is ray-marched by Metal compiled at run time")
    }
    let took = Date().timeIntervalSince(started) * 1000
    try check(pentax.width == 420 && pentax.height == 420, "the loupe is ray-marched by Metal at the display's resolution")
    struct Picture {
      let bytes: [UInt8], width: Int
      init(_ image: CGImage) { bytes = [UInt8](image.dataProvider!.data! as Data); width = image.width }
      /// At a point of the canvas, for the view above at 2×.
      func at(_ x: CGFloat, _ y: CGFloat) -> [Int] {
        let px = Int((x - 98) * 2), py = Int((y - 45) * 2)
        return (0..<4).map { Int(bytes[(py * width + px) * 4 + $0]) }
      }
      /// How wide the white stripe looks through the lens, in points.
      var stripe: CGFloat {
        var n = 0
        for x in stride(from: 175.0, to: 231.0, by: 0.5) {
          let p = at(CGFloat(x), 150)
          if p[0] > 150 && p[2] > 150 && p[1] > 150 { n += 1 }
        }
        return CGFloat(n) / 2
      }
      var sharpest: Int {
        (0..<100).map { i -> Int in
          let a = at(180 + CGFloat(i) * 0.5, 150), b = at(180.5 + CGFloat(i) * 0.5, 150)
          return abs(a[1] - b[1])
        }.max()!
      }
    }
    let p = Picture(pentax)
    let lens = p.at(centre.x, centre.y)
    try check(lens[0] > 170 && lens[1] > 170 && lens[2] > 170, "the lens shows the film beneath its axis: \(lens.prefix(3))")
    try check(abs(p.stripe - 33) < 5, "the Pentax loupe magnifies 5.5×: a 6 pt stripe is \(p.stripe) pt in the lens")
    let left = p.at(centre.x - 20, centre.y)
    try check(left[0] > left[2] + 60, "film to the left of the axis shows to the left in the lens: \(left.prefix(3))")
    let cup = p.at(centre.x, centre.y - r * 0.69), skirt = p.at(centre.x, centre.y - r * 0.965)
    try check(cup[3] == 255 && cup[0] < 70 && cup[1] < 70, "the rubber eyecup is black: \(cup.prefix(3))")
    try check(skirt[3] == 255 && skirt[1] > cup[1] + 60, "the clear skirt lets the table's light through: \(skirt[1]) against the eyecup's \(cup[1])")
    try check(p.at(view.minX + 2, view.minY + 2)[3] == 0, "around the loupe the table shows")
    // Light from the upper left: the shadow falls to the lower right.
    let shaded = p.at(centre.x + r * 0.62, centre.y + r * 0.88)[3], lit = p.at(centre.x - r * 0.62, centre.y - r * 0.88)[3]
    try check(shaded > 10 && shaded > lit + 8, "the loupe stands in its shadow, away from the light: \(shaded) against \(lit)")
    let mamiya = Picture(renderer.render(frame: view, scale: 2, pose: pose(.mamiya), scene: scene)!)
    try check(abs(mamiya.stripe - 24) < 4.5, "the Mamiya loupe magnifies 4×: the stripe is \(mamiya.stripe) pt")
    let lifted = Picture(renderer.render(frame: view, scale: 2, pose: pose(.pentax, lift: r * 0.12), scene: scene)!)
    try check(lifted.sharpest < p.sharpest, "lifted off the film the loupe goes out of focus: edges \(lifted.sharpest) against \(p.sharpest)")
    // Seen from the left, the top leans right: the stripe moves right of the base's centre.
    let oblique = Picture(renderer.render(frame: view, scale: 2, pose: pose(.pentax, eye: SIMD3(-500, 150, 3000)), scene: scene)!)
    var brightest = (x: CGFloat(0), v: 0)
    for x in stride(from: 180.0, to: 260.0, by: 0.5) {
      let v = oblique.at(CGFloat(x), 150)
      if v[2] > 150 && v[0] > 150 && v[1] > brightest.v { brightest = (CGFloat(x), v[1]) }
    }
    try check(brightest.x > centre.x + 3, "perspective: seen from the left, the lens sits right of the base (\(brightest.x) pt)")
    var detailed = scene
    detailed.detail = image(40, 40) { fill($0, CGRect(x: 0, y: 0, width: 40, height: 40), (0.1, 0.8, 0.2)) }
    detailed.detailRect = CGRect(x: 183, y: 130, width: 40, height: 40)
    let green = Picture(renderer.render(frame: view, scale: 2, pose: pose(.pentax), scene: detailed)!).at(centre.x, centre.y)
    try check(green[1] > green[0] + 60 && green[1] > green[2] + 60, "the frame's own pixels win over the contact view's: \(green.prefix(3))")
    print(String(format: "first loupe render (compiles the shader): %.0f ms", took))
    var times = [Double]()
    for i in 0..<10 {
      var moved = pose(.pentax)
      moved.center.x += CGFloat(i)
      let s = Date()
      _ = renderer.render(frame: view, scale: 2, pose: moved, scene: scene)
      times.append(Date().timeIntervalSince(s) * 1000)
    }
    try check(times.sorted()[5] < 12, String(format: "a drag step renders in %.1f ms", times.sorted()[5]))

    // The view on a contact sheet: lies by the edge, drags, parks, hides, follows the film's scale.
    let roll = folder.appendingPathComponent("loupe", isDirectory: true)
    try? FileManager.default.removeItem(at: roll)
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    let overview = image(1500, 800) { ctx in
      fill(ctx, CGRect(x: 0, y: 0, width: 1500, height: 800), (0.06, 0.06, 0.06))
      fill(ctx, CGRect(x: 60, y: 260, width: 1380, height: 280), (0.8, 0.52, 0.33))
      for i in 0..<4 { fill(ctx, CGRect(x: 90 + i * 340, y: 293, width: 320, height: 214), (0.6, 0.38, 0.28 + 0.05 * CGFloat(i))) }
    }
    let overviewURL = roll.appendingPathComponent("overview.png")
    try ImagePipeline.shared.savePNG(overview, to: overviewURL)
    let frames = (0..<4).map { i in
      FilmFrame(name: String(format: "%02d", i + 1),
        rect: NormalRect(x: (90 + Double(i) * 340) / 1500, y: 293.0 / 800, width: 320.0 / 1500, height: 214.0 / 800), format: "135")
    }
    let project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 150, physicalWidthMM: 254, physicalHeightMM: 135.5,
      filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: frames)
    let projectURL = roll.appendingPathComponent("loupe.epscan")
    try JSONEncoder().encode(project).write(to: projectURL)
    let model = AppModel(libraryURL: roll)
    model.loadProject(projectURL)
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    for _ in 0..<40 where model.rendering { settle(0.1) }
    let canvas = FilmCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = canvas
    canvas.model = model
    canvas.updateLoupe()
    settle()
    let loupe = canvas.loupe
    try check(!loupe.isHidden && loupe.center == loupe.parkedCenter, "the loupe lies by the light table's edge in the contact view")
    let perMM = canvas.imageRect.height / 135.5
    try check(abs(loupe.radius - 24 * perMM) < 0.5 || loupe.radius == 44, "the loupe lies to the film's scale: \(Int(loupe.radius)) pt for a 48 mm base")
    let start = loupe.center!
    try check(loupe.hitTest(start) === loupe && loupe.hitTest(CGPoint(x: loupe.frame.minX + 2, y: loupe.frame.minY + 2)) == nil,
      "only the loupe takes the mouse, not its shadow")
    func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    let target = canvas.screen(frames[1].rect.cg)
    let goal = CGPoint(x: target.midX, y: target.midY)
    loupe.mouseDown(with: event(.leftMouseDown, start))
    loupe.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: (start.x + goal.x) / 2, y: (start.y + goal.y) / 2)))
    loupe.mouseDragged(with: event(.leftMouseDragged, goal))
    loupe.mouseUp(with: event(.leftMouseUp, goal))
    try check(abs(loupe.center!.x - goal.x) < 1 && abs(loupe.center!.y - goal.y) < 1 && model.loupeCenter != nil,
      "dragging carries the loupe onto a frame, and it stays there")
    // As SwiftUI does on every change: the roll estimate lands meanwhile and changes the frame.
    for _ in 0..<50 where canvas.loupeScene().detail == nil {
      canvas.updateLoupe()
      settle(0.1)
    }
    let shown = canvas.loupeScene()
    try check(shown.detail != nil && shown.detailRect == target, "the lens reads the frame under it at the frame's own resolution")
    guard let before = shown.detail else { throw DeskError.message("FAIL: no picture of the frame to edit") }
    model.select(frames[1].id)
    model.change { $0.exposure += 0.5 }
    try check(canvas.loupeScene().detail === before, "after an edit the lens keeps its picture until the new one is ready")
    for _ in 0..<50 where canvas.loupeScene().detail === before { settle(0.1) }
    let edited = canvas.loupeScene().detail
    try check(edited != nil && edited !== before, "and then asks for the edited frame by itself")
    var moved = frames[1].rect
    moved.x += 0.01
    model.setRect(frames[1].id, rect: moved)
    try check(canvas.loupeScene().detail == nil, "a moved frame box drops the old picture at once")
    loupe.mouseDown(with: event(.leftMouseDown, goal, clicks: 2))
    try check(loupe.center == loupe.parkedCenter && model.loupeCenter == nil, "a double-click puts the loupe back by the edge")
    canvas.setFrameSize(NSSize(width: 1000, height: 640))
    try check(loupe.center == loupe.parkedCenter, "parked, the loupe stays in its corner when the window changes size")
    let small = loupe.radius
    model.preferences.loupeStyle = .mamiya
    canvas.updateLoupe()
    try check(loupe.style == .mamiya && loupe.radius > small, "the Mamiya loupe is the larger one")
    model.singleView = true
    canvas.updateLoupe()
    try check(loupe.isHidden, "single view has no light table, so no loupe")
    model.singleView = false
    model.preferences.showLoupe = false
    canvas.updateLoupe()
    try check(loupe.isHidden, "the loupe can be put away")
    window.close()

    // Settings.
    let suite = "local.epscan.mac.loupe-test"
    UserDefaults().removePersistentDomain(forName: suite)
    let defaults = UserDefaults(suiteName: suite)!
    let fresh = Preferences(defaults: defaults)
    try check(fresh.previewDPI == 600 && fresh.showLoupe && fresh.loupeStyle == .pentax,
      "previews are 600 dpi and the Pentax loupe lies out, unless changed")
    fresh.previewDPI = 150
    fresh.loupeStyle = .mamiya
    fresh.showLoupe = false
    let again = Preferences(defaults: defaults)
    try check(again.previewDPI == 150 && again.loupeStyle == .mamiya && !again.showLoupe, "preview resolution and the loupe are remembered")
    defaults.set(300, forKey: "previewDPI")
    try check(Preferences(defaults: defaults).previewDPI == 600, "an unoffered preview resolution falls back to 600 dpi")
    UserDefaults().removePersistentDomain(forName: suite)

    // A 600 dpi preview: kept whole on disk and for single frames, at 2200 px for the rest.
    final class Recorder: ScannerController {
      var asked: Int?
      override func preview() { asked = previewDPI }
    }
    let recorder = Recorder()
    let previewing = AppModel(libraryURL: roll.appendingPathComponent("library"), scanner: recorder)
    previewing.requestPreview()
    try check(recorder.asked == 600, "the preview asks the scanner for 600 dpi")
    previewing.preferences.previewDPI = 150
    previewing.requestPreview()
    try check(recorder.asked == 150, "or 150 dpi, when chosen")
    _ = try SaneScannerController.captureArguments(
      rect: .full, dpi: 600, size: CGSize(width: 149.01, height: 246.21), output: roll.appendingPathComponent("p.tiff"))
    let big = image(1500, 2600) { ctx in
      for y in stride(from: 0, to: 2600, by: 20) { fill(ctx, CGRect(x: 0, y: y, width: 1500, height: 10), (0.7, 0.4, 0.3)) }
    }
    previewing.receiveOverview(big, size: CGSize(width: 63.5, height: 110.07), dpi: 600)
    for _ in 0..<50 where previewing.detectingFrames { settle(0.1) }
    let saved = previewing.sessionURL!.appendingPathComponent("overview.tif")
    let info = ImagePipeline.shared.info(saved)
    try check(info.width == 1500 && info.height == 2600 && info.dpi == 600, "the whole preview is kept as a 600 dpi TIFF")
    try check(previewing.overview.map { max($0.width, $0.height) } == 2200, "frame detection and the contact view work on 2200 px")
    previewing.frames = [FilmFrame(name: "01", rect: NormalRect(x: 0.1, y: 0.1, width: 0.4, height: 0.3), format: "135")]
    let crop = try previewing.source(for: previewing.frames[0])
    try check(crop.width == 600 && crop.height == 780, "a single frame comes from the full 600 dpi preview: \(crop.width)×\(crop.height)")
    try check(try previewing.source(for: previewing.frames[0], maxDimension: 300).width == 231, "and is scaled down only when asked")
  }
}
