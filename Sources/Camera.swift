import AppKit
import CoreImage
import Foundation

/// A setting of the camera as its SDK reports it: the value, what it may be set to, and whether it
/// can be set now.
struct CameraProperty: Equatable {
  let name: String
  let value: Int64
  let values: [Int64]
  let settable: Bool
  /// The SDK's data type: with its range bit, `values` are the lowest, the highest and the step.
  var type: UInt32 = 0
  var text: String { Self.describe(name, value) }
  var isRange: Bool { type & 0x4000 != 0 }
  /// What it can be set to, in order: a range's steps (at most 200 of them), else the values listed.
  var choices: [Int64] {
    guard isRange, values.count >= 2 else { return values }
    let lo = values[0], hi = values[1], step = values.count > 2 ? max(1, values[2]) : 1
    guard hi > lo else { return [lo] }
    let n = min(200, (hi - lo) / step + 1)
    return (0..<n).map { lo + $0 * step }
  }
  /// `v` brought within what the camera takes: inside its range on its step, or the nearest of
  /// the values it lists.
  func nearest(_ v: Int64) -> Int64 {
    if isRange, values.count >= 2 {
      let lo = values[0], hi = values[1], step = values.count > 2 ? max(1, values[2]) : 1
      let clamped = min(max(v, lo), hi)
      return lo + ((clamped - lo + step / 2) / step) * step
    }
    return values.min { abs($0 - v) < abs($1 - v) } ?? v
  }
  /// How the camera would show `v` for the setting `name`.
  static func describe(_ name: String, _ v: Int64) -> String {
    func pick(_ names: [Int64: String]) -> String { names[v] ?? String(format: "0x%llx", v) }
    switch name {
    case "FNumber":
      return v == 0xFFFE || v == 0xFFFF ? "--" : String(format: "f/%.1f", Double(v) / 100)
    case "ShutterSpeed":
      // The upper 16 bits are the numerator, the lower the denominator.
      guard v != 0 else { return "B" }
      let num = Double((v >> 16) & 0xFFFF), den = Double(v & 0xFFFF)
      guard num > 0, den > 0 else { return "--" }
      let seconds = num / den
      return seconds >= 0.4 ? String(format: "%g\"", (seconds * 10).rounded() / 10) : "1/\(Int((den / num).rounded()))"
    case "IsoSensitivity":
      let iso = v & 0xFFFFFF
      return iso == 0xFFFFFF ? "ISO AUTO" : "ISO \(iso)"
    case "ExposureBiasCompensation":
      // EV × 1000 in 16 bits, the negative ones as two's complement.
      let ev = Double(v > 32767 ? v - 65536 : v) / 1000
      return ev == 0 ? "±0.0 EV" : String(format: "%+.1f EV", ev)
    case "WhiteBalance":
      return pick([
        0: "自动", 1: "水下自动", 0x11: "日光", 0x12: "阴影", 0x13: "阴天", 0x14: "白炽灯", 0x20: "荧光灯",
        0x21: "荧光灯 暖白", 0x22: "荧光灯 冷白", 0x23: "荧光灯 日白", 0x24: "荧光灯 日光", 0x30: "闪光灯",
        0x100: "色温", 0x101: "自定义 1", 0x102: "自定义 2", 0x103: "自定义 3", 0x104: "自定义",
      ])
    case "Colortemp": return "\(v)K"
    case "FocusMode": return pick([1: "MF", 2: "AF-S", 3: "AF-C", 4: "AF-A", 5: "AF-D", 6: "DMF", 7: "PF"])
    case "FileType": return pick([1: "JPEG", 2: "RAW", 3: "RAW+JPEG", 4: "RAW+HEIF", 5: "HEIF"])
    case "StillImageStoreDestination": return pick([1: "电脑", 2: "存储卡", 3: "电脑和存储卡"])
    case "ExposureProgramMode": return pick([1: "M", 2: "P", 3: "A", 4: "S"])
    case "DriveMode": return v == 1 ? "单张" : String(format: "0x%llx", v)
    case "FocusArea":
      return pick([1: "广域", 2: "区域", 3: "中间", 4: "自由点 S", 5: "自由点 M", 6: "自由点 L", 7: "扩展自由点", 8: "自由点"])
    case "BatteryRemain": return v >= 0 && v <= 100 ? "\(v)%" : "--"
    case "LiveView_Image_Quality": return pick([0: "低", 1: "高"])
    case "FocusIndication":
      return pick([1: "未对焦", 0x102: "已合焦", 0x202: "合焦失败", 0x103: "已合焦", 0x203: "合焦失败", 0x303: "跟踪中"])
    default: return "\(v)"
    }
  }
}

