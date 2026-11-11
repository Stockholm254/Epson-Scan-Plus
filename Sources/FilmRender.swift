import AppKit
import SceneKit
import SwiftUI

/// Film as it comes, rendered in 3D to its real size: a 135 cassette (a lithographed steel shell
/// 25 mm across, crimped end caps, the spool's knob, the felt-lined lip and the leader out of it,
/// cut to its tongue with its perforations) or a 120 roll (backing paper on a black spool, held
/// by its seal), lit by a softbox over a soft contact shadow. The label carries the maker, the
/// stock and its speed in the maker's usual colours, with the DX squares and bar code a cassette
/// has; it does not copy any maker's artwork. A film the catalog lacks, or a preset calibrated on
/// this Mac, comes in a plain reloadable cassette with a written tape.
enum FilmRender {
  /// What one picture shows.
  struct Key: Hashable {
    var look: String
    var gauge: FilmStock.Gauge
    var pixels: CGSize
  }
  private static var done = [Key: NSImage]()
  private static let lock = NSLock()
  private static let queue = DispatchQueue(label: "local.epscan.film-render", qos: .userInitiated)
  private static var renderer: SCNRenderer?

  /// The picture, from those made, or made on the render queue and handed back on the main thread.
  static func image(_ look: NewProjectSheet.Look, gauge: FilmStock.Gauge, points: CGSize, scale: CGFloat, completion: @escaping (NSImage?) -> Void) {
    let key = Key(look: look.renderKey, gauge: gauge, pixels: CGSize(width: (points.width * scale).rounded(), height: (points.height * scale).rounded()))
    if let made = lock.withLock({ done[key] }) { completion(made); return }
    queue.async {
      let made = render(look, gauge: gauge, pixels: key.pixels)
      if let made { lock.withLock { done[key] = made } }
      DispatchQueue.main.async { completion(made) }
    }
  }
  /// Readies the renderer (its Metal shaders take most of a second the first time) and draws the
  /// open roll's film for ②, on the render queue, once.
  private static var warmed = false
  static func prewarm(_ m: AppModel) {
    guard !warmed else { return }
    warmed = true
    let now = NewProjectSheet.current(m)
    let look = NewProjectSheet.look(now, m: m), gauge = NewProjectSheet.gauge(now, format: m.format)
    image(look, gauge: gauge, points: CGSize(width: 38, height: 50), scale: max(2, NSScreen.main?.backingScaleFactor ?? 2)) { _ in }
  }
  /// The same, at once, for a test or a window shot; turned `turn` radians about its axis and
  /// seen `widen` times as wide, as its turn shows it.
  static func renderNow(_ look: NewProjectSheet.Look, gauge: FilmStock.Gauge, pixels: CGSize, turn: CGFloat = 0, widen: CGFloat = 1) -> NSImage? {
    queue.sync { render(look, gauge: gauge, pixels: pixels, turn: turn, widen: widen) }
  }
  /// A film's scene to turn live, for a picture of `points`, made on the render queue (its labels
  /// take a moment to print) and handed back on the main thread, with how much wider than the
  /// picture its view is.
  static func turning(_ look: NewProjectSheet.Look, gauge: FilmStock.Gauge, points: CGSize, completion: @escaping (Stage, CGFloat) -> Void) {
    let aspect = points.width / max(1, points.height)
    let widen = turnWiden(gauge, aspect: aspect)
    queue.async {
      let set = stage(look, gauge: gauge, aspect: aspect, widen: widen)
      DispatchQueue.main.async { completion(set, widen) }
    }
  }

  // MARK: The scene

  private static func render(_ look: NewProjectSheet.Look, gauge: FilmStock.Gauge, pixels: CGSize, turn: CGFloat = 0, widen: CGFloat = 1) -> NSImage? {
    if renderer == nil {
      guard let device = MTLCreateSystemDefaultDevice() else { return nil }
      renderer = SCNRenderer(device: device, options: nil)
    }
    guard let renderer else { return nil }
    let set = stage(look, gauge: gauge, aspect: pixels.width / max(1, pixels.height), widen: widen)
    set.film.eulerAngles.y = turn
    renderer.scene = set.scene
    renderer.pointOfView = set.camera
    return renderer.snapshot(atTime: 0, with: CGSize(width: (pixels.width * widen).rounded(), height: (pixels.height * widen).rounded()), antialiasingMode: .multisampling4X)
  }

