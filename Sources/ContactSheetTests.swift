import AppKit
import Foundation
import ImageIO

enum ContactSheetTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared

    // Layout geometry.
    let cell = CGSize(width: 300, height: 200)
    let strips = ContactSheet.geometry(count: 14, cell: cell, layout: ContactSheet.Layout())
    let bounds = CGRect(origin: .zero, size: strips.size)
    let overlaps = strips.cells.indices.contains { i in
      strips.cells.indices.contains { j in i < j && strips.cells[i].intersects(strips.cells[j]) }
    }
    try check(strips.cells.count == 14 && strips.strips.count == 3 && strips.strips[2].width < strips.strips[0].width
      && strips.cells.allSatisfy { bounds.contains($0) } && !overlaps
      && strips.strips.allSatisfy { s in strips.cells.filter { s.contains($0) }.count == (s == strips.strips[2] ? 2 : 6) },
      "film-strip layout: 6 frames per strip, a short last strip, no overlaps")
    var gridLayout = ContactSheet.Layout()
    gridLayout.style = .grid
    let grid = ContactSheet.geometry(count: 10, cell: cell, layout: gridLayout)
    try check(ContactSheet.columns(count: 10, layout: gridLayout) == 4 && Set(grid.cells.map(\.minY)).count == 3
      && grid.labels.allSatisfy { $0.height > 0 }, "grid layout picks a near-square 4 × 3 for 10 frames")
    gridLayout.columns = 5
    try check(Set(ContactSheet.geometry(count: 10, cell: cell, layout: gridLayout).cells.map(\.minY)).count == 2,
      "a chosen column count is used")
    try check(ContactSheet.cell(for: [CGSize(width: 30, height: 20), CGSize(width: 20, height: 30), CGSize(width: 20, height: 30)])
      == CGSize(width: 20, height: 30), "mostly portrait frames get portrait cells")

    // Every export format writes its own type and depth.
    let sample = try pipe.load(folder.appendingPathComponent("high-precision-test.tif"))
    for format in ExportFormat.allCases {
      let url = folder.appendingPathComponent("format-test.\(format.rawValue).\(format.fileExtension)")
      try? FileManager.default.removeItem(at: url)
      try pipe.export(sample, settings: Adjustments(), profile: FilmProfile.builtins[0], url: url, format: format, dpi: 300)
      let type = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) } as String?
      let info = pipe.info(url)
      try check(type == format.type.identifier && info.bits == (format.sixteenBit ? 16 : 8) && Int(info.dpi) == 300,
        "\(format.title) export writes \(format.type.identifier) at \(format.sixteenBit ? 16 : 8) bits")
    }

    // Settings persist in their suite, and an in-memory set never writes.
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let saved = Preferences(defaults: defaults)
    saved.libraryPath = folder.path
    saved.exportFormat = .png
    saved.jpegQuality = 0.8
    saved.sheet.style = .grid
    saved.sheet.columns = 7
    let reloaded = Preferences(defaults: defaults)
    try check(reloaded.libraryURL.path == folder.path && reloaded.exportFormat == .png && reloaded.jpegQuality == 0.8
      && reloaded.sheet.style == .grid && reloaded.sheet.columns == 7, "settings survive a restart")
    let memory = Preferences()
    memory.exportFormat = .jpeg
    try check(Preferences().exportFormat == .tiff && memory.libraryURL == Preferences.defaultLibraryURL,
      "settings without a store stay in memory with defaults")

    // A synthetic roll: holder, orange film base, four frames.
    let roll = folder.appendingPathComponent("contact-roll", isDirectory: true)
    try? FileManager.default.removeItem(at: roll)
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    let ow = 1500, oh = 800
    let ctx = CGContext(
      data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func fill(_ r: CGRect, _ c: [CGFloat]) {
      ctx.setFillColor(red: c[0], green: c[1], blue: c[2], alpha: 1)
      ctx.fill(CGRect(x: r.minX, y: CGFloat(oh) - r.maxY, width: r.width, height: r.height))
    }
    fill(CGRect(x: 0, y: 0, width: ow, height: oh), [0.06, 0.06, 0.06])
    fill(CGRect(x: 60, y: 260, width: 1380, height: 280), [0.80, 0.52, 0.33])
    for i in 0..<4 {
      let x = 90 + CGFloat(i) * 340
      fill(CGRect(x: x, y: 293, width: 320, height: 120), [0.62, 0.38, 0.26])
      fill(CGRect(x: x, y: 413, width: 320, height: 94), [0.42, 0.33, 0.30])
    }
    let overviewURL = roll.appendingPathComponent("overview.png")
    try pipe.savePNG(ctx.makeImage()!, to: overviewURL)
    var frames = (0..<4).map { i in
      FilmFrame(name: String(format: "%02d", i + 1),
        rect: NormalRect(x: (90 + Double(i) * 340) / 1500, y: 293.0 / 800, width: 320.0 / 1500, height: 214.0 / 800),
        format: "135")
    }
    frames[3].adjustments.rotation = 1
    let project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 600, physicalWidthMM: 63.5, physicalHeightMM: 33.9,
      filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: frames)
    let projectURL = roll.appendingPathComponent("Session.epscan")
    try JSONEncoder().encode(project).write(to: projectURL)
    let model = AppModel(libraryURL: roll)
    model.loadProject(projectURL)

    // The contact view's print: frames positive, unexposed base black, holder white paper.
    let overview = try pipe.load(overviewURL)
    guard let print = pipe.contactPrint(overview, frames: model.frames, profile: model.profile) else {
      throw DeskError.message("FAIL: contact print rendered")
    }
    let raw = pipe.raster(overview, maxDimension: 1500), printed = pipe.raster(print, maxDimension: 1500)
    let rebate = printed.pixel(75, 400).values.max()!, holder = printed.pixel(20, 20).values.min()!
    let frameChanged = (0..<3).contains { abs(printed.pixel(250, 350).values[$0] - raw.pixel(250, 350).values[$0]) > 0.1 }
    try check(print.width == ow && print.height == oh && rebate < 0.15 && holder > 0.85 && frameChanged,
      String(format: "contact print: base %.2f (black), holder %.2f (white), frames converted", rebate, holder))

    // End to end, from the existing previews (no scanner): strips as JPEG, grid as 16-bit TIFF.
    func compose(_ format: ExportFormat, _ name: String, fromPreview: Bool = false) throws -> URL {
      let url = roll.appendingPathComponent(name)
      var finished = false, failure: Error?
      model.composeContactSheet(ids: model.frames.map(\.id), to: url, format: format, fromPreview: fromPreview) { error in
        finished = true
        failure = error
      }
      let deadline = Date().addingTimeInterval(30)
      while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
      if let failure { throw failure }
      try check(finished, "contact sheet \(name) finishes")
      return url
    }
    // Previews are 600 dpi here, so each frame prints 2× larger at 1200 dpi.
    let sizes = try model.frames.map { f -> CGSize in
      let s = try model.source(for: f, full: true)
      let w = CGFloat(s.width) * 2, h = CGFloat(s.height) * 2
      return f.adjustments.rotation % 2 == 1 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
    let expected = ContactSheet.geometry(count: 4, cell: ContactSheet.cell(for: sizes), layout: model.preferences.sheet).size
    let jpeg = try compose(.jpeg, "sheet-strips.jpg")
    let jpegInfo = pipe.info(jpeg)
    try check(jpegInfo.width == Int(expected.width) && jpegInfo.height == Int(expected.height) && jpegInfo.bits == 8
      && Int(jpegInfo.dpi) == ContactSheet.scanDPI,
      "film-strip contact sheet: \(jpegInfo.width) × \(jpegInfo.height) JPEG at 1200 dpi")
    // Straight from the preview: nothing to scan, the sheet at the preview's own resolution.
    try check(model.contactSheetScans(model.frames).isEmpty, "by default a contact sheet scans nothing first")
    model.preferences.sheet.resolution = .scan
    try check(model.contactSheetScans(model.frames).count == model.frames.filter { $0.sourcePath == nil }.count,
      "at 1200 dpi it scans the frames not yet scanned at 1200 dpi first")
    model.preferences.sheet.resolution = .preview
    let previewSizes = sizes.map { CGSize(width: $0.width / 2, height: $0.height / 2) }
    let direct = pipe.info(try compose(.jpeg, "sheet-preview.jpg", fromPreview: true))
    let directExpected = ContactSheet.geometry(count: 4, cell: ContactSheet.cell(for: previewSizes), layout: model.preferences.sheet).size
    try check(direct.width == Int(directExpected.width) && direct.height == Int(directExpected.height) && Int(direct.dpi) == Int(model.overviewDPI),
      "from the preview the sheet is made at the preview's \(Int(model.overviewDPI)) dpi, not enlarged: \(direct.width) × \(direct.height)")
    // The strip's rebate prints black between frames; the paper around it stays light.
    let sheet = pipe.raster(try pipe.load(jpeg), maxDimension: 2000)
    let layout = ContactSheet.geometry(count: 4, cell: ContactSheet.cell(for: sizes), layout: model.preferences.sheet)
    let margin = sheet.pixel(3, 3).values.min()!, strip = layout.strips[0]
    let scale = Double(sheet.width) / Double(jpegInfo.width)
    // Midway between the strip's left edge and its first frame, at mid height: pure rebate.
    let rebateX = (strip.minX + layout.cells[0].minX) / 2
    let rebateInk = sheet.pixel(Int(rebateX * scale), Int(strip.midY * scale)).values.max()!
    try check(margin > 0.85 && rebateInk < 0.15, "white paper around a black film rebate")
    model.preferences.sheet.style = .grid
    model.preferences.sheet.whitePaper = false
    let tiff = try compose(.tiff, "sheet-grid.tif")
    let gridExpected = ContactSheet.geometry(count: 4, cell: ContactSheet.cell(for: sizes), layout: model.preferences.sheet).size
    let tiffInfo = pipe.info(tiff)
    try check(tiffInfo.width == Int(gridExpected.width) && tiffInfo.height == Int(gridExpected.height) && tiffInfo.bits == 16
      && !pipe.storesAlpha(tiff) && !pipe.storesAlpha(jpeg),
      "grid contact sheet: \(tiffInfo.width) × \(tiffInfo.height) 16-bit TIFF, RGB without alpha")
    model.composeContactSheet(ids: [], to: roll.appendingPathComponent("empty.jpg"), format: .jpeg)
    let deadline = Date().addingTimeInterval(5)
    while model.exporting && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    try check(model.errorText != nil && !FileManager.default.fileExists(atPath: roll.appendingPathComponent("empty.jpg").path),
      "an empty contact sheet is refused without writing a file")
    model.errorText = nil
  }
}
