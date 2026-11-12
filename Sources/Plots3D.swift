import AppKit
import SceneKit
import SwiftUI

/// Plots to turn in the hand, drawn by SceneKit: the calibration's neutral points in density
/// space with the line they should lie on, and a flat field's fall-off as a surface per light.
/// Dragged they turn, scrolled they come nearer; nothing in them changes the roll.
enum Plots3D {
  // MARK: Neutral points

  /// Millimetres of the plot to one density unit.
  static let perD: CGFloat = 60
  /// How far a point may lie off the line and still count as on it, in density.
  static let onLine = 0.03

  /// Each point's density above the base, and how far it lies off the fit (0 without one).
  static func neutrals(_ points: [NeutralPoint], fit: FilmCalibration.Fit?) -> [(d: [Double], off: Double)] {
    points.map { p in
      let off = fit.map { f in p.misfit(slopes: f.slopes, offsets: f.offsets, toe: f.toe).map(abs).max() ?? 0 } ?? 0
      return (p.density, off)
    }
  }
  /// The fit's neutral line through density space, from below the thinnest point to past the
  /// densest: green's log exposure L gives each channel's density, its toe bending it at the foot.
  static func line(_ fit: FilmCalibration.Fit, from lo: Double, to hi: Double, steps: Int = 48) -> [[Double]] {
    let w = fit.toe ?? .zero
    return (0...steps).map { i in
      let L = lo + (hi - lo) * Double(i) / Double(steps)
      return (0..<3).map { c in
        let x = L + (c == 1 ? 0 : fit.offsets.values[c])
        return fit.slopes.values[c] * FilmToe.density(x, width: w.values[c])
      }
    }
  }

  static func neutralScene(_ points: [NeutralPoint], fit: FilmCalibration.Fit?) -> (SCNScene, SCNNode) {
    let scene = base()
    let root = scene.rootNode
    let found = neutrals(points, fit: fit)
    let most = max(0.5, ((found.flatMap(\.d).max() ?? 0.5) / 0.5).rounded(.up) * 0.5)
    let top = CGFloat(most) * perD
    // The axes from the base's corner: red across, green up, blue towards the viewer; a tick and its
    // number every 0.5 D.
    let colours = [NSColor(red: 0.92, green: 0.3, blue: 0.25, alpha: 1), NSColor(red: 0.3, green: 0.78, blue: 0.4, alpha: 1), NSColor(red: 0.35, green: 0.55, blue: 0.98, alpha: 1)]
    let names = ["R", "G", "B"]
    for c in 0..<3 {
      var end = SCNVector3(0, 0, 0)
      if c == 0 { end.x = top } else if c == 1 { end.y = top } else { end.z = top }
      root.addChildNode(rod(from: SCNVector3(0, 0, 0), to: end, radius: 0.5, colours[c]))
      root.addChildNode(label(names[c], at: SCNVector3(end.x * 1.14 + (c == 2 ? -6 : 0), end.y * 1.14, end.z * 1.14), size: 7, colours[c]))
      var t = 0.5
      while t <= most + 1e-9 {
        var at = SCNVector3(0, 0, 0)
        if c == 0 { at.x = CGFloat(t) * perD } else if c == 1 { at.y = CGFloat(t) * perD } else { at.z = CGFloat(t) * perD }
        root.addChildNode(sphere(at, radius: 0.9, colours[c]))
        root.addChildNode(label(String(format: "%.1f", t), at: SCNVector3(at.x + (c == 0 ? 0 : -5), at.y - 5, at.z), size: 4, NSColor(white: 0.6, alpha: 1)))
        t += 0.5
      }
    }
    // The red–blue floor, a faint grid every 0.5 D, for the drop lines to land on.
    var g = 0.0
    while g <= most + 1e-9 {
      let k = CGFloat(g) * perD
      root.addChildNode(rod(from: SCNVector3(k, 0, 0), to: SCNVector3(k, 0, top), radius: 0.12, NSColor(white: 0.35, alpha: 0.7)))
      root.addChildNode(rod(from: SCNVector3(0, 0, k), to: SCNVector3(top, 0, k), radius: 0.12, NSColor(white: 0.35, alpha: 0.7)))
      g += 0.5
    }
    // The line the neutrals should lie on.
    if let fit, !found.isEmpty {
      let greens = found.map { $0.d[1] / fit.slopes.g }
      let span = (greens.max()! - greens.min()!)
      let path = line(fit, from: max(0, greens.min()! - 0.15 * span - 0.05), to: greens.max()! + 0.15 * span + 0.05)
      for (a, b) in zip(path, path.dropFirst()) {
        root.addChildNode(rod(from: vector(a), to: vector(b), radius: 0.45, NSColor(white: 0.92, alpha: 1)))
      }
    }
    // The points, amber on the line, red off it, each numbered, a drop line to the floor.
    for (i, p) in found.enumerated() {
      let at = vector(p.d)
      let off = fit != nil && p.off > onLine
      let colour = off ? NSColor(red: 0.95, green: 0.25, blue: 0.2, alpha: 1) : NSColor(red: 0.98, green: 0.7, blue: 0.25, alpha: 1)
      root.addChildNode(sphere(at, radius: 2.4, colour, glow: true))
      root.addChildNode(label("\(i + 1)", at: SCNVector3(at.x + 3.5, at.y + 3.5, at.z), size: 4.5, colour))
      root.addChildNode(rod(from: at, to: SCNVector3(at.x, 0, at.z), radius: 0.18, NSColor(white: 0.5, alpha: 0.6)))
    }
    let centre = SCNVector3(top * 0.42, top * 0.42, top * 0.42)
    return (scene, viewer(scene, looking: centre, from: SCNVector3(1.15, 0.75, 1.5), distance: top * 3.1))
  }

