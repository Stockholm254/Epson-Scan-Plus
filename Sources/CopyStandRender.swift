import AppKit
import SceneKit
import SwiftUI

/// The copy stand, rendered in 3D as the user's is built: a black anodised baseboard 380 × 280 mm
/// on four levelling feet; at its back the square column, 600 mm, a scale down its face, standing
/// in its foot block; on it the carriage, its arm reaching out over the board to a geared
/// three-way levelling head; the camera hanging from that, lens straight down, a long macro lens
/// with its hood. On the board under the lens the film carrier: a black light box whose light
/// comes up through the film, the only thing lit from within, the negative glowing in its
/// window. No maker's marks.
enum CopyStandRender {
  private static var done = [String: NSImage]()
  private static let lock = NSLock()
  private static let queue = DispatchQueue(label: "local.epscan.copystand-render", qos: .userInitiated)
  private static var renderer: SCNRenderer?

  static func image(points: CGSize, scale: CGFloat, completion: @escaping (NSImage?) -> Void) {
    let pixels = CGSize(width: (points.width * scale).rounded(), height: (points.height * scale).rounded())
    let key = "\(Int(pixels.width))x\(Int(pixels.height))"
    if let made = lock.withLock({ done[key] }) { completion(made); return }
    queue.async {
      let made = render(pixels: pixels)
      if let made { lock.withLock { done[key] = made } }
      DispatchQueue.main.async { completion(made) }
    }
  }
  static func renderNow(pixels: CGSize) -> NSImage? { queue.sync { render(pixels: pixels) } }

