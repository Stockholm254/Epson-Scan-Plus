import AppKit

/// ③'s crop on the canvas, as Lightroom's crop overlay in Develop (`AppModel.composing`). The
/// picture shows turned in its whole box (`ImagePipeline.straightened` with the full box), the box
/// kept upright over it. A corner or an edge sizes the box, inside it moves it, and outside it the
/// picture turns about its middle, the box kept on it. The box stops where it would leave the
/// picture, so no corner is ever empty. Boxes here are as the screen shows them: 0–1 of the
/// picture's turned box, turned by quarters and mirrored with the frame; stored back in the frame's
/// own orientation (`Adjustments.composition`).
extension FilmCanvasView {
  enum ComposeHold: Equatable { case corner(Int), edge(Int), move, turn }

  /// The box as the screen shows it, while composing.
  func composeShown() -> CGRect? {
    guard let model, model.composing, let frame = model.selected else { return nil }
    return ImageGeometry.transform(model.compositionBox, settings: frame.adjustments).cg
  }
  /// A box as the screen shows it, in the frame's own orientation.
  func composeStored(_ r: CGRect) -> NormalRect? {
    guard let frame = model?.selected else { return nil }
    return ImageGeometry.transform(NormalRect(r), settings: frame.adjustments, inverse: true)
  }
  func composeFits(_ r: CGRect) -> Bool {
    guard let model, let frame = model.selected, let aspect = model.frameAspect(frame), let o = composeStored(r) else { return false }
    return ImageGeometry.fits(o, degrees: frame.adjustments.angle ?? 0, aspect: aspect)
  }
  /// The furthest of `to` on the way from `from` that fits on the picture.
  func composeFitted(_ to: CGRect, from: CGRect) -> CGRect {
    if composeFits(to) { return to }
    func mix(_ t: CGFloat) -> CGRect {
      CGRect(x: from.minX + (to.minX - from.minX) * t, y: from.minY + (to.minY - from.minY) * t,
        width: from.width + (to.width - from.width) * t, height: from.height + (to.height - from.height) * t)
    }
    var (lo, hi): (CGFloat, CGFloat) = (0, 1)
    for _ in 0..<24 {
      let m = (lo + hi) / 2
      if composeFits(mix(m)) { lo = m } else { hi = m }
    }
    return mix(lo)
  }
  /// A box of the picture shown (0–1) on the canvas.
  func composeScreen(_ r: CGRect) -> CGRect {
    let b = imageRect
    return CGRect(x: b.minX + r.minX * b.width, y: b.minY + r.minY * b.height, width: r.width * b.width, height: r.height * b.height)
  }
  /// The picture's own corners on the canvas, turned in its box: top left, top right, bottom
  /// right, bottom left as the frame lies.
  func composePicture() -> [CGPoint] {
    guard let model, let frame = model.selected, let aspect = model.frameAspect(frame) else { return [] }
    let b = imageRect, degrees = frame.adjustments.angle ?? 0
    return [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { c in
      let q = ImageGeometry.display(ImageGeometry.turned(c, degrees: degrees, aspect: aspect), settings: frame.adjustments)
      return CGPoint(x: b.minX + q.x * b.width, y: b.minY + q.y * b.height)
    }
  }
  /// What a press at `p` takes hold of: a corner of the box (top left, top right, bottom left,
  /// bottom right), else an edge (top, bottom, left, right), else the box, else the picture to turn.
  func composeHold(_ box: CGRect, at p: CGPoint) -> ComposeHold {
    let r = composeScreen(box)
    let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    if let i = corners.indices.min(by: { hypot(corners[$0].x - p.x, corners[$0].y - p.y) < hypot(corners[$1].x - p.x, corners[$1].y - p.y) }),
      hypot(corners[i].x - p.x, corners[i].y - p.y) < Self.cornerReach
    {
      return .corner(i)
    }
    let reach = Self.edgeReach
    let alongX = p.x > r.minX && p.x < r.maxX, alongY = p.y > r.minY && p.y < r.maxY
    if alongX && abs(p.y - r.minY) < reach { return .edge(0) }
    if alongX && abs(p.y - r.maxY) < reach { return .edge(1) }
    if alongY && abs(p.x - r.minX) < reach { return .edge(2) }
    if alongY && abs(p.x - r.maxX) < reach { return .edge(3) }
    return r.contains(p) ? .move : .turn
  }
  /// The box as a hold dragged to `p` makes it, kept to the crop's ratio where one is set (or ⇧
  /// held, to its own), then stopped where it would leave the picture.
  func composeDragged(_ drag: (hold: ComposeHold, start: CGPoint, box: CGRect, angle: Double), to p: CGPoint, shift: Bool) -> CGRect {
    let b = imageRect, o = drag.box
    let dx = (p.x - drag.start.x) / max(1, b.width), dy = (p.y - drag.start.y) / max(1, b.height)
    // Long over short in the screen's pixels: the ratio chosen, else with ⇧ the box's own.
    let pixels = CGSize(width: o.width * b.width, height: o.height * b.height)
    let own = max(pixels.width, pixels.height) / max(1, min(pixels.width, pixels.height))
    let long = model?.cropLong.map { CGFloat($0) } ?? (shift ? own : nil)
    let across = pixels.width >= pixels.height
    /// The size, in the picture's 0–1, of a box `w` wide kept to the ratio.
    func height(forWidth w: CGFloat, _ long: CGFloat) -> CGFloat { (w * b.width) / (across ? long : 1 / long) / b.height }
    func width(forHeight h: CGFloat, _ long: CGFloat) -> CGFloat { (h * b.height) * (across ? long : 1 / long) / b.width }
    var to = o
    switch drag.hold {
    case .move:
      to = o.offsetBy(dx: dx, dy: dy)
    case .turn:
      return o
    case .corner(let i):
      // The opposite corner stays.
      let fixed = CGPoint(x: i % 2 == 0 ? o.maxX : o.minX, y: i < 2 ? o.maxY : o.minY)
      let moved = CGPoint(x: (i % 2 == 0 ? o.minX : o.maxX) + dx, y: (i < 2 ? o.minY : o.maxY) + dy)
      var w = max(0.02, i % 2 == 0 ? fixed.x - moved.x : moved.x - fixed.x)
      var h = max(0.02, i < 2 ? fixed.y - moved.y : moved.y - fixed.y)
      if let long {
        // The larger the pointer asks for, the other side to the ratio.
        let byWidth = height(forWidth: w, long)
        if byWidth >= h { h = byWidth } else { w = width(forHeight: h, long) }
      }
      to = CGRect(x: i % 2 == 0 ? fixed.x - w : fixed.x, y: i < 2 ? fixed.y - h : fixed.y, width: w, height: h)
    case .edge(let e):
      var (x0, x1, y0, y1) = (o.minX, o.maxX, o.minY, o.maxY)
      switch e {
      case 0: y0 = min(y1 - 0.02, y0 + dy)
      case 1: y1 = max(y0 + 0.02, y1 + dy)
      case 2: x0 = min(x1 - 0.02, x0 + dx)
      default: x1 = max(x0 + 0.02, x1 + dx)
      }
      to = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
      if let long {
        // The other side to the ratio, about the box's middle.
        if e < 2 {
          let w = width(forHeight: to.height, long)
          to = CGRect(x: o.midX - w / 2, y: to.minY, width: w, height: to.height)
        } else {
          let h = height(forWidth: to.width, long)
          to = CGRect(x: to.minX, y: o.midY - h / 2, width: to.width, height: h)
        }
      }
    }
    return composeFitted(to, from: o)
  }
  /// The angle, on the screen, the picture turns to as a press outside the box goes round its middle.
  func composeTurn(_ drag: (hold: ComposeHold, start: CGPoint, box: CGRect, angle: Double), to p: CGPoint) -> Double {
    let b = imageRect, c = CGPoint(x: b.midX, y: b.midY)
    let a0 = atan2(Double(drag.start.y - c.y), Double(drag.start.x - c.x)), a1 = atan2(Double(p.y - c.y), Double(p.x - c.x))
    var d = (a1 - a0) * 180 / .pi
    if d > 180 { d -= 360 } else if d < -180 { d += 360 }
    // The view is flipped: y down, so a growing angle turns clockwise, as the straightening counts.
    return drag.angle + d
  }

  /// The crop under way: the canvas's own ground where the turned picture leaves its box, the
  /// picture outside the box darkened, the box with its handles, the overlay chosen (O) over it, a
  /// finer grid while the picture turns, and the angle.
  func drawComposing(box: CGRect, turning: Bool) {
    guard let model else { return }
    let b = imageRect, r = composeScreen(box), picture = composePicture()
    let amber = NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1)
    func polygon(_ path: NSBezierPath, _ points: [CGPoint]) {
      guard let first = points.first else { return }
      path.move(to: first)
      for q in points.dropFirst() { path.line(to: q) }
      path.close()
    }
    // Inside the picture's turned box only: the picture shown is that box, nothing past it.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: b).addClip()
    // The box's corners filled from the picture's edges: covered by the ground.
    let ground = NSBezierPath(rect: b.insetBy(dx: -1, dy: -1))
    polygon(ground, picture)
    ground.windingRule = .evenOdd
    Self.surround(effectiveAppearance).setFill()
    ground.fill()
    // The picture outside the box, darkened.
    let dim = NSBezierPath()
    polygon(dim, picture)
    dim.appendRect(r)
    dim.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.55).setFill()
    dim.fill()
    // The picture's own edge, faint, so it shows where the box can go.
    let edge = NSBezierPath()
    polygon(edge, picture)
    NSColor.white.withAlphaComponent(0.25).setStroke()
    edge.lineWidth = 1
    edge.stroke()
    NSGraphicsContext.restoreGraphicsState()
    // The overlay, or while turning a fine grid to line a horizon up with.
    composeOverlay(in: r, kind: turning ? .grid : model.cropOverlay)
    amber.setStroke()
    let outline = NSBezierPath(rect: r)
    outline.lineWidth = 1.5
    outline.stroke()
    // Corner handles as Lightroom's, short thick bends, and a tick at each edge's middle.
    let arm: CGFloat = min(18, r.width / 4, r.height / 4)
    let handles = NSBezierPath()
    for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
      handles.move(to: CGPoint(x: x + CGFloat(sx) * arm, y: y))
      handles.line(to: CGPoint(x: x, y: y))
      handles.line(to: CGPoint(x: x, y: y + CGFloat(sy) * arm))
    }
    for (a, z) in [(CGPoint(x: r.midX - arm / 2, y: r.minY), CGPoint(x: r.midX + arm / 2, y: r.minY)),
      (CGPoint(x: r.midX - arm / 2, y: r.maxY), CGPoint(x: r.midX + arm / 2, y: r.maxY)),
      (CGPoint(x: r.minX, y: r.midY - arm / 2), CGPoint(x: r.minX, y: r.midY + arm / 2)),
      (CGPoint(x: r.maxX, y: r.midY - arm / 2), CGPoint(x: r.maxX, y: r.midY + arm / 2))]
    {
      handles.move(to: a)
      handles.line(to: z)
    }
    handles.lineWidth = 4
    handles.lineCapStyle = .square
    handles.stroke()
    // The angle and the box's size while it changes, above the box.
    if turning || composeDrag != nil, let stored = composeStored(box), let pixels = model.pixels(ofComposition: stored) {
      let text = String(format: "%+.1f°  ·  %.0f × %.0f", model.screenAngle, pixels.width, pixels.height) as NSString
      let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: amber]
      let size = text.size(withAttributes: attributes)
      let at = CGPoint(x: r.midX - size.width / 2, y: max(b.minY + 4, r.minY - size.height - 8))
      NSColor.black.withAlphaComponent(0.55).setFill()
      NSBezierPath(roundedRect: CGRect(x: at.x - 6, y: at.y - 2, width: size.width + 12, height: size.height + 4), xRadius: 4, yRadius: 4).fill()
      text.draw(at: at, withAttributes: attributes)
    }
    if let line = levelLine {
      let path = NSBezierPath()
      path.move(to: line.from)
      path.line(to: line.to)
      NSColor.black.withAlphaComponent(0.5).setStroke()
      path.lineWidth = 4
      path.stroke()
      amber.setStroke()
      path.lineWidth = 2
      path.stroke()
    }
  }
  /// Lightroom's crop overlays over the box: thirds, a grid, the golden section, the diagonals.
  private func composeOverlay(in r: CGRect, kind: AppModel.CropOverlay) {
    guard kind != .none, r.width > 20, r.height > 20 else { return }
    let path = NSBezierPath()
    func across(_ u: CGFloat) { path.move(to: CGPoint(x: r.minX + u * r.width, y: r.minY)); path.line(to: CGPoint(x: r.minX + u * r.width, y: r.maxY)) }
    func down(_ v: CGFloat) { path.move(to: CGPoint(x: r.minX, y: r.minY + v * r.height)); path.line(to: CGPoint(x: r.maxX, y: r.minY + v * r.height)) }
    switch kind {
    case .thirds:
      for u: CGFloat in [1.0 / 3, 2.0 / 3] { across(u); down(u) }
    case .grid:
      let n = max(4, Int((r.width / 40).rounded())), m = max(4, Int((r.height / 40).rounded()))
      for i in 1..<n { across(CGFloat(i) / CGFloat(n)) }
      for j in 1..<m { down(CGFloat(j) / CGFloat(m)) }
    case .golden:
      for u: CGFloat in [0.382, 0.618] { across(u); down(u) }
    case .diagonal:
      // From each corner at 45° in the screen's pixels, as far as the box goes.
      let s = min(r.width, r.height)
      for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
        path.move(to: CGPoint(x: x, y: y))
        path.line(to: CGPoint(x: x + CGFloat(sx) * s, y: y + CGFloat(sy) * s))
      }
    case .none: break
    }
    NSColor.black.withAlphaComponent(0.35).setStroke()
    path.lineWidth = kind == .grid ? 1 : 1.75
    path.stroke()
    NSColor.white.withAlphaComponent(kind == .grid ? 0.35 : 0.75).setStroke()
    path.lineWidth = kind == .grid ? 0.5 : 0.75
    path.stroke()
  }
  /// The pointer over the crop: a resize arrow at a corner or an edge, a hand inside, a turning
  /// arrow outside.
  func composeCursor(at p: CGPoint) -> NSCursor? {
    guard let box = composeShown() else { return nil }
    switch composeHold(box, at: p) {
    case .corner(let i):
      return NSCursor.frameResize(position: [.topLeft, .topRight, .bottomLeft, .bottomRight][i], directions: .all)
    case .edge(let e):
      return NSCursor.frameResize(position: [.top, .bottom, .left, .right][e], directions: .all)
    case .move:
      return NSCursor.openHand
    case .turn:
      return Self.turnCursor
    }
  }
  static let turnCursor: NSCursor = {
    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
    guard let symbol = (NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90", accessibilityDescription: "旋转")
      ?? NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "旋转"))?.withSymbolConfiguration(config)
    else { return .crosshair }
    // A black arrow on a white disc: legible on a dark picture and a light one.
    let side = max(symbol.size.width, symbol.size.height) + 8
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      NSColor.white.withAlphaComponent(0.92).setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
      NSColor.black.withAlphaComponent(0.5).setStroke()
      NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
      let tinted = NSImage(size: symbol.size, flipped: false) { r in
        symbol.draw(in: r)
        NSColor.black.set()
        r.fill(using: .sourceAtop)
        return true
      }
      tinted.draw(in: NSRect(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
      return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
  }()
}