  // MARK: Flat field

  static func flatScene(_ flat: FlatField) -> (SCNScene, SCNNode) {
    let scene = base()
    let root = scene.rootNode
    let aspect = CGFloat(flat.width) / CGFloat(max(1, flat.height))
    let across: CGFloat = 100, deep = across / max(0.2, aspect)
    let low = flat.falloff.values.min() ?? 0
    // The fall-off exaggerated to a third of the plot's width at most, so a few per cent shows.
    let rise = across * 0.32 / CGFloat(max(0.05, 1 - low))
    let colours = [NSColor(red: 0.95, green: 0.32, blue: 0.28, alpha: 1), NSColor(red: 0.32, green: 0.85, blue: 0.42, alpha: 1), NSColor(red: 0.38, green: 0.56, blue: 1, alpha: 1)]
    for c in 0..<3 {
      let g = surface(flat, channel: c, across: across, deep: deep, floor: low, rise: rise)
      let m = SCNMaterial()
      m.lightingModel = .blinn
      m.diffuse.contents = colours[c]
      m.specular.contents = NSColor(white: 0.5, alpha: 1)
      m.shininess = 40
      m.transparency = c == 1 ? 0.75 : 0.5
      m.isDoubleSided = true
      m.writesToDepthBuffer = c == 1
      g.materials = [m]
      let n = SCNNode(geometry: g)
      n.renderingOrder = c == 1 ? 0 : 10 + c
      root.addChildNode(n)
      if c == 1 {
        // Green's grid over it, to read the shape by.
        let wire = surface(flat, channel: c, across: across, deep: deep, floor: low, rise: rise, step: 4)
        let wm = SCNMaterial()
        wm.lightingModel = .constant
        wm.diffuse.contents = NSColor(white: 1, alpha: 0.35)
        wm.fillMode = .lines
        wire.materials = [wm]
        let wn = SCNNode(geometry: wire)
        wn.position.y = 0.15
        root.addChildNode(wn)
      }
    }
    // The frame's outline on the floor, where every light would be with no fall-off at all.
    let x = across / 2, z = deep / 2, top = (1 - CGFloat(low)) * rise
    let edge = NSColor(white: 0.55, alpha: 1)
    for (a, b) in [((-x, -z), (x, -z)), ((x, -z), (x, z)), ((x, z), (-x, z)), ((-x, z), (-x, -z))] {
      root.addChildNode(rod(from: SCNVector3(a.0, 0, a.1), to: SCNVector3(b.0, 0, b.1), radius: 0.25, edge))
      root.addChildNode(rod(from: SCNVector3(a.0, top, a.1), to: SCNVector3(b.0, top, b.1), radius: 0.15, NSColor(white: 0.55, alpha: 0.5)))
    }
    root.addChildNode(label("100%", at: SCNVector3(-x - 9, top, -z), size: 4.5, edge))
    root.addChildNode(label(String(format: "%.0f%%", low * 100), at: SCNVector3(-x - 9, 0, -z), size: 4.5, edge))
    return (scene, viewer(scene, looking: SCNVector3(0, top * 0.35, 0), from: SCNVector3(0.55, 0.85, 1.25), distance: across * 2.1))
  }

