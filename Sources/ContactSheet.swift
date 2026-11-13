import AppKit
import CoreImage

/// Contact sheet export: the ticked frames as film strips or a grid, straight from the preview at
/// its own resolution, or printed at 1200 dpi from scans made for it first.
enum ContactSheet {
  static let scanDPI = 1200
  enum Resolution: String, Codable, CaseIterable { case preview, scan }
  struct Layout: Codable, Equatable {
    enum Style: String, Codable, CaseIterable { case strips, grid }
    var style = Style.strips
    /// Frames per strip or row; 0 picks 6 per strip, or a near-square grid.
    var columns = 0
    var whitePaper = true
    var numbers = true
    var title = true
    /// Apply each frame's rotation; off keeps every frame the way it lies on the film.
    var followRotation = true
    /// From the preview (nil, as before this setting) or scanned at 1200 dpi first.
    var resolution: Resolution?
    var scansFirst: Bool { resolution == .scan }
    /// The roll's film drawn in the heading, its cassette or 120 roll as the film shelf shows it;
    /// nil in settings from before it could be.
    var film: Bool?
    var showsFilm: Bool {
      get { film == true }
      set { film = newValue }
    }
    /// In strips, each strip printed as the film's black rebate with its perforations, the frame
    /// numbers and film code on it; off, the frames lie straight on the paper. Nil, as before this
    /// setting, is on.
    var sprockets: Bool?
    var showsSprockets: Bool {
      get { sprockets ?? true }
      set { sprockets = newValue ? nil : false }
    }
  }
  /// The film's picture's width over its height, as the shelf draws it.
  static let filmAspect: CGFloat = 0.76
  /// Rectangles in pixels with a top-left origin.
  struct Geometry {
    var size: CGSize
    var cells: [CGRect]
    var strips: [CGRect]
    /// Below each cell: the frame number. Above each strip cell: the film's edge print.
    var labels: [CGRect]
    var edgePrints: [CGRect]
    var title: CGRect?
    /// In the heading, left of the title: the roll's film.
    var film: CGRect?
  }
  /// One frame to print: `source` is the cropped scan, `dpi` its resolution.
  struct Tile {
    var name: String
    var settings: Adjustments
    var dpi: Double
    var source: () throws -> CGImage
    var sharpener: Sharpener? = nil
    /// The size `source` gives, where it is known without reading the pixels.
    var size: (() -> CGSize?)? = nil
  }

