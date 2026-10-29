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
        at: CGPoint(x: reserved.left + open.width / 2 - 30, y: reserved.top + open.height / 2),
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
    let image = NSImage(cgImage: channelled(cg, model.channelView), size: CGSize(width: cg.width, height: cg.height))
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
    if !model.singleView && model.scanner.previewSoFar == nil {
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
    }
    if model.singleView, model.tool == .it8, let frame = model.selected { drawIT8(model.it8Marks, settings: frame.adjustments) }
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
  var loupePointsPerMM: CGFloat? {
    guard let model, !model.singleView, model.physicalMM.height > 0, let cg = shown else { return nil }
    let shownHeight = turn.sideways ? model.physicalMM.width : model.physicalMM.height
    return fitScale * CGFloat(cg.height) / max(1, shownHeight)
  }
  /// On the light table the loupe lies to the film's scale; over the single frame, which is shown
  /// far larger than life, at a size to hold in view.
  func loupeRadius(for style: LoupeStyle) -> CGFloat {
    guard let model, shown != nil else { return 70 }
    if model.singleView { return min(130, max(70, min(bounds.width, bounds.height) * 0.14)) * CGFloat(style.baseMM / 48) }
    guard let perMM = loupePointsPerMM else { return 70 }
    return min(110, max(44, CGFloat(style.baseMM / 2) * perMM))
  }
  /// Over the single frame no more than the frame's pixels can show, half again past one to a
  /// point, and never under 2×; nil on the light table, where the loupe's field decides it.
  func loupeMagnification(for style: LoupeStyle) -> Double? {
    guard let model, model.singleView else { return nil }
    // The frame's own picture once it is here, else the one shown; never another frame's.
    let detail = loupeDetail.flatMap { $0.single && $0.id == model.selectedID && !model.editingSingle ? $0.image : nil }
    let pixels = Double(detail?.width ?? shown?.width ?? 0)
    let perPoint = pixels / Double(max(1, imageRect.width))
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
      let s = screen(f.rect.cg)
      c = CGPoint(x: s.midX, y: s.midY)
    }
    return CGPoint(x: min(max(c.x, bounds.minX), bounds.maxX), y: min(max(c.y, bounds.minY), bounds.maxY))
  }
  private var loupeView: Bool?
  private var loupeShown = CGSize.zero
  private var loupeTurn: QuarterTurn?
  func updateLoupe() {
    guard let model else { return }
    let hidden = !model.preferences.showLoupe || model.displayed == nil
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
    guard let model, let detail = loupeDetail, detail.single == model.singleView else { return scene }
    if model.singleView {
      // The single frame fills the picture, as it is shown; not while the crop shows its surroundings.
      if !model.editingSingle, detail.positive == !model.showNegative, let frame = model.selected, frame.id == detail.id,
        frame.rect == detail.rect
      {
        scene.detail = detail.image
        scene.detailRect = imageRect
        if model.loupeDetailKey(frame, single: true) != detail.key {
          DispatchQueue.main.async { [weak self] in self?.loupeMoved() }
        }
      }
    } else if detail.positive == model.contactPositive,
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
  private var loupeDetail: (key: String, id: UUID, rect: NormalRect, positive: Bool, single: Bool, image: CGImage)?
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
      found = model.contactFrames.last(where: { $0.rect.cg.contains(n) })
    }
    guard let frame = found else { return }
    let key = model.loupeDetailKey(frame, single: single)
    guard key != loupeDetailRequest, key != loupeDetail?.key else { return }
    if loupeDetailRequest != nil {
      loupeDetailStale = true
      return
    }
    loupeDetailRequest = key
    loupeDetailStale = false
    let positive = single ? !model.showNegative : model.contactPositive
    model.loupeDetail(for: frame, single: single) { [weak self] image in
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
