import AppKit
import Foundation

/// The camera without a camera: the settings as the camera shows them, the app's focus search on
/// simulated optics, the controller fed the process's events, pictures arriving in a camera roll
/// (pixel-shift groups too), the channel gels, and the bundled process starting the SDK.
enum CameraTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let pipe = ImagePipeline.shared
    let space = pipe.outputSpace
    func picture(_ w: Int, _ h: Int, blur: Bool = false, colour: (CGFloat, CGFloat, CGFloat)? = nil) -> CGImage {
      let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      if let colour {
        ctx.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
      }
      // A checkerboard, or the same seen through a soft lens.
      for y in stride(from: 0, to: h, by: 4) {
        for x in stride(from: 0, to: w, by: 4) {
          let on = (x / 4 + y / 4) % 2 == 0
          let v: CGFloat = blur ? (on ? 0.56 : 0.44) : (on ? 0.9 : 0.1)
          ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
          ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
        }
      }
      return ctx.makeImage()!
    }
    func jpeg(_ image: CGImage, _ url: URL) throws {
      guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { throw DeskError.message("jpeg") }
      CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
      guard CGImageDestinationFinalize(dest) else { throw DeskError.message("jpeg") }
    }

    // The settings as the camera shows them.
    try check(CameraProperty.describe("FNumber", 800) == "f/8.0" && CameraProperty.describe("ShutterSpeed", 0x0001_00FA) == "1/250"
      && CameraProperty.describe("ShutterSpeed", 0x012C_000A) == "30\"" && CameraProperty.describe("IsoSensitivity", 100) == "ISO 100"
      && CameraProperty.describe("IsoSensitivity", 0xFFFFFF) == "ISO AUTO" && CameraProperty.describe("FocusMode", 1) == "MF"
      && CameraProperty.describe("FileType", 2) == "RAW",
      "the camera's settings read as the camera shows them: f/8.0, 1/250, 30\", ISO 100, MF, RAW")
    try check(CameraProperty.describe("ExposureBiasCompensation", 65236) == "-0.3 EV" && CameraProperty.describe("ExposureBiasCompensation", 700) == "+0.7 EV"
      && CameraProperty.describe("ExposureBiasCompensation", 0) == "±0.0 EV" && CameraProperty.describe("WhiteBalance", 0x100) == "色温"
      && CameraProperty.describe("WhiteBalance", 0x11) == "日光" && CameraProperty.describe("Colortemp", 5500) == "5500K",
      "exposure compensation reads in EV, negatives too; white balance and colour temperature as the camera names them")
    let range = CameraProperty(name: "Colortemp", value: 5500, values: [2500, 9900, 100], settable: true, type: 0x4002)
    try check(range.isRange && range.nearest(5640) == 5600 && range.nearest(12000) == 9900 && range.nearest(1000) == 2500,
      "a colour temperature is kept within the camera's range, on its 100 K steps")

    // The focus search on simulated optics: sharpness peaks at one lens position.
    var landed = [Int]()
    for peak in [-18, -4, 0, 5, 23] {
      var position = 0, search = FocusSearch()
      while let step = search.next(exp(-pow(Double(position - peak), 2) / 72) + 0.001) { position += step }
      landed.append(position - peak)
    }
    try check(landed.allSatisfy { abs($0) <= 1 },
      "the app's focus search, steps of 7, 3 and 1, finds the sharpest place to within one step: \(landed)")
    let sharp = FocusSearch.sharpness(picture(128, 128), in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let soft = FocusSearch.sharpness(picture(128, 128, blur: true), in: CGRect(x: 0, y: 0, width: 1, height: 1))
    try check(sharp.g > soft.g * 20, "a sharp picture measures sharper than a soft one")

    // The channel gels.
    let red = picture(8, 8, colour: (1, 0, 0))
    let throughRed = pipe.raster(ChannelView.r.apply(red), maxDimension: 8).pixel(4, 4).values
    let throughGreen = pipe.raster(ChannelView.g.apply(red), maxDimension: 8).pixel(4, 4).values
    try check(throughRed.allSatisfy { $0 > 0.95 } && throughGreen.allSatisfy { $0 < 0.05 } && ChannelView.all.apply(red) === red,
      "a gel shows its channel alone in grey: red is white through the red gel, black through the green")

    // The controller, fed the process's events.
    let camFolder = folder.appendingPathComponent("camera", isDirectory: true)
    try? FileManager.default.removeItem(at: camFolder)
    let camera = CameraController(helper: URL(fileURLWithPath: "/nonexistent"), folder: camFolder)
    var sent = [String]()
    camera.transport = { sent.append($0) }
    camera.connect()
    try check(camera.phase == .connecting && sent.last?.contains("\"connect\"") == true && sent.last?.contains(camera.incoming.path) == true,
      "connecting asks the process to connect, the pictures to come to the incoming folder")
    camera.receive(#"{"event":"connected","model":"ILCE-7RM4","cameras":1}"#)
    try check(camera.connected && camera.model == "ILCE-7RM4" && sent.contains { $0.contains("\"props\"") }
      && sent.contains { $0.contains("\"live\"") && $0.contains("true") },
      "once connected it reads the settings and opens live view")
    camera.receive(#"{"event":"props","props":[{"name":"FNumber","code":256,"type":2,"value":800,"settable":true,"readable":true,"values":[400,560,800,1100]},{"name":"FocusMode","code":265,"type":2,"value":1,"settable":true,"readable":true,"values":[1,2]}]}"#)
    try check(camera.properties["FNumber"]?.text == "f/8.0" && camera.properties["FNumber"]?.values.count == 4 && !camera.autofocusMode,
      "the settings arrive with the values the camera offers")
    camera.receive(#"{"event":"props","props":[{"name":"WhiteBalance","code":263,"type":2,"value":0,"settable":true,"readable":true,"values":[0,17,256]},{"name":"Colortemp","code":282,"type":16386,"value":5500,"settable":true,"readable":true,"values":[2500,9900,100]}]}"#)
    sent.removeAll()
    camera.nudgeColourTemperature(by: 100)
    try check(sent.count == 2 && sent[0].contains("\"WhiteBalance\"") && sent[0].contains("256") && sent[1].contains("\"Colortemp\"") && sent[1].contains("5600"),
      "a click warmer switches white balance to colour temperature and sets 5600 K")
    camera.set("FNumber", 1100)
    try check(sent.last?.contains("\"set\"") == true && sent.last?.contains("1100") == true, "a setting is sent by name")
    let live = camFolder.appendingPathComponent("live-1.jpg")
    try jpeg(picture(320, 240), live)
    camera.receive(#"{"event":"live","on":true}"#)
    camera.receive("{\"event\":\"frame\",\"path\":\"\(live.path)\",\"n\":1}")
    try check(camera.live?.width == 320 && camera.frames == 1 && (camera.sharpness?.g ?? 0) > 0,
      "a live frame shows and is measured in the focus box")
    camera.setFocusPoint(CGPoint(x: 0.25, y: 0.75))
    try check(sent.last?.contains("\"afpoint\"") == true && sent.last?.contains("\"x\":160") == true && sent.last?.contains("\"y\":359") == true,
      "a click on the live view moves the camera's focus point on its 640 × 480 grid")
    sent.removeAll()
    camera.refineFocus()
    for _ in 0..<200 where camera.refining { camera.receive("{\"event\":\"frame\",\"path\":\"\(live.path)\",\"n\":2}") }
    let steps = sent.filter { $0.contains("\"nearfar\"") }.count
    try check(!camera.refining && steps >= 4 && !sent.contains { $0.contains("FocusMode") },
      "the focus search steps the lens as frames come, waits for each to settle, and stops: \(steps) steps")
    var arrived: URL?
    camera.onCapture = { arrived = $0 }
    camera.receive("{\"event\":\"downloaded\",\"path\":\"\(camFolder.path)/EPS00001.ARW\",\"type\":1}")
    try check(arrived?.lastPathComponent == "EPS00001.ARW", "a picture the camera sends is handed on")
    camera.receive(#"{"event":"shot","ok":true,"code":"0x0","focus":"skipped"}"#)
    camera.receive(#"{"event":"shot","ok":false,"code":"0x8402","focus":"skipped"}"#)
    try check(camera.shots == 1 && camera.message.contains("快门没有释放"),
      "each shot the camera takes flashes the shutter key once; a shutter that did not go says so")
    let bubble = CropLens.magnifier(picture(320, 240), at: CGPoint(x: 0.5, y: 0.5), box: camera.focusBox, shownWidth: 520, backing: 2)
    let loupe = CropLens.loupe(picture(160, 107))
    try check(bubble?.width == 296 && loupe?.width == 224,
      "the glass bubble over the live view and the library's loupe are drawn at the screen's resolution")
    camera.receive(#"{"event":"error","stage":"enum","code":"0x8000","message":"没有找到相机"}"#)
    try check(camera.phase == .failed && camera.message.contains("没有找到相机"), "a failure is shown as the process says it")

    // Pictures arriving in a camera roll.
    let lib = folder.appendingPathComponent("camera-library", isDirectory: true)
    try? FileManager.default.removeItem(at: lib)
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
    let incoming = folder.appendingPathComponent("camera-incoming", isDirectory: true)
    try? FileManager.default.removeItem(at: incoming)
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    let model = AppModel(libraryURL: lib)
    func capture(_ name: String) throws {
      let url = incoming.appendingPathComponent(name)
      try jpeg(picture(240, 160), url)
      let before = model.frames.count
      model.receiveCapture(url)
      if model.pixelShiftCount == 1 || model.pendingShift.isEmpty {
        for _ in 0..<60 where model.frames.count == before { settle(0.05) }
      }
    }
    try capture("EPS00001.JPG")
    try check(model.captureToast == "第 01 张已入库", "a filed picture says so over the live view for a moment")
    let root = model.sessionURL
    try check(model.rollSource == .camera && model.poolPictures && model.frames.count == 1 && model.frames[0].format == "翻拍"
      && model.frames[0].sourcePath?.hasPrefix(root?.appendingPathComponent("Captures").path ?? "-") == true
      && !FileManager.default.fileExists(atPath: incoming.appendingPathComponent("EPS00001.JPG").path),
      "the first picture starts a camera roll, measured as one roll, and moves into its Captures folder")
    try capture("EPS00002.JPG")
    let entry = RollLibrary.scan([(lib, false)]).first
    try check(model.sessionURL == root && model.frames.count == 2 && model.frames.map(\.name) == ["01", "02"]
      && entry?.source == .camera && entry?.frames.count == 2,
      "the next goes into the same roll, which the library files under 翻拍")
    model.pixelShiftCount = 4
    for n in 3...5 { try capture(String(format: "EPS%05d.JPG", n)) }
    try check(model.frames.count == 2 && model.pendingShift.count == 3 && model.status.contains("3 / 4"),
      "the files of a pixel-shift shot wait for the whole group")
    try capture("EPS00006.JPG")
    for _ in 0..<60 where model.frames.count == 2 { settle(0.05) }
    let group = root?.appendingPathComponent("Captures/PixelShift-001")
    let grouped = (try? FileManager.default.contentsOfDirectory(atPath: group?.path ?? "")) ?? []
    try check(model.frames.count == 3 && grouped.count == 4 && model.pendingShift.isEmpty
      && model.frames[2].sourcePath?.hasSuffix("EPS00003.JPG") == true,
      "a whole group goes into a folder of its own, and its first picture becomes the roll's next frame")

    // The bundled process starts the SDK, its libraries found where the app keeps them.
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/EpsonCameraHelper")
    if FileManager.default.isExecutableFile(atPath: helper.path) {
      let p = Process(), out = Pipe()
      p.executableURL = helper
      p.arguments = ["--probe"]
      p.standardOutput = out
      p.standardError = out
      try p.run()
      p.waitUntilExit()
      let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      try check(p.terminationStatus == 0 && text.contains("\"ready\""),
        "the bundled camera process starts Sony's SDK from the app's Frameworks: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    } else {
      print("PASS: built without Sony's SDK, so the camera panel says so (no camera process to start)")
    }
  }
}
