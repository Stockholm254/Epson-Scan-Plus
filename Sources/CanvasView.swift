import AppKit
import SwiftUI

struct ScanCanvas: NSViewRepresentable {
  @ObservedObject var model: AppModel
  /// Room at the edges taken by panels and bars floating over the canvas.
  var reserved = NSEdgeInsets()
  func makeNSView(context: Context) -> FilmCanvasView {
    let v = FilmCanvasView()
    v.model = model
    model.frameOpener = { [weak v] id in v?.open(id) }
    model.viewWillChange = { [weak v] change in v?.viewWillChange(change) }
    model.pictureChanged = { [weak v] in v?.modelChanged() }
    model.zoomChanged = { [weak v] in v?.zoomChanged() }
    model.glideZoom = { [weak v] zoom, anchor in v?.glideZoom(to: zoom, about: anchor) }
    return v
  }
  func updateNSView(_ view: FilmCanvasView, context: Context) {
    view.model = model
    view.reserved = reserved
    view.modelChanged()
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
  /// The canvas's picture (the single frame, or the light table's print or page), and the part of
  /// the single frame zoomed into at its own resolution: layers the window server scales and
  /// colour-matches on the GPU. Drawn into the canvas, each picture was resampled and converted to
  /// the screen's colours on the main thread at every redraw, a third of its time while a slider was
  /// dragged, and all of a zoom's.
  let pictureLayer = CALayer()
  let detailLayer = CALayer()
  /// What lies over the picture (`drawOverlays`), above its layers.
  let overlay = CanvasOverlay()
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
    for picture in [pictureLayer, detailLayer] {
      picture.isHidden = true
      picture.contentsGravity = .resize
      picture.minificationFilter = .trilinear
      picture.magnificationFilter = .linear
      // Placed as the canvas draws: nothing of it animates by itself.
      picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "magnificationFilter": NSNull()]
    }
    layer?.insertSublayer(pictureLayer, at: 0)
    layer?.insertSublayer(detailLayer, above: pictureLayer)
    overlay.canvas = self
    overlay.frame = bounds
    addSubview(overlay)
    loupe.canvas = self
    loupe.isHidden = true
    addSubview(loupe)
    scanHead.canvas = self
    scanHead.isHidden = true
    addSubview(scanHead, positioned: .below, relativeTo: loupe)
    // Placed by their frames, out of Auto Layout: a frame of theirs changed, the window was laid
    // out again for the constraints it stood for, 27 ms for each step of a zoom with the loupe out.
    loupe.translatesAutoresizingMaskIntoConstraints = false
    scanHead.translatesAutoresizingMaskIntoConstraints = false
    overlay.translatesAutoresizingMaskIntoConstraints = false
  }
  /// Whatever the canvas redraws, what lies over its picture is drawn again with it.
  override var needsDisplay: Bool {
    get { super.needsDisplay }
    set {
      super.needsDisplay = newValue
      if newValue { overlay.needsDisplay = true }
    }
  }
  override func setNeedsDisplay(_ invalidRect: NSRect) {
    super.setNeedsDisplay(invalidRect)
    overlay.setNeedsDisplay(invalidRect)
  }
  /// Drawn now, it is drawn now with what lies over its picture.
  override func display() {
    super.display()
    overlay.display()
  }
  override func displayIfNeeded() {
    super.displayIfNeeded()
    overlay.displayIfNeeded()
  }
  /// A picture taken of the canvas has its picture drawn into it, with what lies over it; its
  /// picture's own layers are hidden meanwhile (`tableSnapshot`), as the system draws them too.
  override func cacheDisplay(in rect: NSRect, to bitmapImageRep: NSBitmapImageRep) {
    let was = snapshotting
    snapshotting = true
    defer { snapshotting = was }
    super.cacheDisplay(in: rect, to: bitmapImageRep)
  }
  /// The canvas's picture on its layers, as the canvas draws: `nil` hides them.
  private func placePicture(_ p: (image: CGImage, rect: CGRect, covered: Bool, detail: (CGImage, CGRect)?)?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard let p else {
      pictureLayer.isHidden = true
      detailLayer.isHidden = true
      detailLayer.contents = nil
      return
    }
    if (pictureLayer.contents as AnyObject?) !== p.image { pictureLayer.contents = p.image }
    if pictureLayer.frame != p.rect { pictureLayer.frame = p.rect }
    pictureLayer.isHidden = p.covered
    if let (detail, area) = p.detail {
      if (detailLayer.contents as AnyObject?) !== detail { detailLayer.contents = detail }
      if detailLayer.frame != area { detailLayer.frame = area }
      // Once a pixel of the frame is two of the screen or more, square, as the frame's own.
      let pixelsPerPixel = area.width * (window?.backingScaleFactor ?? 2) / CGFloat(max(1, detail.width))
      let filter: CALayerContentsFilter = pixelsPerPixel >= 2 ? .nearest : .linear
      if detailLayer.magnificationFilter != filter { detailLayer.magnificationFilter = filter }
      detailLayer.isHidden = false
    } else {
      detailLayer.isHidden = true
      detailLayer.contents = nil
    }
  }
  override var wantsDefaultClipping: Bool { true }
  /// Follows the model: on every update of the window, and by itself for each new picture of the
  /// single frame, which the model hands the canvas without updating the window around it.
  func modelChanged() {
    guard let model else { return }
    // A sampler shows its eyedropper over the canvas.
    if cursorTool != model.tool {
      cursorTool = model.tool
      window?.invalidateCursorRects(for: self)
      window?.invalidateCursorRects(for: loupe)
    }
    if lastViewportRevision != model.viewportRevision {
      pan = .zero
      lastViewportRevision = model.viewportRevision
    }
    refreshCursorArea()
    clampPan()
    applyFocusRequest()
    needsDisplay = true
    updateLoupe()
    updateScanHead()
    settleOpening()
    pictureUnderPointer()
  }
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
  /// The crop's edge being dragged, as `cropHold` names it.
  var edge: Int?
  /// The crop's resize pointer is up (`updateCropCursor`).
  private var cropCursorShown = false
  /// The glass bubble over a corner being dragged: the corner, in the shown picture's normalised
  /// coordinates, and when it appeared; the bubble last drawn, and the one fading after release.
  var lens: (point: CGPoint, since: CFTimeInterval)?
  var lensDrawn: (key: String, image: CGImage, frame: CGRect)?
  var lensFading: (image: CGImage, frame: CGRect, since: CFTimeInterval)?
  private var lensTimer: Timer?
  private var baseFlashTimer: Timer?
  /// The de-masking region being drawn (no `original`) or changed by a corner, an edge or the box
  /// itself, in the picture's own coordinates (`pictureNormal`); and the box as it is dragged.
  private var regionDrag: (start: CGPoint, original: CGRect?, corner: Int?, edge: Int?)?
  private(set) var regionDraft: CGRect?
  var pan = CGPoint.zero
  /// A zoom gliding to its end (`glideZoom`), until it lands or the pointer takes over.
  var zoomGlide: ZoomGlide?
  /// When the single frame was last clicked, for a double click to zoom.
  private var singleClickAt: TimeInterval = 0
  var panStart: CGPoint?
  /// A frame clicked on the light table, and where: it opens if the mouse comes up there.
  var clickedFrame: (id: UUID, at: CGPoint)?
  /// A line being drawn to straighten the frame by, on the canvas.
  var levelLine: (from: CGPoint, to: CGPoint)?
  /// Room at the edges taken by panels and bars floating over the canvas: the light table runs
  /// under them, the picture fits between.
  var reserved = NSEdgeInsets() {
    didSet {
      guard !NSEdgeInsetsEqual(reserved, oldValue) else { return }
      clampPan()
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
      if !loupe.isHidden { loupe.layoutOnTable() }
    }
  }
  var cursorTool: CanvasTool?
  /// The pointer while a sampler is chosen: an eyedropper, its tip on the point read (filled for
  /// the film base, as its key shows), or cross hairs for marking the IT8 target.
  var samplingCursor: NSCursor? {
    switch model?.tool {
    case .base: return Self.filledDropper
    case .neutral, .shadowNeutral, .calibrate: return Self.dropper
    case .it8, .dust, .curve: return .crosshair
    default: return nil
    }
  }
  private static let dropper = eyedropper("eyedropper")
  private static let filledDropper = eyedropper("eyedropper.full")
  private static func eyedropper(_ symbol: String) -> NSCursor {
    let size = NSSize(width: 24, height: 24)
    let image = NSImage(size: size, flipped: false) { rect in
      guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .medium))
      else { return false }
      func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: glyph.size, flipped: false) { r in
          glyph.draw(in: r)
          color.set()
          r.fill(using: .sourceAtop)
          return true
        }
      }
      // A white outline round a dark glyph, legible on the bright table and the dark surround.
      let at = NSPoint(x: 2, y: 2), white = tinted(.white), dark = tinted(NSColor(white: 0.1, alpha: 1))
      for dx in [-1.0, 0, 1] { for dy in [-1.0, 0, 1] { white.draw(at: NSPoint(x: at.x + dx, y: at.y + dy), from: .zero, operation: .sourceOver, fraction: 1) } }
      dark.draw(at: at, from: .zero, operation: .sourceOver, fraction: 1)
      return true
    }
    // The tip is at the glyph's lower left; a cursor's hot spot counts from the top.
    return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: size.height - 3))
  }
  override func resetCursorRects() {
    super.resetCursorRects()
    // Only over the picture, and not under the panels and bars floating over the canvas.
    let area = imageRect.intersection(openRect)
    if let cursor = samplingCursor, !area.isEmpty { addCursorRect(area, cursor: cursor) }
  }
  /// The canvas between what floats over it.
  private var open: CGSize {
    CGSize(width: bounds.width - reserved.left - reserved.right, height: bounds.height - reserved.top - reserved.bottom)
  }
  var openRect: CGRect { CGRect(x: reserved.left, y: reserved.top, width: max(0, open.width), height: max(0, open.height)) }
  private var cursorArea = CGRect.zero
  /// The sampler's cursor follows the picture: a new frame shown, the view panned or zoomed.
  func refreshCursorArea() {
    let area = imageRect.intersection(openRect)
    guard area != cursorArea else { return }
    cursorArea = area
    window?.invalidateCursorRects(for: self)
  }
  /// The pan kept within the canvas; not while a zoom glides, whose path keeps it there.
  func clampPan() {
    guard zoomGlide == nil else { return }
    pan = clamped(pan, zoom: model?.zoom ?? 1)
  }
  /// How far the picture can be moved off the middle, either way, at `zoom`: as far as it then
  /// overhangs the canvas.
  func panLimit(zoom: Double) -> CGSize {
    guard let cg = shown else { return .zero }
    let k = fitScale * CGFloat(zoom)
    return CGSize(width: max(0, (CGFloat(cg.width) * k - open.width) / 2), height: max(0, (CGFloat(cg.height) * k - open.height) / 2))
  }
  func clamped(_ p: CGPoint, zoom: Double) -> CGPoint {
    let limit = panLimit(zoom: zoom)
    return CGPoint(x: clamp(p.x, -limit.width, limit.width), y: clamp(p.y, -limit.height, limit.height))
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    overlay.frame = bounds
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
    // A preview being read shows as it comes, in place of the roll before it.
    guard let cg = model?.scanner.previewSoFar ?? model?.displayed else { return nil }
    let t = turn
    guard !t.isIdentity else { return cg }
    if let cached = turnedImage, cached.source === cg, cached.turn == t { return cached.image }
    guard let image = ImagePipeline.shared.turned(cg, quarterTurns: t.turns, mirrored: t.mirrored) else { return cg }
    turnedImage = (cg, t, image)
    return image
  }
  private static let inset: CGFloat = 28
  /// Points per pixel of the shown picture that fit the canvas.
  private var fitScale: CGFloat {
    guard let cg = shown else { return 1 }
    return min(
      max(1, open.width - 2 * Self.inset) / CGFloat(cg.width),
      max(1, open.height - 2 * Self.inset) / CGFloat(cg.height))
  }
  var imageRect: CGRect {
    guard let cg = shown else { return .zero }
    let scale = fitScale * CGFloat(model?.zoom ?? 1)
    let size = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
    return CGRect(
      x: reserved.left + (open.width - size.width) / 2 + pan.x, y: reserved.top + (open.height - size.height) / 2 + pan.y,
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
  /// A rect's edges by their two corners (`corners` order): its min y, max y, min x and max x.
  static let edgeEnds = [(0, 1), (2, 3), (0, 2), (1, 3)]
  /// How near a press must come, in the window's points whatever the zoom, to take hold of a box's
  /// corner, else its edge: the crop's and the de-masking region's alike.
  static let cornerReach: CGFloat = 18, edgeReach: CGFloat = 12
  /// What a press at canvas point `p` takes hold of on the crop `r`: a corner (`cornerReach` round
  /// it, in `corners` order), else an edge (`edgeReach` either side of it, in `edgeEnds` order),
  /// else neither.
  func cropHold(_ r: CGRect, at p: CGPoint) -> (corner: Int?, edge: Int?) {
    let c = corners(r)
    if let i = c.indices.filter({ hypot(c[$0].x - p.x, c[$0].y - p.y) < Self.cornerReach }).min(by: { hypot(c[$0].x - p.x, c[$0].y - p.y) < hypot(c[$1].x - p.x, c[$1].y - p.y) }) { return (i, nil) }
    func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
      let d = CGPoint(x: b.x - a.x, y: b.y - a.y), length = d.x * d.x + d.y * d.y
      let t = length > 0 ? max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / length)) : 0
      return hypot(p.x - (a.x + t * d.x), p.y - (a.y + t * d.y))
    }
    let near = Self.edgeEnds.indices.map { ($0, distance(c[Self.edgeEnds[$0].0], c[Self.edgeEnds[$0].1])) }
      .filter { $0.1 < Self.edgeReach }.min { $0.1 < $1.1 }
    return (nil, near?.0)
  }
  /// The two crops' colours on the picture: the picture's amber, the de-masking region's cyan.
  static func colour(_ tool: CanvasTool) -> NSColor {
    let c = tool.colour ?? (1, 1, 1)
    return NSColor(calibratedRed: c.red, green: c.green, blue: c.blue, alpha: 1)
  }
  /// The part of the picture the de-masking reads while no region is set and no film edge lies in
  /// the crop: all but its outer 5% (`AppModel.followedRegion`).
  static let followRegion = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
  /// A canvas point in the single frame's picture as cropped, unturned and not straightened: where
  /// the de-masking region lives.
  func pictureNormal(_ p: CGPoint) -> CGPoint? {
    guard let model, let frame = model.selected else { return nil }
    let q = ImageGeometry.raw(shownNormal(p), settings: frame.adjustments, aspect: model.shownAspect(frame))
    return CGPoint(x: clamp(Double(q.x)), y: clamp(Double(q.y)))
  }
  /// A rect of the picture (`pictureNormal`) on the canvas, by its corners in `corners` order.
  func pictureCorners(_ r: CGRect) -> [CGPoint] {
    guard let model, let frame = model.selected else { return [] }
    let b = imageRect, aspect = model.shownAspect(frame)
    return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
      .map { n in
        let d = ImageGeometry.display(n, settings: frame.adjustments, aspect: aspect)
        return CGPoint(x: b.minX + d.x * b.width, y: b.minY + d.y * b.height)
      }
  }
  /// What a press at `p` takes hold of on the de-masking region `r`, as `cropHold` does on the crop.
  func regionHold(_ r: CGRect, at p: CGPoint) -> (corner: Int?, edge: Int?) {
    let c = pictureCorners(r)
    guard c.count == 4 else { return (nil, nil) }
    if let i = c.indices.filter({ hypot(c[$0].x - p.x, c[$0].y - p.y) < Self.cornerReach }).min(by: { hypot(c[$0].x - p.x, c[$0].y - p.y) < hypot(c[$1].x - p.x, c[$1].y - p.y) }) { return (i, nil) }
    func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
      let d = CGPoint(x: b.x - a.x, y: b.y - a.y), length = d.x * d.x + d.y * d.y
      let t = length > 0 ? max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / length)) : 0
      return hypot(p.x - (a.x + t * d.x), p.y - (a.y + t * d.y))
    }
    let near = Self.edgeEnds.indices.map { ($0, distance(c[Self.edgeEnds[$0].0], c[Self.edgeEnds[$0].1])) }
      .filter { $0.1 < Self.edgeReach }.min { $0.1 < $1.1 }
    return (nil, near?.0)
  }
  /// A small label in `colour` by the canvas point `at`, kept on the picture.
  private func drawTag(_ text: String, at: CGPoint, colour: NSColor) {
    let r = imageRect, font = NSFont.systemFont(ofSize: 11, weight: .medium)
    let size = (text as NSString).size(withAttributes: [.font: font])
    let label = NSRect(
      x: min(max(r.minX + 4, at.x + 4), r.maxX - size.width - 16), y: min(max(r.minY + 4, at.y + 4), r.maxY - size.height - 10),
      width: size.width + 12, height: size.height + 6)
    colour.setFill()
    NSBezierPath(roundedRect: label, xRadius: 4, yRadius: 4).fill()
    (text as NSString).draw(at: CGPoint(x: label.minX + 6, y: label.minY + 3), withAttributes: [.font: font, .foregroundColor: NSColor.black])
  }
  /// The de-masking region on the single frame, cyan: dashed while it only shows, and with its own
  /// tool up drawn with corners, the rest of the picture dimmed and the picture's crop outlined in
  /// amber, each labelled. With no region set the tool shows what is read instead, dashed.
  private func drawAnalysisRegion(_ frame: FilmFrame) {
    guard let model else { return }
    let editing = model.tool == .region, set = regionDraft ?? frame.adjustments.analysisRegion?.cg
    let c = pictureCorners(set ?? model.followedRegion), whole = pictureCorners(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard c.count == 4, whole.count == 4 else { return }
    let box = [c[0], c[1], c[3], c[2]], picture = [whole[0], whole[1], whole[3], whole[2]]
    let cyan = Self.colour(.region), amber = Self.colour(.crop)
    if editing {
      let mask = NSBezierPath()
      mask.appendPolygon(picture)
      mask.appendPolygon(box)
      mask.windingRule = .evenOdd
      NSColor.black.withAlphaComponent(set == nil ? 0.25 : 0.45).setFill()
      mask.fill()
      let outline = NSBezierPath()
      outline.appendPolygon(picture)
      outline.lineWidth = 2
      amber.setStroke()
      outline.stroke()
    }
    let line = NSBezierPath()
    line.appendPolygon(box)
    line.lineWidth = editing && set != nil ? 2 : 1.5
    if !editing || set == nil { line.setLineDash([6, 4], count: 2, phase: 0) }
    cyan.setStroke()
    line.stroke()
    guard editing else { return }
    if set != nil {
      cyan.setFill()
      for p in c { NSBezierPath(roundedRect: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10), xRadius: 2, yRadius: 2).fill() }
    }
    let topLeft = { (points: [CGPoint]) in points.min { $0.x + $0.y < $1.x + $1.y }! }
    drawTag("画面裁切", at: topLeft(picture), colour: amber)
    let first = topLeft(box)
    let following = model.toneAnalysis?.followed != nil ? "去色罩区域 · 跟随画面，避开片边" : "去色罩区域 · 跟随画面"
    drawTag(set == nil ? following : "去色罩区域", at: CGPoint(x: first.x, y: first.y + 24), colour: cyan)
  }
  /// Over the single frame's crop, the pointer shows what a press there would resize: a corner or
  /// an edge, at the side of the box it is on the screen.
  private func updateCropCursor(at p: CGPoint?) {
    var cursor: NSCursor?
    if let p, let model, model.singleView, model.tool == .crop, let crop = model.canvasCrop, !model.isWorking,
      dragStart == nil, imageRect.contains(p)
    {
      let hold = cropHold(crop.cg, at: p), r = screen(crop.cg), c = corners(crop.cg)
      let at: CGPoint? = hold.corner.map { c[$0] } ?? hold.edge.map { e in
        let (a, b) = (c[Self.edgeEnds[e].0], c[Self.edgeEnds[e].1])
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
      }
      if let at {
        // The view is flipped: the smaller y is the top.
        let left = at.x < r.midX - r.width / 4, right = at.x > r.midX + r.width / 4
        let top = at.y < r.midY - r.height / 4, bottom = at.y > r.midY + r.height / 4
        let position: NSCursor.FrameResizePosition? =
          top && left ? .topLeft : top && right ? .topRight : bottom && left ? .bottomLeft : bottom && right ? .bottomRight
          : top ? .top : bottom ? .bottom : left ? .left : right ? .right : nil
        cursor = position.map { NSCursor.frameResize(position: $0, directions: .all) }
      }
    } else if let p, let model, model.singleView, model.tool == .region, let frame = model.selected,
      !model.isWorking, regionDrag == nil, imageRect.contains(p)
    {
      // While none is set, the part read as the picture follows (`followedRegion`) is held as one.
      let r = frame.adjustments.analysisRegion?.cg ?? model.followedRegion, hold = regionHold(r, at: p), c = pictureCorners(r)
      let at: CGPoint? = hold.corner.map { c[$0] } ?? hold.edge.map { e in
        let (a, b) = (c[Self.edgeEnds[e].0], c[Self.edgeEnds[e].1])
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
      }
      if let at {
        let xs = c.map(\.x), ys = c.map(\.y), midX = (xs.min()! + xs.max()!) / 2, midY = (ys.min()! + ys.max()!) / 2
        let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
        let left = at.x < midX - w / 4, right = at.x > midX + w / 4, top = at.y < midY - h / 4, bottom = at.y > midY + h / 4
        let position: NSCursor.FrameResizePosition? =
          top && left ? .topLeft : top && right ? .topRight : bottom && left ? .bottomLeft : bottom && right ? .bottomRight
          : top ? .top : bottom ? .bottom : left ? .left : right ? .right : nil
        cursor = position.map { NSCursor.frameResize(position: $0, directions: .all) }
      }
    }
    if let cursor {
      cursor.set()
      cropCursorShown = true
    } else if cropCursorShown {
      NSCursor.arrow.set()
      cropCursorShown = false
    }
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
  /// The light table's picture and page last drawn: a new picture of another page slides in.
  private var drawnPicture: CGImage?
  private(set) var drawnPage = 0
  /// When a page last slid in for another.
  private var lastPageTurn: CFTimeInterval = 0
  /// The light table's selection moving by ← → to the next frame on the page: where its outline
  /// set out from, in the table's coordinates, the frame it goes to, and when.
  private var selectionGlide: (from: CGRect, to: UUID, start: CFTimeInterval)?
  private var selectionGlideTimer: Timer?
  static let selectionGlides: CFTimeInterval = 0.2
  /// Where the selection's outline is now, in the table's coordinates, while it moves; nil once it
  /// is on its frame.
  func glidingSelectionRect() -> CGRect? {
    // A picture taken of the table (the loupe's, a view's change) has the selection on its frame.
    guard let g = selectionGlide, !snapshotting, let model, !model.singleView, model.selectedID == g.to,
      let f = model.contactFrames.first(where: { $0.id == g.to })
    else { return nil }
    let t = (CACurrentMediaTime() - g.start) / Self.selectionGlides
    guard t < 1 else { return nil }
    let k = CGFloat(1 - pow(1 - max(0, t), 3)), to = model.contactRect(f).cg
    return CGRect(x: g.from.minX + (to.minX - g.from.minX) * k, y: g.from.minY + (to.minY - g.from.minY) * k,
      width: g.from.width + (to.width - g.from.width) * k, height: g.from.height + (to.height - g.from.height) * k)
  }
  /// ← → on the light table: the selection's outline slides from the frame it was on to the next,
  /// on the same page; another page turns in instead.
  func glideTableSelection(from was: UUID?) {
    guard let model, !model.singleView, !Self.stillMotion, let was, let now = model.selectedID, was != now,
      let a = model.contactFrames.first(where: { $0.id == was }), model.contactFrames.contains(where: { $0.id == now })
    else { return }
    let from = glidingSelectionRect() ?? model.contactRect(a).cg
    selectionGlide = (from, now, CACurrentMediaTime())
    selectionGlideTimer?.invalidate()
    let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      self.overlay.needsDisplay = true
      if self.glidingSelectionRect() == nil {
        timer.invalidate()
        self.selectionGlideTimer = nil
        self.selectionGlide = nil
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    selectionGlideTimer = timer
    overlay.needsDisplay = true
  }
  private func turnPage() {
    guard let model, let picture = model.displayed, picture !== drawnPicture else { return }
    defer {
      drawnPicture = picture
      drawnPage = model.contactPage
    }
    // A picture taken of the canvas for the loupe or a change of view records, but plays nothing.
    guard drawnPicture != nil, model.contactPage != drawnPage, !model.singleView, !snapshotting, let layer else {
      transitionPicture(picture, play: drawnPicture != nil && !snapshotting)
      return
    }
    transitionPicture(picture, play: false)
    let slide = CATransition()
    // Pages turned quicker than one slides in: each a short cross-fade, keeping up.
    let at = CACurrentMediaTime(), quick = at - lastPageTurn < 0.37
    lastPageTurn = at
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || quick {
      slide.type = .fade
      slide.duration = quick ? 0.12 : 0.2
    } else {
      slide.type = .push
      slide.subtype = model.contactPage > drawnPage ? .fromRight : .fromLeft
      slide.duration = 0.35
    }
    slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(slide, forKey: "page")
  }
  override func draw(_ dirtyRect: NSRect) {
    defer { tableDrawn() }
    // The picture's layers go with what is drawn: hidden unless placed below.
    var picturePlaced = false
    defer { if !picturePlaced && !snapshotting { placePicture(nil) } }
    slideToInterim()
    turnPage()
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
      // ① with the scanner shows its own empty view, with the preview's key.
      if model?.emptyScannerTable == true { return }
      let text = "扫描预览" as NSString
      text.draw(
        at: CGPoint(x: reserved.left + open.width / 2 - 30, y: reserved.top + open.height / 2),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 13),
          .foregroundColor: lightTable ? NSColor(calibratedWhite: 0.42, alpha: 1) : NSColor.secondaryLabelColor,
        ])
      return
    }
    // A frame opened from the table grows over the single view, which shows its own picture only
    // once it has grown and the picture is here: not under the table as it fades.
    if let opening, model.singleView, !opening.grown || model.displayed === opening.over { return }
    // Turning, the old picture turns in the new one's place.
    if change?.hold == true { return }
    // Another frame chosen, its own picture on its way: the film strip's picture of it meanwhile.
    if let face = interimFace() {
      let r = Self.fitted(CGSize(width: face.width, height: face.height), in: fitArea)
      drawShadowPlate(around: r)
      if !snapshotting, window != nil {
        placePicture((face, r, false, nil))
        picturePlaced = true
      } else {
        NSImage(cgImage: face, size: CGSize(width: face.width, height: face.height)).draw(
          in: r, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
      }
      return
    }
    let rect = imageRect
    let sheet = model.onSheetPage
    if !sheet {
      if lightTable {
        NSColor.black.setFill()
        rect.insetBy(dx: -1, dy: -1).fill()
      } else {
        drawShadowPlate(around: rect)
      }
    }
    // Zoomed in past the picture shown, the part in view from the frame's own pixels over it:
    // square, once each is two pixels of the screen or more, so a pixel shows as one. Under one
    // that covers all of the picture in view the picture shown is not drawn: nothing of it is seen.
    let zoomed = zoomDetailInView()
    let covered = zoomed.map { $0.1.insetBy(dx: -0.5, dy: -0.5).contains(rect.intersection(visibleRect)) } ?? false
    // On the GPU (`placePicture`), but in a picture taken of the canvas, which has only what is
    // drawn, and in a drawing of the canvas outside a window.
    if !snapshotting, window != nil {
      placePicture((cg, rect, covered, zoomed))
      picturePlaced = true
      return
    }
    if !covered {
      let image = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
      // A laid-out page's strips lie on the table, its perforations open to the light.
      image.draw(
        in: rect, from: .zero, operation: sheet ? .sourceOver : .copy, fraction: 1, respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high])
    }
    if let (detail, area) = zoomed {
      let pixelsPerPixel = area.width * (window?.backingScaleFactor ?? 2) / CGFloat(max(1, detail.width))
      NSImage(cgImage: detail, size: CGSize(width: detail.width, height: detail.height)).draw(
        in: area, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
        hints: [.interpolation: pixelsPerPixel >= 2 ? NSImageInterpolation.none : .high])
    }
  }
  /// Whether the marks over the picture (the frames' outlines and numbers on the table, the crop) are
  /// drawn now. Not while a change of view (back to the table, into or out of the crop, a turn) or an
  /// opening turned back plays: what it moves is a picture of the canvas with its marks in it, and
  /// the marks drawn over that, already where the change ends, stood beside its own (0.19.0: two sets
  /// of frame outlines, one still large, as the table drew back). In a picture taken of the canvas
  /// they are drawn, so what plays has them.
  var marksShown: Bool { snapshotting || (change == nil && turningBack == nil) }
  /// What lies over the picture, drawn by `overlay` above the picture's layers: the crop and its
  /// handles, the grid, the frames on the light table, the marks of what was picked or found, the
  /// crop's lens. Nothing while the canvas shows no picture, or a change of view covers it.
  func drawOverlays() {
    guard let model, shown != nil, marksShown else { return }
    if let opening, model.singleView, !opening.grown || model.displayed === opening.over { return }
    if change?.hold == true { return }
    // The marks belong to the frame's own picture, not the film strip's shown meanwhile.
    if interimFace() != nil { return }
    let rect = imageRect
    let sheet = model.onSheetPage
    if model.singleView, model.canvasCrop == nil, model.straightening {
      drawGrid(in: [
        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
      ])
    }
    if model.singleView, let crop = model.canvasCrop {
      let r = screen(draft ?? crop.cg)
      // Straightened, the part kept: the crop turned about its middle, the largest rectangle of
      // its shape inside it, turned back onto the picture as it lies.
      let degrees = model.screenAngle
      let kept = abs(degrees) > 0.0001 && r.width > 0 && r.height > 0
        ? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { c -> CGPoint in
          let q = ImageGeometry.straightened(c, degrees: degrees, aspect: Double(r.width / r.height), inverse: true)
          return CGPoint(x: r.minX + q.x * r.width, y: r.minY + q.y * r.height)
        } : nil
      let mask = NSBezierPath(rect: imageRect)
      if let kept { mask.appendPolygon(kept) } else { mask.appendRect(r) }
      mask.windingRule = .evenOdd
      NSColor.black.withAlphaComponent(model.tool == .base ? 0.18 : 0.5).setFill()
      mask.fill()
      NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1).setStroke()
      let outline = NSBezierPath(rect: r)
      outline.lineWidth = kept == nil ? 2 : 1
      if kept != nil { outline.setLineDash([5, 4], count: 2, phase: 0) }
      outline.stroke()
      // The de-masking region, cyan, where it lies on the film, inside the crop as it is dragged.
      if let frame = model.selected, let region = frame.adjustments.analysisRegion, let context = model.canvasRegion {
        let shown = ImageGeometry.transform(region.mapped(into: frame.rect).relative(to: context), settings: frame.adjustments).cg
          .intersection(draft ?? crop.cg)
        if !shown.isNull {
          let box = NSBezierPath(rect: screen(shown))
          box.lineWidth = 1.5
          box.setLineDash([6, 4], count: 2, phase: 0)
          Self.colour(.region).setStroke()
          box.stroke()
        }
      }
      if let line = levelLine {
        let amber = NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1)
        let path = NSBezierPath()
        path.move(to: line.from)
        path.line(to: line.to)
        NSColor.black.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 4
        path.stroke()
        amber.setStroke()
        path.lineWidth = 2
        path.stroke()
        amber.setFill()
        for end in [line.from, line.to] { NSBezierPath(ovalIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)).fill() }
        let a = atan2(Double(line.to.y - line.from.y), Double(line.to.x - line.from.x)) * 180 / .pi
        (String(format: "拉直 %+.1f°", -(a - 90 * (a / 90).rounded())) as NSString).draw(
          at: CGPoint(x: line.to.x + 10, y: line.to.y + 6),
          withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: amber])
      }
      if let kept {
        if model.tool == .crop { drawGrid(in: kept, fine: model.straightening) }
        NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1).setStroke()
        let edge = NSBezierPath()
        edge.appendPolygon(kept)
        edge.lineWidth = 2
        edge.stroke()
      }
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
    if !model.singleView && model.scanner.previewSoFar == nil {
      // A new roll's frames come in one after another, each box settling onto its frame.
      noteFrames()
      let movingSelection = glidingSelectionRect()
      for (n, f) in model.contactFrames.enumerated() {
        let appear = rippleShare(n)
        let r = screen(model.contactRect(f).cg).insetBy(dx: -(1 - appear) * 10, dy: -(1 - appear) * 10)
        // Moving to it by ← →, the selection's outline is on its way there (drawn below).
        let selected = f.id == model.selectedID && movingSelection == nil
        // Those chosen with it (⌘ / ⇧) in its colour, fainter.
        let chosen = !selected && model.alsoSelected.contains(f.id)
        let solid =
          selected
          ? NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1)
          : chosen ? NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 0.6)
          : NSColor.white.withAlphaComponent(f.enabled ? 0.85 : 0.3)
        let c = solid.withAlphaComponent(solid.alphaComponent * appear)
        c.setStroke()
        let path = NSBezierPath(rect: r)
        path.lineWidth = selected || chosen ? 2 : f.enabled ? 1.5 : 1
        if !f.enabled { path.setLineDash([4, 4], count: 2, phase: 0) }
        path.stroke()
        // Straightened, the part kept, turned on the film as it lies.
        if !sheet, let degrees = f.adjustments.angle, abs(degrees) > 0.0001, let aspect = model.frameAspect(f) {
          let box = f.rect.cg, b = imageRect
          let kept = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { corner -> CGPoint in
            let q = ImageGeometry.straightened(corner, degrees: degrees, aspect: aspect, inverse: true)
            let s = turn.shown(CGPoint(x: box.minX + q.x * box.width, y: box.minY + q.y * box.height))
            return CGPoint(x: b.minX + s.x * b.width, y: b.minY + s.y * b.height)
          }
          let outline = NSBezierPath()
          outline.appendPolygon(kept)
          outline.lineWidth = 1
          outline.setLineDash([3, 3], count: 2, phase: 0)
          c.withAlphaComponent(0.8).setStroke()
          outline.stroke()
        }
        let label = NSRect(x: r.minX, y: r.minY - 20, width: 30, height: 19)
        c.setFill()
        NSBezierPath(roundedRect: label, xRadius: 3, yRadius: 3).fill()
        (f.name as NSString).draw(
          at: CGPoint(x: label.minX + 6, y: label.minY + 2),
          withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.black.withAlphaComponent(appear),
          ])
      }
      if let moving = movingSelection {
        NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1).setStroke()
        let path = NSBezierPath(rect: screen(moving))
        path.lineWidth = 2
        path.stroke()
      }
      if let draft {
        NSColor.systemOrange.setStroke()
        let p = NSBezierPath(rect: screen(draft))
        p.lineWidth = 1.5
        p.stroke()
      }
    }
    if model.singleView, model.tool == .it8, let frame = model.selected {
      drawIT8(model.it8Marks, settings: frame.adjustments, aspect: model.shownAspect(frame))
    }
    // Where the film base was read: picked by hand, or at the frame's edges; asked for, or while a
    // base is being picked.
    if model.singleView, let frame = model.selected, model.tool == .base || model.showBaseAreas {
      let s = frame.adjustments
      let own = model.frames.firstIndex { $0.id == frame.id }.map { model.edgeBaseSource($0) == $0 } ?? false
      if let found = frame.edgeBase, found.base != nil, model.tool == .base || own && s.base == nil && s.rollBasePicked != true {
        drawBaseAreas(found.areas, frame: frame, aspect: model.shownAspect(frame))
      }
      if s.base != nil, let picked = s.basePicked {
        drawBasePick(picked, settings: s, aspect: model.shownAspect(frame))
      }
    }
    // The de-masking region, cyan, over the picture as cropped; also where it follows the picture
    // inside the film's edge, which the crop takes in.
    if model.singleView, !model.editingSingle, !model.showsOriginal, let frame = model.selected,
      frame.adjustments.analysisRegion != nil || model.tool == .region || model.toneAnalysis?.followed != nil
    {
      drawAnalysisRegion(frame)
    }
    // The automatic base marked for a moment as an uncropped picture comes up, unless shown already.
    if model.singleView, let frame = model.selected, let flash = model.baseFlash, flash.id == frame.id,
      model.tool != .base, !model.showBaseAreas, let found = frame.edgeBase, found.base != nil
    {
      let opacity = BaseFlash.opacity(CACurrentMediaTime() - flash.start)
      if opacity > 0 { drawBaseAreas(found.areas, frame: frame, aspect: model.shownAspect(frame), opacity: opacity) }
      animateBaseFlash()
    }
    // The neutral points picked for a calibration on this frame, or those of the preset in use.
    if model.singleView, let frame = model.selected {
      let marks = model.neutralMarks(on: frame)
      if !marks.isEmpty { drawNeutralMarks(marks, frame: frame, aspect: model.shownAspect(frame)) }
    }
    // The frame's dust, while it is shown or being marked.
    if model.singleView, let frame = model.selected, let dust = frame.dust, !dust.spots.isEmpty,
      model.showDust || model.tool == .dust
    {
      drawDust(dust, frame: frame, aspect: model.shownAspect(frame))
    }
    drawLens()
  }
  /// Puts the glass bubble on the corner under `p`, as it is dragged.
  func showLens(at p: CGPoint) {
    let n = shownNormal(p)
    if lens == nil {
      lensFading = nil
      lens = (n, CACurrentMediaTime())
      animateLens()
    } else {
      lens?.point = n
    }
  }
  /// Lets the bubble go: it shrinks and fades where it was.
  func releaseLens() {
    if lens != nil, let drawn = lensDrawn {
      lensFading = (drawn.image, drawn.frame, CACurrentMediaTime())
      animateLens()
    }
    lens = nil
    lensDrawn = nil
  }
  /// Redraws while the base's marks fade out; through the three seconds they hold, nothing moves.
  private func animateBaseFlash() {
    guard baseFlashTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] t in
      guard let self else { return t.invalidate() }
      let elapsed = self.model?.baseFlash.map { CACurrentMediaTime() - $0.start } ?? .infinity
      if elapsed >= BaseFlash.hold { self.needsDisplay = true }
      if elapsed >= BaseFlash.hold + BaseFlash.fade {
        t.invalidate()
        self.baseFlashTimer = nil
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    baseFlashTimer = timer
  }
  /// Redraws while the bubble swells in or fades out; dragging redraws it otherwise.
  private func animateLens() {
    guard lensTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
      guard let self else { return t.invalidate() }
      let now = CACurrentMediaTime()
      let swelling = self.lens.map { now - $0.since < 0.25 } ?? false
      let fading = self.lensFading.map { now - $0.since < 0.2 } ?? false
      if !swelling && !fading {
        self.lensFading = nil
        t.invalidate()
        self.lensTimer = nil
      }
      self.needsDisplay = true
    }
    RunLoop.main.add(timer, forMode: .common)
    lensTimer = timer
  }
  /// The bubble over the dragged corner: the picture about it four times larger, the crop (or the
  /// frame box) outlined in it, and in single view the outside of the crop darkened as here.
  private func drawLens() {
    let now = CACurrentMediaTime()
    if let lens, let cg = shown, let model {
      let r = imageRect
      let backing = window?.backingScaleFactor ?? 2
      let pixels = Int(CropLens.diameter * backing)
      let center = CGPoint(x: lens.point.x * CGFloat(cg.width), y: lens.point.y * CGFloat(cg.height))
      let scale = CropLens.magnification * r.width / CGFloat(max(1, cg.width)) * backing
      let crop = draft.map { d -> CGRect in
        let s = turn.shown(d)
        return CGRect(
          x: s.minX * CGFloat(cg.width), y: s.minY * CGFloat(cg.height), width: s.width * CGFloat(cg.width),
          height: s.height * CGFloat(cg.height))
      } ?? regionDraft.map { d -> CGRect in
        // The de-masking region being dragged, from the picture's coordinates to the picture shown.
        let c = pictureCorners(d).map { CGPoint(x: ($0.x - r.minX) / max(1, r.width) * CGFloat(cg.width), y: ($0.y - r.minY) / max(1, r.height) * CGFloat(cg.height)) }
        let xs = c.map(\.x), ys = c.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
      }
      let dim = model.singleView ? (model.tool == .base ? 0.18 : 0.5) : 0
      let at = CGPoint(x: r.minX + lens.point.x * r.width, y: r.minY + lens.point.y * r.height)
      let frame = CropLens.frame(for: at, in: bounds.intersection(openRect).insetBy(dx: 8, dy: 8), flipped: isFlipped)
      let key = "\(ObjectIdentifier(cg)) \(center) \(scale) \(crop.map { "\($0)" } ?? "") \(dim) \(pixels)"
      if lensDrawn?.key != key,
        let image = CropLens.render(cg, center: center, scale: scale, crop: crop, dimOutside: dim, pixels: pixels)
      {
        lensDrawn = (key, image, frame)
      }
      lensDrawn?.frame = frame
      if let drawn = lensDrawn { paintLens(drawn.image, in: frame, CropLens.appearance(shownFor: now - lens.since, released: nil)) }
    } else if let fading = lensFading {
      let look = CropLens.appearance(shownFor: 1, released: now - fading.since)
      if look.opacity > 0 { paintLens(fading.image, in: fading.frame, look) }
    }
  }
  /// The single frame's black plate and its drop shadow, made once and stretched to the picture's
  /// size: away from the corners the shadow is the same all along an edge. Blurred afresh at every
  /// draw it was a good part of the main thread's time for each picture shown; made once for each
  /// size, every step of a zoom blurred a new plate as large as the picture, a gigabyte at 8×.
  static let plateMargin: CGFloat = 48
  /// How far along an edge from the picture's corner its shadow still changes.
  static let plateCorner: CGFloat = 40
  /// The plate about a small square, for the screen's scale, in nine parts, by rows from the top:
  /// the corners drawn as they are, the parts between them stretched.
  private(set) var shadowPlate: (scale: CGFloat, parts: [NSImage])?
  private func plateParts(scale: CGFloat) -> [NSImage]? {
    if let kept = shadowPlate, kept.scale == scale { return kept.parts }
    let m = Self.plateMargin, cap = m + Self.plateCorner, side = 2 * cap + 2
    let pixels = Int((side * scale).rounded()), capPixels = Int((cap * scale).rounded())
    guard pixels > 2 * capPixels,
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    // In points, before the context is made from it.
    rep.size = CGSize(width: side, height: side)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    // Drawn the way up the canvas draws, so the shadow falls as it does there.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    context.cgContext.translateBy(x: 0, y: side)
    context.cgContext.scaleBy(x: 1, y: -1)
    Self.paintPlate(CGRect(x: m, y: m, width: side - 2 * m, height: side - 2 * m))
    NSGraphicsContext.restoreGraphicsState()
    guard let whole = rep.cgImage else { return nil }
    let cuts = [0, capPixels, pixels - capPixels, pixels]
    var parts = [NSImage]()
    for row in 0..<3 {
      for column in 0..<3 {
        let r = CGRect(x: cuts[column], y: cuts[row], width: cuts[column + 1] - cuts[column], height: cuts[row + 1] - cuts[row])
        guard let part = whole.cropping(to: r) else { return nil }
        parts.append(NSImage(cgImage: part, size: CGSize(width: r.width / scale, height: r.height / scale)))
      }
    }
    shadowPlate = (scale, parts)
    return parts
  }
  /// The plate and its shadow as they are drawn about `rect`.
  private static func paintPlate(_ rect: CGRect) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = CGSize(width: 0, height: 5)
    shadow.set()
    NSColor.black.setFill()
    rect.insetBy(dx: -1, dy: -1).fill()
    NSGraphicsContext.restoreGraphicsState()
  }
  /// The plate and its shadow under a picture filling `rect`, at the drawing's own scale.
  func drawShadowPlate(around rect: CGRect) {
    let m = Self.plateMargin, cap = m + Self.plateCorner
    let device = NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform ?? .identity
    let scale = max(1, (hypot(device.a, device.b) * 4).rounded() / 4)
    // Too small to stretch the plate to, it is cheap to blur as it is.
    guard rect.width >= 2 * Self.plateCorner + 2, rect.height >= 2 * Self.plateCorner + 2, let parts = plateParts(scale: scale) else {
      return Self.paintPlate(rect)
    }
    let xs = [rect.minX - m, rect.minX - m + cap, rect.maxX + m - cap, rect.maxX + m]
    let ys = [rect.minY - m, rect.minY - m + cap, rect.maxY + m - cap, rect.maxY + m]
    for row in 0..<3 {
      for column in 0..<3 {
        let r = CGRect(x: xs[column], y: ys[row], width: xs[column + 1] - xs[column], height: ys[row + 1] - ys[row])
        if row == 1 && column == 1 {
          // The middle is the plate's black, under the picture.
          NSColor.black.setFill()
          r.fill()
        } else {
          parts[row * 3 + column].draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
      }
    }
  }
  private func paintLens(_ image: CGImage, in frame: CGRect, _ look: (scale: CGFloat, opacity: CGFloat)) {
    let size = CGSize(width: frame.width * look.scale, height: frame.height * look.scale)
    let r = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5 * look.opacity)
    shadow.shadowBlurRadius = 16
    // Shadow offsets are in unflipped coordinates: down is negative.
    shadow.shadowOffset = CGSize(width: 0, height: -6)
    shadow.set()
    NSImage(cgImage: image, size: r.size).draw(
      in: r, from: .zero, operation: .sourceOver, fraction: look.opacity, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
  }
  /// Lines across the quadrilateral `corners` (clockwise from its top left): thirds, and while it
  /// is being straightened a finer grid of about 40 points to line a horizon or an edge up with.
  private func drawGrid(in corners: [CGPoint], fine: Bool = true) {
    guard corners.count == 4 else { return }
    func at(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
      let top = CGPoint(x: corners[0].x + (corners[1].x - corners[0].x) * u, y: corners[0].y + (corners[1].y - corners[0].y) * u)
      let bottom = CGPoint(x: corners[3].x + (corners[2].x - corners[3].x) * u, y: corners[3].y + (corners[2].y - corners[3].y) * u)
      return CGPoint(x: top.x + (bottom.x - top.x) * v, y: top.y + (bottom.y - top.y) * v)
    }
    let width = hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y)
    let height = hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y)
    func lines(_ across: Int, _ down: Int, _ colour: NSColor, _ lineWidth: CGFloat) {
      let path = NSBezierPath()
      for i in 1..<max(1, across) {
        path.move(to: at(CGFloat(i) / CGFloat(across), 0))
        path.line(to: at(CGFloat(i) / CGFloat(across), 1))
      }
      for j in 1..<max(1, down) {
        path.move(to: at(0, CGFloat(j) / CGFloat(down)))
        path.line(to: at(1, CGFloat(j) / CGFloat(down)))
      }
      // Dark under light, so the lines show on a sky and on shadows alike.
      NSColor.black.withAlphaComponent(0.35).setStroke()
      path.lineWidth = lineWidth + 1
      path.stroke()
      colour.setStroke()
      path.lineWidth = lineWidth
      path.stroke()
    }
    if fine {
      lines(max(3, Int((width / 40).rounded())), max(3, Int((height / 40).rounded())), NSColor.white.withAlphaComponent(0.28), 0.5)
    }
    lines(3, 3, NSColor.white.withAlphaComponent(0.7), 0.75)
  }
  /// The IT8 target's marked points, and once four are set, where every patch will be read.
  /// Where the base was picked by hand: a ring about the square read, in the frame as cropped.
  private func drawBasePick(_ place: NormalRect, settings: Adjustments, aspect: Double?) {
    let r = imageRect
    let d = ImageGeometry.display(CGPoint(x: place.x + place.width / 2, y: place.y + place.height / 2), settings: settings, aspect: aspect)
    let c = CGPoint(x: r.minX + d.x * r.width, y: r.minY + d.y * r.height)
    let radius = max(6, place.width * r.width / 2 + 3)
    let amber = NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1)
    let ring = NSBezierPath(ovalIn: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
    ring.lineWidth = 2
    NSColor.black.withAlphaComponent(0.5).setStroke()
    ring.stroke()
    ring.lineWidth = 1.2
    amber.setStroke()
    ring.stroke()
    let text = "手动片基" as NSString
    let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    let size = text.size(withAttributes: [.font: font])
    let label = NSRect(x: min(c.x + radius + 4, r.maxX - size.width - 14), y: max(r.minY + 2, c.y - size.height / 2 - 3), width: size.width + 12, height: size.height + 6)
    amber.setFill()
    NSBezierPath(roundedRect: label, xRadius: 4, yRadius: 4).fill()
    text.draw(at: CGPoint(x: label.minX + 6, y: label.minY + 3), withAttributes: [.font: font, .foregroundColor: NSColor.black])
  }
  /// Neutral points at their spots in the frame's source, through its crop, turn and mirror: a
  /// white ring each, and its number as listed.
  private func drawNeutralMarks(_ marks: [(number: Int, at: CGPoint)], frame: FilmFrame, aspect: Double?) {
    let r = imageRect, crop = frame.rect
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: r).addClip()
    let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    for mark in marks {
      let q = CGPoint(x: (mark.at.x - crop.x) / max(1e-6, crop.width), y: (mark.at.y - crop.y) / max(1e-6, crop.height))
      guard (0...1).contains(q.x), (0...1).contains(q.y) else { continue }
      let d = ImageGeometry.display(q, settings: frame.adjustments, aspect: aspect)
      let c = CGPoint(x: r.minX + d.x * r.width, y: r.minY + d.y * r.height)
      let ring = NSBezierPath(ovalIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
      ring.lineWidth = 3
      NSColor.black.withAlphaComponent(0.55).setStroke()
      ring.stroke()
      ring.lineWidth = 1.5
      NSColor.white.setStroke()
      ring.stroke()
      let text = "中性 \(mark.number)" as NSString
      let size = text.size(withAttributes: [.font: font])
      let label = NSRect(x: min(c.x + 11, r.maxX - size.width - 10), y: max(r.minY + 2, c.y - size.height / 2 - 2), width: size.width + 10, height: size.height + 4)
      NSColor.white.withAlphaComponent(0.9).setFill()
      NSBezierPath(roundedRect: label, xRadius: 4, yRadius: 4).fill()
      text.draw(at: CGPoint(x: label.minX + 5, y: label.minY + 2), withAttributes: [.font: font, .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
  }
  /// A ring round each spot of dust, through the frame's crop, turn and mirror: solid where it is
  /// filled, dotted where it is kept, or all dotted while the frame's dust is left in.
  private func drawDust(_ dust: DustState, frame: FilmFrame, aspect: Double?) {
    let r = imageRect, crop = frame.rect
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: r).addClip()
    for spot in dust.spots {
      let b = spot.box
      let corners = [(b.x, b.y), (b.x + b.width, b.y), (b.x, b.y + b.height), (b.x + b.width, b.y + b.height)].map { x, y in
        let q = CGPoint(x: (x - crop.x) / max(1e-6, crop.width), y: (y - crop.y) / max(1e-6, crop.height))
        let d = ImageGeometry.display(q, settings: frame.adjustments, aspect: aspect)
        return CGPoint(x: r.minX + d.x * r.width, y: r.minY + d.y * r.height)
      }
      let xs = corners.map(\.x), ys = corners.map(\.y)
      guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
        maxX >= r.minX, minX <= r.maxX, maxY >= r.minY, minY <= r.maxY
      else { continue }
      let c = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
      let radius = max(6, max(maxX - minX, maxY - minY) / 2 + 4)
      let ring = NSBezierPath(ovalIn: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
      let filled = dust.on && spot.filled
      ring.lineWidth = 3
      NSColor.black.withAlphaComponent(0.5).setStroke()
      ring.stroke()
      ring.lineWidth = 1.5
      if !filled { ring.setLineDash([3, 3], count: 2, phase: 0) }
      (filled ? NSColor.systemGreen : NSColor.white).setStroke()
      ring.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
  }
  /// The cells of the frame's edges read as its film base, filled over the picture through its
  /// crop, turn and mirror, with a note at the largest.
  private func drawBaseAreas(_ areas: [NormalRect], frame: FilmFrame, aspect: Double?, opacity: Double = 1) {
    guard !areas.isEmpty else { return }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(opacity))
    let r = imageRect, crop = frame.rect
    func onScreen(_ p: CGPoint) -> CGPoint {
      let q = CGPoint(x: (p.x - crop.x) / max(1e-6, crop.width), y: (p.y - crop.y) / max(1e-6, crop.height))
      let d = ImageGeometry.display(q, settings: frame.adjustments, aspect: aspect)
      return CGPoint(x: r.minX + d.x * r.width, y: r.minY + d.y * r.height)
    }
    let amber = NSColor(calibratedRed: 0.95, green: 0.71, blue: 0.38, alpha: 1)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: r).addClip()
    let cells = NSBezierPath()
    for a in areas {
      cells.appendPolygon([
        CGPoint(x: a.x, y: a.y), CGPoint(x: a.x + a.width, y: a.y),
        CGPoint(x: a.x + a.width, y: a.y + a.height), CGPoint(x: a.x, y: a.y + a.height),
      ].map(onScreen))
    }
    amber.withAlphaComponent(0.45).setFill()
    cells.fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let largest = areas.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return }
    let at = onScreen(CGPoint(x: largest.x + largest.width / 2, y: largest.y + largest.height / 2))
    let text = "片基取样" as NSString
    let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    let size = text.size(withAttributes: [.font: font])
    let label = NSRect(
      x: min(max(r.minX + 4, at.x - size.width / 2 - 6), r.maxX - size.width - 16),
      y: min(max(r.minY + 4, at.y - size.height / 2 - 3), r.maxY - size.height - 10),
      width: size.width + 12, height: size.height + 6)
    amber.setFill()
    NSBezierPath(roundedRect: label, xRadius: 4, yRadius: 4).fill()
    text.draw(at: CGPoint(x: label.minX + 6, y: label.minY + 3), withAttributes: [.font: font, .foregroundColor: NSColor.black])
  }
  private func drawIT8(_ marks: [CGPoint], settings: Adjustments, aspect: Double?) {
    let r = imageRect
    func onScreen(_ raw: CGPoint) -> CGPoint {
      let d = ImageGeometry.display(raw, settings: settings, aspect: aspect)
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
  /// A right click on a frame in ②: export it, or the frames chosen together when it is one of them.
  override func menu(for event: NSEvent) -> NSMenu? {
    guard let model, model.page == .convert, model.scanner.previewSoFar == nil else { return super.menu(for: event) }
    let p = convert(event.locationInWindow, from: nil)
    let frame = model.singleView
      ? (imageRect.contains(p) ? model.selected : nil)
      : model.contactFrames.reversed().first(where: { model.contactRect($0).cg.contains(normal(p)) })
    guard let frame else { return super.menu(for: event) }
    let menu = NSMenu()
    menu.autoenablesItems = false
    let chosen = model.selection
    if chosen.count > 1, chosen.contains(where: { $0.id == frame.id }) {
      menu.addItem(ActionMenuItem("导出所选的 \(chosen.count) 张…", symbol: "square.and.arrow.up.on.square", enabled: !model.isWorking) { [weak model] in
        guard let model else { return }
        model.exportImages(model.selection)
      })
    } else {
      menu.addItem(ActionMenuItem("导出这张…", symbol: "square.and.arrow.up", enabled: !model.isWorking) { [weak model] in
        guard let model, let now = model.frames.first(where: { $0.id == frame.id }) else { return }
        model.exportImages([now])
      })
    }
    return menu
  }
  override func mouseMoved(with event: NSEvent) {
    hover = convert(event.locationInWindow, from: nil)
    updateCropCursor(at: hover)
    readPointer()
  }
  override func mouseExited(with event: NSEvent) {
    hover = nil
    updateCropCursor(at: nil)
    readPointer()
  }
  /// The picture moved under a pointer that stayed (zoomed, scrolled): what lies under it is read.
  private func pointerMoved(_ event: NSEvent) {
    guard hover != nil else { return }
    hover = convert(event.locationInWindow, from: nil)
    readPointer()
  }

  // MARK: The pointer on the curves

  /// Where the curves' mark was last read, in the shown picture's normalised coordinates, and the
  /// picture it was read from: a new picture is read again at the same place.
  private var pointerRead: (point: CGPoint, image: CGImage)?
  /// The curves' inverse, while they stay the same.
  private var pointerInverse: (curves: ToneCurves?, inverse: CurveInverse?)?
  /// The curves mark the colour under the pointer over the single frame's positive (`CurveState`),
  /// as it was before them. Off the picture the mark stays, dimmed.
  func readPointer() {
    guard let model else { return }
    guard model.singleView, !model.showsNegative, model.tool != .base, !model.showsOriginal, model.scanner.previewSoFar == nil,
      let cg = shown, let p = hover, imageRect.contains(p)
    else {
      if model.curveState.reading?.over == true { model.curveState.reading?.over = false }
      return
    }
    readPointer(at: shownNormal(p), in: cg, over: true)
  }
  private func readPointer(at point: CGPoint, in cg: CGImage, over: Bool) {
    guard let model, let colour = Self.colour(in: cg, at: point) else { return }
    let curves = model.shownCurves
    if pointerInverse == nil || pointerInverse?.curves != curves { pointerInverse = (curves, CurveInverse(curves)) }
    let input = pointerInverse?.inverse?.input(colour) ?? colour
    pointerRead = (point, cg)
    let reading = CurveState.Reading(input: input, over: over)
    if model.curveState.reading != reading { model.curveState.reading = reading }
  }
  /// A new picture of the frame: the mark is read again where it was, so it follows what the
  /// adjustments do there (the curves alone leave what lies before them as it was). Another crop,
  /// turn or view leaves no such place, and the mark goes.
  private func pictureUnderPointer() {
    guard let model, let cg = shown, cg !== pointerRead?.image else { return }
    if let p = hover, imageRect.contains(p) {
      readPointer()
      return
    }
    guard let read = pointerRead else { return }
    pointerRead = nil
    guard let reading = model.curveState.reading else { return }
    guard model.singleView, !model.showsNegative, model.tool != .base, !model.showsOriginal,
      cg.width == read.image.width, cg.height == read.image.height
    else {
      model.curveState.reading = nil
      return
    }
    readPointer(at: read.point, in: cg, over: reading.over)
  }
  /// The targeted adjustment held on the picture: the tone it works at on the curve taken, the
  /// curves as the press found them, where it began, and whether the curves have moved yet.
  private var curveTarget: (x: Double, start: ToneCurves, from: CGFloat, channel: Int, parametric: Bool, moved: Bool)?
  /// A press with the targeted adjustment: what lies under it before the curves, and where that
  /// lies on the curve taken.
  func beginCurveTarget(at p: CGPoint) {
    guard let model, !model.showsNegative, !model.showsOriginal, let cg = shown, let colour = Self.colour(in: cg, at: shownNormal(p)) else { return }
    let curves = model.shownCurves
    if pointerInverse == nil || pointerInverse?.curves != curves { pointerInverse = (curves, CurveInverse(curves)) }
    let input = pointerInverse?.inverse?.input(colour) ?? colour
    let start = model.settings.curves ?? ToneCurves()
    let state = model.curveState
    curveTarget = (start.target(input, channel: state.channel, parametric: state.parametric), start, p.y, state.channel, state.parametric, false)
  }
  /// Up lightens that part of the curve, down darkens it: the plot's full height for 300 points of
  /// drag, the parametric zone's whole range for 150. One undo step for the drag.
  func dragCurveTarget(to p: CGPoint) {
    guard let model, var t = curveTarget else { return }
    let next = t.start.targeted(at: t.x, channel: t.channel, parametric: t.parametric, by: Double(t.from - p.y) / 300)
    model.change("曲线目标调整", separate: !t.moved) { $0.curves = next.normalized }
    t.moved = true
    curveTarget = t
  }
  /// A picture's colour about a point (normalised, top left at 0) as it shows, in its own encoding,
  /// which is the curves' axis: a few of its pixels each way averaged, so grain does not make the
  /// reading flicker.
  static func colour(in image: CGImage, at point: CGPoint, radius: Int = 2) -> RGB? {
    let x = min(image.width - 1, max(0, Int(point.x * CGFloat(image.width))))
    let y = min(image.height - 1, max(0, Int(point.y * CGFloat(image.height))))
    let rect = CGRect(x: x - radius, y: y - radius, width: 2 * radius + 1, height: 2 * radius + 1)
      .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard !rect.isNull, rect.width >= 1, rect.height >= 1, let part = image.cropping(to: rect) else { return nil }
    let w = Int(rect.width), h = Int(rect.height)
    let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? ImagePipeline.shared.outputSpace
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = px.withUnsafeMutableBytes { raw -> Bool in
      guard let ctx = CGContext(
        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      ctx.interpolationQuality = .none
      ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return nil }
    var sum = [0.0, 0.0, 0.0]
    for i in stride(from: 0, to: px.count, by: 4) {
      for c in 0..<3 { sum[c] += Double(px[i + c]) }
    }
    return RGB(sum.map { $0 / Double(w * h) / 255 })
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
  /// How many points a millimetre of film takes on the light table; nil over the single frame.
  /// Points a millimetre of film takes on the canvas: on the light table from the bed's size; over
  /// the single frame from the frame's own, as it is shown (turned, and zoomed).
  var loupePointsPerMM: CGFloat? {
    guard let model, let cg = shown else { return nil }
    if model.singleView {
      guard let frame = model.selected, let mm = model.frameMM(frame), mm.width > 0, mm.height > 0 else { return nil }
      let across = frame.adjustments.rotation % 2 == 0 ? mm.width : mm.height
      return imageRect.width / across
    }
    // A laid-out page prints every frame as large as a 3:2 cell holds: one narrower than 3:2 as
    // tall, one wider as wide. Without the roll's format that is a 135 frame's scale, a 3:2 one 36
    // mm across, whatever its file's own size; with it, a frame's own size on the film (a 6 × 6
    // its 56 mm), so the loupe takes in as much of it as the real one would.
    if model.onSheetPage, let first = model.contactFrames.first {
      // The page shown is the laid-out page, a pixel to a unit of its layout; a one-page roll's is
      // as wide as its own frames, so it is measured, not laid out again as 3:2 cells.
      let points = imageRect.width / CGFloat(max(1, cg.width)), cell = AppModel.sheetCell
      if model.formatDPI(first) != nil, let mm = model.frameMM(first), mm.width > 0, mm.height > 0 {
        let positive = !model.showsNegative
        let turned = positive && ((first.adjustments.rotation % 4) + 4) % 2 == 1
        let (across, tall) = turned ? (mm.height, mm.width) : (mm.width, mm.height)
        return points * (across / tall >= cell.width / cell.height ? cell.width / across : cell.height / tall)
      }
      return points * cell.width / 36
    }
    guard model.physicalMM.height > 0 else { return nil }
    let shownHeight = turn.sideways ? model.physicalMM.width : model.physicalMM.height
    return fitScale * CGFloat(cg.height) / max(1, shownHeight)
  }
  /// The loupe lies to the film's scale: on the light table, and over the single frame too, where
  /// it grows with the frame as it is shown, the same loupe on the same film seen closer; as large
  /// as the canvas holds at most.
  func loupeRadius(for style: LoupeStyle) -> CGFloat {
    guard let model, shown != nil else { return 70 }
    let side = min(bounds.width, bounds.height)
    if model.singleView {
      guard let perMM = loupePointsPerMM else { return min(130, max(70, side * 0.14)) * CGFloat(style.baseMM / 48) }
      return singleLoupeRadius(style, perMM: perMM)
    }
    guard let perMM = loupePointsPerMM else { return 70 }
    return min(110, max(44, CGFloat(style.baseMM / 2) * perMM))
  }
  private func singleLoupeRadius(_ style: LoupeStyle, perMM: CGFloat) -> CGFloat {
    min(min(bounds.width, bounds.height) * 0.45, max(44, CGFloat(style.baseMM / 2) * perMM))
  }
  /// The single frame as it fits the canvas, not zoomed or moved: what the loupe over it is
  /// measured against, so that zooming the view leaves the loupe's field on the film as it was.
  var fitImageRect: CGRect {
    guard let cg = shown else { return .zero }
    let size = CGSize(width: CGFloat(cg.width) * fitScale, height: CGFloat(cg.height) * fitScale)
    return CGRect(
      x: reserved.left + (open.width - size.width) / 2, y: reserved.top + (open.height - size.height) / 2,
      width: size.width, height: size.height)
  }
  /// Over the single frame: as the frame fits the canvas, no more than its pixels can show, half
  /// again past one to a point, and never under 2×; zoomed, that over how much larger the film under
  /// the lens is shown, so the lens takes in the same part of the frame however the view is zoomed,
  /// as a loupe does on the film (it grew with the zoom: 0.19.0 and before). Nil on the light table,
  /// where the loupe's field decides it.
  func loupeMagnification(for style: LoupeStyle) -> Double? {
    guard let model, model.singleView else { return nil }
    let fit = fitImageRect.width, now = imageRect.width
    guard fit > 0, now > 0 else { return nil }
    // The frame's own pixels under the lens once they are here, else the picture shown, to a point
    // of the frame as it fits.
    let perPoint: Double
    if let region = loupeRegion, region.key == model.selected.map({ model.loupeDetailKey($0, single: true) }) {
      perPoint = Double(region.image.width) / max(1, region.region.width * Double(fit))
    } else {
      perPoint = Double(shown?.width ?? 0) / Double(fit)
    }
    let atFit = min(style.magnification, max(2, perPoint * 1.5))
    // Lying on the film at its scale, the loupe is drawn larger as the film is (as far as the
    // canvas holds), its lens with it; looked into, its lens keeps its size on the canvas.
    var grown = 1.0
    if loupe.field == .actual, let perMM = loupePointsPerMM, perMM > 0 {
      grown = Double(singleLoupeRadius(style, perMM: perMM) / max(1, singleLoupeRadius(style, perMM: perMM * fit / now)))
    }
    return atFit * grown / Double(now / fit)
  }
  /// The frame the loupe was put on: it stays there as the canvas changes, until it is shown
  /// again, the view changes or it is put back on the selected frame.
  var loupeHomeFrame: UUID?
  /// Where the loupe first lies: the middle of its frame on the table, or of the picture.
  var loupeHome: CGPoint {
    let r = imageRect
    var c = CGPoint(x: r.midX, y: r.midY)
    if let model, !model.singleView,
      let f = model.contactFrames.first(where: { $0.id == (loupeHomeFrame ?? model.selectedID) })
        ?? model.contactFrames.first(where: { $0.id == model.selectedID })
    {
      let s = screen(model.contactRect(f).cg)
      c = CGPoint(x: s.midX, y: s.midY)
    }
    return CGPoint(x: min(max(c.x, bounds.minX), bounds.maxX), y: min(max(c.y, bounds.minY), bounds.maxY))
  }
  private var loupeView: Bool?
  private var loupeShown = CGSize.zero
  private var loupeTurn: QuarterTurn?
  func updateLoupe() {
    guard let model else { return }
    let hidden = !model.preferences.showLoupe || shown == nil
    loupe.style = model.preferences.loupeStyle
    loupe.field = model.preferences.loupeField
    // A new view puts the loupe back on what it shows.
    if !hidden, loupeView != model.singleView {
      if loupeView != nil { storedLoupeCenter = nil }
      loupeView = model.singleView
      loupeHomeFrame = model.selectedID
      loupe.layoutOnTable()
    }
    // Set down or picked up by its key: in the window, lowered onto the table or lifted off it.
    let shownNow = !loupe.isHidden && loupe.leaving == nil, moves = window?.isVisible == true && !Self.stillMotion
    if shownNow == hidden {
      if !hidden {
        loupe.isHidden = false
        loupeHomeFrame = model.selectedID
        loupe.layoutOnTable()
        if moves && model.preferences.showLoupe { loupe.setDown() } else { loupe.stayDown() }
      } else {
        // Put away, it keeps no full-resolution picture.
        let putAway = { [weak self] in
          guard let self else { return }
          self.loupe.isHidden = true
          self.loupeDetail = nil
          self.loupeDetailRequest = nil
          self.loupeDetailStale = false
          self.loupeRegion = nil
          self.turnedLoupeDetail = nil
          LoupeRenderer.shared.release()
        }
        // Its key pressed, lifted off; gone with the picture under it, at once.
        if moves, !loupe.isHidden, shown != nil { loupe.pickUp(putAway) } else { putAway() }
      }
    }
    // The picture's size on screen sets the large field over the single frame, as it is zoomed,
    // and the film's scale on the table; a table turned to lie across, or back, puts the loupe
    // back on its frame.
    if !hidden, !model.singleView, loupeTurn != turn {
      if loupeTurn != nil {
        storedLoupeCenter = nil
        loupeHomeFrame = model.selectedID
      }
      loupeTurn = turn
      loupeShown = .zero
    }
    let shownSize = imageRect.size
    if !hidden, abs(shownSize.width - loupeShown.width) > 0.5 || abs(shownSize.height - loupeShown.height) > 0.5 {
      loupeShown = shownSize
      loupe.layoutOnTable()
    }
    if !hidden { loupeMoved() }
  }
  // MARK: Opening a frame

  /// A frame opened from the light table on its way to the middle: the table's picture, the view
  /// closing in on the frame, its own picture over it, until the frame's own is drawn.
  private(set) var opening: (cover: CALayer, picture: CALayer, over: CGImage?, grown: Bool)?
  /// Finishes an opening once the frame's own picture is here, or the table is back; plays any
  /// other change of view once its new picture is.
  func settleOpening() {
    settleChange()
    guard let model, let opening else { return }
    if !model.singleView || (opening.grown && model.displayed !== opening.over) { finishOpening() }
  }
  /// A change of view other than an opening, in flight.
  var change: ViewChangeInFlight?
  /// The single frame or the table's picture as last drawn: its frame, its look and its size.
  var drawnSingle: (id: UUID?, look: [Int], size: CGSize)?
  /// When one frame last slid in for another: frames flipped through quicker than that cross-fade.
  var lastPictureMove: CFTimeInterval = 0
  /// The frame whose film-strip picture slid in for it (`slideToInterim`): its own fades in over it.
  var interimShown: UUID?
  /// Another frame chosen in the single view, its own picture still being made: the film strip's
  /// picture of it, shown in its place meanwhile, so frames flipped through quickly show as they
  /// go by rather than the last one staying until a picture is made. Not over a negative or the
  /// raw picture, which the film strip does not have, nor while a change of view plays.
  func interimFace() -> CGImage? {
    guard let model, model.singleView, !model.showsNegative, !model.showsOriginal, !model.editingSingle, model.tool != .base,
      let id = model.selectedID, let shownID = model.shownFrameID, shownID != id,
      opening == nil, change == nil, turningBack == nil, let face = model.thumbnails[id], face.width > 0, face.height > 0
    else { return nil }
    return face
  }
  /// The film strip's picture slides in for the frame chosen, as the frame's own would.
  private func slideToInterim() {
    guard let model, let layer, let face = interimFace(), let id = model.selectedID, let last = drawnSingle, last.id != id
    else { return }
    defer {
      drawnSingle = (id, last.look, CGSize(width: face.width, height: face.height))
      interimShown = id
    }
    guard !snapshotting, let was = last.id ?? model.shownFrameID, let move = frameMove(from: was, to: id) else { return }
    layer.add(move, forKey: "picture")
  }
  /// The frames on the table as last drawn, and a new roll's coming in.
  var drawnFrameIDs: Set<UUID> = []
  var rippleStart: Date?
  var rippleCount = 0
  var rippleTimer: Timer?
  /// Opens a frame for the model: from where it lies on the table, or at once if it lies on none.
  func open(_ id: UUID) {
    guard let model else { return }
    if let f = model.contactFrames.first(where: { $0.id == id }) { return open(f) }
    model.select(id)
    model.singleView = true
    model.refresh()
  }
  /// Shows a frame on the light table on its own: the view closes in on it, the whole table
  /// growing about it on a spring, a little past and back, until it lies where the single view
  /// shows it and the frames round it have gone off the canvas; the table then fades to the
  /// single view's surround. Cross-faded, with Reduce Motion.
  func open(_ f: FilmFrame) {
    guard let model, !model.singleView else { return }
    model.select(f.id)
    guard !model.previewShowing else { return }
    // A new roll's frames come in on the table first, then the view closes in.
    if noteFrames() {
      DispatchQueue.main.asyncAfter(deadline: .now() + rippleDuration + 0.1) { [weak self] in self?.open(f.id) }
      return
    }
    // Caught drawing back to the table, it opens again from where the table and the frame are.
    let caught = caughtTable()
    finishChange()
    endTurningBack()
    defer {
      model.singleView = true
      model.refresh()
    }
    guard let layer, bounds.width > 0, let table = tableSnapshot() else { return }
    let cell = screen(model.contactRect(f).cg)
    // The positive the film strip has, where the table shows positives; else the table's own.
    let face = !model.showsNegative ? model.thumbnails[f.id] : nil
    var from = cell, image: CGImage?
    if let face, face.width > 0, face.height > 0 {
      image = face
      if model.onSheetPage { from = Self.fitted(CGSize(width: face.width, height: face.height), in: cell) }
    } else {
      let k = CGFloat(table.width) / bounds.width
      image = table.cropping(to: CGRect(x: cell.minX * k, y: cell.minY * k, width: cell.width * k, height: cell.height * k).integral)
    }
    let to = Self.fitted(from.size, in: fitArea)
    finishOpening()
    let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let cover = CALayer(), picture = CALayer()
    cover.frame = bounds
    cover.contents = table
    // The frame's own picture, sharper than the table's as it grows.
    picture.contents = image
    picture.contentsGravity = .resizeAspect
    picture.frame = to
    layer.addSublayer(cover)
    layer.addSublayer(picture)
    cover.opacity = 0
    CATransaction.commit()
    opening = (cover, picture, model.displayed, false)
    openedFrom = from

    // Grown once it is seen to have arrived: what is left of the spring is too small to see.
    DispatchQueue.main.asyncAfter(deadline: .now() + (still ? 0.2 : 0.55)) { [weak self] in
      guard let self, self.opening?.picture === picture else { return }
      self.opening?.grown = true
      self.settleOpening()
    }
    CATransaction.begin()
    // The table fades to the single view's surround once the frames round it are on their way
    // off the canvas.
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    fade.duration = still ? 0.2 : 0.3
    if !still {
      fade.beginTime = CACurrentMediaTime() + 0.2
      fade.fillMode = .backwards
    }
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
    cover.add(fade, forKey: "fade")
    if still {
      let appear = CABasicAnimation(keyPath: "opacity")
      appear.fromValue = 0
      appear.toValue = 1
      appear.duration = 0.2
      picture.add(appear, forKey: "appear")
    } else {
      // As the system springs a window or a photo open: half a second, a slight bounce. The
      // table, scaled about the frame as much as the frame grows, and the frame on the same
      // spring, so the frame stays where it lies on the table.
      Self.springZoom(cover, from: caught.map { ($0.scale, $0.position) } ?? (1, CGPoint(x: bounds.midX, y: bounds.midY)), to: zoomed(showing: from, at: to))
      Self.spring(picture, from: caught?.face ?? from)
    }
    CATransaction.commit()
    // Should the frame's picture never come, the single view shows what it has.
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      if self?.opening?.picture === picture { self?.finishOpening() }
    }
  }
  /// Where the frame opening began, on the table.
  private var openedFrom: CGRect?
  /// An opening turned back part way (`turnBackOpening`): the table and the frame on their way
  /// back, until they are there.
  private var turningBack: (table: CALayer, face: CALayer)?
  /// The table and the frame part way back to the table, a close playing or an opening turned
  /// back: the table's scale and place, as a layer the canvas's size, and the frame's place.
  func caughtTable() -> (scale: CGFloat, position: CGPoint, face: CGRect)? {
    var pair = turningBack
    if pair == nil, let c = change, case .close = c.kind, c.started, c.layers.count == 2 { pair = (c.layers[0], c.layers[1]) }
    guard let pair, let t = pair.table.presentation(), let f = pair.face.presentation() else { return nil }
    return ((t.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1, t.position, f.frame)
  }
  /// Back to the table while the frame is still opening: the opening turns back from where it is,
  /// the frame shrinking into its place on the table and the table coming back round it, rather
  /// than the close starting over from a single view not yet drawn.
  func turnBackOpening() -> Bool {
    guard let o = opening, let start = openedFrom, !Self.stillMotion, let t = o.cover.presentation(), let p = o.picture.presentation()
    else { return false }
    let scale = (t.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1, position = t.position, clear = t.opacity, face = p.frame
    opening = nil
    openedFrom = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for l in [o.cover, o.picture] { l.removeAllAnimations() }
    o.cover.opacity = 1
    o.picture.frame = start
    o.picture.opacity = 0
    CATransaction.commit()
    CATransaction.begin()
    Self.springZoom(o.cover, from: (scale, position), to: (1, CGPoint(x: bounds.midX, y: bounds.midY)))
    Self.spring(o.picture, from: face)
    o.cover.add(Self.fade(from: clear, to: 1, duration: 0.15), forKey: "fade")
    // The frame's picture gives way to its place on the table as it arrives there.
    o.picture.add(Self.fade(from: 1, to: 0, duration: 0.2, after: 0.25), forKey: "fade")
    CATransaction.commit()
    turningBack = (o.cover, o.picture)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
      if self?.turningBack?.table === o.cover { self?.endTurningBack() }
    }
    return true
  }
  func endTurningBack() {
    guard let done = turningBack else { return }
    turningBack = nil
    // The table's own marks again, with what is drawn under them.
    needsDisplay = true
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    done.table.removeFromSuperlayer()
    done.face.removeFromSuperlayer()
    CATransaction.commit()
  }
  /// The opened frame's own picture is drawn: what grew there fades into it.
  private func finishOpening() {
    guard let done = opening else { return }
    opening = nil
    openedFrom = nil
    needsDisplay = true
    CATransaction.begin()
    CATransaction.setCompletionBlock {
      done.cover.removeFromSuperlayer()
      done.picture.removeFromSuperlayer()
    }
    CATransaction.setAnimationDuration(0.15)
    done.picture.opacity = 0
    done.cover.opacity = 0
    CATransaction.commit()
  }
  /// Where the single view fits a picture: the canvas between its bars, less a margin.
  var fitArea: CGRect {
    let inset = Self.inset, room = open
    return CGRect(x: reserved.left + inset, y: reserved.top + inset, width: max(1, room.width - 2 * inset), height: max(1, room.height - 2 * inset))
  }
  /// A picture of `size` as large as fits in `box`, in its middle.
  static func fitted(_ size: CGSize, in box: CGRect) -> CGRect {
    let k = min(box.width / max(1, size.width), box.height / max(1, size.height))
    let w = size.width * k, h = size.height * k
    return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
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
    // A preview being read grows under the loupe as it comes.
    h.combine(model.scanner.previewSoFar.map(ObjectIdentifier.init))
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
      let r = model.contactRect(f)
      for v in [r.x, r.y, r.width, r.height] { h.combine(v) }
    }
    h.combine(model.contactPage)
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
  func tableSnapshot(keptWhileZooming: Bool = false) -> CGImage? {
    if keptWhileZooming, zooming, let kept = snapshot { return kept.image }
    let key = tableKey
    if snapshot?.key != key, bounds.width >= 1, bounds.height >= 1,
      let rep = bitmapImageRepForCachingDisplay(in: bounds)
    {
      snapshotting = true
      loupe.drawingSuppressed = true
      scanHead.drawingSuppressed = true
      // Not what a change of view lays over the canvas meanwhile: the canvas as it draws itself.
      // Nor its picture's layers: the picture is drawn into the snapshot as it is now, and the
      // window server's copy can still hold the last one placed, as on the way back to the table
      // the single frame, large, until the canvas next draws (0.19.0: it stood over the table as it
      // drew back). The system does draw a view's sublayers into a picture taken of it.
      let over = [pictureLayer, detailLayer, opening?.cover, opening?.picture, change?.cover, turningBack?.table, turningBack?.face]
        .compactMap { $0 } + (change?.layers ?? [])
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      let shown = over.filter { !$0.isHidden }
      for l in shown { l.isHidden = true }
      cacheDisplay(in: bounds, to: rep)
      for l in shown { l.isHidden = false }
      CATransaction.commit()
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
    scanHead.follow(frame: model.scanningFrames.first?.id, progress: ScanBatchProgress.normalized(model.scanner.progress))
  }
  /// Where the head is at `progress` through the pass under way: across the box it reads (a row of
  /// frames or one), a little past each side, at the line the scanner has reached. In single view
  /// it crosses the frame shown, when that frame is in the pass. The V850 reads the bed from its
  /// top down.
  func scanHeadPose(progress: Double) -> ScanHeadRenderer.Pose? {
    guard let model, let pass = model.scanningRect else { return nil }
    let scanning = model.scanningFrames
    let r: NormalRect, along: Double
    if model.singleView {
      guard let frame = model.selected, scanning.contains(where: { $0.id == frame.id }) else { return nil }
      r = frame.rect
      along = (pass.y + pass.height * clamp(progress) - r.y) / r.height
    } else {
      guard scanning.contains(where: { f in model.contactFrames.contains { $0.id == f.id } }) else { return nil }
      r = pass
      along = progress
    }
    let y = r.y + r.height * clamp(along), margin = min(r.width, r.height * 0.67) * 0.12
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
    var scene = LoupeRenderer.Scene(table: tableSnapshot(keptWhileZooming: true), canvas: bounds.size)
    if let shown {
      scene.film = shown
      scene.filmRect = imageRect
    }
    // Not after a new preview, a moved frame box or a switch between raw and positive. After an
    // edit it stays until the new picture arrives, so the lens never goes blank.
    guard let model else { return scene }
    if model.singleView {
      // What lies under the lens at the frame's own resolution, where it is on the picture; not
      // while the crop shows the frame's surroundings.
      guard !model.editingSingle, let frame = model.selected else { return scene }
      if let region = loupeRegion, region.key == model.loupeDetailKey(frame, single: true) {
        let r = imageRect
        scene.detail = region.image
        scene.detailRect = CGRect(
          x: r.minX + region.region.x * r.width, y: r.minY + region.region.y * r.height,
          width: region.region.width * r.width, height: region.region.height * r.height)
      }
      if let centre = loupe.center, loupeRegion.map({ $0.key != model.loupeDetailKey(frame, single: true) || !$0.region.covers(loupeFieldRegion(around: centre, by: 1.05)) }) ?? true {
        DispatchQueue.main.async { [weak self] in self?.loupeMoved() }
      }
      return scene
    }
    guard let detail = loupeDetail, !detail.single else { return scene }
    if detail.positive == !model.showsNegative,
      let frame = model.contactFrames.first(where: { $0.id == detail.id }), frame.rect == detail.rect
    {
      scene.detail = turnedDetail(detail.key, detail.image)
      let cell = screen(model.contactRect(frame).cg)
      // On a laid-out page the frame is fitted in its cell, as the page shows it.
      if model.onSheetPage, detail.image.width > 0, detail.image.height > 0 {
        let k = min(cell.width / CGFloat(detail.image.width), cell.height / CGFloat(detail.image.height))
        let size = CGSize(width: CGFloat(detail.image.width) * k, height: CGFloat(detail.image.height) * k)
        scene.detailRect = CGRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height)
      } else {
        scene.detailRect = cell
      }
      if model.loupeDetailKey(frame) + "@\(loupePixels(for: frame))" != detail.key {
        DispatchQueue.main.async { [weak self] in self?.loupeMoved() }
      }
    }
    return scene
  }
  private var loupeDetail: (key: String, id: UUID, rect: NormalRect, positive: Bool, single: Bool, image: CGImage)?
  /// How many pixels across the loupe's picture of a frame on the table should have: as many as
  /// the lens shows it with, the frame's size on the table times the loupe's magnification at
  /// the screen's resolution, from 2400 to 8192.
  private func loupePixels(for frame: FilmFrame) -> Int {
    let r = screen(model?.contactRect(frame).cg ?? frame.rect.cg), mag = CGFloat(loupe.magnification ?? loupe.style.magnification)
    let needed = max(r.width, r.height) * mag * (window?.backingScaleFactor ?? 2)
    return min(8192, max(2400, Int((needed / 1024).rounded(.up)) * 1024))
  }
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
  private var loupeDetailStale = false
  /// Fetches the frame under the loupe at its own resolution, once per change to it: on the
  /// table the frame it lies on, over the single frame that frame at full resolution. One at a
  /// time: while one renders, newer changes only mark it stale, and the newest is asked for when
  /// it is back, so a dragged fader does not queue a full-resolution render for every step.
  func loupeMoved() {
    guard let model, let center = loupe.center, imageRect.contains(center) else { return }
    let single = model.singleView
    let found: FilmFrame?
    if single {
      found = model.editingSingle ? nil : model.selected
    } else {
      let n = normal(center)
      found = model.contactFrames.last(where: { model.contactRect($0).cg.contains(n) })
    }
    guard let frame = found else { return }
    if single {
      askLoupeRegion(frame)
    } else {
      requestDetail(frame, single: false)
    }
  }
  /// Over the single frame, what lies under the lens at the frame's own resolution, read as the
  /// zoom reads its part: a 60-megapixel frame read whole took tens of seconds, the lens's piece
  /// a fraction of one.
  private(set) var loupeRegion: AppModel.Detail?
  private var loupeRegionAsked = false
  /// How far from the lens's centre, in canvas points, the film it shows reaches.
  var loupeField: CGFloat {
    let lens = loupe.eyepiece?.lens ?? CGFloat(loupe.style.lens.radius) * loupe.radius
    return lens * loupe.style.rimReach / CGFloat(loupe.magnification ?? loupe.style.magnification)
  }
  private func loupeFieldRegion(around centre: CGPoint, by scale: CGFloat) -> NormalRect {
    let r = imageRect, reach = loupeField * scale
    let x0 = max(0, (centre.x - reach - r.minX) / r.width), y0 = max(0, (centre.y - reach - r.minY) / r.height)
    let x1 = min(1, (centre.x + reach - r.minX) / r.width), y1 = min(1, (centre.y + reach - r.minY) / r.height)
    return NormalRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
  }
  private func askLoupeRegion(_ frame: FilmFrame) {
    guard let model, let centre = loupe.center, !loupeRegionAsked else { return }
    let key = model.loupeDetailKey(frame, single: true), needed = loupeFieldRegion(around: centre, by: 1.05)
    if let kept = loupeRegion, kept.key == key, kept.region.covers(needed) { return }
    loupeRegionAsked = true
    // Half again round the lens's field, so a little moving needs nothing new.
    model.renderDetail(frame, region: loupeFieldRegion(around: centre, by: 1.6)) { [weak self] detail in
      guard let self else { return }
      self.loupeRegionAsked = false
      self.loupe.setNeedsRender()
      // Moved on while it rendered: what is under the lens now. Nothing yet (the frame not yet
      // analysed) waits for the next move or picture.
      guard let detail else { return }
      self.loupeRegion = detail
      if let frame = self.model?.selected, self.model?.singleView == true { self.askLoupeRegion(frame) }
    }
  }
  /// The part of the single frame in view at its full resolution, or as much of it as the screen
  /// shows, while zoomed in past the picture shown, and where it goes on the canvas; asked for, a
  /// moment after the view settles, when what there is does not cover the view, is coarser than
  /// the screen now or is of the frame as it was.
  private(set) var zoomDetail: AppModel.Detail?
  private var zoomDetailAsked: String?
  private var zoomDetailWait: (key: String, view: NormalRect, work: DispatchWorkItem)?
  /// For a test that waits on it.
  var zoomDetailState: String { "asked \(zoomDetailAsked != nil), waiting \(zoomDetailWait != nil)" }
  private func zoomDetailInView() -> (CGImage, CGRect)? {
    guard let model, model.singleView, !model.editingSingle, let frame = model.selected, let shown else { return nil }
    let r = imageRect
    guard r.width * (window?.backingScaleFactor ?? 2) > CGFloat(shown.width) * 1.05 else {
      if zoomDetail != nil {
        zoomDetail = nil
        model.releaseDetailSource()
      }
      return nil
    }
    let view = r.intersection(visibleRect)
    guard !view.isNull, view.width > 1, view.height > 1 else { return nil }
    let inView = NormalRect(x: (view.minX - r.minX) / r.width, y: (view.minY - r.minY) / r.height, width: view.width / r.width, height: view.height / r.height)
    let key = model.loupeDetailKey(frame, single: true)
    let current = zoomDetail.flatMap { $0.key == key ? $0 : nil }
    // The screen's pixels across the whole picture as it is shown. The part was made with a tenth
    // more, at most the frame's own: a 61-megapixel frame zoomed to half again its fit rendered
    // all 61 for a screen of 4, and every draw took them down to it.
    let across = Double(r.width * (window?.backingScaleFactor ?? 2))
    let sharp = current.map { $0.scale >= 0.999 || Double($0.image.width) / max(1, $0.region.width * across) >= 0.9 } ?? false
    if current.map({ !$0.region.covers(inView) }) ?? true || !sharp { askZoomDetail(frame, key: key, around: inView, across: across * 1.1) }
    guard let d = current else { return nil }
    return (d.image, CGRect(x: r.minX + d.region.x * r.width, y: r.minY + d.region.y * r.height, width: d.region.width * r.width, height: d.region.height * r.height))
  }
  private func askZoomDetail(_ frame: FilmFrame, key: String, around inView: NormalRect, across: Double) {
    // Redraws that leave the view as it is keep the wait as it is; a moved view starts it again.
    if let w = zoomDetailWait, w.key == key, w.view == inView { return }
    zoomDetailWait?.work.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.zoomDetailWait = nil
      guard let model = self.model, self.zoomDetailAsked == nil else {
        // One under way: asked for again when it comes back, if it does not cover the view.
        return
      }
      // A quarter of the view more on each side, so a little panning stays sharp.
      let m = 0.25
      let region = NormalRect(
        x: max(0, inView.x - inView.width * m), y: max(0, inView.y - inView.height * m),
        width: min(1, inView.x + inView.width * (1 + m)) - max(0, inView.x - inView.width * m),
        height: min(1, inView.y + inView.height * (1 + m)) - max(0, inView.y - inView.height * m))
      self.zoomDetailAsked = key
      model.renderDetail(frame, region: region, across: across) { [weak self] detail in
        guard let self else { return }
        self.zoomDetailAsked = nil
        if let detail { self.zoomDetail = detail }
        self.needsDisplay = true
      }
    }
    zoomDetailWait = (key, inView, work)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }
  /// The frame at its own resolution, once per change to it: one at a time, a newer change only
  /// marking the one under way stale.
  func requestDetail(_ frame: FilmFrame, single: Bool) {
    guard let model else { return }
    let pixels = single ? 0 : loupePixels(for: frame)
    // The size is part of what is asked for: a stronger loupe asks again for more pixels.
    let key = model.loupeDetailKey(frame, single: single) + (single ? "" : "@\(pixels)")
    guard key != loupeDetailRequest, key != loupeDetail?.key else { return }
    if loupeDetailRequest != nil {
      loupeDetailStale = true
      return
    }
    loupeDetailRequest = key
    loupeDetailStale = false
    let positive = !model.showsNegative
    model.loupeDetail(for: frame, single: single, pixels: pixels) { [weak self] image in
      guard let self, self.loupeDetailRequest == key else { return }
      self.loupeDetailRequest = nil
      self.loupeDetail = image.map { (key, frame.id, frame.rect, positive, single, $0) }
      self.loupe.setNeedsRender()
      if self.loupeDetailStale {
        self.loupeDetailStale = false
        self.loupeMoved()
      }
    }
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    endZoomGlide()
    guard let model, model.displayed != nil, !model.rendering else { return }
    let p = convert(event.locationInWindow, from: nil)
    guard bounds.contains(p), imageRect.contains(p) else { return }
    if model.tool.picksPoint {
      sample(at: p)
      return
    }
    if model.tool == .curve {
      if model.singleView { beginCurveTarget(at: p) }
      return
    }
    if model.singleView {
      // The de-masking region: a corner, an edge or the box itself takes hold of it; elsewhere a new
      // one is drawn. While none is set, the part read as the picture follows (dashed) has its
      // corners and edges held the same way, so they drag from where they follow the picture; a
      // press inside it still draws a new one.
      if model.tool == .region, !model.isWorking, let frame = model.selected, let q = pictureNormal(p) {
        let own = frame.adjustments.analysisRegion?.cg, set = own ?? model.followedRegion
        let hold = regionHold(set, at: p)
        let held = hold.corner != nil || hold.edge != nil || own?.contains(q) == true
        regionDrag = (q, held ? set : nil, hold.corner, hold.edge)
        regionDraft = held ? set : nil
        return
      }
      if model.tool == .crop, model.canvasCrop != nil, !model.isWorking,
        model.levelling || event.modifierFlags.contains(.option)
      {
        levelLine = (p, p)
        return
      }
      if model.tool == .crop, let crop = model.canvasCrop, !model.isWorking {
        dragStart = normal(p)
        dragID = model.selectedID
        original = crop.cg
        draft = crop.cg
        let r = screen(crop.cg)
        (corner, edge) = cropHold(crop.cg, at: p)
        if corner == nil && edge == nil && !r.contains(p) {
          dragID = nil
          original = nil
          draft = CGRect(origin: normal(p), size: .zero)
        }
        return
      }
      // A double click zooms in about the point, and again back out to fit, gliding there: both
      // its clicks on the frame, not the first on the table opening it.
      if model.tool == .select {
        if event.clickCount >= 2, event.timestamp - singleClickAt < NSEvent.doubleClickInterval {
          singleClickAt = 0
          let zoomedIn = model.zoom > 1.05
          glideZoom(to: zoomedIn ? 1 : Self.doubleClickZoom, about: zoomedIn ? nil : p)
          return
        }
        singleClickAt = event.timestamp
      }
      panStart = p
      return
    }
    guard !model.isWorking else { return }
    dragStart = normal(p)
    // A missed frame is drawn on the holder's picture; a laid-out page is not one.
    if model.tool == .crop, !model.onSheetPage {
      draft = CGRect(origin: dragStart!, size: .zero)
      return
    }
    // On the table a click on a frame opens it, once the mouse comes up where it went down; its
    // crop is set on its own.
    if let f = model.contactFrames.reversed().first(where: { model.contactRect($0).cg.contains(normal(p)) }) {
      // ⌘ adds it to the frames chosen, ⇧ takes the run, leaving the frame selected.
      if model.choose(f.id, modifiers: event.modifierFlags) {
        dragStart = nil
        needsDisplay = true
        return
      }
      model.select(f.id)
      clickedFrame = (f.id, p)
    }
  }
  override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if curveTarget != nil {
      dragCurveTarget(to: p)
      return
    }
    if let line = levelLine {
      levelLine = (line.from, p)
      needsDisplay = true
      return
    }
    if let drag = regionDrag, let q = pictureNormal(p) {
      if let o = drag.original {
        if let corner = drag.corner {
          let opposite = CGPoint(x: corner % 2 == 0 ? o.maxX : o.minX, y: corner < 2 ? o.maxY : o.minY)
          regionDraft = CGRect(x: min(q.x, opposite.x), y: min(q.y, opposite.y), width: abs(q.x - opposite.x), height: abs(q.y - opposite.y))
        } else if let edge = drag.edge {
          var (x0, x1, y0, y1) = (o.minX, o.maxX, o.minY, o.maxY)
          switch edge {
          case 0: y0 = q.y
          case 1: y1 = q.y
          case 2: x0 = q.x
          default: x1 = q.x
          }
          regionDraft = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        } else {
          regionDraft = CGRect(
            x: clamp(Double(o.minX + q.x - drag.start.x), 0, Double(1 - o.width)),
            y: clamp(Double(o.minY + q.y - drag.start.y), 0, Double(1 - o.height)), width: o.width, height: o.height)
        }
      } else {
        regionDraft = CGRect(x: min(drag.start.x, q.x), y: min(drag.start.y, q.y), width: abs(q.x - drag.start.x), height: abs(q.y - drag.start.y))
      }
      // The loupe on the corner or edge being placed, as the crop's; not while the box moves whole.
      if drag.original == nil || drag.corner != nil || drag.edge != nil { showLens(at: p) }
      needsDisplay = true
      return
    }
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
        showLens(at: p)
      } else if let edge {
        // Only that edge follows the pointer, across it; the other three stay.
        var (x0, x1, y0, y1) = (original.minX, original.maxX, original.minY, original.maxY)
        switch edge {
        case 0: y0 = end.y
        case 1: y1 = end.y
        case 2: x0 = end.x
        default: x1 = end.x
        }
        draft = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        showLens(at: p)
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
      showLens(at: p)
    }
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    defer {
      curveTarget = nil
      releaseLens()
      dragStart = nil
      draft = nil
      original = nil
      dragID = nil
      corner = nil
      edge = nil
      panStart = nil
      levelLine = nil
      needsDisplay = true
    }
    if regionDrag != nil {
      // A click, or a box too small to read, changes nothing.
      if let draft = regionDraft, draft != regionDrag?.original { model?.setAnalysisRegion(NormalRect(draft)) }
      regionDrag = nil
      regionDraft = nil
      releaseLens()
      return
    }
    if let clicked = clickedFrame {
      clickedFrame = nil
      let p = convert(event.locationInWindow, from: nil)
      if hypot(p.x - clicked.at.x, p.y - clicked.at.y) < 4 { model?.open(clicked.id) }
      return
    }
    if let line = levelLine {
      // A click, or a line too short to tell a direction by, leaves the frame as it is.
      if hypot(line.to.x - line.from.x, line.to.y - line.from.y) >= 12 {
        model?.straighten(along: Double(line.to.x - line.from.x), Double(line.to.y - line.from.y))
      }
      return
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
  /// How far a horizontal swipe on the light table has gone; past 40 points it turns the page.
  private var swipe: CGFloat = 0
  private var lastStep = Date.distantPast
  override func scrollWheel(with event: NSEvent) {
    if let model, !model.singleView, (model.zoom) <= 1, model.contactPages.count > 1,
      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipe != 0
    {
      // Fingers moving left bring the next page in from the right, as pages turn in the system.
      if event.phase == .began { swipe = 0 }
      guard event.momentumPhase.isEmpty else { return }
      swipe += event.scrollingDeltaX
      let ended = event.phase == .ended || event.phase == .cancelled
      let wheel = event.phase.isEmpty
      if (ended || wheel) && abs(swipe) > 40 && Date().timeIntervalSince(lastStep) > 0.4 {
        model.showContactPage(model.contactPage + (swipe < 0 ? 1 : -1))
        lastStep = Date()
        swipe = 0
      } else if ended {
        swipe = 0
      }
      return
    }
    if event.modifierFlags.contains(.command) {
      setZoom(
        (model?.zoom ?? 1) * exp(-event.scrollingDeltaY * 0.01),
        anchor: convert(event.locationInWindow, from: nil))
    } else if (model?.zoom ?? 1) > 1 {
      // The picture follows the fingers, as a scroll view's content does with the system's own
      // scrolling direction.
      endZoomGlide()
      pan.x += event.scrollingDeltaX
      pan.y += event.scrollingDeltaY
      clampPan()
      refreshCursorArea()
    }
    needsDisplay = true
    pointerMoved(event)
  }
  override func magnify(with event: NSEvent) {
    setZoom(
      (model?.zoom ?? 1) * (1 + event.magnification),
      anchor: convert(event.locationInWindow, from: nil))
    needsDisplay = true
    pointerMoved(event)
  }
  /// The light table always shows the whole roll; only the single frame zooms.
  /// A sampler's click on a point of the picture: on the canvas, or through the loupe's lens.
  func sample(at p: CGPoint) {
    guard let model, model.displayed != nil, !model.rendering, model.tool.picksPoint, imageRect.contains(p) else { return }
    model.sample(normal(p))
  }
  func setZoom(_ zoom: Double, anchor: CGPoint) {
    guard model?.singleView == true else { return }
    endZoomGlide()
    defer { window?.invalidateCursorRects(for: self) }
    let old = imageRect
    guard old.width > 0, old.height > 0 else { return }
    let n = CGPoint(x: (anchor.x - old.minX) / old.width, y: (anchor.y - old.minY) / old.height)
    // Far enough that a pixel of a 60-megapixel frame is several of the screen's.
    settingZoom = true
    model?.zoom = clamp(zoom, 0.5, 32)
    settingZoom = false
    let new = imageRect
    pan.x += anchor.x - (new.minX + n.x * new.width)
    pan.y += anchor.y - (new.minY + n.y * new.height)
    clampPan()
    viewZoomed()
  }
  /// While `setZoom` sets the model's zoom, which tells the canvas; it follows once the anchor is kept.
  private var settingZoom = false
  /// The model's zoom changed, or 「适合」 was asked for (another frame, a test): the canvas follows
  /// by itself, as the window no longer updates for either.
  func zoomChanged() {
    guard !settingZoom, let model else { return }
    // Set from elsewhere (another frame, the crop), the glide gives way.
    endZoomGlide()
    // 「适合」: back in the middle.
    if lastViewportRevision != model.viewportRevision {
      pan = .zero
      lastViewportRevision = model.viewportRevision
    }
    clampPan()
    viewZoomed()
  }
  /// The zoom and the pan set together, as a glide's step sets them; the pan as given, not kept
  /// within the canvas, the glide's path keeping it there.
  func place(zoom: Double, pan p: CGPoint) {
    settingZoom = true
    model?.zoom = zoom
    settingZoom = false
    pan = p
    viewZoomed()
    window?.invalidateCursorRects(for: self)
  }
  /// The model's 「适合」 back in the middle, once a glide lands there.
  func noteViewport() { lastViewportRevision = model?.viewportRevision ?? lastViewportRevision }
  /// What follows the picture's size on the canvas, as an update of the window did when the zoom
  /// was published: the sampler's cursor, the loupe grown with the frame, the scan head.
  private func viewZoomed() {
    zoomingUntil = CACurrentMediaTime() + Self.zoomSettles
    refreshCursorArea()
    needsDisplay = true
    updateLoupe()
    updateScanHead()
    if !loupe.isHidden {
      // Once the zoom stops, the loupe looks through the table as it is then, and sharp.
      zoomSettle?.cancel()
      let settle = DispatchWorkItem { [weak self] in self?.loupe.setNeedsRender() }
      zoomSettle = settle
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.zoomSettles + 0.01, execute: settle)
    }
  }
  /// While a zoom is under way, and a moment after its last step: the loupe looks through the
  /// table as it was last taken, one ray a pixel. Taken again for every step, the canvas drawn
  /// whole once more and sent to the graphics card, a step with the loupe out took four times one
  /// without; the lens itself shows the frame as it is now all the same.
  private static let zoomSettles: CFTimeInterval = 0.15
  private var zoomingUntil: CFTimeInterval = 0
  private var zoomSettle: DispatchWorkItem?
  var zooming: Bool { CACurrentMediaTime() < zoomingUntil }
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
    } else if model?.singleView == true, model?.tool == .crop, [33, 30].contains(event.keyCode),
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let model
    {
      // [ and ]: a tenth of a degree, with shift a whole one.
      let step = event.modifierFlags.contains(.shift) ? 1.0 : 0.1
      model.straighten(model.screenAngle + (event.keyCode == 30 ? step : -step))
    } else if [36, 76].contains(event.keyCode), model?.singleView == true, model?.tool == .crop || model?.tool == .region {
      // Return (or the keypad's Enter) ends the crop or the de-masking region, as it is set.
      model?.useTool(.select)
    } else if [123, 124].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
      // The frame before or after, on the light table too, its page turning with it.
      let was = model?.selectedID
      model?.navigate(event.keyCode == 123 ? -1 : 1)
      glideTableSelection(from: was)
    } else if event.keyCode == 51 {
      model?.deletePressed()
    } else if event.keyCode == 53 {
      model?.useTool(.select)
      model?.fitView()
      pan = .zero
      needsDisplay = true
    } else if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
      event.charactersIgnoringModifiers?.lowercased() == AppModel.loupeShortcut
    {
      model?.toggleLoupe()
    } else if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
      let key = event.charactersIgnoringModifiers?.lowercased(),
      let tool = CanvasTool.allCases.first(where: { $0.shortcut == key }),
      // The pickers belong to taking the mask off; capturing has only the frame tools.
      model?.page != .capture || ![CanvasTool.base, .neutral, .shadowNeutral, .region].contains(tool)
    {
      model?.useTool(tool)
    } else {
      super.keyDown(with: event)
    }
  }
}

private extension NSBezierPath {
  func appendPolygon(_ points: [CGPoint]) {
    guard let first = points.first else { return }
    move(to: first)
    for p in points.dropFirst() { line(to: p) }
    close()
  }
}

/// What the canvas draws over its picture (`FilmCanvasView.drawOverlays`), a view of its own above
/// the picture's layers. The canvas takes every press and every pointer.
final class CanvasOverlay: NSView {
  weak var canvas: FilmCanvasView?
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) { canvas?.drawOverlays() }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
  private let run: () -> Void
  init(_ title: String, symbol: String? = nil, enabled: Bool = true, _ run: @escaping () -> Void) {
    self.run = run
    super.init(title: title, action: #selector(fire), keyEquivalent: "")
    target = self
    isEnabled = enabled
    if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
  }
  required init(coder: NSCoder) { fatalError("not from a nib") }
  @objc private func fire() { run() }
}