  /// A film's scene and the camera on it, for a picture of `aspect`: the film, its floor and its
  /// lights. `widen` sees that many times as far across and up from the same place, so the
  /// picture's middle is the picture itself: room for the leader as the cassette turns.
  struct Stage {
    var scene: SCNScene
    var camera: SCNNode
    /// What turns, about the film's own axis.
    var film: SCNNode
  }
  static func stage(_ look: NewProjectSheet.Look, gauge: FilmStock.Gauge, aspect: CGFloat, widen: CGFloat = 1) -> Stage {
    let scene = SCNScene()
    scene.background.contents = NSColor.clear
    scene.lightingEnvironment.contents = studio
    let film = gauge == .mm135 ? cassette(look) : roll(look)
    scene.rootNode.addChildNode(film)
    let (bottom, top, left, right) = extent(gauge)
    // A floor that only takes the shadow.
    let floor = SCNFloor()
    floor.reflectivity = 0
    let catcher = SCNMaterial()
    catcher.lightingModel = .shadowOnly
    floor.materials = [catcher]
    let floorNode = SCNNode(geometry: floor)
    floorNode.position = SCNVector3(0, bottom, 0)
    scene.rootNode.addChildNode(floorNode)
    // A softbox up to the left (the shadow's), a rim from behind on the right, little else.
    let key = SCNNode()
    key.light = SCNLight()
    key.light!.type = .directional
    key.light!.intensity = 1100
    key.light!.castsShadow = true
    key.light!.shadowMode = .deferred
    key.light!.shadowRadius = 9
    key.light!.shadowSampleCount = 32
    key.light!.shadowColor = NSColor(white: 0, alpha: 0.5)
    // Over all the floor the leader may reach as it turns, where the view is wider.
    key.light!.orthographicScale = 70 * widen
    key.light!.zFar = 400
    key.position = SCNVector3(-80, 120, 90)
    key.look(at: SCNVector3(0, bottom, 0))
    scene.rootNode.addChildNode(key)
    let rim = SCNNode()
    rim.light = SCNLight()
    rim.light!.type = .directional
    rim.light!.intensity = 520
    rim.position = SCNVector3(90, 40, -90)
    rim.look(at: SCNVector3(0, 0, 0))
    scene.rootNode.addChildNode(rim)
    let fill = SCNNode()
    fill.light = SCNLight()
    fill.light!.type = .ambient
    fill.light!.intensity = 70
    scene.rootNode.addChildNode(fill)
    scene.lightingEnvironment.intensity = 1.9
    // A long lens from a little above, the film and its leader filling the frame.
    let camera = SCNNode()
    camera.camera = SCNCamera()
    let lens: CGFloat = 16
    camera.camera!.fieldOfView = 2 * atan(widen * tan(lens / 2 * .pi / 180)) * 180 / .pi
    camera.camera!.zNear = 10
    camera.camera!.zFar = 2000
    camera.camera!.wantsHDR = true
    camera.camera!.wantsExposureAdaptation = false
    camera.camera!.exposureOffset = 0.1
    let fit = framing(gauge, aspect: aspect)
    let distance = fit / 2 / tan(lens / 2 * .pi / 180)
    let centre = SCNVector3((left + right) / 2, (top + bottom) / 2, 0)
    let elevation: CGFloat = gauge == .mm135 ? 0.4 : 0.2
    camera.position = SCNVector3(centre.x, centre.y + distance * sin(elevation), distance * cos(elevation))
    camera.look(at: SCNVector3(centre.x, centre.y - 0.5, 0))
    scene.rootNode.addChildNode(camera)
    return Stage(scene: scene, camera: camera, film: film)
  }
  /// Where a film stands and how far it reaches, in millimetres: the cassette from its spool's foot
  /// to its knob, its leader out to the right; the roll from flange end to flange end.
  static func extent(_ gauge: FilmStock.Gauge) -> (bottom: CGFloat, top: CGFloat, left: CGFloat, right: CGFloat) {
    gauge == .mm135 ? (-22.0, 33, -23, 25) : (-33.7, 33.7, -13.6, 13.6)
  }
  /// How tall the view is, in millimetres at the film, for a picture of `aspect`.
  static func framing(_ gauge: FilmStock.Gauge, aspect: CGFloat) -> CGFloat {
    let e = extent(gauge)
    return max((e.top - e.bottom) * 1.14, (e.right - e.left) * 1.1 / max(0.01, aspect))
  }
  /// How much wider than its picture a film's turn needs: the leader, curled back round behind
  /// the cassette, reaches some 44 mm from its axis, and nearer the camera it looks larger.
  static func turnWiden(_ gauge: FilmStock.Gauge, aspect: CGFloat) -> CGFloat {
    let e = extent(gauge), reach: CGFloat = gauge == .mm135 ? 44 : 13.6
    let across = framing(gauge, aspect: aspect) * aspect
    let needed = 2 * (reach * 1.22 + abs(e.left + e.right) / 2 + 2)
    return max(1, needed / across)
  }

