import AppKit
import SwiftUI

enum ScanProgressTests {
  /// Exercises the production queue/callback wiring without starting device discovery or scanning.
  private final class TestScanner: ScannerController {
    var requests = [String]()
    var cancellations = 0
    var startError: Error?
    override func scan(rect: NormalRect, dpi: Int, directory: URL, name: String) throws {
      if let startError { throw startError }
      requests.append(name)
      busy = true
      progress = 0
    }
    override func cancel() { cancellations += 1 }
    func complete(file: URL? = nil, error: Error? = nil) {
      if let file { onScan?(file) }
      busy = false
      progress = 1  // The real driver resets this even on error; it must not finish a failed batch.
      onFinished?(error)
    }
  }

  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }
      print("PASS: " + label)
    }
    func waitForQueue() {
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    var batch = ScanBatchProgress()
    try check(batch.fraction(frameProgress: .nan) == 0, "empty scan progress is finite and zero")
    batch = ScanBatchProgress(total: 18)
    for _ in 0..<2 {
      batch.beginFrame()
      batch.completeFrame()
    }
    batch.beginFrame()
    try check(
      batch.label(frameProgress: 0.42) == "第 3 / 18 张 · 本张 42%"
        && abs(batch.fraction(frameProgress: 0.42) - 2.42 / 18) < 0.00001,
      "batch fraction combines completed frames with current frame percentage")
    try check(
      batch.fraction(frameProgress: .infinity).isFinite
        && batch.fraction(frameProgress: -10) == 2.0 / 18
        && batch.fraction(frameProgress: 100) < 3.0 / 18,
      "driver progress is clamped and never counts an uncommitted frame as complete")
    batch.completeFrame()
    try check(
      batch.current == nil && batch.isActive && batch.fraction(frameProgress: 1) == 3.0 / 18,
      "inter-frame progress ignores the preceding frame's 100 percent")

    let scanner = TestScanner()
    let model = AppModel(
      libraryURL: folder.appendingPathComponent("scan-progress"), scanner: scanner)
    let original = folder.appendingPathComponent("progress-original.png")
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<32 {
      for x in 0..<32 {
        bitmap.setColor(NSColor(deviceRed: 1, green: 0.5, blue: 0, alpha: 1), atX: x, y: y)
      }
    }
    try ImagePipeline.shared.savePNG(bitmap.cgImage!, to: original)
    var imported = FilmFrame(name: "导入", rect: .full, format: "导入")
    imported.sourcePath = original.path
    var unchecked = FilmFrame(name: "12", rect: .full, format: "135")
    unchecked.enabled = false
    model.frames = [
      FilmFrame(name: "04", rect: .full, format: "135"),
      imported,
      FilmFrame(name: "09", rect: .full, format: "135"),
      unchecked,
    ]
    model.scanEnabled()
    scanner.progress = 0.42
    try check(
      model.scanBatch.total == 2 && model.scanBatch.current == 1
        && scanner.requests.count == 1 && model.scanProgressLabel == "第 1 / 2 张 · 本张 42%"
        && abs(model.scanProgressFraction - 0.21) < 0.00001,
      "scan queue freezes actual target count, excluding imported and unchecked images")

    // Render only our own toolbar into an offscreen bitmap, never capture the user's desktop.
    let toolbar = NSHostingView(
      rootView: ContentView(m: model).scanProgress.padding(12)
        .background(Color(red: 0.135, green: 0.14, blue: 0.145)).preferredColorScheme(.dark)
        .tint(Color(red: 0.91, green: 0.68, blue: 0.37)))
    toolbar.frame = CGRect(x: 0, y: 0, width: 1120, height: 64)
    toolbar.layoutSubtreeIfNeeded()
    if let rendered = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds) {
      toolbar.cacheDisplay(in: toolbar.bounds, to: rendered)
      if let cg = rendered.cgImage {
        try ImagePipeline.shared.savePNG(
          cg, to: folder.appendingPathComponent("scan-progress-toolbar.png"))
      }
    }

    scanner.complete(file: original)
    scanner.onFinished?(nil)  // Duplicate callback must not advance the queue twice.
    model.setAllEnabled(false)
    model.scanEnabled()
    try check(
      model.scanBatch.completed == 1 && model.scanBatch.current == nil && model.isWorking
        && model.enabledCount == 3 && scanner.requests.count == 1
        && model.scanProgressFraction == 0.5,
      "batch remains locked and visible between frames; duplicate completion is ignored")
    model.cancel()
    try check(
      model.scanBatch.phase == .cancelled && !model.isWorking
        && model.status.contains("1 / 2") && model.scanProgressFraction == 0.5,
      "cancel between frames preserves the completed fraction and unlocks the workspace")
    model.selectedID = model.frames[2].id
    model.scanSelected()
    waitForQueue()
    try check(
      model.scanBatch.total == 1 && model.scanBatch.completed == 0 && scanner.requests.count == 2,
      "single-frame restart resets the denominator and ignores the old batch's delayed work")
    scanner.complete(file: original)
    try check(
      model.scanBatch.phase == .completed && model.scanProgressFraction == 1 && !model.isWorking
        && model.status == "扫描完成 · 1 / 1 张",
      "only a delivered file plus successful completion reaches 1 / 1")

    model.scanEnabled()
    scanner.complete(file: original)
    waitForQueue()
    try check(
      model.scanBatch.current == 2 && model.scanBatch.completed == 1
        && model.scanProgressLabel == "第 2 / 2 张 · 本张 0%",
      "the next actual scan advances the numerator and resets current frame progress")
    scanner.complete(file: original)
    try check(
      model.scanBatch.phase == .completed && model.scanBatch.completed == 2 && !model.isWorking,
      "full simulated batch finishes with exact total and releases the busy state")

    model.scanSelected()
    scanner.progress = 0.8
    model.cancel()
    try check(
      model.scanBatch.phase == .cancelling && model.isWorking && scanner.cancellations == 1,
      "cancel during a frame waits for the driver before unlocking")
    scanner.complete(error: DeskError.message("用户取消"))
    try check(
      model.scanBatch.phase == .cancelled && model.scanBatch.completed == 0
        && model.scanProgressFraction == 0 && model.errorText == nil && !model.isWorking,
      "cancel callback does not count an incomplete frame or show a false error")

    model.scanEnabled()
    scanner.complete(file: original)
    waitForQueue()
    scanner.busy = false
    scanner.progress = 1
    scanner.onFailure?("测试断线")
    scanner.onFinished?(DeskError.message("测试断线"))
    try check(
      model.scanBatch.phase == .failed && model.scanBatch.completed == 1
        && model.scanProgressFraction == 0.5 && model.scanQueue.isEmpty && !model.isWorking
        && model.status.contains("1 / 2") && model.errorText == "测试断线",
      "disconnect and duplicate failure retain only the completed files, never 100 percent")

    model.scanSelected()
    scanner.complete()
    try check(
      model.scanBatch.phase == .failed && model.scanBatch.completed == 0
        && model.errorText?.contains("没有返回可读取的图像") == true,
      "successful driver termination without a file is not reported as a completed scan")
    scanner.startError = DeskError.message("测试未就绪")
    model.scanSelected()
    try check(
      model.scanBatch.phase == .failed && !model.isWorking && model.scanProgressFraction == 0
        && model.errorText == "测试未就绪",
      "synchronous start failure leaves no hanging batch or false progress")

    // Positives go to Exports once the whole batch is scanned, not frame by frame.
    let exportScanner = TestScanner()
    let exporting = AppModel(libraryURL: folder.appendingPathComponent("auto-export"), scanner: exportScanner)
    exporting.preferences.autoExport = true
    let session = folder.appendingPathComponent("auto-export-session", isDirectory: true)
    try? FileManager.default.removeItem(at: session)
    exporting.sessionURL = session
    exporting.frames = [FilmFrame(name: "01", rect: .full, format: "135"), FilmFrame(name: "02", rect: .full, format: "135")]
    let exports = session.appendingPathComponent("Exports")
    func exported() -> [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? []).filter { $0.hasSuffix(".tif") }
    }
    exporting.scanEnabled()
    exportScanner.complete(file: original)
    waitForQueue()
    try check(exported().isEmpty, "nothing is exported while the batch is still scanning")
    exportScanner.complete(file: original)
    try check(exporting.status.hasSuffix("正在导出正片到 Exports…"), "the end of the batch says positives are being exported")
    let exportDeadline = Date().addingTimeInterval(15)
    while (exported().count < 2 || exporting.isWorking) && Date() < exportDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    try check(exported().count == 2 && exporting.status == "已导出 2 张到 Exports",
      "both scans of the batch are exported as positives when it ends")

    let empty = AppModel(libraryURL: folder, scanner: TestScanner())
    empty.scanEnabled()
    empty.frames = [imported]
    empty.scanEnabled()
    try check(
      empty.scanBatch.phase == .idle && empty.scanBatch.total == 0 && !empty.isWorking,
      "empty or imported-only selections do not create a zero-denominator scan batch")
  }
}