/// How sharp the picture in the focus box is: the readout over the live view, and the focus
/// check of the last picture.
enum Sharpness {
  /// How sharp `image` is in `box` (normalised, from the top left), channel by channel: the mean
  /// squared Laplacian, which grows as edges and grain come into focus.
  static func measure(_ image: CGImage, in box: CGRect) -> RGB {
    let r = CGRect(
      x: box.minX * CGFloat(image.width), y: box.minY * CGFloat(image.height),
      width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height)
    ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard !r.isNull, r.width >= 3, r.height >= 3, let part = image.cropping(to: r) else { return RGB(r: 0, g: 0, b: 0) }
    let k = min(1, 256 / max(r.width, r.height))
    let w = max(3, Int(r.width * k)), h = max(3, Int(r.height * k))
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { raw in
      guard let ctx = CGContext(
        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: ImagePipeline.shared.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      ctx.interpolationQuality = .none
      ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var sums = [0.0, 0.0, 0.0]
    for y in 1..<(h - 1) {
      for x in 1..<(w - 1) {
        let i = (y * w + x) * 4
        for c in 0..<3 {
          let v = Double(px[i + c]), l = Double(px[i - 4 + c]), rr = Double(px[i + 4 + c])
          let u = Double(px[i - w * 4 + c]), d = Double(px[i + w * 4 + c])
          let lap = 4 * v - l - rr - u - d
          sums[c] += lap * lap
        }
      }
    }
    let n = Double((w - 2) * (h - 2)) * 255 * 255
    return RGB(r: sums[0] / n, g: sums[1] / n, b: sums[2] / n)
  }
}

/// The camera on the copy stand, driven by a process of its own: over the camera's own PTP (this
/// app started again as `--sony-ptp-camera`, SonyPTPCamera.swift), or over Sony's Camera Remote
/// SDK (`EpsonCameraHelper`, built when the SDK is on this Mac). Both speak the same lines. Live
/// view arrives as JPEG frames, and each picture taken arrives as a file, which `onCapture` hands on.
final class CameraController: ObservableObject {
  /// How the camera is reached: its own PTP, which reaches the pixel shift, or Sony's SDK.
  enum Link: String, CaseIterable {
    case ptp, sdk
    var name: String { self == .ptp ? "直连 PTP" : "Sony SDK" }
  }
  enum Phase: Equatable { case missing, idle, connecting, connected, failed }
  @Published private(set) var phase: Phase
  @Published private(set) var model = ""
  @Published private(set) var message = ""
  /// What the app makes of what the camera did (a pixel-shift group that came short, say), in the
  /// panel's line.
  func explain(_ text: String) { message = text }
  @Published private(set) var live: CGImage? {
    didSet {
      liveHistogram = live.map(Histogram.picture)
      liveBackdrop = live.flatMap(Frost.backdrop)
    }
  }
  /// The live frame as frost on the copy stand shows it under its panes.
  @Published private(set) var liveBackdrop: CGImage?
  /// The histogram of the live frame, as the camera rendered it.
  @Published private(set) var liveHistogram: Histogram?
  @Published private(set) var liveOn = false
  @Published private(set) var frames = 0
  /// Sharpness in the focus box of the last live frame.
  @Published private(set) var sharpness: RGB?
  @Published private(set) var properties = [String: CameraProperty]()
  @Published private(set) var focusResult: String?
  /// Shots the camera has taken since connecting.
  @Published private(set) var shots = 0
  @Published private(set) var log = [String]()
  /// Where the camera focuses, in the live view's normalised coordinates.
  @Published private(set) var focusPoint = CGPoint(x: 0.5, y: 0.5)
  /// The focus box's side against the live view's width.
  static let boxSize = 0.12
  var onCapture: ((URL) -> Void)?
  /// Pictures one press brings: 4 for a pixel-shift shot, set on the camera. The shutter waits for
  /// them all, so the next press's pictures never join this one's group.
  var picturesPerShot = 1
  /// A press whose pictures stopped coming before `picturesPerShot`: how many came.
  var onShotEnded: ((Int) -> Void)?
  /// The camera's pixel shift (1 off, 4 or 16 shots), read and set over its own PTP: the SDK does
  /// not reach it. Others for tests.
  var readShift: () async throws -> Int = { try await SonyPTP.inChild(["read"]) }
  var writeShift: (Int) async throws -> Int = { try await SonyPTP.inChild(["set", String($0)]) }
  /// Whether the pixel shift is read and set over PTP; by default with the real camera only, not
  /// the simulated one nor a test's transport.
  var shiftOverPTP: Bool?
  /// With the SDK, the pixel shift is read and set by letting go of the camera for a moment.
  private var reachesShift: Bool { link == .sdk && (shiftOverPTP ?? (transport == nil && helper.lastPathComponent == "EpsonCameraHelper")) }
  /// Over the camera's own PTP, it is set and read in the connection itself.
  var shiftDirect: Bool { link == .ptp }
  /// The pixel shift as read from the camera or set on it, for the app's choice to follow.
  var onShiftRead: ((Int) -> Void)?
  /// The count the camera is being set to, while the SDK has let go of it for that.
  @Published private(set) var shiftSwitching: Int?
  /// A switch waiting for the SDK to let go, and where the pictures were going.
  private var switchOnDisconnect: (count: Int, card: Bool)?
  /// What setting the pixel shift came to, said once the camera is connected again.
  private var shiftNote: String?
  static func shiftName(_ count: Int) -> String { count > 1 ? "像素位移 \(count) 张" : "单张（像素位移关）" }
  /// How long after a press's last picture the rest may still come: the A7R IV sends a pixel-shift
  /// shot's 120 MB RAWs about a second apart.
  static var groupWait: TimeInterval = 8
  /// Lines the controller sends, instead of to the process: for tests.
  var transport: ((String) -> Void)?
  private(set) var link: Link
  private(set) var helper: URL
  /// What the process is started with: `--sony-ptp-camera` for the app itself.
  private(set) var helperArguments = [String]()
  /// Sony's SDK process, when the link is the SDK.
  private let sdkHelper: URL
  let incoming: URL
  let liveFolder: URL
  private var process: Process?
  private var input: FileHandle?
  private var pending = Data()
  /// The focus locked by a half-press held since AF: where the camera offers no MF (the lens's
  /// switch at AF), the way to fine-tune it with steps and to take a picture without focusing
  /// again. The camera lets go of it with the picture.
  @Published private(set) var focusLocked = false
  private var propsQueued = false

  init(
    helper: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/EpsonCameraHelper"),
    folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("local.epscan.mac").appendingPathComponent("Camera"),
    link: Link = .sdk
  ) {
    sdkHelper = helper
    self.link = link
    self.helper = helper
    incoming = folder.appendingPathComponent("Incoming")
    liveFolder = folder.appendingPathComponent("Live")
    phase = .idle
    use(link)
  }
  /// The link the next connection takes; not while connected, or while its process is still there.
  func use(_ link: Link) {
    guard process == nil, phase != .connected, phase != .connecting else { return }
    self.link = link
    if link == .ptp, let me = Bundle.main.executableURL {
      helper = me
      helperArguments = ["--sony-ptp-camera"]
    } else {
      helper = sdkHelper
      helperArguments = []
    }
    phase = FileManager.default.isExecutableFile(atPath: helper.path) ? .idle : .missing
    if phase == .idle, message.hasPrefix("这份 App 构建时没有") { message = "" }
  }
  var available: Bool { transport != nil || FileManager.default.isExecutableFile(atPath: helper.path) }
  var connected: Bool { phase == .connected }
  var focusBox: CGRect {
    let s = Self.boxSize
    return CGRect(x: min(max(focusPoint.x - s / 2, 0), 1 - s), y: min(max(focusPoint.y - s / 2, 0), 1 - s), width: s, height: s)
  }
  /// The focus mode is one of the camera's autofocus modes: AF-S, AF-C, AF-A, AF-D or DMF, which
  /// focuses automatically before the ring takes over.
  var autofocusMode: Bool { (2...6).contains(properties["FocusMode"]?.value ?? 0) }
  /// Manual focus, as the lens must be for the app to step it.
  var manualFocus: Bool { properties["FocusMode"]?.value == 1 }
  /// Pictures received since connecting, to tell a shot that brought none.
  private var received = 0
  /// Pictures received when the shutter was last pressed, and which press that was: the picture
  /// can come before the process says how the press went (a fast one, a JPEG or a compressed RAW,
  /// arrives while it still waits to let the half-press go).
  private var receivedAtPress = 0, presses = 0
  /// What the process is started with, over this one's own: for tests, a simulated camera's setup.
  var environment: [String: String]?
  /// Programs that take the camera for themselves whenever it comes on the cable, through macOS's
  /// image capture or Sony's own SDK: with one of them open the camera refuses this app, or is not
  /// found. By the start of their bundle identifiers, with the names said.
  static let rivals: [(id: String, name: String)] = [
    ("com.captureone.captureone", "Capture One"), ("com.phaseone.captureone", "Capture One"),
    ("com.adobe.mas.lightroomCC", "Lightroom"), ("com.adobe.lightroomCC", "Lightroom"),
    ("com.adobe.LightroomClassicCC", "Lightroom Classic"), ("com.apple.Photos", "照片"),
    ("com.apple.Image_Capture", "图像捕捉"), ("com.sony.Remote", "Imaging Edge Remote"),
  ]
  /// The rivals among the programs `running`, by bundle identifier, each named once.
  static func rivals(among running: [String]) -> [String] {
    var names = [String]()
    for id in running {
      if let rival = rivals.first(where: { id.hasPrefix($0.id) }), !names.contains(rival.name) { names.append(rival.name) }
    }
    return names
  }
  /// The bundle identifiers of the programs open, as the Dock shows them: others for tests.
  var running: () -> [String] = {
    NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
  }
  /// A shot taken whose picture has not come yet: the camera takes no new one while it writes and
  /// sends the last (an uncompressed RAW is 120 MB), and says nothing, so the shutter waits too.
  @Published private(set) var awaitingPicture = false
  /// The camera's own focus magnifications, in tenths (59 is 5.9×), as it offers them: its live
  /// view then shows that part of the sensor pixel for pixel. None when the camera does not say.
  var magnifications: [Int64] {
    (properties["Focus_Magnifier_Setting"]?.values ?? []).map { $0 >> 32 }.filter { $0 > 10 }
  }
  /// The magnification on, in tenths; 0 off.
  @Published private(set) var magnification: Int64 = 0
  func magnify(_ tenths: Int64) {
    magnification = tenths
    set("Focus_Magnifier_Setting", magnifierValue)
  }
  /// The setting for the magnification at the focus point: the magnification in the high word,
  /// the point on the camera's 640 × 480 grid in the low one. 1× is the camera's own ×1.0 step,
  /// the whole frame again: the A7R IV does not take its "off" value back from a magnification.
  var magnifierValue: Int64 {
    let x = Int64((focusPoint.x * 639).rounded()), y = Int64((focusPoint.y * 479).rounded())
    return (magnification > 0 ? magnification : 10) << 32 | x << 16 | y
  }
  /// Where the sharpness is measured: the focus box, or with the camera magnifying, the middle of
  /// the live view, which is then the part about the focus point.
  var measureBox: CGRect {
    guard magnification > 0 else { return focusBox }
    let s = Self.boxSize
    return CGRect(x: 0.5 - s / 2, y: 0.5 - s / 2, width: s, height: s)
  }

  // MARK: Commands

  /// Connects, the pictures coming here and with `keepOnCard` staying on the card too. Its pixel
  /// shift is set to `shift`, or, without one, read for the app's choice to follow: over PTP once
  /// connected; with the SDK, over PTP before the SDK takes the camera.
  func connect(keepOnCard: Bool = false, shift: Int? = nil) {
    guard available else {
      phase = .missing
      message = "这份 App 构建时没有 Sony Camera Remote SDK"
      return
    }
    guard phase != .connecting, phase != .connected else { return }
    try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: liveFolder, withIntermediateDirectories: true)
    if retiring, process != nil {
      // The last PTP process still letting go of the camera: connected once it has gone.
      connectAfterExit = (keepOnCard, shift)
      phase = .connecting
      message = "正在连接相机…"
      return
    }
    if transport == nil && process == nil { launch() }
    phase = .connecting
    if shiftDirect {
      shiftOnConnect = shift ?? 0
      return sendConnect(keepOnCard)
    }
    guard reachesShift else { return sendConnect(keepOnCard) }
    message = shift.map { "正在把相机设为\(Self.shiftName($0))…" } ?? "正在读相机的像素位移设置…"
    overPTP(shift) { [weak self] said in
      self?.shiftNote = said
      self?.sendConnect(keepOnCard)
    }
  }
  private func sendConnect(_ keepOnCard: Bool) {
    message = "正在连接相机…"
    send(["cmd": "connect", "save": incoming.path, "card": keepOnCard])
  }
  /// The camera's pixel shift set to `count` (1 off, 4 or 16) while connected: the SDK lets go of
  /// the camera, it is set over PTP, and the SDK connects again, the live view back after some
  /// seconds. Not while a press's pictures are still coming.
  func switchPixelShift(to count: Int, keepOnCard: Bool) {
    if shiftDirect {
      // Over PTP, in the connection itself: the live view goes on.
      guard connected, shiftSwitching == nil, !awaitingPicture else { return }
      shiftSwitching = count
      message = "正在把相机设为\(Self.shiftName(count))…"
      return send(["cmd": "shift", "count": count])
    }
    guard reachesShift, connected, shiftSwitching == nil, !awaitingPicture else { return }
    shiftSwitching = count
    switchOnDisconnect = (count, keepOnCard)
    message = "正在把相机设为\(Self.shiftName(count))：先断开…"
    disconnect()
  }
  /// The pixel shift set to `count` over PTP, or read without one; then `done` on the main thread
  /// with what to say of it, nil when it is as asked or was only read.
  private func overPTP(_ count: Int?, done: @escaping (String?) -> Void) {
    let read = readShift, write = writeShift
    Task {
      var got: Int?, failure: Error?
      do {
        if let count { got = try await write(count) } else { got = try await read() }
      } catch { failure = error }
      DispatchQueue.main.async {
        if let got { self.onShiftRead?(got) }
        var said: String?
        if let count, let got, got != count {
          said = "相机没有改成\(Self.shiftName(count))，读回来是\(Self.shiftName(got))：请在相机菜单里设"
        } else if let failure {
          said = (count.map { "没能从电脑把相机设为\(Self.shiftName($0))" } ?? "没能读出相机的像素位移设置")
            + "（\(failure.localizedDescription)）" + (count == nil ? "" : "：请在相机菜单里设")
        } else if let count {
          said = "相机已设为\(Self.shiftName(count))"
        }
        if let said { self.note("像素位移：" + said) }
        done(said)
      }
    }
  }
  func disconnect() {
    magnification = 0
    send(["cmd": "disconnect"])
  }
  func setLive(_ on: Bool) { send(["cmd": "live", "on": on, "dir": liveFolder.path]) }
  func refreshProperties() { send(["cmd": "props"]) }
  func set(_ name: String, _ value: Int64) {
    send(["cmd": "set", "name": name, "value": value])
    // Changing the focus mode ends the camera's magnifier: put back, once the camera has changed.
    if name == "FocusMode", magnification > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self, self.magnification > 0 else { return }
        self.send(["cmd": "set", "name": "Focus_Magnifier_Setting", "value": self.magnifierValue])
      }
    }
  }
  /// Focuses once at the focus point and holds it: from manual focus by way of AF-S, and the
  /// camera left in manual focus after, so the shutter takes the picture where it focused.
  func autofocus() {
    focusResult = nil
    focusLocked = false
    var command: [String: Any] = ["cmd": "af", "afs": !autofocusMode, "hold": true]
    if magnification > 0 { command["magnify"] = magnifierValue }
    send(command)
  }
  /// A focus step, nearer (negative) or farther: in manual focus only, which the camera is switched
  /// to first when it is not; until its settings come back it is taken to be so.
  func step(_ size: Int) {
    // The process decides from the camera itself: MF it can drive, or the focus locked in DMF.
    var command: [String: Any] = ["cmd": "nearfar", "step": max(-6, min(6, size))]
    // A switch to MF ends the camera's magnifier, which the step then puts back first.
    if magnification > 0 { command["magnify"] = magnifierValue }
    send(command)
  }
  /// Puts the focus point (and the app's focus box) at `p`, in the live view's normalised
  /// coordinates; the camera's grid is 640 × 480.
  func setFocusPoint(_ p: CGPoint) {
    focusPoint = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    send(["cmd": "afpoint", "x": Int((focusPoint.x * 639).rounded()), "y": Int((focusPoint.y * 479).rounded())])
    // The magnifier follows the point.
    if magnification > 0 { set("Focus_Magnifier_Setting", magnifierValue) }
  }
  /// The shutter, once the last picture is in: the camera takes no new one while it writes and
  /// sends the last, and says nothing. It does not focus, which is AF's: in an autofocus mode the
  /// camera is switched to manual focus first, the lens left where it is.
  func shoot() {
    guard !awaitingPicture else {
      message = "上一张还在写入和传输，到了再拍"
      return
    }
    awaitingPicture = true
    receivedAtPress = received
    presses += 1
    let press = presses
    var command: [String: Any] = ["cmd": "shoot", "mf": autofocusMode]
    if magnification > 0 { command["magnify"] = magnifierValue }
    if focusLocked {
      message = "快门：焦点锁住，不会再对焦"
    } else if autofocusMode {
      message = "快门：先切手动对焦；相机不提供手动对焦时，这一张会先对焦（先按 AF 锁住焦点就不会）"
    }
    send(command)
    // A press that brings no picture says so, rather than nothing; the shutter is free again then.
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pictureWait) { [weak self] in
      guard let self, self.presses == press, self.awaitingPicture, self.received == self.receivedAtPress else { return }
      self.awaitingPicture = false
      if self.connected {
        self.message = "按了快门，但 \(Int(Self.pictureWait)) 秒内没有收到照片：相机可能没有拍，或只存进了存储卡。请把「复制诊断信息」发给我"
      }
    }
  }
  /// How long a press waits for its picture: an uncompressed RAW of the A7R IV is 120 MB.
  static var pictureWait: TimeInterval = 12
  /// The white balance the camera's colour-temperature setting gives.
  static let colourTemperatureMode: Int64 = 0x100
  /// Sets the colour temperature (switching white balance to it first), within what the camera takes.
  func setColourTemperature(_ kelvin: Int64) {
    if properties["WhiteBalance"]?.value != Self.colourTemperatureMode { set("WhiteBalance", Self.colourTemperatureMode) }
    set("Colortemp", properties["Colortemp"]?.nearest(kelvin) ?? kelvin)
  }
  /// A step warmer or cooler: 100 K a click, as the camera steps it.
  func nudgeColourTemperature(by kelvin: Int64) {
    guard let now = properties["Colortemp"]?.value else { return setColourTemperature(5500) }
    setColourTemperature(now + kelvin)
  }
  func quit() {
    send(["cmd": "quit"])
    input = nil
    process = nil
  }

  /// Over PTP: the pixel shift to set once connected (0 to read it), nil when nothing is to be done.
  private var shiftOnConnect: Int?
  /// The PTP process ends when it lets go of the camera (ptpcamerad keeps the USB for as long as it
  /// lives): after it has said so, a connection waits for it to be gone.
  private var retiring = false
  private var connectAfterExit: (card: Bool, shift: Int?)?

  // MARK: The process

  private func launch() {
    let p = Process(), toHelper = Pipe(), fromHelper = Pipe()
    retiring = false
    p.executableURL = helper
    p.arguments = helperArguments
    p.currentDirectoryURL = incoming
    if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
    p.standardInput = toHelper
    p.standardOutput = fromHelper
    p.standardError = fromHelper
    fromHelper.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      DispatchQueue.main.async { self?.consume(data) }
    }
    p.terminationHandler = { [weak self] p in
      DispatchQueue.main.async {
        guard let self, self.process === p else { return }
        self.process = nil
        self.input = nil
        self.liveOn = false
        self.awaitingPicture = false
        self.shiftSwitching = nil
        self.switchOnDisconnect = nil
        if self.link == .ptp, p.terminationStatus == 0 {
          // It let go of the camera, as it does on a disconnect or a failed connection.
          self.retiring = false
          if let next = self.connectAfterExit {
            self.connectAfterExit = nil
            // A moment for ptpcamerad to let go of the USB.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
              if self.phase == .connecting { self.phase = .idle }
              self.connect(keepOnCard: next.card, shift: next.shift)
            }
          } else if self.phase == .connected || self.phase == .connecting {
            self.phase = .idle
            self.message = "已断开"
          }
          return
        }
        if self.phase != .idle {
          self.phase = .failed
          self.message = "相机进程已退出（\(p.terminationStatus)）"
        }
      }
    }
    do {
      try p.run()
      process = p
      input = toHelper.fileHandleForWriting
    } catch {
      phase = .failed
      message = "无法启动相机进程：\(error.localizedDescription)"
    }
  }
  private func send(_ command: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: command, options: [.withoutEscapingSlashes]), let line = String(data: data, encoding: .utf8) else { return }
    note("→ " + line)
    if let transport { return transport(line) }
    guard let input else { return }
    input.write(Data((line + "\n").utf8))
  }
  private func consume(_ data: Data) {
    pending.append(data)
    while let n = pending.firstIndex(of: 10) {
      let line = pending[pending.startIndex..<n]
      pending.removeSubrange(pending.startIndex...n)
      if let text = String(data: line, encoding: .utf8) { receive(text) }
    }
  }
  private func note(_ line: String) {
    log.append(line)
    if log.count > 200 { log.removeFirst(log.count - 200) }
  }

  // MARK: Events

  /// One line from the process.
  func receive(_ line: String) {
    guard let data = line.data(using: .utf8),
      let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let kind = event["event"] as? String
    else {
      note(line)
      return
    }
    if kind != "frame" { note(line) }
    switch kind {
    case "ready": break
    case "connected":
      phase = .connected
      if let m = event["model"] as? String { model = m }
      message = "已连接 \(model)" + (shiftNote.map { "。" + $0 } ?? "")
      shiftNote = nil
      shiftSwitching = nil
      refreshProperties()
      setLive(true)
      if shiftDirect, let shift = shiftOnConnect {
        shiftOnConnect = nil
        if shift > 0 {
          shiftSwitching = shift
          send(["cmd": "shift", "count": shift])
        } else {
          send(["cmd": "shift"])
        }
      }
    case "shift":
      // Over PTP: what the pixel shift reads, after a switch asked for, or as changed on the camera.
      let asked = shiftSwitching ?? (event["asked"] as? Int)
      shiftSwitching = nil
      guard let got = event["shots"] as? Int else {
        let why = event["error"] as? String ?? "读不出相机的像素位移设置"
        message = "像素位移：" + why + (asked == nil ? "" : "：请在相机菜单里设")
        note(message)
        break
      }
      onShiftRead?(got)
      if let asked {
        message = got == asked
          ? "相机已设为\(Self.shiftName(got))"
          : "相机没有改成\(Self.shiftName(asked))，读回来是\(Self.shiftName(got))：请在相机菜单里设"
      } else if event["changed"] as? Bool == true {
        message = "相机上改成了\(Self.shiftName(got))"
      }
    case "disconnected":
      // The SDK's own word on the disconnect a switch asked for, after the helper's: the switch goes on.
      if shiftSwitching != nil, switchOnDisconnect == nil, phase == .connecting { break }
      if link == .ptp {
        retiring = true
        shiftSwitching = nil
      }
      phase = .idle
      focusLocked = false
      awaitingPicture = false
      liveOn = false
      live = nil
      message = event["code"] as? String == "gone" ? "相机断开了（关机或拔了线？）" : "已断开"
      if let s = switchOnDisconnect {
        // The SDK has let go of the camera: its pixel shift set over PTP, and the SDK back.
        switchOnDisconnect = nil
        phase = .connecting
        message = "正在把相机设为\(Self.shiftName(s.count))…"
        overPTP(s.count) { [weak self] said in
          self?.shiftNote = said
          self?.sendConnect(s.card)
        }
      }
    case "warning":
      // The lens refused a focus step (0x60003, an invalid operation, on NearFar): the camera is not
      // in manual focus after all, so the next step switches it first.
      if event["code"] as? String == "0x60003", (event["params"] as? [Int])?.contains(287) == true, let mode = properties["FocusMode"] {
        if mode.value == 1 {
          properties["FocusMode"] = CameraProperty(name: mode.name, value: 0, values: mode.values, settable: mode.settable, type: mode.type)
        }
        message = "相机没有接受对焦步进：它不在手动对焦。镜头上的 AF / MF 开关在 AF 时相机不提供 MF，步进用不了：把开关拨到 MF"
      }
    case "error":
      let stage = event["stage"] as? String ?? ""
      message = (event["message"] as? String ?? "相机出错") + ((event["code"] as? String).map { $0 == "0x0" ? "" : "（\($0)）" } ?? "")
      if stage == "enum" || stage == "connect" || stage == "init" {
        phase = .failed
        shiftSwitching = nil
        shiftNote = nil
        // The PTP process ends after a failed connection.
        if link == .ptp { retiring = true }
      }
      // A camera not found or refused is most often held by a program open beside this one.
      if stage == "enum" || stage == "connect" {
        let rivals = Self.rivals(among: running())
        if !rivals.isEmpty {
          message += "。\(rivals.joined(separator: "、")) 开着，会占住相机：请退出\(rivals.count > 1 ? "它们" : "它")（⌘Q），把相机关机再开，再连接"
          note("占着相机的程序：" + rivals.joined(separator: "、"))
        }
      }
    case "props":
      for item in event["props"] as? [[String: Any]] ?? [] {
        guard let name = item["name"] as? String else { continue }
        // The magnification is what the camera says it is: it ends it by itself, on a change of
        // focus mode or after a while.
        if name == "Focus_Magnifier_Setting", let v = (item["value"] as? NSNumber)?.int64Value {
          let tenths = v >> 32
          magnification = tenths > 10 && tenths != 0xFFFF_FFFF ? tenths : 0
        }
        properties[name] = CameraProperty(
          name: name, value: (item["value"] as? NSNumber)?.int64Value ?? 0,
          values: (item["values"] as? [NSNumber])?.map(\.int64Value) ?? [],
          settable: item["settable"] as? Bool ?? false, type: (item["type"] as? NSNumber)?.uint32Value ?? 0)
      }
    case "changed":
      // Many arrive at once; one read answers them all.
      guard !propsQueued else { return }
      propsQueued = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        self?.propsQueued = false
        if self?.connected == true { self?.refreshProperties() }
      }
    case "set":
      if event["name"] as? String == "NearFar", event["ok"] as? Bool == false, let why = event["code"] as? String, why == "unlocked" || why == "lensMF" {
        message = why == "lensMF"
          ? "镜头上的 AF / MF 开关在 MF：相机驱动不了镜头，步进用不了。用镜头的对焦环手动对焦，或把开关拨回 AF，按 AF 锁住焦点再步进"
          : "步进要先按 AF 锁住焦点：相机不提供手动对焦（镜头开关在 AF），对焦后半按按住时才能微调"
      } else if event["ok"] as? Bool == false {
        message = "设置 \(event["name"] as? String ?? "") 没有生效（\(event["code"] as? String ?? "")）"
      }
    case "unlocked":
      focusLocked = false
      switch event["why"] as? String {
      case "shot": message = "焦点锁随这一张松开了：下一张前再按 AF。整卷不想每张对焦，就在锁焦后把镜头开关拨到 MF，焦点停在原处"
      case "set": message = "改设置前松开了半按，焦点锁已解除：要微调或拍摄不再对焦，再按 AF"
      default: break
      }
    case "live":
      liveOn = event["on"] as? Bool ?? false
      if !liveOn { live = nil }
    case "frame":
      guard let path = event["path"] as? String,
        let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
      else { return }
      live = image
      frames += 1
      sharpness = Sharpness.measure(image, in: measureBox)
    case "af":
      let result = event["result"] as? String ?? ""
      focusResult = result
      focusLocked = event["locked"] as? Bool ?? false
      if result == "lensMF" {
        message = "镜头上的 AF / MF 开关在 MF：相机不自动对焦，焦点停在原处，快门也不会对焦。要自动对焦或步进微调，把开关拨回 AF"
        return
      }
      if focusLocked {
        message = "已合焦，半按按住锁住了焦点：可以步进微调，快门不会再对焦（拍完一张会松开，下一张前再按 AF）"
        return
      }
      let said = result == "focused" ? "已合焦" : result == "failed" ? "相机没能合焦" : "等待合焦超时"
      // Held unless the camera would not go back to manual focus (the lens's AF/MF switch, say).
      message = event["noManual"] as? Bool == true
        ? said + "。相机现在不提供手动对焦（镜头上的 AF / MF 开关在 AF 时就没有 MF），按快门会再对焦一次，对焦步进也用不了：把开关拨到 MF，用镜头的对焦环手动对焦"
        : event["held"] as? Bool == false
        ? said + "，但相机没有切回手动对焦，按快门会再对焦一次：看看镜头上的 AF / MF 开关"
        : said + "，已切回手动对焦，快门不会再对焦"
    case "shot":
      if event["ok"] as? Bool == false {
        message = "快门没有释放（\(event["code"] as? String ?? "")）"
        awaitingPicture = false
      } else {
        shots += 1
        if event["manual"] as? Bool == false { message = "相机没有切到手动对焦，这一张先对了焦：看看镜头上的 AF / MF 开关" }
      }
    case "downloaded":
      received += 1
      let got = received - receivedAtPress
      if got >= picturesPerShot { awaitingPicture = false }
      if picturesPerShot > 1 {
        // The pictures stopping for a while ends the shot, however it was pressed: here, on the
        // camera, or here with the camera answering an error and shooting all the same. The
        // shutter is free again, and a group short of its count is let go.
        let count = received, pressed = awaitingPicture
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.groupWait) { [weak self] in
          guard let self, self.received == count else { return }
          self.awaitingPicture = false
          if pressed {
            self.message = "这一下只收到 \(got) / \(self.picturesPerShot) 张：相机可能没有打开像素位移，或张数不是 \(self.picturesPerShot)。请在相机菜单里设好，或在取景区选「单张」"
          }
          self.onShotEnded?(got)
        }
      } else {
        awaitingPicture = false
      }
      if let ms = event["afterShotMs"] as? Int { log.append("照片在按下快门 \(ms) ms 后到达") }
      if let path = event["path"] as? String, !path.isEmpty { onCapture?(URL(fileURLWithPath: path)) }
    default: break
    }
  }
}
