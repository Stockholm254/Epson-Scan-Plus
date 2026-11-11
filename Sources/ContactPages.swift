import AppKit
import CoreText

/// The light table's pages. A scanned roll's frames lie on the preview of their holder, as they
/// were scanned; frames of files of their own (the camera's, imports) are laid out the way a roll
/// is printed on a contact sheet, in strips of six, six strips to a page, and once a page is full
/// the next one lies beyond it, a swipe to the right away.
extension AppModel {
  enum ContactPage: Equatable { case holder, sheet(Int) }
  static let sheetPerStrip = 6, sheetStrips = 6
  static var sheetPerPage: Int { sheetPerStrip * sheetStrips }

  /// Frames of files of their own, in the roll's order: not those of a scanned holder, nor those
  /// found together on one imported picture of a holder, which lie on it as scanned.
  var sheetFrames: [FilmFrame] {
    var shared = [String: Int]()
    for f in frames { if let path = f.sourcePath { shared[path, default: 0] += 1 } }
    return frames.filter { f in f.sourcePath.map { shared[$0] == 1 } ?? false }
  }
  /// The holder's preview first when frames lie on it, then a page for every 36 frames of their own.
  var contactPages: [ContactPage] {
    var pages = [ContactPage]()
    let own = sheetFrames.count
    if own < frames.count || frames.isEmpty || scanner.previewSoFar != nil { pages.append(.holder) }
    pages += (0..<((own + Self.sheetPerPage - 1) / Self.sheetPerPage)).map { ContactPage.sheet($0) }
    return pages
  }
  var shownContactPage: ContactPage {
    let pages = contactPages
    return pages[min(max(0, contactPage), pages.count - 1)]
  }
  /// The light table shows a page laid out from frames of their own files.
  var onSheetPage: Bool {
    guard !singleView, scanner.previewSoFar == nil, case .sheet = shownContactPage else { return false }
    return true
  }
  /// The frames on the page shown, in the order they are laid out.
  var sheetPageFrames: [FilmFrame] {
    guard case .sheet(let i) = shownContactPage else { return [] }
    return Array(sheetFrames.dropFirst(i * Self.sheetPerPage).prefix(Self.sheetPerPage))
  }
  /// The page a frame lies on.
  func contactPageIndex(of id: UUID) -> Int? {
    let pages = contactPages
    if let i = sheetFrames.firstIndex(where: { $0.id == id }) { return pages.firstIndex(of: .sheet(i / Self.sheetPerPage)) }
    return frames.contains { $0.id == id } ? pages.firstIndex(of: .holder) : nil
  }
  /// Turns to page `index` of the light table, as a swipe or its keys do.
  func showContactPage(_ index: Int) {
    let i = min(max(0, index), contactPages.count - 1)
    guard i != contactPage else { return }
    contactPage = i
    refresh()
  }
  /// A frame's rectangle on the light table, normalised to the picture shown: its cell on a laid-out
  /// page, else where it lies on the holder's preview.
  func contactRect(_ f: FilmFrame) -> NormalRect {
    let page = sheetPageFrames
    guard onSheetPage, let i = page.firstIndex(where: { $0.id == f.id }) else { return f.rect }
    let positive = !showsNegative
    let layout = Self.sheetLayout(aspects: page.map { sheetAspect($0, positive: positive) }, pages: contactPages.count)
    let c = layout.cells[i]
    return NormalRect(x: c.minX / layout.size.width, y: c.minY / layout.size.height, width: c.width / layout.size.width, height: c.height / layout.size.height)
  }
  /// A frame's width over its height on a laid-out page, from its file and its crop: turned as it
  /// is printed for the positives, as it lies on the film for the negatives; 3:2 until its file
  /// is read.
  func sheetAspect(_ f: FilmFrame, positive: Bool) -> CGFloat {
    let pixels = f.sourcePath.map(filePixels) ?? .zero
    guard pixels.width > 0, pixels.height > 0, f.rect.width > 0, f.rect.height > 0 else { return Self.sheetCell.width / Self.sheetCell.height }
    let aspect = CGFloat(f.rect.width) * pixels.width / (CGFloat(f.rect.height) * pixels.height)
    return positive && ((f.adjustments.rotation % 4) + 4) % 2 == 1 ? 1 / aspect : aspect
  }
  /// From the film strip, the view switch or a finished preview: the frame selected, and from
  /// the light table shown on its own, the view closing in on it there. Without a canvas, at once.
  func open(_ id: UUID) {
    select(id)
    guard !singleView, !previewShowing else { return }
    if let frameOpener {
      frameOpener(id)
    } else {
      singleView = true
      refresh()
    }
  }
  /// The view switch: into the single view by opening the selected frame; back to the light
  /// table, the view drawing back from the frame.
  func showSingle(_ on: Bool) {
    if on, !singleView, let id = selectedID {
      open(id)
    } else if on != singleView {
      if !on { viewWillChange?(.close) }
      singleView = on
      refresh()
    }
  }

