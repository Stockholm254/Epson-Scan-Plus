import AppKit
import ImageCaptureCore

/// The camera's pixel shift, which Sony's Camera Remote SDK does not reach on the A7R IV: read and
/// set over the camera's own PTP (Sony's vendor operations, as libgphoto2 speaks them), through
/// macOS's image capture. Only while the SDK has let go of the camera: the two cannot share it.
/// And only in a process of its own (`inChild`): image capture's daemon, ptpcamerad, keeps the
/// camera's USB for as long as the process that opened it lives, its session closed or not, and
/// the SDK cannot connect until that process is gone (seen in the app 2026-11-06).
///
/// As found on the A7R IV (2026-11-05/06): pixel shift on is 0xD239 (read only), switched by
/// ControlDevice 0xD2D4 (2 on, 1 off); its count is 0xD23A (1, 4, 16). Both take effect only with
/// the computer's priority (0xD25A = 1) set first in the same session, which ends with it, and
/// read back as set only in the next session. Nothing else is written; no file is read.
final class SonyPTP: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
  enum Failure: LocalizedError {
    case noCamera, session(String), answered(UInt16, UInt16), unread, child(String)
    var errorDescription: String? {
      switch self {
      case .noCamera: return "电脑上没有找到 Sony 相机（开着吗？USB 连接方式是「PC 遥控」吗？）"
      case .session(let why): return "打不开和相机的会话：" + why
      case .answered(let op, let code): return String(format: "相机拒绝了操作 0x%04X（0x%04X）", op, code)
      case .unread: return "读不出相机的像素位移设置"
      case .child(let why): return why
      }
    }
  }

  /// The pictures a press takes as the camera is set: 1 with pixel shift off, else 4 or 16.
  static func pixelShift(timeout: TimeInterval = 6) async throws -> Int {
    let link = SonyPTP()
    try await link.open(timeout)
    defer { link.close() }
    return try await link.shots()
  }
  /// Sets the camera to take `count` pictures a press (1 switches pixel shift off), and returns
  /// what it then reads, in a session of its own.
  static func setPixelShift(_ count: Int, timeout: TimeInterval = 6) async throws -> Int {
    let link = SonyPTP()
    try await link.open(timeout)
    let before: (on: Bool, number: Int)
    do {
      before = try await link.state()
      if (before.on ? before.number : 1) != count {
        try await link.write(setProp, priority, Data([1]))
        try await link.pause(0.8)
        if count == 1 {
          try await link.write(control, shiftSwitch, le16(1))
        } else {
          if !before.on {
            try await link.write(control, shiftSwitch, le16(2))
            try await link.pause(0.5)
          }
          if before.number != count { try await link.write(setProp, shiftNumber, le16(UInt16(count))) }
        }
        try await link.pause(0.5)
      }
    } catch {
      link.close()
      throw error
    }
    link.close()
    if (before.on ? before.number : 1) == count { return count }
    try await Task.sleep(nanoseconds: 300_000_000)
    return try await pixelShift(timeout: timeout)
  }

  private static let connectOp: UInt16 = 0x9201, extInfo: UInt16 = 0x9202, setProp: UInt16 = 0x9205,
    control: UInt16 = 0x9207, allProps: UInt16 = 0x9209
  private static let shiftOn: UInt16 = 0xD239, shiftNumber: UInt16 = 0xD23A, priority: UInt16 = 0xD25A,
    shiftSwitch: UInt16 = 0xD2D4
  private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }

  private var browser: ICDeviceBrowser?
  private var camera: ICCameraDevice?
  private var opened: CheckedContinuation<Void, Error>?
  private var transaction: UInt32 = 1

  /// Finds the camera, opens a session and makes Sony's handshake (protocol 300, which lists the
  /// pixel-shift properties).
  private func open(_ timeout: TimeInterval) async throws {
    do { try await start(timeout) } catch {
      close()
      throw error
    }
  }
  private func start(_ timeout: TimeInterval) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      DispatchQueue.main.async {
        self.opened = c
        let browser = ICDeviceBrowser()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        self.browser = browser
        browser.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { self.opening(self.camera == nil ? Failure.noCamera : Failure.session("相机没有回应")) }
      }
    }
    for step: UInt32 in [1, 2] { try await check(Self.connectOp, [step, 0, 0]) }
    try await check(Self.extInfo, [300])
    try await check(Self.connectOp, [3, 0, 0])
  }
  private func opening(_ error: Error?) {
    guard let c = opened else { return }
    opened = nil
    if let error { c.resume(throwing: error) } else { c.resume() }
  }
  /// Ends the session and lets go of the camera, for the SDK to have it again.
  private func close() {
    DispatchQueue.main.async {
      self.camera?.requestCloseSession()
      self.browser?.stop()
      self.browser?.delegate = nil
      self.browser = nil
    }
  }
  private func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

  /// Pixel shift on, and its count.
  private func state() async throws -> (on: Bool, number: Int) {
    let values = Self.currents(try await check(Self.allProps))
    guard let on = values[Self.shiftOn], let number = values[Self.shiftNumber] else { throw Failure.unread }
    return (on != 0, Int(number))
  }
  private func shots() async throws -> Int {
    let s = try await state()
    return s.on ? s.number : 1
  }

  @discardableResult
  private func check(_ op: UInt16, _ params: [UInt32] = [], out: Data? = nil) async throws -> Data {
    let r = try await send(op, params, out: out)
    guard r.code == 0x2001 else { throw Failure.answered(op, r.code) }
    return r.data
  }
  private func write(_ op: UInt16, _ code: UInt16, _ value: Data) async throws {
    try await check(op, [UInt32(code)], out: value)
  }
  private func send(_ op: UInt16, _ params: [UInt32], out: Data?) async throws -> (data: Data, code: UInt16) {
    var command = Data()
    func le32(_ v: UInt32) { for i in 0..<4 { command.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    le32(UInt32(12 + 4 * params.count))
    command.append(contentsOf: [1, 0, UInt8(op & 0xFF), UInt8(op >> 8)])
    le32(transaction)
    transaction += 1
    params.forEach(le32)
    return try await withCheckedThrowingContinuation { c in
      DispatchQueue.main.async {
        guard let camera = self.camera else { c.resume(throwing: Failure.noCamera); return }
        camera.requestSendPTPCommand(command, outData: out) { data, response, error in
          if let error { c.resume(throwing: error); return }
          c.resume(returning: (data, response.count >= 8 ? UInt16(Self.le(response, 6, 2)) : 0))
        }
      }
    }
  }

  // MARK: In a process of its own

  /// The pictures a press takes, read (`["read"]`) or set (`["set", "16"]`) by this app started
  /// again with `--sony-ptp`, which is gone before this returns, the camera's USB let go with it.
  static func inChild(_ arguments: [String], executable: URL? = Bundle.main.executableURL,
                      timeout: TimeInterval = 40) async throws -> Int {
    guard let executable else { throw Failure.child("找不到 App 自己的程序") }
    let p = Process()
    p.executableURL = executable
    p.arguments = ["--sony-ptp"] + arguments
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    let said: Data = try await withCheckedThrowingContinuation { c in
      p.terminationHandler = { _ in c.resume(returning: out.fileHandleForReading.readDataToEndOfFile()) }
      do { try p.run() } catch {
        p.terminationHandler = nil
        c.resume(throwing: error)
        return
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    }
    // ptpcamerad lets the USB go as the process ends: a moment for it before the SDK connects.
    try await Task.sleep(nanoseconds: 500_000_000)
    return try answer(said)
  }
  /// The last line `--sony-ptp` printed: `{"shots":N}`, or `{"error":"…"}`.
  static func answer(_ said: Data) throws -> Int {
    let line = said.split(separator: 10).last.map { Data($0) } ?? Data()
    guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
      throw Failure.child("相机的设置没有读完（读取它的进程没有回答）")
    }
    if let shots = o["shots"] as? Int { return shots }
    throw Failure.child(o["error"] as? String ?? "读取相机设置的进程出错了")
  }
  /// `EpsonScanPlus --sony-ptp read | set N`: one line, as `answer` reads it, and the process ends.
  static func runChild() -> Never {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let args = CommandLine.arguments
    let rest = args.firstIndex(of: "--sony-ptp").map { Array(args[($0 + 1)...]) } ?? []
    func finish(_ object: [String: Any]) -> Never {
      var line = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
      line.append(10)
      FileHandle.standardOutput.write(line)
      exit(0)
    }
    Task {
      var result: [String: Any]
      do {
        if rest.first == "set", rest.count > 1, let n = Int(rest[1]) {
          result = ["shots": try await setPixelShift(n)]
        } else {
          result = ["shots": try await pixelShift()]
        }
      } catch { result = ["error": error.localizedDescription] }
      // The session's close goes out before the process ends.
      try? await Task.sleep(nanoseconds: 300_000_000)
      DispatchQueue.main.async { finish(result) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish(["error": "相机 30 秒没有回应"]) }
    RunLoop.main.run()
    exit(0)
  }

  // MARK: Sony's property list

  private static func le(_ d: Data, _ o: Int, _ n: Int) -> UInt64 {
    (0..<n).reduce(0) { $0 | UInt64(d[d.startIndex + o + $1]) << (8 * UInt64($1)) }
  }
  /// The current value of each scalar property in GetAllExtDevicePropInfo's answer: per property
  /// its code, type, two flags, default and current value, and its form (none, a range, or one or
  /// two enumerations), as libgphoto2 reads Sony's.
  static func currents(_ d: Data) -> [UInt16: UInt64] {
    func size(_ type: UInt16) -> Int? {
      switch type {
      case 1, 2: return 1
      case 3, 4: return 2
      case 5, 6: return 4
      case 7, 8: return 8
      case 9, 10: return 16
      default: return nil
      }
    }
    /// A value at `o`: its integer when scalar, and the offset after it.
    func value(_ o: Int, _ type: UInt16) -> (UInt64?, Int)? {
      if let n = size(type) {
        guard o + n <= d.count else { return nil }
        return (n <= 8 ? le(d, o, n) : nil, o + n)
      }
      if type == 0xFFFF {
        guard o < d.count else { return nil }
        let end = o + 1 + 2 * Int(d[d.startIndex + o])
        return end <= d.count ? (nil, end) : nil
      }
      if type & 0x4000 != 0, let n = size(type & 0x0FFF) {
        guard o + 4 <= d.count else { return nil }
        let end = o + 4 + Int(le(d, o, 4)) * n
        return end <= d.count ? (nil, end) : nil
      }
      return nil
    }
    func list(_ at: Int, _ type: UInt16) -> Int? {
      guard at + 2 <= d.count else { return nil }
      var q = at + 2
      for _ in 0..<Int(le(d, at, 2)) {
        guard let v = value(q, type) else { return nil }
        q = v.1
      }
      return q
    }
    var out = [UInt16: UInt64]()
    var o = 8
    while o + 6 <= d.count {
      let code = UInt16(le(d, o, 2)), type = UInt16(le(d, o + 2, 2))
      guard let def = value(o + 6, type), let cur = value(def.1, type) else { break }
      if let v = cur.0 { out[code] = v }
      var p = cur.1
      guard p < d.count else { break }
      let form = d[d.startIndex + p]
      p += 1
      if form == 1 {
        guard let lo = value(p, type), let hi = value(lo.1, type), let step = value(hi.1, type) else { break }
        p = step.1
      } else if form == 2 {
        guard let first = list(p, type) else { break }
        p = first
        // Newer Sonys send a second list (what may be set); a property code after it is ≥ 0x200.
        if p + 2 <= d.count, le(d, p, 2) < 0x200, let second = list(p, type) { p = second }
      }
      o = p
    }
    return out
  }

  // MARK: Image capture's callbacks

  func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    guard camera == nil, device.usbVendorID == 0x054C, let found = device as? ICCameraDevice else { return }
    camera = found
    found.delegate = self
    found.requestOpenSession()
  }
  func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
    if let error { opening(Failure.session(error.localizedDescription)); return }
    // The session answers PTP at once; the camera's catalogue, which is not wanted, may take longer.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.opening(nil) }
  }
  func didRemove(_ device: ICDevice) {}
  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
  func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
  func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
  func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
  func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
  func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
  func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
  func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
  func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
  func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
  func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
