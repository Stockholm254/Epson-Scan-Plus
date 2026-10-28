import AppKit

enum ExportCommand {
  static func run() {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    func argument(_ key: String) -> String? {
      guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
      return args[i + 1]
    }
    guard let path = argument("--export-project"), let folder = argument("--output") else {
      fputs(
        "--export-project FILE --output DIRECTORY [--format tiff|tiff8|jpeg|png] [--color-space srgb|p3|adobe|prophoto] [--rotation 0|1|2|3]\n",
        stderr)
      exit(1)
    }
    let url = URL(fileURLWithPath: path)
    let model = AppModel(libraryURL: url.deletingLastPathComponent())
    model.readOnly = true
    model.loadProject(url)
    model.registerMissingLevels(wait: true)
    guard model.errorText == nil else {
      fputs("\(model.errorText!)\n", stderr)
      exit(1)
    }
    model.exportType = (argument("--format").flatMap(ExportFormat.init(rawValue:)) ?? .tiff).rawValue
    if let space = argument("--color-space") {
      guard let chosen = ExportColorSpace(rawValue: space) else {
        fputs("--color-space takes srgb, p3, adobe or prophoto\n", stderr)
        exit(1)
      }
      model.preferences.exportColorSpace = chosen
    }
    var items = model.frames.filter { $0.enabled && $0.hasFullResolution }
    if let r = argument("--rotation"), let value = Int(r) {
      for i in items.indices { items[i].adjustments.rotation = ((value % 4) + 4) % 4 }
    }
    if args.contains("--mirror") {
      for i in items.indices { items[i].adjustments.flipHorizontal = true }
    }
    guard !items.isEmpty else {
      fputs("No full-resolution frames\n", stderr)
      exit(1)
    }
    model.export(items: items, to: URL(fileURLWithPath: folder)) {
      CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    if let error = model.errorText {
      fputs("\(error)\n", stderr)
      exit(1)
    }
    print(model.status)
    exit(0)
  }
}
