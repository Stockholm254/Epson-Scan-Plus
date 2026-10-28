import AppKit
import Darwin
import Foundation

/// Where the app and its MCP bridge meet: a socket only this user can open, in the app's support
/// folder. `EPSCAN_MCP_SOCKET` moves it, for tests.
enum MCPSocket {
  static var path: String {
    if let p = ProcessInfo.processInfo.environment["EPSCAN_MCP_SOCKET"], !p.isEmpty { return p }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("epscan").appendingPathComponent("mcp.sock").path
  }
  static func address(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    return address
  }
  static func connect(_ path: String) -> LineChannel? {
    guard var address = address(path) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
      close(fd)
      return nil
    }
    return LineChannel(fd)
  }
}

/// One JSON object a line, each way, over a socket or a pipe.
final class LineChannel {
  let fd: Int32
  private var buffer = Data()
  init(_ fd: Int32) {
    self.fd = fd
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  }
  func readObject() -> [String: Any]? {
    while true {
      if let end = buffer.firstIndex(of: 10) {
        let line = buffer[buffer.startIndex..<end]
        buffer.removeSubrange(buffer.startIndex...end)
        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return object }
        continue
      }
      var chunk = [UInt8](repeating: 0, count: 65536)
      let n = read(fd, &chunk, chunk.count)
      guard n > 0 else { return nil }
      buffer.append(contentsOf: chunk[0..<n])
    }
  }
  @discardableResult func write(_ object: [String: Any]) -> Bool {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
    data.append(10)
    return data.withUnsafeBytes { raw -> Bool in
      var sent = 0
      while sent < raw.count {
        let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
        guard n > 0 else { return false }
        sent += n
      }
      return true
    }
  }
}

/// The app's end. While turned on it takes tool calls from the bridge, one line each, and runs them
/// on the model; turning it off closes every connection.
final class MCPServer {
  let path: String
  weak var model: AppModel?
  /// After each call, with the tool's name.
  var onCall: ((String) -> Void)?
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var clients = Set<Int32>()
  var running: Bool { lock.withLock { listener >= 0 } }
  init(path: String = MCPSocket.path) { self.path = path }

  func start() throws {
    guard !running else { return }
    let folder = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    unlink(path)
    guard var address = MCPSocket.address(path) else { throw DeskError.message("MCP 连接路径过长。") }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DeskError.message("无法建立 MCP 连接。") }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    // Only this user may connect: the socket is theirs alone, in a folder that is theirs alone.
    guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
      close(fd)
      throw DeskError.message("无法建立 MCP 连接：\(String(cString: strerror(errno)))")
    }
    lock.withLock { listener = fd }
    Thread.detachNewThread { [weak self] in self?.accept(on: fd) }
  }
  func stop() {
    let (fd, open) = lock.withLock { () -> (Int32, Set<Int32>) in
      defer { listener = -1; clients = [] }
      return (listener, clients)
    }
    guard fd >= 0 else { return }
    for c in open { shutdown(c, SHUT_RDWR) }
    close(fd)
    unlink(path)
  }
  private func accept(on fd: Int32) {
    while true {
      let client = Darwin.accept(fd, nil, nil)
      guard client >= 0 else { return }
      lock.withLock { _ = clients.insert(client) }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(LineChannel(client)) }
    }
  }
  private func serve(_ channel: LineChannel) {
    defer {
      lock.withLock { _ = clients.remove(channel.fd) }
      close(channel.fd)
    }
    while let request = channel.readObject() {
      let name = request["name"] as? String ?? ""
      let result: (content: [[String: Any]], isError: Bool)
      if let model {
        result = MCPTools.call(name, request["arguments"] as? [String: Any] ?? [:], model: model)
      } else {
        result = ([["type": "text", "text": "错误：App 正在关闭。"]], true)
      }
      onCall?(name)
      guard channel.write(["id": request["id"] ?? NSNull(), "content": result.content, "isError": result.isError]) else { return }
    }
  }
}

/// `EpsonScanPlus --mcp`: the MCP server an assistant starts, over stdio. It answers the handshake
/// and the list of tools itself, and passes each tool call to the running app; with the app closed
/// or MCP off, the call says so instead of failing the session.
enum MCPBridge {
  static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

  static func run() -> Never {
    NSApplication.shared.setActivationPolicy(.prohibited)
    signal(SIGPIPE, SIG_IGN)
    let out = FileHandle.standardOutput
    func send(_ object: [String: Any]) {
      guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
      data.append(10)
      out.write(data)
    }
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    var app: LineChannel?
    var sequence = 0
    /// The app's answer, over the open connection or, once, over a new one (the app may have restarted).
    func forward(_ name: String, _ arguments: [String: Any]) -> [String: Any]? {
      for _ in 0..<2 {
        if app == nil { app = MCPSocket.connect(MCPSocket.path) }
        guard let channel = app else { return nil }
        sequence += 1
        if channel.write(["id": sequence, "name": name, "arguments": arguments]), let answer = channel.readObject() { return answer }
        close(channel.fd)
        app = nil
      }
      return nil
    }
    while let line = readLine(strippingNewline: true) {
      guard !line.isEmpty else { continue }
      guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        continue
      }
      // Notifications (initialized, cancelled) need no answer.
      guard let id = message["id"], let method = message["method"] as? String else { continue }
      let params = message["params"] as? [String: Any] ?? [:]
      func reply(_ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
      func fail(_ code: Int, _ text: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]) }
      switch method {
      case "initialize":
        let asked = params["protocolVersion"] as? String
        reply([
          "protocolVersion": asked.flatMap { protocolVersions.contains($0) ? $0 : nil } ?? protocolVersions[0],
          "capabilities": ["tools": ["listChanged": false]],
          "serverInfo": ["name": "epscan", "title": "Epson Scan plus", "version": version],
          "instructions": MCPTools.instructions,
        ])
      case "ping":
        reply([:])
      case "tools/list":
        reply(["tools": MCPTools.definitions])
      case "tools/call":
        let name = params["name"] as? String ?? ""
        guard MCPTools.tools.contains(where: { $0.name == name }) else { fail(-32602, "Unknown tool: \(name)"); continue }
        if let answer = forward(name, params["arguments"] as? [String: Any] ?? [:]) {
          reply(["content": answer["content"] ?? [], "isError": answer["isError"] ?? false])
        } else {
          reply(["content": [["type": "text", "text": "Epson Scan plus 没有在运行，或没有开启 AI 助手（「胶片」页 →「AI 助手 · MCP」）。请先打开 App 并开启后再试。"]], "isError": true])
        }
      default:
        fail(-32601, "Method not found: \(method)")
      }
    }
    exit(0)
  }
}
