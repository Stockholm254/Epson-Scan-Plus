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
    // As the A7R IV reports itself with the Sigma 70 on: DMF, and the magnifier's steps.
    camera.receive(#"{"event":"props","props":[{"name":"FocusMode","code":265,"type":8194,"value":6,"settable":true,"readable":true,"values":[2,4,3,6]},{"name":"Focus_Magnifier_Setting","code":285,"type":8196,"value":20971760,"settable":true,"readable":true,"values":[4294967295,47244640255,257698037759,515396075519]}]}"#)
    sent.removeAll()
    camera.shoot()
    try check(camera.autofocusMode && sent.last?.contains("\"af\":true") == true,
      "in DMF the shutter is half-pressed to focus before the full press, as in AF-S: a full press alone takes nothing")
    camera.step(3)
    let switched = sent.last?.contains("\"mf\":true") == true && camera.manualFocus
    camera.step(1)
    try check(switched && sent.last?.contains("\"mf\"") == false, "a focus step out of manual focus switches the camera to it first, and only once")
    camera.receive(#"{"event":"shot","ok":true,"code":"0x0","focus":"failed"}"#)
    try check(camera.shots == 1 && camera.message.contains("没能合焦"), "a shot the camera could not focus for says so, and is not counted")
    try check(camera.magnifications == [59, 119], "the camera's own magnifications are read from what it offers: \(camera.magnifications)")
    camera.setFocusPoint(CGPoint(x: 0.5, y: 0.5))
    sent.removeAll()
    camera.magnify(119)
    let magnified = sent.last?.contains("\"Focus_Magnifier_Setting\"") == true && sent.last?.contains("\((Int64(119) << 32) | (Int64(320) << 16) | 240)") == true
    camera.setFocusPoint(CGPoint(x: 0.25, y: 0.5))
    let followed = sent.last?.contains("\((Int64(119) << 32) | (Int64(160) << 16) | 240)") == true
    camera.magnify(0)
    let whole = sent.last?.contains("\((Int64(10) << 32) | (Int64(160) << 16) | 240)") == true
    try check(magnified && followed && whole, "the camera magnifies at the focus point, follows it, and goes back to ×1.0, the whole frame")
    camera.magnify(119)
    camera.receive(#"{"event":"props","props":[{"name":"FocusMode","code":265,"type":8194,"value":6,"settable":true,"readable":true,"values":[2,4,3,6]},{"name":"Focus_Magnifier_Setting","code":285,"type":8196,"value":20971760,"settable":true,"readable":true,"values":[4294967295,47244640255,257698037759,515396075519]}]}"#)
    try check(camera.magnification == 0, "when the camera ends its magnifier by itself, the app shows 1× again")
    camera.magnify(59)
    sent.removeAll()
    camera.step(1)
    try check(sent.last?.contains("\"mf\":true") == true && sent.last?.contains("\"magnify\":\((Int64(59) << 32) | (Int64(160) << 16) | 240)") == true,
      "switching to manual focus to step puts the magnifier back, which the switch ends")
    let stage = CGSize(width: 520, height: 390), point = CGPoint(x: 260, y: 195)
    let standing = LiveLoupe.render(picture(1024, 768), size: stage, at: point, style: .pentax, backing: 2)
    let loupe = CropLens.loupe(picture(160, 107))
    try check(standing.map { $0.image.width == Int($0.frame.width * 2) && $0.frame.contains(point) && CGRect(origin: .zero, size: stage).contains($0.frame) } == true
      && loupe?.width == 224,
      "the light table's loupe stands on the live view at the focus point, and the library's loupe, both at the screen's resolution")
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

    // An uncompressed ARW laid out as the A7R IV writes one, small: IFD0 pointing to the sensor's
    // SubIFD, 14-bit RGGB, black 512, white 16383. Its cells read as they are, no matrix.
    func arw(orientation: Int, compression: Int = 1) -> Data {
      var d = Data()
      func u16(_ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8 & 0xFF)) }
      func u32(_ v: Int) { u16(v & 0xFFFF); u16(v >> 16) }
      func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) { u16(tag); u16(type); u32(count); u32(value) }
      let w = 8, h = 6, sub = 38, black = 176, strip = 184
      d.append(contentsOf: Array("II".utf8)); u16(42); u32(8)
      u16(2); entry(0x112, 3, 1, orientation); entry(0x14A, 4, 1, sub); u32(0)
      u16(11)
      entry(0x100, 3, 1, w); entry(0x101, 3, 1, h); entry(0x102, 3, 1, 14); entry(0x103, 3, 1, compression)
      entry(0x106, 3, 1, 32803); entry(0x111, 4, 1, strip); entry(0x117, 4, 1, w * h * 2)
      entry(0x828D, 3, 2, 2 | 2 << 16); entry(0x828E, 1, 4, 0 | 1 << 8 | 1 << 16 | 2 << 24)
      entry(0x7310, 3, 4, black); entry(0xC61D, 3, 1, 16383); u32(0)
      for _ in 0..<4 { u16(512) }
      for y in 0..<h { for x in 0..<w { u16(512 + (y % 2 == 0 ? (x % 2 == 0 ? 1000 : 2000) : (x % 2 == 0 ? 2002 : 4000))) } }
      return d
    }
    let arwURL = folder.appendingPathComponent("native.ARW")
    try arw(orientation: 1).write(to: arwURL)
    let native = try SensorRaw.nativeRGB(arwURL)
    let bytes = native?.dataProvider?.data as Data?
    func at(_ x: Int, _ y: Int) -> [Int] { bytes.map { b in (0..<3).map { c in let i = 2 * (3 * (y * 8 + x) + c); return Int(b[i]) | Int(b[i + 1]) << 8 } } ?? [] }
    let scale = 65535.0 / (16383 - 512)
    // Within half a percent: the gradient correction answers the greens' 2000 / 2002 by a step.
    func near(_ got: [Int], _ want: [Double]) -> Bool { got.count == 3 && zip(got, want).allSatisfy { abs(Double($0) - $1 * scale) <= max(2, $1 * scale * 0.005) } }
    // A flat field: every photosite keeps its own reading, and the others come out as flat as it.
    try check(native?.width == 8 && native?.height == 6 && native?.bitsPerComponent == 16
      && near(at(2, 2), [1000, 2001, 4000]) && near(at(3, 2), [1000, 2000, 4000]) && near(at(2, 3), [1000, 2002, 4000])
      && near(at(3, 3), [1000, 2001, 4000]),
      "an uncompressed ARW is read at the sensor's full size, each photosite's own colour as measured less the black level, the others interpolated, no colour matrix: \(at(2, 2)) \(at(3, 2)) \(at(2, 3)) \(at(3, 3))")
    try arw(orientation: 6).write(to: arwURL)
    let turned = try SensorRaw.nativeRGB(arwURL)
    try arw(orientation: 1, compression: 32767).write(to: arwURL)
    try check(turned?.width == 6 && turned?.height == 8 && (try SensorRaw.nativeRGB(arwURL)) == nil,
      "turned as the camera was held; a compressed ARW is left to the system's RAW engine")

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
