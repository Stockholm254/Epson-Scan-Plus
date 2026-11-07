import AppKit
import Foundation

/// The camera over its own PTP, without a camera: the A7R IV's property list as it answered it,
/// read and written back; its settings in the SDK's names and values; a live-view frame and a
/// picture's object info; then the controller driving this app's own `--sony-ptp-camera` process
/// against a simulated A7R IV (SonyPTPSimulation.swift), the pixel shift switched while connected.
enum SonyPTPTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    @discardableResult func until(_ seconds: Double, _ done: () -> Bool) -> Bool {
      let end = Date().addingTimeInterval(seconds)
      while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
      return done()
    }

    // The list as the camera sent it.
    let recorded = Data(base64Encoded: SimulatedSonyBody.recorded.joined()) ?? Data()
    let list = SonyWire.descriptors(recorded)
    let focus = list[0x500A]
    try check(list.count >= 80 && focus?.current == 2 && focus?.values == [2, 0x8006] && focus?.settable.contains(1) == true
      && list[0x5007]?.current == 450 && list[0xD20D]?.current == 0x1007D && list[0xD20F]?.range == [2500, 9900, 100]
      && list[0xD218]?.current == 99 && list[0xD254]?.values.contains(0x3B_FFFF_FFFF) == true
      && SonySettings.shots(list) == 4,
      "the A7R IV's property list reads: \(list.count) settings, AF-S offering AF-S and DMF (MF only settable), f/4.5, 1/125, the colour temperature's range, battery 99, the magnifier's steps, pixel shift 4")
    let again = SonyWire.descriptors(SonyWire.encode(Array(list.values)))
    try check(again == list.filter { SonyWire.size($0.value.type) != nil },
      "and written back as the camera writes it, it reads the same")

    func app(_ name: String) -> CameraProperty? {
      guard let s = SonySettings.named(name), let d = list[s.code] else { return nil }
      let o = SonySettings.describe(s, d)
      return CameraProperty(name: name, value: (o["value"] as? NSNumber)?.int64Value ?? 0,
        values: (o["values"] as? [NSNumber])?.map(\.int64Value) ?? [], settable: o["settable"] as? Bool ?? false,
        type: (o["type"] as? NSNumber)?.uint32Value ?? 0)
    }
    let wb = app("WhiteBalance"), temp = app("Colortemp"), mode = app("FocusMode"), store = app("StillImageStoreDestination")
    try check(wb?.value == CameraController.colourTemperatureMode && wb?.text == "色温" && wb?.values.contains(0x12) == true
      && temp?.isRange == true && temp?.nearest(5480) == 5500 && mode?.text == "AF-S" && mode?.values == [2, 6]
      && store?.value == 1 && store?.settable == true && app("PriorityKeySettings")?.value == 2
      && app("ShutterSpeed")?.text == "1/125" && app("FNumber")?.text == "f/4.5" && app("BatteryRemain")?.text == "99%"
      && app("ExposureProgramMode")?.text == "M" && app("FileType")?.text == "RAW",
      "the camera's settings in the SDK's names and values: colour temperature, its range, AF-S, the computer for the pictures and its priority, 1/125, f/4.5, 99%, M, RAW")
    let shade = SonySettings.named("WhiteBalance")!, area = SonySettings.named("FocusArea")!
    try check(shade.camera(0x12) == 0x8011 && shade.app(0x8011) == 0x12 && area.app(0x103) == 6 && area.camera(4) == 0x101
      && SonySettings.named("FocusMode")!.camera(6) == 0x8006 && SonySettings.named("BatteryRemain")!.app(-1) == 0xFFFF
      && SonySettings.named("StillImageStoreDestination")!.camera(3) == 0x11,
      "and back: shade, flexible spots, DMF, no battery reading, the computer and the card")

    // A live-view frame, with its header and without; a picture's name and size.
    let jpeg = Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9])
    var framed = Data([16, 0, 0, 0, UInt8(jpeg.count), 0, 0, 0]) + Data(count: 8) + jpeg + Data([9, 9])
    let headed = SonyWire.liveJPEG(framed)
    framed[0] = 200
    try check(headed == jpeg && SonyWire.liveJPEG(framed) == jpeg && SonyWire.liveJPEG(Data([1, 2, 3])) == nil,
      "the live view's JPEG is taken where its header says, else between its markers")
    let info = SonyWire.objectName(SonyWire.objectInfo(name: "DSC04370.ARW", size: 122_583_040))
    try check(info?.name == "DSC04370.ARW" && info?.size == 122_583_040, "a picture's object info gives its name and size")

    // The controller and the process, against the simulated A7R IV.
    guard Bundle.main.executableURL.map({ FileManager.default.isExecutableFile(atPath: $0.path) }) == true else {
      print("PASS: no app executable to start the PTP camera process from")
      return
    }
    final class Session {
      let camera: CameraController
      var arrived = [URL](), shifts = [Int]()
      init(_ camera: CameraController) { self.camera = camera }
    }
    var sessions = [Session]()
    defer { sessions.forEach { $0.camera.quit() } }
    func start(_ name: String, _ setup: String, wait: Bool = true) -> Session {
      let place = folder.appendingPathComponent("camera-ptp-\(name)", isDirectory: true)
      try? FileManager.default.removeItem(at: place)
      let camera = CameraController(folder: place, link: .ptp)
      camera.environment = ["EPSCAN_PTP_SIM": setup]
      let s = Session(camera)
      camera.onCapture = { s.arrived.append($0) }
      camera.onShiftRead = { n in
        s.shifts.append(n)
        camera.picturesPerShot = n
      }
      sessions.append(s)
      camera.connect()
      if wait { until(15) { camera.connected && camera.properties["FocusMode"] != nil && !s.shifts.isEmpty } }
      return s
    }

    let a = start("a", "transfer=150")
    let c = a.camera
    try check(c.connected && c.link == .ptp && c.model == "ILCE-7RM4" && a.shifts == [4] && c.picturesPerShot == 4
      && c.properties["FNumber"]?.text == "f/4.5" && c.properties["Colortemp"]?.isRange == true
      && c.log.contains { $0.contains("已切换到电脑优先") },
      "over PTP the simulated A7R IV connects, takes the computer's priority, its settings read as the SDK's, its pixel shift (4) read")
    until(5) { c.frames >= 3 }
    try check(c.liveOn && c.frames >= 3 && c.live != nil, "its live view comes, frame after frame")

    c.shoot()
    until(15) { a.arrived.count == 4 && !c.awaitingPicture && c.shots == 1 }
    let names = Set(a.arrived.map(\.lastPathComponent))
    try check(a.arrived.count == 4 && names.count == 4 && a.arrived.allSatisfy { $0.pathExtension == "ARW" && FileManager.default.fileExists(atPath: $0.path) }
      && !c.awaitingPicture && c.shots == 1,
      "one press with pixel shift 4 brings four RAWs, fetched one by one from the camera, and frees the shutter")
    try check(c.log.contains { $0.contains("没能切到 MF") },
      "MF, not on offer with the lens's switch at AF, is asked for once and, not taken, said so")

    let framesBefore = c.frames
    var everLeft = false
    c.switchPixelShift(to: 16, keepOnCard: false)
    until(10) {
      if !c.connected { everLeft = true }
      return c.shiftSwitching == nil
    }
    until(1) { false }
    try check(!everLeft && c.connected && a.shifts.last == 16 && c.picturesPerShot == 16 && c.message.contains("像素位移 16 张")
      && c.frames > framesBefore,
      "pixel shift 16 is set while connected: the camera is never let go of, and the live view goes on")
    c.shoot()
    until(20) { a.arrived.count == 20 && !c.awaitingPicture && c.shots == 2 }
    try check(a.arrived.count == 20 && !c.awaitingPicture, "and the next press brings sixteen")

    c.switchPixelShift(to: 1, keepOnCard: false)
    until(10) { c.shiftSwitching == nil }
    try check(a.shifts.last == 1 && c.picturesPerShot == 1 && c.connected,
      "pixel shift off straight after the group, once the camera has finished it, again while connected")
    c.set("FNumber", 800)
    until(5) { c.properties["FNumber"]?.value == 800 }
    try check(c.properties["FNumber"]?.text == "f/8.0", "a setting written comes back as the camera reports it, a read late")

    // AF with MF not on offer: in DMF, the half-press held locks the focus; the shutter over it.
    c.autofocus()
    until(10) { c.focusResult != nil && c.properties["FocusMode"]?.value == 6 }
    try check(c.focusResult == "focused" && c.focusLocked && c.properties["FocusMode"]?.text == "DMF",
      "AF focuses in DMF and the half-press held locks the focus")
    c.shoot()
    until(10) { a.arrived.count == 21 && !c.awaitingPicture && !c.focusLocked && c.shots == 3 }
    try check(a.arrived.count == 21 && !c.focusLocked && c.log.contains { $0.contains("焦点锁住，不再对焦") },
      "the shutter pressed over the lock takes one picture without focusing again, and the lock goes with it")
    c.switchPixelShift(to: 4, keepOnCard: false)
    until(12) { c.shiftSwitching == nil }
    try check(a.shifts.last == 4 && c.picturesPerShot == 4,
      "and the half-press is let go of after it, so the pixel shift switches again (the camera takes no setting while it is held)")

    // Let go of: the process ends; a connection straight after waits for it to be gone.
    c.disconnect()
    until(5) { c.phase == .idle }
    let idle = c.phase == .idle
    c.connect()
    until(15) { c.connected && a.shifts.count >= 5 }
    try check(idle && c.connected && a.shifts.count == 5 && a.shifts.last == 4,
      "let go of, and connected again at once: a new process, once the last has gone, the pixel shift read again")
    c.disconnect()
    until(5) { c.phase == .idle }
    until(1) { false }
    try check(c.phase == .idle && c.message == "已断开", "and let go of again, the process gone without a word of failure")

    // No camera on the cable: said so, and nothing more once the process has gone.
    let none = start("none", "absent=1", wait: false)
    until(5) { none.camera.phase == .failed }
    until(1.5) { false }
    try check(none.camera.phase == .failed && none.camera.message.contains("没有找到相机"),
      "with no camera found, the connection fails saying so, and the process's going changes nothing")

    // A connection that asks for a count sets it once connected.
    let b = start("b", "shift=1,transfer=100")
    try check(b.shifts == [1], "a camera with pixel shift off reads as single shots")
    b.camera.disconnect()
    until(5) { b.camera.phase == .idle }
    until(1) { false }
    b.camera.connect(shift: 16)
    until(15) { b.camera.connected && b.shifts.last == 16 && b.camera.shiftSwitching == nil }
    try check(b.shifts.last == 16 && b.camera.message.contains("像素位移 16 张"), "a count chosen before connecting is set as it connects")
  }
}
