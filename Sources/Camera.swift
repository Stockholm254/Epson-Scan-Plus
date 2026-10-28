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
  var text: String { Self.describe(name, value) }
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

/// The app's own focusing: the lens is stepped (the SDK's Near/Far, sizes 7, 3, then 1) while the
/// picture in the focus box gets sharper, one step back when it gets blurrier, and then the next
/// smaller size from there, both ways. A step and its reverse are taken to come back to the same
/// place; how far a step of each size moves the lens is not known, so positions are never added up.
struct FocusSearch {
  static let sizes = [7, 3, 1]
  /// Sharper by more than this counts; live view is noisy.
  static let margin = 0.004
  private enum Stage { case start, probe, backThenProbe, backThenNarrow }
  private var stage = Stage.start
  private var size = 0
  private var direction = 1
  private var best = 0.0
  private var improved = false
  private var reversed = false
  private(set) var moves = 0
  private(set) var done = false
  var step: Int { direction * Self.sizes[size] }
  /// Where the lens is now measures `sharpness`: the step to take next, or nil when it is focused.
  mutating func next(_ sharpness: Double) -> Int? {
    guard !done else { return nil }
    moves += 1
    if moves > 60 {
      done = true
      return nil
    }
    switch stage {
    case .start:
      best = sharpness
      stage = .probe
      return step
    case .probe:
      if sharpness > best * (1 + Self.margin) {
        best = sharpness
        improved = true
        return step
      }
      if !improved && !reversed {
        // Blurrier straight away: back to where it was, then the other way.
        reversed = true
        direction = -direction
        stage = .backThenProbe
        return step
      }
      stage = .backThenNarrow
      return -step
    case .backThenProbe:
      stage = .probe
      return step
    case .backThenNarrow:
      size += 1
      guard size < Self.sizes.count else {
        done = true
        return nil
      }
      improved = false
      reversed = false
      stage = .probe
      return step
    }
  }

