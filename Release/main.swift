import CryptoKit
import Foundation

// release.sh's helper, built with Sources/UpdateFeed.swift so both read the feed the same way.
//   keygen KEYFILE                  makes the release key if there is none; prints its public half
//   notes CHANGELOG VERSION         prints the headings of that version's entries
//   check-key KEYFILE               fails unless the app's UpdateFeed.publicKey is this key's
//   publish KEYFILE FEED ARCHIVE VERSION BUILD MINIMUM COMMIT NOTES
//                                   signs ARCHIVE and adds it to FEED; never replaces a version

enum DeskError: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

func fail(_ text: String) -> Never {
  FileHandle.standardError.write(Data((text + "\n").utf8))
  exit(1)
}

func readKey(_ path: String) -> Curve25519.Signing.PrivateKey {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8),
    let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
    let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
  else { fail("no release key at \(path)") }
  return key
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: release-tool keygen|check-key|publish KEYFILE ...") }
let keyPath = args[2]
switch args[1] {
case "keygen":
  if !FileManager.default.fileExists(atPath: keyPath) {
    let dir = (keyPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: keyPath, contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
      attributes: [.posixPermissions: 0o600])
    else { fail("could not write \(keyPath)") }
  }
  print(readKey(keyPath).publicKey.rawRepresentation.base64EncodedString())
case "notes":
  // notes CHANGELOG VERSION: the headings of that version's entries, a line each.
  guard args.count == 4, let log = try? String(contentsOfFile: args[2], encoding: .utf8) else { fail("usage: release-tool notes CHANGELOG VERSION") }
  var inside = false
  for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
    if line.hasPrefix("## ") {
      inside = line == "## \(args[3])" || line.hasPrefix("## \(args[3]) ")
    } else if inside, line.hasPrefix("- **"), let end = line.dropFirst(4).range(of: "**") {
      var title = String(line.dropFirst(4)[..<end.lowerBound])
      while let last = title.last, "：:".contains(last) { title.removeLast() }
      print(title)
    }
  }
case "check-key":
  let own = readKey(keyPath).publicKey.rawRepresentation.base64EncodedString()
  guard own == UpdateFeed.publicKey else {
    fail("the app verifies updates with \(UpdateFeed.publicKey), not this key (\(own)): installed copies would refuse the release")
  }
case "check-feed", "publish":
  // check-feed KEYFILE FEED VERSION BUILD: fails unless VERSION (BUILD) may be published.
  let publishing = args[1] == "publish"
  guard args.count == (publishing ? 10 : 6) else {
    fail("usage: release-tool publish KEYFILE FEED ARCHIVE VERSION BUILD MINIMUM COMMIT NOTES | check-feed KEYFILE FEED VERSION BUILD")
  }
  let feedURL = URL(fileURLWithPath: args[3])
  let version = publishing ? args[5] : args[4]
  guard let build = Int(publishing ? args[6] : args[5]) else { fail("the build is not a number") }
  var feed = UpdateFeed(releases: [])
  if let data = try? Data(contentsOf: feedURL) {
    guard let read = try? JSONDecoder().decode(UpdateFeed.self, from: data) else { fail("\(feedURL.path) is not a feed") }
    feed = read
  }
  if let same = feed.releases.first(where: { $0.build == build || $0.version == version }) {
    fail("the feed already has \(same.version) (\(same.build)); a published version is never replaced: raise the version in Info.plist")
  }
  if let top = feed.releases.map(\.build).max(), build <= top { fail("build \(build) is not after the newest on the feed (\(top))") }
  guard publishing else { break }
  let key = readKey(keyPath)
  let archiveURL = URL(fileURLWithPath: args[4])
  let archive = try Data(contentsOf: archiveURL)
  let notes = (try String(contentsOfFile: args[9], encoding: .utf8)).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  var release = UpdateRelease(
    version: args[5], build: build, date: ISO8601DateFormatter().string(from: Date()),
    archive: archiveURL.lastPathComponent, size: archive.count, sha256: UpdateRelease.digest(archive), signature: "",
    minimumSystem: args[7], commit: args[8], notes: notes)
  release.signature = try key.signature(for: Data(release.signedText.utf8)).base64EncodedString()
  try release.verify(archive, key: key.publicKey)
  feed.releases.append(release)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try encoder.encode(feed).write(to: feedURL, options: .atomic)
  print("\(release.version) (\(release.build)) published: \(release.archive), \(release.size) bytes")
default:
  fail("unknown command \(args[1])")
}
