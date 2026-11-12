import AppKit
import Foundation

/// One roll whatever took it: pictures a file each (as a camera takes them) estimated together with
/// 全卷斜率估计, each a roll of their own to print, and a film base picked once and shared with the roll.
enum RollGroupTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let pipe = ImagePipeline.shared

    // Which frames go together.
    func frame(_ path: String?, gamma: Double = 1, bits: Int = 16) -> FilmFrame {
      var f = FilmFrame(name: "x", rect: .full, format: path == nil ? "135" : "导入")
      f.sourcePath = path
      f.sourceBits = path == nil ? nil : bits
      f.adjustments.inputGamma = gamma
      return f
    }
    let mixed = [frame(nil), frame(nil), frame("/strip.tif"), frame("/strip.tif"),
      frame("/a.tif"), frame("/b.tif"), frame("/c.tif"), frame("/d.jpg", gamma: 2.2, bits: 8)]
    let apart = AppModel.rollGroups(mixed, poolPictures: false).map(\.count)
    let pooled = AppModel.rollGroups(mixed, poolPictures: true).map(\.count)
    try check(apart == [2, 2, 1, 1, 1, 1] && pooled == [2, 2, 3, 1],
      "scanned frames go together, a strip file on its own; pictures a file each each apart, or together (only those read alike)")

    // A roll of three pictures, a file each, on a film whose slopes are not the data sheet's.
    let base = RGB(r: 0.80, g: 0.52, b: 0.33)
    let truth = RGB(r: 0.51, g: 0.55, b: 0.65)
    func picture(_ low: Double, _ high: Double) -> CGImage {
      let w = 200, h = 140
      var samples = [UInt16](repeating: 65535, count: w * h * 4)
      for y in 0..<h {
        for x in 0..<w {
          let l = low + (high - low) * (Double(x) / 199 * 0.8 + Double(y % 7) / 6 * 0.2)
          for c in 0..<3 { samples[(y * w + x) * 4 + c] = UInt16(max(0, min(1, base.values[c] * pow(10, -truth.values[c] * l))) * 65535) }
        }
      }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    let lib = folder.appendingPathComponent("roll-groups", isDirectory: true)
    try? FileManager.default.removeItem(at: lib)
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    var urls = [URL]()
    for (i, range) in [(0.2, 0.9), (0.6, 1.5), (1.1, 2.0)].enumerated() {
      let url = lib.appendingPathComponent("capture-\(i + 1).png")
      try pipe.savePNG(picture(range.0, range.1), to: url)
      urls.append(url)
    }
    let model = AppModel(libraryURL: lib)
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.undoManager = undo
    model.importURLs(urls)
    // Decoded camera files are linear.
    for f in model.frames {
      model.select(f.id)
      model.change("输入设置") { $0.inputGamma = 1 }
    }
    func estimate() {
      var done = false
      model.updateRollSlopes { done = true }
      for _ in 0..<200 where !done { settle(0.05) }
      for _ in 0..<40 where model.rendering { settle(0.05) }
    }
    estimate()
    model.select(model.frames[0].id)
    try check(model.frames.count == 3 && !model.estimatesSlopes && !model.selectedSharesRoll
      && model.frames.allSatisfy { $0.adjustments.rollSlopes == nil },
      "pictures imported a file each start with 全卷斜率估计 off, and are each a roll of their own to print")
    model.setRollSlopeEstimate(true)
    estimate()
    let slopes = model.frames.compactMap(\.adjustments.rollSlopes)
    try check(slopes.count == 3 && slopes.allSatisfy { abs($0.r / truth.r - 1) < 0.04 && abs($0.b / truth.b - 1) < 0.04 },
      String(format: "with 全卷斜率估计 on they give the roll estimate, as the scanned frames do: R %.3f · B %.3f (true %.2f · %.2f)",
        slopes.first?.r ?? 0, slopes.first?.b ?? 0, truth.r, truth.b))

    // Off again: the data sheet's slopes, the estimate cleared.
    model.setRollSlopeEstimate(false)
    estimate()
    try check(!model.estimatesSlopes && model.frames.allSatisfy { $0.adjustments.rollSlopes == nil }
      && ImagePipeline.slopes(model.frames[0].adjustments, model.profile).slopes == model.profile.slopes,
      "with 全卷斜率估计 off the roll converts with the calibration, else the data sheet")
    model.setRollSlopeEstimate(true)
    estimate()

    // The base picked once, on the leader, for the whole roll.
    model.select(model.frames[0].id)
    model.setFilmBase(base)
    model.shareFilmBase()
    estimate()
    try check(model.frames.allSatisfy { $0.adjustments.rollBase == base && $0.adjustments.rollBasePicked == true },
      "a base picked on one frame is shared with every frame of its roll")
    model.select(model.frames[2].id)
    model.change("曝光") { $0.exposure = 0.3 }
    try check(model.frames[2].adjustments.rollBase == base && model.frames[2].adjustments.rollBasePicked == true,
      "editing a frame keeps the shared base")
    let reopened = AppModel(libraryURL: lib)
    reopened.loadProject(model.projectURL!)
    for _ in 0..<40 where reopened.rendering { settle(0.05) }
    // The first picture is also the overview, whose gaps (there are none) would otherwise clear it.
    try check(reopened.estimatesSlopes && reopened.frames.allSatisfy { $0.adjustments.rollBase == base && $0.adjustments.rollBasePicked == true },
      "the shared base and 全卷斜率估计 are kept in the project, and the overview's gaps do not clear the base")
    undo.undo()
    undo.undo()
    try check(model.frames.allSatisfy { $0.adjustments.rollBasePicked != true && $0.adjustments.rollBase == nil },
      "sharing the base is undone like any edit")
    undo.redo()
    undo.redo()
    try check(model.frames.allSatisfy { $0.adjustments.rollBase == base && $0.adjustments.rollBasePicked == true },
      "and redone")
    model.unshareFilmBase()
    try check(model.frames.allSatisfy { $0.adjustments.rollBasePicked != true && $0.adjustments.rollBase == nil },
      "taking the shared base back leaves each frame to the base measured or estimated for it")

    // Lightroom's marks: stars, flags and colour labels on the frames chosen, one edit each, the same
    // flag or label again taking it off, kept in the project.
    model.select(model.frames[0].id)
    model.alsoSelected = [model.frames[1].id]
    model.setRating(3)
    model.setFlag(1)
    model.setLabel(.green)
    let marked = model.frames.prefix(2).allSatisfy { $0.rating == 3 && $0.flag == 1 && $0.label == FrameLabel.green.rawValue } && model.frames[2].rating == nil
    model.setFlag(1)
    let flagOff = model.frames[0].flag == nil
    undo.undo()
    let flagBack = model.frames[0].flag == 1
    model.alsoSelected = []
    model.setRating(0)
    let reopenedMarks = AppModel(libraryURL: lib)
    reopenedMarks.loadProject(model.projectURL!)
    try check(marked && flagOff && flagBack && model.frames[0].rating == nil && model.frames[1].rating == 3
      && reopenedMarks.frames[1].rating == 3 && reopenedMarks.frames[1].label == FrameLabel.green.rawValue
      && AppModel.markWords(model.frames[1]) == "★★★ · 留用 · 绿色标签",
      "stars, a flag and a colour label go on the frames chosen, the same flag again takes it off, undo puts it back, and the project keeps them")
    // Chosen by their marks, as Lightroom's 按旗标 / 按星级 / 按颜色标签选择; ⌘A all of them, ⌘D the
    // one shown alone. Frame 1 is 留用 · 绿色, frame 2 ★★★ · 留用 · 绿色, the others unmarked.
    model.select(model.frames[2].id)
    model.selectMarked(.picked)
    let pickedChosen = model.selectionIDs == Set(model.frames.prefix(2).map(\.id)) && model.selectedID == model.frames[0].id
    model.selectMarked(.stars(3))
    let starsChosen = model.selectionIDs == [model.frames[1].id] && model.selectedID == model.frames[1].id
    model.selectMarked(.rejected)
    let noneLeaves = model.selectionIDs == [model.frames[1].id] && model.status == "这一卷没有不要的画面"
    model.selectMarked(.label(.green))
    let greens = model.selectionIDs == Set(model.frames.prefix(2).map(\.id)) && model.selectedID == model.frames[1].id
    model.selectMarked(.unflagged)
    let unflagged = model.selection.count == model.frames.count - 2 && model.selectedID == model.frames[2].id
    model.selectAllFrames()
    let all = model.selection.count == model.frames.count && model.selectedID == model.frames[2].id
    model.selectOnlyShown()
    try check(pickedChosen && starsChosen && noneLeaves && greens && unflagged && all && model.selection.count == 1,
      "frames are chosen by a flag, by stars or by a colour label, the one shown kept when it is one of them; ⌘A chooses all, ⌘D the one shown")
    // And by the assistant's tools: marks set outright on frames named, read back in list_frames,
    // frames chosen by them.
    func reply(_ name: String, _ arguments: [String: Any] = [:]) -> (text: String, error: Bool) {
      let r = MCPTools.call(name, arguments, model: model)
      return ((r.content.first?["text"] as? String) ?? "", r.isError)
    }
    let (first, third) = (model.frames[0].name, model.frames[2].name)
    let set = reply("set_marks", ["frames": [first, third], "stars": 4, "flag": "rejected", "label": "blue"])
    let setRight = model.frames[0].rating == 4 && model.frames[0].flag == -1 && model.frames[0].label == FrameLabel.blue.rawValue
      && model.frames[2].rating == 4 && model.frames[1].rating == 3 && model.frames[1].flag == 1
    let chosen = reply("select_by_marks", ["by": "stars", "stars": 4])
    let listedMarks = reply("list_frames").text
    let cleared = reply("set_marks", ["flag": "none", "label": "none"])
    let clearedRight = model.frames[0].flag == nil && model.frames[0].label == nil && model.frames[0].rating == 4 && model.frames[2].flag == nil
    let wrong = reply("set_marks", ["frames": ["不存在"], "stars": 1])
    undo.undo()
    try check(!set.error && setRight && chosen.text.hasSuffix("所选：\(first)、\(third)") && listedMarks.contains("\"stars\" : 4") && listedMarks.contains("\"rejected\"")
      && listedMarks.contains("\"chosen\" : true") && !cleared.error && clearedRight && wrong.error && model.frames[0].flag == -1,
      "the assistant sets stars, a flag and a label on frames named or chosen, reads them in list_frames and chooses frames by them: \(set.text) / \(chosen.text) / \(cleared.text)")
    // Culling fast: a flag on one frame and then, within the second, on the next are two steps.
    model.select(model.frames[0].id)
    model.setFlag(1)
    model.select(model.frames[2].id)
    model.setFlag(1)
    let bothPicked = model.frames[0].flag == 1 && model.frames[2].flag == 1
    undo.undo()
    try check(bothPicked && model.frames[0].flag == 1 && model.frames[2].flag == -1,
      "flagging one frame and then the next within a second are two steps: ⌘Z takes back only the last")
    // The grading wheels' figures under them, and the mixer's tracks in each band's colours.
    let red = ColourMixer.track(band: 0, kind: 0), blueSaturation = ColourMixer.track(band: 5, kind: 1)
    try check(ColourGrading.readout(hue: 210, amount: 0.25) == "210° · 25" && ColourGrading.readout(hue: -30, amount: 0.004) == "—"
      && ColourGrading.readout(hue: 359.6, amount: 1) == "0° · 100" && ColourGrading.readout(hue: -90, amount: 0.5) == "270° · 50"
      && red.count == 3 && blueSaturation.count == 2 && (0..<8).allSatisfy { b in (0..<3).allSatisfy { ColourMixer.track(band: b, kind: $0).count >= 2 } },
      "a grading wheel reads its hue and amount (a dash at the middle), and each of the mixer's sliders has its band's colours")
    // The single view's before (\\): in ③ the frame shows as ② leaves it; not in ②.
    model.page = .convert
    model.convertStep = .grade
    model.select(model.frames[0].id)
    model.change("曝光") { $0.exposure = 0.7 }
    model.showBefore = true
    let before = model.asShown(model.frames[0]).adjustments.exposure
    model.showBefore = false
    let after = model.asShown(model.frames[0]).adjustments.exposure
    try check(before == 0 && after == 0.7 && model.loupeDetailKey(model.frames[0], single: true) != {
        model.showClipping = true
        defer { model.showClipping = false }
        return model.loupeDetailKey(model.frames[0], single: true)
      }(),
      "\\ shows ③'s before (the exposure as new) and back; J's clipping marks ask the zoomed picture again")
  }
}
