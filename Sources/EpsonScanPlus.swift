import AppKit
import SwiftUI

@main
struct EpsonScanPlusApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model: AppModel
  init() {
    let args = CommandLine.arguments
    if args.contains("--self-test") { SmokeTests.run() }
    if args.contains("--hardware-test") { HardwareTest.run() }
    if args.contains("--sane-hardware-test") { HardwareTest.run(sane: true) }
    if args.contains("--export-project") { ExportCommand.run() }
    let preferences = Preferences(defaults: .standard)
    let library: URL
    if let i = args.firstIndex(of: "--library"), args.count > i + 1 {
      library = URL(fileURLWithPath: args[i + 1])
    } else {
      library = preferences.libraryURL
    }
    let scanner: ScannerController = args.contains("--ica") ? ScannerController() : SaneScannerController()
    _model = StateObject(
      wrappedValue: AppModel(libraryURL: library, scanner: scanner, preferences: preferences))
  }
  var body: some Scene {
    WindowGroup("Epson Scan plus") {
      ContentView(m: model).onAppear {
        delegate.model = model
        model.start()
        if let i = CommandLine.arguments.firstIndex(of: "--project"),
          CommandLine.arguments.count > i + 1
        {
          model.loadProject(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        } else if let i = CommandLine.arguments.firstIndex(of: "--image"),
          CommandLine.arguments.count > i + 1
        {
          model.importURLs([URL(fileURLWithPath: CommandLine.arguments[i + 1])])
        }
      }
    }.defaultSize(width: 1320, height: 900).commands {
      CommandGroup(replacing: .appSettings) {
        // Every setting is in the main window's left panel.
        Button("设置…") { model.panelTab = .scan }.keyboardShortcut(",")
      }
      CommandGroup(replacing: .newItem) {
        Button("导入图像…") { model.importImages() }.keyboardShortcut("o")
        Button("打开工程…") { model.openProject() }.keyboardShortcut(
          "o", modifiers: [.command, .shift])
      }
      CommandMenu("扫描") {
        Button("预览") { model.requestPreview() }.keyboardShortcut(
          "p", modifiers: [.command, .shift])
        Button("扫描当前画面") { model.scanSelected() }.keyboardShortcut(
          "s", modifiers: [.command, .shift])
        Button("扫描勾选画面") { model.scanEnabled() }
        Button("取消扫描") { model.cancel() }.keyboardShortcut(".")
      }
      CommandMenu("画面") {
        Button("接触表 / 单张") {
          model.singleView.toggle()
          model.refresh()
        }.keyboardShortcut("1")
        Button("放大镜") { model.tool = model.tool == .loupe ? .select : .loupe }.keyboardShortcut("l")
        Toggle(
          "灯箱上的看片镜",
          isOn: Binding(get: { model.preferences.showLoupe }, set: { model.preferences.showLoupe = $0 })
        ).keyboardShortcut("l", modifiers: [.command, .option])
        Picker(
          "看片镜型号", selection: Binding(get: { model.preferences.loupeStyle }, set: { model.preferences.loupeStyle = $0 })
        ) {
          ForEach(LoupeStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Button("顺时针旋转") { model.turn(clockwise: true) }.keyboardShortcut("r")
        Button("逆时针旋转") { model.turn(clockwise: false) }.keyboardShortcut(
          "r", modifiers: [.command, .shift])
        Button("水平镜像") { model.toggleMirror() }
        Toggle("旋转 / 镜像同步到全部照片", isOn: $model.syncOrientation)
        Divider()
        Button("导出当前…") { model.exportImages(all: false) }.keyboardShortcut("e")
        Button("导出勾选画面…") { model.exportImages(all: true) }.keyboardShortcut(
          "e", modifiers: [.command, .shift])
        Button("导出接触表…") { model.exportContactSheet() }.keyboardShortcut(
          "e", modifiers: [.command, .option])
      }
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Cancel this quit and quit again once the helper is done. A deferred reply would wait in
    // AppKit's modal loop, which cannot run main-queue work when the quit came from main-queue code.
    let waiting = model?.finishScanBeforeQuit { sender.terminate(nil) } ?? false
    return waiting ? .terminateCancel : .terminateNow
  }
  func applicationWillTerminate(_ notification: Notification) {
    model?.saveProject()
    model?.scanner.close()
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
