// Opt-in hardware test: scan only a 10 × 10 mm patch, cancel after start, then probe.
// Usage: xcrun swift test-cancellation.swift /path/to/Scanner /new/test/output.tiff
import Foundation
setbuf(stdout, nil)
let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("Requires Scanner resources path and a NEW TIFF output path") }
let resources = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Output must not exist") }
func helper(_ args: [String]) -> Process {
  let p = Process()
  p.executableURL = resources.appendingPathComponent("SaneCapture")
  p.arguments = [resources.appendingPathComponent("libsane-epson2.1.dylib").path,
    resources.appendingPathComponent("config").path] + args
  return p
}
let p = helper(["--scan", "1200", "16", "14", "10", "10", "--output", output.path])
let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
try p.run()
var pending = Data(), cancelled = false, sawCancellation = false
while true {
  let data = pipe.fileHandleForReading.availableData
  if data.isEmpty { break }
  pending.append(data)
  while let end = pending.firstIndex(of: 10) {
    let line = Data(pending[..<end]); pending.removeSubrange(...end)
    print(String(data: line, encoding: .utf8) ?? "")
    if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
      if value["event"] as? String == "parameters", !cancelled, p.isRunning {
        p.interrupt(); cancelled = true
      }
      if value["event"] as? String == "error", value["cancelled"] as? Bool == true { sawCancellation = true }
    }
  }
}
p.waitUntilExit()
guard cancelled, sawCancellation, p.terminationStatus == 130,
  !FileManager.default.fileExists(atPath: output.path)
else { fatalError("FAIL: cancellation did not preserve clean output state") }
let probe = helper(["--probe"]), probePipe = Pipe()
probe.standardOutput = probePipe; probe.standardError = probePipe
try probe.run()
let response = probePipe.fileHandleForReading.readDataToEndOfFile()
probe.waitUntilExit()
guard probe.terminationStatus == 0,
  String(data: response, encoding: .utf8)?.contains("capabilities") == true
else { fputs("FAIL: scanner not available after cancellation\n", stderr); exit(1) }
print("PASS: cancellation drains the current transfer; no TIFF published; scanner reconnects with RGB48")