  /// A 3:2 frame on a laid-out page, in pixels: 36 mm across.
  static let sheetCell = CGSize(width: 360, height: 240)
  /// A page of frames all 3:2.
  static func sheetLayout(count: Int, pages: Int) -> (size: CGSize, cells: [CGRect], strips: [CGRect]) {
    sheetLayout(aspects: Array(repeating: sheetCell.width / sheetCell.height, count: count), pages: pages)
  }
  /// A page's layout in pixels, top-left origin: frames in strips of film with their rebates, each
  /// cell the shape of its frame (`aspects`, width over height), so none leaves black beside it: one
  /// narrower than 3:2 as tall as a 3:2 frame, one wider as wide and lower. Every page of a roll
  /// with more than one has room for six strips of six 3:2 frames, so turning keeps the scale; a
  /// roll of one page is as tall as its strips and as wide as its widest strip of its own frames
  /// (six 6×6 squares are two thirds of six 3:2 frames across), so the light table shows it as
  /// large as it holds rather than in a corner of an empty page.
  static func sheetLayout(aspects: [CGFloat], pages: Int) -> (size: CGSize, cells: [CGRect], strips: [CGRect]) {
    let cell = sheetCell, gap: CGFloat = 18, rebate: CGFloat = 40, side: CGFloat = 28
    let stripGap: CGFloat = 40, margin: CGFloat = 48
    let count = aspects.count
    let strips = pages > 1 ? sheetStrips : max(1, (count + sheetPerStrip - 1) / sheetPerStrip)
    let across = pages > 1 ? sheetPerStrip : min(sheetPerStrip, max(1, count))
    let stripWidth = side * 2 + cell.width * CGFloat(across) + gap * CGFloat(across - 1)
    let stripHeight = cell.height + rebate * 2
    let size = CGSize(width: margin * 2 + stripWidth, height: margin * 2 + stripHeight * CGFloat(strips) + stripGap * CGFloat(strips - 1))
    var cells = [CGRect](), stripRects = [CGRect]()
    for s in 0..<strips {
      let y = margin + CGFloat(s) * (stripHeight + stripGap)
      let inStrip = aspects.dropFirst(s * sheetPerStrip).prefix(sheetPerStrip)
      guard !inStrip.isEmpty else { continue }
      var x = margin + side
      for aspect in inStrip {
        let a = min(max(aspect, 0.25), 4)
        let w = (min(a, cell.width / cell.height) * cell.height).rounded(), h = min(cell.height, cell.width / a).rounded()
        cells.append(CGRect(x: x, y: y + rebate + ((cell.height - h) / 2).rounded(), width: w, height: h))
        x += w + gap
      }
      stripRects.append(CGRect(x: margin, y: y, width: x - gap + side - margin, height: stripHeight))
    }
    // One page: no wider than its strips.
    if pages <= 1, let widest = stripRects.map(\.width).max() {
      return (CGSize(width: margin * 2 + widest, height: size.height), cells, stripRects)
    }
    return (size, cells, stripRects)
  }

  /// The page as the light table shows it: only the pictures, laid out as on strips of film but
  /// without the film (pictures of their own files, a copy stand's or imported, have no strip of
  /// sprocket holes to show), each as it is (positives, or the negatives as they came), filling its
  /// frame of its `aspect`. Its number is the canvas's, on the label above it.
  static func composeSheet(_ tiles: [(name: String, image: CGImage?, aspect: CGFloat)], pages: Int) -> CGImage? {
    let layout = sheetLayout(aspects: tiles.map(\.aspect), pages: pages)
    let w = Int(layout.size.width), h = Int(layout.size.height)
    guard let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: ImagePipeline.shared.outputSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // Top-left origin, as the layout is.
    func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height) }
    for (i, tile) in tiles.enumerated() where i < layout.cells.count {
      let cell = layout.cells[i]
      ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.04, blue: 0.035, alpha: 1))
      ctx.fill(flip(cell))
      if let image = tile.image {
        let kx = cell.width / CGFloat(image.width), ky = cell.height / CGFloat(image.height)
        // Filling its cell, which has its shape; fitted in it while a picture just turned is not
        // yet in as turned.
        let k = abs(kx / ky - 1) < 0.03 ? max(kx, ky) : min(kx, ky)
        let size = CGSize(width: CGFloat(image.width) * k, height: CGFloat(image.height) * k)
        let fit = CGRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height)
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.clip(to: flip(cell))
        ctx.draw(image, in: flip(fit))
        ctx.restoreGState()
      }
    }
    return ctx.makeImage()
  }
}
