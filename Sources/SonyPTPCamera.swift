import AppKit
import ImageCaptureCore

// The camera on the copy stand driven over its own PTP, as Sony's vendor operations go (the ones
// libgphoto2 speaks), through macOS's image capture: instead of Sony's Camera Remote SDK, which
// keeps the A7R IV's pixel shift out of reach. It is the app started again as
// `EpsonScanPlus --sony-ptp-camera`, a process of its own as the SDK's is, and it talks to the
// app in the same JSON lines (CameraHelper.cpp's commands and events), the camera's settings named
// and valued as the SDK names and values them, so the controller and the panel are the same for
// both. And one more command: {"cmd":"shift","count":16} sets the pixel shift without letting go
// of the camera; {"cmd":"shift"} reads it. Its answer, and any change made on the camera itself,
// is the event {"event":"shift","shots":N}.
//
// The process ends when the camera is let go of: image capture's daemon keeps the camera's USB for
// as long as the process that opened it lives (seen 2026-11-06), and another program (or the SDK)
// can have the camera only once it has gone.

// MARK: The wire

enum PTPFailure: LocalizedError, Equatable {
  case noCamera, noAnswer, refused(String), timeout(UInt16), gone, answered(UInt16, UInt16)
  var errorDescription: String? {
    switch self {
    case .noCamera: return "电脑上没有找到 Sony 相机"
    case .noAnswer: return "找到了相机，但它没有回应"
    case .refused(let why): return "相机拒绝了连接：" + why
    case .timeout(let op): return String(format: "相机没有回应操作 0x%04X", op)
    case .gone: return "相机已断开"
    case .answered(let op, let code): return String(format: "相机拒绝了操作 0x%04X（0x%04X）", op, code)
    }
  }
}

/// PTP with one camera, a transaction at a time: an operation, its parameters and the data sent
/// with it (nil when data comes back, or none), answered with that data and the response code.
protocol PTPTransport: AnyObject {
  /// Finds the camera and opens a session with it: its model.
  func open(timeout: TimeInterval) throws -> String
  func transact(_ op: UInt16, _ params: [UInt32], out: Data?, timeout: TimeInterval) throws -> (data: Data, code: UInt16)
  func close()
  /// The camera's events, its code and parameters, and its going away: on any thread.
  var onEvent: ((UInt16, [UInt32]) -> Void)? { get set }
  var onGone: (() -> Void)? { get set }
}

/// The transport through macOS's image capture (ImageCaptureCore's raw PTP). Its calls block the
/// thread they are made on, never the main one, where image capture answers.
final class ICCTransport: NSObject, PTPTransport, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
  var onEvent: ((UInt16, [UInt32]) -> Void)?
  var onGone: (() -> Void)?
  private var browser: ICDeviceBrowser?
  private var camera: ICCameraDevice?
  private let opened = DispatchSemaphore(value: 0)
  private var openFailure: Error?
  private var openSettled = false
  private let wire = NSLock()
  private var transaction: UInt32 = 1

  func open(timeout: TimeInterval) throws -> String {
    DispatchQueue.main.async {
      let browser = ICDeviceBrowser()
      browser.delegate = self
      browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
      self.browser = browser
      browser.start()
    }
    if opened.wait(timeout: .now() + timeout) == .timedOut {
      let found = DispatchQueue.main.sync { () -> Bool in
        self.openSettled = true
        return self.camera != nil
      }
      close()
      throw found ? PTPFailure.noAnswer : PTPFailure.noCamera
    }
    if let openFailure {
      close()
      throw openFailure
    }
    return DispatchQueue.main.sync { camera?.name ?? "Sony" }
  }
  func transact(_ op: UInt16, _ params: [UInt32], out: Data?, timeout: TimeInterval) throws -> (data: Data, code: UInt16) {
    wire.lock()
    defer { wire.unlock() }
    let command = SonyWire.command(op, params, transaction)
    transaction += 1
    final class Answer { var data = Data(), code: UInt16 = 0, error: Error? }
    let answer = Answer(), done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
      guard let camera = self.camera else {
        answer.error = PTPFailure.gone
        done.signal()
        return
      }
      camera.requestSendPTPCommand(command, outData: out) { data, response, error in
        answer.data = data
        answer.code = response.count >= 8 ? UInt16(SonyWire.le(response, 6, 2)) : 0
        answer.error = error
        done.signal()
      }
    }
    if done.wait(timeout: .now() + timeout) == .timedOut { throw PTPFailure.timeout(op) }
    if let error = answer.error { throw error }
    return (answer.data, answer.code)
  }
  func close() {
    DispatchQueue.main.async {
      self.camera?.requestCloseSession()
      self.browser?.stop()
      self.browser?.delegate = nil
      self.browser = nil
    }
  }
  private func settle(_ failure: Error?) {
    guard !openSettled else { return }
    openSettled = true
    openFailure = failure
    opened.signal()
  }

  func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    guard camera == nil, device.usbVendorID == 0x054C, let found = device as? ICCameraDevice else { return }
    camera = found
    found.delegate = self
    found.requestOpenSession()
  }
  func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
    if device === camera { onGone?() }
  }
  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
    if let error { return settle(PTPFailure.refused(error.localizedDescription)) }
    // PTP is answered once the session is open; the card's catalogue, not wanted, may take longer.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.settle(nil) }
  }
  func didRemove(_ device: ICDevice) { onGone?() }
  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
  func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
  func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
  func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
  func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
  func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
  func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
  func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
    guard eventData.count >= 8 else { return }
    let code = UInt16(SonyWire.le(eventData, 6, 2))
    var params = [UInt32](), o = 12
    while o + 4 <= eventData.count {
      params.append(UInt32(SonyWire.le(eventData, o, 4)))
      o += 4
    }
    onEvent?(code, params)
  }
  func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
  func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
  func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

