import CoreGraphics
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

/// The 去漏光 page: FilmLightLab's engine on a leaked picture with a clean reference, the exact
/// colour conversion it reads with, its saved model, the request to the image model (to a local
/// stub, never the network), the Keychain (a temporary one, never the user's), a job from import
/// to export, a frame of a roll, and the page over MCP.
enum LightLeakTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let root = folder.appendingPathComponent("light-leak")
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // A day scene with hard edges, a leak from the left, and the clean scene as the reference.
    func scene(_ x: Double, _ y: Double) -> SIMD3<Double> {
      var p = y < 0.45 ? SIMD3(0.42, 0.58, 0.85) * (1 - y / 0.45) + SIMD3(0.78, 0.82, 0.9) * (y / 0.45)
        : SIMD3(0.24, 0.34, 0.15) + 0.05 * sin(x * 40) * cos(y * 30) * SIMD3(1, 1, 0.5)
      for (bx, bw, top, c) in [(0.1, 0.12, 0.3, SIMD3(0.55, 0.5, 0.45)), (0.45, 0.15, 0.25, SIMD3(0.7, 0.62, 0.5)), (0.7, 0.1, 0.33, SIMD3(0.3, 0.28, 0.27))]
      where x > bx && x < bx + bw && y > top && y < 0.62 {
        p = Int((x - bx) * 120) % 3 == 0 && Int((y - top) * 90) % 3 == 0 ? c * 0.6 : c
      }
      return p
    }
    func picture(_ w: Int, _ h: Int, leaked: Bool) -> LeakImage {
      var data = [UInt16](repeating: 0, count: w * h * 3)
      for j in 0..<h {
        for i in 0..<w {
          let x = (Double(i) + 0.5) / Double(w), y = (Double(j) + 0.5) / Double(h)
          var p = scene(x, y)
          if leaked {
            let l = SIMD3(pow(p.x, 2.2), pow(p.y, 2.2), pow(p.z, 2.2)) + exp(-x / 0.22) * (0.8 + 0.2 * sin(y * 5)) * SIMD3(0.30, 0.04, 0.10)
            p = SIMD3(pow(min(1, l.x), 1 / 2.2), pow(min(1, l.y), 1 / 2.2), pow(min(1, l.z), 1 / 2.2))
          }
          for c in 0..<3 { data[(j * w + i) * 3 + c] = UInt16((min(1, max(0, p[c])) * 65535).rounded()) }
        }
      }
      return LeakImage(width: w, height: h, data: data)
    }
    func error(_ a: LeakImage, _ b: LeakImage) -> Double {
      var e = 0.0
      for i in 0..<a.data.count { e += abs(Double(a.data[i]) - Double(b.data[i])) }
      return e / Double(a.data.count) / 65535
    }
    let leaked = picture(1200, 800, leaked: true), clean = picture(1200, 800, leaked: false)
    let referenceURL = root.appendingPathComponent("reference.png")
    try ImagePipeline.shared.savePNG(
      ImagePipeline.shared.converted(picture(768, 512, leaked: false).cgImage(), to: CGColorSpace(name: CGColorSpace.sRGB)!, bitsPerComponent: 8)!,
      to: referenceURL)
    let guide = LeakEngine.resized(try LeakImage(contentsOf: referenceURL), width: 640)
    let fitted = try LeakEngine.fitReference(base: leaked, guide: guide, params: LeakParams(), baseID: "base")
    let repaired = try LeakEngine.result(leaked, base: leaked, params: fitted)
    let model = fitted.referenceModel!
    try check(model.kind == "hybrid-veil-bilateral-v9" && model.alignment.rotation == 0 && model.alignment.reliable && fitted.sceneInfo != nil,
      "the reference is fitted with revision 9's model, aligned and with the scene judged (\(fitted.sceneInfo?.label ?? "?"))")
    try check(model.veilField.sample(0.03, 0.5) > 0.2 && model.veilField.sample(0.9, 0.5) < 0.05,
      String(format: "the leak is found where it is: confidence %.2f at the left edge, %.2f across", model.veilField.sample(0.03, 0.5), model.veilField.sample(0.9, 0.5)))
    try check(error(repaired, clean) < error(leaked, clean) * 0.3,
      String(format: "the leak is taken out: mean error to the clean picture %.4f → %.4f", error(leaked, clean), error(repaired, clean)))
    var off = fitted
    off.referenceModel?.strength = 0
    try check(try LeakEngine.result(leaked, base: leaked, params: off).data == leaked.data, "at strength 0 every pixel stays as it was")
    var guarded = fitted
    guarded.protect.append(LeakRegion(id: "hand", name: "手绘保护区", shape: "ellipse", x: 0.1, y: 0.5, rx: 0.06, ry: 0.06))
    let kept = try LeakEngine.result(leaked, base: leaked, params: guarded)
    let centre = (400 * 1200 + 120) * 3
    try check(kept.data[centre..<(centre + 3)] == leaked.data[centre..<(centre + 3)] && repaired.data[centre] != leaked.data[centre],
      "a hand-drawn protection keeps the original's pixels where it covers")
    // Rotated a quarter turn, the reference is still found.
    let turned = LeakEngine.cropped(leaked, rotation: 90, crop: LeakCrop())
    let refit = try LeakEngine.fitReference(base: turned, guide: guide, params: LeakParams(), baseID: "turned")
    // Turned clockwise, (x, y) on the original is (y, 1 − x) on the reference: FilmLightLab's 90°.
    try check(turned.width == 800 && refit.referenceModel?.alignment.rotation == 90 && refit.referenceModel?.alignment.reliable == true,
      "a turned original finds its reference's orientation (\(refit.referenceModel?.alignment.rotation ?? -1)°)")

    // The saved model: FilmLightLab's keys, read back the same, and a damaged one refused.
    let encoded = try JSONEncoder().encode(fitted)
    let decoded = try JSONDecoder().decode(LeakParams.self, from: encoded)
    let keys = (try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["referenceModel"] as? [String: Any]
    try check(decoded == fitted && Set(["grid", "bilateral", "veilField", "neutralField", "tonePolicy", "scenePolicy", "alignment"]).isSubset(of: Set(keys?.keys ?? [:].keys)),
      "parameters and the model are saved with FilmLightLab's keys and read back unchanged")
    var damaged = model
    damaged.grid.nodes.removeLast()
    try check((try? damaged.validate()) == nil && (try? LeakEngine.apply(leaked, damaged, fitted)) == nil, "a damaged model is refused, not read out of bounds")

    // Colour: sRGB into Adobe RGB exactly, as the engine's pure 563/256 gamma decodes it.
    var ramp = [UInt8](repeating: 255, count: 256 * 2 * 4)
    for v in 0..<256 { for r in 0..<2 { let i = (r * 256 + v) * 4; ramp[i] = UInt8(v); ramp[i + 1] = UInt8(v); ramp[i + 2] = UInt8(v) } }
    let rampImage = CGImage(width: 256, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(ramp) as CFData)!,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let converted = try LeakImage(rampImage)
    let worst = (0..<256).map { v -> Double in
      let s = Double(v) / 255, lin = s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
      return abs(Double(converted.data[v * 3]) - pow(lin, 256 / 563.0) * 65535)
    }.max()!
    try check(worst <= 1, "sRGB becomes Adobe RGB by the exact curves, deep shadows included (worst \(worst) of 65535)")
    let tiff = root.appendingPathComponent("roundtrip.tif")
    try leaked.saveTIFF(to: tiff)
    try check(try LeakImage(contentsOf: tiff).data == leaked.data, "a 16-bit Adobe RGB TIFF is read back sample for sample")
    let jpeg = LeakLab.withoutExif(try leaked.jpeg(maxDimension: 1536, quality: 0.94).data)
    let jpegSource = CGImageSourceCreateWithData(jpeg as CFData, nil)
    let jpegProperties = jpegSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
    try check(jpegProperties?[kCGImagePropertyExifDictionary] == nil && jpegSource.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?.width == 1200,
      "the upload is a JPEG with no Exif")

    // The image model, asked through a stub: what is sent, and how answers and failures read.
    let key = "sk-test-synthetic-0000000000"
    LeakStub.handler = { request in
      LeakStub.request = request
      let image = try! ImagePipeline.shared.load(referenceURL)
      let png = NSMutableData()
      let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
      CGImageDestinationAddImage(dest, image, nil)
      CGImageDestinationFinalize(dest)
      let body = try! JSONSerialization.data(withJSONObject: ["data": [["b64_json": (png as Data).base64EncodedString()]], "size": "1536x1024", "usage": ["total_tokens": 1234]])
      return (200, ["x-request-id": "req_test"], body)
    }
    let request = LeakOpenAI.Request(apiKey: key, model: LeakOpenAI.defaultModel, quality: "high", jpeg: jpeg, width: 1200, height: 800, note: "", scene: "day")
    func call(_ r: LeakOpenAI.Request) -> Result<(bytes: Data, meta: LeakJob.Generated), Error> {
      let done = DispatchSemaphore(value: 0)
      var outcome: Result<(bytes: Data, meta: LeakJob.Generated), Error>!
      Task {
        do { outcome = .success(try await LeakOpenAI.edit(r, session: LeakOpenAI.session(protocols: [LeakStub.self]))) } catch { outcome = .failure(error) }
        done.signal()
      }
      done.wait()
      return outcome
    }
    let answer = try call(request).get()
    let sent = LeakStub.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let image = ((sent?["images"] as? [[String: Any]])?.first?["image_url"] as? String) ?? ""
    try check(LeakStub.request?.url == LeakOpenAI.endpoint && LeakStub.request?.httpMethod == "POST"
      && LeakStub.request?.value(forHTTPHeaderField: "Authorization") == "Bearer " + key
      && sent?["model"] as? String == LeakOpenAI.defaultModel && sent?["size"] as? String == "1536x1024" && sent?["n"] as? Int == 1
      && image.hasPrefix("data:image/jpeg;base64,") && (sent?["prompt"] as? String)?.contains("DAY / NATURAL LIGHT") == true,
      "one request to the images endpoint: the key in the header only, the JPEG, size and the day prompt")
    try check(answer.meta.requestId == "req_test" && answer.meta.usage?.total_tokens == 1234 && answer.meta.promptVersion == LeakOpenAI.promptVersion
      && answer.bytes.count > 1000, "the reference comes back with what to record of the request")
    LeakStub.handler = { _ in (401, [:], try! JSONSerialization.data(withJSONObject: ["error": ["message": "Incorrect API key provided: \(key)"]])) }
    let refused = call(request)
    let message = (try? refused.get()).map { _ in "" } ?? { if case .failure(let e) = refused { return e.localizedDescription }; return "" }()
    try check(message.contains("401") && message.contains("未自动重试") && !message.contains(key) && message.contains("[REDACTED]"),
      "a refusal says what went wrong, with the key taken out, and is not retried")
    try check(LeakOpenAI.redact("bad sk-abc_DEF-123 here", key: "") == "bad [REDACTED] here" && (try? LeakOpenAI.outputSize(4000, 1000)) == nil,
      "anything like a key is redacted, and pictures wider than 3:1 are refused before upload")

    // The Keychain: a temporary one only, with a synthetic key.
    let keychainFolder = root.appendingPathComponent("keychain")
    try FileManager.default.createDirectory(at: keychainFolder, withIntermediateDirectories: true)
    let password = Array(UUID().uuidString.utf8)
    var keychain: SecKeychain?
    let created = password.withUnsafeBytes { SecKeychainCreate(keychainFolder.appendingPathComponent("test.keychain").path, UInt32(password.count), $0.baseAddress, false, nil, &keychain) }
    if created == errSecSuccess, let keychain {
      defer { SecKeychainDelete(keychain) }
      let store = LeakKeychain(service: "local.epscan.test.\(UUID().uuidString)", keychain: keychain)
      let credentials = LeakCredentials(store: store)
      try credentials.update(apiKey: key, model: "gpt-image-2", remember: true)
      let reopened = LeakCredentials(store: LeakKeychain(service: store.service, keychain: keychain))
      reopened.restore()
      try check(reopened.configured && reopened.remembered && reopened.secret == key && reopened.model == "gpt-image-2",
        "a remembered key is found again by the next launch, with its model")
      try credentials.update(apiKey: "", model: LeakOpenAI.defaultModel, remember: false)
      let forgotten = LeakCredentials(store: LeakKeychain(service: store.service, keychain: keychain))
      forgotten.restore()
      try check(credentials.configured && !forgotten.configured && (try store.load()) == nil,
        "not remembering keeps the key for this session only and takes it out of the Keychain")
      try check((try? credentials.update(apiKey: "short", model: LeakOpenAI.defaultModel, remember: false)) == nil && credentials.secret == key,
        "a malformed key is refused and the current one kept")
      credentials.clear()
      try check(!credentials.configured && credentials.secret.isEmpty, "removing the key forgets it")
    } else {
      print("SKIP: Keychain checks (no temporary keychain: \(created))")
    }

    // A job: an imported positive, a reference from a file, the repair, undo, scene, export.
    let lab = LeakLab(root: root.appendingPathComponent("jobs"))
    let undo = UndoManager()
    undo.groupsByEvent = false
    lab.undoManager = undo
    let sourceURL = root.appendingPathComponent("leaked.tif")
    try leaked.saveTIFF(to: sourceURL)
    let sourceBytes = try Data(contentsOf: sourceURL)
    lab.importFile(sourceURL)
    lab.wait()
    try check(lab.hasBase && !lab.hasReference && lab.job?.source != nil && lab.before != nil && lab.errorText == nil,
      "an imported positive is copied into its job and shown")
    lab.start()
    try check(lab.showAPI && lab.busy == nil, "without a reference or a key, starting asks for the key and calls nothing")
    lab.showAPI = false
    lab.importReference(referenceURL)
    lab.wait()
    lab.start()
    lab.wait()
    let strength = lab.model?.strength
    try check(lab.repaired && lab.after != nil && lab.wipe == 0.5 && strength == 1, "with a reference, starting repairs here and shows before and after")
    lab.setStrength(0.4)
    lab.wait()
    try check(lab.model?.strength == 0.4, "the strength changes")
    undo.undo()
    lab.wait()
    try check(lab.model?.strength == 1, "and ⌘Z takes it back")
    lab.setScene("night")
    lab.wait()
    try check(lab.params.sceneInfo?.type == "night" && lab.repaired, "a new scene is fitted again against the reference, for free")
    let exportURL = root.appendingPathComponent("out").appendingPathComponent("leaked_去漏光.tif")
    try FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("an older export".utf8).write(to: exportURL.deletingPathExtension().appendingPathExtension("jpg"))
    lab.export(to: exportURL)
    lab.wait()
    let exported = try ImagePipeline.shared.load(exportURL)
    let older = try String(contentsOf: exportURL.deletingPathExtension().appendingPathExtension("jpg"), encoding: .utf8)
    try check(exported.width == 1200 && exported.height == 800 && exported.bitsPerComponent == 16 && exported.colorSpace?.name == CGColorSpace.adobeRGB1998
      && FileManager.default.fileExists(atPath: exportURL.deletingLastPathComponent().appendingPathComponent("leaked_去漏光-2.jpg").path)
      && FileManager.default.fileExists(atPath: exportURL.path + ".json") && older == "an older export",
      "the export is a full-size 16-bit Adobe RGB TIFF with an sRGB JPEG and a record beside it, over nothing else")
    try check(try Data(contentsOf: sourceURL) == sourceBytes, "the imported original is not changed")
    let id = lab.job!.id
    let reopened = LeakLab(root: lab.root)
    reopened.open(id)
    reopened.wait()
    try check(reopened.params == lab.params && reopened.repaired && reopened.hasReference && reopened.jobs().first?.id == id,
      "the job opens again as it was left")
    // The paid path, from the stub's answer: the reference is kept before it is fitted.
    let fresh = LeakLab(root: lab.root)
    fresh.importFile(sourceURL)
    fresh.wait()
    try fresh.receive(answer, prepared: try LeakEngine.prepare(base: leaked, params: LeakParams(), target: nil))
    fresh.wait()
    try check(fresh.repaired && fresh.job?.generatedAI?.requestId == "req_test" && fresh.job?.guide.map { FileManager.default.fileExists(atPath: fresh.folder!.appendingPathComponent($0).path) } == true,
      "a generated reference is saved with its record, then fitted")

    // A frame of a roll, converted by the app, and the page over MCP.
    let roll = root.appendingPathComponent("roll")
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    let negative = LeakImage(width: 900, height: 600, data: leaked.data.enumerated().compactMap { i, v in
      let p = i / 3, x = p % 1200, y = p / 1200
      return x < 900 && y < 600 ? 65535 - v : nil
    })
    let overviewURL = roll.appendingPathComponent("overview.tif")
    try negative.saveTIFF(to: overviewURL)
    let frame = FilmFrame(name: "01", rect: NormalRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), format: "135")
    let project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 300, physicalWidthMM: 76.2, physicalHeightMM: 50.8,
      filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: [frame])
    let projectURL = roll.appendingPathComponent("Session.epscan")
    try JSONEncoder().encode(project).write(to: projectURL)
    let app = AppModel(libraryURL: roll)
    app.loadProject(projectURL)
    for _ in 0..<40 where app.rendering { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    let pageLab = LeakLab(root: root.appendingPathComponent("frame-jobs"))
    pageLab.renderFrame = { try app.leakPositive($0) }
    app.leak = pageLab
    app.undoManager = undo
    pageLab.undoManager = undo
    func mcp(_ name: String, _ arguments: [String: Any] = [:]) -> (content: [[String: Any]], isError: Bool) {
      let done = DispatchSemaphore(value: 0)
      var result: (content: [[String: Any]], isError: Bool)!
      DispatchQueue.global().async {
        result = MCPTools.call(name, arguments, model: app)
        done.signal()
      }
      while done.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
      return result
    }
    let names = MCPTools.tools.map(\.name)
    try check(names.filter { $0.hasPrefix("leak_") }.count == 8 && Set(names).count == names.count && MCPTools.instructions.contains("leak_request_reference"),
      "the MCP server lists the 去漏光 tools beside the conversion ones")
    let opened = mcp("leak_open", ["frame": "01"])
    try check(!opened.isError && app.page == .leak && pageLab.job?.origin?.frame == frame.id && pageLab.hasBase && !FileManager.default.fileExists(atPath: pageLab.root.path),
      "leak_open converts the roll's frame for the page, and keeps nothing until it is worked on")
    let state = (mcp("leak_get_state").content.first?["text"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    try check((state?["photo"] as? [String: Any])?["frame"] as? String == "01" && (state?["reference"] as? [String: Any])?["present"] as? Bool == false
      && state?["api_key_configured"] as? Bool == false && state?.description.contains("sk-") == false,
      "leak_get_state reads the photo and whether a reference and a key exist, never the key")
    let started = mcp("leak_start")
    try check(started.isError && (started.content.first?["text"] as? String)?.contains("leak_request_reference") == true,
      "without a reference, leak_start says the reference must be asked of the user")
    let asked = mcp("leak_request_reference")
    try check(!asked.isError && pageLab.showAPI && pageLab.busy == nil && pageLab.job?.generatedAI == nil,
      "leak_request_reference only opens the app's own confirmation: no upload, no charge")
    pageLab.showAPI = false
    pageLab.importReference(referenceURL)
    pageLab.wait()
    try check(!mcp("leak_start").isError && pageLab.repaired && FileManager.default.fileExists(atPath: pageLab.folder!.appendingPathComponent("job.json").path),
      "leak_start repairs with the reference, and the job is kept from then on")
    try check(!mcp("leak_set", ["strength": 0.6, "exposure": 0.25]).isError && pageLab.model?.strength == 0.6 && pageLab.params.exposure == 0.25
      && mcp("leak_set", ["rotation": 90]).isError, "leak_set changes only what it is given, and refuses what it does not know")
    let shot = mcp("leak_preview", ["kind": "result", "max_size": 400])
    let shotImage = (shot.content.first?["data"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
      .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    let sampled = (mcp("leak_sample", ["points": [[0.03, 0.5], [0.9, 0.5]]]).content.first?["text"] as? String)
      .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]] }
    let confidence = sampled?.compactMap { $0["leak_confidence"] as? Double } ?? []
    try check(shotImage.map { max($0.width, $0.height) <= 400 } == true && confidence.count == 2 && confidence.allSatisfy { (0...1).contains($0) }
      && sampled?.allSatisfy { $0["original_adobe_rgb"] != nil && $0["result_adobe_rgb"] != nil } == true,
      "leak_preview shows the result, and leak_sample reads before, after and the leak's confidence at each point")
    let undone = mcp("undo")
    try check(!undone.isError && pageLab.model?.strength == 1, "undo over MCP takes back the page's last change")
    let frameExport = root.appendingPathComponent("out").appendingPathComponent("frame.tif")
    pageLab.export(to: frameExport)
    pageLab.wait()
    let frameImage = try ImagePipeline.shared.load(frameExport)
    try check(frameImage.width == pageLab.job?.meta?.width && frameImage.bitsPerComponent == 16 && pageLab.errorText == nil,
      "a frame's export converts it again at full size, as its job began")
  }
}

/// Answers the image request in place of the network.
final class LeakStub: URLProtocol {
  static var handler: ((URLRequest) -> (Int, [String: String], Data))?
  static var request: URLRequest?
  static var body: Data?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var body = request.httpBody
    if body == nil, let stream = request.httpBodyStream {
      var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
      stream.open()
      while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
      }
      stream.close()
      body = data
    }
    Self.body = body
    let (status, headers, data) = Self.handler!(request)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
