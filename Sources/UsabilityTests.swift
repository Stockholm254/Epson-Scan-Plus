import CoreGraphics
import Foundation

/// Telling the tools apart, what the canvas says while one is active, and what a batch scan will
/// take before it starts.
enum UsabilityTests {
  /// Starts a scan and stays busy, so a test sees whether a batch began, until told to finish.
  private final class IdleScanner: ScannerController {
    var requests = 0
    override func scan(rect: NormalRect, dpi: Int, directory: URL, name: String) throws {
      requests += 1
      busy = true
    }
    func finish(_ file: URL) {
      onScan?(file)
      busy = false
      progress = 1
      onFinished?(nil)
    }
  }

  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let toolbar: [CanvasTool] = [.select, .crop, .base, .neutral]
    try check(Set(toolbar.map(\.symbol)).count == toolbar.count && CanvasTool.base.label != nil && CanvasTool.neutral.label != nil
      && CanvasTool.base.label != CanvasTool.neutral.label,
      "the toolbar's tools have their own symbols, and the two samplers say which is which")
    // The system draws Liquid Glass for this app though it may be built with an earlier SDK.
    try check(SystemGlass.viewClass != nil, "on macOS 26 the system's Liquid Glass is found at run time, for the floating plates and the fader caps")
    // A fader set at once (自动调整, 重置调整) glides there; the hand on it stops it at the setting.
    let fader = DetentSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    fader.glide(to: 1)
    let glideStart = fader.doubleValue, gliding = fader.glideTarget == 1
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let partWay = fader.doubleValue
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    let landed = fader.doubleValue, ended = fader.glideTarget == nil
    fader.glide(to: -1)
    fader.stopGlide()
    try check(glideStart == 0 && gliding && partWay > 0.05 && partWay < (FilmCanvasView.stillMotion ? 1.01 : 0.99) && landed == 1 && ended && fader.doubleValue == -1,
      "a fader set at once glides to the value (\(String(format: "%.2f", partWay)) a tenth of a second in) and lands on it; stopped, it is at the setting")

    let model = AppModel(libraryURL: folder.appendingPathComponent("usability"), scanner: IdleScanner())
    try check(model.toolHint == nil, "the select tool puts nothing on the canvas")
    var hints = [CanvasTool: String]()
    for tool in CanvasTool.allCases where tool != .select {
      model.tool = tool
      hints[tool] = model.toolHint
    }
    try check(hints.count == CanvasTool.allCases.count - 1 && hints.values.allSatisfy { $0.contains("Esc") }
      && Set(hints.values).count == hints.count,
      "every other tool says on the canvas what to click, and that Esc leaves it")
    model.tool = .it8
    model.it8Marks = [CGPoint(x: 0.1, y: 0.1)]
    try check(model.toolHint?.contains(IT8Layout.marks[1]) == true && model.toolHint?.contains("2 / 6") == true,
      "on the IT8 target it names the next point to click")
    model.singleView = true
    model.tool = .crop
    let single = model.toolHint
    model.singleView = false
    try check(single != model.toolHint, "cropping a single frame and drawing a frame on the light table are explained apart")
    model.tool = .select

    // A 35 mm frame on the V850's bed at 2400 dpi, as the hardware test scans it: 2216 × 3378, 45 MB.
    let bed = CGSize(width: 149.86, height: 246.38)
    func frame(_ name: String, scanned: Bool = false) -> FilmFrame {
      var f = FilmFrame(name: name, rect: NormalRect(x: 0.1, y: 0.1, width: 23.45 / bed.width, height: 35.75 / bed.height), format: "135")
      if scanned { f.scanPath = "/tmp/\(name).tiff" }
      return f
    }
    let roll = (1...36).map { frame(String(format: "%02d", $0), scanned: $0 <= 3) }
    let alone = roll.map { [$0] }
    let plan = ScanPlan.make(alone, physicalMM: bed, dpi: 2400, bitsPerChannel: 16, export: .tiff, speed: nil, available: 500e9)
    try check(plan.width == 2216 && plan.height == 3378 && plan.uniform && abs(plan.originalBytes / 36 - 44.9e6) < 0.1e6,
      String(format: "a 35 mm frame at 2400 dpi is %d × %d pixels, %.1f MB as a 48-bit original", plan.width, plan.height, plan.originalBytes / 36e6))
    try check(abs(plan.seconds / 36 - 43.6) < 0.3 && ScanPlan.duration(plan.seconds) == "约 26 分钟" && !plan.measured && plan.passes == 36,
      String(format: "until this scanner has been timed, a frame takes about %.0f s, as measured on the V850: a roll %@", plan.seconds / 36, ScanPlan.duration(plan.seconds)))
    try check(plan.rescans == 3 && plan.exportBytes == plan.originalBytes && plan.fits,
      "it counts frames scanned before and the automatic exports' space")
    let text = plan.summary
    try check(["2216 × 3378", "48-bit", "其中 3 张已扫描过", "约 26 分钟", "按 V850 实测估计", "TIFF · 16-bit", "可用空间"].allSatisfy(text.contains)
      && !text.contains("按行合并"),
      "and says it all before the batch starts:\n" + text)
    let full = ScanPlan.make(alone, physicalMM: bed, dpi: 2400, bitsPerChannel: 16, export: nil, speed: nil, available: 600e6)
    try check(!full.fits && full.summary.hasPrefix("磁盘空间不足") && full.exportBytes == 0,
      "a batch that would fill the disk says so first")
    try check(ScanPlan.duration(44) == "约 40 秒" && ScanPlan.duration(3600) == "约 1 小时" && ScanPlan.duration(5000) == "约 1 小时 23 分钟",
      "times read in seconds, minutes or hours")

