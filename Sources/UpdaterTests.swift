import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Updating a copy in Applications: which version the feed offers, refusing an archive that is
/// not the one published, not signed with the release key or not this app, and putting the new
/// version in place once the app has ended, the old one kept.
enum UpdaterTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let root = folder.appendingPathComponent("updater", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let feedDir = root.appendingPathComponent("Releases", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    for dir in [applications, feedDir, support] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    /// A signed app bundle at `version` (`build`): a copy of /usr/bin/true with an Info.plist.
    func app(in dir: URL, version: String, build: Int, id: String = UpdateFeed.bundleID) throws -> URL {
      let app = dir.appendingPathComponent("Epson Scan plus.app")
      let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
      try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
      try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("EpsonScanPlus").path)
      let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "EpsonScanPlus", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version, "CFBundleVersion": String(build)]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
      try Updater.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
      return app
    }
    let key = Curve25519.Signing.PrivateKey(), stranger = Curve25519.Signing.PrivateKey()
    /// `app` zipped beside the feed, and its entry signed with `signer`.
    func publish(_ app: URL, version: String, build: Int, minimum: String = "26.0", signer: Curve25519.Signing.PrivateKey? = nil) throws -> UpdateRelease {
      let zip = feedDir.appendingPathComponent("Epson-Scan-plus-\(version)-\(build).zip")
      try Updater.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", app.path, zip.path])
      let data = try Data(contentsOf: zip)
      var r = UpdateRelease(version: version, build: build, date: "2026-11-03T12:00:00Z", archive: zip.lastPathComponent, size: data.count,
        sha256: UpdateRelease.digest(data), signature: "", minimumSystem: minimum, commit: "test", notes: ["第 \(build) 版"])
      r.signature = try (signer ?? key).signature(for: Data(r.signedText.utf8)).base64EncodedString()
      return r
    }
    let installed = try app(in: applications, version: "0.7.0", build: 25)
    let builds = root.appendingPathComponent("builds", isDirectory: true)
    func made(_ name: String) -> URL { builds.appendingPathComponent(name, isDirectory: true) }
    for name in ["26", "27", "28", "other"] { try FileManager.default.createDirectory(at: made(name), withIntermediateDirectories: true) }
    let next = try publish(try app(in: made("26"), version: "0.7.1", build: 26), version: "0.7.1", build: 26)
    let future = try publish(try app(in: made("27"), version: "0.8.0", build: 27, id: UpdateFeed.bundleID), version: "0.8.0", build: 27, minimum: "99.0")
    let older = try publish(try app(in: made("other"), version: "0.6.6", build: 24), version: "0.6.6", build: 24)
    let feed = UpdateFeed(releases: [older, next, future])
    let feedURL = feedDir.appendingPathComponent("appcast.json")
    try JSONEncoder().encode(feed).write(to: feedURL)
    let system = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)
    try check(feed.newest(after: 25, system: system) == next && feed.newest(after: 26, system: system) == nil
      && future.runs(on: OperatingSystemVersion(majorVersion: 99, minorVersion: 0, patchVersion: 0)) && !future.runs(on: system)
      && next.runs(on: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)),
      "the feed offers the newest version after this one that this system runs: 0.7.1 over 0.7.0, not 0.8.0, which needs macOS 99")

    let updater = Updater(bundle: installed, feed: feedURL, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), support: support)
    try check(updater.version == "0.7.0" && updater.build == 25 && (try updater.newest()) == next,
      "the copy reads its own version and finds 0.7.1 on the feed")
    let missing = Updater(bundle: installed, feed: feedDir.appendingPathComponent("none.json"), support: support)
    try check((try missing.newest()) == nil, "no feed on this computer yet is nothing new, not a failure")

    // What it refuses.
    func refusal(_ r: UpdateRelease) -> String? {
      do { _ = try updater.stage(r); return nil } catch { return error.localizedDescription }
    }
    var tampered = next
    tampered.sha256 = String(repeating: "0", count: 64)
    let unsigned = try publish(try app(in: made("28"), version: "0.7.2", build: 28), version: "0.7.2", build: 28, signer: stranger)
    let foreign = try publish(try app(in: made("other-id"), version: "0.7.3", build: 29, id: "com.example.other"), version: "0.7.3", build: 29)
    var mislabelled = next
    mislabelled.version = "0.7.9"
    mislabelled.signature = try key.signature(for: Data(mislabelled.signedText.utf8)).base64EncodedString()
    let refused = [tampered, unsigned, foreign, mislabelled].map(refusal)
    try check(refused[0]?.contains("校验值") == true && refused[1]?.contains("签名不对") == true
      && refused[2]?.contains("不是 Epson Scan plus") == true && refused[3]?.contains("版本") == true,
      "it refuses an archive changed after publishing, one signed with another key, another app, and a version that is not what the feed says")

    // Fetched, checked, and put in place once the app has ended.
    let staged = try updater.stage(next)
    try check(NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String == "26",
      "0.7.1 is fetched, its signature and code signature checked, and unpacked")
    let ended = Process()
    ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try ended.run()
    ended.waitUntilExit()
    // Waits for the installer to say how it ended.
    func finished(_ build: Int) {
      for _ in 0..<100 where updater.lastInstall?.build != build { Thread.sleep(forTimeInterval: 0.1) }
    }
    let parked = updater.parkedURL(version: updater.version, build: updater.build)
    try updater.launchInstaller(new: staged, build: 26, over: installed, parked: parked, relaunch: false, pid: ended.processIdentifier)
    finished(26)
    let now = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
    let kept = NSDictionary(contentsOf: parked.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
    try check(now == "26" && kept == "25" && parked.lastPathComponent == "Epson Scan plus 0.7.0 (25).app"
      && !FileManager.default.fileExists(atPath: staged.path)
      && (try? Updater.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", installed.path])) != nil,
      "once the app has ended, 0.7.1 is where 0.7.0 was, its signature whole, and 0.7.0 is kept by its version")
    try check(updater.parkedURL(version: "0.7.0", build: 25).lastPathComponent != parked.lastPathComponent,
      "a copy kept before is never replaced by the next one of that version")

    // A folder the installer may not change: the copy stays as it was, and the next launch says
    // why instead of fetching that version again at every quit.
    let locked = root.appendingPathComponent("Locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    let stuck = try app(in: locked, version: "0.7.0", build: 25)
    let again = try updater.stage(next)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    try FileManager.default.removeItem(at: updater.workRoot.appendingPathComponent("install-result"))
    try updater.launchInstaller(new: again, build: 26, over: stuck,
      parked: updater.parkedURL(version: "0.7.0", build: 25), relaunch: false, pid: ended.processIdentifier)
    finished(26)
    let stayed = NSDictionary(contentsOf: stuck.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
    let later = Updater(bundle: installed, feed: feedURL, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), support: support)
    later.offer(next, manual: false)
    let quiet = later.phase
    later.offer(next, manual: true)
    try check(stayed == "25" && updater.lastInstall?.failure?.contains("挪不开") == true
      && { if case .failed(let text) = quiet { return text.contains("上次没能换上 0.7.1") }; return false }()
      && later.phase == .available(next),
      "when the copy cannot be moved it stays as it was; the next launch says so and leaves that version until asked again")

    // Reopened after the swap even when the system first refuses, as it did right after the app
    // ended (-600): a stand-in for `open` that fails twice, then opens.
    let reopen = made("Reopen")
    let swapped = try app(in: reopen, version: "0.7.0", build: 25)
    let tries = reopen.appendingPathComponent("tries"), opened = reopen.appendingPathComponent("opened")
    let opener = reopen.appendingPathComponent("open.sh")
    try "#!/bin/bash\necho x >> \"\(tries.path)\"\n[ $(wc -l < \"\(tries.path)\") -ge 3 ] || exit 1\necho \"$1\" > \"\(opened.path)\"\n"
      .write(to: opener, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
    try updater.launchInstaller(new: try updater.stage(next), build: 26, over: swapped,
      parked: updater.parkedURL(version: "0.7.0", build: 25), relaunch: true, pid: ended.processIdentifier, opener: opener.path)
    for _ in 0..<80 where !FileManager.default.fileExists(atPath: opened.path) { Thread.sleep(forTimeInterval: 0.1) }
    let openedPath = (try? String(contentsOf: opened, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    let attempts = ((try? String(contentsOf: tries, encoding: .utf8)) ?? "").split(separator: "\n").count
    try check(openedPath == swapped.path && attempts == 3,
      "after the swap the new version is opened even if the first tries are refused (opened on try \(attempts))")

    // Only copies in Applications update; old kept copies past five go.
    let home = FileManager.default.homeDirectoryForCurrentUser
    try check(!Updater.updatesItself(home.appendingPathComponent("Documents/Epson-Scan-plus-试用/Epson Scan plus.app"))
      && !Updater.updatesItself(URL(fileURLWithPath: "/Volumes/Epson Scan plus/Epson Scan plus.app"))
      && Updater.onDiskImage(URL(fileURLWithPath: "/Volumes/Epson Scan plus/Epson Scan plus.app"))
      && Updater.updatesItself(URL(fileURLWithPath: "/Applications/Epson Scan plus.app")) == FileManager.default.isWritableFile(atPath: "/Applications"),
      "only a copy in Applications updates itself; a trial elsewhere or the disk image does not")
    for b in 30..<37 { _ = try app(in: made("kept-\(b)"), version: "0.9.\(b)", build: b) }
    let shelf = root.appendingPathComponent("shelf", isDirectory: true)
    try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
    for b in 30..<37 {
      try FileManager.default.moveItem(at: made("kept-\(b)").appendingPathComponent("Epson Scan plus.app"),
        to: shelf.appendingPathComponent("Epson Scan plus 0.9.\(b) (\(b)).app"))
    }
    var gone = [String]()
    Updater.prune(shelf, keep: 5) { gone.append($0.lastPathComponent) }
    try check(Set(gone) == ["Epson Scan plus 0.9.30 (30).app", "Epson Scan plus 0.9.31 (31).app"],
      "of seven kept copies the two oldest builds go, five stay")

    let sheet = NSHostingView(rootView: UpdateSheet(m: AppModel(libraryURL: root, preferences: Preferences()), updater: updater))
    sheet.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
    sheet.layoutSubtreeIfNeeded()
    try check(sheet.fittingSize.width >= 400 && sheet.fittingSize.height > 100, "the update window lays out")
  }
}