  /// How sharp `image` is in `box` (normalised, from the top left), channel by channel: the mean
  /// squared Laplacian, which grows as edges and grain come into focus.
  static func sharpness(_ image: CGImage, in box: CGRect) -> RGB {
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

/// Which of the picture's channels is shown: all, or one alone in grey.
enum ChannelView: String, CaseIterable {
  case all = "RGB", r = "R", g = "G", b = "B"
  private static let context = CIContext(options: [.workingColorSpace: NSNull()])
  /// `image` as this view shows it.
  func apply(_ image: CGImage) -> CGImage {
    guard self != .all, let filter = CIFilter(name: "CIColorMatrix") else { return image }
    let pick: CIVector = self == .r ? CIVector(x: 1, y: 0, z: 0, w: 0) : self == .g ? CIVector(x: 0, y: 1, z: 0, w: 0) : CIVector(x: 0, y: 0, z: 1, w: 0)
    filter.setValue(CIImage(cgImage: image, options: [.colorSpace: NSNull()]), forKey: kCIInputImageKey)
    filter.setValue(pick, forKey: "inputRVector")
    filter.setValue(pick, forKey: "inputGVector")
    filter.setValue(pick, forKey: "inputBVector")
    guard let out = filter.outputImage,
      let cg = Self.context.createCGImage(
        out, from: out.extent, format: image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8,
        colorSpace: image.colorSpace ?? ImagePipeline.shared.outputSpace)
    else { return image }
    return cg
  }
}

/// The camera on the copy stand, driven by a process of its own over Sony's Camera Remote SDK
/// (`EpsonCameraHelper`, built when the SDK is on this Mac). Live view arrives as JPEG frames, and
/// each picture taken arrives as a file, which `onCapture` hands on.
final class CameraController: ObservableObject {
  enum Phase: Equatable { case missing, idle, connecting, connected, failed }
  @Published private(set) var phase: Phase
  @Published private(set) var model = ""
  @Published private(set) var message = ""
  @Published private(set) var live: CGImage?
  @Published private(set) var liveOn = false
  @Published private(set) var frames = 0
  /// Sharpness in the focus box of the last live frame.
  @Published private(set) var sharpness: RGB?
  @Published private(set) var properties = [String: CameraProperty]()
  @Published private(set) var focusResult: String?
  @Published private(set) var refining = false
  @Published private(set) var log = [String]()
  /// Where the camera focuses, in the live view's normalised coordinates.
  @Published private(set) var focusPoint = CGPoint(x: 0.5, y: 0.5)
  /// The focus box's side against the live view's width.
  static let boxSize = 0.12
  var onCapture: ((URL) -> Void)?
  /// Lines the controller sends, instead of to the process: for tests.
  var transport: ((String) -> Void)?
  let helper: URL
  let incoming: URL
  let liveFolder: URL
  private var process: Process?
  private var input: FileHandle?
  private var pending = Data()
  private var search: FocusSearch?
  private var settle = 0
  private var propsQueued = false

  init(
    helper: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/EpsonCameraHelper"),
    folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("local.epscan.mac").appendingPathComponent("Camera")
  ) {
    self.helper = helper
    incoming = folder.appendingPathComponent("Incoming")
    liveFolder = folder.appendingPathComponent("Live")
    phase = FileManager.default.isExecutableFile(atPath: helper.path) ? .idle : .missing
  }
  var available: Bool { transport != nil || FileManager.default.isExecutableFile(atPath: helper.path) }
  var connected: Bool { phase == .connected }
  var focusBox: CGRect {
    let s = Self.boxSize
    return CGRect(x: min(max(focusPoint.x - s / 2, 0), 1 - s), y: min(max(focusPoint.y - s / 2, 0), 1 - s), width: s, height: s)
  }
  /// The focus mode is one of the camera's autofocus modes.
  var autofocusMode: Bool { (2...5).contains(properties["FocusMode"]?.value ?? 0) }

  // MARK: Commands

  func connect(keepOnCard: Bool = false) {
    guard available else {
      phase = .missing
      message = "这份 App 构建时没有 Sony Camera Remote SDK"
      return
    }
    guard phase != .connecting, phase != .connected else { return }
    try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: liveFolder, withIntermediateDirectories: true)
    if transport == nil && process == nil { launch() }
    phase = .connecting
    message = "正在连接相机…"
    send(["cmd": "connect", "save": incoming.path, "card": keepOnCard])
  }
  func disconnect() {
    search = nil
    refining = false
    send(["cmd": "disconnect"])
  }
  func setLive(_ on: Bool) { send(["cmd": "live", "on": on, "dir": liveFolder.path]) }
  func refreshProperties() { send(["cmd": "props"]) }
  func set(_ name: String, _ value: Int64) { send(["cmd": "set", "name": name, "value": value]) }
  func autofocus() {
    focusResult = nil
    send(["cmd": "af"])
  }
  func step(_ size: Int) { send(["cmd": "nearfar", "step": max(-7, min(7, size))]) }
  /// Puts the focus point (and the app's focus box) at `p`, in the live view's normalised
  /// coordinates; the camera's grid is 640 × 480.
  func setFocusPoint(_ p: CGPoint) {
    focusPoint = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    send(["cmd": "afpoint", "x": Int((focusPoint.x * 639).rounded()), "y": Int((focusPoint.y * 479).rounded())])
  }
  func shoot() { send(["cmd": "shoot", "af": autofocusMode]) }
  /// Focuses by the sharpness of the live view in the focus box: needs live view and manual focus,
  /// which it switches to.
  func refineFocus() {
    guard connected else { return }
    if !liveOn { setLive(true) }
    if properties["FocusMode"]?.value != 1 { set("FocusMode", 1) }
    search = FocusSearch()
    refining = true
    settle = 3
    message = "精确对焦中…"
  }
  func cancelRefine() {
    search = nil
    refining = false
    message = "已停止精确对焦"
  }
  func quit() {
    send(["cmd": "quit"])
    input = nil
    process = nil
  }

  // MARK: The process

  private func launch() {
    let p = Process(), toHelper = Pipe(), fromHelper = Pipe()
    p.executableURL = helper
    p.currentDirectoryURL = incoming
    p.standardInput = toHelper
    p.standardOutput = fromHelper
    p.standardError = fromHelper
    fromHelper.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      DispatchQueue.main.async { self?.consume(data) }
    }
    p.terminationHandler = { [weak self] p in
      DispatchQueue.main.async {
        guard let self else { return }
        self.process = nil
        self.input = nil
        self.liveOn = false
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
      message = "已连接 \(model)"
      refreshProperties()
      setLive(true)
    case "disconnected":
      phase = .idle
      liveOn = false
      live = nil
      message = "已断开"
    case "error":
      let stage = event["stage"] as? String ?? ""
      message = (event["message"] as? String ?? "相机出错") + ((event["code"] as? String).map { $0 == "0x0" ? "" : "（\($0)）" } ?? "")
      if stage == "enum" || stage == "connect" || stage == "init" { phase = .failed }
      if refining {
        search = nil
        refining = false
      }
    case "props":
      for item in event["props"] as? [[String: Any]] ?? [] {
        guard let name = item["name"] as? String else { continue }
        properties[name] = CameraProperty(
          name: name, value: (item["value"] as? NSNumber)?.int64Value ?? 0,
          values: (item["values"] as? [NSNumber])?.map(\.int64Value) ?? [],
          settable: item["settable"] as? Bool ?? false)
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
      if event["ok"] as? Bool == false {
        message = "设置 \(event["name"] as? String ?? "") 没有生效（\(event["code"] as? String ?? "")）"
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
      let s = FocusSearch.sharpness(image, in: focusBox)
      sharpness = s
      advanceSearch(s.g)
    case "af":
      let result = event["result"] as? String ?? ""
      focusResult = result
      message = result == "focused" ? "已合焦" : result == "failed" ? "相机没能合焦" : "等待合焦超时"
    case "shot":
      if event["ok"] as? Bool == false { message = "快门没有释放（\(event["code"] as? String ?? "")）" }
    case "downloaded":
      if let path = event["path"] as? String, !path.isEmpty { onCapture?(URL(fileURLWithPath: path)) }
    default: break
    }
  }
  /// The next step of the focus search, once the lens has settled for a few frames.
  private func advanceSearch(_ sharpness: Double) {
    guard var s = search else { return }
    if settle > 0 {
      settle -= 1
      return
    }
    if let next = s.next(sharpness) {
      search = s
      step(next)
      settle = 3
    } else {
      search = nil
      refining = false
      message = String(format: "精确对焦完成：清晰度 %.4f，移动 %d 步", sharpness, s.moves)
    }
  }
}
