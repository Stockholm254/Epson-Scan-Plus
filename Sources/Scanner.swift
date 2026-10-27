import AppKit
import Combine
import Foundation
import ImageCaptureCore

class ScannerController: NSObject, ObservableObject, ICDeviceBrowserDelegate,
  ICScannerDeviceDelegate
{
  @Published var name = "未连接扫描仪"
  @Published var status = "正在查找扫描仪…"
  @Published var ready = false
  @Published var busy = false
  @Published var progress = 0.0
  @Published var supportedDPI = [300, 600, 1200, 2400, 3200, 4800, 6400]
  @Published var bits = 8
  @Published var physicalMM = CGSize(width: 149.86, height: 246.38)
  @Published var log = [String]()
  /// What the next whole-holder preview asks for; ICA picks its own overview size.
  var previewDPI = 150
  private let browser = ICDeviceBrowser()
  private var scanner: ICScannerDevice?
  private var selectionRequested = false
  private var configured = false
  private var reopenOnClose = false
  private var progressTimer: Timer?
  private var watchdog: Timer?
  var onOverview: ((CGImage, CGSize, Double) -> Void)?
  var onScan: ((URL) -> Void)?
  var onFinished: ((Error?) -> Void)?
  var onFailure: ((String) -> Void)?
  var backendID: String { "ica-positive-v1" }
  var captureInputGamma: Double? { nil }
  var actualScanAreaMM: CGRect? { nil }
  var cancellationHint: String? { nil }
  /// True when an app-owned process holds USB and must finish its transfer before the app quits.
  var finishesScanBeforeQuit: Bool { false }
  var captureNote: String { "ICA 驱动开放 24-bit。48-bit 文件可通过 Epson Scan 2 扫描后导入。" }
  override init() {
    super.init()
    browser.delegate = self
    browser.browsedDeviceTypeMask = ICDeviceTypeMask(
      rawValue: ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
  }
  func record(_ s: String) {
    log.append(s)
    if log.count > 150 { log.removeFirst() }
    print(s)
    fflush(stdout)
  }
  func start() { if !browser.isBrowsing { browser.start() } }
  func reconnect() {
    guard !busy else { return }
    if let scanner {
      if scanner.hasOpenSession {
        reopenOnClose = true
        scanner.requestCloseSession()
      } else {
        scanner.requestOpenSession()
      }
    } else {
      browser.stop()
      browser.start()
    }
  }
  func close() {
    reopenOnClose = false
    watchdog?.invalidate()
    progressTimer?.invalidate()
    if busy { scanner?.cancelScan() }
    scanner?.requestCloseSession()
    ready = false
  }
  func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    guard let s = device as? ICScannerDevice, scanner == nil else { return }
    scanner = s
    name = s.name ?? "Epson"
    s.delegate = self
    status = "连接 \(name)…"
    record(status)
    s.requestOpenSession()
  }
  func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
    if device === scanner { didRemove(device) }
  }
  func didRemove(_ device: ICDevice) {
    scanner = nil
    ready = false
    busy = false
    configured = false
    selectionRequested = false
    status = "扫描仪已断开"
    onFinished?(DeskError.message(status))
  }
  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
    if let error {
      fail("无法打开扫描仪：\(error.localizedDescription)。请关闭占用它的 Epson Scan 2 或图像捕捉，再点重新连接。")
      return
    }
    status = "读取透扫能力…"
    selectionRequested = false
    configured = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.selectTransparency()
    }
  }
  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
    ready = false
    configured = false
    selectionRequested = false
    status = "扫描仪会话已关闭"
    if reopenOnClose {
      reopenOnClose = false
      device.requestOpenSession()
    }
  }
  func deviceDidBecomeReady(_ device: ICDevice) { selectTransparency() }
  func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) {
    if !scanner.hasOpenSession { scanner.requestOpenSession() }
  }
  private func selectTransparency() {
    guard let s = scanner, s.hasOpenSession, !selectionRequested,
      !s.availableFunctionalUnitTypes.isEmpty
    else { return }
    guard
      s.availableFunctionalUnitTypes.contains(
        NSNumber(value: ICScannerFunctionalUnitType.positiveTransparency.rawValue))
    else {
      fail("驱动未开放透扫模式。")
      return
    }
    selectionRequested = true
    s.requestSelect(.positiveTransparency)
  }
  func scannerDevice(
    _ scanner: ICScannerDevice, didSelect unit: ICScannerFunctionalUnit, error: Error?
  ) {
    if let error {
      fail(error.localizedDescription)
      return
    }
    if unit.type != .positiveTransparency {
      selectTransparency()
      return
    }
    guard !configured else { return }
    configured = true
    unit.pixelDataType = .RGB
    unit.measurementUnit = .centimeters
    unit.scaleFactor = 100
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      self?.finishConfiguration()
    }
  }
  private func finishConfiguration() {
    guard let s = scanner else { return }
    let u = s.selectedFunctionalUnit
    bits = u.supportedBitDepths.contains(16) ? 16 : 8
    u.bitDepth = bits == 16 ? .depth16Bits : .depth8Bits
    bits = Int(u.bitDepth.rawValue)
    physicalMM = CGSize(width: u.physicalSize.width * 10, height: u.physicalSize.height * 10)
    supportedDPI = [300, 600, 1200, 1800, 2400, 3200, 4800, 6400].filter {
      u.supportedResolutions.contains($0)
    }
    for f in u.vendorFeatures ?? [] {
      if let e = f as? ICScannerFeatureEnumeration,
        let i = e.menuItemLabels.firstIndex(where: {
          $0.lowercased() == "none" || $0.lowercased() == "off"
        })
      {
        e.currentValue = e.values[i]
      }
      if let b = f as? ICScannerFeatureBoolean { b.value = false }
    }
    ready = true
    status = "透扫就绪 · \(bits*3)-bit RGB"
    record(
      "\(name) / \(physicalMM.width)×\(physicalMM.height) mm / \(bits) bit/channel / \(supportedDPI) dpi"
    )
  }
  func preview() {
    guard let s = scanner, ready, !busy else { return }
    s.selectedFunctionalUnit.overviewResolution = 150
    begin("预览扫描中…")
    s.requestOverviewScan()
  }
  func scan(rect: NormalRect, dpi: Int, directory: URL, name: String) throws {
    guard let s = scanner, ready, !busy else { throw DeskError.message("扫描仪尚未就绪。") }
    guard supportedDPI.contains(dpi) else { throw DeskError.message("驱动不支持该分辨率。") }
    let u = s.selectedFunctionalUnit
    u.resolution = dpi
    u.bitDepth = bits == 16 ? .depth16Bits : .depth8Bits
    u.scanArea = CGRect(
      x: rect.x * u.physicalSize.width, y: rect.y * u.physicalSize.height,
      width: rect.width * u.physicalSize.width, height: rect.height * u.physicalSize.height)
    s.transferMode = .fileBased
    s.downloadsDirectory = directory
    s.documentName = name
    s.documentUTI = "public.tiff"
    begin("扫描 \(name) · \(dpi) dpi…")
    s.requestScan()
  }
  private func begin(_ text: String) {
    busy = true
    status = text
    progress = 0
    record(text)
    progressTimer?.invalidate()
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
      guard let self, let s = self.scanner else { return }
      self.progress = Double(s.selectedFunctionalUnit.scanProgressPercentDone) / 100
    }
    watchdog?.invalidate()
    watchdog = Timer.scheduledTimer(withTimeInterval: 900, repeats: false) { [weak self] _ in
      self?.cancel()
      self?.fail("扫描超时，请检查连接后重试。")
    }
  }
  func cancel() {
    scanner?.cancelScan()
    status = "正在取消…"
  }
  private func end() {
    busy = false
    progressTimer?.invalidate()
    watchdog?.invalidate()
    progress = 1
  }
  private func fail(_ message: String) {
    end()
    status = message
    record(message)
    onFailure?(message)
  }
  func scannerDevice(_ scanner: ICScannerDevice, didCompleteOverviewScanWithError error: Error?) {
    end()
    if let error {
      fail("预览失败：\(error.localizedDescription)")
      return
    }
    guard let cg = scanner.selectedFunctionalUnit.overviewImage else {
      fail("驱动没有返回预览图像。")
      return
    }
    status = "预览完成"
    record("Overview \(cg.width)×\(cg.height)")
    onOverview?(cg, physicalMM, Double(scanner.selectedFunctionalUnit.overviewResolution))
  }
  func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
    record("扫描完成：\(url.lastPathComponent)")
    onScan?(url)
  }
  func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
    end()
    status = error?.localizedDescription ?? "扫描完成"
    onFinished?(error)
  }
  func device(_ device: ICDevice, didEncounterError error: Error?) {
    if let error {
      fail(error.localizedDescription)
      onFinished?(error)
    }
  }
}
