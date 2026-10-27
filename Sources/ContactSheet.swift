import AppKit
import CoreImage

/// Contact sheet export: the ticked frames printed at 1200 dpi, as film strips or a grid.
enum ContactSheet {
  static let scanDPI = 1200
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
  }
  /// Rectangles in pixels with a top-left origin.
  struct Geometry {
    var size: CGSize
    var cells: [CGRect]
    var strips: [CGRect]
    /// Below each cell: the frame number. Above each strip cell: the film's edge print.
    var labels: [CGRect]
    var edgePrints: [CGRect]
    var title: CGRect?
  }
  /// One frame to print: `source` is the cropped scan, `dpi` its resolution.
  struct Tile {
    var name: String
    var settings: Adjustments
    var dpi: Double
    var source: () throws -> CGImage
    var sharpener: Sharpener? = nil
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
  static func geometry(count: Int, cell: CGSize, layout: Layout) -> Geometry {
    let cols = columns(count: count, layout: layout)
    let rows = max(1, Int((Double(count) / Double(cols)).rounded(.up)))
    // Proportions follow 135 film, with u as the 24 mm frame height.
    let u = min(cell.width, cell.height)
    func px(_ f: CGFloat) -> CGFloat { (f * u).rounded() }
    let margin = px(0.35)
    let titleHeight = layout.title ? px(0.3) : 0
    let top = margin + (layout.title ? titleHeight + px(0.15) : 0)
    var g = Geometry(size: .zero, cells: [], strips: [], labels: [], edgePrints: [], title: nil)
    switch layout.style {
    case .strips:
      // About 5.5 mm of rebate either side of the frame and 2 mm between frames.
      let rebate = px(0.23), gap = px(0.085), pad = px(0.12), stripGap = px(0.25)
      let stripHeight = cell.height + 2 * rebate
      for r in 0..<rows {
        let n = min(cols, count - r * cols)
        let y = top + CGFloat(r) * (stripHeight + stripGap)
        g.strips.append(
          CGRect(x: margin, y: y, width: CGFloat(n) * cell.width + CGFloat(n - 1) * gap + 2 * pad, height: stripHeight))
        for c in 0..<n {
          let cellRect = CGRect(
            x: margin + pad + CGFloat(c) * (cell.width + gap), y: y + rebate, width: cell.width, height: cell.height)
          g.cells.append(cellRect)
          g.labels.append(CGRect(x: cellRect.minX, y: cellRect.maxY + px(0.012), width: cell.width, height: px(0.07)))
          g.edgePrints.append(CGRect(x: cellRect.minX, y: cellRect.minY - px(0.082), width: cell.width, height: px(0.07)))
        }
      }
      g.size = CGSize(
        width: CGFloat(cols) * cell.width + CGFloat(cols - 1) * gap + 2 * pad + 2 * margin,
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
    if layout.title { g.title = CGRect(x: margin, y: margin, width: g.size.width - 2 * margin, height: titleHeight) }
    return g
  }

  /// Renders and writes the sheet, returning its pixel size. Frames are rendered one at a time,
  /// so memory holds the sheet and a single frame.
  @discardableResult
  static func export(
    _ tiles: [Tile], profile: FilmProfile, layout: Layout, title: String, filmCode: String, to url: URL,
    format: ExportFormat, quality: Double
  ) throws -> CGSize {
    guard !tiles.isEmpty else { throw DeskError.message("没有可放进接触表的画面。") }
    let pipe = ImagePipeline.shared
    func settings(_ t: Tile) -> Adjustments {
      var s = t.settings
      if !layout.followRotation { s.rotation = 0 }
      return s
    }
    // First pass: each frame's printed size at 1200 dpi, without rendering pixels.
    let sizes = try tiles.map { t -> CGSize in
      let image = try t.source()
      let scale = Double(scanDPI) / max(1, t.dpi)
      let sideways = ((settings(t).rotation % 4) + 4) % 2 == 1
      let w = Double(image.width) * scale, h = Double(image.height) * scale
      return sideways ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
    let cell = Self.cell(for: sizes)
    let g = geometry(count: tiles.count, cell: cell, layout: layout)
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
    for s in g.strips {
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
    for (i, t) in tiles.enumerated() {
      try autoreleasepool {
        var ci = try pipe.output(try t.source(), settings: settings(t), profile: profile, sharpener: t.sharpener)
        let fit = min(cell.width / sizes[i].width, cell.height / sizes[i].height, 1)
        let scale = Double(scanDPI) / max(1, t.dpi) * fit
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
        let strips = layout.style == .strips
        text(strips ? "▸ \(t.name)" : t.name, in: g.labels[i], size: (strips ? 0.055 : 0.11) * u,
          color: strips ? edgeInk : ink, mono: true)
      }
      if layout.style == .strips, !filmCode.isEmpty {
        text(filmCode, in: g.edgePrints[i], size: 0.055 * u, color: edgeInk, mono: true)
      }
    }
    guard let sheet = ctx.makeImage() else { throw DeskError.message("无法生成接触表。") }
    try pipe.write(sheet, to: url, format: format, dpi: scanDPI, quality: quality)
    return g.size
  }
}
