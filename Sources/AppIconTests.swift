import AppKit

/// The built app carries its icon: Info.plist names it, and the layered icon (Assets.car) and the
/// flat copy (AppIcon.icns) that Icon/build-icon.sh compiles are in the bundle.
enum AppIconTests {
  static func run() throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let bundle = Bundle.main
    let named = ["CFBundleIconFile", "CFBundleIconName"].allSatisfy { bundle.object(forInfoDictionaryKey: $0) as? String == "AppIcon" }
    let resources = bundle.resourceURL ?? bundle.bundleURL
    let layered = (try? Data(contentsOf: resources.appendingPathComponent("Assets.car")).count) ?? 0
    let flat = NSImage(contentsOf: resources.appendingPathComponent("AppIcon.icns"))
    let largest = flat?.representations.map(\.pixelsWide).max() ?? 0
    try check(named && layered > 100_000 && largest >= 256,
      "the app carries its icon: Info.plist names AppIcon, the layered icon and a flat copy up to \(largest) px are in the bundle")
  }
}