  /// A light's share over the frame as a surface: the picture's top away from the viewer, the
  /// floor at the weakest share of any light.
  static func surface(_ flat: FlatField, channel c: Int, across: CGFloat, deep: CGFloat, floor: Double, rise: CGFloat, step: Int = 1) -> SCNGeometry {
    let nx = max(2, min(64, flat.width * 2)) / step + 1, nz = max(2, min(48, flat.height * 2)) / step + 1
    var vertices = [SCNVector3](), normals = [SCNVector3]()
    func height(_ u: Double, _ v: Double) -> CGFloat {
      CGFloat(flat.value(at: CGPoint(x: u, y: v)).values[c] - floor) * rise
    }
    for j in 0..<nz {
      for i in 0..<nx {
        let u = Double(i) / Double(nx - 1), v = Double(j) / Double(nz - 1)
        let y = height(u, v)
        vertices.append(SCNVector3((CGFloat(u) - 0.5) * across, y, (CGFloat(v) - 0.5) * deep))
        let e = 0.01
        let dx = (height(min(1, u + e), v) - height(max(0, u - e), v)) / (2 * CGFloat(e) * across)
        let dz = (height(u, min(1, v + e)) - height(u, max(0, v - e))) / (2 * CGFloat(e) * deep)
        let n = SIMD3<Double>(Double(-dx), 1, Double(-dz))
        let k = 1 / (n * n).sum().squareRoot()
        normals.append(SCNVector3(CGFloat(n.x * k), CGFloat(n.y * k), CGFloat(n.z * k)))
      }
    }
    var indices = [Int32]()
    for j in 0..<(nz - 1) {
      for i in 0..<(nx - 1) {
        let a = Int32(j * nx + i), b = a + 1, cc = a + Int32(nx), d = cc + 1
        indices += [a, cc, b, b, cc, d]
      }
    }
    return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
      elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
  }

  // MARK: Parts

  private static func base() -> SCNScene {
    let scene = SCNScene()
    scene.background.contents = NSColor.clear
    let key = SCNNode()
    key.light = SCNLight()
    key.light!.type = .directional
    key.light!.intensity = 800
    key.position = SCNVector3(-100, 200, 150)
    key.look(at: SCNVector3(0, 0, 0))
    scene.rootNode.addChildNode(key)
    let fill = SCNNode()
    fill.light = SCNLight()
    fill.light!.type = .ambient
    fill.light!.intensity = 450
    scene.rootNode.addChildNode(fill)
    return scene
  }
  private static func viewer(_ scene: SCNScene, looking at: SCNVector3, from direction: SCNVector3, distance: CGFloat) -> SCNNode {
    let n = SCNNode()
    n.camera = SCNCamera()
    n.camera!.fieldOfView = 30
    n.camera!.zNear = 1
    n.camera!.zFar = 5000
    let len = (direction.x * direction.x + direction.y * direction.y + direction.z * direction.z).squareRoot()
    n.position = SCNVector3(at.x + direction.x / len * distance, at.y + direction.y / len * distance, at.z + direction.z / len * distance)
    n.look(at: at)
    scene.rootNode.addChildNode(n)
    return n
  }
  private static func vector(_ d: [Double]) -> SCNVector3 {
    SCNVector3(CGFloat(d[0]) * perD, CGFloat(d[1]) * perD, CGFloat(d[2]) * perD)
  }
  private static func flat(_ colour: NSColor, glow: Bool = false) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = glow ? .blinn : .constant
    m.diffuse.contents = colour
    if glow { m.emission.contents = colour.withAlphaComponent(0.35); m.specular.contents = NSColor.white }
    return m
  }
  private static func rod(from a: SCNVector3, to b: SCNVector3, radius: CGFloat, _ colour: NSColor) -> SCNNode {
    let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
    let length = (dx * dx + dy * dy + dz * dz).squareRoot()
    let c = SCNCylinder(radius: radius, height: max(0.01, length))
    c.radialSegmentCount = 10
    c.materials = [flat(colour)]
    let n = SCNNode(geometry: c)
    n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
    // The cylinder stands along y; turned onto the segment.
    if length > 1e-6 {
      let up = SIMD3<Float>(0, 1, 0), along = SIMD3<Float>(Float(dx / length), Float(dy / length), Float(dz / length))
      let axis = simd_cross(up, along), sine = simd_length(axis), cosine = simd_dot(up, along)
      if sine > 1e-6 {
        n.simdOrientation = simd_quatf(angle: atan2(sine, cosine), axis: axis / sine)
      } else if cosine < 0 {
        n.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
      }
    }
    return n
  }
  private static func sphere(_ at: SCNVector3, radius: CGFloat, _ colour: NSColor, glow: Bool = false) -> SCNNode {
    let s = SCNSphere(radius: radius)
    s.segmentCount = 24
    s.materials = [flat(colour, glow: glow)]
    let n = SCNNode(geometry: s)
    n.position = at
    return n
  }
  /// Words that always face the viewer, `size` millimetres tall.
  private static func label(_ text: String, at: SCNVector3, size: CGFloat, _ colour: NSColor) -> SCNNode {
    let t = SCNText(string: text, extrusionDepth: 0)
    t.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    t.flatness = 0.2
    t.materials = [flat(colour)]
    let n = SCNNode(geometry: t)
    let (lo, hi) = n.boundingBox
    n.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0)
    n.scale = SCNVector3(size / 10, size / 10, size / 10)
    let holder = SCNNode()
    holder.position = at
    holder.addChildNode(n)
    holder.constraints = [SCNBillboardConstraint()]
    return holder
  }
  /// A still of a plot, for tests and window shots.
  static func snapshot(_ set: (SCNScene, SCNNode), pixels: CGSize) -> NSImage? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let r = SCNRenderer(device: device, options: nil)
    r.scene = set.0
    r.pointOfView = set.1
    return r.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X)
  }
}

