import AppKit
import Foundation

enum RegressionTests {
  static func run(folder: URL) throws {
    _ = NSApplication.shared
    // The positives the library keeps go with the test's files, not into the user's caches.
    RollLibrary.cacheRoot = folder.appendingPathComponent("roll-thumbnails")
    try ScanProgressTests.run(folder: folder)
    try SaneScannerTests.run(folder: folder)
    try OrientationTests.run(folder: folder)
    try MultiSelectTests.run(folder: folder)
    try ExportFlowTests.run(folder: folder)
    try WindowGateTests.run(folder: folder)
    try LeakFixTests.run(folder: folder)
    try StepTests.run(folder: folder)
    try StraightenTests.run(folder: folder)
    try ToneTests.run(folder: folder)
    try HighlightTests.run(folder: folder)
    try AutoAdjustTests.run(folder: folder)
    try ContactSheetTests.run(folder: folder)
    try SharpeningTests.run(folder: folder)
    try FilmBaseTests.run(folder: folder)
    try CalibrationTests.run(folder: folder)
    try RollCurveTests.run(folder: folder)
    try FilmCurveTests.run(folder: folder)
    try DataSheetTests.run(folder: folder)
    try IT8Tests.run(folder: folder)
    try LightTableTests.run(folder: folder)
    try LoupeTests.run(folder: folder)
    try WorkflowTests.run(folder: folder)
    try UsabilityTests.run(folder: folder)
    try CanvasTests.run(folder: folder)
    try LibraryTests.run(folder: folder)
    try RollGroupTests.run(folder: folder)
    try ContactPageTests.run(folder: folder)
    try PresetTableTests.run(folder: folder)
    try PixelShiftTests.run(folder: folder)
    try CameraTests.run(folder: folder)
    try EdgeBaseTests.run(folder: folder)
    try PhotoInfoTests.run(folder: folder)
    try NewProjectTests.run(folder: folder)
    try AnalysisRegionTests.run(folder: folder)
    try UIDayTests.run(folder: folder)
    try FollowedRegionTests.run(folder: folder)
    try ReversalTests.run(folder: folder)
    try OriginalViewTests.run(folder: folder)
    try ProxyTests.run(folder: folder)
    try CopyLightTests.run(folder: folder)
    try DustTests.run(folder: folder)
    try FrameCropTests.run(folder: folder)
    try RollPrintTests.run(folder: folder)
    try CameraSimulationTests.run(folder: folder)
    try SonyPTPTests.run(folder: folder)
    try RowScanTests.run(folder: folder)
    try LevelRegistrationTests.run(folder: folder)
    try MCPTests.run(folder: folder)
    try LightLeakTests.run(folder: folder)
    try LightLeakEdgesTests.run(folder: folder)
    try UpdaterTests.run(folder: folder)
    try RenderTests.run(folder: folder)
    try Render3DTests.run(folder: folder)
    try ProjectFormatTests.run(folder: folder)
    try BaseChecksTests.run(folder: folder)
    try PreviewExportTests.run(folder: folder)
    try SectionOrderTests.run(folder: folder)
    try AppIconTests.run()
    let pipe = ImagePipeline.shared
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }
      print("PASS: " + label)
    }
    try check(
      Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "Epson Scan plus"
        && Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
          == "Epson Scan plus"
        && Bundle.main.executableURL?.lastPathComponent == "EpsonScanPlus",
      "renamed application has matching display name and executable")
    func makeImage(_ width: Int, _ height: Int, _ sample: (Int, Int) -> RGB) -> CGImage {
      var bytes = [UInt8](repeating: 255, count: width * height * 4)
      for y in 0..<height {
        for x in 0..<width {
          let p = sample(x, y).values
          for c in 0..<3 { bytes[(y * width + x) * 4 + c] = UInt8((clamp(p[c]) * 255).rounded()) }
        }
      }
      return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    let profile = FilmProfile.builtins[0]
    let base = RGB(r: 0.85, g: 0.57, b: 0.38)
    let fractional = NormalRect(x: 0.105, y: 0.105, width: 0.79, height: 0.79)
      .pixels(CGSize(width: 100, height: 100))
    try check(
      fractional == CGRect(x: 11, y: 11, width: 78, height: 78),
      "crop rounding never reintroduces outside edge pixels")
    // The same image with a wide edge-connected film base, white leak and holder border.
    let content = makeImage(240, 320) { x, y in
      let value = Double((x * 17 + y * 29) % 61) / 255
      return RGB(r: 0.35 + value, g: 0.18 + value * 0.8, b: 0.1 + value * 0.65)
    }
    let cleanRaster = pipe.raster(content)
    let contaminated = makeImage(240, 320) { x, y in
      if x < 9 { return RGB(r: 0.01, g: 0.01, b: 0.01) }
      if x >= 231 { return .one }
      if y < 12 || y >= 308 { return base }
      return cleanRaster.pixel(x, y)
    }
    let cleanAnalysis = pipe.analyze(content, settings: Adjustments(), profile: profile)
    let dirtyAnalysis = pipe.analyze(contaminated, settings: Adjustments(), profile: profile)
    try check(
      zip(cleanAnalysis.base.values, dirtyAnalysis.base.values).allSatisfy { abs($0 - $1) < 0.006 }
        && abs(cleanAnalysis.high - dirtyAnalysis.high) < 0.025,
      "holder, white leak and orange border do not bias automatic color statistics")
    let contentBounds = FilmEdges.contentBounds(
      pipe.raster(contaminated), within: CGRect(x: 0, y: 0, width: 240, height: 320), base: base)
    try check(
      contentBounds.minX >= 9 && contentBounds.maxX <= 231
        && contentBounds.minY >= 12 && contentBounds.maxY <= 308
        && contentBounds.area > 222 * 296 * 0.95,
      "edge refinement removes known border bands without excessive image loss: \(contentBounds)")
    let centerBright = makeImage(240, 320) { x, y in
      (x > 70 && x < 170 && y > 90 && y < 230) ? base : cleanRaster.pixel(x, y)
    }
    let centerBounds = FilmEdges.contentBounds(
      pipe.raster(centerBright), within: CGRect(x: 0, y: 0, width: 240, height: 320), base: base)
    try check(
      centerBounds == CGRect(x: 1, y: 1, width: 238, height: 318),
      "bright image content is not mistaken for an edge-connected film gap")
    let mixedEdge = makeImage(240, 320) { x, y in
      if y >= 308 {
        let blend = 0.2 + 0.6 * Double(x) / 239
        return RGB(base.values.map { $0 * (1 - blend) + blend })
      }
      return cleanRaster.pixel(x, y)
    }
    let mixedBounds = FilmEdges.contentBounds(
      pipe.raster(mixedEdge), within: CGRect(x: 0, y: 0, width: 240, height: 320), base: base)
    try check(
      mixedBounds.maxY <= 308, "mixed clear/base transmission at a slanted film end is excluded")
    // Stretching each channel to the scene corrects crossover with the generic preset; a named
    // preset trusts its own channel slopes instead (see ToneTests).
    let stretch = FilmProfile.builtins.first { $0.id == "generic" }!
    let neutral = makeImage(512, 64) { x, _ in
      let density = Double(x) / 511 * 2.8 + 0.2
      let factors = [0.75, 1.08, 1.35]
      return RGB(
        (0..<3).map {
          base.values[$0] * pow(10, -density * factors[$0] * stretch.slopes.values[$0] / 2.2)
        })
    }
    var settings = Adjustments()
    settings.base = base
    let corrected = pipe.raster(
      try pipe.preview(neutral, settings: settings, profile: stretch), maxDimension: 512)
    for x in [100, 256, 400] {
      let p = corrected.pixel(x, 32).values
      try check(
        p.max()! - p.min()! < 0.035, "WB neutral ramp has no shadow/highlight cyan cast at \(x)")
    }
    let before = corrected.pixel(256, 32)
    settings.baseFine = RGB(r: 0.2, g: 0, b: 0)
    let fine = pipe.raster(
      try pipe.preview(neutral, settings: settings, profile: stretch), maxDimension: 512
    ).pixel(256, 32)
    try check(
      fine.r > before.r + 0.06 && abs(fine.g - before.g) < 0.01,
      "manual film-base red trim survives automatic WB/levels")
    settings.baseFine = nil
    settings.autoWhiteBalance = false
    settings.neutralSample = pipe.raster(neutral, maxDimension: 512).pixel(256, 32)
    let picked = pipe.raster(
      try pipe.preview(neutral, settings: settings, profile: stretch), maxDimension: 512
    ).pixel(256, 32).values
    try check(
      picked.max()! - picked.min()! < 0.012, "neutral picker anchors sampled negative values")
    settings.neutralSample = nil
    settings.autoWhiteBalance = true
    settings.autoLevels = true
    // A frame saved with a highlight point (Dmax, picked until 0.10.0) opens as it was, the point
    // not read.
    var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] ?? [:]
    saved["highlightSample"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RGB(r: 0.1, g: 0.2, b: 0.3)))
    let reopened = try? JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: saved))
    try check(reopened == settings, "a frame saved with a highlight (Dmax) point opens as it was, without the point")
    // A picture taken after earlier ones were deleted takes the number past the highest, not one in
    // use; a roll saved with repeats (up to 0.11.2) has its later ones renumbered when it opens.
    func named(_ n: String) -> FilmFrame { FilmFrame(name: n, rect: .full, format: "翻拍") }
    var repeats = ["03", "04", "03", "04"].map(named)
    let renamed = AppModel.renumberRepeats(&repeats)
    var distinct = ["01", "02", "05"].map(named)
    try check(AppModel.frameName(after: ["03", "04"].map(named)) == "05" && AppModel.frameName(after: []) == "01"
      && AppModel.frameName(after: ["A", "B"].map(named)) == "03"
      && repeats.map(\.name) == ["03", "04", "05", "06"] && renamed.map(\.from) == ["03", "04"] && renamed.map(\.to) == ["05", "06"]
      && AppModel.renumberRepeats(&distinct).isEmpty && distinct.map(\.name) == ["01", "02", "05"],
      "a new frame is numbered past the roll's highest, and repeated names are renumbered in the roll's order")
    // After a frame is deleted or moved the roll is numbered 01, 02, … in its order again.
    var gappy = ["03", "04", "07"].map(named)
    let moves = AppModel.renumber(&gappy)
    let order = AppModel(libraryURL: folder.appendingPathComponent("renumber", isDirectory: true))
    order.frames = ["01", "02", "03", "04"].map(named).map { var f = $0; f.sourcePath = "/tmp/\(f.name).tif"; return f }
    let ids = order.frames.map(\.id)
    order.moveFrame(ids[3], to: ids[1])
    let moved = order.frames.map(\.id) == [ids[0], ids[3], ids[1], ids[2]] && order.frames.map(\.name) == ["01", "02", "03", "04"]
    order.remove(order.frames[0].id)
    try check(gappy.map(\.name) == ["01", "02", "03"] && moves.count == 3 && moved
      && order.frames.map(\.name) == ["01", "02", "03"] && order.frames.map(\.id) == [ids[3], ids[1], ids[2]],
      "the roll is numbered 01, 02, … in its order: after a gap, after a frame is dragged to another's place, after one is deleted")
    // A slider's figure typed in: the number read past units, full-width figures and a decimal
    // comma; the field starts from the readout's figure, or the value where it shows a word.
    try check(ValueField.number("+0.25°") == 0.25 && ValueField.number("－１，５") == -1.5 && ValueField.number(" 85 % ") == 85
      && ValueField.number("−0.120") == -0.12 && ValueField.number("关") == nil && ValueField.number("1.2.3") == nil
      && ValueField.figure("+1.20°") == "+1.20" && ValueField.figure("97") == "97" && ValueField.figure("关") == nil
      && ValueField.plain(0.35 * 100) == "35",
      "a slider's typed figure is read past its units, in full-width figures, with a decimal comma")
    let rawRect = NormalRect(x: 0.15, y: 0.22, width: 0.6, height: 0.51)
    let point = CGPoint(x: 0.19, y: 0.67)
    let orientationFixture = makeImage(80, 60) { x, y in
      RGB(r: x < 40 ? 0.8 : 0.2, g: y < 30 ? 0.7 : 0.3, b: 0.1)
    }
    let expectedSample = pipe.raster(orientationFixture).pixel(15, 40).values
    for rotation in 0..<4 {
      for mirror in [false, true] {
        var s = Adjustments()
        s.rotation = rotation
        s.flipHorizontal = mirror
        let roundTrip = ImageGeometry.raw(ImageGeometry.display(point, settings: s), settings: s)
        let rectangle = ImageGeometry.transform(
          ImageGeometry.transform(rawRect, settings: s), settings: s, inverse: true)
        try check(
          hypot(roundTrip.x - point.x, roundTrip.y - point.y) < 1e-10
            && abs(rectangle.x - rawRect.x) + abs(rectangle.y - rawRect.y)
              + abs(rectangle.width - rawRect.width) + abs(rectangle.height - rawRect.height)
              < 1e-10,
          "crop/picker coordinate round-trip rotation \(rotation), mirror \(mirror)")
        let oriented = pipe.raster(
          pipe.render(
            orientationFixture, settings: s, profile: profile, analysis: nil, negative: true)!)
        let displayPoint = ImageGeometry.display(point, settings: s)
        let actualSample = oriented.pixel(
          Int(displayPoint.x * Double(oriented.width)),
          Int(displayPoint.y * Double(oriented.height))
        ).values
        try check(
          zip(expectedSample, actualSample).allSatisfy { abs($0 - $1) < 0.01 },
          "picker coordinates match rendered pixels rotation \(rotation), mirror \(mirror)")
      }
    }
    let sourceURL = folder.appendingPathComponent("high-precision-test.tif")
    let model = AppModel(libraryURL: folder)
    var frame = FilmFrame(
      name: "test", rect: NormalRect(x: 0.125, y: 0.125, width: 0.5, height: 0.5), format: "135")
    frame.scanPath = sourceURL.path
    frame.scanDPI = 2400
    frame.sourceBits = 16
    model.frames = [frame]
    model.selectedID = frame.id
    model.setRect(frame.id, rect: NormalRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25))
    let crop = try model.source(for: model.frames[0], full: true)
    try check(
      model.frames[0].hasFullResolution && model.frames[0].scanPath == sourceURL.path
        && crop.width == 512 && crop.height == 2 && crop.bitsPerComponent == 16,
      "post-scan crop retains original file and 16-bit precision")
    model.resetCrop()
    try check(
      try model.source(for: model.frames[0], full: true).width == 1024,
      "reset crop restores original captured pixels")
    model.setRect(frame.id, rect: NormalRect(x: 0, y: 0, width: 0.8, height: 0.8))
    try check(
      model.frames[0].needsRescan && !model.frames[0].hasFullResolution
        && model.frames[0].scanPath == sourceURL.path,
      "expanded crop flags rescan without discarding original")
    model.resetCrop()

    // Draw ONLY our own offscreen canvas into a sentinel bitmap, never capture the desktop.
    model.displayed = neutral
    model.zoom = 8
    let view = FilmCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
    view.model = model
    try check(
      view.clipsToBounds && view.wantsDefaultClipping && view.layer?.masksToBounds == true,
      "native view and backing layer both clip")
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    NSColor.magenta.setFill()
    NSRect(x: 0, y: 0, width: 800, height: 600).fill()
    graphics.cgContext.translateBy(x: 240, y: 170)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    var escaped = 0
    for y in stride(from: 0, to: 600, by: 3) {
      for x in stride(from: 0, to: 800, by: 3) where x < 239 || x > 560 || y < 169 || y > 430 {
        let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        if c.redComponent < 0.98 || c.greenComponent > 0.02 || c.blueComponent < 0.98 {
          escaped += 1
        }
      }
    }
    try check(escaped == 0, "8× zoom draws zero pixels outside canvas (\(escaped) escaped)")
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: folder.appendingPathComponent("canvas-clipping.png"))
    view.pan = CGPoint(x: 99999, y: -99999)
    view.clampPan()
    try check(abs(view.pan.x) < 2000 && abs(view.pan.y) < 2000, "pan is bounded at high zoom")

    // Exercise single-frame context and actual picker routing without sending OS input events.
    let overviewURL = folder.appendingPathComponent("context-negative.png")
    let contextImage = makeImage(300, 200) { x, y in
      (x < 35 || x > 265 || y < 25 || y > 175)
        ? base : RGB(r: 0.45 + Double(x % 30) / 200, g: 0.22 + Double(y % 20) / 250, b: 0.14)
    }
    try pipe.savePNG(contextImage, to: overviewURL)
    var contextFrame = FilmFrame(
      name: "context", rect: NormalRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7), format: "135")
    contextFrame.adjustments.rotation = 1
    contextFrame.adjustments.flipHorizontal = true
    let project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 150, physicalWidthMM: 50.8,
      physicalHeightMM: 33.87, filmName: profile.name, profile: profile, scanDPI: 2400,
      frames: [contextFrame])
    let projectURL = folder.appendingPathComponent("context.epscan")
    try JSONEncoder().encode(project).write(to: projectURL)
    let editor = AppModel(libraryURL: folder)
    editor.loadProject(projectURL)
    editor.singleView = true
    editor.useTool(.crop)
    func awaitRender() throws {
      let deadline = Date().addingTimeInterval(5)
      while editor.rendering && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      }
      try check(!editor.rendering && editor.errorText == nil, "single-frame render completes")
    }
    try awaitRender()
    let originalRegion = editor.canvasRegion!
    let displayedCrop = editor.canvasCrop!
    let trimmed = NormalRect(
      x: displayedCrop.x + 0.02, y: displayedCrop.y + 0.02, width: displayedCrop.width - 0.04,
      height: displayedCrop.height - 0.04)
    editor.commitSingleCrop(trimmed)
    try awaitRender()
    try check(
      editor.singleView && editor.tool == .crop && editor.canvasRegion == originalRegion,
      "single-frame crop stays in place with a stable context")
    editor.useTool(.base)
    try awaitRender()
    let samplePoint = ImageGeometry.display(CGPoint(x: 0.01, y: 0.01), settings: editor.settings)
    editor.sample(samplePoint)
    try awaitRender()
    try check(
      editor.singleView && editor.settings.base != nil && editor.settings.autoWhiteBalance == false,
      "base picker works in single view and preserves manual sample")
    let compatibility = try JSONDecoder().decode(
      DeskProject.self, from: JSONEncoder().encode(project))
    try check(
      compatibility.frames[0].scanRect == nil
        && compatibility.frames[0].adjustments.baseFine == nil,
      "new optional fields accept existing projects")

    // Feed a saved/synthetic overview into the same completion path as a scanner.
    let previewModel = AppModel(libraryURL: folder.appendingPathComponent("preview-navigation"))
    let filmStrip = makeImage(400, 800) { x, y in
      guard (80..<180).contains(x), (40..<660).contains(y) else { return .zero }
      let row = (y - 40) % 208
      if row >= 200 { return base }
      return cleanRaster.pixel(x, row)
    }
    previewModel.receiveOverview(filmStrip, size: CGSize(width: 100, height: 200), dpi: 100)
    let previewDeadline = Date().addingTimeInterval(12)
    while (previewModel.rendering || previewModel.frames.isEmpty) && Date() < previewDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try check(
      !previewModel.singleView && previewModel.selectedID == previewModel.frames.first?.id
        && previewModel.frames.count >= 2 && previewModel.errorText == nil,
      "preview completion stays on the light table, the first frame selected")
    previewModel.singleView = true
    let navigationView = FilmCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
    navigationView.model = previewModel
    func pressArrow(_ key: UInt16) {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: key)!
      navigationView.keyDown(with: event)  // Own test view only; never post an OS event.
    }
    let firstID = previewModel.selectedID
    previewModel.zoom = 4
    pressArrow(124)
    try check(
      previewModel.selectedIndex == 1 && previewModel.zoom == 1 && previewModel.singleView,
      "right arrow selects next frame and resets zoom")
    pressArrow(123)
    pressArrow(123)
    try check(
      previewModel.selectedID == firstID, "left arrow returns to first frame and stops at boundary")
    previewModel.select(previewModel.frames.last!.id)
    pressArrow(124)
    try check(
      previewModel.selectedID == previewModel.frames.last!.id,
      "right arrow does not wrap at final frame")
    previewModel.useTool(.crop)
    let cropDeadline = Date().addingTimeInterval(5)
    while previewModel.rendering && Date() < cropDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let cropID = previewModel.selectedID
    let cropBefore = previewModel.selected!.rect
    pressArrow(123)
    try check(
      previewModel.selectedID == cropID && previewModel.selected!.rect != cropBefore,
      "crop mode arrows adjust the crop without switching frames")

    // Tightening an old project's bounds must not reset its edits or scan mapping.
    previewModel.useTool(.select)
    let settleDeadline = Date().addingTimeInterval(5)
    while previewModel.rendering && Date() < settleDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    previewModel.frames[0].rect = previewModel.frames[0].rect.expanded(by: 0.04)
    previewModel.frames[0].adjustments.warmth = 0.31
    previewModel.frames[0].scanPath = overviewURL.path
    let oldFrame = previewModel.frames[0]
    previewModel.tightenExistingBorders()
    let tightenDeadline = Date().addingTimeInterval(10)
    while previewModel.rendering && Date() < tightenDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let tightened = previewModel.frames[0]
    // The roll base and slopes are measured by the app from the frames, not edits; new bounds may
    // re-measure them.
    func edits(_ a: Adjustments) -> Adjustments {
      var a = a
      a.rollBase = nil
      a.rollSlopes = nil
      return a
    }
    try check(
      tightened.rect != oldFrame.rect && oldFrame.rect.contains(tightened.rect)
        && edits(tightened.adjustments) == edits(oldFrame.adjustments) && tightened.scanPath == oldFrame.scanPath
        && tightened.captureRect == oldFrame.rect && tightened.initialRect == oldFrame.rect,
      "tighten existing borders preserves settings, original scan footprint and restore range")
    let selectionBefore = previewModel.selectedID
    let framesBefore = previewModel.frames
    previewModel.zoom = 2.5
    previewModel.setAllEnabled(false)
    try check(
      previewModel.enabledCount == 0 && previewModel.selectedID == selectionBefore
        && previewModel.singleView && previewModel.zoom == 2.5,
      "deselect all preserves the current single view and zoom")
    let savedDeselection = try JSONDecoder().decode(
      DeskProject.self,
      from: Data(
        contentsOf:
          previewModel.sessionURL!.appendingPathComponent("Session.epscan")))
    try check(
      savedDeselection.frames.allSatisfy { !$0.enabled }, "deselect all persists to the project")
    previewModel.setAllEnabled(true)
    try check(
      previewModel.enabledCount == previewModel.frames.count
        && zip(previewModel.frames, framesBefore).allSatisfy { a, b in
          a.id == b.id && a.rect == b.rect && a.adjustments == b.adjustments
            && a.scanPath == b.scanPath && a.captureRect == b.captureRect
        }, "select all preserves frame identity, crops, colors and original scans")
    previewModel.setEnabled(selectionBefore!, enabled: false)
    try check(
      previewModel.selected?.enabled == false
        && previewModel.enabledCount == previewModel.frames.count - 1,
      "current-frame checkbox affects only the current photograph")
    let savedSelection = try JSONDecoder().decode(
      DeskProject.self,
      from: Data(
        contentsOf:
          previewModel.sessionURL!.appendingPathComponent("Session.epscan")))
    try check(
      savedSelection.frames.filter { !$0.enabled }.map(\.id) == [selectionBefore!],
      "current-frame selection persists to the project")
    previewModel.exporting = true
    previewModel.setAllEnabled(false)
    previewModel.setEnabled(selectionBefore!, enabled: true)
    try check(
      previewModel.enabledCount == previewModel.frames.count - 1
        && previewModel.selected?.enabled == false,
      "selection changes are blocked while a batch operation is running")
    previewModel.exporting = false
    let emptySelection = AppModel(libraryURL: folder)
    emptySelection.setAllEnabled(true)
    emptySelection.setAllEnabled(false)
    try check(
      emptySelection.enabledCount == 0 && emptySelection.selectedID == nil,
      "bulk selection is safe with an empty project")
  }
}
