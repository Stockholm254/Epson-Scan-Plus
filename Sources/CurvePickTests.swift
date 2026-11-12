import AppKit
import Foundation
import SwiftUI

/// The curves' picker, as Capture One has it under its curve: 取曲线点 puts a point on the curve
/// taken where the colour clicked lies, 取中性点 a point on each of red, green and blue that takes it
/// to grey at its brightness, the ends left; each pick one step ⌘Z takes back.
enum CurvePickTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let pipe = ImagePipeline.shared
    let level = 1.0 / 255
    func spread(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
    /// What the curves' kernel gives channel `c` of a value: the table's entries between which it falls, interpolated.
    func looked(_ table: [Float], _ v: Double, _ c: Int) -> Double {
      let n = table.count / 4, at = min(1, max(0, v)) * Double(n - 1), i = min(n - 2, Int(at)), t = at - Double(i)
      return Double(table[i * 4 + c]) * (1 - t) + Double(table[(i + 1) * 4 + c]) * t
    }

    // MARK: The arithmetic

    // Curves already bent every way: the parametric curve, an S on RGB, red lifted in the middle.
    var bent = ToneCurves()
    var parametric = ParametricCurve()
    parametric.darks = 0.3
    bent.parametric = parametric
    bent.rgb.points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.25), CurvePoint(x: 0.7, y: 0.76), CurvePoint(x: 1, y: 1)]
    bent.red.points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.58), CurvePoint(x: 1, y: 1)]
    let colour = RGB(r: 0.42, g: 0.47, b: 0.56)
    let found = bent.neutralized(colour)
    let table = found?.curves.table(1024) ?? []
    let out = table.isEmpty ? [] : (0..<3).map { looked(table, colour.values[$0], $0) }
    let endsKept = found.map { f in (1...3).allSatisfy { f.curves[$0].points.first == bent[$0].points.first && f.curves[$0].points.last == bent[$0].points.last } } ?? false
    let othersKept = found.map { $0.curves.rgb == bent.rgb && $0.curves.parametric == bent.parametric } ?? false
    let brightnessKept = found.map { abs(ToneCurves.brightness(RGB(out)) - $0.target) < level } ?? false
    try check(found != nil && out.count == 3 && spread(out) < level && brightnessKept && endsKept && othersKept
      && found!.curves.red.points.count == 4 && found!.curves.green.points.count == 3 && found!.curves.blue.points.count == 3,
      String(format: "取中性点 takes a colour to grey through the curves' table (spread %.5f, under 1/255), at its own brightness %.3f, a point on each of red, green and blue; their ends, the RGB and the parametric curve stay",
        spread(out), found?.target ?? 0))
    // Another brightness, another set; one close by moves the set already there.
    let darker = RGB(r: 0.2, g: 0.18, b: 0.27)
    let second = found?.curves.neutralized(darker)
    let bothTable = second?.curves.table(1024) ?? []
    let bothGrey = !bothTable.isEmpty && [colour, darker].allSatisfy { c in spread((0..<3).map { looked(bothTable, c.values[$0], $0) }) < level }
    let near = found?.curves.neutralized(RGB(r: 0.425, g: 0.474, b: 0.563))
    try check(second.map { s in (1...3).allSatisfy { s.curves[$0].points.count == found!.curves[$0].points.count + 1 } } == true && bothGrey
      && near.map { n in (1...3).allSatisfy { n.curves[$0].points.count == found!.curves[$0].points.count } } == true,
      "picked again at another brightness, another point goes on each curve and both places are grey; close to one already picked, its points move instead")
    try check(bent.neutralized(RGB(r: 0.004, g: 0.3, b: 0.3)) == nil && bent.neutralized(RGB(r: 0.3, g: 0.3, b: 0.995)) == nil,
      "a colour with a channel at black or white is refused, so the curves' ends never move")
    // 取曲线点: on the curve, where the colour lies on the page taken.
    let onGreen = ToneCurves().pickedPoint(colour, channel: 2)
    let greenPoint = onGreen.curves?.green.points
    let onRGB = bent.pickedPoint(colour, channel: 0)
    let rgbX = ToneCurves.brightness(RGB(colour.values.map { bent.firstStage!.value($0) }))
    let rgbPoint = onRGB.curves?.rgb.points.first { abs($0.x - onRGB.x) < 1e-12 }
    var redOnly = ToneCurves()
    redOnly.red = bent.red
    try check(greenPoint?.count == 3 && abs((greenPoint?[1].x ?? 0) - colour.g) < 1e-12 && abs((greenPoint?[1].y ?? 0) - colour.g) < 1e-12
      && abs(onRGB.x - rgbX) < 1e-12 && rgbPoint.map { abs($0.y - bent.rgb.value(onRGB.x)) < 1e-12 } == true && onRGB.curves?.red == bent.red
      && redOnly.pickedPoint(RGB(r: 0.51, g: 0.5, b: 0.5), channel: 1).curves == nil,
      "取曲线点 adds a point on the curve taken where the colour lies on it (input = output on a straight curve; on the RGB curve its brightness after the parametric one); one already there is left to drag")
    // Under the plot: the input and output where the pointer lies, where 取曲线点 would put its point.
    let reading = CurveState.Reading(input: colour, over: true)
    let io = CurveEditor.inputOutput(reading, curves: bent, channel: 0, parametric: false)
    let ioRed = CurveEditor.inputOutput(reading, curves: bent, channel: 1, parametric: false)
    try check(abs(io.input - onRGB.x) < 1e-12 && abs(io.output - bent.rgb.value(onRGB.x)) < 1e-12
      && abs(ioRed.input - bent.channelInputs(colour)[0]) < 1e-12 && abs(ioRed.output - bent.red.value(ioRed.input)) < 1e-12,
      String(format: "under the curve the input and output on the page taken: RGB %@ → %@, R %@ → %@",
        CurveEditor.level(io.input), CurveEditor.level(io.output), CurveEditor.level(ioRed.input), CurveEditor.level(ioRed.output)))

    // MARK: The key and its mode

    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = Preferences(defaults: defaults)
    let startsOnPoint = first.curvePick == .point
    first.curvePick = .neutral
    let shortcuts = CanvasTool.allCases.compactMap(\.shortcut)
    try check(startsOnPoint && Preferences(defaults: defaults).curvePick == .neutral
      && CanvasTool.curvePick.shortcut == "u" && Set(shortcuts).count == shortcuts.count && !shortcuts.contains(AppModel.loupeShortcut)
      && CanvasTool.curvePick.step == .grade && CanvasTool.curvePick.picksPoint,
      "the picker starts on 取曲线点 and keeps the mode last chosen; its key U, as in Capture One, is no other tool's or the loupe's")

    // MARK: In the app

    // A roll on the light table: one frame of six steps of density on an orange base.
    let roll = folder.appendingPathComponent("curve-pick")
    try? FileManager.default.removeItem(at: roll)
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    let draw = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
      space: pipe.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw.setFillColor(red: 0.85, green: 0.55, blue: 0.32, alpha: 1)
    draw.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
    for i in 0..<6 {
      draw.setFillColor(red: 0.6 - Double(i) * 0.07, green: 0.36 - Double(i) * 0.035, blue: 0.2 - Double(i) * 0.022, alpha: 1)
      draw.fill(CGRect(x: 120 + i * 60, y: 120, width: 60, height: 160))
    }
    let overviewURL = roll.appendingPathComponent("overview.png")
    try pipe.savePNG(draw.makeImage()!, to: overviewURL)
    let frameRect = NormalRect(x: 0.15, y: 0.2, width: 0.7, height: 0.6)
    let project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 150, physicalWidthMM: 101.6, physicalHeightMM: 67.7,
      filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400,
      frames: [FilmFrame(name: "01", rect: frameRect, format: "135")])
    let projectURL = roll.appendingPathComponent("Session.epscan")
    try JSONEncoder().encode(project).write(to: projectURL)
    let model = AppModel(libraryURL: roll)
    model.loadProject(projectURL)
    for _ in 0..<40 where model.rendering { settle(0.1) }
    model.select(model.frames[0].id)
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.undoManager = undo
    let canvas = FilmCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = canvas
    canvas.model = model
    model.preferences.showLoupe = false
    model.page = .convert
    model.convertStep = .demask
    func key(_ characters: String, code: UInt16) {
      canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)!)
    }
    key("u", code: 32)
    for _ in 0..<400 where model.rendering || model.samplingInput == nil { settle(0.05) }
    settle()
    try check(model.tool == .curvePick && model.singleView && model.convertStep == .grade && canvas.samplingCursor != nil
      && (model.toolHint ?? "").contains("曲线上它所在的地方"),
      "U takes up the curves' picker on the single frame, in ③ 调色, with an eyedropper and a hint for the mode chosen")
    // The steps' middles, in the frame; the one furthest from black and white in every channel is picked.
    let steps = (0..<6).map { i in CGPoint(x: (150 + 60 * Double(i) - 90) / 420, y: 0.5) }
    let readings = steps.map { model.positiveBeforeCurves(at: $0) }
    let room = readings.map { r in r.map { $0.values.map { min($0, 1 - $0) }.min() ?? 0 } ?? -1 }
    let best = room.indices.max { room[$0] < room[$1] } ?? 0
    let point = steps[best]
    guard let before = readings[best], room[best] > 0.05 else {
      throw DeskError.message("FAIL: the frame's steps have a colour clear of black and white to pick (\(readings))")
    }
    // A cast to take out: red lifted and blue lowered through the middle, as a curve set by hand.
    var cast = ToneCurves()
    cast.red.points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)]
    cast.blue.points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.43), CurvePoint(x: 1, y: 1)]
    let plain = model.displayed
    model.change("曲线") { $0.curves = cast }
    for _ in 0..<400 where model.displayed === plain || model.rendering { settle(0.05) }
    /// The single frame's positive about the point as it is printed now, curves and all, in floats.
    func printed() -> RGB? {
      guard let input = model.samplingInput, let f = model.selected,
        let ci = try? pipe.output(input, settings: f.adjustments, profile: model.conversionProfile, analysis: model.toneAnalysis)
      else { return nil }
      return pipe.mean(ci, at: point)
    }
    let castOut = printed()
    func screen(_ p: CGPoint) -> CGPoint {
      let r = canvas.imageRect
      return CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
    }

    // 取中性点, clicked on the canvas.
    model.preferences.curvePick = .neutral
    let tinted = model.displayed
    canvas.sample(at: screen(point))
    for _ in 0..<400 where model.displayed === tinted || model.rendering { settle(0.05) }
    let neutralCurves = model.settings.curves
    let greyOut = printed()
    let shownGrey = model.displayed.flatMap { FilmCanvasView.colour(in: $0, at: point) }
    let neutralEnds = neutralCurves.map { c in (1...3).allSatisfy { c[$0].points.first == cast[$0].points.first && c[$0].points.last == cast[$0].points.last } } ?? false
    try check(castOut.map { spread($0.values) > 3 * level } == true && greyOut.map { spread($0.values) < level } == true && neutralEnds
      && neutralCurves.map { c in (1...3).allSatisfy { (cast[$0].points.count...cast[$0].points.count + 1).contains(c[$0].points.count) } && c.green.points.count == 3 } == true
      && shownGrey.map { spread($0.values) <= 2 * level } == true && model.tool == .curvePick
      && model.status.hasPrefix("已取中性点"),
      String(format: "取中性点 on the canvas takes the point clicked from a cast (spread %.3f) to grey: R G B %.4f %.4f %.4f (spread %.5f, under 1/255; on the screen %.0f/255), a point on each of red, green and blue, their ends where they were; the tool stays for the next",
        castOut.map { spread($0.values) } ?? -1, greyOut?.r ?? -1, greyOut?.g ?? -1, greyOut?.b ?? -1, greyOut.map { spread($0.values) } ?? -1,
        (shownGrey.map { spread($0.values) } ?? -1) * 255) + " · " + model.status)
    let greyPicture = model.displayed
    undo.undo()
    for _ in 0..<400 where model.displayed === greyPicture || model.rendering { settle(0.05) }
    try check(model.settings.curves == cast && model.status != "", "⌘Z takes the neutral point back in one step")

    // 取曲线点 on the green page, and from the parametric page onto RGB.
    model.preferences.curvePick = .point
    model.curveState.parametric = false
    model.curveState.channel = 2
    let input = model.positiveBeforeCurves(at: point)
    for _ in 0..<400 where model.rendering { settle(0.05) }
    canvas.sample(at: screen(point))
    let greenCurve = model.settings.curves?.green
    let x = input.map { cast.target($0, channel: 2, parametric: false) } ?? -1
    let added = greenCurve?.points.first { abs($0.x - x) < 1e-9 }
    try check(input.map { i in (0..<3).allSatisfy { abs(i.values[$0] - before.values[$0]) < 1e-6 } } == true
      && greenCurve?.points.count == 3 && added.map { abs($0.y - cast.green.value(x)) < 1e-9 } == true
      && model.settings.curves?.red == cast.red && model.status.hasPrefix("已在 G 曲线上加点"),
      String(format: "取曲线点 reads the positive before the curves and adds a point on the green curve where it lies, on the curve (%.4f → %.4f)", x, added?.y ?? -1))
    undo.undo()
    try check(model.settings.curves == cast, "⌘Z takes the curve point back in one step")
    model.curveState.parametric = true
    for _ in 0..<400 where model.rendering { settle(0.05) }
    canvas.sample(at: screen(point))
    try check(!model.curveState.parametric && model.curveState.channel == 0 && model.settings.curves?.rgb.points.count == 3,
      "picked on the parametric page, the point goes on the RGB curve, and the page turns to it")
    undo.undo()
    // The picker under the curve: its key and menu laid out with the curves.
    let editor = NSHostingView(rootView: CurveEditor(
      curves: .constant(cast), histogram: model.histogram, channels: model.channelHistograms, state: model.curveState,
      picking: .constant(true), pickMode: .constant(.neutral)).frame(width: 260))
    let editorWindow = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 280, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
    editorWindow.contentView = editor
    editorWindow.appearance = NSAppearance(named: .darkAqua)
    model.curveState.reading = CurveState.Reading(input: colour, over: true)
    editor.setFrameSize(NSSize(width: 260, height: max(300, editor.fittingSize.height)))
    editor.layoutSubtreeIfNeeded()
    settle(0.2)
    // A picture of it beside the test's files, to look at.
    if let rep = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) {
      editor.cacheDisplay(in: editor.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: roll.appendingPathComponent("curve-picker.png"))
    }
    model.curveState.reading = nil
    try check(editor.fittingSize.height > 260, String(format: "the curves lay out with the input and output and the picker under the plot (%.0f high)", editor.fittingSize.height))
    editorWindow.contentView = nil
    key("v", code: 9)
    try check(model.tool == .select, "V puts the picker down")
  }
}