  /// The studio the metal reflects: dark, a large softbox up to the left, a strip to the right.
  private static let studio: NSImage = {
    let w = 1024, h = 512
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    NSColor(white: 0.06, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(white: 0.04, alpha: 1))?.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
    func box(_ r: NSRect, _ white: CGFloat, _ blur: CGFloat) {
      for i in 0..<8 {
        let k = CGFloat(i) / 7
        NSColor(white: white, alpha: 0.18 * (1 - k * 0.6)).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: -blur * k, dy: -blur * k), xRadius: 12, yRadius: 12).fill()
      }
      NSColor(white: white, alpha: 1).setFill()
      NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
    }
    box(NSRect(x: 300, y: 300, width: 210, height: 130), 1.0, 40)
    box(NSRect(x: 760, y: 220, width: 46, height: 200), 0.55, 24)
    box(NSRect(x: 40, y: 250, width: 70, height: 90), 0.35, 20)
    image.unlockFocus()
    return image
  }()

  // MARK: Materials

  private static func material(_ diffuse: Any, metal: CGFloat, rough: CGFloat, coat: CGFloat = 0) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = diffuse
    m.metalness.contents = metal
    m.roughness.contents = rough
    if coat > 0 {
      m.clearCoat.contents = coat
      m.clearCoatRoughness.contents = 0.08
    }
    return m
  }
  private static let steel = material(NSColor(white: 0.78, alpha: 1), metal: 1, rough: 0.26)
  private static let darkSteel = material(NSColor(white: 0.32, alpha: 1), metal: 1, rough: 0.34)
  private static let blackPlastic = material(NSColor(white: 0.035, alpha: 1), metal: 0, rough: 0.3, coat: 0.4)
  private static let felt = material(NSColor(white: 0.02, alpha: 1), metal: 0, rough: 1)

  // MARK: 135

  /// The black paint of a cassette's end caps, and a reloadable cassette's plastic.
  private static let capPaint = material(NSColor(white: 0.03, alpha: 1), metal: 0.5, rough: 0.3, coat: 0.7)
  private static let reloadable = material(NSColor(white: 0.04, alpha: 1), metal: 0, rough: 0.42, coat: 0.25)

  /// A 135 cassette as the photographs show it: the printed shell, its lip running on from it down
  /// the right side, the mouth lined with black felt; black end caps crimped over it, their rolled
  /// bead standing well above a dished face, a collar round the spool; the spool's knob a wide thin-walled tube
  /// with its lugs deep inside, the hub nearly flush below; and the leader out of the mouth,
  /// curling out to the right, perforated, cut to its tongue.
  private static func cassette(_ look: NewProjectSheet.Look) -> SCNNode {
    let node = SCNNode()
    let r = Shell.radius, h: CGFloat = 38
    let plain = look.named || look.calibrated
    // The shell and its lip, one sheet: the print round it and on out along the lip, the mouth in felt.
    let shell = Shell.geometry(height: h)
    shell.materials = [plain ? reloadable : material(Label.cassette(look), metal: 0.15, rough: 0.28, coat: 1), velvet, plain ? reloadable : capPaint]
    node.addChildNode(SCNNode(geometry: shell))
    if plain {
      // A reloadable cassette's tape, written on.
      let tape = SCNTube(innerRadius: r + 0.01, outerRadius: r + 0.12, height: 15)
      tape.radialSegmentCount = 128
      tape.materials = [material(Label.tape(look), metal: 0, rough: 0.6), material(NSColor(white: 0.95, alpha: 1), metal: 0, rough: 0.6)]
      let tapeNode = SCNNode(geometry: tape)
      tapeNode.eulerAngles.y = -.pi / 2 + 0.35
      tapeNode.position.y = 1
      node.addChildNode(tapeNode)
    }
    let ends = plain ? reloadable : capPaint
    /// A part turned round the cassette's axis, at `y`, its height (a torus's) `flat` of its width.
    func turned(_ g: SCNGeometry, _ m: SCNMaterial, y: CGFloat, flat: CGFloat = 1) {
      g.materials = [m]
      let n = SCNNode(geometry: g)
      n.position.y = y
      n.scale.y = flat
      node.addChildNode(n)
    }
    // The end caps as the photographs show them, pressed steel painted black: a skirt crimped over
    // the shell's end, its edge rolled into a bead standing above the face; the face dished in
    // below the bead; round the spool's hole a raised collar.
    var faceTop: CGFloat = 0
    for top in [true, false] {
      let y = top ? h / 2 : -h / 2, out: CGFloat = top ? 1 : -1
      // The skirt rises well above the face, a wall round it, the bead rolled on its top.
      let skirt = SCNTube(innerRadius: r - 0.05, outerRadius: r + 0.5, height: 2.9)
      skirt.radialSegmentCount = 128
      turned(skirt, ends, y: y + out * 0.75)
      let bead = SCNTorus(ringRadius: r + 0.05, pipeRadius: 0.55)
      bead.ringSegmentCount = 128
      turned(bead, ends, y: y + out * 2.2)
      let face = SCNCylinder(radius: r - 0.2, height: 0.5)
      face.radialSegmentCount = 128
      turned(face, ends, y: y + out * 1.2)
      let collar = SCNTube(innerRadius: 5.85, outerRadius: 7.3, height: 0.5)
      collar.radialSegmentCount = 96
      turned(collar, ends, y: y + out * 1.6)
      let collarEdge = SCNTorus(ringRadius: 6.58, pipeRadius: 0.72)
      collarEdge.ringSegmentCount = 96
      turned(collarEdge, ends, y: y + out * 1.7, flat: 0.55)
      if top { faceTop = y + 1.45 }
    }
    // The spool's knob: a plastic tube about 11.6 mm across, its wall 1.2 mm, standing 6.6 mm proud
    // of the face, its mouth rounded; inside, deep down, the two lugs a camera's rewind fork takes.
    let knob = SCNTube(innerRadius: 4.6, outerRadius: 5.8, height: 6.4)
    knob.radialSegmentCount = 96
    knob.materials = [blackPlastic, blackPlastic, blackPlastic, blackPlastic]
    let knobNode = SCNNode(geometry: knob)
    knobNode.position.y = faceTop + 3.2
    node.addChildNode(knobNode)
    let mouth = SCNTorus(ringRadius: 5.2, pipeRadius: 0.6)
    mouth.ringSegmentCount = 96
    turned(mouth, blackPlastic, y: faceTop + 6.4, flat: 0.4)
    let floor = SCNCylinder(radius: 4.62, height: 0.4)
    floor.radialSegmentCount = 64
    turned(floor, felt, y: faceTop + 0.9)
    let lugs = SCNNode()
    lugs.eulerAngles.y = 0.5
    for side: CGFloat in [-1, 1] {
      let lug = SCNBox(width: 1.3, height: 2.2, length: 1.6, chamferRadius: 0.25)
      lug.materials = [blackPlastic]
      let lugNode = SCNNode(geometry: lug)
      lugNode.position = SCNVector3(side * 4.05, faceTop + 2.2, 0)
      lugs.addChildNode(lugNode)
    }
    node.addChildNode(lugs)
    // Below, the spool's other end, nearly flush with the cap.
    let hub = SCNTube(innerRadius: 2.4, outerRadius: 4.2, height: 0.9)
    hub.materials = [blackPlastic, blackPlastic, blackPlastic, blackPlastic]
    let hubNode = SCNNode(geometry: hub)
    hubNode.position.y = -h / 2 - 1.45 - 0.35
    node.addChildNode(hubNode)
    // The leader out of the lip's mouth, from between its felts, along the lip.
    let leader = curledLeader(look)
    let e = Shell.exit, radial = r - Shell.gap / 2, along = Shell.reach - 0.4
    leader.position = SCNVector3(radial * sin(e) + along * cos(e), 0, radial * cos(e) - along * sin(e))
    leader.eulerAngles.y = e
    node.addChildNode(leader)
    return node
  }
  /// A 135 shell seen from above, as it is made, of one sheet of steel: rolled round, its two ends
  /// carried out together along the tangent at `exit` (some 53° right of the front) as the lip,
  /// `gap` apart with the felt and the film between them, `reach` out from where the outer end
  /// leaves the round; so the lip runs smoothly on from the round, the print with it, and the inner
  /// end leaves the round further on, in a crease.
  enum Shell {
    static let radius: CGFloat = 12.4, exit: CGFloat = 0.92, gap: CGFloat = 2.6, reach: CGFloat = 10.5
    /// The angle round of the print's front, from the camera: a little to the right, where the
    /// shelf's view centres the face between its left edge and the lip.
    static let front: CGFloat = 0.12
    /// How much further round the inner end leaves the round, and how far along the lip that is.
    static var bend: CGFloat { acos((radius - gap) / radius) }
    static var inner: CGFloat { (radius * radius - (radius - gap) * (radius - gap)).squareRoot() }
    /// Millimetres round the outline, from where the inner end leaves the round: the round, the
    /// outer lip, the mouth, the inner lip back.
    static var round: CGFloat { radius * (2 * .pi - bend) + reach + gap + reach - inner }
    /// Where the print's front is along it.
    static var frontAt: CGFloat { radius * (2 * .pi + front - exit - bend) }
    /// The shell's side all round, the felt across the mouth, and the lip's top and foot (where it
    /// stands out of the end caps): three elements, for the print, the felt and the steel.
    static func geometry(height h: CGFloat) -> SCNGeometry {
      let r = radius, e = exit, t = gap, l = reach
      let n = CGPoint(x: sin(e), y: cos(e)), d = CGPoint(x: cos(e), y: -sin(e))
      func at(_ base: CGPoint, _ k: CGFloat, _ v: CGPoint) -> CGPoint { CGPoint(x: base.x + k * v.x, y: base.y + k * v.y) }
      let outer = CGPoint(x: r * n.x, y: r * n.y)
      let mouthOut = at(outer, l, d), mouthIn = at(at(outer, -t, n), l, d), crease = at(at(outer, -t, n), inner, d)
      var vertices = [SCNVector3](), normals = [SCNVector3](), uv = [CGPoint]()
      var side = [Int32](), felt = [Int32](), ends = [Int32]()
      let total = round
      // A run of the outline (points with their outward normals) stood up into the side.
      func stand(_ points: [(CGPoint, CGPoint)], from s0: CGFloat, into list: inout [Int32]) -> CGFloat {
        var s = s0
        for (i, (q, normal)) in points.enumerated() {
          if i > 0 { s += hypot(q.x - points[i - 1].0.x, q.y - points[i - 1].0.y) }
          let base = Int32(vertices.count)
          for top in [true, false] {
            vertices.append(SCNVector3(q.x, top ? h / 2 : -h / 2, q.y))
            normals.append(SCNVector3(normal.x, 0, normal.y))
            uv.append(CGPoint(x: s / total, y: top ? 0 : 1))
          }
          if i > 0 { list += [base - 2, base - 1, base, base, base - 1, base + 1] }
        }
        return s
      }
      let steps = 256
      var round = (0...steps).map { i -> (CGPoint, CGPoint) in
        let a = e + bend + (2 * .pi - bend) * CGFloat(i) / CGFloat(steps)
        return (CGPoint(x: r * sin(a), y: r * cos(a)), CGPoint(x: sin(a), y: cos(a)))
      }
      round.append((mouthOut, n))
      var s = stand(round, from: 0, into: &side)
      s = stand([(mouthOut, d), (mouthIn, d)], from: s, into: &felt)
      _ = stand([(mouthIn, CGPoint(x: -n.x, y: -n.y)), (crease, CGPoint(x: -n.x, y: -n.y))], from: s, into: &side)
      for top in [true, false] {
        let base = Int32(vertices.count)
        for q in [outer, mouthOut, mouthIn, crease] {
          vertices.append(SCNVector3(q.x, top ? h / 2 : -h / 2, q.y))
          normals.append(SCNVector3(0, top ? 1 : -1, 0))
          uv.append(.zero)
        }
        ends += top ? [base, base + 1, base + 2, base, base + 2, base + 3] : [base, base + 2, base + 1, base, base + 3, base + 2]
      }
      return SCNGeometry(
        sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals), SCNGeometrySource(textureCoordinates: uv)],
        elements: [side, felt, ends].map { SCNGeometryElement(indices: $0, primitiveType: .triangles) })
    }
  }
  /// Black felt: no shine, a little fuzz.
  private static let velvet: SCNMaterial = {
    let m = material(NSColor(white: 0.025, alpha: 1), metal: 0, rough: 1)
    m.normal.contents = Label.fuzz
    m.normal.intensity = 0.6
    return m
  }()
  /// The leader as it hangs out of a cassette in the photographs: 35 mm film, straight out of the
  /// mouth for 6 mm, then curling back round behind the cassette on a 24 mm radius, clear of it,
  /// for some 160°, its tongue ending behind on the left; a strip of quads along that path with its
  /// picture (`Label.leader`) cutting the perforations and the tongue.
  private static func curledLeader(_ look: NewProjectSheet.Look) -> SCNNode {
    let length: CGFloat = 72, straight: CGFloat = 6, radius: CGFloat = 24, width: CGFloat = 35
    var vertices = [SCNVector3](), normals = [SCNVector3](), uv = [CGPoint]()
    let n = 120
    for i in 0...n {
      let s = length * CGFloat(i) / CGFloat(n)
      // Along the tangent out of the mouth (x), then bending inwards (−z, towards the back).
      var (x, z, nx, nz): (CGFloat, CGFloat, CGFloat, CGFloat) = (s, 0, 0, 1)
      if s > straight {
        let phi = (s - straight) / radius
        (x, z, nx, nz) = (straight + radius * sin(phi), -radius * (1 - cos(phi)), sin(phi), cos(phi))
      }
      for top in [true, false] {
        vertices.append(SCNVector3(x, top ? width / 2 : -width / 2, z))
        normals.append(SCNVector3(nx, 0, nz))
        uv.append(CGPoint(x: s / length, y: top ? 0 : 1))
      }
    }
    var indices = [Int32]()
    for i in 0..<n {
      let a = Int32(i * 2)
      indices += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
    }
    let geometry = SCNGeometry(
      sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals), SCNGeometrySource(textureCoordinates: uv)],
      elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    let picture = Label.leader(look, length: length)
    let m = material(picture, metal: 0, rough: 0.2, coat: 0.55)
    m.transparent.contents = picture
    m.transparencyMode = .aOne
    m.isDoubleSided = true
    geometry.materials = [m]
    return SCNNode(geometry: geometry)
  }

  // MARK: 120

  private static func roll(_ look: NewProjectSheet.Look) -> SCNNode {
    let node = SCNNode()
    let r: CGFloat = 12.0, h: CGFloat = 62
    let paper = SCNCylinder(radius: r, height: h)
    paper.radialSegmentCount = 96
    // The backing paper and the seal round it, as each maker prints them (`Roll120Print`).
    paper.materials = [material(Roll120Print.paper(look), metal: 0, rough: 0.78), material(NSColor(white: 0.1, alpha: 1), metal: 0, rough: 0.8)]
    let paperNode = SCNNode(geometry: paper)
    paperNode.eulerAngles.y = -.pi / 2 + 0.35
    node.addChildNode(paperNode)
    let printed = Roll120Print.seal(look)
    let seal = SCNTube(innerRadius: r + 0.01, outerRadius: r + 0.14, height: printed.height)
    seal.radialSegmentCount = 96
    seal.materials = [material(printed.image, metal: 0, rough: 0.42, coat: 0.3), material(NSColor(white: 0.95, alpha: 1), metal: 0, rough: 0.5)]
    let sealNode = SCNNode(geometry: seal)
    sealNode.eulerAngles.y = paperNode.eulerAngles.y
    sealNode.position.y = printed.rise
    node.addChildNode(sealNode)
    // The spool's ends as the real ones are: a thin flat flange of black plastic a little wider
    // than the paper, its edge square; in its middle the key hole the camera's winder takes, a
    // round hole with a notch either side reaching a third of the way across. Nothing stands out
    // past the flange.
    let spoolPlastic = material(NSColor(white: 0.05, alpha: 1), metal: 0, rough: 0.46, coat: 0.12)
    let hole = material(NSColor(white: 0.004, alpha: 1), metal: 0, rough: 1)
    for (y, top) in [(h / 2, true), (-h / 2, false)] {
      let side: CGFloat = top ? 1 : -1, t: CGFloat = 0.9
      let flange = SCNCylinder(radius: r + 0.9, height: t)
      flange.radialSegmentCount = 120
      flange.materials = [spoolPlastic]
      let flangeNode = SCNNode(geometry: flange)
      flangeNode.position.y = y + side * t / 2
      node.addChildNode(flangeNode)
      // A hairline bevel round the flange's outer edge, where the light catches it.
      let bevel = SCNTorus(ringRadius: r + 0.82, pipeRadius: 0.1)
      bevel.ringSegmentCount = 120
      bevel.materials = [spoolPlastic]
      let bevelNode = SCNNode(geometry: bevel)
      bevelNode.position.y = y + side * t
      node.addChildNode(bevelNode)
      let face = y + side * t
      // The hole and its two notches, dark as a hole into the spool's core is.
      let bore = SCNCylinder(radius: 2.0, height: 0.04)
      bore.radialSegmentCount = 72
      bore.materials = [hole]
      let boreNode = SCNNode(geometry: bore)
      boreNode.position.y = face + side * 0.03
      node.addChildNode(boreNode)
      for dx in [-2.9, 2.9] as [CGFloat] {
        let notch = SCNBox(width: 2.4, height: 0.04, length: 1.4, chamferRadius: 0.1)
        notch.materials = [hole]
        let notchNode = SCNNode(geometry: notch)
        notchNode.position = SCNVector3(dx, face + side * 0.03, 0)
        node.addChildNode(notchNode)
      }
    }
    return node
  }

  // MARK: Print

  /// The colours a maker prints its film in, roughly: the ground, a band, and the ink.
  struct Livery {
    var ground: NSColor
    var band: NSColor
    var ink: NSColor
  }
  static func livery(_ maker: String?) -> Livery {
    func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: 1) }
    switch maker ?? "" {
    case "Kodak": return Livery(ground: c(0.97, 0.74, 0.08), band: c(0.83, 0.13, 0.1), ink: c(0.08, 0.06, 0.04))
    case "Fujifilm": return Livery(ground: c(0.0, 0.5, 0.33), band: c(0.95, 0.95, 0.92), ink: c(0.98, 0.98, 0.96))
    case "Ilford", "Rollei", "CineStill": return Livery(ground: c(0.07, 0.07, 0.08), band: maker == "Ilford" ? c(0.92, 0.92, 0.9) : c(0.82, 0.12, 0.12), ink: c(0.96, 0.96, 0.94))
    case "Kentmere", "ADOX", "Lomography": return Livery(ground: c(0.94, 0.94, 0.91), band: maker == "Kentmere" ? c(0.1, 0.3, 0.62) : maker == "ADOX" ? c(0.8, 0.1, 0.1) : c(0.88, 0.32, 0.42), ink: c(0.1, 0.1, 0.12))
    case "Harman": return Livery(ground: c(0.93, 0.42, 0.1), band: c(0.1, 0.08, 0.08), ink: c(0.08, 0.05, 0.04))
    case "Foma", "ORWO": return Livery(ground: c(0.11, 0.26, 0.56), band: c(0.93, 0.93, 0.9), ink: c(0.97, 0.97, 0.95))
    case "Ferrania", "Lucky": return Livery(ground: c(0.8, 0.1, 0.12), band: c(0.97, 0.85, 0.3), ink: c(0.98, 0.97, 0.93))
    case "AgfaPhoto": return Livery(ground: c(0.55, 0.58, 0.62), band: c(0.95, 0.52, 0.1), ink: c(0.98, 0.98, 0.98))
    default: return Livery(ground: c(0.85, 0.85, 0.83), band: c(0.4, 0.4, 0.4), ink: c(0.1, 0.1, 0.1))
    }
  }
  /// The kind's mark at the label's foot: the process a lab reads.
  static func kindBand(_ look: NewProjectSheet.Look) -> (NSColor, String) {
    switch look.kind ?? .colour {
    case .colour: return (NSColor(red: 0.93, green: 0.52, blue: 0.16, alpha: 1), "C-41")
    case .slide: return (NSColor(red: 0.18, green: 0.42, blue: 0.78, alpha: 1), look.mono ? "B&W REVERSAL" : "E-6")
    case .blackWhite: return (NSColor(white: 0.55, alpha: 1), "B&W")
    case .cine: return (NSColor(red: 0.55, green: 0.12, blue: 0.12, alpha: 1), "ECN-2")
    }
  }

  /// The labels, drawn flat to be wrapped round: their width the circumference, so a millimetre
  /// is a millimetre all round.
  enum Label {
    static let mm: CGFloat = 22
    /// Where round a wrapped label the camera looks, as SceneKit maps a cylinder's side and the
    /// shell is turned (`-π/2 + 0.35`): a roll's front; a cassette's a little to the left, clear of
    /// its lip.
    static let front: CGFloat = 0.7
    static let cassetteFront: CGFloat = 0.725
    static func draw(width: CGFloat, height: CGFloat, _ body: (CGContext, CGSize) -> Void) -> NSImage {
      let size = NSSize(width: (width * mm).rounded(), height: (height * mm).rounded())
      let image = NSImage(size: size)
      image.lockFocusFlipped(true)
      if let ctx = NSGraphicsContext.current?.cgContext { body(ctx, size) }
      image.unlockFocus()
      return image
    }
    /// `s` set at `p` (its top, centred or from the left), made smaller to fit `fit` points across.
    static func text(_ s: String, _ font: NSFont, _ colour: NSColor, at p: CGPoint, centred: Bool = true, kern: CGFloat = 0, fit: CGFloat? = nil) {
      var a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: colour, .kern: kern])
      if let fit, a.size().width > fit, let smaller = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * fit / a.size().width) {
        a = NSAttributedString(string: s, attributes: [.font: smaller, .foregroundColor: colour, .kern: kern * fit / a.size().width])
      }
      let w = a.size().width
      a.draw(at: CGPoint(x: centred ? p.x - w / 2 : p.x, y: p.y))
    }
    static func condensed(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont {
      let names: [NSFont.Weight: String] = [.heavy: "AvenirNextCondensed-Heavy", .bold: "AvenirNextCondensed-Bold", .semibold: "AvenirNextCondensed-DemiBold", .medium: "AvenirNextCondensed-Medium"]
      return names[weight].flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: weight)
    }
    /// `s` set along a cassette's length, reading from its top end down as the print on a
    /// standing cassette does, centred at `centre`, made smaller to be no longer than `fit`.
    static func along(_ s: String, _ font: NSFont, _ colour: NSColor, centre: CGPoint, fit: CGFloat, kern: CGFloat = 0) {
      guard let ctx = NSGraphicsContext.current?.cgContext else { return }
      var a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: colour, .kern: kern])
      if a.size().width > fit, let smaller = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * fit / a.size().width) {
        a = NSAttributedString(string: s, attributes: [.font: smaller, .foregroundColor: colour, .kern: kern * fit / a.size().width])
      }
      let size = a.size()
      ctx.saveGState()
      ctx.translateBy(x: centre.x, y: centre.y)
      ctx.rotate(by: .pi / 2)
      a.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
      ctx.restoreGState()
    }
    /// What the film is, in the words printed on the box.
    static func description(_ look: NewProjectSheet.Look) -> String {
      switch look.kind ?? .colour {
      case .colour: return "Color Negative Film"
      case .slide: return look.mono ? "Black & White Reversal" : "Color Reversal Film"
      case .blackWhite: return "Black & White Film"
      case .cine: return "Motion Picture Film"
      }
    }
    /// A 135 shell's print, as far round as the shell's outline goes (the round and out along the
    /// lip, `Shell.round`) and 38 mm tall: the stock's own print (`FilmPrint`), its front where the
    /// camera looks.
    static func cassette(_ look: NewProjectSheet.Look) -> NSImage {
      draw(width: Shell.round, height: 38) { ctx, size in
        let flat = FilmPrint.Flat(ctx: ctx, size: size, front: Shell.frontAt * mm)
        (FilmPrint.design(look) ?? FilmPrint.generic(look)).draw(flat, look)
      }
    }
    /// A leader's picture, `length` mm along and 35 mm across, its top edge at the top: the film's
    /// base, the perforations cut out (2.8 × 1.98 mm, 4.75 mm apart, 2 mm in from each edge); from
    /// 12 mm out only the upper 18 mm goes on, the tongue, perforated along its top, its end rounded.
    static func leader(_ look: NewProjectSheet.Look, length: CGFloat) -> NSImage {
      let base: NSColor
      switch look.kind ?? .colour {
      case .colour, .cine: base = NSColor(red: 0.6, green: 0.3, blue: 0.13, alpha: 0.96)
      case .slide: base = NSColor(white: 0.12, alpha: 0.97)
      case .blackWhite: base = NSColor(red: 0.36, green: 0.38, blue: 0.41, alpha: 0.95)
      }
      return draw(width: length, height: 35) { ctx, size in
        // As a factory cassette's leader is cut (Kodak's, photographed upright): the lower edge
        // turns up at once out of the lip, steep at first and easing off, in a concave curve some
        // 16 mm along and 13 mm up, to a tongue 22 mm wide (the upper perforations and a strip of
        // the picture area) that runs on to its end, cut square, its lower corner well rounded.
        let m = mm, tongue = 22 * m, shoulder = 1 * m, run = 16 * m, rise = size.height - tongue, end = size.width
        ctx.setFillColor(base.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setBlendMode(.clear)
        let k: CGFloat = 0.5523
        let cut = CGMutablePath()
        cut.move(to: CGPoint(x: shoulder, y: size.height))
        cut.addCurve(to: CGPoint(x: shoulder + run, y: tongue),
          control1: CGPoint(x: shoulder, y: size.height - k * rise), control2: CGPoint(x: shoulder + run - k * run, y: tongue))
        cut.addLine(to: CGPoint(x: end, y: tongue))
        cut.addLine(to: CGPoint(x: end, y: size.height))
        cut.closeSubpath()
        ctx.addPath(cut)
        ctx.fillPath()
        // The tongue's end: its corners rounded, 1 mm at the film's edge, 4.5 mm at the cut.
        let outer = 1 * m, inner = 4.5 * m
        ctx.fill(CGRect(x: end - inner - 1, y: 0, width: inner + 1, height: tongue))
        ctx.setBlendMode(.normal)
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: end - inner - 1, y: 0))
        tip.addLine(to: CGPoint(x: end - outer, y: 0))
        tip.addQuadCurve(to: CGPoint(x: end, y: outer), control: CGPoint(x: end, y: 0))
        tip.addLine(to: CGPoint(x: end, y: tongue - inner))
        tip.addCurve(to: CGPoint(x: end - inner, y: tongue), control1: CGPoint(x: end, y: tongue - inner * (1 - k)), control2: CGPoint(x: end - inner * (1 - k), y: tongue))
        tip.addLine(to: CGPoint(x: end - inner - 1, y: tongue))
        tip.closeSubpath()
        ctx.setFillColor(base.cgColor)
        ctx.addPath(tip)
        ctx.fillPath()
        let tipRoom = outer + 0.6 * m
        // The perforations: along the top all the way, along the bottom up to the shoulder.
        ctx.setBlendMode(.clear)
        var x = 1.2 * m
        while x + 2.8 * m < size.width - tipRoom {
          ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 2 * m, width: 2.8 * m, height: 1.98 * m), cornerWidth: 0.5 * m, cornerHeight: 0.5 * m, transform: nil))
          if x + 2.8 * m < shoulder {
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: size.height - 2 * m - 1.98 * m, width: 2.8 * m, height: 1.98 * m), cornerWidth: 0.5 * m, cornerHeight: 0.5 * m, transform: nil))
          }
          x += 4.75 * m
        }
        ctx.fillPath()
        ctx.setBlendMode(.normal)
      }
    }
    /// A fine tangent-space fuzz for felt: normals tilted a little at random.
    static let fuzz: NSImage = {
      let n = 256
      var px = [UInt8](repeating: 255, count: n * n * 4)
      var seed: UInt32 = 12345
      for i in 0..<(n * n) {
        seed = seed &* 1103515245 &+ 12345
        let dx = Int((seed >> 16) % 90) - 45
        seed = seed &* 1103515245 &+ 12345
        let dy = Int((seed >> 16) % 90) - 45
        px[i * 4] = UInt8(128 + dx); px[i * 4 + 1] = UInt8(128 + dy); px[i * 4 + 2] = 235; px[i * 4 + 3] = 255
      }
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32)!
      px.withUnsafeBytes { memcpy(rep.bitmapData!, $0.baseAddress!, n * n * 4) }
      let image = NSImage(size: NSSize(width: n, height: n))
      image.addRepresentation(rep)
      return image
    }()
    /// A reloadable cassette's tape: what the roll is, written in pencil; a preset of this Mac
    /// under an amber 本机 mark.
    static func tape(_ look: NewProjectSheet.Look) -> NSImage {
      let round = 2 * .pi * 12.5, tall: CGFloat = 15
      return draw(width: round, height: tall) { ctx, size in
        let m = mm
        ctx.setFillColor(NSColor(red: 0.96, green: 0.94, blue: 0.86, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let front = size.width * (Label.cassetteFront - 0.05)
        if look.calibrated {
          ctx.setFillColor(NSColor(red: 0.91, green: 0.68, blue: 0.37, alpha: 1).cgColor)
          ctx.fill(CGRect(x: front - 14 * m, y: 0, width: 28 * m, height: 3.6 * m))
          text("本机标定", NSFont.systemFont(ofSize: 2.6 * m, weight: .bold), NSColor(white: 0.1, alpha: 1), at: CGPoint(x: front, y: 0.25 * m))
        }
        let hand = NSFont(name: "BradleyHandITCTT-Bold", size: 4.2 * m) ?? NSFont(name: "Noteworthy-Bold", size: 4.2 * m) ?? NSFont.systemFont(ofSize: 4.2 * m)
        let words = look.named ? look.name : (look.name.components(separatedBy: " · ").first ?? look.name)
        let shown = words.count > 18 ? String(words.prefix(17)) + "…" : words
        text(shown, hand, NSColor(red: 0.16, green: 0.16, blue: 0.22, alpha: 1), at: CGPoint(x: front, y: look.calibrated ? 5 * m : 3.4 * m), fit: 20 * m)
        if let iso = look.iso {
          text("\(iso)", NSFont(name: "BradleyHandITCTT-Bold", size: 3.4 * m) ?? hand, NSColor(red: 0.16, green: 0.16, blue: 0.22, alpha: 1), at: CGPoint(x: front, y: 9.6 * m))
        }
      }
    }
    /// 120 backing paper's outside: the maker's ground, its name and the speed printed along.
    static func backing(_ look: NewProjectSheet.Look) -> NSImage {
      let round = 2 * .pi * 12.0, tall: CGFloat = 62
      let l = livery(look.maker)
      return draw(width: round, height: tall) { ctx, size in
        let m = mm
        ctx.setFillColor(l.ground.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(l.band.cgColor)
        ctx.fill(CGRect(x: 0, y: 3 * m, width: size.width, height: 3.2 * m))
        ctx.fill(CGRect(x: 0, y: size.height - 6.2 * m, width: size.width, height: 3.2 * m))
        let front = size.width * Label.front
        text((look.maker ?? "").uppercased(), condensed(4.6 * m, .heavy), l.ink, at: CGPoint(x: front, y: 9 * m), kern: 0.4 * m, fit: 19 * m)
        text("120", condensed(4.4 * m, .bold), l.ink, at: CGPoint(x: front, y: size.height - 13 * m))
        text("\((look.maker ?? "").uppercased())  ·  120", condensed(3 * m, .bold), l.ink.withAlphaComponent(0.8), at: CGPoint(x: size.width * 0.72, y: 30 * m))
      }
    }
    /// The seal round a 120 roll: the stock and its speed, the kind's colour under them.
    static func seal(_ look: NewProjectSheet.Look) -> NSImage {
      let round = 2 * .pi * 12.15, tall: CGFloat = 18
      let l = livery(look.maker)
      let (kindColour, process) = kindBand(look)
      return draw(width: round, height: tall) { ctx, size in
        let m = mm
        ctx.setFillColor(NSColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(kindColour.cgColor)
        ctx.fill(CGRect(x: 0, y: size.height - 3.8 * m, width: size.width, height: 3.8 * m))
        let front = size.width * Label.front
        let name = look.name
        text(name, condensed(4.6 * m, .bold), l.ground == NSColor(red: 0.94, green: 0.94, blue: 0.91, alpha: 1) ? l.band : NSColor(white: 0.1, alpha: 1), at: CGPoint(x: front, y: 1.4 * m), fit: 19 * m)
        if let iso = look.iso { text("\(iso)", condensed(6.4 * m, .heavy), NSColor(white: 0.08, alpha: 1), at: CGPoint(x: front, y: 6.2 * m)) }
        text(process, condensed(2.4 * m, .semibold), NSColor.white, at: CGPoint(x: front, y: size.height - 3.4 * m))
      }
    }
  }
}

/// A film, rendered, in a SwiftUI view: drawn once per film and size, faded in when it comes.
/// `turns`: rested on with the pointer, it turns once round in its own light, the leader swinging
/// out over what is beside it, and settles where it was.
struct FilmObject: View {
  let look: NewProjectSheet.Look
  let gauge: FilmStock.Gauge
  var turns = false
  /// Turning on its own, whatever the pointer does: while its roll opens. Each time it becomes
  /// true it turns once more, round after round while it stays so.
  var spinning = false
  @State private var image: NSImage?
  @State private var turning: (stage: FilmRender.Stage, widen: CGFloat, id: Int)?
  /// The turn's first frame is on screen: the still under it can go.
  @State private var live = false
  @State private var resting = false
  @State private var turnCount = 0
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    GeometryReader { g in
      ZStack {
        if let image {
          Image(nsImage: image).resizable().interpolation(.high).transition(.opacity)
            .opacity(turning != nil && live ? 0 : 1)
        }
      }
      .frame(width: g.size.width, height: g.size.height)
      .overlay {
        if let turning {
          FilmTurnView(stage: turning.stage, id: turning.id, shown: { live = true }) {
            if self.turning?.id == turning.id { self.turning = nil; live = false }
            // Still opening: round again.
            if spinning { startTurn(g.size) }
          }
          .frame(width: g.size.width * turning.widen, height: g.size.height * turning.widen)
          .allowsHitTesting(false)
        }
      }
      .onHover { inside in
        guard turns, !reduceMotion else { return }
        resting = inside
        guard inside, turning == nil else { return }
        // Only when the pointer stays a moment, not as it passes over the shelf.
        turnCount += 1
        let asked = turnCount, size = g.size
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          guard resting, asked == turnCount, turning == nil else { return }
          startTurn(size)
        }
      }
      .onChange(of: spinning) { _, on in
        if on, turning == nil, !reduceMotion { startTurn(g.size) }
      }
      .onAppear {
        if spinning, turning == nil, !reduceMotion { startTurn(g.size) }
      }
      .task(id: "\(look.renderKey)|\(gauge.rawValue)|\(Int(g.size.width))x\(Int(g.size.height))") {
        let size = g.size
        await withCheckedContinuation { done in
          FilmRender.image(look, gauge: gauge, points: size, scale: max(2, displayScale)) { made in
            withAnimation(.easeOut(duration: 0.18)) { image = made }
            done.resume()
          }
        }
      }
    }
  }
}

