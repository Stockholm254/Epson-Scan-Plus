import AppKit
import SwiftUI

struct ScanCanvas: NSViewRepresentable {
  @ObservedObject var model: AppModel
  func makeNSView(context: Context) -> FilmCanvasView {
    let v = FilmCanvasView()
    v.model = model
    return v
  }
  func updateNSView(_ view: FilmCanvasView, context: Context) {
    view.model = model
    if view.lastViewportRevision != model.viewportRevision {
      view.pan = .zero
      view.lastViewportRevision = model.viewportRevision
    }
    view.clampPan()
    view.applyFocusRequest()
    view.needsDisplay = true
    view.updateLoupe()
    view.updateScanHead()
  }
}

/// How the light table lays the overview: a quarter turn, then a mirror, as a frame is turned
/// and mirrored. Between the overview's normalised coordinates, where frames live, and those of
/// the picture as the table shows it.
struct QuarterTurn: Equatable {
  /// Clockwise, 0–3.
  var turns: Int
  var mirrored: Bool
  init(_ turns: Int, mirrored: Bool = false) {
    self.turns = ((turns % 4) + 4) % 4
    self.mirrored = mirrored
  }
  var sideways: Bool { turns % 2 == 1 }
  var isIdentity: Bool { turns == 0 && !mirrored }
  private var settings: Adjustments {
    var s = Adjustments()
    s.rotation = turns
    s.flipHorizontal = mirrored ? true : nil
    return s
  }
  func shown(_ p: CGPoint) -> CGPoint { ImageGeometry.display(p, settings: settings) }
  func overview(_ p: CGPoint) -> CGPoint { ImageGeometry.raw(p, settings: settings) }
  func shown(_ r: CGRect) -> CGRect {
    let a = shown(CGPoint(x: r.minX, y: r.minY)), b = shown(CGPoint(x: r.maxX, y: r.maxY))
    return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }
}