  private static func render(pixels: CGSize) -> NSImage? {
    if renderer == nil {
      guard let device = MTLCreateSystemDefaultDevice() else { return nil }
      renderer = SCNRenderer(device: device, options: nil)
    }
    guard let renderer else { return nil }
    let (scene, camera) = stage(aspect: pixels.width / max(1, pixels.height))
    renderer.scene = scene
    renderer.pointOfView = camera
    return renderer.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X)
  }

  // MARK: Materials

  private static func material(_ diffuse: Any, rough: CGFloat, metal: CGFloat = 0, coat: CGFloat = 0) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = diffuse
    m.roughness.contents = rough
    m.metalness.contents = metal
    if coat > 0 { m.clearCoat.contents = coat; m.clearCoatRoughness.contents = 0.2 }
    return m
  }
  /// Black anodised aluminium: a little metal under the black, a soft sheen.
  private static let anodised = material(NSColor(white: 0.07, alpha: 1), rough: 0.42, metal: 0.55)
  private static let anodisedDark = material(NSColor(white: 0.035, alpha: 1), rough: 0.5, metal: 0.4)
  /// The board and the carrier's top: a bead-blasted black, matt, so the room shows little in it.
  private static let matt = material(NSColor(white: 0.06, alpha: 1), rough: 0.72, metal: 0.2)
  private static let body = material(NSColor(white: 0.05, alpha: 1), rough: 0.55, coat: 0.15)
  private static let rubber = material(NSColor(white: 0.025, alpha: 1), rough: 0.85)
  private static let steel = material(NSColor(white: 0.7, alpha: 1), rough: 0.3, metal: 1)
  private static let white = material(NSColor(white: 0.85, alpha: 1), rough: 0.6)
  private static let glass = material(NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1), rough: 0.05, coat: 1)
  /// Lit from within: what the carrier's light comes up through.
  private static func glowing(_ contents: Any) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = contents
    return m
  }

  private static func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, at p: SCNVector3, chamfer: CGFloat = 1) -> SCNNode {
    let b = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
    b.materials = [m]
    let n = SCNNode(geometry: b)
    n.position = p
    return n
  }
  private static func cylinder(_ r: CGFloat, _ h: CGFloat, _ m: SCNMaterial, at p: SCNVector3, segments: Int = 64) -> SCNNode {
    let c = SCNCylinder(radius: r, height: h)
    c.radialSegmentCount = segments
    c.materials = [m]
    let n = SCNNode(geometry: c)
    n.position = p
    return n
  }
  /// A knob turned on `axis` (x or z), knurled.
  private static func knob(_ r: CGFloat, _ h: CGFloat, at p: SCNVector3, alongX: Bool) -> SCNNode {
    let n = SCNNode()
    n.position = p
    let core = cylinder(r, h, rubber, at: SCNVector3(0, 0, 0), segments: 32)
    n.addChildNode(core)
    for i in 0..<16 {
      let a = CGFloat(i) / 16 * 2 * .pi
      let rib = box(1.1, h * 0.9, 1.1, rubber, at: SCNVector3(r * cos(a), 0, r * sin(a)), chamfer: 0.3)
      rib.eulerAngles.y = -a
      n.addChildNode(rib)
    }
    if alongX { n.eulerAngles.z = .pi / 2 } else { n.eulerAngles.x = .pi / 2 }
    return n
  }

  // MARK: The scene

  /// Where things stand, in millimetres from the board's middle, its top at y = 0.
  static let boardSize = CGSize(width: 380, height: 280), column = (x: CGFloat(70), z: CGFloat(-105), side: CGFloat(40), tall: CGFloat(600))
  /// The lens's axis, over the carrier, and how high the camera's back is.
  static let carrier = (x: CGFloat(76), z: CGFloat(45)), cameraBack: CGFloat = 330

  static func stage(aspect: CGFloat) -> (SCNScene, SCNNode) {
    let scene = SCNScene()
    scene.background.contents = NSColor.clear
    scene.lightingEnvironment.contents = studio
    scene.lightingEnvironment.intensity = 2.0
    let root = scene.rootNode
    // The board, chamfered, on its four feet.
    let w = boardSize.width, d = boardSize.height
    root.addChildNode(box(w, 10, d, matt, at: SCNVector3(0, -5, 0), chamfer: 2.5))
    for (fx, fz) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
      let x = CGFloat(fx) * (w / 2 - 22), z = CGFloat(fz) * (d / 2 - 22)
      root.addChildNode(cylinder(10, 9, anodisedDark, at: SCNVector3(x, -14.5, z)))
      root.addChildNode(cylinder(12, 3, rubber, at: SCNVector3(x, -20.5, z)))
    }
    // The column in its foot block, a scale down its front face, a cap on top.
    let c = column
    root.addChildNode(box(78, 58, 70, anodised, at: SCNVector3(c.x, 29, c.z), chamfer: 3))
    root.addChildNode(box(c.side, c.tall, c.side, anodised, at: SCNVector3(c.x, c.tall / 2, c.z), chamfer: 2))
    root.addChildNode(box(c.side + 2, 8, c.side + 2, anodisedDark, at: SCNVector3(c.x, c.tall + 4, c.z), chamfer: 2))
    var mark: CGFloat = 70
    while mark < c.tall - 10 {
      let long = Int(mark.rounded()) % 50 == 0
      root.addChildNode(box(long ? 9 : 5, 0.8, 0.4, white, at: SCNVector3(c.x - c.side / 2 + (long ? 6.5 : 4.5), mark, c.z + c.side / 2 + 0.3), chamfer: 0))
      mark += 10
    }
    // The carriage at the camera's height, clamped by its knobs; a short arm out of it, and on
    // the arm the geared levelling head, two stages with a knob each, its last plate upright,
    // the camera's foot screwed to it: the camera hangs right in front of the column.
    let mid = cameraBack - 24, front = c.z + c.side / 2
    root.addChildNode(box(62, 96, 58, anodised, at: SCNVector3(c.x, mid, c.z), chamfer: 3))
    root.addChildNode(knob(13, 14, at: SCNVector3(c.x + 38, mid + 22, c.z), alongX: true))
    root.addChildNode(knob(9, 10, at: SCNVector3(c.x + 36, mid - 26, c.z), alongX: true))
    root.addChildNode(box(40, 34, 30, anodised, at: SCNVector3(c.x, mid, front + 15), chamfer: 2.5))
    root.addChildNode(box(66, 44, 22, anodised, at: SCNVector3(c.x, mid, front + 41), chamfer: 2))
    root.addChildNode(knob(9, 12, at: SCNVector3(c.x + 40, mid, front + 41), alongX: true))
    root.addChildNode(box(60, 50, 20, anodisedDark, at: SCNVector3(c.x, mid, front + 62), chamfer: 2))
    root.addChildNode(knob(9, 12, at: SCNVector3(c.x, mid + 31, front + 62), alongX: false))
    root.addChildNode(box(72, 58, 6, anodised, at: SCNVector3(c.x, mid, front + 75), chamfer: 1.5))
    // The quick-release clamp between the plate and the camera's foot.
    root.addChildNode(box(46, 34, 8, anodisedDark, at: SCNVector3(c.x, mid, front + 82), chamfer: 1))
    // The camera, turned so its top faces out and its foot the column, its lens over the carrier.
    let cam = camera()
    cam.eulerAngles.y = .pi
    cam.position = SCNVector3(carrier.x - 6, cameraBack, carrier.z + 4)
    root.addChildNode(cam)
    // The carrier on the board under it, the only thing lit from within.
    root.addChildNode(filmCarrier(at: SCNVector3(carrier.x, 0, carrier.z)))
    // The room's light, soft, from up to the left; the carrier's own light, up into the lens.
    let key = SCNNode()
    key.light = SCNLight()
    key.light!.type = .directional
    key.light!.intensity = 650
    key.light!.castsShadow = true
    key.light!.shadowMode = .deferred
    key.light!.shadowRadius = 10
    key.light!.shadowSampleCount = 24
    key.light!.shadowColor = NSColor(white: 0, alpha: 0.42)
    key.light!.orthographicScale = 800
    key.light!.zFar = 3000
    key.position = SCNVector3(-600, 1000, 550)
    key.look(at: SCNVector3(0, 200, 0))
    root.addChildNode(key)
    let up = SCNNode()
    up.light = SCNLight()
    up.light!.type = .spot
    up.light!.intensity = 900
    up.light!.spotInnerAngle = 30
    up.light!.spotOuterAngle = 70
    up.light!.color = NSColor(white: 1, alpha: 1)
    up.position = SCNVector3(carrier.x, 24, carrier.z)
    up.eulerAngles.x = .pi / 2
    root.addChildNode(up)
    // A light from behind on the right, drawing the black parts' edges.
    let rim = SCNNode()
    rim.light = SCNLight()
    rim.light!.type = .directional
    rim.light!.intensity = 600
    rim.position = SCNVector3(800, 320, -200)
    rim.look(at: SCNVector3(0, 250, 0))
    root.addChildNode(rim)
    let fill = SCNNode()
    fill.light = SCNLight()
    fill.light!.type = .ambient
    fill.light!.intensity = 260
    root.addChildNode(fill)
    let floor = SCNFloor()
    floor.reflectivity = 0
    let catcher = SCNMaterial()
    catcher.lightingModel = .shadowOnly
    floor.materials = [catcher]
    let floorNode = SCNNode(geometry: floor)
    floorNode.position.y = -22.05
    root.addChildNode(floorNode)
    // From the front, a little to the left and above the board, as the stand is photographed.
    let viewer = SCNNode()
    viewer.camera = SCNCamera()
    let lens: CGFloat = 22
    viewer.camera!.fieldOfView = lens
    viewer.camera!.zNear = 20
    viewer.camera!.zFar = 8000
    viewer.camera!.wantsHDR = true
    viewer.camera!.wantsExposureAdaptation = false
    let tallView: CGFloat = 690, wideView: CGFloat = 470 / max(0.1, aspect)
    let fit = max(tallView, wideView) * 1.14
    let distance = fit / 2 / tan(lens / 2 * .pi / 180)
    let yaw: CGFloat = -0.55, pitch: CGFloat = 0.2
    let target = SCNVector3(10, 290, -10)
    viewer.position = SCNVector3(target.x + distance * cos(pitch) * sin(yaw), target.y + distance * sin(pitch), target.z + distance * cos(pitch) * cos(yaw))
    viewer.look(at: target)
    root.addChildNode(viewer)
    return (scene, viewer)
  }

  /// A plain mirrorless body hanging lens down, its back up, the finder towards the column; a
  /// long macro lens with its focusing ring and hood, the front glass looking at the film.
  private static func camera() -> SCNNode {
    let node = SCNNode()
    // Its own frame: the lens axis −y; the body 132 wide (x), 96 tall (z, its top towards the
    // column, −z), 48 deep (y, its back up).
    let w: CGFloat = 132, h: CGFloat = 96, d: CGFloat = 48
    node.addChildNode(box(w, d, h, body, at: SCNVector3(0, -d / 2, 0), chamfer: 7))
    node.addChildNode(box(38, d + 20, h - 8, rubber, at: SCNVector3(w / 2 - 20, -d / 2 - 10, 3), chamfer: 11))
    node.addChildNode(box(58, d - 4, 24, body, at: SCNVector3(-2, -d / 2, -h / 2 - 8), chamfer: 6))
    node.addChildNode(box(30, 7, 22, rubber, at: SCNVector3(-2, 3, -h / 2 + 2), chamfer: 3))
    node.addChildNode(box(78, 1.2, 54, glass, at: SCNVector3(-10, 0.4, 8), chamfer: 0.6))
    for x: CGFloat in [28, 46] {
      let dial = cylinder(8, 8, anodisedDark, at: SCNVector3(x, -d / 2 + 4, -h / 2 - 3))
      dial.eulerAngles.x = .pi / 2
      node.addChildNode(dial)
    }
    // The mount and a 90 mm macro lens: the barrel, its wide ribbed focusing ring, the hood.
    let mountY = -d
    node.addChildNode(cylinder(30, 4, steel, at: SCNVector3(-6, mountY - 2, 4)))
    node.addChildNode(cylinder(34, 36, body, at: SCNVector3(-6, mountY - 22, 4)))
    let ring = SCNTube(innerRadius: 34, outerRadius: 35.8, height: 34)
    ring.radialSegmentCount = 120
    ring.materials = [rubber]
    let ringNode = SCNNode(geometry: ring)
    ringNode.position = SCNVector3(-6, mountY - 58, 4)
    node.addChildNode(ringNode)
    for i in 0..<48 {
      let ang = CGFloat(i) / 48 * 2 * .pi
      let rib = box(1.4, 32, 1.2, rubber, at: SCNVector3(-6 + 36 * cos(ang), mountY - 58, 4 + 36 * sin(ang)), chamfer: 0.3)
      rib.eulerAngles.y = -ang
      node.addChildNode(rib)
    }
    node.addChildNode(cylinder(33, 22, body, at: SCNVector3(-6, mountY - 86, 4)))
    let hood = SCNTube(innerRadius: 33, outerRadius: 36, height: 44)
    hood.radialSegmentCount = 96
    hood.materials = [rubber, rubber, rubber, rubber]
    let hoodNode = SCNNode(geometry: hood)
    hoodNode.position = SCNVector3(-6, mountY - 119, 4)
    node.addChildNode(hoodNode)
    node.addChildNode(cylinder(28, 1, glass, at: SCNVector3(-6, mountY - 100, 4)))
    return node
  }

  /// The film carrier: a black light box on the board, a stepped frame on it, and in its window
  /// a strip of colour negative lit from beneath, glowing orange, the white of the light round it.
  private static func filmCarrier(at p: SCNVector3) -> SCNNode {
    let node = SCNNode()
    node.position = p
    node.addChildNode(box(200, 22, 170, matt, at: SCNVector3(0, 11, 0), chamfer: 2))
    let frame = NSBezierPath(roundedRect: NSRect(x: -80, y: -70, width: 160, height: 140), xRadius: 3, yRadius: 3)
    frame.append(NSBezierPath(roundedRect: NSRect(x: -58, y: -42, width: 116, height: 84), xRadius: 2, yRadius: 2))
    frame.windingRule = .evenOdd
    let shape = SCNShape(path: frame, extrusionDepth: 9)
    shape.chamferRadius = 1
    shape.materials = [matt]
    let shapeNode = SCNNode(geometry: shape)
    shapeNode.eulerAngles.x = -.pi / 2
    shapeNode.position.y = 22 + 4.5
    node.addChildNode(shapeNode)
    // The light's diffuser in the window, and over it the negative: its frames, its base.
    let light = SCNPlane(width: 116, height: 84)
    light.materials = [glowing(NSColor(white: 1, alpha: 1))]
    let lightNode = SCNNode(geometry: light)
    lightNode.eulerAngles.x = -.pi / 2
    lightNode.position.y = 22.2
    node.addChildNode(lightNode)
    let picture = NSImage(size: NSSize(width: 360, height: 210))
    picture.lockFocus()
    NSColor(red: 0.95, green: 0.6, blue: 0.34, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 360, height: 210).fill()
    // A frame of the negative: dense sky over thin ground.
    NSGradient(colors: [NSColor(red: 0.7, green: 0.36, blue: 0.18, alpha: 1), NSColor(red: 0.42, green: 0.18, blue: 0.09, alpha: 1)])?
      .draw(in: NSRect(x: 30, y: 33, width: 300, height: 144), angle: 90)
    NSColor.white.setFill()
    var x: CGFloat = 4
    while x < 360 {
      NSBezierPath(roundedRect: NSRect(x: x, y: 8, width: 16, height: 11), xRadius: 2.5, yRadius: 2.5).fill()
      NSBezierPath(roundedRect: NSRect(x: x, y: 191, width: 16, height: 11), xRadius: 2.5, yRadius: 2.5).fill()
      x += 27
    }
    picture.unlockFocus()
    // A strip of 35 mm across the window, the light white past its ends and edges.
    let film = SCNPlane(width: 96, height: 35)
    film.materials = [glowing(picture)]
    let filmNode = SCNNode(geometry: film)
    filmNode.eulerAngles.x = -.pi / 2
    filmNode.position.y = 22.5
    node.addChildNode(filmNode)
    return node
  }

  private static let studio: NSImage = {
    let w = 512, h = 256
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    NSGradient(starting: NSColor(white: 0.55, alpha: 1), ending: NSColor(white: 0.12, alpha: 1))?.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
    NSColor(white: 1, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 150, width: 170, height: 70), xRadius: 10, yRadius: 10).fill()
    NSColor(white: 0.75, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 370, y: 130, width: 46, height: 90), xRadius: 8, yRadius: 8).fill()
    image.unlockFocus()
    return image
  }()
}

/// The copy stand, rendered, in a SwiftUI view.
struct CopyStandObject: View {
  @State private var image: NSImage?
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    GeometryReader { g in
      ZStack {
        if let image { Image(nsImage: image).resizable().interpolation(.high).transition(.opacity) }
      }
      .frame(width: g.size.width, height: g.size.height)
      .task(id: "\(Int(g.size.width))x\(Int(g.size.height))") {
        let size = g.size
        await withCheckedContinuation { done in
          CopyStandRender.image(points: size, scale: max(2, displayScale)) { made in
            withAnimation(.easeOut(duration: 0.2)) { image = made }
            done.resume()
          }
        }
      }
    }.accessibilityHidden(true)
  }
}
