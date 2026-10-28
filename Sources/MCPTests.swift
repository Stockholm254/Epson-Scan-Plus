import AppKit
import Foundation

/// An assistant over MCP: the tools on the model, and the whole path an assistant takes — this
/// app started with `--mcp`, over stdio, through the socket into the running app.
enum MCPTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let names = MCPTools.tools.map(\.name)
    try check(Set(names).count == names.count && names.count >= 14
      && MCPTools.definitions.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" }
      && !MCPTools.instructions.isEmpty && !Preferences().mcpEnabled,
      "\(names.count) tools are described for an assistant, and MCP is off until turned on")

    // A roll on the light table: one frame, warm orange base.
    let roll = folder.appendingPathComponent("mcp")
    try? FileManager.default.removeItem(at: roll)
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    let draw = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
      space: ImagePipeline.shared.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw.setFillColor(red: 0.85, green: 0.55, blue: 0.32, alpha: 1)
    draw.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
    for i in 0..<6 {
      draw.setFillColor(red: 0.6 - Double(i) * 0.07, green: 0.35 - Double(i) * 0.04, blue: 0.2 - Double(i) * 0.02, alpha: 1)
      draw.fill(CGRect(x: 120 + i * 60, y: 120, width: 60, height: 160))
    }
    let overviewURL = roll.appendingPathComponent("overview.png")
    try ImagePipeline.shared.savePNG(draw.makeImage()!, to: overviewURL)
    let frame = FilmFrame(name: "01", rect: NormalRect(x: 0.15, y: 0.2, width: 0.7, height: 0.6), format: "135")
    let project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: 150, physicalWidthMM: 101.6, physicalHeightMM: 67.7,
      filmName: "Kodak Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400, frames: [frame])
    let projectURL = roll.appendingPathComponent("Session.epscan")
    try JSONEncoder().encode(project).write(to: projectURL)
    let model = AppModel(libraryURL: roll)
    model.loadProject(projectURL)
    for _ in 0..<40 where model.rendering { settle(0.1) }
    model.select(model.frames[0].id)
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.undoManager = undo
    func call(_ name: String, _ arguments: [String: Any] = [:]) -> (content: [[String: Any]], isError: Bool) {
      MCPTools.call(name, arguments, model: model)
    }
    func json(_ r: (content: [[String: Any]], isError: Bool)) -> Any? {
      (r.content.first?["text"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }
    let state = json(call("get_state")) as? [String: Any]
    let base = (state?["film_base"] as? [String: Any])?["rgb"] as? [String: Double]
    try check((state?["preset"] as? [String: Any])?["name"] as? String == model.profile.name && (base?["r"] ?? 0) > (base?["b"] ?? 1)
      && state?["positive_srgb"] != nil && state?["negative_density_above_base"] != nil,
      "get_state reads the preset, the orange film base and where it came from, and the densities and the result")
    let samples = json(call("sample", ["points": [[0.5, 0.5], [0.05, 0.5]]])) as? [[String: Any]]
    let d = samples?.map { ($0["density_above_base"] as? [String: Double])?["g"] ?? -1 }
    try check(samples?.count == 2 && (d?[0] ?? 0) > (d?[1] ?? 1),
      "sample reads the negative's density above the base and the positive at each point")
    try check(!call("adjust", ["warmth": 0.3, "exposure": 0.25]).isError && model.settings.warmth == 0.3 && model.settings.exposure == 0.25,
      "adjust changes only what it is given")
    try check(!call("undo").isError && model.settings.warmth == 0 && model.settings.exposure == 0, "and undo takes it back, as ⌘Z does")
    try check(call("adjust", ["warmth": 0.3, "rotation": 1]).isError && model.settings.warmth == 0, "an unknown setting is refused, and nothing changes")
    let picked = call("pick_neutral", ["x": 0.5, "y": 0.5])
    try check(!picked.isError && model.settings.neutralSample != nil && model.settings.autoWhiteBalance,
      "pick_neutral white-balances on a point, auto white balance staying on")
    let pickedGrey = model.settings.neutralSample
    try check(!call("adjust", ["exposure": 0.1, "auto_white_balance": true]).isError && model.settings.neutralSample == pickedGrey,
      "asking for auto white balance when it is already on keeps the neutral pick")
    _ = call("undo")
    // On the generic preset auto goes on fitting each channel's contrast; the picked point still comes out grey.
    if let generic = FilmProfile.builtins.first(where: { $0.id == "generic" }) {
      model.chooseProfile(generic)
      for _ in 0..<40 where model.rendering { settle(0.1) }
      _ = call("pick_neutral", ["x": 0.5, "y": 0.5])
      let grey = ((json(call("sample", ["points": [[0.5, 0.5]]])) as? [[String: Any]])?.first?["positive_srgb"] as? [String: Double]) ?? [:]
      let values = ["r", "g", "b"].compactMap { grey[$0] }
      try check(values.count == 3 && values.max()! - values.min()! < 0.02 && model.settings.autoWhiteBalance,
        String(format: "and on the generic preset, still fitting each channel's contrast, the picked point comes out grey: %.3f %.3f %.3f",
          values.first ?? 0, values.count > 1 ? values[1] : 0, values.last ?? 0))
    }
    try check(!call("pick_film_base", ["x": 0.02, "y": 0.5]).isError && model.settings.base != nil, "pick_film_base takes the base from a point")
    try check(!call("auto_film_base").isError && model.settings.base == nil, "auto_film_base goes back to the measured base")
    try check(!call("choose_preset", ["name": "portra 400"]).isError && model.profile.name.contains("400"), "choose_preset finds a preset by part of its name")
    try check(call("select_frame", ["name": "99"]).isError && call("pick_neutral", ["x": 2, "y": 0]).isError, "a frame that is not there, or a point off the frame, says so")
    let preview = call("preview", ["max_size": 400])
    let jpeg = (preview.content.first?["data"] as? String).flatMap { Data(base64Encoded: $0) }
    let image = jpeg.flatMap { NSBitmapImageRep(data: $0) }
    try check(!preview.isError && preview.content.first?["mimeType"] as? String == "image/jpeg" && image.map { max($0.pixelsWide, $0.pixelsHigh) <= 400 } == true,
      "preview returns a JPEG of the positive at the size asked")

    // The whole way: this app started with --mcp, as an assistant starts it.
    let socket = NSTemporaryDirectory() + "epscan-mcp-\(getpid()).sock"
    let server = MCPServer(path: socket)
    server.model = model
    try server.start()
    var mode = stat()
    stat(socket, &mode)
    try check(mode.st_mode & 0o777 == 0o600, "the app's socket is for this user alone")
    let bridge = Process()
    bridge.executableURL = Bundle.main.executableURL
    bridge.arguments = ["--mcp"]
    bridge.environment = ProcessInfo.processInfo.environment.merging(["EPSCAN_MCP_SOCKET": socket]) { $1 }
    let input = Pipe(), output = Pipe()
    bridge.standardInput = input
    bridge.standardOutput = output
    bridge.standardError = FileHandle.nullDevice
    let lock = NSLock()
    var buffer = Data(), replies = [[String: Any]]()
    output.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      lock.withLock {
        buffer.append(chunk)
        while let end = buffer.firstIndex(of: 10) {
          if let m = try? JSONSerialization.jsonObject(with: buffer[buffer.startIndex..<end]) as? [String: Any] { replies.append(m) }
          buffer.removeSubrange(buffer.startIndex...end)
        }
      }
    }
    try bridge.run()
    func ask(_ message: [String: Any]) -> [String: Any]? {
      let id = message["id"]
      var data = try! JSONSerialization.data(withJSONObject: message.merging(["jsonrpc": "2.0"]) { $1 })
      data.append(10)
      input.fileHandleForWriting.write(data)
      guard let id = id as? Int else { return nil }
      let deadline = Date().addingTimeInterval(20)
      while Date() < deadline {
        if let found = lock.withLock({ replies.first { ($0["id"] as? Int) == id } }) { return found }
        settle(0.05)
      }
      return nil
    }
    let hello = ask(["id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "self-test", "version": "1"]]])
    _ = ask(["method": "notifications/initialized"])
    let listed = ask(["id": 2, "method": "tools/list"])
    try check((hello?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18"
      && ((listed?["result"] as? [String: Any])?["tools"] as? [Any])?.count == names.count,
      "started as an assistant starts it, the bridge answers the handshake and lists the tools")
    let remote = ask(["id": 3, "method": "tools/call", "params": ["name": "adjust", "arguments": ["tint": -0.2]]])
    try check((remote?["result"] as? [String: Any])?["isError"] as? Bool == false && model.settings.tint == -0.2,
      "a tool call goes through the socket into the running app")
    let unknown = ask(["id": 4, "method": "tools/call", "params": ["name": "delete_everything", "arguments": [String: Any]()]])
    try check((unknown?["error"] as? [String: Any])?["code"] as? Int == -32602, "a tool that does not exist is refused by the bridge")
    server.stop()
    let closed = ask(["id": 5, "method": "tools/call", "params": ["name": "get_state", "arguments": [String: Any]()]])
    let message = (((closed?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    try check((closed?["result"] as? [String: Any])?["isError"] as? Bool == true && message.contains("没有开启"),
      "with MCP turned off, a call says how to turn it on instead of failing the session")
    input.fileHandleForWriting.closeFile()
    for _ in 0..<40 where bridge.isRunning { settle(0.05) }
    output.fileHandleForReading.readabilityHandler = nil
    try check(!bridge.isRunning && bridge.terminationStatus == 0 && !FileManager.default.fileExists(atPath: socket),
      "the bridge ends with its input, and turning MCP off removes the socket")
  }
}