/// A plot to turn: drag to turn it round its middle, scroll or pinch to come nearer.
struct Plot3DView: NSViewRepresentable {
  let scene: SCNScene
  let camera: SCNNode
  /// The wheel zooms (in a popover or sheet of its own), or goes on to what scrolls around it.
  var scrollZooms = true
  /// A scene view whose wheel can be the panel's.
  final class View: SCNView {
    var scrollZooms = true
    override func scrollWheel(with event: NSEvent) {
      if scrollZooms { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }
  }
  func makeNSView(context: Context) -> SCNView {
    let v = View(frame: .zero, options: nil)
    v.scrollZooms = scrollZooms
    v.scene = scene
    v.pointOfView = camera
    v.backgroundColor = .clear
    v.antialiasingMode = .multisampling4X
    v.allowsCameraControl = true
    v.defaultCameraController.interactionMode = .orbitTurntable
    v.defaultCameraController.inertiaEnabled = true
    v.wantsLayer = true
    v.layer?.isOpaque = false
    return v
  }
  func updateNSView(_ v: SCNView, context: Context) {
    (v as? View)?.scrollZooms = scrollZooms
    if v.scene !== scene {
      v.scene = scene
      v.pointOfView = camera
    }
  }
}

/// The calibration's neutral points, in the calibration section: in 3D, or as the three
/// channels' curves in 2D.
struct NeutralSpaceView: View {
  let points: [NeutralPoint]
  let fit: FilmCalibration.Fit?
  /// Whose points they are, when they are a preset's rather than those being picked.
  var of: String? = nil
  @AppStorage("neutralPlot") private var mode = "3d"
  @State private var set: (SCNScene, SCNNode)?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Picker("", selection: $mode) {
          Text("3D").tag("3d")
          Text("2D").tag("2d")
        }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
          .help("3D：红、绿、蓝密度组成的空间；2D：三个通道的密度对曝光，像数据表的特性曲线")
        Spacer()
        Text(fit.map { String(format: "残差 %.3f D", $0.residual) } ?? "还拟合不出直线").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
      }
      if let of {
        Text("「\(of)」标定时的 \(points.count) 个中性点").font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ZStack {
        RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.1))
        if mode == "2d" {
          NeutralCurvesView(points: points, fit: fit).padding(8)
        } else if let set {
          // In the panel the wheel scrolls the panel; a pinch zooms.
          Plot3DView(scene: set.0, camera: set.1, scrollZooms: false)
        }
      }.frame(maxWidth: .infinity).frame(height: 230)
      Text(mode == "2d"
        ? "横轴是按绿色算出的曝光（对数），纵轴是高于片基的密度；三条线是标定出的红、绿、蓝特性曲线。同一种光下的中性点三个通道都落在各自的线上；红、蓝离开线 0.03 D 以上的点圈成琥珀色。"
        : "三条轴是红、绿、蓝高于片基的密度。同一种光下的中性点应当落在白线上；偏离 0.03 D 以上的点是红的，多半不是中性，或者光不一样。拖动转，捏合缩放。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .onAppear { set = Plots3D.neutralScene(points, fit: fit) }
    // Points added or taken out: the scene made again, the view where it was turned.
    .onChange(of: points) { set = Plots3D.neutralScene(points, fit: fit) }
  }
}

