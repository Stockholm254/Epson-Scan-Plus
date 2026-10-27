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
    try check(!missing.busy && !missing.ready && message != nil, "missing helper fails clearly without claiming 48-bit readiness")
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
