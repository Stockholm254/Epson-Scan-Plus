import CryptoKit
import Foundation

/// The versions published for copies of the app to update to, as `release.sh` writes them and
/// `Updater` reads them: a JSON file with the zipped apps beside it.
struct UpdateFeed: Codable, Equatable {
  static let bundleID = "local.epscan.mac"
  /// The release key's public half. `release.sh` signs each version with the private half, kept
  /// outside the repository; a copy installs only what this key verifies.
  static let publicKey = "GCd1+8TENm8QxJNbT5s1MX4a0A0qRH/1xTydu7d47qM="
  var releases: [UpdateRelease]
  /// The newest version after `build` this system can run.
  func newest(after build: Int, system: OperatingSystemVersion) -> UpdateRelease? {
    releases.filter { $0.build > build && $0.runs(on: system) }.max { $0.build < $1.build }
  }
}

struct UpdateRelease: Codable, Equatable {
  var version: String
  var build: Int
  var date: String
  /// The zipped app: a name beside the feed, or a whole URL.
  var archive: String
  var size: Int
  /// SHA-256 of the archive, hex.
  var sha256: String
  /// Ed25519 over `signedText`, base64.
  var signature: String
  var minimumSystem: String
  var commit: String?
  /// What changed, a line each.
  var notes: [String]
  /// What the signature covers: which app, which version, its archive and the system it needs,
  /// so an old archive cannot be passed off as a newer version.
  var signedText: String { [UpdateFeed.bundleID, version, String(build), sha256, minimumSystem].joined(separator: "\n") }
  func runs(on system: OperatingSystemVersion) -> Bool {
    let need = minimumSystem.split(separator: ".").compactMap { Int($0) }
    let have = [system.majorVersion, system.minorVersion, system.patchVersion]
    for (n, h) in zip(need, have) where n != h { return h > n }
    return true
  }
  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  /// Throws unless `archive` is the one this release names and `key` signed it.
  func verify(_ archive: Data, key: Curve25519.Signing.PublicKey) throws {
    guard archive.count == size, Self.digest(archive) == sha256 else {
      throw DeskError.message("下载的更新包和发布时的不一样（大小或校验值不符）")
    }
    guard let sig = Data(base64Encoded: signature), key.isValidSignature(sig, for: Data(signedText.utf8)) else {
      throw DeskError.message("更新包的签名不对：不是用这个 App 的发布密钥签的")
    }
  }
}
