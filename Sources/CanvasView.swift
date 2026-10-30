import AppKit
import SwiftUI

struct ScanCanvas: NSViewRepresentable {
  @ObservedObject var model: AppModel
  /// Room at the edges taken by panels and bars floating over the canvas.
  var reserved = NSEdgeInsets()
  func makeNSView(context: Context) -> FilmCanvasView {
    let v = FilmCanvasView()
    v.model = model
    return v
  }
  func updateNSView(_ view: FilmCanvasView, context: Context) {
    view.model = model
    view.reserved = reserved
    // A sampler shows its eyedropper over the canvas.
    if view.cursorTool != model.tool {
      view.cursorTool = model.tool
      view.window?.invalidateCursorRects(for: view)
      view.window?.invalidateCursorRects(for: view.loupe)
    }
    if view.lastViewportRevision != model.viewportRevision {
      view.pan = .zero
      view.lastViewportRevision = model.viewportRevision
    }
    view.refreshCursorArea()
    view.clampPan()
    view.applyFocusRequest()
    view.needsDisplay = true
    view.updateLoupe()
    view.updateScanHead()
    view.applyOpenRequest()
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
  /// The glass bubble over a corner being dragged: the corner, in the shown picture's normalised
  /// coordinates, and when it appeared; the bubble last drawn, and the one fading after release.
  var lens: (point: CGPoint, since: CFTimeInterval)?
  var lensDrawn: (key: String, image: CGImage, frame: CGRect)?
  var lensFading: (image: CGImage, frame: CGRect, since: CFTimeInterval)?
  private var lensTimer: Timer?
  /// The picture through the chosen channel gel, kept while the picture and the gel stay the same.
  private var channelCache: (source: CGImage, channel: ChannelView, image: CGImage)?
  private func channelled(_ cg: CGImage, _ channel: ChannelView) -> CGImage {
    guard channel != .all else { return cg }
    if let c = channelCache, c.source === cg, c.channel == channel { return c.image }
    let image = channel.apply(cg)
    channelCache = (cg, channel, image)
    return image
  }
  var pan = CGPoint.zero
  var panStart: CGPoint?
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
    case .neutral, .calibrate: return Self.dropper
    case .highlight: return Self.halfDropper
    case .it8: return .crosshair
    default: return nil
    }
  }
  private static let dropper = eyedropper("eyedropper")
  private static let filledDropper = eyedropper("eyedropper.full")
  private static let halfDropper = eyedropper("eyedropper.halffull")
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
  func clampPan() {
    let r = imageRect
    let x = max(0, (r.width - open.width) / 2)
    let y = max(0, (r.height - open.height) / 2)
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
  private func turnPage() {
    guard let model, let picture = model.displayed, picture !== drawnPicture else { return }
    defer {
      drawnPicture = picture
      drawnPage = model.contactPage
    }
    guard drawnPicture != nil, model.contactPage != drawnPage, !model.singleView, let layer else { return }
    let slide = CATransition()
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      slide.type = .fade
      slide.duration = 0.2
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
      let text = "扫描预览" as NSString
      text.draw(
        at: CGPoint(x: reserved.left + open.width / 2 - 30, y: reserved.top + open.height / 2),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 13),
          .foregroundColor: lightTable ? NSColor(calibratedWhite: 0.42, alpha: 1) : NSColor.secondaryLabelColor,
        ])
      return
    }
    // A frame opened from the table grows over the single view until its own picture is here.
    if let opening, model.singleView, model.displayed === opening.over { return }
    let rect = imageRect
    let sheet = model.onSheetPage
    if !sheet {
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
    }
    let image = NSImage(cgImage: channelled(cg, model.channelView), size: CGSize(width: cg.width, height: cg.height))
    // A laid-out page's strips lie on the table, its perforations open to the light.
    image.draw(
      in: rect, from: .zero, operation: sheet ? .sourceOver : .copy, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high])
    // Zoomed in past the picture shown, the part in view from the frame's own pixels over it:
    // square, once each is two pixels of the screen or more, so a pixel shows as one.
    if let (detail, area) = zoomDetailInView() {
      let pixelsPerPixel = area.width * (window?.backingScaleFactor ?? 2) / CGFloat(max(1, detail.width))
      NSImage(cgImage: detail, size: CGSize(width: detail.width, height: detail.height)).draw(
        in: area, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
        hints: [.interpolation: pixelsPerPixel >= 2 ? NSImageInterpolation.none : .high])
    }
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
      for f in model.contactFrames {
        let r = screen(model.contactRect(f).cg)
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
            .foregroundColor: NSColor.black,
          ])
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
  override func mouseMoved(with event: NSEvent) {
    hover = convert(event.locationInWindow, from: nil)
  }
  override func mouseExited(with event: NSEvent) {
    hover = nil
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
    // A laid-out page prints every frame in a cell the size of a 135 frame, whatever its file's
    // own size, so the loupe's field takes in a whole one.
    if model.onSheetPage, let f = model.contactFrames.first {
      return imageRect.width * CGFloat(model.contactRect(f).width) / 36
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
      return min(side * 0.45, max(44, CGFloat(style.baseMM / 2) * perMM))
    }
    guard let perMM = loupePointsPerMM else { return 70 }
    return min(110, max(44, CGFloat(style.baseMM / 2) * perMM))
  }
  /// Over the single frame no more than the frame's pixels can show, half again past one to a
  /// point, and never under 2×; nil on the light table, where the loupe's field decides it.
  func loupeMagnification(for style: LoupeStyle) -> Double? {
    guard let model, model.singleView else { return nil }
    // The frame's own pixels under the lens once they are here, else the picture shown.
    let perPoint: Double
    if let region = loupeRegion, region.key == model.selected.map({ model.loupeDetailKey($0, single: true) }) {
      perPoint = Double(region.image.width) / max(1, region.region.width * Double(imageRect.width))
    } else {
      perPoint = Double(shown?.width ?? 0) / Double(max(1, imageRect.width))
    }
    return min(style.magnification, max(2, perPoint * 1.5))
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
    if loupe.isHidden != hidden {
      loupe.isHidden = hidden
      if !hidden {
        loupeHomeFrame = model.selectedID
        loupe.layoutOnTable()
      } else {
        // Put away, it keeps no full-resolution picture.
        loupeDetail = nil
        loupeDetailRequest = nil
        loupeDetailStale = false
        loupeRegion = nil
        turnedLoupeDetail = nil
        LoupeRenderer.shared.release()
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

  private var openedRevision = 0
  /// A frame opened from the light table on its way to the middle: the table's picture, the view
  /// closing in on the frame, its own picture over it, until the frame's own is drawn.
  private(set) var opening: (cover: CALayer, picture: CALayer, over: CGImage?, grown: Bool)?
  /// Opens the frame the film strip asked for, and finishes an opening once its picture is here.
  func applyOpenRequest() {
    guard let model else { return }
    if let opening, !model.singleView || (opening.grown && model.displayed !== opening.over) { finishOpening() }
    guard let ask = model.openRequest, ask.revision != openedRevision else { return }
    openedRevision = ask.revision
    guard !model.singleView, let f = model.contactFrames.first(where: { $0.id == ask.id }) else { return }
    open(f)
  }
  /// Shows a frame on the light table on its own: the view closes in on it, the whole table
  /// growing about it on a spring, a little past and back, until it lies where the single view
  /// shows it and the frames round it have gone off the canvas; the table then fades to the
  /// single view's surround. Cross-faded, with Reduce Motion.
  func open(_ f: FilmFrame) {
    guard let model, !model.singleView else { return }
    model.select(f.id)
    defer {
      model.singleView = true
      model.refresh()
    }
    guard let layer, bounds.width > 0, let table = tableSnapshot() else { return }
    let cell = screen(model.contactRect(f).cg)
    // The positive the film strip has, where the table shows positives; else the table's own.
    let face = model.contactPositive && !model.showNegative ? model.thumbnails[f.id] : nil
    var from = cell, image: CGImage?
    if let face, face.width > 0, face.height > 0 {
      image = face
      if model.onSheetPage { from = Self.fitted(CGSize(width: face.width, height: face.height), in: cell) }
    } else {
      let k = CGFloat(table.width) / bounds.width
      image = table.cropping(to: CGRect(x: cell.minX * k, y: cell.minY * k, width: cell.width * k, height: cell.height * k).integral)
    }
    let area = CGRect(x: reserved.left + Self.inset, y: reserved.top + Self.inset,
      width: max(1, open.width - 2 * Self.inset), height: max(1, open.height - 2 * Self.inset))
    let to = Self.fitted(from.size, in: area)
    // The table as the view closes in: scaled about the frame as much as the frame grows.
    let k = to.width / max(1, from.width)
    let tableTo = CGRect(x: to.midX + (bounds.minX - from.midX) * k, y: to.midY + (bounds.minY - from.midY) * k,
      width: bounds.width * k, height: bounds.height * k)
    finishOpening()
    let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let cover = CALayer(), picture = CALayer()
    cover.frame = still ? bounds : tableTo
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

    // Grown once it is seen to have arrived: what is left of the spring is too small to see.
    DispatchQueue.main.asyncAfter(deadline: .now() + (still ? 0.2 : 0.55)) { [weak self] in
      guard let self, self.opening?.picture === picture else { return }
      self.opening?.grown = true
      self.applyOpenRequest()
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
      // table and the frame on the same spring, so the frame stays where it lies on the table.
      for (moving, start) in [(cover, bounds), (picture, from)] {
        let move = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.15)
        move.keyPath = "position"
        move.fromValue = NSValue(point: CGPoint(x: start.midX, y: start.midY))
        let grow = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.15)
        grow.keyPath = "bounds.size"
        grow.fromValue = NSValue(size: start.size)
        for a in [move, grow] {
          a.duration = a.settlingDuration
          moving.add(a, forKey: a.keyPath)
        }
      }
    }
    CATransaction.commit()
    // Should the frame's picture never come, the single view shows what it has.
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      if self?.opening?.picture === picture { self?.finishOpening() }
    }
  }
  /// The opened frame's own picture is drawn: what grew there fades into it.
  private func finishOpening() {
    guard let done = opening else { return }
    opening = nil
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
    var scene = LoupeRenderer.Scene(table: tableSnapshot(), canvas: bounds.size)
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
    if detail.positive == model.contactPositive,
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
  /// The part of the single frame in view at its full resolution, while zoomed in past the
  /// picture shown, and where it goes on the canvas; asked for, a moment after the view settles,
  /// when what there is does not cover the view or is of the frame as it was.
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
    if current.map({ !$0.region.covers(inView) }) ?? true { askZoomDetail(frame, key: key, around: inView) }
    guard let d = current else { return nil }
    return (d.image, CGRect(x: r.minX + d.region.x * r.width, y: r.minY + d.region.y * r.height, width: d.region.width * r.width, height: d.region.height * r.height))
  }
  private func askZoomDetail(_ frame: FilmFrame, key: String, around inView: NormalRect) {
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
      model.renderDetail(frame, region: region) { [weak self] detail in
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
    let positive = single ? !model.showNegative : model.contactPositive
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
    guard let model, model.displayed != nil, !model.rendering else { return }
    let p = convert(event.locationInWindow, from: nil)
    guard bounds.contains(p), imageRect.contains(p) else { return }
    if model.tool.picksPoint {
      sample(at: p)
      return
    }
    if model.singleView {
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
    // On the table a click picks a frame and a double click opens it; its crop is set on its own.
    if let f = model.contactFrames.reversed().first(where: { model.contactRect($0).cg.contains(normal(p)) }) {
      model.select(f.id)
      if event.clickCount == 2 { open(f) }
    }
  }
  override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if let line = levelLine {
      levelLine = (line.from, p)
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
      releaseLens()
      dragStart = nil
      draft = nil
      original = nil
      dragID = nil
      corner = nil
      panStart = nil
      levelLine = nil
      needsDisplay = true
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
      pan.x += event.scrollingDeltaX
      pan.y += event.scrollingDeltaY
      clampPan()
      refreshCursorArea()
    }
    needsDisplay = true
  }
  override func magnify(with event: NSEvent) {
    setZoom(
      (model?.zoom ?? 1) * (1 + event.magnification),
      anchor: convert(event.locationInWindow, from: nil))
    needsDisplay = true
  }
  /// The light table always shows the whole roll; only the single frame zooms.
  /// A sampler's click on a point of the picture: on the canvas, or through the loupe's lens.
  func sample(at p: CGPoint) {
    guard let model, model.displayed != nil, !model.rendering, model.tool.picksPoint, imageRect.contains(p) else { return }
    model.sample(normal(p))
  }
  func setZoom(_ zoom: Double, anchor: CGPoint) {
    guard model?.singleView == true else { return }
    defer { window?.invalidateCursorRects(for: self) }
    let old = imageRect
    guard old.width > 0, old.height > 0 else { return }
    let n = CGPoint(x: (anchor.x - old.minX) / old.width, y: (anchor.y - old.minY) / old.height)
    // Far enough that a pixel of a 60-megapixel frame is several of the screen's.
    model?.zoom = clamp(zoom, 0.5, 32)
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
    } else if model?.singleView == true, model?.tool == .crop, [33, 30].contains(event.keyCode),
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let model
    {
      // [ and ]: a tenth of a degree, with shift a whole one.
      let step = event.modifierFlags.contains(.shift) ? 1.0 : 0.1
      model.straighten(model.screenAngle + (event.keyCode == 30 ? step : -step))
    } else if event.keyCode == 36 && model?.tool == .crop && model?.singleView == true {
      model?.useTool(.select)
    } else if [123, 124].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
      // The frame before or after, on the light table too, its page turning with it.
      model?.navigate(event.keyCode == 123 ? -1 : 1)
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
      let tool = CanvasTool.allCases.first(where: { $0.shortcut == key })
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
