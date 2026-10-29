import AppKit
import Foundation

/// The camera taken pictures with end to end, without a camera: the controller drives the real
/// camera process, built against a simulated A7R IV (CameraHelper/SimulatedCamera.cpp) that
/// answers as the one on the copy stand did, including what made the shutter unreliable there.
enum CameraSimulationTests {
  final class Session {
    let camera: CameraController
    var arrived = [URL]()
    init(_ camera: CameraController) { self.camera = camera }
    var presses: Int { camera.log.filter { $0.hasPrefix("→") && $0.contains("\"shoot\"") }.count }
  }
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    @discardableResult func until(_ seconds: Double, _ done: () -> Bool) -> Bool {
      let end = Date().addingTimeInterval(seconds)
      while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
      return done()
    }
    let simulator = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/EpsonCameraSimulator")
    guard FileManager.default.isExecutableFile(atPath: simulator.path) else {
      print("PASS: built without Sony's SDK headers, so there is no simulated camera to take pictures with")
      return
    }
    var sessions = [Session]()
    defer { sessions.forEach { $0.camera.quit() } }
    /// A simulated camera set up as `setup` says, connected, its settings read.
    func connect(_ name: String, _ setup: String, live: URL? = nil) -> Session {
      let place = folder.appendingPathComponent("camera-simulated-\(name)", isDirectory: true)
      try? FileManager.default.removeItem(at: place)
      let camera = CameraController(helper: simulator, folder: place)
      camera.environment = ["EPSON_CAMERA_SIM": setup].merging(live.map { ["EPSON_CAMERA_SIM_LIVE": $0.path] } ?? [:]) { $1 }
      let session = Session(camera)
      camera.onCapture = { session.arrived.append($0) }
      sessions.append(session)
      camera.connect()
      until(10) { camera.connected && camera.properties["FocusMode"] != nil }
      return session
    }

    // A fast picture (a JPEG, a compressed RAW) comes before the process has said how the press
    // went: the shutter is free again at once, and nothing says a picture is missing.
    let fast = connect("fast", "transfer=400,early=1500")
    let a = fast.camera
    try check(a.connected && a.autofocusMode && a.log.contains { $0.contains("已切换到电脑优先") },
      "the simulated A7R IV connects through a second and a half of 0x8402, in DMF, and gives the computer priority")
    a.shoot()
    let waiting = a.awaitingPicture
    a.shoot()
    try check(waiting && fast.presses == 1 && a.message.contains("还在写入和传输"),
      "the shutter waits from the press itself: a second press before the picture is not sent")
    until(8) { fast.arrived.count == 1 && a.shots == 1 && !a.awaitingPicture }
    try check(fast.arrived.count == 1 && fast.arrived[0].pathExtension == "ARW" && a.shots == 1 && !a.awaitingPicture
      && a.log.contains { $0.contains("照片在按下快门") },
      "a picture that arrives before the shutter's answer is taken in, and the shutter is free again at once")
    a.shoot()
    until(8) { fast.arrived.count == 2 && !a.awaitingPicture }
    try check(fast.arrived.count == 2 && !a.message.contains("没有收到照片"), "and the next press takes the next picture, nothing said missing")
    // The camera's own priority back (a dial touched): the shutter asks for the computer's first.
    a.set("PriorityKeySettings", 1)
    until(1) { false }
    a.shoot()
    // The press's answer, with its steps, comes after the fast picture.
    until(10) { fast.arrived.count == 3 && a.shots == 3 && !a.awaitingPicture }
    try check(fast.arrived.count == 3 && a.shots == 3 && a.log.contains { $0.contains("电脑优先 0x0") },
      "with the camera's priority back, the shutter takes the computer's first, and the picture comes")

    // A slow picture (an uncompressed RAW, 120 MB): the shutter waits for it, past the press's answer.
    let slow = connect("slow", "transfer=3000,early=200")
    let b = slow.camera
    b.shoot()
    until(6) { b.shots == 1 }
    let heldBack = b.awaitingPicture && slow.arrived.isEmpty
    b.shoot()
    until(6) { slow.arrived.count == 1 && !b.awaitingPicture }
    try check(heldBack && slow.presses == 1 && slow.arrived.count == 1 && !b.awaitingPicture,
      "a picture still being written and sent holds the shutter until it arrives, and a press meanwhile is not sent")

    // Focus first: a half-press that cannot focus takes no picture, and says so.
    let blind = connect("blind", "af=fail,early=200")
    let c = blind.camera
    c.shoot()
    until(8) { c.message.contains("没能合焦") }
    until(2) { false }
    try check(c.message.contains("没能合焦") && !c.awaitingPicture && blind.arrived.isEmpty && c.shots == 0,
      "in DMF a half-press that does not focus takes nothing: the app says so and frees the shutter")

    // A focus step in DMF: switched to manual focus first, the magnifier the switch ends put back.
    let manual = connect("manual", "early=200")
    let d = manual.camera
    d.magnify(59)
    until(1) { false }
    d.step(2)
    until(3) { d.manualFocus && d.magnification == 59 }
    try check(d.manualFocus && d.magnification == 59 && !d.log.contains { $0.contains("0x60003") },
      "a focus step out of DMF switches the camera to manual focus, the lens steps, and the 5.9× magnifier comes back")
    d.set("FocusMode", 6)
    until(1.5) { d.autofocusMode }
    d.receive(#"{"event":"props","props":[{"name":"FocusMode","code":265,"type":2,"value":1,"settable":true,"readable":true,"values":[2,4,3,6,1]}]}"#)
    d.step(1)
    until(3) { d.message.contains("没有接受对焦步进") }
    try check(d.message.contains("没有接受对焦步进") && !d.manualFocus,
      "a step the camera refuses (0x60003 on NearFar: not in manual focus after all) says so, and the next one switches first")

    // Live view, from the camera's pictures as it hands them over.
    let still = folder.appendingPathComponent("camera-simulated-live.jpg")
    let draw = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: ImagePipeline.shared.outputSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw.setFillColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1)
    draw.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let dest = CGImageDestinationCreateWithURL(still as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, draw.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    let watched = connect("live", "early=200", live: still)
    until(6) { watched.camera.frames >= 3 }
    try check(watched.camera.liveOn && watched.camera.frames >= 3 && watched.camera.live?.width == 64,
      "live view comes as pictures through the process: \(watched.camera.frames) frames")

    // No camera.
    let none = folder.appendingPathComponent("camera-simulated-none", isDirectory: true)
    let alone = CameraController(helper: simulator, folder: none)
    alone.environment = ["EPSON_CAMERA_SIM": "cameras=0"]
    sessions.append(Session(alone))
    alone.connect()
    until(6) { alone.phase == .failed }
    try check(alone.phase == .failed && alone.message.contains("没有找到相机"), "with no camera on the cable, it says what to check")
  }
}
