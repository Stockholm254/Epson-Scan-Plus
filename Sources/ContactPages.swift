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

  /// Frames of files of their own, in the roll's order.
  var sheetFrames: [FilmFrame] { frames.filter { $0.sourcePath != nil } }
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
    guard onSheetPage, let i = sheetPageFrames.firstIndex(where: { $0.id == f.id }) else { return f.rect }
    let layout = Self.sheetLayout(count: sheetPageFrames.count, pages: contactPages.count)
    let c = layout.cells[i]
    return NormalRect(x: c.minX / layout.size.width, y: c.minY / layout.size.height, width: c.width / layout.size.width, height: c.height / layout.size.height)
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

  /// A page's layout in pixels, top-left origin: frames 3:2 in strips of film with their rebates.
  /// Every page of a roll with more than one has room for six strips, so turning keeps the scale.
  static func sheetLayout(count: Int, pages: Int) -> (size: CGSize, cells: [CGRect], strips: [CGRect]) {
    let cell = CGSize(width: 360, height: 240), gap: CGFloat = 18, rebate: CGFloat = 40, side: CGFloat = 28
    let stripGap: CGFloat = 40, margin: CGFloat = 48
    let strips = pages > 1 ? sheetStrips : max(1, (count + sheetPerStrip - 1) / sheetPerStrip)
    let stripWidth = side * 2 + cell.width * CGFloat(sheetPerStrip) + gap * CGFloat(sheetPerStrip - 1)
    let stripHeight = cell.height + rebate * 2
    let size = CGSize(width: margin * 2 + stripWidth, height: margin * 2 + stripHeight * CGFloat(strips) + stripGap * CGFloat(strips - 1))
    var cells = [CGRect](), stripRects = [CGRect]()
    for s in 0..<strips {
      let y = margin + CGFloat(s) * (stripHeight + stripGap)
      let inStrip = min(sheetPerStrip, count - s * sheetPerStrip)
      guard inStrip > 0 else { continue }
      stripRects.append(CGRect(x: margin, y: y, width: side * 2 + cell.width * CGFloat(inStrip) + gap * CGFloat(inStrip - 1), height: stripHeight))
      for c in 0..<inStrip {
        cells.append(CGRect(x: margin + side + CGFloat(c) * (cell.width + gap), y: y + rebate, width: cell.width, height: cell.height))
      }
    }
    return (size, cells, stripRects)
  }

  /// The page as the light table shows it: each strip of dark film, its perforations open to the
  /// table's light, the frames in it as they are (positives, or the negatives as they came), each
  /// fitted in its frame, its number printed on the rebate above.
  static func composeSheet(_ tiles: [(name: String, image: CGImage?)], pages: Int) -> CGImage? {
    let layout = sheetLayout(count: tiles.count, pages: pages)
    let w = Int(layout.size.width), h = Int(layout.size.height)
    guard let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: ImagePipeline.shared.outputSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // Top-left origin, as the layout is.
    func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height) }
    for strip in layout.strips {
      ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.075, blue: 0.045, alpha: 0.97))
      ctx.addPath(CGPath(roundedRect: flip(strip), cornerWidth: 6, cornerHeight: 6, transform: nil))
      ctx.fillPath()
      // The perforations: holes the table's light comes through.
      ctx.setBlendMode(.clear)
      for y in [strip.minY + 7, strip.maxY - 7 - 10] {
        for x in stride(from: strip.minX + 14, to: strip.maxX - 24, by: 26) {
          ctx.addPath(CGPath(roundedRect: flip(CGRect(x: x, y: y, width: 14, height: 10)), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        }
      }
      ctx.fillPath()
      ctx.setBlendMode(.normal)
    }
    let font = CTFontCreateWithName("Menlo-Bold" as CFString, 15, nil)
    for (i, tile) in tiles.enumerated() where i < layout.cells.count {
      let cell = layout.cells[i]
      ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.04, blue: 0.035, alpha: 1))
      ctx.fill(flip(cell))
      if let image = tile.image {
        let k = min(cell.width / CGFloat(image.width), cell.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * k, height: CGFloat(image.height) * k)
        let fit = CGRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: flip(fit))
      }
      // The frame's number on the rebate above it, as the film's edge print.
      let text = NSAttributedString(string: "▸ " + tile.name, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.98, green: 0.71, blue: 0.4, alpha: 0.9),
      ])
      let line = CTLineCreateWithAttributedString(text)
      ctx.textPosition = CGPoint(x: cell.minX + 4, y: CGFloat(h) - (cell.minY - 7))
      CTLineDraw(line, ctx)
    }
    return ctx.makeImage()
  }
}