  static func columns(count: Int, layout: Layout) -> Int {
    if layout.columns > 0 { return layout.columns }
    return layout.style == .strips
      ? min(6, max(1, count)) : max(1, Int(Double(max(1, count)).squareRoot().rounded(.up)))
  }
  /// One cell fits every frame: landscape unless most frames are portrait.
  static func cell(for sizes: [CGSize]) -> CGSize {
    let long = (sizes.map { max($0.width, $0.height) }.max() ?? 1).rounded()
    let short = (sizes.map { min($0.width, $0.height) }.max() ?? 1).rounded()
    let portrait = sizes.filter { $0.height > $0.width }.count * 2 > sizes.count
    return portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
  }
  /// With `sizes`, each frame's own size as it prints: in strips each cell is as wide as its frame
  /// fitted in `cell`, so a frame turned the other way leaves no black rebate beside it.
  static func geometry(count: Int, cell: CGSize, layout: Layout, sizes: [CGSize]? = nil) -> Geometry {
    let cols = columns(count: count, layout: layout)
    let rows = max(1, Int((Double(count) / Double(cols)).rounded(.up)))
    // Proportions follow 135 film, with u as the 24 mm frame height.
    let u = min(cell.width, cell.height)
    func px(_ f: CGFloat) -> CGFloat { (f * u).rounded() }
    let margin = px(0.35)
    let titleHeight = layout.title ? px(0.3) : 0
    // The film's picture, as tall as about three quarters of a frame, the title beside it.
    let filmHeight = layout.showsFilm ? px(0.75) : 0, filmWidth = (filmHeight * filmAspect).rounded()
    let heading = max(titleHeight, filmHeight)
    let top = margin + (heading > 0 ? heading + px(0.15) : 0)
    var g = Geometry(size: .zero, cells: [], strips: [], labels: [], edgePrints: [], title: nil)
    switch layout.style {
    case .strips:
      // About 5.5 mm of rebate either side of the frame and 2 mm between frames; without the
      // rebate, room for the frame number under it.
      let rebate = layout.showsSprockets ? px(0.23) : (layout.numbers ? px(0.11) : px(0.02))
      let gap = px(0.085), pad = layout.showsSprockets ? px(0.12) : 0, stripGap = px(0.25)
      let stripHeight = cell.height + 2 * rebate
      func width(_ i: Int) -> CGFloat {
        guard let s = sizes?[i], s.width > 0, s.height > 0 else { return cell.width }
        return (s.width * min(cell.width / s.width, cell.height / s.height, 1)).rounded()
      }
      for r in 0..<rows {
        let n = min(cols, count - r * cols)
        let y = top + CGFloat(r) * (stripHeight + stripGap)
        var x = margin + pad
        for c in 0..<n {
          let w = width(r * cols + c)
          let cellRect = CGRect(x: x, y: y + rebate, width: w, height: cell.height)
          g.cells.append(cellRect)
          g.labels.append(CGRect(x: cellRect.minX, y: cellRect.maxY + px(0.012), width: w, height: layout.showsSprockets ? px(0.07) : px(0.09)))
          g.edgePrints.append(CGRect(x: cellRect.minX, y: cellRect.minY - px(0.082), width: w, height: px(0.07)))
          x += w + gap
        }
        g.strips.append(CGRect(x: margin, y: y, width: x - gap + pad - margin, height: stripHeight))
      }
      g.size = CGSize(
        width: (g.strips.map(\.maxX).max() ?? margin) + margin,
        height: top + CGFloat(rows) * stripHeight + CGFloat(rows - 1) * stripGap + margin)
    case .grid:
      let gap = px(0.12), label = layout.numbers ? px(0.2) : 0
      for i in 0..<count {
        let x = margin + CGFloat(i % cols) * (cell.width + gap)
        let y = top + CGFloat(i / cols) * (cell.height + label + gap)
        g.cells.append(CGRect(x: x, y: y, width: cell.width, height: cell.height))
        g.labels.append(CGRect(x: x, y: y + cell.height, width: cell.width, height: label))
      }
      g.size = CGSize(
        width: CGFloat(cols) * cell.width + CGFloat(cols - 1) * gap + 2 * margin,
        height: top + CGFloat(rows) * (cell.height + label) + CGFloat(rows - 1) * gap + margin)
    }
    if layout.showsFilm { g.film = CGRect(x: margin, y: margin, width: filmWidth, height: filmHeight) }
    if layout.title {
      let x = margin + (layout.showsFilm ? filmWidth + px(0.15) : 0)
      g.title = CGRect(x: x, y: margin + ((heading - titleHeight) / 2).rounded(), width: g.size.width - margin - x, height: titleHeight)
    }
    return g
  }

