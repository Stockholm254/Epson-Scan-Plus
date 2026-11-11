import AppKit
import SwiftUI

@main
struct EpsonScanPlusApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model: AppModel
  init() {
    let args = CommandLine.arguments
    // Started by an assistant: a stdio MCP server that talks to the running app, never a window.
    if args.contains("--mcp") { MCPBridge.run() }
    // No window restoration, here or in the self-test and the other runs below (this app too, by
    // bundle id). A self-test's windows, left saved since it ends in exit(), were what the next
    // launch restored: nothing, and no window opened until the Dock icon was clicked again. The
    // one window is made fresh each launch (restoration never brought back a project); its frame
    // comes back from its autosave.
    var defaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults["ApplePersistence"] = false
    UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)
    // The camera's pixel shift read or set over PTP, in a process of its own (SonyPTP.inChild).
    if args.contains("--sony-ptp") { SonyPTP.runChild() }
    // The camera driven over its own PTP instead of Sony's SDK, in a process of its own.
    if args.contains("--sony-ptp-camera") { SonyPTPCamera.runProcess() }
    if args.contains("--self-test") { SmokeTests.run() }
    if args.contains("--sane-hardware-test") { HardwareTest.run() }
    if args.contains("--export-project") { ExportCommand.run() }
    Preferences.migrate(into: .standard)
    let preferences = Preferences(defaults: .standard)
    let library: URL
    if let i = args.firstIndex(of: "--library"), args.count > i + 1 {
      library = URL(fileURLWithPath: args[i + 1])
    } else {
      library = preferences.libraryURL
    }
    _model = StateObject(
      wrappedValue: AppModel(libraryURL: library, scanner: SaneScannerController(), preferences: preferences))
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
          // Opened from the command line as from the library: on to taking the mask off.
          if model.sessionURL != nil { model.page = .convert }
        } else if let i = CommandLine.arguments.firstIndex(of: "--image"),
          CommandLine.arguments.count > i + 1
        {
          // As from the library: on to ② once it is a roll.
          model.importChosen([URL(fileURLWithPath: CommandLine.arguments[i + 1])])
        }
      }
    }.defaultSize(width: 1320, height: 900).commands {
      CommandGroup(replacing: .appSettings) {
        // The scanner's and the camera's settings, in module ①'s left panel, opened if put away.
        // They are in ①'s panel, open once a project is (`AppModel.hasProject`).
        Button("设置…") {
          model.page = .capture
          model.settingsRequests += 1
        }.keyboardShortcut(",").disabled(!model.hasProject)
      }
      // No help book: the Help menu holds the keys.
      CommandGroup(replacing: .help) {
        Button("键盘快捷键") { model.showShortcuts = true }.keyboardShortcut("/")
      }
      CommandGroup(after: .appInfo) {
        Button("检查更新…") {
          model.showUpdates = true
          model.updater.check(manual: true)
        }
      }
      CommandGroup(replacing: .newItem) {
        Button("新建工程…") { model.askNewProject() }.keyboardShortcut("n").disabled(model.isWorking)
        // On ③, the positive to repair, as its own key has it.
        Button(model.page == .leak ? "导入正片…" : "导入图像…") {
          if model.page == .leak { model.leak.chooseFile() } else { model.importImages() }
        }.keyboardShortcut("o")
        Button("打开工程…") { model.openProject() }.keyboardShortcut(
          "o", modifiers: [.command, .shift])
      }
      CommandMenu("扫描") {
        // Only what the scanner can do now: ready, idle, and frames of the preview to scan.
        // A preview needs a project to go into; scanning frames, a page with the roll's frames.
        Button("预览") { model.requestPreview() }.keyboardShortcut(
          "p", modifiers: [.command, .shift]).disabled(!model.scanner.ready || model.isWorking || !model.hasProject)
        Button("扫描当前画面") { model.requestScanSelected() }.keyboardShortcut(
          "s", modifiers: [.command, .shift])
          .disabled(!model.scanner.ready || model.isWorking || model.selected == nil || model.selected?.sourcePath != nil || model.page == .library)
        Button("扫描勾选画面") { model.requestScanEnabled() }
          .disabled(!model.scanner.ready || model.isWorking || !model.hasScanTargets || model.page == .library)
        Button("取消扫描") { model.cancel() }.keyboardShortcut(".")
          .disabled(!model.scanner.busy && !model.scanBatch.isActive && model.scanQueue.isEmpty)
      }
      CommandMenu("模块") {
        // The library always; the modules once a project is new, opened or imported.
        Button(AppModel.Page.library.title) { model.page = .library }.keyboardShortcut("l", modifiers: [.command, .shift])
        ForEach(AppModel.Page.allCases.filter { $0 != .library }, id: \.self) { page in
          Button(page.title) { model.page = page }
            .keyboardShortcut(KeyEquivalent(Character("\(AppModel.Page.allCases.firstIndex(of: page)!)")), modifiers: [.command, .option])
            .disabled(!model.hasProject)
        }
        Divider()
        Button("管理预设…") { model.showPresets = true }
      }
      CommandMenu("画面") {
        Button("接触表 / 单张") {
          // From the live view, to the pictures taken as they were last looked at.
          if model.liveViewShown { model.reviewingShots = true } else { model.showSingle(!model.singleView) }
        }.keyboardShortcut("1").disabled(model.previewShowing && !model.singleView || !model.onRollModule)
        Toggle("看片镜", isOn: Binding(get: { model.preferences.showLoupe }, set: { model.toggleLoupe($0) }))
          .keyboardShortcut("l")
        // As the toolbar's key: the dust found ringed on the single view.
        Toggle("除尘标出", isOn: $model.showDust).keyboardShortcut("d", modifiers: [.command, .shift])
        Picker(
          "看片镜型号", selection: Binding(get: { model.preferences.loupeStyle }, set: { model.preferences.loupeStyle = $0 })
        ) {
          ForEach(LoupeStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker(
          "看片镜视场", selection: Binding(get: { model.preferences.loupeField }, set: { model.preferences.loupeField = $0 })
        ) {
          ForEach(LoupeField.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        // As the keys under the picture: the frame (or with it the roll, synced) in the single view,
        // the whole roll on the light table. ③ turns its own picture.
        Button("顺时针旋转") { model.singleView ? model.turn(clockwise: true) : model.turnRoll(clockwise: true) }
          .keyboardShortcut("r").disabled(model.frames.isEmpty || !model.onRollModule)
        Button("逆时针旋转") { model.singleView ? model.turn(clockwise: false) : model.turnRoll(clockwise: false) }
          .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.frames.isEmpty || !model.onRollModule)
        Button("水平镜像") { model.singleView ? model.toggleMirror() : model.mirrorRoll() }
          .disabled(model.frames.isEmpty || !model.onRollModule)
        // The wand by the title: ②'s, as the capture page shows the raw reading.
        Button("自动调整") { model.autoAdjust() }.keyboardShortcut("a", modifiers: [.command, .shift])
          .disabled(model.selected == nil || model.isWorking || model.page != .convert)
        Button("在去漏光里打开") { if let id = model.selectedID { model.openInLeak(id) } }
          .keyboardShortcut("l", modifiers: [.command, .option]).disabled(model.selected == nil || !model.onRollModule)
        Toggle("整卷一起转", isOn: $model.syncOrientation)
        Divider()
        // Lightroom's: one frame's settings given to others, chosen now or later.
        Button("拷贝调整") { model.copySettings() }.keyboardShortcut("c", modifiers: [.command, .shift])
          .disabled(model.selected == nil || model.page != .convert)
        Button(model.multiSelected ? "粘贴调整到所选的 \(model.selection.count) 张" : "粘贴调整") { model.pasteSettings() }
          .keyboardShortcut("v", modifiers: [.command, .shift])
          .disabled(model.copiedSettings == nil || model.selected == nil || model.isWorking || model.page != .convert)
        Divider()
        // Which frames a batch scans and exports; on the light table's strip as well, by its menu.
        // ③ exports on its own, so its page ticks nothing.
        // With several chosen (⌘ or ⇧ on the strip or the light table), all of them.
        if model.multiSelected {
          Button(model.selectionEnabled ? "取消勾选所选的 \(model.selection.count) 张" : "勾选所选的 \(model.selection.count) 张") {
            model.setSelectionEnabled(!model.selectionEnabled)
          }.disabled(model.isWorking || !model.onRollModule)
        } else {
          Button(model.selected?.enabled == true ? "取消勾选当前画面" : "勾选当前画面") {
            if let id = model.selectedID { model.setEnabled(id, enabled: model.selected?.enabled != true) }
          }.disabled(model.selected == nil || model.isWorking || !model.onRollModule)
        }
        Button("全部勾选") { model.setAllEnabled(true) }.disabled(model.frames.isEmpty || model.isWorking || !model.onRollModule)
        Button("全部不勾选") { model.setAllEnabled(false) }.disabled(model.enabledCount == 0 || model.isWorking || !model.onRollModule)
        Divider()
        // ②'s conversion; ③ exports its repair from its own bar.
        Button(model.exportSelectionTitle) { model.exportImages(all: false) }.keyboardShortcut("e")
          .disabled(model.selected == nil || model.isWorking || !model.onRollModule)
        Button("导出勾选的 \(model.enabledCount) 张…") { model.exportImages(all: true) }.keyboardShortcut(
          "e", modifiers: [.command, .shift]).disabled(model.enabledCount == 0 || model.isWorking || !model.onRollModule)
        Button("导出接触表…") { model.exportContactSheet() }.keyboardShortcut(
          "e", modifiers: [.command, .option]).disabled(model.enabledCount == 0 || model.isWorking || !model.onRollModule)
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
    // A version fetched and checked goes in once this process has ended.
    model?.updater.install(relaunch: false)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
