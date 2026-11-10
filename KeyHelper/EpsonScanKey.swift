import CryptoKit
import Foundation
import Security

// EpsonScanKey: reads, saves and deletes Epson Scan plus's own Keychain item (the OpenAI key) for
// the app it ships in. The Keychain's 始终允许 is given to this program, not to the app: macOS
// remembers a program signed without a developer team by its own hash, every build of the app has
// a new one, and so each update asked for the login password again (twice). This program is built
// once and copied into every version unchanged (KeyHelper/build-key.sh), so its hash, and the
// Keychain's allowance, stay.
//
// It answers only the app: its caller must be signed as `local.epscan.mac` with the same
// certificate as this program.
//
//   EpsonScanKey read <service> <account> [keychain path]           the item's data on stdout
//   EpsonScanKey save <service> <account> <label> [keychain path]   the data from stdin
//   EpsonScanKey delete <service> <account> [keychain path]
//
// Exit 0 done; 2 no such item; 3 the caller is not the app; 4 usage; 1 the Keychain said no (its
// OSStatus on stderr).

func fail(_ code: Int32, _ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

/// This program's signing certificate, as the SHA-1 a code requirement names it by; nil when it is
/// signed ad hoc.
func ownLeaf() -> String? {
  var me: SecCode?
  guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
  var file: SecStaticCode?
  guard SecCodeCopyStaticCode(me, [], &file) == errSecSuccess, let file else { return nil }
  var info: CFDictionary?
  guard SecCodeCopySigningInformation(file, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
    let signing = info as? [String: Any], let chain = signing[kSecCodeInfoCertificates as String] as? [SecCertificate],
    let leaf = chain.first
  else { return nil }
  return Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
}

/// The process that started this one is the app: signed as it, by the same certificate.
func calledByTheApp() -> Bool {
  var caller: SecCode?
  guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: getppid())] as CFDictionary, [], &caller) == errSecSuccess,
    let caller
  else { return false }
  var text = "identifier \"local.epscan.mac\""
  if let leaf = ownLeaf() { text += " and certificate leaf = H\"\(leaf)\"" }
  var requirement: SecRequirement?
  guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
  return SecCodeCheckValidity(caller, [], requirement) == errSecSuccess
}

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first, ["read", "save", "delete"].contains(verb), args.count >= (verb == "save" ? 4 : 3) else {
  fail(4, "usage: EpsonScanKey read|delete <service> <account> [keychain] | save <service> <account> <label> [keychain]")
}
guard calledByTheApp() else { fail(3, "EpsonScanKey answers only Epson Scan plus") }
let service = args[1], account = args[2]
let path = args.count > (verb == "save" ? 4 : 3) ? args[verb == "save" ? 4 : 3] : nil
var keychain: SecKeychain?
if let path {
  guard SecKeychainOpen(path, &keychain) == errSecSuccess, keychain != nil else { fail(1, "\(errSecNoSuchKeychain)") }
}
var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
if let keychain { query[kSecMatchSearchList as String] = [keychain] }

switch verb {
case "read":
  var q = query
  q[kSecReturnData as String] = true
  q[kSecMatchLimit as String] = kSecMatchLimitOne
  var result: CFTypeRef?
  let status = SecItemCopyMatching(q as CFDictionary, &result)
  if status == errSecItemNotFound { exit(2) }
  guard status == errSecSuccess, let data = result as? Data else { fail(1, "\(status)") }
  FileHandle.standardOutput.write(data)
case "save":
  let data = FileHandle.standardInput.readDataToEndOfFile()
  let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: args[3]]
  var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  if status == errSecItemNotFound {
    var q = query
    q.removeValue(forKey: kSecMatchSearchList as String)
    if let keychain { q[kSecUseKeychain as String] = keychain }
    q.merge(attributes) { _, new in new }
    status = SecItemAdd(q as CFDictionary, nil)
  }
  guard status == errSecSuccess else { fail(1, "\(status)") }
default:
  let status = SecItemDelete(query as CFDictionary)
  if status == errSecItemNotFound { exit(2) }
  guard status == errSecSuccess else { fail(1, "\(status)") }
}
exit(0)
