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
    let rodenstock = Picture(renderer.render(frame: view, scale: 2, pose: pose(.rodenstock), scene: scene)!)
    let wideCup = rodenstock.at(centre.x, centre.y - r * 0.82), wideSkirt = rodenstock.at(centre.x, centre.y - r * 0.98)
    try check(abs(rodenstock.stripe - 18) < 3.5 && wideCup[3] == 255 && wideCup[0] < 70 && wideSkirt[1] > wideCup[1] + 60,
      "the Rodenstock loupe magnifies 3×, its wide lens in a black eyecup on a clear skirt: the stripe is \(rodenstock.stripe) pt, the eyecup \(wideCup[1]), the skirt \(wideSkirt[1])")
    let peak = Picture(renderer.render(frame: view, scale: 2, pose: pose(.peak), scene: scene)!)
    let peakCup = peak.at(centre.x, centre.y - r * 0.71), peakSkirt = peak.at(centre.x, centre.y - r * 0.965)
    try check(abs(peak.stripe - 47) < 6 && peakCup[3] == 255 && peakCup[0] < 70 && peakSkirt[1] > peakCup[1] + 60,
      "the Peak loupe magnifies 8×, its lens in a black eyecup on a tall clear skirt: the stripe is \(peak.stripe) pt, the eyecup \(peakCup[1]), the skirt \(peakSkirt[1])")
    let schneider = Picture(renderer.render(frame: view, scale: 2, pose: pose(.schneider10), scene: scene)!)
    let axis = schneider.at(centre.x, centre.y), smallCup = schneider.at(centre.x, centre.y - r * 0.58)
    try check(schneider.stripe >= 2 * r * CGFloat(LoupeStyle.schneider10.lens.radius) * 0.85 && axis[0] > 170 && axis[2] > 170 && smallCup[3] == 255 && smallCup[0] < 70,
      "the Schneider 10× magnifies most, the stripe filling its small lens, set in a black eyecup: \(schneider.stripe) pt, the eyecup \(smallCup[1])")
    let lifted = Picture(renderer.render(frame: view, scale: 2, pose: pose(.pentax, lift: r * 0.12), scene: scene)!)
    try check(lifted.sharpest * 10 >= p.sharpest * 8 && abs(lifted.stripe - p.stripe) < 4,
      "picked up and moved, the loupe stays in focus and magnified: edges \(lifted.sharpest) against \(p.sharpest)")
    // Pincushion: full magnification on the axis, a little more towards the rim, as slight as the
    // real loupe's. The film at four times the canvas's resolution, so its own pixels do not blur the edge.
    try check(LoupeStyle.allCases.allSatisfy { $0.pincushion <= 0.03 && $0.pincushion >= LoupeStyle.schneider10.pincushion }
      && LoupeStyle.pentax.pincushion > LoupeStyle.rodenstock.pincushion,
      "the loupes bow lines at the rim no more than real ones, the Pentax a little more than the aspheric 3×, the Schneider least")
    var edge = scene
    edge.film = image(1600, 1200) { ctx in
      fill(ctx, CGRect(x: 0, y: 0, width: 1600, height: 1200), (0.1, 0.2, 0.8))
      fill(ctx, CGRect(x: 207 * 4, y: 0, width: 1600, height: 1200), (1, 1, 1))
    }
    let wide = Picture(renderer.render(frame: view, scale: 2, pose: pose(.pentax), scene: edge)!)
    var reached: CGFloat = 0
    for x in stride(from: 203.0, to: 240.0, by: 0.5) where reached == 0 && wide.at(CGFloat(x), 150)[1] > 150 { reached = CGFloat(x) }
    try check(reached - 203 > 4 * 5.5 * 0.97 && reached - 203 < 4 * 5.5 * 1.06,
      "film 4 pt off the axis shows \(reached - 203) pt out, near the rim barely further than 5.5× alone would put it")
    // Looking into the eyecup: the lens fills a large circle, magnified as much, with colour fringes at its rim.
    let lensOnScreen: CGFloat = 120, lz = CGFloat(LoupeStyle.pentax.lens.z) * r
    let s = lensOnScreen / (CGFloat(LoupeStyle.pentax.lens.radius) * r), close = lz * s / (s - 1)
    let near = CGRect(x: centre.x - 160, y: centre.y - 160, width: 320, height: 320)
    var dark = scene
    dark.film = image(400, 300) { ctx in
      fill(ctx, CGRect(x: 0, y: 0, width: 400, height: 300), (0, 0, 0))
      fill(ctx, CGRect(x: 203 + 18, y: 0, width: 400, height: 300), (1, 1, 1))
      fill(ctx, CGRect(x: 200, y: 0, width: 6, height: 300), (1, 1, 1))
    }
    var into = pose(.pentax, eye: SIMD3(Float(centre.x), Float(centre.y), Float(close)))
    into.cut = lensOnScreen * LoupeView.rim
    let looked = renderer.render(frame: near, scale: 2, pose: into, scene: dark)!
    let bytes = [UInt8](looked.dataProvider!.data! as Data)
    func px(_ x: CGFloat, _ y: CGFloat) -> [Int] {
      let i = (Int((y - near.minY) * 2) * looked.width + Int((x - near.minX) * 2)) * 4
      return (0..<4).map { Int(bytes[i + $0]) }
    }
    var stripe = 0.0, firstRed: CGFloat = 0, firstBlue: CGFloat = 0
    for x in stride(from: centre.x - 60, to: centre.x + 60, by: 0.5) where px(x, centre.y)[1] > 150 && x < centre.x + 40 { stripe += 0.5 }
    for x in stride(from: centre.x + 40, to: centre.x + 118, by: 0.5) {
      let v = px(x, centre.y)
      if firstRed == 0 && v[0] > 120 { firstRed = x }
      if firstBlue == 0 && v[2] > 120 { firstBlue = x }
    }
    let rim = px(centre.x + lensOnScreen * 1.05, centre.y), beyond = px(centre.x + lensOnScreen * 1.2, centre.y)
    try check(abs(stripe - 33) < 5 && rim[3] == 255 && rim[0] < 70 && rim[1] < 70 && beyond[3] == 0,
      "looking into the eyecup the lens fills a \(Int(lensOnScreen)) pt circle, still 5.5× (stripe \(stripe) pt), inside a thin black rim of the eyecup (\(rim.prefix(3))), the table beyond")
    try check(firstRed > 0 && firstBlue > firstRed + 0.4,
      "near the rim red and blue part a little: an edge shows in red \(firstBlue - firstRed) pt before blue")
    // The glass rim over black film: lit on the side facing the softbox, up and to the left.
    func luma(_ v: [Int]) -> Int { v[0] + v[1] + v[2] }
    let d = lensOnScreen * 0.97 / 2.squareRoot()
    let toward = px(centre.x - d, centre.y - d), away = px(centre.x - d, centre.y + d)
    try check(luma(toward) > luma(away) + 40,
      "the lens's glass rim catches the light on the side facing it: \(luma(toward)) against \(luma(away))")
    // An eye almost at the eyecup sees the rim at a grazing angle: the coating and the eyecup's
    // inside must still mirror the room and the loupe's dark inside, never the bright table.
    var black = scene
    black.film = image(400, 300) { fill($0, CGRect(x: 0, y: 0, width: 400, height: 300), (0, 0, 0)) }
    let grazing: CGFloat = 7, nearEye = lz * grazing / (grazing - 1)
    var almost = pose(.pentax, eye: SIMD3(Float(centre.x), Float(centre.y), Float(nearEye)))
    let rimLens = CGFloat(LoupeStyle.pentax.lens.radius) * r * grazing
    almost.cut = rimLens * LoupeView.rim
    let span = CGRect(x: centre.x - rimLens * 1.2, y: centre.y - rimLens * 1.2, width: rimLens * 2.4, height: rimLens * 2.4)
    let nearRender = renderer.render(frame: span, scale: 1, pose: almost, scene: black)!
    let closeBytes = [UInt8](nearRender.dataProvider!.data! as Data)
    var brightestRim = 0, greenestRim = 0
    for k in 0..<16 {
      let a = Double(k) * .pi / 8
      // Away from the side that faces the light, where the bevel's own glint is allowed.
      if cos(a) * -0.28 + sin(a) * -0.40 > 0.1 { continue }
      for f in [0.86, 0.92, 0.97, 1.05] {
        let x = Int(rimLens * 1.2 + CGFloat(cos(a) * f) * rimLens), y = Int(rimLens * 1.2 + CGFloat(sin(a) * f) * rimLens)
        let i = (y * nearRender.width + x) * 4
        let v = (0..<3).map { Int(closeBytes[i + $0]) }
        brightestRim = max(brightestRim, v.reduce(0, +) / 3)
        greenestRim = max(greenestRim, v[1] - v[0])
      }
    }
    try check(brightestRim < 110 && greenestRim < 30,
      "even with the eye almost at the eyecup the rim mirrors no table: brightest \(brightestRim), green cast \(greenestRim)")
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
    try check(canvas.loupe.isHidden, "the loupe is put away until its key is pressed")
    model.toggleLoupe()
    canvas.updateLoupe()
    settle()
    let loupe = canvas.loupe
    let first = canvas.screen(frames[0].rect.cg)
    try check(!loupe.isHidden && loupe.center == loupe.homeCenter && abs(loupe.center!.x - first.midX) < 1 && abs(loupe.center!.y - first.midY) < 1,
      "the loupe lies on the selected frame on the light table")
    let side = min(canvas.bounds.width, canvas.bounds.height)
    guard let looked = loupe.eyepiece else { throw DeskError.message("FAIL: the loupe is looked into") }
    let lensHeight = CGFloat(LoupeStyle.pentax.lens.z) * looked.radius + loupe.lift / max(1, loupe.radius) * looked.radius
    let nearness = CGFloat(looked.eye.z) / (CGFloat(looked.eye.z) - lensHeight)
    try check(model.preferences.loupeField == .large && abs(looked.lens - 0.32 * side) < 2 && loupe.frame.width > looked.lens * 2
      && looked.extent < looked.lens * 1.2 && abs(nearness - LoupeView.eyeNearness) < 0.01,
      "looked into, its lens fills a large circle, \(Int(looked.lens)) pt in radius on a \(Int(side)) pt canvas, as a real loupe fills the view, with only a thin rim round it")
    // How far from the axis the lens shows the film, out to its rim.
    func reach() -> CGFloat { loupe.style.rimReach * (loupe.eyepiece?.lens ?? 0) / CGFloat(loupe.magnification ?? 99) }
    let tableMM = canvas.loupePointsPerMM ?? 0, frame135 = hypot(18, 12) * tableMM
    let large = loupe.magnification ?? 0
    try check(reach() > frame135 && large > 1.3,
      String(format: "on the light table the 5.5× shows a whole 24 × 36 mm frame, as a real one does: %.0f pt from the axis to the rim, the frame's corner %.0f pt off, magnified %.1f× past the table", reach(), frame135, large))
    let largeReach = reach()
    model.preferences.loupeField = .medium
    canvas.updateLoupe()
    try check(reach() < largeReach - 1 && abs((loupe.magnification ?? 0) - large) < 1e-9,
      String(format: "a smaller field magnifies as much, %.1f×, showing less of the frame: %.0f pt to the rim against %.0f", loupe.magnification ?? 0, reach(), largeReach))
    model.preferences.loupeField = .actual
    canvas.updateLoupe()
    try check(loupe.eyepiece == nil && abs(loupe.frame.width - (loupe.radius * 4.2).rounded()) <= 2,
      "at the film's own scale it lies on the table, seen from afar, as before")
    model.preferences.loupeField = .large
    canvas.updateLoupe()
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
    // The loupe began on frame 01, so it waits for the picture of the frame it now lies on.
    for _ in 0..<50 where canvas.loupeScene().detail == nil || canvas.loupeScene().detailRect != target {
      canvas.updateLoupe()
      settle(0.1)
    }
    let shown = canvas.loupeScene()
    try check(shown.detail != nil && shown.detailRect == target,
      "the lens reads the frame under it at the frame's own resolution (\(shown.detail == nil ? "none" : "\(shown.detailRect)") for \(target))")
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
    loupe.home()
    try check(loupe.center == loupe.homeCenter && model.loupeCenter == nil, "its menu puts the loupe back on the selected frame")
    canvas.setFrameSize(NSSize(width: 1000, height: 640))
    try check(loupe.center == loupe.homeCenter, "where it stays when the window changes size")
    model.select(frames[2].id)
    canvas.setFrameSize(NSSize(width: 990, height: 636))
    let ownFrame = canvas.screen(model.frames[1].rect.cg)
    try check(abs(loupe.center!.x - ownFrame.midX) < 1 && abs(loupe.center!.y - ownFrame.midY) < 1,
      "with another frame selected, the loupe stays on its own frame as the window changes")
    canvas.setFrameSize(NSSize(width: 1000, height: 640))
    model.select(frames[1].id)
    let small = loupe.radius
    model.preferences.loupeStyle = .mamiya
    canvas.updateLoupe()
    try check(loupe.style == .mamiya && loupe.radius > small, "the Mamiya loupe is the larger one")
    try check(reach() > hypot(18, 12) * (canvas.loupePointsPerMM ?? 0), "and it too shows a whole 135 frame")
    model.preferences.loupeStyle = .rodenstock
    canvas.updateLoupe()
    let frame66 = hypot(28, 28) * (canvas.loupePointsPerMM ?? 0), medium = loupe.magnification ?? 0
    try check(loupe.style == .rodenstock && reach() > frame66 && medium >= 1.2 && (loupe.eyepiece?.lens ?? 0) <= 0.46 * min(canvas.bounds.width, canvas.bounds.height) + 0.5,
      String(format: "the 3× for medium format grows its large field, within the canvas, to show a whole 6 × 6 frame: %.0f pt to the rim, the corner %.0f pt off, %.1f×", reach(), frame66, medium))
    model.preferences.loupeStyle = .peak
    canvas.updateLoupe()
    try check(loupe.style == .peak && reach() > frame135 && (loupe.magnification ?? 0) >= 1.2,
      String(format: "the Peak 8× shows a whole 135 frame: %.0f pt to the rim, the corner %.0f pt off, %.1f×", reach(), frame135, loupe.magnification ?? 0))
    let eight = loupe.magnification ?? 0
    model.preferences.loupeStyle = .schneider10
    canvas.updateLoupe()
    try check(loupe.style == .schneider10 && reach() < frame135 && (loupe.magnification ?? 0) > eight,
      String(format: "the Schneider 10× shows part of a frame, magnified most: %.0f pt to the rim, %.1f×", reach(), loupe.magnification ?? 0))
    model.preferences.loupeStyle = .mamiya
    canvas.updateLoupe()
    model.singleView = true
    model.refresh()
    for _ in 0..<40 where model.rendering { settle(0.1) }
    canvas.updateLoupe()
    settle()
    try check(!loupe.isHidden && loupe.center == canvas.loupeHome, "over the single frame the loupe is there too, on the picture's middle")
    let spans = loupe.eyepiece?.lens ?? 0, wanted = min(canvas.imageRect.width / 2, min(canvas.bounds.width, canvas.bounds.height) / 2)
    try check(abs(spans - wanted) < 1.5, String(format: "and its large field is just as wide as the picture: lens %.0f pt across, picture %.0f pt", spans * 2, canvas.imageRect.width))
    for _ in 0..<50 where canvas.loupeScene().detail == nil {
      canvas.updateLoupe()
      settle(0.1)
    }
    let single = canvas.loupeScene(), magnification = canvas.loupeMagnification(for: loupe.style) ?? 0
    let reach = canvas.loupeField, under = CGRect(x: loupe.center!.x - reach, y: loupe.center!.y - reach, width: 2 * reach, height: 2 * reach)
    try check(single.detail != nil && canvas.imageRect.insetBy(dx: -1, dy: -1).contains(single.detailRect)
      && single.detailRect.insetBy(dx: -1, dy: -1).contains(under.intersection(canvas.imageRect)) && magnification >= 2 && magnification <= loupe.style.magnification,
      String(format: "it reads what lies under its lens at the frame's own resolution, magnified %.1f×, no further than its pixels allow", magnification))
    // A sampler picks through the lens the point it shows there, magnified; the loupe stays put.
    let lensCentre = loupe.center!, off = CGPoint(x: lensCentre.x + (loupe.eyepiece?.lens ?? 0) * 0.5, y: lensCentre.y)
    let through = loupe.pictureThroughLens(off), shrink = (1 - loupe.style.pincushion * 0.25) / (loupe.magnification ?? 1)
    try check(loupe.pictureThroughLens(lensCentre) == lensCentre && through.map { abs($0.x - (lensCentre.x + (off.x - lensCentre.x) * shrink)) < 0.01 } == true,
      "the lens shows at each point the picture's point its shader maps there")
    model.useTool(.neutral)
    for _ in 0..<40 where model.rendering { settle(0.1) }
    let unpicked = model.settings.neutralSample
    loupe.mouseDown(with: event(.leftMouseDown, off))
    loupe.mouseUp(with: event(.leftMouseUp, off))
    try check(loupe.center == lensCentre && model.settings.neutralSample != nil && model.settings.neutralSample != unpicked,
      "with the neutral sampler a click on the lens picks the point it shows, and leaves the loupe where it is")
    model.useTool(.select)
    model.singleView = false
    model.toggleLoupe(false)
    canvas.updateLoupe()
    try check(loupe.isHidden, "the loupe can be put away")
    window.close()

    // Settings.
    let suite = "local.epscan.mac.loupe-test"
    UserDefaults().removePersistentDomain(forName: suite)
    let defaults = UserDefaults(suiteName: suite)!
    let fresh = Preferences(defaults: defaults)
    defaults.set(true, forKey: "showLoupe")
    try check(fresh.previewDPI == 600 && !fresh.showLoupe && fresh.loupeStyle == .pentax,
      "previews are 600 dpi and the Pentax loupe is put away until shown, whatever the old setting said")
    try check(fresh.loupeField == .large, "and it is looked into with the large field")
    fresh.previewDPI = 150
    fresh.loupeStyle = .mamiya
    fresh.showLoupe = true
    fresh.loupeField = .small
    let again = Preferences(defaults: defaults)
    try check(again.previewDPI == 150 && again.loupeStyle == .mamiya && again.showLoupe && again.loupeField == .small,
      "preview resolution and the loupe are remembered")
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