/// The neutrals as a data sheet draws a film: each channel's density above the base against the
/// log exposure green gives each point, the fitted curves through them, toes and all.
struct NeutralCurvesView: View {
  let points: [NeutralPoint]
  let fit: FilmCalibration.Fit?
  static let colours = [Color(red: 0.92, green: 0.3, blue: 0.25), Color(red: 0.3, green: 0.78, blue: 0.4), Color(red: 0.35, green: 0.55, blue: 0.98)]
  /// Each point's log exposure (from its green), its three densities and how far red or blue lies
  /// off its curve; without a fit, green density stands for the exposure.
  static func placed(_ points: [NeutralPoint], fit: FilmCalibration.Fit?) -> [(x: Double, d: [Double], off: [Double])] {
    points.map { p in
      let d = p.density
      guard let f = fit else { return (d[1], d, [0, 0]) }
      let w = f.toe ?? .zero
      return (FilmToe.exposure(d[1] / f.slopes.g, width: w.g), d, p.misfit(slopes: f.slopes, offsets: f.offsets, toe: f.toe).map(abs))
    }
  }
  var body: some View {
    let found = Self.placed(points, fit: fit)
    Canvas { ctx, size in
      guard !found.isEmpty else { return }
      let xs = found.map(\.x), lo0 = xs.min()!, hi0 = xs.max()!, pad = max(0.05, (hi0 - lo0) * 0.12)
      let lo = lo0 - pad, hi = hi0 + pad
      let top = max(0.5, ((found.flatMap(\.d).max() ?? 0.5) / 0.5).rounded(.up) * 0.5)
      let left: CGFloat = 26, bottom: CGFloat = 16
      let plot = CGRect(x: left, y: 4, width: size.width - left - 4, height: size.height - bottom - 4)
      func at(_ x: Double, _ d: Double) -> CGPoint {
        CGPoint(x: plot.minX + plot.width * CGFloat((x - lo) / (hi - lo)), y: plot.maxY - plot.height * CGFloat(d / top))
      }
      // Density every 0.5 D (0.25 when it is low), and the frame.
      let step = top > 1 ? 0.5 : 0.25
      var g = 0.0
      while g <= top + 1e-9 {
        let y = at(lo, g).y
        ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) },
          with: .color(.white.opacity(g == 0 ? 0.3 : 0.1)), lineWidth: 0.5)
        ctx.draw(Text(String(format: "%.1f", g)).font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)),
          at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
        g += step
      }
      ctx.draw(Text("曝光 →").font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)), at: CGPoint(x: plot.maxX, y: plot.maxY + 9), anchor: .trailing)
      ctx.draw(Text("D").font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)), at: CGPoint(x: 2, y: plot.minY + 2), anchor: .topLeading)
      // The curves.
      if let fit {
        let line = Plots3D.line(fit, from: lo, to: hi)
        for c in 0..<3 {
          var path = Path()
          for (i, d) in line.enumerated() {
            let p = at(lo + (hi - lo) * Double(i) / Double(max(1, line.count - 1)), d[c])
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
          }
          ctx.stroke(path, with: .color(Self.colours[c].opacity(0.85)), lineWidth: 1.4)
        }
      }
      // The points: each one's three readings at its exposure, numbered over the densest; red or
      // blue off its curve ringed.
      for (i, p) in found.enumerated() {
        for c in 0..<3 {
          let q = at(p.x, p.d[c])
          ctx.fill(Path(ellipseIn: CGRect(x: q.x - 2.6, y: q.y - 2.6, width: 5.2, height: 5.2)), with: .color(Self.colours[c]))
          let off = c == 0 ? p.off[0] : c == 2 ? p.off[1] : 0
          if fit != nil && off > Plots3D.onLine {
            ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 4.6, y: q.y - 4.6, width: 9.2, height: 9.2)), with: .color(Hardware.amber), lineWidth: 1.2)
          }
        }
        let topmost = at(p.x, p.d.max() ?? 0)
        ctx.draw(Text("\(i + 1)").font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.75)),
          at: CGPoint(x: topmost.x, y: topmost.y - 8))
      }
    }
    .accessibilityElement().accessibilityLabel("中性点的三通道特性曲线 · \(points.count) 个点")
  }
}

/// A flat field's fall-off in 3D: each light a surface, its height its share.
struct FlatSurfaceView: View {
  let flat: FlatField
  @State private var set: (SCNScene, SCNNode)?
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.1))
      if let set { Plot3DView(scene: set.0, camera: set.1) }
    }
    .onAppear { set = Plots3D.flatScene(flat) }
    .onChange(of: flat) { _, f in set = Plots3D.flatScene(f) }
    .help("每个通道一层：越低暗角越重；三层分开的地方就是边上偏色。拖动转，滚轮缩放")
  }
}