extension FilmObject {
  /// Builds the film's scene and turns it once round.
  fileprivate func startTurn(_ size: CGSize) {
    turnCount += 1
    let asked = turnCount
    FilmRender.turning(look, gauge: gauge, points: size) { stage, widen in
      guard asked == turnCount, turning == nil, resting || spinning else { return }
      live = false
      turning = (stage, widen, asked)
    }
  }
}

/// A film turning once round, live: its scene as the still picture's, seen wider from the same
/// place, on a clear ground, its shadow turning with it on the floor. Done, it says so.
struct FilmTurnView: NSViewRepresentable {
  let stage: FilmRender.Stage
  let id: Int
  var shown: () -> Void
  var done: () -> Void
  /// Says once when the first frame has been drawn.
  final class Coordinator: NSObject, SCNSceneRendererDelegate {
    var shown: (() -> Void)?
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
      guard let said = shown else { return }
      shown = nil
      DispatchQueue.main.async { said() }
    }
  }
  func makeCoordinator() -> Coordinator {
    let c = Coordinator()
    c.shown = shown
    return c
  }
  /// One turn: slow away, quicker round the back, slow into place.
  static let duration: TimeInterval = 2.2
  func makeNSView(context: Context) -> SCNView {
    let view = SCNView(frame: .zero, options: nil)
    view.scene = stage.scene
    view.pointOfView = stage.camera
    view.backgroundColor = .clear
    view.antialiasingMode = .multisampling4X
    view.allowsCameraControl = false
    view.wantsLayer = true
    view.layer?.isOpaque = false
    view.delegate = context.coordinator
    view.isPlaying = true
    let spin = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: Self.duration)
    spin.timingMode = .easeInEaseOut
    let finished = done
    stage.film.runAction(spin) { DispatchQueue.main.async { finished() } }
    return view
  }
  func updateNSView(_ view: SCNView, context: Context) {}
  static func dismantleNSView(_ view: SCNView, coordinator: ()) {
    view.isPlaying = false
    view.scene = nil
  }
}