    // Timing this scanner: each finished pass refines how it keeps time at that resolution.
    let prefs = Preferences()
    let predicted = plan.seconds / 36
    prefs.recordScan(backend: "epson2-linear-v1", dpi: 2400, seconds: 45, predicted: predicted)
    prefs.recordScan(backend: "epson2-linear-v1", dpi: 2400, seconds: 50, predicted: predicted)
    prefs.recordScan(backend: "epson2-linear-v1", dpi: 2400, seconds: .nan, predicted: predicted)
    let rate = prefs.scanSpeed[ScanPlan.speedKey(backend: "epson2-linear-v1", dpi: 2400)] ?? 0
    try check(abs(rate - (45 + 50) / 2 / predicted) < 1e-9 && prefs.scanSpeed.count == 1,
      String(format: "finished scans time this scanner: %.2f× the V850's measured pace at 2400 dpi", rate))
    let timed = ScanPlan.make(alone, physicalMM: bed, dpi: 2400, bitsPerChannel: 16, export: nil, speed: rate, available: nil)
    try check(timed.measured && timed.seconds > plan.seconds && timed.summary.contains("按本机 2400 dpi 的实测") && timed.fits,
      "and the next batch's estimate uses it")

    // The toolbar asks first for a batch, and starts only on yes.
    let scanner = model.scanner as! IdleScanner
    model.physicalMM = bed
    model.dpi = 2400
    model.frames = [frame("01"), frame("02"), frame("03")]
    var asked: ScanPlan?
    model.confirmScan = { plan, _, _ in asked = plan; return false }
    model.requestScanEnabled()
    try check(asked?.frames == 3 && asked?.dpi == 2400 && scanner.requests == 0 && !model.scanBatch.isActive,
      "scanning the ticked frames asks first, and cancelling starts nothing")
    model.selectedID = model.frames[0].id
    asked = nil
    model.requestScanSelected()
    try check(asked == nil && scanner.requests == 1 && model.scanBatch.isActive,
      "one frame with room to spare starts without asking")
    // The scan comes back: its time goes into the rate for this backend and resolution.
    let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 16, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let file = folder.appendingPathComponent("usability-scan.tif")
    try ImagePipeline.shared.saveTIFF(ctx.makeImage()!, to: file, dpi: 2400)
    try check(model.preferences.scanSpeed.isEmpty, "nothing is timed before a scan finishes")
    scanner.finish(file)
    let key = ScanPlan.speedKey(backend: scanner.backendID, dpi: 2400)
    try check(model.preferences.scanSpeed.keys.sorted() == [key] && model.frames[0].scanPath == file.path,
      "a finished scan is timed for the next estimate, under its backend and resolution: \(model.preferences.scanSpeed)")

    // Frames chosen together, to export at once: ⌘ adds or takes one away, ⇧ takes the run from the
    // frame shown, which stays shown; a plain click, or another frame selected, goes back to one.
    model.frames.append(frame("04"))
    let ids = model.frames.map(\.id)
    model.selectedID = ids[0]
    let added = model.choose(ids[2], modifiers: .command)
    let afterAdd = model.selection.map(\.name)
    _ = model.choose(ids[2], modifiers: .command)
    let afterToggle = model.selection.map(\.name)
    let ran = model.choose(ids[3], modifiers: .shift)
    let afterRun = model.selection.map(\.name), title = model.exportSelectionTitle
    let plain = model.choose(ids[1], modifiers: [])
    let afterPlain = model.selection.map(\.name)
    _ = model.choose(ids[3], modifiers: .command)
    model.selectedID = ids[1]
    let afterSelect = model.selection.map(\.name)
    try check(added && afterAdd == ["01", "03"] && afterToggle == ["01"] && ran && afterRun == ["01", "02", "03", "04"]
      && title == "导出所选的 4 张…" && model.selectedID == ids[1] && !plain && afterPlain == ["01"] && afterSelect == ["02"]
      && model.exportSelectionTitle == "导出当前…",
      "⌘ and ⇧ choose frames to export together, the frame shown kept; a plain click or another frame lets them go (\(afterAdd), \(afterRun), \(title))")
  }
}
