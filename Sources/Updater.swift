import AppKit
import CryptoKit
import Foundation

/// Keeps a copy in Applications up to date from the update feed. It looks at the feed a few
/// seconds after launch and every six hours; a newer version is fetched (on its own, unless that
/// is turned off), checked against the release key, its checksum and its code signature, and put
/// in place of this copy when the app quits, or at once with the app reopened. The copy replaced
/// is kept in `parkRoot`, the newest five. Copies elsewhere (trials, the disk image) never update.
final class Updater: ObservableObject {
  enum Phase: Equatable {
    case idle, checking
    case upToDate(Date)
    case available(UpdateRelease)
    case downloading(UpdateRelease)
    /// Fetched and checked: installs when the app quits.
    case ready(UpdateRelease)
    case installing(UpdateRelease)
    case failed(String)
  }
  /// Where this computer's releases go (`release.sh`), unless `Preferences.updateFeed` names another.
  static let localFeed = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("epscan/Releases/appcast.json")
  static let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("epscan")
  static let keptVersions = 5
  @Published private(set) var phase = Phase.idle
  let bundleURL: URL
  let version: String
  let build: Int
  let feedURL: URL
  /// Where fetched versions are unpacked and the installer keeps its log.
  let workRoot: URL
  /// Where the copies replaced are kept.
  let parkRoot: URL
  private let key: Curve25519.Signing.PublicKey?
  private let preferences: Preferences?
  private let queue = DispatchQueue(label: "epscan.update", qos: .utility)
  private var staged: URL?
  private var timer: Timer?
  private var launched = false