  /// Renders and writes the sheet at `dpi`, returning its pixel size. Frames are rendered one at a
  /// time, so memory holds the sheet and a single frame.
  @discardableResult
  static func export(
    _ tiles: [Tile], profile: FilmProfile, layout: Layout, title: String, filmCode: String, to url: URL,
    format: ExportFormat, quality: Double, dpi: Int = scanDPI, film: ((CGSize) -> CGImage?)? = nil,
    progress: ((Int) throws -> Void)? = nil
  ) throws -> CGSize {
    guard !tiles.isEmpty else { throw DeskError.message("没有可放进接触表的画面。") }
    let pipe = ImagePipeline.shared
    func settings(_ t: Tile) -> Adjustments {
      var s = t.settings
      if !layout.followRotation { s.rotation = 0 }
      return s
    }
    // First pass: each frame's printed size at the sheet's resolution, without rendering pixels.
    // A frame's size from its file's header where that tells it: the frames were decoded here
    // once just for it, a second for a 61-megapixel copy, and again to be drawn.
    let pixels = try tiles.map { t -> CGSize in
      if let known = t.size?() { return known }
      let image = try t.source()
      return CGSize(width: image.width, height: image.height)
    }
    func sized(_ dpi: Double) -> [CGSize] {
      zip(tiles, pixels).map { t, p in
        let scale = dpi / max(1, t.dpi)
        let sideways = ((settings(t).rotation % 4) + 4) % 2 == 1
        let w = Double(p.width) * scale, h = Double(p.height) * scale
        return sideways ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
      }
    }
    // At the resolution asked for, unless its file would pass the limit: then as fine as it fits,
    // the sheet's whole layout scaling with it (a copy roll's preview is thousands of dpi).
    var sheetDPI = Double(dpi)
    var sizes = sized(sheetDPI)
    var cell = Self.cell(for: sizes)
    var g = geometry(count: tiles.count, cell: cell, layout: layout, sizes: sizes)
    let shrink = Self.fitting(Double(g.size.width * g.size.height), format: format, quality: quality)
    if shrink < 1 {
      sheetDPI *= shrink
      sizes = sized(sheetDPI)
      cell = Self.cell(for: sizes)
      g = geometry(count: tiles.count, cell: cell, layout: layout, sizes: sizes)
    }
    let dpi = max(1, Int(sheetDPI.rounded()))
    let width = Int(g.size.width), height = Int(g.size.height)
    let bits = format.sixteenBit ? 16 : 8
    guard Double(width) * Double(height) * Double(bits / 2) < 3e9 else {
      throw DeskError.message("接触表过大（\(width) × \(height)），请减少张数，或改用 8-bit 格式。")
    }
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: pipe.outputSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0))
    else { throw DeskError.message("无法分配接触表画布。") }
    func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height) }
    let u = min(cell.width, cell.height)
    let paper = layout.whitePaper ? NSColor(srgbRed: 0.96, green: 0.955, blue: 0.94, alpha: 1) : NSColor(white: 0.04, alpha: 1)
    let ink = layout.whitePaper ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.82, alpha: 1)
    let edgeInk = NSColor(srgbRed: 0.93, green: 0.85, blue: 0.7, alpha: 1)
    ctx.setFillColor(paper.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Film rebate prints black on a contact sheet; perforations show faintly.
    for s in g.strips where layout.showsSprockets {
      ctx.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor)
      ctx.fill(flip(s))
      ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
      let hole = CGSize(width: 0.117 * u, height: 0.0825 * u)
      for x in stride(from: s.minX + 0.06 * u, to: s.maxX - hole.width, by: 0.198 * u) {
        for y in [s.minY + 0.06 * u, s.maxY - 0.06 * u - hole.height] {
          ctx.addPath(CGPath(roundedRect: flip(CGRect(origin: CGPoint(x: x, y: y), size: hole)),
            cornerWidth: 0.015 * u, cornerHeight: 0.015 * u, transform: nil))
        }
      }
      ctx.fillPath()
    }
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    func text(_ string: String, in rect: CGRect, size: CGFloat, color: NSColor, mono: Bool) {
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = graphics
      let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size, weight: .medium)
      NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        .draw(with: flip(rect), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
      NSGraphicsContext.restoreGraphicsState()
    }
    if let r = g.title { text(title, in: r, size: 0.14 * u, color: ink, mono: false) }
    // The roll's film, rendered at the size it prints (within reason) and fitted to its place.
    if let r = g.film, let picture = film?(CGSize(width: min(r.width, 1800 * filmAspect), height: min(r.height, 1800))) {
      let k = min(r.width / CGFloat(picture.width), r.height / CGFloat(picture.height))
      let w = (CGFloat(picture.width) * k).rounded(), h = (CGFloat(picture.height) * k).rounded()
      ctx.interpolationQuality = .high
      ctx.draw(picture, in: flip(CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)))
    }
    for (i, t) in tiles.enumerated() {
      // Before each frame: the frame about to be drawn, and the chance to stop.
      try progress?(i)
      try autoreleasepool {
        var ci = try pipe.output(try t.source(), settings: settings(t), profile: profile, sharpener: t.sharpener)
        let fit = min(cell.width / sizes[i].width, cell.height / sizes[i].height, 1)
        let scale = sheetDPI / max(1, t.dpi) * fit
        if abs(scale - 1) > 0.0005, let lanczos = CIFilter(name: "CILanczosScaleTransform") {
          lanczos.setValue(ci, forKey: kCIInputImageKey)
          lanczos.setValue(scale, forKey: kCIInputScaleKey)
          lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
          ci = lanczos.outputImage ?? ci
        }
        guard
          let frame = pipe.context.createCGImage(
            ci, from: ci.extent.integral, format: bits == 16 ? .RGBA16 : .RGBA8, colorSpace: pipe.outputSpace)
        else { throw DeskError.message("无法渲染第 \(t.name) 张。") }
        let c = g.cells[i]
        let w = CGFloat(frame.width), h = CGFloat(frame.height)
        ctx.draw(frame, in: flip(CGRect(x: (c.midX - w / 2).rounded(), y: (c.midY - h / 2).rounded(), width: w, height: h)))
      }
      if layout.numbers {
        // On the rebate as the film's edge print; on the paper in the paper's ink.
        let onRebate = layout.style == .strips && layout.showsSprockets
        text(onRebate ? "▸ \(t.name)" : t.name, in: g.labels[i], size: (onRebate ? 0.055 : layout.style == .strips ? 0.06 : 0.11) * u,
          color: onRebate ? edgeInk : ink, mono: true)
      }
      if layout.style == .strips, layout.showsSprockets, !filmCode.isEmpty {
        text(filmCode, in: g.edgePrints[i], size: 0.055 * u, color: edgeInk, mono: true)
      }
    }
    guard let sheet = ctx.makeImage() else { throw DeskError.message("无法生成接触表。") }
    try pipe.write(sheet, to: url, format: format, dpi: dpi, quality: quality)
    // The estimate a little short for this sheet: written smaller again until it fits.
    var written = CGSize(width: sheet.width, height: sheet.height)
    for _ in 0..<4 {
      guard let bytes = Self.fileBytes(url), bytes > Self.fileLimit else { break }
      let k = (Self.fileLimit / bytes).squareRoot() * 0.95
      let scale = Double(written.width) * k / Double(sheet.width)
      let ci = CIImage(cgImage: sheet).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
      guard let smaller = pipe.context.createCGImage(ci, from: ci.extent.integral, format: bits == 16 ? .RGBA16 : .RGBA8, colorSpace: pipe.outputSpace) else { break }
      written = CGSize(width: smaller.width, height: smaller.height)
      try pipe.write(smaller, to: url, format: format, dpi: max(1, Int((Double(dpi) * Double(smaller.width) / Double(sheet.width)).rounded())), quality: quality)
    }
    return written
  }
  /// What a contact sheet's file may take: a sheet is for sending and sharing, 10 MB.
  static let fileLimit = 10_000_000.0
  /// How much a sheet of `area` pixels is made smaller (in each direction) for its file to fit
  /// `fileLimit` in `format`: 1 when it fits as it is.
  static func fitting(_ area: Double, format: ExportFormat, quality: Double) -> Double {
    // A little under the limit: the file's header, its colour profile and its metadata come on top.
    let budget = fileLimit * 0.97 / bytesPerPixel(format, quality: quality)
    return area > budget ? (budget / area).squareRoot() : 1
  }
  /// A sheet's bytes a pixel in `format`, as `ExportEstimate` has a film scan's, four fifths of it:
  /// the paper and rebate between the frames compress well.
  static func bytesPerPixel(_ format: ExportFormat, quality: Double) -> Double {
    let scan = ExportEstimate.bytes(CGSize(width: 1000, height: 1000), format: format, quality: quality) / 1_000_000
    return format == .tiff || format == .tiff8 ? scan : scan * 0.8
  }
  static func fileBytes(_ url: URL) -> Double? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).map { $0.doubleValue }
  }
}