// MARK: Sony's operations and properties

/// The bytes of Sony's PTP: operations, the property list GetAllExtDevicePropInfo answers with,
/// a picture's object info, and the live view's frame.
enum SonyWire {
  static let ok: UInt16 = 0x2001, busy: UInt16 = 0x2019
  static let sdioConnect: UInt16 = 0x9201, extDeviceInfo: UInt16 = 0x9202, setProp: UInt16 = 0x9205,
    control: UInt16 = 0x9207, allProps: UInt16 = 0x9209, objectInfo: UInt16 = 0x1008, object: UInt16 = 0x1009
  /// Where the camera hands over a picture taken, and its live view.
  static let pictureHandle: UInt32 = 0xFFFF_C001, liveHandle: UInt32 = 0xFFFF_C002
  /// Sony's events: a picture ready, a setting changed, a picture taken.
  static let objectAdded: UInt16 = 0xC201, propertyChanged: UInt16 = 0xC203, captured: UInt16 = 0xC206

  static func le(_ d: Data, _ o: Int, _ n: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<n { v |= UInt64(d[d.startIndex + o + i]) << (8 * UInt64(i)) }
    return v
  }
  static func command(_ op: UInt16, _ params: [UInt32], _ transaction: UInt32) -> Data {
    var d = Data()
    func le32(_ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    le32(UInt32(12 + 4 * params.count))
    d.append(contentsOf: [1, 0, UInt8(op & 0xFF), UInt8(op >> 8)])
    le32(transaction)
    params.forEach(le32)
    return d
  }
  /// Bytes in one value of a PTP data type; nil for strings and arrays.
  static func size(_ type: UInt16) -> Int? {
    switch type {
    case 1, 2: return 1
    case 3, 4: return 2
    case 5, 6: return 4
    case 7, 8: return 8
    case 9, 10: return 16
    default: return nil
    }
  }
  /// `v` as a value of `type`, little-endian.
  static func bytes(_ v: Int64, _ type: UInt16) -> Data {
    let n = size(type) ?? 2
    let bits = UInt64(bitPattern: v)
    return Data((0..<min(n, 8)).map { UInt8((bits >> (8 * UInt64($0))) & 0xFF) })
  }
  /// The value of `n` bytes at `o` as a value of `type`: signed for the odd types.
  static func value(_ d: Data, _ o: Int, _ type: UInt16) -> Int64 {
    let n = size(type) ?? 0
    let raw = le(d, o, min(n, 8))
    switch type {
    case 1: return Int64(Int8(truncatingIfNeeded: raw))
    case 3: return Int64(Int16(truncatingIfNeeded: raw))
    case 5: return Int64(Int32(truncatingIfNeeded: raw))
    default: return Int64(bitPattern: raw)
    }
  }

  /// A setting as the camera describes it.
  struct Descriptor: Equatable {
    var code: UInt16, type: UInt16
    /// 1 when it can be written at all; and 1 enabled, 2 shown only, 0 not now.
    var getSet: UInt8, enabled: UInt8
    var current: Int64
    /// The values on offer now (the first list), and all it may be set to (the second).
    var values = [Int64](), settable = [Int64]()
    /// Lowest, highest and step, for a range.
    var range: [Int64]?
    var writable: Bool { getSet == 1 && enabled == 1 }
  }
  /// GetAllExtDevicePropInfo's answer, property by property: code, type, two flags, default and
  /// current value, and the form (none, a range, or an enumeration, which on newer Sonys is two:
  /// what is on offer now and what may be set). Strings and arrays are stepped over.
  static func descriptors(_ d: Data) -> [UInt16: Descriptor] {
    /// Steps over a value at `o`: its integer when scalar, and the offset after it.
    func step(_ o: Int, _ type: UInt16) -> (Int64?, Int)? {
      if let n = size(type) {
        guard o + n <= d.count else { return nil }
        return (n <= 8 ? value(d, o, type) : nil, o + n)
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
    func list(_ at: Int, _ type: UInt16) -> ([Int64], Int)? {
      guard at + 2 <= d.count else { return nil }
      var q = at + 2, items = [Int64]()
      for _ in 0..<Int(le(d, at, 2)) {
        guard let v = step(q, type) else { return nil }
        if let x = v.0 { items.append(x) }
        q = v.1
      }
      return (items, q)
    }
    var out = [UInt16: Descriptor]()
    var o = 8
    while o + 6 <= d.count {
      let code = UInt16(le(d, o, 2)), type = UInt16(le(d, o + 2, 2))
      let getSet = d[d.startIndex + o + 4], enabled = d[d.startIndex + o + 5]
      guard let def = step(o + 6, type), let cur = step(def.1, type) else { break }
      var p = cur.1
      var item = Descriptor(code: code, type: type, getSet: getSet, enabled: enabled, current: cur.0 ?? 0)
      guard p < d.count else {
        if cur.0 != nil { out[code] = item }
        break
      }
      let form = d[d.startIndex + p]
      p += 1
      if form == 1 {
        guard let lo = step(p, type), let hi = step(lo.1, type), let by = step(hi.1, type) else { break }
        if let a = lo.0, let b = hi.0, let c = by.0 { item.range = [a, b, c] }
        p = by.1
      } else if form == 2 {
        guard let first = list(p, type) else { break }
        item.values = first.0
        p = first.1
        // The second list's count is small; a property code after the first list is ≥ 0x200.
        if p + 2 <= d.count, le(d, p, 2) < 0x200, let second = list(p, type) {
          item.settable = second.0
          p = second.1
        }
      }
      if cur.0 != nil { out[code] = item }
      o = p
    }
    return out
  }
  /// The list back in the camera's bytes, as `descriptors` reads it: for the simulated camera.
  static func encode(_ items: [Descriptor]) -> Data {
    var d = Data()
    func le(_ v: UInt64, _ n: Int) { for i in 0..<n { d.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    le(UInt64(items.count), 4)
    le(0, 4)
    for item in items.sorted(by: { $0.code < $1.code }) {
      guard size(item.type) != nil else { continue }
      le(UInt64(item.code), 2)
      le(UInt64(item.type), 2)
      d.append(item.getSet)
      d.append(item.enabled)
      d.append(bytes(item.current, item.type))
      d.append(bytes(item.current, item.type))
      if let r = item.range, r.count == 3 {
        d.append(1)
        r.forEach { d.append(bytes($0, item.type)) }
      } else {
        d.append(2)
        for list in [item.values, item.settable] {
          le(UInt64(list.count), 2)
          list.forEach { d.append(bytes($0, item.type)) }
        }
      }
    }
    return d
  }
  /// A picture's file name in its ObjectInfo, and its size.
  static func objectName(_ info: Data) -> (name: String, size: Int)? {
    guard info.count > 53 else { return nil }
    let chars = Int(info[info.startIndex + 52])
    var name = ""
    for i in 0..<chars where 53 + 2 * i + 2 <= info.count {
      let c = UInt16(le(info, 53 + 2 * i, 2))
      if c != 0, let u = Unicode.Scalar(c) { name.append(Character(u)) }
    }
    return (name, Int(le(info, 8, 4)))
  }
  static func objectInfo(name: String, size: Int, format: UInt16 = 0xB101) -> Data {
    var d = Data(count: 52)
    func put(_ v: UInt64, _ o: Int, _ n: Int) { for i in 0..<n { d[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) } }
    put(0x0001_0001, 0, 4)
    put(UInt64(format), 4, 2)
    put(UInt64(size), 8, 4)
    let units = Array(name.utf16) + [0]
    d.append(UInt8(units.count))
    for u in units { d.append(contentsOf: [UInt8(u & 0xFF), UInt8(u >> 8)]) }
    d.append(contentsOf: [0, 0, 0, 0])
    return d
  }
  /// The JPEG in a live-view frame: where the frame's header says it is (its offset and size in the
  /// first eight bytes), or else from the first start-of-image marker to the end-of-image after it.
  static func liveJPEG(_ d: Data) -> Data? {
    let b = d.startIndex
    if d.count >= 8 {
      let at = Int(le(d, 0, 4)), n = Int(le(d, 4, 4))
      if at >= 8, n > 4, at + n <= d.count, d[b + at] == 0xFF, d[b + at + 1] == 0xD8 {
        return d.subdata(in: (b + at)..<(b + at + n))
      }
    }
    var i = 0
    while i + 1 < d.count, !(d[b + i] == 0xFF && d[b + i + 1] == 0xD8) { i += 1 }
    guard i + 1 < d.count else { return nil }
    var j = i + 2
    while j + 1 < d.count, !(d[b + j] == 0xFF && d[b + j + 1] == 0xD9) { j += 1 }
    guard j + 1 < d.count else { return nil }
    return d.subdata(in: (b + i)..<(b + j + 2))
  }
}

/// The camera's settings by the names and values Sony's SDK gives them, which the app knows them
/// by, over the camera's own PTP codes and values. Most are the same numbers; the rest are tables.
enum SonySettings {
  struct Setting {
    let name: String
    let code: UInt16
    /// The type to write as when the camera has not described the setting.
    let type: UInt16
    /// The camera's values as the SDK's, where they differ; anything else passes as it is.
    let table: [Int64: Int64]
    var back: [Int64: Int64] { Dictionary(table.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a }) }
    func app(_ v: Int64) -> Int64 { table[v] ?? v }
    func camera(_ v: Int64) -> Int64 { back[v] ?? v }
  }
  static let all: [Setting] = [
    Setting(name: "ShutterSpeed", code: 0xD20D, type: 6, table: [:]),
    Setting(name: "FNumber", code: 0x5007, type: 4, table: [:]),
    Setting(name: "IsoSensitivity", code: 0xD21E, type: 6, table: [:]),
    Setting(name: "ExposureBiasCompensation", code: 0x5010, type: 3, table: [:]),
    Setting(name: "Colortemp", code: 0xD20F, type: 4, table: [:]),
    Setting(name: "ExposureProgramMode", code: 0x500E, type: 6, table: [1: 1, 0x10002: 2, 0x20003: 3, 0x30004: 4]),
    // The file format: locked to RAW (1) while pixel shift is on; 2 and 3 as the menu orders them,
    // not yet checked on the camera.
    Setting(name: "FileType", code: 0xD253, type: 2, table: [1: 2, 2: 3, 3: 1]),
    Setting(name: "WhiteBalance", code: 0x5005, type: 4, table: [
      0x2: 0, 0x8030: 1, 0x4: 0x11, 0x8011: 0x12, 0x8010: 0x13, 0x6: 0x14, 0x8001: 0x21, 0x8002: 0x22,
      0x8003: 0x23, 0x8004: 0x24, 0x7: 0x30, 0x8012: 0x100, 0x8020: 0x101, 0x8021: 0x102, 0x8022: 0x103,
    ]),
    Setting(name: "FocusMode", code: 0x500A, type: 4, table: [1: 1, 2: 2, 0x8004: 3, 0x8005: 4, 0x8006: 6]),
    Setting(name: "FocusArea", code: 0xD22C, type: 4, table: [
      1: 1, 2: 2, 3: 3, 0x101: 4, 0x102: 5, 0x103: 6, 0x104: 7,
      0x201: 0x11, 0x202: 0x12, 0x203: 0x13, 0x204: 0x14, 0x205: 0x15, 0x206: 0x16, 0x207: 0x17,
    ]),
    Setting(name: "DriveMode", code: 0x5013, type: 6, table: [:]),
    Setting(name: "StillImageStoreDestination", code: 0xD222, type: 4, table: [1: 1, 0x10: 2, 0x11: 3]),
    Setting(name: "PriorityKeySettings", code: 0xD25A, type: 2, table: [0: 1, 1: 2]),
    Setting(name: "FocusIndication", code: 0xD213, type: 2, table: [1: 1, 2: 0x102, 3: 0x202]),
    Setting(name: "BatteryRemain", code: 0xD218, type: 1, table: [-1: 0xFFFF]),
    Setting(name: "LiveView_Image_Quality", code: 0xD26A, type: 2, table: [1: 0, 2: 1]),
    // The magnification in the high word, the point on the 640 × 480 grid below, as the SDK has it.
    Setting(name: "Focus_Magnifier_Setting", code: 0xD254, type: 8, table: [:]),
  ]
  /// The camera's buttons and steps, pressed with ControlDevice: the half-press and the full one
  /// (2 down, 1 up), a focus step, the focus point.
  static let buttons: [String: (code: UInt16, type: UInt16)] = [
    "S1": (0xD2C1, 4), "Release": (0xD2C2, 4), "NearFar": (0xD2D1, 3), "AF_Area_Position": (0xD2DC, 6),
  ]
  static func named(_ name: String) -> Setting? { all.first { $0.name == name } }
  /// The pixel shift: on (read only), its count, switched on (2) and off (1), and the computer's
  /// priority, without which the camera takes writes and does nothing with them.
  static let shiftOn: UInt16 = 0xD239, shiftNumber: UInt16 = 0xD23A, shiftSwitch: UInt16 = 0xD2D4,
    shiftStatus: UInt16 = 0xD23C, priority: UInt16 = 0xD25A, objectsWaiting: UInt16 = 0xD215
  /// The pictures a press takes as the camera is set: 1 with the pixel shift off.
  static func shots(_ d: [UInt16: SonyWire.Descriptor]) -> Int? {
    guard let on = d[shiftOn]?.current, let n = d[shiftNumber]?.current else { return nil }
    return on != 0 ? Int(n) : 1
  }
  /// The SDK's data type for a PTP one: the size (1, 2, 4, 8 bytes as 1–4), signed, a range.
  static func sdkType(_ d: SonyWire.Descriptor) -> UInt32 {
    let size: UInt32 = [1: 1, 2: 1, 3: 2, 4: 2, 5: 3, 6: 3, 7: 4, 8: 4][d.type] ?? 0
    return size | (d.type & 1 == 1 && d.type <= 7 ? 0x1000 : 0) | (d.range != nil ? 0x4000 : 0)
  }
  /// One setting as the process says it, in the SDK's values.
  static func describe(_ s: Setting, _ d: SonyWire.Descriptor) -> [String: Any] {
    let values = d.range ?? d.values.map(s.app)
    return [
      "name": s.name, "code": Int(s.code), "type": Int(sdkType(d)), "value": NSNumber(value: s.app(d.current)),
      "settable": d.writable && (d.range != nil || !d.values.isEmpty), "readable": true,
      "values": values.map { NSNumber(value: $0) },
    ]
  }
}

// MARK: The camera

/// The camera driven over a transport: the commands the app sends, the events it is told.
final class SonyPTPCamera {
  let transport: PTPTransport
  /// Where each event goes: a JSON line on standard output in the process.
  var emit: ([String: Any]) -> Void
  /// The commands, one after another.
  let work = DispatchQueue(label: "camera.ptp.work")
  /// What happens when the camera is let go of: the process ends.
  var finished: () -> Void = {}

  private let state = NSLock()
  private var cache = [UInt16: SonyWire.Descriptor]()
  private var connected = false
  /// The half-press held after AF, which locks the focus where the camera offers no MF.
  private var halfHeld = false
  /// MF asked for where the camera does not list it, and not taken: not asked for again.
  private var manualRefused = false
  private var saveFolder: URL?
  private var counter = 0
  private var shotAt = Date()
  /// The pixel shift last told, to tell a change made on the camera; and a switch under way.
  private var shotsTold: Int?
  private var switching = false
  private var monitoring = false, monitor: Thread?
  private let wake = DispatchSemaphore(value: 0)
  private var liveOn = false, live: Thread?, liveDir = ""
  private let downloading = NSLock()

  init(transport: PTPTransport, emit: @escaping ([String: Any]) -> Void) {
    self.transport = transport
    self.emit = emit
    transport.onEvent = { [weak self] code, _ in
      if code == SonyWire.objectAdded || code == SonyWire.propertyChanged || code == SonyWire.captured { self?.wake.signal() }
    }
    transport.onGone = { [weak self] in self?.gone("相机断开了") }
  }

  private func log(_ text: String) { emit(["event": "log", "text": text]) }
  private func error(_ stage: String, _ code: UInt16, _ message: String) {
    emit(["event": "error", "stage": stage, "code": String(format: "0x%x", code), "message": message])
  }
  private func hex(_ v: UInt16) -> String { String(format: "0x%x", v) }
  private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

  // MARK: Transactions

  @discardableResult
  private func call(_ op: UInt16, _ params: [UInt32] = [], out: Data? = nil, timeout: TimeInterval = 10) throws -> (data: Data, code: UInt16) {
    try transport.transact(op, params, out: out, timeout: timeout)
  }
  private func check(_ op: UInt16, _ params: [UInt32] = []) throws {
    let r = try call(op, params)
    guard r.code == SonyWire.ok else { throw PTPFailure.answered(op, r.code) }
  }
  /// Asked again while the camera says it is busy, for up to three seconds: just after it connects,
  /// and while it writes a picture, it takes nothing for a moment.
  private func patiently(_ body: () throws -> UInt16) -> UInt16 {
    var code = (try? body()) ?? 0
    for _ in 0..<15 where code == SonyWire.busy {
      pause(0.2)
      code = (try? body()) ?? 0
    }
    return code
  }
  private func setRaw(_ code: UInt16, _ type: UInt16, _ value: Int64) -> UInt16 {
    patiently { try call(SonyWire.setProp, [UInt32(code)], out: SonyWire.bytes(value, type)).code }
  }
  private func control(_ code: UInt16, _ type: UInt16, _ value: Int64) -> UInt16 {
    patiently { try call(SonyWire.control, [UInt32(code)], out: SonyWire.bytes(value, type)).code }
  }
  /// A setting written by its SDK name and in the SDK's values; a button pressed.
  private func write(_ name: String, _ value: Int64) -> UInt16 {
    if let b = SonySettings.buttons[name] { return control(b.code, b.type, value) }
    guard let s = SonySettings.named(name) else { return 0 }
    let type = described(s.code)?.type ?? s.type
    return setRaw(s.code, type, s.camera(value))
  }
  private func described(_ code: UInt16) -> SonyWire.Descriptor? {
    state.lock()
    defer { state.unlock() }
    return cache[code]
  }

  /// Every setting read, the cache brought up to date, and what changed told: the settings the app
  /// knows by name, and the pixel shift when it was changed on the camera.
  @discardableResult
  private func readAll() throws -> [UInt16: SonyWire.Descriptor] {
    let r = try call(SonyWire.allProps)
    guard r.code == SonyWire.ok else { throw PTPFailure.answered(SonyWire.allProps, r.code) }
    let now = SonyWire.descriptors(r.data)
    guard !now.isEmpty else { return now }
    state.lock()
    let before = cache
    cache = now
    let told = shotsTold, quiet = switching
    let shots = SonySettings.shots(now)
    if !quiet, shots != nil { shotsTold = shots }
    state.unlock()
    if !before.isEmpty {
      let names = SonySettings.all.filter { before[$0.code] != now[$0.code] }.map(\.name)
      if !names.isEmpty { emit(["event": "changed", "names": names]) }
    }
    if !quiet, let shots, let told, shots != told { emit(["event": "shift", "shots": shots, "changed": true]) }
    return now
  }
  /// A setting's value now, in the SDK's values, read afresh.
  private func fresh(_ name: String) -> Int64? {
    guard let s = SonySettings.named(name), let d = (try? readAll())?[s.code] else { return nil }
    return s.app(d.current)
  }
  /// Whether the camera offers `value` for `name` now; one that lists nothing offers all.
  private func offers(_ name: String, _ value: Int64) -> Bool {
    guard let s = SonySettings.named(name), let d = described(s.code) else { return false }
    return d.values.isEmpty || d.values.map(s.app).contains(value)
  }

  // MARK: Commands

  func handle(_ line: String) {
    guard let data = line.data(using: .utf8), let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let cmd = m["cmd"] as? String
    else { return error("parse", 0, "看不懂的命令：" + line) }
    switch cmd {
    case "quit": return quit()
    case "connect": return connect(m)
    case "disconnect": return disconnect()
    default: break
    }
    guard connected else { return error(cmd, 0, "相机没有连接") }
    // The camera takes no setting while the half-press is held: let go of it first.
    if cmd == "set", let name = m["name"] as? String, name != "S1", name != "NearFar" { unlockFocus("set") }
    if cmd == "shift" { unlockFocus("set") }
    if cmd == "live", m["on"] as? Bool != true { unlockFocus(cmd) }
    switch cmd {
    case "props": props()
    case "set":
      let name = m["name"] as? String ?? ""
      guard SonySettings.named(name) != nil || SonySettings.buttons[name] != nil else { return error("set", 0, "未知的设置：" + name) }
      remote()
      let code = write(name, (m["value"] as? NSNumber)?.int64Value ?? 0)
      emit(["event": "set", "name": name, "ok": code == SonyWire.ok, "code": hex(code)])
      wake.signal()
    case "live": setLive(m["on"] as? Bool == true, dir: m["dir"] as? String ?? "")
    case "af": autofocus(m)
    case "nearfar": nearFar(m)
    case "afpoint":
      let x = (m["x"] as? NSNumber)?.int64Value ?? 320, y = (m["y"] as? NSNumber)?.int64Value ?? 240
      remote()
      let code = write("AF_Area_Position", x << 16 | y)
      emit(["event": "set", "name": "AF_Area_Position", "ok": code == SonyWire.ok, "code": hex(code)])
    case "shoot": shoot(m)
    case "shift": shift((m["count"] as? NSNumber)?.intValue)
    default: error(cmd, 0, "未知的命令")
    }
  }

  private func connect(_ m: [String: Any]) {
    if connected { return emit(["event": "connected", "again": true]) }
    let model: String
    do {
      model = try transport.open(timeout: 10)
    } catch PTPFailure.noCamera {
      error("enum", 0, "没有找到相机：请确认已用 USB 连接、开机，且相机的 USB 连接方式是「PC 遥控」；照片、图像捕捉、Lightroom 等 App 开着时可能占住相机")
      return finished()
    } catch {
      self.error("connect", 0, (error as? PTPFailure).map { $0 == .noAnswer ? "相机没有回应：可能有别的程序占着它" : $0.localizedDescription } ?? error.localizedDescription)
      return finished()
    }
    do {
      // Sony's handshake, at the version that lists the pixel shift.
      try check(SonyWire.sdioConnect, [1, 0, 0])
      try check(SonyWire.sdioConnect, [2, 0, 0])
      try check(SonyWire.extDeviceInfo, [300])
      try check(SonyWire.sdioConnect, [3, 0, 0])
    } catch {
      self.error("connect", 0, "相机没有接受 Sony 的握手：" + error.localizedDescription)
      transport.close()
      return finished()
    }
    if let save = m["save"] as? String, !save.isEmpty { saveFolder = URL(fileURLWithPath: save, isDirectory: true) }
    // The app sets focus, exposure and the pixel shift, not the camera's dials.
    let priority = setRaw(SonySettings.priority, 2, 1)
    log(priority == SonyWire.ok ? "已切换到电脑优先" : "切换到电脑优先失败：" + hex(priority))
    pause(0.5)
    let card = m["card"] as? Bool == true
    let store = setRaw(0xD222, 4, card ? 0x11 : 0x1)
    if store != SonyWire.ok { log("设定保存位置失败：" + hex(store)) }
    _ = setRaw(0xD26A, 2, 2)
    // Just after the handshake the camera answers with placeholders for a moment (the shutter as
    // 0xFFFFFFFF, the battery -1; seen 2026-11-07): read until two reads agree, for up to 1.5 s.
    var last = (try? readAll()).map { now in SonySettings.all.map { now[$0.code] } }
    for _ in 0..<6 {
      pause(0.25)
      let now = (try? readAll()).map { now in SonySettings.all.map { now[$0.code] } }
      if now != nil, now! == last ?? [] { break }
      last = now
    }
    state.lock()
    connected = true
    shotsTold = SonySettings.shots(cache)
    state.unlock()
    startMonitor()
    emit(["event": "connected", "model": model, "cameras": 1, "link": "ptp"])
  }
  /// Lets go of the camera and ends: a half-press held is let go first, the live view stopped.
  private func disconnect() {
    if connected {
      if halfHeld { releaseS1() }
      stopLive()
      stopMonitor()
      transport.close()
      connected = false
    }
    emit(["event": "disconnected", "code": "0x0"])
    finished()
  }
  private func quit() {
    if connected {
      if halfHeld { releaseS1() }
      stopLive()
      stopMonitor()
      transport.close()
      connected = false
    }
    finished()
  }
  /// The camera gone from the cable, or answering nothing: told, and the process ends.
  private func gone(_ why: String) {
    work.async {
      guard self.connected else { return }
      self.liveOn = false
      self.monitoring = false
      self.connected = false
      self.transport.close()
      self.emit(["event": "disconnected", "code": "gone", "why": why])
      self.finished()
    }
  }
  private func props() {
    do {
      let now = try readAll()
      var items = [[String: Any]]()
      for s in SonySettings.all { if let d = now[s.code] { items.append(SonySettings.describe(s, d)) } }
      emit(["event": "props", "props": items])
    } catch { self.error("props", 0, "读取相机设置失败：" + error.localizedDescription) }
  }

  // MARK: Pictures

  private func startMonitor() {
    monitoring = true
    let thread = Thread { [weak self] in
      var failures = 0
      while let self, self.monitoring {
        _ = self.wake.wait(timeout: .now() + 0.4)
        guard self.monitoring else { break }
        do {
          let now = try self.readAll()
          failures = 0
          if let waiting = now[SonySettings.objectsWaiting]?.current, waiting > 0x8000 { self.download() }
        } catch {
          failures += 1
          if failures == 1 { self.log("读取相机状态失败：" + error.localizedDescription) }
          if failures >= 8 { self.gone("相机 3 秒多没有回应") }
        }
      }
    }
    thread.name = "camera.ptp.monitor"
    monitor = thread
    thread.start()
  }
  private func stopMonitor() {
    monitoring = false
    wake.signal()
  }
  /// The pictures the camera holds for the computer, fetched one by one and written into the save
  /// folder (aside, then renamed into place), each told as it is in.
  private func download() {
    guard downloading.`try`() else { return }
    defer { downloading.unlock() }
    for _ in 0..<64 {
      guard let info = try? call(SonyWire.objectInfo, [SonyWire.pictureHandle]), info.code == SonyWire.ok,
        let object = SonyWire.objectName(info.data)
      else { break }
      guard let picture = try? call(SonyWire.object, [SonyWire.pictureHandle], timeout: 120), picture.code == SonyWire.ok else {
        log("取照片 \(object.name) 失败")
        break
      }
      let ext = (object.name as NSString).pathExtension.isEmpty ? "ARW" : (object.name as NSString).pathExtension
      let folder = saveFolder ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      var file: URL
      repeat {
        counter += 1
        file = folder.appendingPathComponent(String(format: "EPS%05d.", counter) + ext)
      } while FileManager.default.fileExists(atPath: file.path)
      let part = file.appendingPathExtension("part")
      do {
        try picture.data.write(to: part)
        try FileManager.default.moveItem(at: part, to: file)
      } catch {
        log("写入照片失败：" + error.localizedDescription)
        continue
      }
      let ms = Int(Date().timeIntervalSince(shotAt) * 1000)
      emit(["event": "downloaded", "path": file.path, "type": 0, "afterShotMs": ms, "name": object.name])
      guard let left = (try? readAll())?[SonySettings.objectsWaiting]?.current, left > 0x8000 else { break }
    }
  }

  // MARK: Live view

  private func setLive(_ on: Bool, dir: String) {
    if on, !liveOn {
      liveDir = dir
      liveOn = true
      let thread = Thread { [weak self] in self?.liveLoop() }
      thread.name = "camera.ptp.live"
      live = thread
      thread.start()
    } else if !on {
      stopLive()
    }
    emit(["event": "live", "on": liveOn])
  }
  private func stopLive() { liveOn = false }
  private func liveLoop() {
    var n = 0, misses = 0
    while liveOn {
      var shown = false
      if let r = try? call(SonyWire.object, [SonyWire.liveHandle], timeout: 4), r.code == SonyWire.ok, let jpeg = SonyWire.liveJPEG(r.data) {
        n += 1
        // Written aside and renamed into place, so the app never reads half a frame.
        let path = liveDir + "/live-\(n % 4).jpg", part = path + ".part"
        if (try? jpeg.write(to: URL(fileURLWithPath: part))) != nil, rename(part, path) == 0 {
          emit(["event": "frame", "path": path, "n": n])
          shown = true
        }
      }
      if !shown {
        misses += 1
        if misses % 50 == 1 { log("实时取景暂无画面") }
        pause(0.1)
      }
      pause(0.05)
    }
  }

  // MARK: Focus and the shutter

  /// The computer's priority, without which the camera takes a press or a setting and does nothing
  /// with it: asked for again when a dial was touched since. What it answered goes into `steps`.
  @discardableResult
  private func remote() -> String {
    if described(SonySettings.priority)?.current == 1 { return "" }
    let code = setRaw(SonySettings.priority, 2, 1)
    pause(0.5)
    _ = try? readAll()
    return "电脑优先 " + hex(code) + "，"
  }
  private func releaseS1() {
    halfHeld = false
    _ = write("S1", 1)
  }
  private func unlockFocus(_ why: String) {
    guard halfHeld else { return }
    releaseS1()
    emit(["event": "unlocked", "why": why])
  }
  private func autofocusMode() -> Bool { (2...6).contains(fresh("FocusMode") ?? 0) }
  /// The lens's own switch at MF: the camera is in MF and offers nothing else.
  private func lensAtMF() -> Bool { fresh("FocusMode") == 1 && !offers("FocusMode", 2) }
  /// The camera in focus mode `mode` as it says it is. One it does not offer now is not asked for,
  /// but MF: the A7R IV lists no MF with the lens's switch at AF, yet may be set to it, and is
  /// asked once in a connection (when it does not take it, not again). Read back for two seconds,
  /// twice; the magnifier, which the switch ends, put back. Whether it is in that mode now.
  private func ensureFocusMode(_ mode: Int64, _ m: [String: Any], _ steps: inout String) -> Bool {
    let name = mode == 1 ? "MF" : mode == 6 ? "DMF" : "AF-S"
    guard let now = fresh("FocusMode") else { return false }
    if now == mode { return true }
    let listed = offers("FocusMode", mode)
    let settable = described(0x500A).map { $0.settable.contains(SonySettings.named("FocusMode")!.camera(mode)) } ?? false
    if !listed && !(mode == 1 && settable && !manualRefused) {
      steps += "相机现在不提供 \(name)，"
      return false
    }
    for attempt in 1...2 {
      let code = write("FocusMode", mode)
      if code != SonyWire.ok { steps += "切到 \(name) \(hex(code))，" }
      for _ in 0..<10 where code == SonyWire.ok {
        pause(0.2)
        if fresh("FocusMode") == mode {
          steps += "切到 \(name)" + (attempt > 1 ? "（第 2 次）" : "") + "，"
          if let v = (m["magnify"] as? NSNumber)?.int64Value, v != 0 {
            _ = write("Focus_Magnifier_Setting", v)
            pause(0.3)
          }
          return true
        }
      }
      if !listed { break }
    }
    if !listed { manualRefused = true }
    steps += "没能切到 \(name)，"
    return false
  }
  /// Half-presses and waits up to four seconds for the camera to say whether it focused.
  private func focusOnce() -> String {
    let code = write("S1", 2)
    if code != SonyWire.ok {
      error("af", code, "半按快门失败")
      return "error"
    }
    let until = Date().addingTimeInterval(4)
    while Date() < until {
      pause(0.15)
      switch fresh("FocusIndication") {
      case 0x102, 0x103: return "focused"
      case 0x202, 0x203: return "failed"
      default: continue
      }
    }
    return "timeout"
  }
  /// Focused once and held: from MF by way of AF-S and back to it, or, where the camera offers no
  /// MF, in DMF with the half-press held, which locks the focus (CameraHelper.cpp's AF).
  private func autofocus(_ m: [String: Any]) {
    var steps = ""
    unlockFocus("af")
    steps += remote()
    if lensAtMF() {
      log("AF：镜头开关在 MF，相机不对焦")
      return emit(["event": "af", "result": "lensMF", "held": true, "locked": false])
    }
    let mfOffered = offers("FocusMode", 1)
    if !mfOffered && fresh("FocusMode") != 6 {
      _ = ensureFocusMode(6, m, &steps)
    } else if mfOffered && !autofocusMode() {
      _ = ensureFocusMode(2, m, &steps)
    }
    let result = focusOnce()
    var locked = false, held = true
    if !mfOffered && result == "focused" {
      halfHeld = true
      locked = true
    } else {
      releaseS1()
      pause(0.15)
      held = !mfOffered ? false : (m["hold"] as? Bool != true || ensureFocusMode(1, m, &steps))
    }
    log("AF：" + steps + result + (locked ? "，半按按住锁住焦点" : held ? "" : "，没能切回手动对焦"))
    emit(["event": "af", "result": result, "held": held, "locked": locked, "noManual": !mfOffered])
  }
  /// A focus step: in MF the camera drives, or in DMF while the half-press holds the focus.
  private func nearFar(_ m: [String: Any]) {
    var steps = ""
    let step = max(-6, min(6, (m["step"] as? NSNumber)?.int64Value ?? 0))
    if !halfHeld {
      steps += remote()
      if lensAtMF() {
        log("对焦步进：镜头开关在 MF，相机驱动不了镜头")
        return emit(["event": "set", "name": "NearFar", "ok": false, "code": "lensMF"])
      }
      if !ensureFocusMode(1, m, &steps) {
        log("对焦步进：" + steps + "焦点没有锁住（先按 AF）")
        return emit(["event": "set", "name": "NearFar", "ok": false, "code": "unlocked"])
      }
      if !steps.isEmpty { log("对焦步进：" + steps) }
    }
    let code = write("NearFar", step)
    emit(["event": "set", "name": "NearFar", "ok": code == SonyWire.ok, "code": hex(code)])
  }
  /// The shutter without focusing (CameraHelper.cpp's shoot): over a held half-press, pressed fully
  /// where the lens is; else with the computer's priority, in MF where the camera takes it, half-
  /// pressed a moment, pressed fully, and let go. The pictures come by the monitor.
  private func shoot(_ m: [String: Any]) {
    var steps = ""
    if halfHeld {
      shotAt = Date()
      let down = write("Release", 2)
      pause(0.2)
      let up = write("Release", 1)
      pause(0.3)
      // Over PTP the half-press stays down until it is let go of (the SDK let go of it with the
      // picture), and the camera takes no setting while it is: the pixel shift would not switch
      // after the group (seen 2026-11-07).
      releaseS1()
      let code = down != SonyWire.ok ? down : up
      log("快门（焦点锁住，不再对焦）：全按 " + hex(code))
      emit(["event": "shot", "ok": code == SonyWire.ok, "code": hex(code), "manual": true, "locked": true])
      emit(["event": "unlocked", "why": "shot"])
      wake.signal()
      return
    }
    steps += remote()
    releaseS1()
    pause(0.1)
    let manual = ensureFocusMode(1, m, &steps)
    if !manual { log("相机不在手动对焦，焦点也没有锁住，这一张会先对焦") }
    let half = write("S1", 2)
    pause(0.3)
    shotAt = Date()
    let down = write("Release", 2)
    pause(0.2)
    let up = write("Release", 1)
    pause(0.5)
    releaseS1()
    let code = down != SonyWire.ok ? down : up
    log("快门：" + steps + "半按 " + hex(half) + "，全按 " + hex(code))
    emit(["event": "shot", "ok": code == SonyWire.ok, "code": hex(code), "manual": manual])
    wake.signal()
  }

  // MARK: Pixel shift

  /// The pixel shift set to `count` pictures a press (1 off, 4 or 16), or read without one, then
  /// told: switched on or off with ControlDevice, its count written, and read back until it reads
  /// as set (the camera reports a write a read or two late), for up to four seconds.
  private func shift(_ count: Int?) {
    state.lock()
    switching = true
    state.unlock()
    defer {
      state.lock()
      switching = false
      shotsTold = SonySettings.shots(cache)
      state.unlock()
    }
    guard let now = try? readAll(), let before = SonySettings.shots(now) else {
      return emit(["event": "shift", "error": "读不出相机的像素位移设置"] as [String: Any])
    }
    var answer: [String: Any] = ["event": "shift", "shots": before]
    if let count { answer["asked"] = count }
    guard let count, count != before else { return emit(answer) }
    remote()
    // Just after a group the camera takes the switch and does nothing with it (seen 2026-11-07
    // after 16 shots): while its pixel-shift status (0xD23C) says a group is under way, waited for,
    // up to ten seconds; and a switch that does not read as made in four seconds is made once more.
    var status = now[SonySettings.shiftStatus]?.current ?? 0
    let calm = Date().addingTimeInterval(10)
    while status != 0, Date() < calm {
      pause(0.3)
      status = (try? readAll())?[SonySettings.shiftStatus]?.current ?? 0
    }
    var codes = [UInt16](), got = before
    for attempt in 1...2 {
      let read = attempt == 1 ? now : ((try? readAll()) ?? now)
      let on = read[SonySettings.shiftOn]?.current != 0, number = Int(read[SonySettings.shiftNumber]?.current ?? 0)
      if count == 1 {
        codes.append(control(SonySettings.shiftSwitch, 4, 1))
      } else {
        if !on {
          codes.append(control(SonySettings.shiftSwitch, 4, 2))
          pause(0.5)
        }
        if number != count { codes.append(setRaw(SonySettings.shiftNumber, 4, Int64(count))) }
      }
      let until = Date().addingTimeInterval(4)
      while Date() < until {
        pause(0.4)
        if let n = (try? readAll()).flatMap(SonySettings.shots) { got = n }
        if got == count { break }
      }
      if got == count { break }
    }
    log("像素位移：\(before) → \(count)，回答 " + codes.map(hex).joined(separator: " ") + "，读回 \(got)")
    answer["shots"] = got
    if let bad = codes.first(where: { $0 != SonyWire.ok }) { answer["code"] = hex(bad) }
    emit(answer)
  }

  // MARK: The process

  /// `EpsonScanPlus --sony-ptp-camera`: commands on standard input, events on standard output,
  /// until the camera is let go of or the app goes.
  static func runProcess() -> Never {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let out = NSLock()
    let say: ([String: Any]) -> Void = { event in
      guard var line = try? JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes]) else { return }
      line.append(10)
      out.lock()
      FileHandle.standardOutput.write(line)
      out.unlock()
    }
    let transport: PTPTransport
    if let setup = ProcessInfo.processInfo.environment["EPSCAN_PTP_SIM"] {
      transport = SimulatedSonyBody(setup)
    } else {
      transport = ICCTransport()
    }
    let camera = SonyPTPCamera(transport: transport, emit: say)
    // The close goes out before the process ends, and ptpcamerad lets go of the USB as it does.
    camera.finished = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) } }
    say(["event": "ready", "link": "ptp"])
    let reader = Thread {
      while let line = readLine() {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        camera.work.async { camera.handle(line) }
      }
      // The app gone: the camera let go of.
      camera.work.async { camera.handle("{\"cmd\":\"quit\"}") }
    }
    reader.name = "camera.ptp.input"
    reader.start()
    RunLoop.main.run()
    exit(0)
  }
}
