import AppKit
import Foundation

enum SaneScannerTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let output = folder.appendingPathComponent("unused-capture.tiff")
    let bed = CGSize(width: 149.8599853515625, height: 246.37998962402344)
    let args = try SaneScannerController.captureArguments(rect: .full, dpi: 150, size: bed, output: output)
    try check(args[0] == "--scan" && args[1] == "150" && args[6] == "--output" && args[7] == output.path,
      "SANE capture arguments preserve paths without shell interpretation")
    for invalid in [NormalRect(x: -0.01, y: 0, width: 1, height: 1), NormalRect(x: 0, y: 0, width: .nan, height: 1),
      NormalRect(x: 0.9, y: 0, width: 0.2, height: 1)] {
      var rejected = false
      do { _ = try SaneScannerController.captureArguments(rect: invalid, dpi: 150, size: bed, output: output) }
      catch { rejected = true }
      try check(rejected, "SANE rejects unsafe or non-finite scan rectangle before device access")
    }
    var rejected = false
    do { _ = try SaneScannerController.captureArguments(rect: .full, dpi: 6400, size: bed, output: output) }
    catch { rejected = true }
    try check(rejected, "SANE rejects oversized whole-bed RGB48 allocation")
    // The bundled helper starts SANE and libusb on this system, with no scanner configured: built
    // against a newer SDK, a library can call a function this system does not have.
    let resources = Bundle.main.resourceURL!.appendingPathComponent("Scanner")
    if FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("SaneCapture").path) {
      let none = folder.appendingPathComponent("sane-no-devices")
      try FileManager.default.createDirectory(at: none, withIntermediateDirectories: true)
      try "# no devices\n".write(to: none.appendingPathComponent("epson2.conf"), atomically: true, encoding: .utf8)
      let p = Process()
      p.executableURL = resources.appendingPathComponent("SaneCapture")
      p.arguments = [resources.appendingPathComponent("libsane-epson2.1.dylib").path, none.path, "--probe"]
      p.standardOutput = FileHandle.nullDevice
      p.standardError = FileHandle.nullDevice
      try p.run()
      p.waitUntilExit()
      try check(p.terminationReason == .exit && p.terminationStatus != 0,
        "the bundled 48-bit helper starts SANE and libusb here and, with no scanner, says so instead of crashing")

      // The same helper finding no scanner as the app opens: no alert, the reason in the lamp's
      // tooltip; 「重新连接」 says it in an alert.
      let quietResources = folder.appendingPathComponent("sane-quiet-start", isDirectory: true)
      let quietScanner = quietResources.appendingPathComponent("Scanner", isDirectory: true)
      try? FileManager.default.removeItem(at: quietResources)
      try FileManager.default.createDirectory(at: quietScanner, withIntermediateDirectories: true)
      for name in ["SaneCapture", "libsane-epson2.1.dylib", "libusb-1.0.0.dylib"] {
        try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: quietScanner.appendingPathComponent(name))
      }
      try FileManager.default.copyItem(at: none, to: quietScanner.appendingPathComponent("config"))
      let absent = SaneScannerController(resources: quietResources)
      let opened = AppModel(libraryURL: folder.appendingPathComponent("sane-quiet-library"), scanner: absent)
      func settle(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while absent.busy && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
      }
      absent.start()
      settle(30)
      try check(!absent.busy && !absent.ready && opened.errorText == nil && absent.status.contains("没有找到"),
        "with no scanner on the cable, opening the app shows no alert; the lamp says 未就绪 and its tooltip why")
      absent.reconnect()
      settle(30)
      try check(!absent.busy && !absent.ready && opened.errorText?.contains("没有找到") == true,
        "and 重新连接 with still no scanner says so in an alert")
    }
    let scanner = SaneScannerController()
    let model = AppModel(libraryURL: folder.appendingPathComponent("sane-offline"), scanner: scanner)
    model.frames = [FilmFrame(name: "01", rect: NormalRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), format: "135")]
    model.selectedID = model.frames[0].id
    model.scanSelected()
    try check(model.errorText?.contains("重新预览") == true && !scanner.busy,
      "old ICA project cannot scan with a different backend's coordinates or film-base encoding")
    // Exercise missing-helper completion; this deliberately uses no real scanner.
    let missing = SaneScannerController(resources: folder.appendingPathComponent("missing-helper"))
    var message: String?
    missing.onFailure = { message = $0 }
    missing.start()
    try check(!missing.busy && !missing.ready && message == nil && missing.status.contains("无法启动"),
      "missing helper, as the app opens: not ready, said in the status, no alert")
    missing.reconnect()
    try check(!missing.busy && !missing.ready && message?.contains("无法启动") == true,
      "and on 重新连接 it fails clearly without claiming 48-bit readiness")
    let frame = FilmFrame(name: "01", rect: .full, format: "135")
    let p = DeskProject(overviewPath: output.path, overviewDPI: 150, physicalWidthMM: 149,
      physicalHeightMM: 246, filmName: "Portra 160", profile: FilmProfile.builtins[0], scanDPI: 2400,
      frames: [frame], scanBackendID: scanner.backendID, overviewInputGamma: 1)
    let decoded = try JSONDecoder().decode(DeskProject.self, from: JSONEncoder().encode(p))
    try check(decoded.scanBackendID == "epson2-linear-v1" && decoded.overviewInputGamma == 1,
      "project preserves scan backend and linear overview encoding")
    let temporary = folder.appendingPathComponent(UUID().uuidString + ".tiff")
    try FileManager.default.copyItem(at: folder.appendingPathComponent("high-precision-test.tif"), to: temporary)
    let preview = try SaneScannerController.loadDetachedPreview(temporary)
    try FileManager.default.removeItem(at: temporary)
    let png = folder.appendingPathComponent("detached-16bit-preview.png")
    try ImagePipeline.shared.savePNG(preview, to: png)
    let reopened = try ImagePipeline.shared.load(png)
    try check(reopened.bitsPerComponent == 16 && reopened.width == 1024,
      "48-bit preview pixels survive temporary TIFF deletion and PNG/project persistence")
  }
}
