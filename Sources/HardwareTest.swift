import AppKit
import Foundation

/// Explicit opt-in integration test. Never runs during normal app launch.
enum HardwareTest {
  static func run(sane: Bool = false) {
    _ = NSApplication.shared
    guard let index = CommandLine.arguments.firstIndex(of: "--library"),
      index + 1 < CommandLine.arguments.count
    else {
      fputs("--hardware-test requires --library PATH\n", stderr)
      exit(1)
    }
    let scanner: ScannerController = sane ? SaneScannerController() : ScannerController()
    // The SANE test runs with saved settings at their defaults, in a suite of its own and removed
    // afterwards, so it also covers the positives exported when the batch ends.
    let suite = "local.filmdesk.mac.hardware-test"
    let defaults = sane ? UserDefaults(suiteName: suite) : nil
    defaults?.removePersistentDomain(forName: suite)
    let model = AppModel(
      libraryURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]), scanner: scanner,
      preferences: Preferences(defaults: defaults))
    func automaticExport(_ session: URL) -> URL? {
      (try? FileManager.default.contentsOfDirectory(
        at: session.appendingPathComponent("Exports"), includingPropertiesForKeys: nil))?
        .first { $0.pathExtension == "tif" }
    }
    var stage = 0
    var done = false
    var success = false
    let started = Date()
    var exported: URL?
    let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
      if done { return }
      if let error = model.errorText {
        fputs("HARDWARE TEST FAILED: \(error)\n", stderr)
        done = true
        model.cancel()
        model.scanner.close()
        CFRunLoopStop(CFRunLoopGetMain())
        return
      }
      if Date().timeIntervalSince(started) > 600 {
        fputs("HARDWARE TEST TIMEOUT\n", stderr)
        done = true
        model.cancel()
        model.scanner.close()
        CFRunLoopStop(CFRunLoopGetMain())
        return
      }
      if stage == 0 && model.scanner.ready {
        stage = 1
        model.requestPreview()
      } else if stage == 1 && !model.scanner.busy && !model.rendering && !model.frames.isEmpty {
        print("DETECTED \(model.frames.count) frames")
        let index = min(8, model.frames.count - 1)
        model.select(model.frames[index].id)
        model.singleView = true
        model.dpi = 2400
        model.change { $0.rotation = 1 }
        stage = 2
        model.scanSelected()
      } else if stage == 2 && !model.isWorking, let frame = model.selected,
        let path = frame.scanPath, let session = model.sessionURL,
        !sane || automaticExport(session) != nil
      {
        stage = 3
        let info = ImagePipeline.shared.info(URL(fileURLWithPath: path))
        print("RAW \(info.width)×\(info.height) / \(info.bits) bit/channel / \(info.dpi) dpi")
        // Kept apart from the positives exported on their own.
        exported = session.appendingPathComponent("Exports-check")
        model.exportType = "tiff"
        model.export(items: [frame], to: exported!) {
          guard model.errorText == nil else { return }
          model.exportType = "jpeg"
          model.export(items: [frame], to: exported!) { stage = 4 }
        }
      } else if stage == 4 && !model.exporting {
        do {
          guard let frame = model.selected, let path = frame.scanPath,
            let session = model.sessionURL, let exported
          else { throw DeskError.message("Missing scan result") }
          let raw = ImagePipeline.shared.info(URL(fileURLWithPath: path))
          let files = try FileManager.default.contentsOfDirectory(
            at: exported, includingPropertiesForKeys: nil)
          guard let tif = files.first(where: { $0.pathExtension == "tif" }),
            let jpg = files.first(where: { $0.pathExtension == "jpg" })
          else { throw DeskError.message("Missing exports") }
          let ti = ImagePipeline.shared.info(tif)
          let ji = ImagePipeline.shared.info(jpg)
          let cropSize = frame.rect.relative(to: frame.captureRect).pixels(CGSize(width: raw.width, height: raw.height)).size
          guard raw.width > 1800, raw.height > 2800, ti.bits == 16, ti.width == Int(cropSize.height),
            ti.height == Int(cropSize.width),
            ji.width == ti.width
          else { throw DeskError.message("Unexpected export dimensions/depth") }
          var precision = ""
          if sane {
            // Any film in the holder: how many frames it holds is reported, not required.
            guard raw.bits == 16, frame.adjustments.inputGamma == 1,
              frame.captureRect.contains(frame.rect), model.singleView,
              !model.frames.isEmpty, model.scanBatch.completed == 1
            else { throw DeskError.message("RGB48/gamma/coverage/batch verification failed") }
            let image = try ImagePipeline.shared.load(URL(fileURLWithPath: path))
            let data = image.dataProvider!.data! as Data
            let step = image.bitsPerPixel / 8
            let little = image.bitmapInfo.contains(.byteOrder16Little)
            var values = [Set<UInt16>(), Set<UInt16>(), Set<UInt16>()]
            for y in stride(from: 0, to: image.height, by: 3) {
              for x in stride(from: 0, to: image.width, by: 3) {
                for c in 0..<3 {
                  let i = y * image.bytesPerRow + x * step + c * 2
                  let v = little ? UInt16(data[i]) | UInt16(data[i+1]) << 8 : UInt16(data[i]) << 8 | UInt16(data[i+1])
                  values[c].insert(v)
                }
              }
            }
            guard values.allSatisfy({ $0.count > 1024 && $0.contains { $0 % 257 != 0 } }) else {
              throw DeskError.message("RGB48 samples do not demonstrate higher than 8-bit precision")
            }
            precision = "Distinct sampled R/G/B values: \(values.map(\.count))\nInput gamma: 1.0, identity hardware LUT\nActual footprint contains crop: yes\n"
            // Reported, not required: the film in the holder decides how much the roll shows.
            precision += frame.adjustments.rollSlopes.map {
              String(format: "Roll estimate: R %.3f · G %.3f · B %.3f\n", $0.r, $0.g, $0.b)
            } ?? "Roll estimate: none\n"
            guard let automatic = automaticExport(session) else { throw DeskError.message("No positive was exported when the batch ended") }
            let ai = ImagePipeline.shared.info(automatic)
            guard ai.bits == 16, ai.width == ti.width, ai.height == ti.height else {
              throw DeskError.message("The positive exported when the batch ended has the wrong size or depth")
            }
            precision += "Exported when the batch ended: \(automatic.lastPathComponent), \(ai.width) × \(ai.height), \(ai.bits)-bit/channel\n"
          }
          let report =
            "Epson Scan plus hardware integration test\nDate: \(Date())\nScanner: \(model.scanner.name)\nBackend: \(model.scanner.backendID)\nAcquisition: \(raw.bits*3)-bit RGB\n\(precision)Frames detected: \(model.frames.count)\nScan: frame \(frame.name), 2400 dpi, \(raw.width) × \(raw.height)\nTIFF: \(ti.width) × \(ti.height), \(ti.bits)-bit/channel\nJPEG: \(ji.width) × \(ji.height), \(ji.bits)-bit/channel\nDust removal: disabled\nRaw: \(path)\nTIFF: \(tif.path)\nJPEG: \(jpg.path)\nRESULT: PASS\n"
          try report.write(
            to: session.appendingPathComponent("Hardware-test.txt"), atomically: true,
            encoding: .utf8)
          print(report)
          success = true
        } catch { fputs("\(error.localizedDescription)\n", stderr) }
        done = true
        model.scanner.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { CFRunLoopStop(CFRunLoopGetMain()) }
      }
    }
    model.start()
    CFRunLoopRun()
    timer.invalidate()
    defaults?.removePersistentDomain(forName: suite)
    withExtendedLifetime(model) {}
    exit(success ? 0 : 1)
  }
}
