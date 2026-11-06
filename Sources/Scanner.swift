import AppKit
import Combine
import Foundation

/// The scanner as the app sees it: its state, and what it is asked to do. This base finds no
/// scanner and does nothing, for where none is wanted (the tests); `SaneScannerController` drives
/// the V850 over SANE, at 48 bits.
class ScannerController: NSObject, ObservableObject {
  @Published var name = "未连接扫描仪"
  @Published var status = "正在查找扫描仪…"
  @Published var ready = false
  @Published var busy = false
  @Published var progress = 0.0
  @Published var supportedDPI = [300, 600, 1200, 2400, 3200, 4800, 6400]
  @Published var bits = 8
  @Published var physicalMM = CGSize(width: 149.86, height: 246.38)
  @Published var log = [String]()
  /// A preview while it is read: what the scanner has sent so far, small, the rest clear. Nil
  /// otherwise, and once the preview is done.
  @Published var previewSoFar: CGImage?
  /// What the next whole-holder preview asks for.
  var previewDPI = 150
  var onOverview: ((CGImage, CGSize, Double) -> Void)?
  var onScan: ((URL) -> Void)?
  var onFinished: ((Error?) -> Void)?
  var onFailure: ((String) -> Void)?
  var backendID: String { "none" }
  var captureInputGamma: Double? { nil }
  var actualScanAreaMM: CGRect? { nil }
  var cancellationHint: String? { nil }
  /// True when an app-owned process holds USB and must finish its transfer before the app quits.
  var finishesScanBeforeQuit: Bool { false }
  var captureNote: String { "" }
  func record(_ s: String) {
    log.append(s)
    if log.count > 150 { log.removeFirst() }
    print(s)
    fflush(stdout)
  }
  func start() {}
  func reconnect() {}
  func close() { ready = false }
  func preview() {}
  func scan(rect: NormalRect, dpi: Int, directory: URL, name: String) throws {
    throw DeskError.message("扫描仪尚未就绪。")
  }
  func cancel() {}
}
