import AppKit
import Foundation

/// A separate process owns USB only while probing/scanning. No ICA browser is started.
final class SaneScannerController: ScannerController {
  override var backendID: String { "epson2-linear-v1" }
  override var captureInputGamma: Double? { 1 }
  override var actualScanAreaMM: CGRect? { lastArea }
  override var cancellationHint: String? { cancelled && busy ? "等待当前扫描结束后停止" : nil }
  override var finishesScanBeforeQuit: Bool { true }
  private var lastArea: CGRect?
  private var previewingDPI = 150
  override var captureNote: String { "epson2 · 48-bit 实验接口\n线性采集，输入 Gamma 1.0；无除尘、自动调色或锐化。" }
  private let helper: URL
  private let backend: URL
  private let config: URL
  private let worker = DispatchQueue(label: "EpsonScanPlus.USB", qos: .userInitiated)
  private var process: Process?
  private var job = UUID()
  private var started = false
  private var cancelled = false
  private var closing = false
  init(resources: URL = Bundle.main.resourceURL!) {
    helper = resources.appendingPathComponent("Scanner/SaneCapture")
    backend = resources.appendingPathComponent("Scanner/libsane-epson2.1.dylib")
    config = resources.appendingPathComponent("Scanner/config")
    super.init()
    name = "EPSON V800/V850"
    status = "正在检测 48-bit 透扫…"
    bits = 16
  }
  override func start() {
    guard !started, !busy else { return }
    started = true
    probe()
  }
  override func reconnect() { guard !busy else { return }; started = true; probe() }
  private func probe() {
    ready = false
    launch(arguments: ["--probe"], output: nil, preview: false)
  }
  override func preview() {
    guard ready, !busy else { return }
    do {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EpsonScanPlus-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      let output = folder.appendingPathComponent("overview.tiff")
      let dpi = [150, 300, 600].contains(previewDPI) ? previewDPI : 150
      let args = try Self.captureArguments(rect: .full, dpi: dpi, size: physicalMM, output: output)
      previewingDPI = dpi
      launch(arguments: args, output: output, preview: true)
    } catch { onFailure?(error.localizedDescription) }
  }
  override func scan(rect: NormalRect, dpi: Int, directory: URL, name: String) throws {
    guard ready, !busy else { throw DeskError.message("扫描仪尚未就绪。") }
    guard supportedDPI.contains(dpi) else { throw DeskError.message("不支持该分辨率。") }
    guard !name.contains("/"), !name.isEmpty else { throw DeskError.message("扫描文件名无效。") }
    let output = directory.appendingPathComponent(name).appendingPathExtension("tiff")
    let args = try Self.captureArguments(rect: rect, dpi: dpi, size: physicalMM, output: output)
    launch(arguments: args, output: output, preview: false)
  }
  static func captureArguments(rect: NormalRect, dpi: Int, size: CGSize, output: URL) throws -> [String] {
    let values = [rect.x, rect.y, rect.width, rect.height, size.width, size.height]
    guard values.allSatisfy(\.isFinite), rect.x >= 0, rect.y >= 0,
      rect.width > 0, rect.height > 0, rect.x + rect.width <= 1.00000001,
      rect.y + rect.height <= 1.00000001,
      size.width > 100, size.width <= 151, size.height > 200, size.height <= 247,
      [150, 300, 600, 1200, 1800, 2400, 3200, 4800, 6400].contains(dpi)
    else { throw DeskError.message("扫描范围或分辨率无效。") }
    let w = rect.width * size.width, h = rect.height * size.height
    guard w >= 0.5, h >= 0.5,
      ceil(w / 25.4 * Double(dpi)) * ceil(h / 25.4 * Double(dpi)) * 6 <= 768 * 1024 * 1024
    else { throw DeskError.message("扫描区域过小或数据量过大，请逐张扫描或降低 dpi。") }
    guard !FileManager.default.fileExists(atPath: output.path) else { throw DeskError.message("原始文件已存在，不会覆盖。") }
    func number(_ v: Double) -> String { String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), v) }
    return ["--scan", String(dpi), number(rect.x * size.width), number(rect.y * size.height),
      number(w), number(h), "--output", output.path]
  }
  static func loadDetachedPreview(_ url: URL) throws -> CGImage {
    // ImageIO loads lazily. Own decoded pixels before removing the helper's temp TIFF.
    let image = try ImagePipeline.shared.load(url)
    guard let data = image.dataProvider?.data, let provider = CGDataProvider(data: data),
      let space = image.colorSpace,
      let detached = CGImage(width: image.width, height: image.height,
        bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
        bytesPerRow: image.bytesPerRow, space: space, bitmapInfo: image.bitmapInfo,
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw DeskError.message("无法保留 48-bit 预览像素。") }
    return detached
  }
  private func launch(arguments: [String], output: URL?, preview: Bool) {
    guard !busy else { return }
    let id = UUID(); job = id; cancelled = false; closing = false; lastArea = nil
    let p = Process(), pipe = Pipe()
    p.executableURL = helper
    p.arguments = [backend.path, config.path] + arguments
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SANE_") }
    environment["LC_ALL"] = "C"
    p.environment = environment
    p.standardOutput = pipe; p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    busy = true; progress = 0
    status = output == nil ? "读取 48-bit 透扫能力…" : (preview ? "48-bit 预览扫描中…" : "48-bit 扫描中…")
    record(status)
    process = p
    do { try p.run() } catch {
      process = nil; busy = false; ready = false
      status = "无法启动 48-bit 接口：\(error.localizedDescription)"
      if preview, let output { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
      onFailure?(status)
      return
    }
    worker.async { [weak self] in
      var pending = Data(), capability: [String: Any]?, file: String?, receipt: [String: Any]?, errorMessage: String?
      var diagnostics = ""
      func consume(_ line: Data) {
        if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let event = value["event"] as? String {
          switch event {
          case "capabilities": capability = value
          case "file": file = value["path"] as? String; receipt = value
          case "error": errorMessage = value["message"] as? String
          case "progress":
            if let fraction = value["value"] as? Double, fraction.isFinite {
              DispatchQueue.main.async {
                guard let self, self.job == id else { return }
                self.progress = max(self.progress, min(0.99, max(0, fraction)))
              }
            }
          default: break
          }
        } else if let text = String(data: line, encoding: .utf8) {
          diagnostics = String((diagnostics + text + "\n").suffix(4000))
        }
      }
      while true {
        let data = pipe.fileHandleForReading.availableData
        if data.isEmpty { break }
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
          consume(Data(pending[..<end])); pending.removeSubrange(...end)
        }
        if pending.count > 65536 { pending.removeAll() }
      }
      if !pending.isEmpty { consume(pending) }
      p.waitUntilExit()
      var image: CGImage?
      var resultError = errorMessage
      if p.terminationStatus == 0 && output != nil {
        do {
          guard let output, file == output.path else { throw DeskError.message("接口没有返回扫描文件。") }
          let info = ImagePipeline.shared.info(output)
          guard info.bits == 16, info.width > 0, info.height > 0 else { throw DeskError.message("扫描文件不是有效的 48-bit TIFF。") }
          if preview { image = try Self.loadDetachedPreview(output) }
        } catch { resultError = error.localizedDescription }
      }
      if preview, let output { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
      let returnedCapability = capability, returnedImage = image, returnedError = resultError, returnedDiagnostics = diagnostics, returnedReceipt = receipt
      DispatchQueue.main.async {
        guard let self, self.job == id else { return }
        self.process = nil; self.busy = false
        guard !self.closing else { return }
        if self.cancelled {
          self.status = "扫描已取消"
          if output != nil && !preview { self.onFinished?(DeskError.message(self.status)) }
          return
        }
        if let error = returnedError ?? (p.terminationStatus == 0 ? nil : "48-bit 接口异常退出。请检查连接并重新连接。") {
          self.ready = false; self.status = error; self.record(error)
          if !returnedDiagnostics.isEmpty { self.record(returnedDiagnostics) }
          self.onFailure?(error)
          return
        }
        guard let c = returnedCapability, c["bits"] as? Int == 16,
          let w = c["widthMM"] as? Double, let h = c["heightMM"] as? Double,
          w > 100, w <= 151, h > 200, h <= 247, let resolutions = c["dpi"] as? [Int]
        else { self.ready = false; self.onFailure?("接口未确认 48-bit 透扫能力。"); return }
        self.name = c["name"] as? String ?? "EPSON V800/V850"
        self.physicalMM = CGSize(width: w, height: h)
        self.supportedDPI = resolutions.filter { $0 >= 300 }
        self.bits = 16; self.ready = true; self.progress = 1
        if output != nil {
          guard let r = returnedReceipt, let x = r["xMM"] as? Double, let y = r["yMM"] as? Double,
            let width = r["widthMM"] as? Double, let height = r["heightMM"] as? Double,
            [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
            x + width <= w + 0.001, y + height <= h + 0.001
          else { self.onFailure?("扫描完成，但缺少实际采集范围；未绑定到画面。"); return }
          self.lastArea = CGRect(x: x, y: y, width: width, height: height)
        }
        if preview, let image = returnedImage {
          self.status = "48-bit 预览完成"
          self.onOverview?(image, self.lastArea!.size, Double(self.previewingDPI))
        } else if let output {
          self.status = "48-bit 扫描完成"; self.record(output.lastPathComponent)
          self.onScan?(output); self.onFinished?(nil)
        } else { self.status = "透扫就绪 · 48-bit RGB · epson2（实验）" }
      }
    }
  }
  override func cancel() {
    guard busy else { return }
    cancelled = true; status = "正在取消：等待当前扫描完成归位，不再扫描下一张…"
    if process?.isRunning == true { process?.interrupt() }
  }
  override func close() {
    cancel(); closing = true; ready = false; started = false
  }
}
