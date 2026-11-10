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
  /// The same, at once, for a test or a window shot.
  static func renderNow(_ look: NewProjectSheet.Look, gauge: FilmStock.Gauge, pixels: CGSize) -> NSImage? {
    queue.sync { render(look, gauge: gauge, pixels: pixels) }
  }

  // MARK: The scene

  private static func render(_ look: NewProjectSheet.Look, gauge: FilmStock.Gauge, pixels: CGSize) -> NSImage? {
    if renderer == nil {
      guard let device = MTLCreateSystemDefaultDevice() else { return nil }
      renderer = SCNRenderer(device: device, options: nil)
    }
    guard let renderer else { return nil }
    let scene = SCNScene()
    scene.background.contents = NSColor.clear
    scene.lightingEnvironment.contents = studio
    let film = gauge == .mm135 ? cassette(look) : roll(look)
    scene.rootNode.addChildNode(film)
    // Where it stands and how far it reaches: the cassette from its spool's foot to its knob, its
    // leader out to the right; the roll from flange end to flange end.
    let (bottom, top): (CGFloat, CGFloat) = gauge == .mm135 ? (-22.0, 33) : (-33.7, 33.7)
    let (left, right): (CGFloat, CGFloat) = gauge == .mm135 ? (-23, 25) : (-13.6, 13.6)
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
    key.light!.orthographicScale = 70
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
    camera.camera!.fieldOfView = 16
    camera.camera!.zNear = 10
    camera.camera!.zFar = 2000
    camera.camera!.wantsHDR = true
    camera.camera!.wantsExposureAdaptation = false
    camera.camera!.exposureOffset = 0.1
    let aspect = pixels.width / max(1, pixels.height)
    let fit = max((top - bottom) * 1.14, (right - left) * 1.1 / aspect)
    let distance = fit / 2 / tan(CGFloat(16) / 2 * .pi / 180)
    let centre = SCNVector3((left + right) / 2, (top + bottom) / 2, 0)
    let elevation: CGFloat = gauge == .mm135 ? 0.4 : 0.2
    camera.position = SCNVector3(centre.x, centre.y + distance * sin(elevation), distance * cos(elevation))
    camera.look(at: SCNVector3(centre.x, centre.y - 0.5, 0))
    scene.rootNode.addChildNode(camera)
    renderer.scene = scene
    renderer.pointOfView = camera
    return renderer.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X)
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

  /// A 135 cassette as the photographs show it: the printed shell; black end caps pressed over it
  /// with a rolled rim; the spool's knob a short thick-walled tube with its key bar, the short
  /// hub below; the lip down the right side, its mouth lined with black felt; and the leader out of
  /// it, curling out to the right, perforated, cut to its tongue.
  private static func cassette(_ look: NewProjectSheet.Look) -> SCNNode {
    let node = SCNNode()
    let r: CGFloat = 12.4, h: CGFloat = 38
    let plain = look.named || look.calibrated
    let shell = SCNCylinder(radius: r, height: h)
    shell.radialSegmentCount = 128
    shell.materials = [plain ? reloadable : material(Label.cassette(look), metal: 0.15, rough: 0.28, coat: 1), capPaint, capPaint]
    let shellNode = SCNNode(geometry: shell)
    // The print's front towards the camera.
    shellNode.eulerAngles.y = -.pi / 2 + 0.35
    node.addChildNode(shellNode)
    if plain {
      // A reloadable cassette's tape, written on.
      let tape = SCNTube(innerRadius: r + 0.01, outerRadius: r + 0.12, height: 15)
      tape.radialSegmentCount = 128
      tape.materials = [material(Label.tape(look), metal: 0, rough: 0.6), material(NSColor(white: 0.95, alpha: 1), metal: 0, rough: 0.6)]
      let tapeNode = SCNNode(geometry: tape)
      tapeNode.eulerAngles.y = shellNode.eulerAngles.y
      tapeNode.position.y = 1
      node.addChildNode(tapeNode)
    }
    let ends = plain ? reloadable : capPaint
    for top in [true, false] {
      let y = top ? h / 2 : -h / 2, out: CGFloat = top ? 1 : -1
      // The cap over the shell's end, its rim rolled, a ring pressed into its face.
      let cap = SCNCylinder(radius: r + 0.6, height: 1.7)
      cap.radialSegmentCount = 128
      cap.materials = [ends]
      let capNode = SCNNode(geometry: cap)
      capNode.position.y = y + out * 0.85
      node.addChildNode(capNode)
      let rim = SCNTorus(ringRadius: r + 0.3, pipeRadius: 0.9)
      rim.ringSegmentCount = 128
      rim.materials = [ends]
      let rimNode = SCNNode(geometry: rim)
      rimNode.position.y = y + out * 0.5
      node.addChildNode(rimNode)
      let groove = SCNTorus(ringRadius: r - 2.6, pipeRadius: 0.45)
      groove.ringSegmentCount = 96
      groove.materials = [ends]
      let grooveNode = SCNNode(geometry: groove)
      grooveNode.position.y = y + out * 1.72
      node.addChildNode(grooveNode)
    }
    // The spool's knob: a tube standing 6 mm proud, its key bar across inside; the hub below.
    let knob = SCNTube(innerRadius: 2.75, outerRadius: 4.35, height: 6.2)
    knob.radialSegmentCount = 64
    knob.materials = [blackPlastic, blackPlastic, blackPlastic, blackPlastic]
    let knobNode = SCNNode(geometry: knob)
    knobNode.position.y = h / 2 + 1.7 + 3.1
    node.addChildNode(knobNode)
    let bore = SCNCylinder(radius: 2.76, height: 0.5)
    bore.materials = [felt]
    let boreNode = SCNNode(geometry: bore)
    boreNode.position.y = h / 2 + 1.7 + 2.0
    node.addChildNode(boreNode)
    let key = SCNBox(width: 5.6, height: 2.6, length: 1.0, chamferRadius: 0.2)
    key.materials = [blackPlastic]
    let keyNode = SCNNode(geometry: key)
    keyNode.position.y = h / 2 + 1.7 + 3.6
    keyNode.eulerAngles.y = 0.5
    node.addChildNode(keyNode)
    let hub = SCNTube(innerRadius: 2.1, outerRadius: 3.5, height: 1.6)
    hub.materials = [blackPlastic, blackPlastic, blackPlastic, blackPlastic]
    let hubNode = SCNNode(geometry: hub)
    hubNode.position.y = -h / 2 - 1.7 - 0.8
    node.addChildNode(hubNode)
    // The lip down the right side, along the shell's tangent, its mouth in black felt.
    let exit: CGFloat = 0.92
    func place(_ n: SCNNode, radial: CGFloat, along: CGFloat, y: CGFloat = 0) {
      n.position = SCNVector3(radial * sin(exit) + along * cos(exit), y, radial * cos(exit) - along * sin(exit))
      n.eulerAngles.y = exit
    }
    let lip = SCNBox(width: 8.6, height: h + 0.8, length: 3.6, chamferRadius: 1.5)
    lip.materials = [plain ? reloadable : material(Label.lip(look), metal: 0.15, rough: 0.28, coat: 1)]
    let lipNode = SCNNode(geometry: lip)
    place(lipNode, radial: r - 0.6, along: 3.4)
    node.addChildNode(lipNode)
    let velvet = SCNBox(width: 2.4, height: h - 0.4, length: 3.3, chamferRadius: 0.7)
    velvet.materials = [Self.velvet]
    let velvetNode = SCNNode(geometry: velvet)
    place(velvetNode, radial: r - 0.45, along: 7.9)
    node.addChildNode(velvetNode)
    let leader = curledLeader(look)
    place(leader, radial: r - 0.2, along: 8.9)
    node.addChildNode(leader)
    return node
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
    paper.materials = [material(Label.backing(look), metal: 0, rough: 0.78), material(NSColor(white: 0.1, alpha: 1), metal: 0, rough: 0.8)]
    let paperNode = SCNNode(geometry: paper)
    paperNode.eulerAngles.y = -.pi / 2 + 0.35
    node.addChildNode(paperNode)
    // The seal round its middle.
    let seal = SCNTube(innerRadius: r + 0.01, outerRadius: r + 0.14, height: 18)
    seal.radialSegmentCount = 96
    seal.materials = [material(Label.seal(look), metal: 0, rough: 0.42, coat: 0.3), material(NSColor(white: 0.95, alpha: 1), metal: 0, rough: 0.5)]
    let sealNode = SCNNode(geometry: seal)
    sealNode.eulerAngles.y = paperNode.eulerAngles.y
    sealNode.position.y = 2
    node.addChildNode(sealNode)
    // The spool's flanges, a little wider than the paper, and its ends.
    for (y, top) in [(h / 2, true), (-h / 2, false)] {
      let flange = SCNCylinder(radius: r + 0.9, height: 1.1)
      flange.radialSegmentCount = 96
      flange.materials = [blackPlastic]
      let flangeNode = SCNNode(geometry: flange)
      flangeNode.position.y = y + (top ? 0.55 : -0.55)
      node.addChildNode(flangeNode)
      let rim = SCNTorus(ringRadius: r + 0.7, pipeRadius: 0.55)
      rim.ringSegmentCount = 96
      rim.materials = [blackPlastic]
      let rimNode = SCNNode(geometry: rim)
      rimNode.position.y = y + (top ? 0.55 : -0.55)
      node.addChildNode(rimNode)
      let end = SCNCylinder(radius: 3.1, height: 1.6)
      end.materials = [blackPlastic]
      let endNode = SCNNode(geometry: end)
      endNode.position.y = y + (top ? 1.9 : -1.9)
      node.addChildNode(endNode)
      let slot = SCNBox(width: 4.6, height: 0.8, length: 1.0, chamferRadius: 0.2)
      slot.materials = [felt]
      let slotNode = SCNNode(geometry: slot)
      slotNode.position.y = y + (top ? 2.5 : -2.5)
      node.addChildNode(slotNode)
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
    /// A 135 shell's print, 2π × 12.4 mm round and 38 mm tall, laid out as cassettes print theirs:
    /// in bands along the length, the words reading from the top down, the maker's band beside
    /// the lip, then the film's name and what it is, then its speed large; the process in the
    /// kind's colour; the DX squares and the bar code behind.
    static func cassette(_ look: NewProjectSheet.Look) -> NSImage {
      let round = 2 * .pi * 12.4, tall: CGFloat = 38
      let l = livery(look.maker)
      let (kindColour, process) = kindBand(look)
      return draw(width: round, height: tall) { ctx, size in
        let m = mm, w = size.width, mid = size.height / 2
        let front = w * Label.cassetteFront
        func u(_ k: CGFloat) -> CGFloat { front + k * w }
        ctx.setFillColor(l.ground.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        // The maker's band, beside the lip.
        ctx.setFillColor(l.band.cgColor)
        ctx.fill(CGRect(x: u(0.024), y: 0, width: 0.062 * w, height: size.height))
        // The band's words in the cassette's ground where they stand out on it, else black or white.
        func luminance(_ c: NSColor) -> CGFloat {
          let c = c.usingColorSpace(.sRGB) ?? c
          return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        let bandLight = luminance(l.band) > 0.5, groundLight = luminance(l.ground) > 0.5
        let bandInk = bandLight ? (groundLight ? NSColor(white: 0.08, alpha: 1) : l.ground) : (groundLight ? l.ground : NSColor.white)
        along(look.maker ?? "", condensed(3.9 * m, .heavy), bandInk, centre: CGPoint(x: u(0.055), y: mid), fit: 32 * m, kern: 0.2 * m)
        // The film's name, and what it is.
        along(look.name.uppercased(), condensed(5.4 * m, .bold), l.ink, centre: CGPoint(x: u(-0.022), y: mid), fit: 33 * m, kern: 0.15 * m)
        along(description(look), condensed(2.3 * m, .medium), l.ink.withAlphaComponent(0.85), centre: CGPoint(x: u(-0.079), y: mid), fit: 30 * m)
        // The speed, large, towards the foot; the length above it.
        if let iso = look.iso {
          along("\(iso)", condensed(8.4 * m, .heavy), l.ink, centre: CGPoint(x: u(-0.142), y: size.height * 0.64), fit: 19 * m)
          along("36 EXP", condensed(2.3 * m, .semibold), l.ink, centre: CGPoint(x: u(-0.11), y: size.height * 0.2), fit: 12 * m)
        }
        // The kind's stripe with the process, at the far left of the front.
        ctx.setFillColor(kindColour.cgColor)
        ctx.fill(CGRect(x: u(-0.235), y: 0, width: 0.032 * w, height: size.height))
        along(process, condensed(2.0 * m, .bold), NSColor.white, centre: CGPoint(x: u(-0.219), y: size.height * 0.22), fit: 14 * m)
        // The DX squares, bare steel or painted, two by six; the bar code beside them.
        for row in 0..<2 {
          for col in 0..<6 {
            let bare = (row * 5 + col + (look.iso ?? 100) / 50) % 3 != 0
            ctx.setFillColor(bare ? NSColor(white: 0.8, alpha: 1).cgColor : NSColor(white: 0.07, alpha: 1).cgColor)
            ctx.fill(CGRect(x: u(0.3) + CGFloat(row) * 2.6 * m, y: size.height * 0.5 + CGFloat(col) * 2.6 * m, width: 2.3 * m, height: 2.3 * m))
          }
        }
        let code = CGRect(x: u(0.39), y: size.height * 0.12, width: 7.5 * m, height: size.height * 0.62)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(code)
        var y = code.minY + 0.8 * m
        var seed = look.renderKey.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value } | 1
        ctx.setFillColor(NSColor.black.cgColor)
        while y < code.maxY - 1 * m {
          seed = seed &* 1103515245 &+ 12345
          let t = CGFloat((seed >> 16) % 3 + 1) * 0.28 * m
          ctx.fill(CGRect(x: code.minX + 0.8 * m, y: y, width: code.width - 1.6 * m, height: t))
          y += t + CGFloat((seed >> 20) % 2 + 1) * 0.3 * m
        }
        along("DX", condensed(2.6 * m, .heavy), l.ink, centre: CGPoint(x: u(0.31), y: size.height * 0.3), fit: 6 * m)
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
        let m = mm, tongue = 18 * m, shoulder = 12 * m, tip = 9 * m
        ctx.setFillColor(base.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setBlendMode(.clear)
        // Below the tongue, past the shoulder: nothing.
        let cut = CGMutablePath()
        cut.move(to: CGPoint(x: shoulder, y: size.height))
        cut.addCurve(to: CGPoint(x: shoulder + 6 * m, y: tongue), control1: CGPoint(x: shoulder + 1 * m, y: tongue + (size.height - tongue) * 0.3), control2: CGPoint(x: shoulder + 2 * m, y: tongue))
        cut.addLine(to: CGPoint(x: size.width, y: tongue))
        cut.addLine(to: CGPoint(x: size.width, y: size.height))
        cut.closeSubpath()
        ctx.addPath(cut)
        ctx.fillPath()
        // The tongue's rounded end.
        ctx.fill(CGRect(x: size.width - tip, y: 0, width: tip, height: tongue))
        ctx.setBlendMode(.normal)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: size.width - tip, y: 0, width: tip, height: tongue))
        ctx.setFillColor(base.cgColor)
        ctx.fillEllipse(in: CGRect(x: size.width - 2 * tip, y: 0, width: 2 * tip, height: tongue))
        ctx.restoreGState()
        // The perforations: along the top all the way, along the bottom up to the shoulder.
        ctx.setBlendMode(.clear)
        var x = 1.2 * m
        while x + 2.8 * m < size.width - tip {
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
    /// The lip's own print: the ground, with the bands.
    static func lip(_ look: NewProjectSheet.Look) -> NSImage {
      let l = livery(look.maker)
      return draw(width: 8, height: 38) { ctx, size in
        ctx.setFillColor(l.ground.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
      }
    }
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
struct FilmObject: View {
  let look: NewProjectSheet.Look
  let gauge: FilmStock.Gauge
  @State private var image: NSImage?
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    GeometryReader { g in
      ZStack {
        if let image {
          Image(nsImage: image).resizable().interpolation(.high).transition(.opacity)
        }
      }
      .frame(width: g.size.width, height: g.size.height)
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