final class FilmCanvasView: NSView {
  /// Lies on the light table in the contact view.
  let loupe = LoupeView()
  /// Passes over the frame being scanned.
  let scanHead = ScanHeadView()
  override init(frame: NSRect) {
    super.init(frame: frame)
    setUp()
  }
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setUp()
  }
  private func setUp() {
    wantsLayer = true
    clipsToBounds = true
    layer?.masksToBounds = true
    loupe.canvas = self
    loupe.isHidden = true
    addSubview(loupe)
    scanHead.canvas = self
    scanHead.isHidden = true
    addSubview(scanHead, positioned: .below, relativeTo: loupe)
  }
  override var wantsDefaultClipping: Bool { true }
  var lastViewportRevision = -1
  var lastFocusRevision = -1
  func applyFocusRequest() {
    guard let model, let window, lastFocusRevision != model.canvasFocusRevision else { return }
    lastFocusRevision = model.canvasFocusRevision
    // Focus is requested only by preview/navigation/user view actions, never sliders.
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window, self.window === window else { return }
      window.makeFirstResponder(self)
    }
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyFocusRequest()
    if !loupe.isHidden { loupe.layoutOnTable() }
  }
  weak var model: AppModel?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  var tracking: NSTrackingArea?
  var hover: CGPoint?
  var dragStart: CGPoint?
  var draft: CGRect?
  var original: CGRect?
  var dragID: UUID?
  var corner: Int?
  var pan = CGPoint.zero
  var panStart: CGPoint?
  func clampPan() {
    let r = imageRect
    let x = max(0, (r.width - bounds.width) / 2)
    let y = max(0, (r.height - bounds.height) / 2)
    pan = CGPoint(x: clamp(pan.x, -x, x), y: clamp(pan.y, -y, y))
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    clampPan()
    if !loupe.isHidden { loupe.layoutOnTable() }
  }
  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    needsDisplay = true
  }
  /// The contact view's turn; single view always shows the frame as it is.
  var turn: QuarterTurn { QuarterTurn(model?.contactTurn ?? 0, mirrored: model?.contactMirrored ?? false) }
  /// Holds its source, so a new picture can never be taken for it.
  private var turnedImage: (source: CGImage, turn: QuarterTurn, image: CGImage)?
  /// The picture as the canvas shows it: the model's, turned with the table.
  var shown: CGImage? {
    guard let cg = model?.displayed else { return nil }
    let t = turn
    guard !t.isIdentity else { return cg }
    if let cached = turnedImage, cached.source === cg, cached.turn == t { return cached.image }
    guard let image = ImagePipeline.shared.turned(cg, quarterTurns: t.turns, mirrored: t.mirrored) else { return cg }
    turnedImage = (cg, t, image)
    return image
  }
  private static let inset: CGFloat = 28
  /// Points per pixel of the shown picture that fit the canvas, leaving `reserve` on the right.
  private func fitScale(reserving reserve: CGFloat) -> CGFloat {
    guard let cg = shown else { return 1 }
    return min(
      max(1, bounds.width - 2 * Self.inset - reserve) / CGFloat(cg.width),
      max(1, bounds.height - 2 * Self.inset) / CGFloat(cg.height))
  }
  /// In the contact view, a strip of glass down the right where the loupe rests clear of the film.
  var loupeRest: CGRect? {
    guard let model, !model.singleView, model.preferences.showLoupe, model.displayed != nil else { return nil }
    let glass = LightTable.glassRect(in: bounds)
    // Wide enough for the loupe at the scale the film would have without it; with it the film
    // is smaller, and so is the loupe.
    let width = 2 * loupeRadius(model.preferences.loupeStyle, scale: fitScale(reserving: 0)) + 36
    guard glass.width > width * 3 else { return nil }
    return CGRect(x: glass.maxX - width, y: glass.minY, width: width, height: glass.height)
  }
  var imageRect: CGRect {
    guard let cg = shown else { return .zero }
    let reserve = loupeRest.map { bounds.maxX - $0.minX - Self.inset } ?? 0
    let scale = fitScale(reserving: reserve) * CGFloat(model?.zoom ?? 1)
    let size = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
    return CGRect(
      x: (bounds.width - reserve - size.width) / 2 + pan.x, y: (bounds.height - size.height) / 2 + pan.y,
      width: size.width, height: size.height)
  }
  /// A canvas point in the shown picture's normalised coordinates.
  func shownNormal(_ p: CGPoint) -> CGPoint {
    let r = imageRect
    return CGPoint(
      x: clamp((p.x - r.minX) / max(1, r.width)), y: clamp((p.y - r.minY) / max(1, r.height)))
  }
  /// A canvas point in the overview's (or single frame's) normalised coordinates.
  func normal(_ p: CGPoint) -> CGPoint { turn.overview(shownNormal(p)) }
  func screen(_ r: CGRect) -> CGRect {
    let b = imageRect, r = turn.shown(r)
    return CGRect(
      x: b.minX + r.minX * b.width, y: b.minY + r.minY * b.height, width: r.width * b.width,
      height: r.height * b.height)
  }
  /// The corners of a normalised rect on the canvas, in its own order: (min x, min y), (max x,
  /// min y), (min x, max y), (max x, max y). On a turned table they are not where the screen
  /// rect's corners of the same order are.
  func corners(_ r: CGRect) -> [CGPoint] {
    let b = imageRect
    return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
      .map { n in let d = turn.shown(n); return CGPoint(x: b.minX + d.x * b.width, y: b.minY + d.y * b.height) }
  }
  override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    tracking = NSTrackingArea(
      rect: .zero,
      options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(tracking!)
    super.updateTrackingAreas()
  }
  override func draw(_ dirtyRect: NSRect) {
    defer { tableDrawn() }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSBezierPath(rect: bounds).addClip()
    NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
    bounds.fill()
    // The contact sheet lies on a lit light table. Single view keeps a neutral dark
    // surround, so the bright glass does not skew exposure and colour judgement.
    let lightTable = model?.singleView != true
    if lightTable { drawLightTable() }
    guard let model, let cg = shown else {
      let text = "扫描预览" as NSString
      text.draw(
        at: CGPoint(x: bounds.midX - 30, y: bounds.midY),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 13),
          .foregroundColor: lightTable ? NSColor(calibratedWhite: 0.42, alpha: 1) : NSColor.secondaryLabelColor,
        ])
      return
    }
    let rect = imageRect
    NSGraphicsContext.saveGraphicsState()
    if !lightTable {
      let shadow = NSShadow()
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
      shadow.shadowBlurRadius = 18
      shadow.shadowOffset = CGSize(width: 0, height: 5)
      shadow.set()
    }
    NSColor.black.setFill()
    rect.insetBy(dx: -1, dy: -1).fill()
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    image.draw(
      in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high])
    if model.singleView, let crop = model.canvasCrop {
      let r = screen(draft ?? crop.cg)
      let mask = NSBezierPath(rect: imageRect)
      mask.appendRect(r)
      mask.windingRule = .evenOdd
      NSColor.black.withAlphaComponent(model.tool == .base ? 0.18 : 0.5).setFill()
      mask.fill()
      NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1).setStroke()
      let outline = NSBezierPath(rect: r)
      outline.lineWidth = 2
      outline.stroke()
      if model.tool == .crop {
        for p in [
          CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
          CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
        ] {
          NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1).setFill()
          NSBezierPath(
            roundedRect: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10), xRadius: 2,
            yRadius: 2
          ).fill()
        }
      }
    }
    if !model.singleView {
      for f in model.contactFrames {
        let r = screen(dragID == f.id ? (draft ?? f.rect.cg) : f.rect.cg)
        let selected = f.id == model.selectedID
        let c =
          selected
          ? NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1)
          : NSColor.white.withAlphaComponent(f.enabled ? 0.85 : 0.3)
        c.setStroke()
        let path = NSBezierPath(rect: r)
        path.lineWidth = selected ? 2 : f.enabled ? 1.5 : 1
        if !f.enabled { path.setLineDash([4, 4], count: 2, phase: 0) }
        path.stroke()
        let label = NSRect(x: r.minX, y: r.minY - 20, width: 30, height: 19)
        c.setFill()
        NSBezierPath(roundedRect: label, xRadius: 3, yRadius: 3).fill()
        (f.name as NSString).draw(
          at: CGPoint(x: label.minX + 6, y: label.minY + 2),
          withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.black,
          ])
        if selected {
          for p in [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
          ] {
            c.setFill()
            NSBezierPath(
              roundedRect: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7), xRadius: 1,
              yRadius: 1
            ).fill()
          }
        }
      }
      if dragID == nil, let draft {
        NSColor.systemOrange.setStroke()
        let p = NSBezierPath(rect: screen(draft))
        p.lineWidth = 1.5
        p.stroke()
      }
      if let rest = loupeRest { drawLoupeRest(rest) }
    }
    if model.singleView, model.tool == .it8, let frame = model.selected { drawIT8(model.it8Marks, settings: frame.adjustments) }
    if model.tool == .loupe, let hover, imageRect.contains(hover) {
      drawLoupe(image: image, point: hover)
    }
  }
  /// The IT8 target's marked points, and once four are set, where every patch will be read.
  private func drawIT8(_ marks: [CGPoint], settings: Adjustments) {
    let r = imageRect
    func onScreen(_ raw: CGPoint) -> CGPoint {
      let d = ImageGeometry.display(raw, settings: settings)
      return CGPoint(x: r.minX + d.x * r.width, y: r.minY + d.y * r.height)
    }
    let half = max(2, IT8Layout.sampleRadius(marks) * min(r.width, r.height))
    NSColor.white.withAlphaComponent(0.9).setStroke()
    for (_, centre) in IT8Layout.centres(marks) {
      let c = onScreen(centre)
      let square = NSBezierPath(rect: CGRect(x: c.x - half, y: c.y - half, width: 2 * half, height: 2 * half))
      square.lineWidth = 1
      square.stroke()
    }
    let amber = NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1)
    for (i, mark) in marks.enumerated() {
      let c = onScreen(mark)
      amber.setFill()
      NSBezierPath(ovalIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)).fill()
      ("\(i + 1)" as NSString).draw(
        at: CGPoint(x: c.x - 4, y: c.y - 7),
        withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.black])
    }
  }
  /// A ring printed on the glass where the loupe rests, so it can be put back by eye.
  private func drawLoupeRest(_ rest: CGRect) {
    let r = loupe.radius + 6, c = CGPoint(x: rest.midX, y: rest.midY)
    let ink = NSColor(calibratedRed: 0.42, green: 0.39, blue: 0.35, alpha: 0.32)
    ink.setStroke()
    let ring = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ring.lineWidth = 0.8
    ring.stroke()
    let label = "看片镜" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: ink.withAlphaComponent(0.6)]
    let size = label.size(withAttributes: attributes)
    label.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y + r + 6), withAttributes: attributes)
  }
  /// The lit light table, shaded by Metal when available. Leaves the glass as the clip, so the
  /// scan and frames stay on it.
  private func drawLightTable() {
    // While the window is being resized, a 1× table keeps up with the drag; full resolution follows.
    let scale = inLiveResize ? 1 : window?.backingScaleFactor ?? 2
    guard let table = LightTable.shared.image(size: bounds.size, scale: scale) else {
      drawGradientLightTable()
      return
    }
    NSImage(cgImage: table, size: bounds.size).draw(
      in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.none])
    NSBezierPath(
      roundedRect: LightTable.glassRect(in: bounds), xRadius: LightTable.glassRadius, yRadius: LightTable.glassRadius
    ).addClip()
  }
  /// Without Metal: opal glass in an aluminium frame, brighter at the centre, with a faint
  /// printed grid.
  private func drawGradientLightTable() {
    NSGradient(
      starting: NSColor(calibratedWhite: 0.3, alpha: 1), ending: NSColor(calibratedWhite: 0.16, alpha: 1)
    )?.draw(in: NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 8, yRadius: 8), angle: 90)
    let glassRect = bounds.insetBy(dx: 12, dy: 12)
    let glass = NSBezierPath(roundedRect: glassRect, xRadius: 4, yRadius: 4)
    NSGradient(colors: [
      NSColor(calibratedRed: 0.97, green: 0.955, blue: 0.92, alpha: 1),
      NSColor(calibratedRed: 0.84, green: 0.82, blue: 0.78, alpha: 1),
    ])?.draw(in: glass, relativeCenterPosition: .zero)
    glass.addClip()
    let grid = NSBezierPath()
    for x in stride(from: glassRect.minX + 24, to: glassRect.maxX, by: 24) {
      grid.move(to: CGPoint(x: x, y: glassRect.minY))
      grid.line(to: CGPoint(x: x, y: glassRect.maxY))
    }
    for y in stride(from: glassRect.minY + 24, to: glassRect.maxY, by: 24) {
      grid.move(to: CGPoint(x: glassRect.minX, y: y))
      grid.line(to: CGPoint(x: glassRect.maxX, y: y))
    }
    grid.lineWidth = 0.5
    NSColor(calibratedRed: 0.45, green: 0.42, blue: 0.38, alpha: 0.14).setStroke()
    grid.stroke()
    // The frame's lip shades the edge of the glass.
    NSGraphicsContext.saveGraphicsState()
    let lip = NSShadow()
    lip.shadowColor = NSColor.black.withAlphaComponent(0.45)
    lip.shadowBlurRadius = 7
    lip.set()
    let rim = NSBezierPath(rect: glassRect.insetBy(dx: -30, dy: -30))
    rim.append(glass)
    rim.windingRule = .evenOdd
    NSColor.black.setFill()
    rim.fill()
    NSGraphicsContext.restoreGraphicsState()
  }
  private func drawLoupe(image: NSImage, point: CGPoint) {
    let diameter: CGFloat = 190
    var center = CGPoint(x: point.x + 115, y: point.y - 85)
    center.x = min(bounds.maxX - 105, max(105, center.x))
    center.y = min(bounds.maxY - 105, max(105, center.y))
    let ring = CGRect(
      x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = CGSize(width: 0, height: 8)
    shadow.set()
    NSColor.black.setFill()
    NSBezierPath(ovalIn: ring).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
      NSColor(calibratedWhite: 0.65, alpha: 1), NSColor(calibratedWhite: 0.12, alpha: 1),
      NSColor(calibratedWhite: 0.4, alpha: 1),
    ])?.draw(in: NSBezierPath(ovalIn: ring), angle: 70)
    let glass = ring.insetBy(dx: 8, dy: 8)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: glass).addClip()
    NSColor.black.setFill()
    glass.fill()
    let n = shownNormal(point)
    let r = imageRect
    let factor = max(2, CGFloat(image.size.width) / max(1, r.width)) * 1.5
    let scaled = CGRect(
      x: center.x - n.x * r.width * factor, y: center.y - n.y * r.height * factor,
      width: r.width * factor, height: r.height * factor)
    image.draw(
      in: scaled, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.none])
    NSColor.white.withAlphaComponent(0.35).setStroke()
    let cross = NSBezierPath()
    cross.move(to: CGPoint(x: center.x - 6, y: center.y))
    cross.line(to: CGPoint(x: center.x + 6, y: center.y))
    cross.move(to: CGPoint(x: center.x, y: center.y - 6))
    cross.line(to: CGPoint(x: center.x, y: center.y + 6))
    cross.lineWidth = 0.5
    cross.stroke()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.black.setFill()
    NSBezierPath(
      roundedRect: CGRect(x: center.x - 22, y: ring.maxY - 19, width: 44, height: 20), xRadius: 5,
      yRadius: 5
    ).fill()
    ("LOUPE" as NSString).draw(
      at: CGPoint(x: center.x - 17, y: ring.maxY - 16),
      withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
        .foregroundColor: NSColor.white,
      ])
  }
  override func mouseMoved(with event: NSEvent) {
    hover = convert(event.locationInWindow, from: nil)
    // Only the magnifier tool follows the mouse; other redraws would retake the loupe's picture.
    if model?.tool == .loupe { needsDisplay = true }
  }
  override func mouseExited(with event: NSEvent) {
    hover = nil
    if model?.tool == .loupe { needsDisplay = true }
  }

  // MARK: Loupe

  /// Where the loupe was left, kept by the model so a rebuilt view finds it again.
  var storedLoupeCenter: CGPoint? {
    get { model?.loupeCenter.map { CGPoint(x: $0.x * bounds.width, y: $0.y * bounds.height) } }
    set {
      model?.loupeCenter = newValue.map {
        CGPoint(x: $0.x / max(1, bounds.width), y: $0.y / max(1, bounds.height))
      }
    }
  }
  /// The loupe at the film's scale, as the table shows it before zooming in.
  func loupeRadius(for style: LoupeStyle) -> CGFloat {
    let reserve = loupeRest.map { bounds.maxX - $0.minX - Self.inset } ?? 0
    return loupeRadius(style, scale: fitScale(reserving: reserve))
  }
  private func loupeRadius(_ style: LoupeStyle, scale: CGFloat) -> CGFloat {
    guard let model, let cg = shown, model.physicalMM.height > 0 else { return 70 }
    let shownHeight = turn.sideways ? model.physicalMM.width : model.physicalMM.height
    let pointsPerMM = scale * CGFloat(cg.height) / max(1, shownHeight)
    return min(110, max(44, CGFloat(style.baseMM / 2) * pointsPerMM))
  }
  func updateLoupe() {
    guard let model else { return }
    let hidden = model.singleView || !model.preferences.showLoupe
    loupe.style = model.preferences.loupeStyle
    if loupe.isHidden != hidden {
      loupe.isHidden = hidden
      if !hidden { loupe.layoutOnTable() }
    }
    if !hidden { loupeMoved() }
  }
  private var snapshot: (key: Int, image: CGImage)?
  private var snapshotting = false
  private var drawnKey = 0
  /// Everything the canvas draws, so redraws that change nothing keep the loupe's picture.
  private var tableKey: Int {
    var h = Hasher()
    h.combine(bounds.width)
    h.combine(bounds.height)
    h.combine(window?.backingScaleFactor)
    h.combine(inLiveResize)
    guard let model else { return h.finalize() }
    h.combine(model.displayed.map(ObjectIdentifier.init))
    h.combine(turn.turns)
    h.combine(turn.mirrored)
    let r = imageRect
    for v in [r.minX, r.minY, r.width, r.height] { h.combine(v) }
    h.combine(model.singleView)
    h.combine(model.selectedID)
    for f in model.contactFrames {
      h.combine(f.id)
      h.combine(f.name)
      h.combine(f.enabled)
      for v in [f.rect.x, f.rect.y, f.rect.width, f.rect.height] { h.combine(v) }
    }
    if let draft { for v in [draft.minX, draft.minY, draft.width, draft.height] { h.combine(v) } }
    h.combine(dragID)
    return h.finalize()
  }
  private func tableDrawn() {
    guard !snapshotting else { return }
    let key = tableKey
    guard key != drawnKey else { return }
    drawnKey = key
    if !loupe.isHidden { loupe.setNeedsRender() }
    if !scanHead.isHidden { scanHead.setNeedsRender() }
  }
  /// The canvas as drawn, without the loupe or the scan head: what they stand on and look through.
  func tableSnapshot() -> CGImage? {
    let key = tableKey
    if snapshot?.key != key, bounds.width >= 1, bounds.height >= 1,
      let rep = bitmapImageRepForCachingDisplay(in: bounds)
    {
      snapshotting = true
      loupe.drawingSuppressed = true
      scanHead.drawingSuppressed = true
      cacheDisplay(in: bounds, to: rep)
      loupe.drawingSuppressed = false
      scanHead.drawingSuppressed = false
      snapshotting = false
      snapshot = rep.cgImage.map { (key, $0) }
    }
    return snapshot?.image
  }
  /// The viewer, in front of the table and well above it, for the overlays' perspective.
  var viewer: SIMD3<Float> { SIMD3(Float(bounds.midX), Float(bounds.maxY), Float(max(bounds.width, bounds.height) * 2)) }
  /// A point of the overview on the canvas: on the (turned) table, or in the single frame.
  func canvasPoint(overview p: CGPoint) -> CGPoint? {
    guard let model else { return nil }
    let d: CGPoint
    if model.singleView {
      guard let s = model.singleViewPoint(p) else { return nil }
      d = s
    } else {
      d = turn.shown(p)
    }
    let b = imageRect
    return CGPoint(x: b.minX + d.x * b.width, y: b.minY + d.y * b.height)
  }
  func updateScanHead() {
    guard let model else { return }
    scanHead.follow(frame: model.scanningFrame?.id, progress: ScanBatchProgress.normalized(model.scanner.progress))
  }
  /// Where the head is over `frame` at `progress`: across the frame, a little past each side,
  /// at the line the scanner has reached. The V850 reads the bed from its top down.
  func scanHeadPose(frame id: UUID, progress: Double) -> ScanHeadRenderer.Pose? {
    guard let model, let frame = model.frames.first(where: { $0.id == id }) else { return nil }
    if model.singleView {
      guard model.selectedID == id else { return nil }
    } else {
      guard model.contactFrames.contains(where: { $0.id == id }) else { return nil }
    }
    let r = frame.rect, y = r.y + r.height * clamp(progress), margin = r.width * 0.12
    guard let a = canvasPoint(overview: CGPoint(x: r.x - margin, y: y)),
      let b = canvasPoint(overview: CGPoint(x: r.x + r.width + margin, y: y)),
      let top = canvasPoint(overview: CGPoint(x: r.x + r.width / 2, y: r.y)),
      let bottom = canvasPoint(overview: CGPoint(x: r.x + r.width / 2, y: r.y + r.height))
    else { return nil }
    let length = hypot(b.x - a.x, b.y - a.y), span = hypot(bottom.x - top.x, bottom.y - top.y)
    guard length > 4, span > 4 else { return nil }
    let width = min(46, max(12, span * 0.15))
    return ScanHeadRenderer.Pose(
      a: a, axis: CGVector(dx: (b.x - a.x) / length, dy: (b.y - a.y) / length),
      travel: CGVector(dx: (bottom.x - top.x) / span, dy: (bottom.y - top.y) / span),
      length: length, width: width, height: width * 0.62, gap: width * 0.32, eye: viewer)
  }
  /// The table as drawn, without the loupe: what its skirt and lens look through.
  func loupeScene() -> LoupeRenderer.Scene {
    var scene = LoupeRenderer.Scene(table: tableSnapshot(), canvas: bounds.size)
    if let shown {
      scene.film = shown
      scene.filmRect = imageRect
    }
    // Not after a new preview, a moved frame box or a switch between raw and positive. After an
    // edit it stays until the new picture arrives, so the lens never goes blank.
    if let model, let detail = loupeDetail, detail.positive == model.contactPositive,
      let frame = model.contactFrames.first(where: { $0.id == detail.id }), frame.rect == detail.rect
    {
      scene.detail = turnedDetail(detail.key, detail.image)
      scene.detailRect = screen(frame.rect.cg)
      if model.loupeDetailKey(frame) != detail.key {
        DispatchQueue.main.async { [weak self] in self?.loupeMoved() }
      }
    }
    return scene
  }
  private var loupeDetail: (key: String, id: UUID, rect: NormalRect, positive: Bool, image: CGImage)?
  private var turnedLoupeDetail: (key: String, turn: QuarterTurn, image: CGImage)?
  /// The frame under the lens, turned with the table.
  private func turnedDetail(_ key: String, _ image: CGImage) -> CGImage {
    let t = turn
    guard !t.isIdentity else { return image }
    if let cached = turnedLoupeDetail, cached.key == key, cached.turn == t { return cached.image }
    guard let turned = ImagePipeline.shared.turned(image, quarterTurns: t.turns, mirrored: t.mirrored) else { return image }
    turnedLoupeDetail = (key, t, turned)
    return turned
  }
  private var loupeDetailRequest: String?
  /// Fetches the frame under the loupe at its own resolution, once per change to it.
  func loupeMoved() {
    guard let model, let center = loupe.center, imageRect.contains(center) else { return }
    let n = normal(center)
    guard let frame = model.contactFrames.last(where: { $0.rect.cg.contains(n) }) else { return }
    let key = model.loupeDetailKey(frame)
    guard key != loupeDetailRequest, key != loupeDetail?.key else { return }
    loupeDetailRequest = key
    let positive = model.contactPositive
    model.loupeDetail(for: frame) { [weak self] image in
      guard let self, self.loupeDetailRequest == key else { return }
      self.loupeDetailRequest = nil
      self.loupeDetail = image.map { (key, frame.id, frame.rect, positive, $0) }
      self.loupe.setNeedsRender()
    }
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    guard let model, model.displayed != nil, !model.rendering else { return }
    let p = convert(event.locationInWindow, from: nil)
    guard bounds.contains(p), imageRect.contains(p) else { return }
    if model.tool == .base || model.tool == .neutral || model.tool == .calibrate || model.tool == .it8 {
      model.sample(normal(p))
      return
    }
    if model.tool == .loupe {
      hover = p
      needsDisplay = true
      return
    }
    if model.singleView {
      if model.tool == .crop, let crop = model.canvasCrop, !model.isWorking {
        dragStart = normal(p)
        dragID = model.selectedID
        original = crop.cg
        draft = crop.cg
        let r = screen(crop.cg)
        corner = corners(crop.cg).firstIndex { hypot($0.x - p.x, $0.y - p.y) < 13 }
        if corner == nil && !r.contains(p) {
          dragID = nil
          original = nil
          draft = CGRect(origin: normal(p), size: .zero)
        }
        return
      }
      panStart = p
      return
    }
    guard !model.isWorking else { return }
    dragStart = normal(p)
    if model.tool == .crop {
      draft = CGRect(origin: dragStart!, size: .zero)
      return
    }
    if let f = model.frames.first(where: { $0.id == model.selectedID }) {
      if let c = corners(f.rect.cg).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 10 }) {
        corner = c
        dragID = f.id
        original = f.rect.cg
        draft = f.rect.cg
        return
      }
    }
    if let f = model.contactFrames.reversed().first(where: { $0.rect.cg.contains(normal(p)) }) {
      model.select(f.id)
      if event.clickCount == 2 {
        model.singleView = true
        model.refresh()
        return
      }
      dragID = f.id
      original = f.rect.cg
      draft = f.rect.cg
    }
  }
  override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if let start = panStart {
      pan.x += p.x - start.x
      pan.y += p.y - start.y
      panStart = p
      clampPan()
      needsDisplay = true
      return
    }
    guard let start = dragStart else { return }
    let end = normal(p)
    if let original, dragID != nil {
      if let corner {
        let opposite = CGPoint(
          x: corner % 2 == 0 ? original.maxX : original.minX,
          y: corner < 2 ? original.maxY : original.minY)
        draft = CGRect(
          x: min(end.x, opposite.x), y: min(end.y, opposite.y), width: abs(end.x - opposite.x),
          height: abs(end.y - opposite.y))
      } else {
        draft = CGRect(
          x: clamp(original.minX + end.x - start.x, 0, 1 - original.width),
          y: clamp(original.minY + end.y - start.y, 0, 1 - original.height), width: original.width,
          height: original.height)
      }
    } else if model?.tool == .crop {
      draft = CGRect(
        x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
        height: abs(end.y - start.y))
    }
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    defer {
      dragStart = nil
      draft = nil
      original = nil
      dragID = nil
      corner = nil
      panStart = nil
      needsDisplay = true
    }
    guard let draft else { return }
    if model?.singleView == true, model?.tool == .crop {
      model?.commitSingleCrop(NormalRect(draft))
    } else if let id = dragID {
      model?.setRect(id, rect: NormalRect(draft))
    } else if model?.tool == .crop {
      model?.addFrame(NormalRect(draft))
    }
  }
  override func scrollWheel(with event: NSEvent) {
    if event.modifierFlags.contains(.command) {
      setZoom(
        (model?.zoom ?? 1) * exp(-event.scrollingDeltaY * 0.01),
        anchor: convert(event.locationInWindow, from: nil))
    } else if (model?.zoom ?? 1) > 1 {
      pan.x -= event.scrollingDeltaX
      pan.y -= event.scrollingDeltaY
      clampPan()
    }
    needsDisplay = true
  }
  override func magnify(with event: NSEvent) {
    setZoom(
      (model?.zoom ?? 1) * (1 + event.magnification),
      anchor: convert(event.locationInWindow, from: nil))
    needsDisplay = true
  }
  func setZoom(_ zoom: Double, anchor: CGPoint) {
    let old = imageRect
    guard old.width > 0, old.height > 0 else { return }
    let n = CGPoint(x: (anchor.x - old.minX) / old.width, y: (anchor.y - old.minY) / old.height)
    model?.zoom = clamp(zoom, 0.5, 8)
    let new = imageRect
    pan.x += anchor.x - (new.minX + n.x * new.width)
    pan.y += anchor.y - (new.minY + n.y * new.height)
    clampPan()
    needsDisplay = true
  }
  override func keyDown(with event: NSEvent) {
    if model?.singleView == true, model?.tool == .crop,
      [123, 124, 125, 126].contains(event.keyCode), let crop = model?.canvasCrop
    {
      let step =
        (event.modifierFlags.contains(.shift) ? 10.0 : 1.0)
        / Double(max(model?.displayed?.width ?? 1, model?.displayed?.height ?? 1))
      let dx = event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0)
      let dy = event.keyCode == 126 ? -step : (event.keyCode == 125 ? step : 0)
      model?.commitSingleCrop(
        NormalRect(
          x: clamp(crop.x + dx, 0, 1 - crop.width), y: clamp(crop.y + dy, 0, 1 - crop.height),
          width: crop.width, height: crop.height))
    } else if event.keyCode == 36 && model?.tool == .crop && model?.singleView == true {
      model?.useTool(.select)
    } else if model?.singleView == true, [123, 124].contains(event.keyCode),
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    {
      model?.navigate(event.keyCode == 123 ? -1 : 1)
    } else if event.keyCode == 51 {
      model?.deletePressed()
    } else if event.keyCode == 53 {
      model?.useTool(.select)
      model?.fitView()
      pan = .zero
      needsDisplay = true
    } else if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
      let key = event.charactersIgnoringModifiers?.lowercased(),
      let tool = CanvasTool.allCases.first(where: { $0.shortcut == key })
    {
      model?.useTool(tool)
    } else {
      super.keyDown(with: event)
    }
  }
}