  init(bundle: URL = Bundle.main.bundleURL, feed: URL? = nil, preferences: Preferences? = nil,
    publicKey: String = UpdateFeed.publicKey, support: URL = Updater.supportRoot)
  {
    bundleURL = bundle.standardizedFileURL
    let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
    version = info["CFBundleShortVersionString"] as? String ?? "?"
    build = (info["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
    self.preferences = preferences
    feedURL = feed ?? preferences?.updateFeed.flatMap { URL(string: $0) } ?? Self.localFeed
    key = Data(base64Encoded: publicKey).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    workRoot = support.appendingPathComponent("Updates", isDirectory: true)
    parkRoot = support.appendingPathComponent("旧版", isDirectory: true)
  }

  /// Only a copy in Applications (the system's or the user's) that it may replace updates itself.
  static func updatesItself(_ bundle: URL) -> Bool {
    let parent = bundle.deletingLastPathComponent().standardizedFileURL.path
    let applications = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
    return applications.contains(parent) && FileManager.default.isWritableFile(atPath: parent)
  }
  static func onDiskImage(_ bundle: URL) -> Bool { bundle.standardizedFileURL.path.hasPrefix("/Volumes/") }
  var updatesItself: Bool { Self.updatesItself(bundleURL) }
  var automatic: Bool {
    get { preferences?.autoUpdate ?? false }
    set {
      objectWillChange.send()
      preferences?.autoUpdate = newValue
      if newValue, case .available(let r) = phase { prepare(r) }
    }
  }
  /// The version on offer, fetched or not.
  var release: UpdateRelease? {
    switch phase {
    case .available(let r), .downloading(let r), .ready(let r), .installing(let r): return r
    default: return nil
    }
  }
  var status: String {
    guard updatesItself else {
      return Self.onDiskImage(bundleURL)
        ? "从磁盘映像打开的，不会更新。拷到「应用程序」文件夹里再打开。"
        : "这一份在「\(bundleURL.deletingLastPathComponent().lastPathComponent)」里，不自动更新；放在「应用程序」里的才会。"
    }
    switch phase {
    case .idle: return "还没有检查"
    case .checking: return "正在检查…"
    case .upToDate(let d): return "已是最新 · \(d.formatted(date: .omitted, time: .shortened)) 检查过"
    case .available(let r): return "有新版本 \(r.version)（\(r.build)）"
    case .downloading(let r): return "正在下载 \(r.version)…"
    case .ready(let r): return "\(r.version) 已准备好，退出时更新"
    case .installing(let r): return "正在更新到 \(r.version)…"
    case .failed(let text): return "没能更新：\(text)"
    }
  }

  /// On launch: from the disk image, offers to copy the app into Applications; in Applications,
  /// clears what earlier updates unpacked, puts kept copies past five in the Trash and starts
  /// looking at the feed.
  func start() {
    if Self.onDiskImage(bundleURL) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.offerMoveToApplications() }
      return
    }
    guard updatesItself, timer == nil else { return }
    for dir in (try? FileManager.default.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      try? FileManager.default.removeItem(at: dir)
    }
    Self.prune(parkRoot, keep: Self.keptVersions) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.check() }
    timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
  }
  /// Not while it is looking, fetching or has a version waiting.
  var canCheck: Bool {
    switch phase {
    case .checking, .downloading, .ready, .installing: return false
    default: return true
    }
  }
  func check() {
    guard updatesItself, canCheck else { return }
    phase = .checking
    queue.async {
      let found = Result { try self.newest() }
      DispatchQueue.main.async {
        switch found {
        case .success(nil): self.phase = .upToDate(Date())
        case .success(let r?):
          self.phase = .available(r)
          if self.automatic { self.prepare(r) }
        case .failure(let error): self.phase = .failed(error.localizedDescription)
        }
      }
    }
  }
  /// The newest version on the feed after this one; none while nothing has been published.
  func newest() throws -> UpdateRelease? {
    if feedURL.isFileURL && !FileManager.default.fileExists(atPath: feedURL.path) { return nil }
    let data = try Self.load(feedURL)
    guard let feed = try? JSONDecoder().decode(UpdateFeed.self, from: data) else {
      throw DeskError.message("读不懂更新列表 \(feedURL.lastPathComponent)")
    }
    return feed.newest(after: build, system: ProcessInfo.processInfo.operatingSystemVersion)
  }
  func prepare(_ release: UpdateRelease) {
    phase = .downloading(release)
    queue.async {
      let result = Result { try self.stage(release) }
      DispatchQueue.main.async {
        switch result {
        case .success(let app):
          self.staged = app
          self.phase = .ready(release)
        case .failure(let error): self.phase = .failed(error.localizedDescription)
        }
      }
    }
  }
  /// Fetches `release`, checks it and unpacks it; returns the app, ready to put in place.
  func stage(_ release: UpdateRelease) throws -> URL {
    guard let key else { throw DeskError.message("这个 App 里没有发布公钥") }
    guard let url = URL(string: release.archive, relativeTo: feedURL)?.absoluteURL else {
      throw DeskError.message("更新包的地址不对：\(release.archive)")
    }
    let data = try Self.load(url)
    try release.verify(data, key: key)
    let dir = workRoot.appendingPathComponent(String(release.build), isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let zip = dir.appendingPathComponent("update.zip")
    try data.write(to: zip)
    try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
    try? FileManager.default.removeItem(at: zip)
    guard let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      .first(where: { $0.pathExtension == "app" })
    else { throw DeskError.message("更新包里没有 App") }
    try Self.check(app, as: release)
    return app
  }
  /// Throws unless `app` is this app, at `release`'s version, and its code signature is whole.
  static func check(_ app: URL, as release: UpdateRelease) throws {
    let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
    guard info["CFBundleIdentifier"] as? String == UpdateFeed.bundleID else {
      throw DeskError.message("更新包里的不是 Epson Scan plus（\(info["CFBundleIdentifier"] as? String ?? "没有标识")）")
    }
    guard info["CFBundleShortVersionString"] as? String == release.version,
      (info["CFBundleVersion"] as? String).flatMap(Int.init) == release.build
    else { throw DeskError.message("更新包里 App 的版本和更新列表上写的不一样") }
    do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) } catch {
      throw DeskError.message("更新包里 App 的代码签名不完整：\(error.localizedDescription)")
    }
  }
  /// Puts the fetched version in place once this process has ended, and opens it if `relaunch`.
  /// Quitting calls it without; the key to update now, with, and then quits.
  func install(relaunch: Bool) {
    guard !launched, let staged, case .ready(let release) = phase else { return }
    do {
      try launchInstaller(new: staged, over: bundleURL, parked: parkedURL(version: version, build: build), relaunch: relaunch)
      launched = true
      phase = .installing(release)
      if relaunch { NSApp.terminate(nil) }
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
  /// Where the copy replaced goes: named by its version, never over one kept before.
  func parkedURL(version: String, build: Int) -> URL {
    let name = "Epson Scan plus \(version) (\(build))"
    let plain = parkRoot.appendingPathComponent(name + ".app")
    guard FileManager.default.fileExists(atPath: plain.path) else { return plain }
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd HHmmss"
    return parkRoot.appendingPathComponent("\(name) \(stamp.string(from: Date())).app")
  }
  /// Waits, outside this process, for `pid` to end; moves `current` (if there is one) to
  /// `parked` and `new` to where it was, putting `current` back if that fails; opens it if
  /// `relaunch`. Writes what it did to `install.log` in `workRoot`.
  func launchInstaller(new: URL, over current: URL, parked: URL, relaunch: Bool, pid: Int32 = getpid()) throws {
    try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
    let script = workRoot.appendingPathComponent("install.sh")
    try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    // Started in the background and left, so it outlives this process.
    p.arguments = ["-c", "nohup /bin/bash \"$0\" \"$@\" >/dev/null 2>&1 &", script.path, String(pid), current.path, new.path,
      parked.path, relaunch ? "1" : "0", workRoot.appendingPathComponent("install.log").path]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw DeskError.message("没能启动安装") }
  }
  static let installScript = """
    #!/bin/bash
    pid="$1" current="$2" new="$3" parked="$4" relaunch="$5" log="$6"
    exec >>"$log" 2>&1
    while kill -0 "$pid" 2>/dev/null; do sleep 0.3; done
    echo "$(date '+%F %T') $new -> $current"
    if [ -e "$current" ]; then
      mkdir -p "$(dirname "$parked")"
      mv "$current" "$parked" || { echo "could not move $current aside"; exit 1; }
      echo "kept $parked"
    fi
    if ! mv "$new" "$current"; then
      echo "could not move the new version in; the old one goes back"
      [ -e "$parked" ] && mv "$parked" "$current"
      exit 1
    fi
    xattr -dr com.apple.quarantine "$current" 2>/dev/null
    echo "installed"
    if [ "$relaunch" = 1 ]; then open "$current"; fi
    """
  /// Opened from the disk image: offers to copy the app into Applications and open it there. A
  /// copy already there is kept in `parkRoot`, as an update keeps it.
  func offerMoveToApplications() {
    let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleURL.lastPathComponent)
    let old = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    let alert = NSAlert()
    alert.messageText = "把 Epson Scan plus 拷到「应用程序」文件夹？"
    alert.informativeText = "它现在是从磁盘映像打开的。拷到「应用程序」里以后从那里打开，以后会自动更新。"
      + (old.map { "「应用程序」里已有的 \($0["CFBundleShortVersionString"] as? String ?? "") 会移到 \(parkRoot.path)。" } ?? "")
    alert.addButton(withTitle: "拷过去并打开")
    alert.addButton(withTitle: "先不用")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      let dir = workRoot.appendingPathComponent("from-disk-image", isDirectory: true)
      try? FileManager.default.removeItem(at: dir)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let copy = dir.appendingPathComponent(bundleURL.lastPathComponent)
      try Self.run("/usr/bin/ditto", [bundleURL.path, copy.path])
      let parked = parkedURL(version: old?["CFBundleShortVersionString"] as? String ?? "?",
        build: (old?["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0)
      try launchInstaller(new: copy, over: target, parked: parked, relaunch: true)
      NSApp.terminate(nil)
    } catch {
      let failed = NSAlert()
      failed.messageText = "没能拷到「应用程序」"
      failed.informativeText = error.localizedDescription + "\n可以把磁盘映像里的 App 拖到「应用程序」文件夹。"
      failed.runModal()
    }
  }
  /// Puts away the kept copies in `root` past the newest `keep`, by their build.
  static func prune(_ root: URL, keep: Int, dispose: (URL) throws -> Void) {
    let apps = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    let builds = apps.filter { $0.pathExtension == "app" }.map { app in
      (app, (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0)
    }
    for (app, _) in builds.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? dispose(app) }
  }
  static func load(_ url: URL) throws -> Data {
    if url.isFileURL { return try Data(contentsOf: url) }
    var result: Result<Data, Error> = .failure(DeskError.message("没有回应"))
    let done = DispatchSemaphore(value: 0)
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    request.setValue("Epson Scan plus", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        result = .failure(error)
      } else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
        result = .failure(DeskError.message("\(url.lastPathComponent)：HTTP \(status)"))
      } else {
        result = .success(data ?? Data())
      }
      done.signal()
    }.resume()
    done.wait()
    return try result.get()
  }
  static func run(_ tool: String, _ arguments: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = arguments
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
      throw DeskError.message(text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "\(tool) 失败")
    }
  }
}
