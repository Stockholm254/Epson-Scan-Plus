import AppKit
import SwiftUI

private let accent = Hardware.accent

extension View {
  /// The window in the system's appearance, light or dark, on every page; on the copy stand the live
  /// view frosted under it all.
  func copyStandGlass(_ on: Bool, camera: CameraController) -> some View {
    background { if on { CopyStandBackdrop(camera: camera) } }
  }
}

struct ContentView: View {
  /// The model, observed through its gate (`WindowGate`): while a slider is dragged the window is
  /// updated ten times a second, not with every step.
  @Gated var m: AppModel
  init(m: AppModel) { _m = Gated(wrappedValue: m) }
  /// The contact sheet's picture in the output tab, opened large.
  @State var sheetPreviewOpen = false
  /// The strip's frame a dragged frame is over, to take its place.
  @State var dropTarget: UUID?
  /// The window's, which the Edit menu's Undo and Redo use.
  @Environment(\.undoManager) private var undoManager
  /// The sidebar shown or hidden by the toolbar's key: in module ① it holds the source's settings
  /// and stays out; in module ② only calibration and the export settings, so it is put away until
  /// wanted and the picture has the room. The 去漏光 page has none.
  @State private var captureSidebar = NavigationSplitViewVisibility.all
  @AppStorage("convertSidebarShown") private var convertSidebarShown = false
  /// The colour mixer's kind of move shown: hue, saturation or luminance.
  @AppStorage("mixerKind") private var mixerKind = 0
  @State private var inspector = true
  /// The status line shows a while after it changes, and stays while something is under way.
  /// The status line shows once something says a thing: at launch the library's own line says
  /// where to start, and the footer saying it again was a third copy.
  @State private var statusShown = false
  @State private var statusChange = 0
  var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: {
        switch m.page {
        case .library, .leak: return .detailOnly
        case .convert: return convertSidebarShown ? .all : .detailOnly
        case .capture: return captureSidebar
        }
      },
      set: { v in
        switch m.page {
        case .library, .leak: break
        case .convert: convertSidebarShown = v != .detailOnly
        case .capture: captureSidebar = v
        }
      })
  }
  /// The inspector, put away on the library, whose rolls take the window; shown or hidden as left
  /// on the modules.
  var inspectorShown: Binding<Bool> {
    Binding(get: { m.page != .library && inspector }, set: { if m.page != .library { inspector = $0 } })
  }
  /// Module ②'s sidebar, opened on calibrating the preset: its film tab, the section unfolded.
  func openCalibration() {
    // Calibrating a preset is ②'s: the film's slopes.
    m.convertStep = .demask
    UserDefaults.standard.set(true, forKey: "panelSection.calibration")
    withAnimation(Liquid.flow) { convertSidebarShown = true }
  }
  /// Module ②'s sidebar, opened on the export settings.
  func openExportSettings() {
    // Exporting is ③'s.
    m.convertStep = .grade
    withAnimation(Liquid.flow) { convertSidebarShown = true }
  }
  /// The roll open, as the library names it, else the app's name.
  var windowTitle: String {
    guard let url = m.sessionURL else { return "Epson Scan plus" }
    if !m.rollName.isEmpty { return m.rollName }
    return RollLibrary.started(url.lastPathComponent).map(RollLibrary.title) ?? url.lastPathComponent
  }
  var windowSubtitle: String {
    guard m.sessionURL != nil || !m.frames.isEmpty else { return "" }
    return [FilmCalibration.film(m.filmName), "\(m.frames.count) 张"].filter { !$0.isEmpty }.joined(separator: " · ")
  }
  var body: some View {
    // The system's window: a sidebar for the module's settings, the workspace with the film strip
    // under it, and an inspector for the frame, all under the system's toolbar.
    NavigationSplitView(columnVisibility: sidebarVisibility) {
      // Worked out only while it shows: put away, the sidebar was worked out again with every
      // update of the window all the same (③'s 输出 tab, some 5 ms each).
      Group {
        if sidebarVisibility.wrappedValue != .detailOnly { leftPanel } else { Color.clear }
      }
        .navigationSplitViewColumnWidth(min: Preferences.leftWidths.lowerBound, ideal: m.preferences.leftWidth, max: Preferences.leftWidths.upperBound)
    } detail: {
      VStack(spacing: 0) {
        // One module over the other as they change, cross-fading, not one under the other.
        ZStack {
          if m.page == .library {
            LibraryPage(m: m, shelf: m.shelf).transition(.opacity)
          } else if m.page == .leak {
            LeakPage(m: m, lab: m.leak).transition(.opacity)
          } else {
            workspace.transition(.opacity)
          }
        }
        // The open roll's strip, under the modules that work on it; the library shows every roll.
        if m.page != .library { filmstrip.transition(.move(edge: .bottom).combined(with: .opacity)) }
        if m.page == .leak {
          if m.leak.busy != nil { LeakStatus(lab: m.leak) }
        } else if footerShown {
          footer.transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(Liquid.flow, value: footerShown)
      .inspector(isPresented: inspectorShown) {
        ZStack { if m.page == .leak { LeakPanel(m: m, lab: m.leak).transition(.opacity) } else { rightPanel.transition(.opacity) } }
          .inspectorColumnWidth(min: Preferences.rightWidths.lowerBound, ideal: m.preferences.rightWidth, max: Preferences.rightWidths.upperBound + 40)
      }
    }
    // From one module to another the sidebar and the inspector slide, the pages cross-fade.
    .animation(Liquid.pageChange, value: m.page)
    // ② ↔ ③: the same picture, the step's controls cross-fading in, as a page's do.
    .animation(Liquid.pageChange, value: m.convertStep)
    // No sidebar on the library or ③: no key for one.
    .toolbar(removing: m.page == .library || m.page == .leak ? .sidebarToggle : nil)
    .navigationTitle(windowTitle)
    .navigationSubtitle(windowSubtitle)
    .toolbar { toolbarContent }
    .onChange(of: m.activityStatus) { showStatus() }
    // An export done shows, also one whose words are those the line said last.
    .onChange(of: m.exportsDone) { showStatus() }
    // ② works with the film in the left panel, ③ exports from it.
    .onChange(of: m.convertStep) { _, step in
      if step == .demask, m.page == .convert { withAnimation(Liquid.flow) { convertSidebarShown = true } }
    }
    // A batch of scans takes minutes a frame, an export of a roll a while: the Dock icon counts
    // the frames done, and once the batch ends with the app behind another, it bounces once.
    .onChange(of: m.scanBatch.badge ?? m.exportProgress.badge) { was, now in
      NSApp.dockTile.badgeLabel = now
      if was != nil, now == nil, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
    .onChange(of: m.tool) { _, tool in
      // Picking neutral points calibrates the preset, whose section is in module ②'s film tab.
      if tool == .calibrate, m.page == .convert, !convertSidebarShown || m.convertStep != .demask { openCalibration() }
    }
    .copyStandGlass(cameraStage, camera: m.camera)
    .windowMinimum(width: 1120, height: 760)
    .alert(
      "无法完成操作",
      isPresented: Binding(get: { m.errorText != nil }, set: { if !$0 { m.errorText = nil } })
    ) {
      Button("好") { m.errorText = nil }
    } message: {
      Text(m.errorText ?? "")
    }
    .sheet(isPresented: $m.showPresets) { PresetManagerSheet(m: m) }
    .sheet(isPresented: $m.showFlats) { FlatManagerSheet(m: m) }
    .sheet(isPresented: $m.showUpdates) { UpdateSheet(m: m, updater: m.updater) }
    .sheet(isPresented: $m.showShortcuts) { ShortcutsSheet() }
    .sheet(isPresented: $m.choosingPaste) { PasteSheet(m: m) }
    .sheet(isPresented: $m.choosingSync) { PasteSheet(m: m, purpose: .sync) }
    .sheet(isPresented: $m.savingGradingPreset) { PasteSheet(m: m, purpose: .preset) }
    .sheet(isPresented: $m.askingNewProject) { NewProjectSheet(m: m) }
    .sheet(isPresented: $m.changingFilm) { NewProjectSheet(m: m, purpose: .changeFilm) }
    .onChange(of: m.tool) { m.refresh() }
    .onAppear {
      m.undoManager = undoManager
      if m.page == .leak { m.leak.undoManager = undoManager }
      // The 3D film's renderer readied while the window settles, so the film shelf and ②'s film
      // come at once the first time.
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { FilmRender.prewarm(m) }
    }
    .onChange(of: undoManager) { _, new in
      m.undoManager = new
      if m.page == .leak { m.leak.undoManager = new }
    }
    .onChange(of: m.page) { _, page in
      if page == .leak { m.leak.undoManager = undoManager } else { m.leak.save() }
    }
    .onChange(of: m.settingsRequests) { withAnimation(Liquid.flow) { captureSidebar = .all } }
    // From the live view to the pictures taken: the light table comes back, fitted and drawn.
    .onChange(of: m.liveViewShown) { _, live in
      guard !live else { return }
      m.fitView()
      m.refresh()
    }
  }
  /// The window's toolbar, the system's: the scanner's lamp by the title, the modules in the
  /// middle with the assistant, the module's keys after the title, and the module's leading
  /// action and the inspector's key at the trailing end. A scan's progress is in the workspace's
  /// status line, where it never lies across into the inspector. The system groups them
  /// on its glass and folds what does not fit into its overflow menu.
  @ToolbarContentBuilder var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      if showsScannerLamp { scannerLamp }
    }
    ToolbarItemGroup(placement: .navigation) {
      if m.page == .leak {
        LeakToolbar(lab: m.leak)
      } else {
        // The library, a new project and importing are the library tab's, the first in the switcher.
        // The frame's colour and tone set from its own picture, on this Mac (`AutoAdjust`). Opening it
        // on the leak page stays in the 画面 menu (⌥⌘L) and the light table's context menu.
        // Each step's own keys: ③ the automatic grade, ② the dust it ringed.
        if m.page == .convert && m.convertStep == .grade {
          Button {
            m.autoAdjust()
          } label: {
            Label("自动调整", systemImage: "wand.and.stars")
          }
          .help("自动调整这张：白平衡和色阶回到自动，按画面定曝光和阴影冷暖，对比度、饱和度不动；只在本机计算，不上传，⌘Z 撤销（⇧⌘A）")
          .disabled(m.selected == nil || m.isWorking)
        }
        if m.page == .convert && m.convertStep == .demask {
          // The dust found ringed on the single view, or the picture clear of rings.
          Toggle(isOn: $m.showDust) {
            Label("除尘标出", systemImage: CanvasTool.dust.symbol)
          }
          .help(m.showDust ? "除尘标出（⇧⌘D）：开着，单张上用圆圈标出找到的灰尘（实线去掉，虚线留下）；点一下不画圆圈" : "除尘标出（⇧⌘D）：关着，单张上不画灰尘的圆圈；点一下标出")
          .accessibilityLabel("除尘标出")
        }
      }
    }
    ToolbarItem(placement: .principal) {
      // The modules open once there is a project: until then their segments are greyed out. The
      // system's segmented control, as SwiftUI's segmented picker does not grey a segment alone.
      let stations = AppModel.Station.allCases
      HStack(spacing: 8) {
        // While a frame is repaired, ② names its last part: 去漏光 is in ②, not a step after it.
        ModuleSwitch(
          titles: stations.map { $0 == .demask && m.page == .leak ? "② 去色罩 › 去漏光" : $0.title },
          selected: stations.firstIndex(of: m.station) ?? 0,
          enabled: stations.map { $0 == .library || m.hasProject },
          help: m.hasProject
            ? "库（⇧⌘L）：所有的卷，新建工程和导入；① 采集、② 去色罩（负片变成干净的正片，必要时去漏光）、③ 调色（调色和导出）（⌥⌘1–3）"
            : "先在库里新建工程、打开一卷或导入，① 采集、② 去色罩、③ 调色才能用"
        ) { i in
          let s = stations[i]
          if s == .library || m.hasProject { m.station = s } else { m.objectWillChange.send() }
        }
      }
    }
    // The assistant by the modules, in the middle, clear of the inspector's part of the toolbar,
    // on a capsule of its own (`AssistantKey`): on the toolbar's shared glass it ran into the
    // modules' capsule through a neck in the front window, and a fixed spacer did not part them.
    ToolbarItem(placement: .status) { AssistantKey(m: m, panel: assistantPanel) }
      .sharedBackgroundVisibility(.hidden)
    ToolbarItemGroup(placement: .primaryAction) {
      if m.page == .leak {
        LeakExportKey(lab: m.leak)
      } else if m.page == .capture && m.captureSource == .scanner {
        Button {
          m.requestPreview()
        } label: {
          Label("预览", systemImage: "viewfinder")
        }.disabled(!m.scanner.ready || m.isWorking)
        Button {
          m.requestScanEnabled()
        } label: {
          Label("扫描所选 \(m.enabledCount)", systemImage: "scanner")
        }.leadingAction().disabled(!m.scanner.ready || !m.hasScanTargets || m.isWorking)
      } else if m.page == .convert && m.convertStep == .grade {
        // Exporting, ③'s, with its settings behind it in the sidebar.
        Menu {
          Button(m.exportSelectionTitle) { m.exportImages(all: false) }.disabled(m.selected == nil || m.isWorking)
          Button(m.quickExportTitle) { m.exportHere(m.selection) }.disabled(m.selected == nil || m.isWorking || m.exportFolder == nil)
          Button("导出勾选的 \(m.enabledCount) 张…") { m.exportImages(all: true) }.disabled(m.enabledCount == 0 || m.isWorking)
          let changed = m.changedSinceExport
          if !changed.isEmpty {
            Button("导出改过的 \(changed.count) 张…") { m.exportImages(changed) }.disabled(m.isWorking)
          }
          Button("导出接触表…") { m.exportContactSheet() }.disabled(m.enabledCount == 0 || m.isWorking)
          Divider()
          Button("导出设置…") { openExportSettings() }
        } label: {
          Label("导出", systemImage: "square.and.arrow.up")
        } primaryAction: {
          if m.selected != nil && !m.isWorking { m.exportImages(all: false) }
        }
        .help("导出当前这张，或 ⌘ / ⇧ 点选的几张（⌘E）；点箭头导出勾选的画面、接触表，或改格式和文件名")
      }
    }
    ToolbarItem(placement: .primaryAction) {
      // The library has no inspector.
      if m.page != .library {
        Button {
          withAnimation(Liquid.pageChange) { inspector.toggle() }
        } label: {
          Label(inspector ? "隐藏检查器" : "显示检查器", systemImage: "sidebar.trailing")
        }.help(inspector ? "隐藏右边的检查器" : "显示右边的检查器")
      }
    }
  }
  /// The batch's progress, frames counted with the one being scanned, on one line; while
  /// cancelling, what the scanner does first in its place.
  var scanProgress: some View {
    let label = m.scanBatch.isActive
      ? m.scanProgressLabel : "预览 · \(Int(ScanBatchProgress.normalized(m.scanner.progress) * 100))%"
    let hint = m.scanner.cancellationHint
    return HStack(spacing: 8) {
      Text(hint ?? label)
        .font(.system(size: 11)).monospacedDigit().lineLimit(1).truncationMode(.tail)
        .foregroundStyle(hint == nil ? Color.primary : Color.secondary)
        .frame(maxWidth: 190, alignment: .trailing)
      ProgressView(
        value: m.scanBatch.isActive
          ? m.scanProgressFraction : ScanBatchProgress.normalized(m.scanner.progress)
      ).frame(width: 90)
      .accessibilityLabel(m.scanBatch.isActive ? "整批扫描进度" : "预览进度")
      .accessibilityValue(m.scanBatch.isActive ? m.scanProgressLabel : m.scanner.status)
    }
      .help((hint.map { $0 + "\n" } ?? "") + "整批进度按张数计算，包含当前这张的扫描进度。剩余时间开始按计划估计（本机实测的速度），扫过一部分以后按目前的速度。每张开头扫描头先定位、校准，要十几秒")
  }
  /// The scanner's front-panel lamp with a short LCD status; the full status is in the tooltip.
  var scannerLamp: some View {
    let state = lampState
    return HStack(spacing: 5) {
      StatusLED(lamp: state.lamp, size: 8)
      Text(state.text).lineLimit(1)
    }.readout(10).help(m.scanner.status)
      .accessibilityElement(children: .combine).accessibilityLabel("扫描仪状态")
      .accessibilityValue(state.text)
  }
  /// The scanner's lamp where the scanner is used, ① with the V850 as the source, or while it works.
  var showsScannerLamp: Bool {
    (m.page == .capture && m.captureSource == .scanner) || m.scanner.busy || m.scanBatch.isActive
  }
  var lampState: (lamp: StatusLED.Lamp, text: String) {
    if m.scanner.busy { return (.busy, m.scanner.cancellationHint == nil ? "工作中" : "取消中") }
    return m.scanner.ready ? (.ready, "就绪") : (.fault, "未就绪")
  }
  /// The view and tool keys over the light table, on glass.
  var glassToolRow: some View {
    HStack(spacing: 10) {
      HStack(spacing: 10) { viewControls }.glassBar()
      Spacer(minLength: 8)
      HStack(spacing: 8) { toolControls }.glassBar()
    }
  }
  /// The view switch, the loupe and how the table lies.
  @ViewBuilder var viewControls: some View {
    Group {
    // With the camera the live view is a third way to look, beside the sheet and the frame.
    if m.page == .capture && m.captureSource == .camera {
      CaptureViewPicker(m: m)
    } else {
      // The single frame first: a roll opens on it.
      Picker("视图", selection: Binding(get: { m.singleView }, set: { m.showSingle($0) })) {
        Text("单张").tag(true)
        Text("接触表").tag(false)
      }.pickerStyle(.segmented).frame(width: 150)
        // A preview being read shows on the light table as it comes.
        .disabled(m.previewShowing)
        .help(m.previewShowing ? "预览扫描中，画面在接触表上逐渐出现；扫完后才能看单张" : "单张 / 接触表（⌘1）")
    }
    }
        .onChange(of: m.singleView) {
        m.fitView()
        m.focusCanvas()
        m.refresh()
      }
      Button {
        m.toggleLoupe()
      } label: {
        Label("看片镜", systemImage: "circle.circle").font(.system(size: 11))
      }.buttonStyle(KeyStyle(latched: m.preferences.showLoupe)).controlSize(.small)
        .help("看片镜：点一下放到所选画面上，拖动放大细看，再点一下收起 · Z。接触表和单张都能用；右键选择型号")
      // Turning the holder: pages laid out from files of their own have none.
      if !m.singleView && !m.onSheetPage {
        Button {
          m.preferences.contactLandscape.toggle()
          m.fitView()
        } label: {
          Label("横排", systemImage: "rectangle.landscape.rotate").font(.system(size: 11))
        }.buttonStyle(KeyStyle(latched: m.preferences.contactLandscape)).controlSize(.small)
          .help("把竖放的片夹横过来摆在灯箱上，胶片条横向排开，更好地利用宽屏。方向跟随多数画面的旋转，都没有旋转时顺时针转")
      }
  }
  /// The canvas tools, and fitting the picture.
  @ViewBuilder var toolControls: some View {
      // Capturing places the frames; ② takes the mask off (the crops and the base), ③ grades (the
      // neutral grey).
      let tools: [CanvasTool] = m.page == .capture ? [.select, .crop, .base]
        : m.convertStep == .demask ? [.select, .crop, .region, .base] : [.select, .neutral]
      ForEach(tools, id: \.self) { t in
        Button {
          m.useTool(t)
        } label: {
          HStack(spacing: 4) {
            // The two crops' keys in their colours on the picture: amber the picture, cyan the de-masking region.
            Image(systemName: t.symbol).frame(width: 16, height: 14)
              .foregroundStyle(t.colour.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color.primary)
            if let label = t.label { Text(label).font(.system(size: 11)) }
          }
        }.buttonStyle(KeyStyle(latched: m.tool == t)).controlSize(.small).help(t.help)
          .accessibilityLabel(t.rawValue)
      }
      // ②'s last, optional part: the frame shown into 去漏光, and back with its repair into ③.
      if m.page == .convert && m.convertStep == .demask {
        Divider().frame(height: 18)
        Button {
          if let id = m.selectedID { m.openInLeak(id) }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "wand.and.rays").frame(width: 16, height: 14)
            Text(m.selected?.adjustments.leakFix == nil ? "去漏光" : "改去漏光").font(.system(size: 11))
          }
        }.buttonStyle(.bordered).controlSize(.small).disabled(m.selected == nil || m.isWorking)
          .help("去漏光（可选 · ⌥⌘L）：在 ② 的结果上修这一张的漏光，修好后「用到 ③ 调色」，在修好的照片上接着调色")
      }
      // Only the single frame zooms; the light table always shows the whole roll.
      if m.singleView {
        Divider().frame(height: 18)
        Button {
          m.fitView(animated: true)
        } label: {
          Text("适合").font(.system(size: 11))
        }.buttonStyle(.bordered).controlSize(.small).help("缩放回适合窗口")
      }
  }
  /// Which frame is shown, or how many there are.
  /// The light table's pages, once a roll's frames fill more than one.
  var pageControl: some View {
    let pages = m.contactPages.count
    return HStack(spacing: 6) {
      Button { m.showContactPage(m.contactPage - 1) } label: { Image(systemName: "chevron.left") }
        .disabled(m.contactPage == 0).accessibilityLabel("上一页")
      Text("第 \(m.contactPage + 1) / \(pages) 页").font(.system(size: 11)).monospacedDigit()
      Button { m.showContactPage(m.contactPage + 1) } label: { Image(systemName: "chevron.right") }
        .disabled(m.contactPage >= pages - 1).accessibilityLabel("下一页")
    }.buttonStyle(.borderless).help("接触表排满后翻到下一页；也可以在灯箱上左右滑动，或按 ← →")
  }
  /// The bars under the picture: where you are on the left, how it is shown and how it is turned
  /// on the right, each its own group. Narrow, the source's size is left out.
  func bottomBars(compact: Bool) -> some View {
    HStack(spacing: 10) {
      HStack(spacing: 8) { placeControls(compact: compact) }.glassBar()
      // The pages' control grows out of the count beside it; the bars change as the view does.
      if !m.singleView && m.contactPages.count > 1 {
        pageControl.glassBar().transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
      }
      Spacer(minLength: 8)
      HStack(spacing: 8) { displayControls }.glassBar()
      // Module ① shows the raw picture, with nothing to adjust: turning it is ②'s.
      if m.page != .capture { HStack(spacing: 8) { orientationControls }.glassBar() }
    }
  }
  /// Which frame is shown, with the keys to the ones beside it; or how many there are.
  @ViewBuilder func placeControls(compact: Bool) -> some View {
    if m.singleView {
      Button {
        m.navigate(-1)
      } label: {
        Image(systemName: "chevron.left")
      }.buttonStyle(.borderless).disabled(!m.canNavigate(-1)).help("上一张 · ←").accessibilityLabel("上一张")
      Text("第 \(m.selected?.name ?? "—") 张").font(.system(size: 12, weight: .medium, design: .monospaced))
      Button {
        m.navigate(1)
      } label: {
        Image(systemName: "chevron.right")
      }.buttonStyle(.borderless).disabled(!m.canNavigate(1)).help("下一张 · →").accessibilityLabel("下一张")
      if let f = m.selected { PhotoInfoButton(frame: f) }
    } else {
      Text("\(m.frames.count) 个画面").font(.system(size: 12, weight: .medium, design: .monospaced))
      // The strip's positives as they are converted, after the library's small copies.
      if let p = m.positivesLoading {
        ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).progressViewStyle(.linear).frame(width: 90).controlSize(.small)
        Text("\(p.what) \(p.done) / \(p.total)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
          .help(p.what == "读取原图"
            ? "第一次打开这一卷：正在读每张原图（翻拍的一张 370 MB），做全卷斜率估计，同时存一份 3000 像素的无损小样，下次打开就快了；先显示的是库里存着的小图"
            : "正在把每张转成正片：先显示的是库里存着的小图，转好一张换一张")
      }
    }
    // The single frame's size and source; on the light table only the holder's preview just read,
    // not the last frame looked at alone, which another may have followed.
    if !compact && !m.sourceSummary.isEmpty && (m.singleView || m.sourceSummary.hasPrefix("透扫预览")) {
      Text(m.sourceSummary).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
    }
  }
  /// What is shown, the negative or the positive, one choice on the light table and for the single
  /// frame; and the single frame's zoom.
  @ViewBuilder var displayControls: some View {
    if m.showsOriginal {
      // Module ①: the raw picture, in daylight white balance or as read, and in the single view how
      // it was exposed.
      Picker("原片", selection: Binding(get: { m.preferences.balanceRawView }, set: { m.setBalanceRawView($0) })) {
        Text("原样").tag(false)
        Text("日光").tag(true)
      }.pickerStyle(.segmented).labelsHidden().frame(width: 100)
        .help("相机的原片：日光按日光白平衡显示，和相机的取景、C1 打开时一样，用来检查窄带灯的配比：片基是中性灰，灯就配对了。原样是传感器读到的，没有白平衡，绿通道最灵敏，所以偏绿。只为显示，存下的数据、曝光和片基的读数都不变。扫描仪的扫描本来就按灯配平，两样一样")
      if m.singleView, let e = m.exposureReading {
        HStack(spacing: 6) {
          Circle().fill(e.verdict == .over ? Color.red : e.verdict == .under ? Color.orange : Color.green).frame(width: 7, height: 7)
          Text(e.short).font(.system(size: 11, weight: .medium)).lineLimit(1)
          InfoButton(text: e.text + "\n\n" + Self.originalInfo)
          // The base's balance across the channels, for setting the narrowband light.
          if let b = m.baseBalance {
            Divider().frame(height: 12)
            BaseSwatch(level: b.balanced)
            Text(b.short).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
              .help(b.isEven ? "片基在日光白平衡下是灰的，灯的配比合适" : "片基在日光白平衡下还偏色：点 ⓘ 看哪盏灯调多少")
            InfoButton(text: b.text, about: "片基偏色")
          }
        }
      } else {
        HStack(spacing: 6) {
          Text("原片 · 线性").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          InfoButton(text: Self.originalInfo)
        }
      }
    } else {
      conversionDisplayControls
    }
  }
  static let originalInfo = "① 采集显示原片：raw 文件里的读数，按线性响应显示（光多一倍，读数就大一倍，再编码到屏幕），不反相、不去色罩、不去串色，也不加曲线。默认「日光」：按日光白平衡显示（A7R IV 红 ×2.61、蓝 ×1.60），和相机的取景、C1 打开时一样，这正是检查窄带灯配比用的：片基是中性灰、片基偏色旁边的色块左右两半一样，灯就配对了。「原样」是传感器读到的，没有白平衡，绿通道比红、蓝灵敏，所以偏绿。两样都只为显示，存下的数据、曝光和片基的读数都不变。扫描仪的扫描本来就按灯配平，不受影响。这里先不提供调整；去色罩和调整在 ②。\n\n曝光指示看的是胶片最亮的地方：负片是最薄的片基和暗部，反转片是最亮处。有通道到顶的胶片超过 0.5% 算过曝，最亮处不到满量程的 25%（还差两档以上）算欠曝。三个通道都到顶的裸光（灯箱、空片框）不算在内；没到顶的裸光会被当成胶片，翻拍时把画面裁到胶片上判断更准。"
  /// Module ②'s: the negative or the positive, and the single frame's zoom.
  @ViewBuilder var conversionDisplayControls: some View {
    Picker("显示", selection: $m.showNegative) {
      Text("负片").tag(true)
      Text("正片").tag(false)
    }.pickerStyle(.segmented).labelsHidden().frame(width: 100)
      .help("负片：扫描或翻拍的原样。正片：每张按各自的调色显示，接触表上片边与片夹按本卷片基反相")
      .onChange(of: m.showNegative) { m.refresh() }
    if m.singleView {
      ZoomReadoutLabel(readout: m.zoomReadout)
    }
  }
  /// Turning and mirroring: this frame (or every one, synced) in the single view, the whole roll on
  /// the light table.
  @ViewBuilder var orientationControls: some View {
    if m.singleView {
      Button {
        m.turn(clockwise: false)
      } label: {
        Image(systemName: "rotate.left")
      }.help(m.syncOrientation ? "全部逆时针旋转 90° · ⇧⌘R" : m.multiSelected ? "所选的 \(m.selection.count) 张逆时针旋转 90° · ⇧⌘R" : "逆时针旋转 90° · ⇧⌘R")
      Button {
        m.turn(clockwise: true)
      } label: {
        Image(systemName: "rotate.right")
      }.help(m.syncOrientation ? "全部顺时针旋转 90° · ⌘R" : m.multiSelected ? "所选的 \(m.selection.count) 张顺时针旋转 90° · ⌘R" : "顺时针旋转 90° · ⌘R")
      Button {
        m.toggleMirror()
      } label: {
        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
      }.buttonStyle(KeyStyle(latched: m.settings.flipHorizontal == true)).help(
        m.syncOrientation ? "全部水平镜像：修正整卷胶片正反面方向" : m.multiSelected ? "所选的 \(m.selection.count) 张水平镜像" : "水平镜像：修正胶片正反面方向")
      Button {
        m.syncOrientation.toggle()
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "link")
          Text("整卷一起转")
        }.font(.system(size: 12))
      }.buttonStyle(KeyStyle(latched: m.syncOrientation))
        .help("开启后，旋转和水平镜像同步应用到本卷全部照片")
    } else {
      Button {
        m.turnRoll(clockwise: false)
      } label: {
        Image(systemName: "rotate.left")
      }.help(m.multiSelected ? "所选的 \(m.selection.count) 张逆时针旋转 90°" : "全卷逆时针旋转 90°：改变每张在单张视图和导出中的方向；转过 90° 的画面在横排的灯箱上也正立；⌘ 或 ⇧ 点选几张时只转所选的").disabled(m.frames.isEmpty)
      Button {
        m.turnRoll(clockwise: true)
      } label: {
        Image(systemName: "rotate.right")
      }.help(m.multiSelected ? "所选的 \(m.selection.count) 张顺时针旋转 90°" : "全卷顺时针旋转 90°：改变每张在单张视图和导出中的方向；转过 90° 的画面在横排的灯箱上也正立；⌘ 或 ⇧ 点选几张时只转所选的").disabled(m.frames.isEmpty)
      Button {
        m.mirrorRoll()
      } label: {
        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
      }.buttonStyle(KeyStyle(latched: m.tableMirrored)).help(
        m.multiSelected ? (m.tableMirrored ? "取消所选的 \(m.selection.count) 张水平镜像" : "所选的 \(m.selection.count) 张水平镜像")
          : m.rollMirrored ? "取消全卷水平镜像" : "全卷水平镜像：修正胶片正反面放反").disabled(m.frames.isEmpty)
    }
  }
  /// What floats over the picture: the render in progress, the frame's resolution, the tool's hint.
  @ViewBuilder var canvasOverlays: some View {
      if m.rendering { RenderProgress(step: m.renderStep, pictureShownAt: { m.pictureShownAt }).padding(14) }
      // A new roll on ① with the scanner: the preview's key where the eye is, as the camera's empty
      // view has its connect key (the canvas then writes nothing of its own).
      if m.emptyScannerTable {
        VStack(spacing: 10) {
          Image(systemName: "viewfinder").font(.system(size: 30, weight: .light)).foregroundStyle(Color(white: 0.45))
          Text(m.scanner.ready ? "片夹放好后，先扫一张整幅预览" : "扫描仪还没有就绪")
            .font(.system(size: 13)).foregroundStyle(Color(white: 0.4))
          // What can be done now: preview once the scanner is ready, else connect it again.
          if m.scanner.ready {
            Button {
              m.requestPreview()
            } label: {
              Label("预览", systemImage: "viewfinder")
            }.buttonStyle(KeyStyle(prominent: true)).controlSize(.large).disabled(m.isWorking)
              .help("扫一张整幅预览（⇧⌘P）：找出片夹里的画面，再勾选要正式扫描的")
          } else {
            Button {
              m.scanner.reconnect()
            } label: {
              Label("重新连接", systemImage: "arrow.clockwise")
            }.buttonStyle(.bordered).controlSize(.large).disabled(m.isWorking || m.scanner.busy)
              .help("接好 V850 的 USB 和电源后再连一次")
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
          // On the lit table: drawn for a light surface whatever the window's look.
          .environment(\.colorScheme, .light)
      }
      // The film base and the white balance the single frame converts with, at its top left; the
      // base's numbers on hover.
      // Not over ①'s raw picture, which nothing converts.
      if m.singleView, !m.showsOriginal, let f = m.selected, f.adjustments.inputIsNegative {
        HStack(spacing: 12) {
          HStack(spacing: 5) { Text("片基").foregroundStyle(.secondary); Text(m.baseShort(f)) }
          HStack(spacing: 5) { Text("白平衡").foregroundStyle(.secondary); Text(m.balanceShort(f)) }
          if let region = f.adjustments.analysisRegion ?? m.toneAnalysis?.followed {
            HStack(spacing: 5) {
              Image(systemName: CanvasTool.region.symbol)
                .foregroundStyle(CanvasTool.region.colour.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .primary)
              Text(String(format: f.adjustments.analysisRegion == nil ? "去色罩区域 %.0f%%（避开片边）" : "去色罩区域 %.0f%%", region.width * region.height * 100))
            }
          }
        }.font(.system(size: 11)).lineLimit(1)
          .padding(.horizontal, 9).padding(.vertical, 5)
          .floatingPlate(RoundedRectangle(cornerRadius: 5), text: Color(white: 0.92), opacity: 0.65)
          .help(m.baseSource(f) + (m.baseNotes(f).isEmpty ? "" : "\n" + m.baseNotes(f)) + (m.toneAnalysis.map { a in
            "\n片基 " + zip(["R", "G", "B"], a.base.values).map { String(format: "%@ %.3f", $0, $1) }.joined(separator: " · ")
          } ?? "") + "\n白平衡按这个顺序定：取样中性灰 → 标定预设的中性 → 自动；冷暖、绿洋红、阴影冷暖和阴影色调在它之后")
          .accessibilityElement(children: .combine).accessibilityLabel("片基和白平衡")
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
      }
      if m.singleView && !m.rendering {
        VStack(alignment: .trailing, spacing: 6) {
          if let frame = m.selected, !frame.hasFullResolution {
            Text(
              frame.needsRescan
                ? "裁切超出原扫描 · 需重扫"
                : m.overviewDPI >= 600 ? "\(Int(m.overviewDPI)) dpi 预览 · 正式扫描后更清晰" : "低清预览 · 正式扫描后查看细节"
            ).font(.system(size: 11))
              .padding(7).floatingPlate(RoundedRectangle(cornerRadius: 5), text: Hardware.amberText, opacity: 0.65)
              // On the dark round the picture in either appearance: a light plate in light mode
              // left its amber unreadable.
              .environment(\.colorScheme, .dark)
          }
        }.padding(12).allowsHitTesting(false)
      }
      if let hint = m.toolHint, !m.rendering {
        HStack(spacing: 6) {
          Image(systemName: m.tool.symbol).foregroundStyle(accent)
          Text(hint)
        }.font(.system(size: 11))
          .padding(.horizontal, 11).padding(.vertical, 6)
          .floatingPlate(Capsule(), text: Color(white: 0.92), opacity: 0.72)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(Self.barInset + 4)
          .allowsHitTesting(false).accessibilityLabel("工具提示")
      }
      // A line about the picture for a few seconds (`AppModel.noteOnCanvas`), a little below its
      // middle, fading in and out.
      GeometryReader { g in
        ZStack {
          if let note = m.canvasNote {
            Text(note).font(.system(size: 12, weight: .medium))
              .padding(.horizontal, 14).padding(.vertical, 7)
              .floatingPlate(Capsule(), text: Color(white: 0.92), opacity: 0.72)
              .transition(.opacity)
          }
        }.position(x: g.size.width / 2, y: g.size.height * 0.62)
      }.allowsHitTesting(false).animation(.easeInOut(duration: 0.4), value: m.canvasNote)
  }
  /// Module ① with the camera: the live view takes the canvas's place.
  var cameraStage: Bool { m.liveViewShown }
  @ViewBuilder var workspace: some View {
    if cameraStage { CameraStage(m: m, camera: m.camera) } else { sheetWorkspace }
  }
  /// The bars floating over the canvas lie this far in from its edges: on the light table's
  /// glass, clear of its frame.
  static let barInset = LightTable.glassInset + 6
  var sheetWorkspace: some View {
    let inset = Self.barInset, bar = inset + 44
    return ZStack {
      ScanCanvas(model: m, reserved: NSEdgeInsets(top: bar, left: 0, bottom: bar, right: 0))
        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
      VStack(spacing: 0) {
        WidthFit {
          glassToolRow
        } compact: {
          glassToolRow.labelStyle(.iconOnly)
        }.lineLimit(1).padding(.horizontal, inset).padding(.top, inset)
        ZStack(alignment: .topTrailing) {
          Color.clear
          canvasOverlays
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        WidthFit {
          bottomBars(compact: false)
        } compact: {
          bottomBars(compact: true)
        }.lineLimit(1).buttonStyle(.bordered).controlSize(.small).padding(.horizontal, inset).padding(.bottom, inset)
          .animation(Liquid.flow, value: m.singleView)
          .animation(Liquid.flow, value: m.contactPages.count)
      }
    }
  }
  /// Module ① keeps the roll's name and notes on the right; module ② the adjustments.
  var rightPanel: some View {
    // One over the other as the module changes, cross-fading.
    ZStack {
      if m.page == .capture { rollPanel.transition(.opacity) } else { adjustPanel.transition(.opacity) }
    }
  }
  /// Module ②'s sidebar's first tab: the film and where its slopes come from, the film base and
  /// the frame's extent, which are set once for a roll or a frame, before the picture is worked on.
  var filmTab: some View {
    // In the order the user put them (dragged by their grips), else the film, calibrating its
    // preset, its base, the frame's extent. A slide has no channel slopes and no mask to divide
    // by; the frame's extent is the single frame's.
    let slide = m.settings.isSlide
    let shown = ["film"] + (slide ? [] : ["calibration", "base"]) + (m.singleView ? ["frame"] : [])
    return VStack(alignment: .leading, spacing: 16) {
      ArrangedColumn(.film, shown: shown) { key in
        switch key {
        case "film": filmSection
        case "calibration": calibrationSection
        case "base": baseSection.disabled(frameControlsOff)
        case "frame": frameSection.disabled(frameControlsOff)
        default: EmptyView()
        }
      }
    }
  }
  /// Module ②'s inspector, in the order the picture is worked on: white balance, tone, levels and
  /// colour; then what is reached for less (dust, curves, sharpening, input) folded away. The film,
  /// its base and the frame's extent are in the sidebar's first tab. Every section folds, and opens
  /// as it was left.
  var adjustPanel: some View {
    let grading = m.convertStep == .grade
    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          sectionTitle(grading ? "调色" : "去色罩", symbol: grading ? "slider.horizontal.3" : "circle.lefthalf.filled")
          Spacer()
          // This step's settings only: ③'s 重置 leaves the base and the repair, ②'s the grading.
          let what = AppModel.scopeName(m.stepScope)
          Button(m.multiSelected ? "重置所选的\(what)" : "重置\(what)") { m.resetAdjustments(m.stepScope) }.font(.system(size: 11))
            .help((m.multiSelected ? "把所选的 \(m.selection.count) 张的" : "把这一张的") + what + "恢复成新照片的样子"
              + (grading ? "；② 去色罩的设置和去漏光的修复不动" : "；③ 的调色不动，方向、画面范围和去漏光的修复保留"))
            .disabled(frameControlsOff)
        }
        // ③'s own row under the title: its looks kept by name and the frame's snapshots.
        if grading {
          HStack(spacing: 6) {
            gradingPresetMenu
            snapshotMenu
            Spacer()
          }.padding(.top, -8)
        }
        Group {
          if grading {
            // ③ 调色: on the picture ② leaves, repaired where 去漏光 was used; the sections in the
            // order the user put them, else white balance, tone, levels, colour, curves and
            // sharpening (a scan's by the scanner's measured MTF, a copy's by its camera's).
            leakRepairSection
            compositionSection
            ArrangedColumn(.grade, shown: SectionColumn.grade.defaults) { key in
              switch key {
              case "balance": balanceSection
              case "tone": toneSection
              case "levels": levelsSection
              case "colour": colourSection
              case "mixer": mixerSection
              case "grading": gradingSection
              case "curves": curvesSection
              case "sharpening": sharpeningSection
              default: EmptyView()
              }
            }
          } else {
            // ② 去色罩: the film, its base and the frame's extent are in the left panel; here what
            // is cleaned off the negative and how it is read, in the user's order; the steps after.
            ArrangedColumn(.demask, shown: SectionColumn.demask.defaults) { key in
              switch key {
              case "dust": DustSection(m: m)
              case "input": if readsAnImport { inputSection }
              default: EmptyView()
              }
            }
            Divider()
            nextSteps
          }
        }.disabled(frameControlsOff)
      }.padding(18)
        .buttonStyle(.bordered).controlSize(.small)
    }
    // Pinned under the sections, as Lightroom's Sync is: at hand however far the panel is scrolled,
    // rather than past the last folded section.
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        Divider()
        HStack(spacing: 6) {
          Button {
            m.syncSettings()
          } label: {
            let what = AppModel.scopeName(m.stepScope)
            Label(m.multiSelected ? "同步\(what)到所选的 \(m.selection.count) 张" : "同步\(what)到本卷", systemImage: "square.on.square").frame(maxWidth: .infinity)
          }.buttonStyle(.bordered).controlSize(.regular)
            .help((m.multiSelected ? "把这一张的\(AppModel.scopeName(m.stepScope))用到所选的每一张（⌘ 或 ⇧ 点胶片条选的）" : "把这一张的\(AppModel.scopeName(m.stepScope))用到本卷每一张；⌘ 或 ⇧ 点胶片条多选几张时，只用到所选的")
              + (m.convertStep == .grade ? "。只同步调色：各张的片基、画面范围和去漏光不动" : "。只同步去色罩：各张的调色不动，方向、画面范围和去漏光保留"))
            .disabled(frameControlsOff)
          // Lightroom's 同步设置 dialog: the settings to sync ticked one by one.
          Button { m.choosingSync = true } label: { Image(systemName: "checklist").frame(height: 16) }
            .buttonStyle(.bordered).controlSize(.regular)
            .help("选择性同步：把这张的设置一项项列出，只同步勾上的")
            .accessibilityLabel("选择性同步")
            .disabled(frameControlsOff || m.frames.count < 2)
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, m.multiSelected ? 4 : 10)
        // Lightroom's 自动同步: while on, every edit of this one goes to the others chosen as well.
        if m.multiSelected {
          Toggle(isOn: $m.autoSync) {
            Text(m.autoSync ? "自动同步：调这张，所选的 \(m.selection.count) 张一起变" : "自动同步").font(.system(size: 12))
          }
          .toggleStyle(.switch).controlSize(.mini)
          .help("打开后，在这张上改的每一项（滑杆、曲线、中性灰……）同时设到所选的每一张，按这张现在的值；没改的那些各张保留自己的。各张的方向、去色罩区域和去漏光修复不动；自动调整（魔棒）仍然只调这张。关掉或只选一张时停止。")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 18).padding(.bottom, 10)
        }
      }.background(.bar)
    }
  }
  /// 快照, as Lightroom's: the frame shown's grading kept under a name, to try it another way and
  /// come back to it; the latest first.
  var snapshotMenu: some View {
    let shots = m.shownSnapshots
    return Menu {
      if shots.isEmpty {
        Text("这张还没有快照")
      } else {
        Section("回到快照") {
          ForEach(shots.reversed()) { s in
            Button(s.name) { m.restoreSnapshot(s) }
              .help("存于 " + s.made.formatted(date: .abbreviated, time: .shortened))
          }
        }
      }
      Divider()
      Button("存快照…", systemImage: "camera") {
        let alert = NSAlert()
        alert.messageText = "存快照"
        alert.informativeText = "把这张现在的调色存在一个名字下，换个调法以后能一键回来；跟着这一卷存，不影响别的画面。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = m.nextSnapshotName
        alert.accessoryView = field
        alert.addButton(withTitle: "存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { m.takeSnapshot(named: field.stringValue) }
      }
      if !shots.isEmpty {
        Menu("删除快照", systemImage: "trash") {
          ForEach(shots.reversed()) { s in Button(s.name, role: .destructive) { m.deleteSnapshot(s) } }
        }
      }
    } label: {
      Text(shots.isEmpty ? "快照" : "快照 \(shots.count)").font(.system(size: 11)).monospacedDigit()
    }
    .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
    .help("快照：把这张现在的调色存一份，换个调法以后能一键回来，像 Lightroom 的快照")
    .disabled(frameControlsOff || m.isWorking)
  }
  /// 调色预设, as Lightroom's develop presets: one click gives the frame shown, or those chosen,
  /// a look kept earlier; saving lists the frame's grading to tick what the preset holds.
  var gradingPresetMenu: some View {
    let presets = m.preferences.gradingPresets
    return Menu {
      if presets.isEmpty {
        Text("还没有调色预设")
      } else {
        Section(m.multiSelected ? "套用到所选的 \(m.selection.count) 张" : "套用到这张") {
          ForEach(presets) { p in
            Button(p.name) { m.applyGradingPreset(p) }
              .help(p.settingsGroups.map(\.name).joined(separator: "、"))
          }
        }
      }
      Divider()
      Button("把这张的调色存为预设…", systemImage: "plus") { m.savingGradingPreset = true }
      if !presets.isEmpty {
        Menu("删除预设", systemImage: "trash") {
          ForEach(presets) { p in Button(p.name, role: .destructive) { m.deleteGradingPreset(p) } }
        }
      }
    } label: {
      Text("预设").font(.system(size: 11))
    }
    .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
    .help("调色预设：把调好的一张存成预设，一键套用到别的画面（多选时套用到所选的每一张）")
    .disabled(frameControlsOff || m.isWorking)
  }
  /// The frame's own controls wait for a frame, and for an export to finish.
  private var frameControlsOff: Bool { m.selected == nil || m.exporting }
  /// A section's ⟲, while the frame's section differs from a new frame's and can be changed.
  func resetKey(_ part: AppModel.AdjustmentPart) -> (() -> Void)? {
    !frameControlsOff && !m.isWorking && m.isChanged(part) ? { m.reset(part) } : nil
  }
  /// A preset as the film menu names it: with the day it was calibrated where another preset has
  /// its name (two calibrations of one film on the V850 are both "Kodak Portra 160 · V850").
  /// Presets in the menu by where they come from: data sheets, then those calibrated here, under
  /// headings naming `film` when they are its.
  @ViewBuilder func presetSections(_ list: [FilmProfile], film: String?) -> some View {
    let sheets = list.filter { $0.offsets == nil }, calibrated = list.filter { $0.offsets != nil }
    if !sheets.isEmpty {
      Section(film.map { "\($0) · 数据表" } ?? "数据表") { ForEach(sheets) { p in presetButton(p) } }
    }
    if !calibrated.isEmpty {
      Section(film.map { "\($0) · 本机标定" } ?? "本机标定") { ForEach(calibrated) { p in presetButton(p) } }
    }
  }
  /// A preset in the menu, checked when in use.
  func presetButton(_ p: FilmProfile) -> some View {
    Button {
      m.chooseProfile(p)
    } label: {
      if p.id == m.profile.id { Label(presetTitle(p), systemImage: "checkmark") } else { Text(presetTitle(p)) }
    }
  }
  func presetTitle(_ p: FilmProfile) -> String {
    guard m.profiles.filter({ $0.name == p.name }).count > 1,
      let day = p.publication.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression)
    else { return p.name }
    return "\(p.name)（\(p.publication[day])）"
  }
  /// The film: its preset, where the channel slopes come from in a line (the whole of it behind
  /// ⓘ), and the roll's switches that change how it is read.
  var filmSection: some View {
    PanelSection("胶片", key: "film", info: conversionBasis) {
      VStack(alignment: .leading, spacing: 8) {
        // The roll's film as it comes, and the shelf to take another from.
        let now = NewProjectSheet.current(m)
        Button {
          m.changingFilm = true
        } label: {
          HStack(spacing: 10) {
            FilmObject(look: NewProjectSheet.look(now, m: m), gauge: NewProjectSheet.gauge(now, format: m.format), turns: true)
              .frame(width: 38, height: 50).zIndex(1)
            VStack(alignment: .leading, spacing: 2) {
              Text(FilmCalibration.film(m.filmName)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
              Text("\(m.reversalRoll ? "反转片" : "负片") · \(m.format.rawValue)").font(.system(size: 10.5)).foregroundStyle(.secondary)
              Text("从胶片架换…").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Hardware.amberText)
            }
            Spacer(minLength: 0)
          }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(m.isWorking || !m.hasProject)
        .help("这一卷的胶片、片种和画幅：点开胶片架，搜索后换一种，三项一起换，可以撤销")
        // The preset, named as such: under the film it reads as a second film.
        labeled("预设") {
          // The film's presets first, as the film was chosen: its data sheet's and those calibrated
          // for it; another film's preset takes the roll to that film.
          Menu {
            presetSections(m.rollPresets, film: m.rollFilm.isEmpty ? nil : m.rollFilm)
            if !m.otherPresets.isEmpty {
              Menu("其他胶片的预设") { presetSections(m.otherPresets, film: nil) }
            }
            Divider()
            Button("管理预设…") { m.showPresets = true }
            Button(m.copyStandRoll ? "翻拍预设标定…" : "本机预设标定…") { openCalibration() }
          } label: {
            Text(presetTitle(m.profile)).lineLimit(1)
          }
          .menuStyle(.button).frame(maxWidth: .infinity, alignment: .leading)
          .help("这一卷用的预设：通道斜率和标定的中性。先列这种胶片的，分「数据表」和「本机标定」（这台扫描仪或翻拍时标定的）；选别的胶片的预设，这一卷也换成那种胶片")
        }
        // Where the preset in use comes from, at a glance: a data sheet, or calibrated here.
        Label(PresetTable.tag(m.profile), systemImage: PresetTable.symbol(m.profile))
          .font(.system(size: 10.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
          .foregroundStyle(m.profile.offsets != nil ? Hardware.amberText : Color.secondary)
          .help(m.profile.offsets != nil
            ? "本机标定的预设：用这台扫描仪或这次翻拍的中性点算出来的斜率和中性。\(m.profile.publication)"
            : "数据表的预设：斜率按厂家数据表的特性曲线，没有为这台扫描仪或相机标定过")
        // Which film the roll is comes before its preset: a slide is not inverted at all.
        labeled("本卷片种") {
          Picker("本卷片种", selection: Binding(get: { m.reversalRoll }, set: { m.setReversal($0) })) {
            Text("负片").tag(false)
            Text("反转片").tag(true)
          }
          .pickerStyle(.segmented).labelsHidden().disabled(m.isWorking || m.frames.isEmpty)
          .help("这一卷是负片还是反转片（幻灯片、正片）：整卷一起切换，可以撤销；扫描、翻拍和导入的卷都一样。反转片不去色罩、不用通道斜率，扫描或翻拍的读数就是画面。反转片当负片转时，片边发白、颜色反着")
        }
        labeled("画幅") {
          Picker("画幅", selection: Binding(get: { m.format }, set: { m.setFormat($0) })) {
            ForEach(FilmFormat.offered(keeping: m.format), id: \.self) { Text($0.rawValue).tag($0) }
          }
          .labelsHidden().frame(maxWidth: .infinity, alignment: .leading).disabled(m.isWorking)
          .help("这一卷的画幅：翻拍的照片按它算画面在胶片上的大小，看片镜的视场和导出的 dpi 跟着它；扫描时按它识别画面。「自动」时翻拍照片的长边按 135 的 36 mm 算")
        }
        // The roll's switches in the order they act: how the pixels are read, then where the
        // channel slopes come from; under them, the slopes they come to. Apart from what the roll
        // is, above, by a rule.
        if m.hasSensorPictures || m.hasLinearPictures || m.profile.offsets != nil || negativeRoll {
          Divider().padding(.vertical, 2)
        }
        if m.hasSensorPictures {
          filmSwitch("去串色 · RGB 光源",
            isOn: Binding(get: { m.crosstalkRemoved }, set: { m.removeCrosstalk($0) }), info: Self.crosstalkInfo)
            .disabled(m.isWorking)
        }
        if m.hasLinearPictures { flatRow }
        if m.profile.offsets != nil {
          filmSwitch(calibrationSwitchTitle, isOn: Binding(get: { m.useCalibration }, set: { m.setUseCalibration($0) }),
            info: calibrationSwitchInfo)
            .disabled(m.isWorking || m.selected == nil)
        }
        if negativeRoll {
          // With the calibration in use the slopes are its own: dimmed and said so.
          VStack(alignment: .leading, spacing: 3) {
            filmSwitch("全卷斜率估计", isOn: Binding(get: { m.estimatesSlopes }, set: { m.setRollSlopeEstimate($0) }),
              info: Self.slopeEstimateInfo)
              .opacity(m.slopeEstimateApplies ? 1 : 0.5)
              .disabled(m.isWorking)
            if !m.slopeEstimateApplies {
              Text("用着标定，斜率来自标定，全卷估计不参与转换")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        Text(conversionBasisShort).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
  /// The flat field from a blank frame: what the selected frame is divided by, and the roll's; the
  /// selected frame taken as a blank, the last flat used again, the flats table.
  var flatRow: some View {
    let selected = m.selected, blanks = m.blankFrameIDs
    let isBlank = selected.map { blanks.contains($0.id) } ?? false
    let kinds = Set(m.frames.compactMap(\.flatID)).subtracting([AppModel.noFlat]).count
    // Pictures a blank's flat could divide that have none, once the roll has one.
    let unflattened = kinds == 0 ? [] : m.frames.filter { $0.flatID == nil && !blanks.contains($0.id) && m.isLinearPicture($0) }
    let blocked = m.flatsBlocked
    let summary: String = {
      guard let selected else { return kinds == 0 ? "这一卷没有" : "全卷 \(kinds) 种" }
      let own = isBlank ? "这张是「\(m.rollFlats.first { $0.sourceFrame == selected.id }?.name ?? "")」的空白帧" : "这张：\(m.flatName(selected))"
      return own + (kinds > 1 ? " · 全卷 \(kinds) 种" : "")
    }()
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text("平场").font(.system(size: 12))
        Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 4)
        InfoButton(text: Self.flatInfo, about: "平场")
      }
      // This picture's flat: switched on or off, which one, and the same for the whole roll.
      if let selected, !isBlank, m.isLinearPicture(selected) {
        let choices = m.flatChoices(for: selected)
        let applied = m.flatApplied(selected), usable = !choices.isEmpty
        SwitchRow("应用平场", isOn: Binding(get: { applied }, set: { m.setFlatApplied($0) }),
          info: "这张照片除不除以平场。关掉：不补；打开：用它那张空白帧的平场，没有时用最近量的、尺寸合适的那个。可以 ⌘Z 撤销。"
            + (usable ? "" : "\n\n现在还没有和这张尺寸一样的平场：先拍一张空白帧，选中它点「设成平场」。"))
          .disabled(!usable || blocked != nil)
        HStack(spacing: 6) {
          Picker("用哪个", selection: Binding(
            get: { selected.flatID.flatMap { $0 == AppModel.noFlat ? nil : $0 } ?? choices.first?.id ?? "" }, set: { m.chooseFlat($0) })) {
            ForEach(choices, id: \.id) { p in Text(p.name).tag(p.id) }
          }
          .labelsHidden().frame(maxWidth: .infinity, alignment: .leading).disabled(!applied || !usable || blocked != nil)
          .help("这张除以哪个平场：这一卷和平场列表里尺寸和它一样的，按名字（空白帧的拍摄时间和光圈）")
          Button("应用到本卷") { m.applySelectedFlatToRoll() }
            .disabled(blocked != nil)
            .help(applied ? "把这张的平场「\(m.flatName(selected))」用到整卷：尺寸不同的照片和空白帧不动" : "整卷都不补平场（空白帧不动），可以 ⌘Z 撤销")
        }
      }
      HStack(spacing: 6) {
        if !unflattened.isEmpty {
          Button("\(unflattened.count) 张没有平场") {
            m.flatsFocus = Set(unflattened.map(\.id))
            m.showFlats = true
          }.foregroundStyle(.orange).help("这些照片还没有按空白帧补平：打开平场表格，它们已经选好")
        }
        Spacer(minLength: 0)
        if let selected, !isBlank, m.isLinearPicture(selected) {
          Button("设成平场") { m.makeFlat(from: selected) }
            .help("把第 \(selected.name) 张当作空白帧（拿走底片，用同样的镜头、光圈、放大倍率和灯拍的）量平场，用到"
              + m.scopeWords(m.blankScope(selected.id)) + "；这张随后取消勾选")
            .disabled(blocked != nil)
        }
        Button("管理…") {
          m.flatsFocus = nil
          m.showFlats = true
        }.help("平场表格：所有平场、每张照片用哪一个，选一组照片换一个")
      }
    }.font(.system(size: 11)).controlSize(.small)
  }
  static let flatInfo = "平场去掉微距镜头的暗角和光源的不匀：四周比中间暗、边上偏色，翻拍时常见，转成正片以后边缘发亮、变色。\n\n做法：拿走底片，片夹或遮罩照旧，用和翻拍完全一样的镜头、光圈、放大倍率和灯拍一张空白帧，曝光到最亮处约 70%（看直方图），不要过曝；像素位移的照片也只要拍一张普通的。选中它，点「设成平场」（胶片条上右键也有）。App 量出它的明暗，把对应的照片逐个颜色通道除一遍，四周就和中间一样亮、一样色。白光、RGB 光源都行；去串色开着关着都行，换的时候跟着换算。\n\n用到哪些：这一卷还没有空白帧时用到整卷；已经有了，就从这张空白帧到下一张空白帧之前（这张之后没有照片时，往前到上一张空白帧之后）。新拍进来的照片跟着最近的一张。空白帧自己不补，会取消勾选，也不算进全卷斜率估计和片基；留着它做分界，或者删掉都行，平场跟着这一卷存着。\n\n换了光圈、对焦距离（放大倍率）、镜头或灯的位置，就再拍一张空白帧。「管理…」打开平场表格：所有平场在上面，这一卷的照片在下面，选一组照片（按住 Shift 或 Command 点选）换成另一个平场或不补。下一卷设置没变时，在「用哪个」里选上次的平场，再点「应用到本卷」。都可以撤销。\n\n片夹遮住的地方（不到最亮处四分之一）不补；尺寸和空白帧不同的照片（裁切模式、转了方向）不补，表格里标出来。扫描仪的扫描有它自己的校正，不用这个。"
  /// A switch of the roll's in the film section: its name, the switch lined up with the others', ⓘ.
  func filmSwitch(_ title: String, isOn: Binding<Bool>, info: String) -> some View {
    SwitchRow(title, isOn: isOn, info: info)
  }
  var calibrationSwitchTitle: String { m.profile.id.contains("-copy-") ? "用翻拍标定" : "用本机标定" }
  /// The roll is converted as negatives, through channel slopes: slides have none.
  var negativeRoll: Bool { m.selected != nil && !m.settings.isSlide }
  static let slopeEstimateInfo = "按整卷所有画面里的明暗过渡估计红、蓝通道的斜率（绿沿用预设），用在没有标定的卷上。斜率的先后：本机标定 → 全卷斜率估计 → 厂家数据表；关掉时是本机标定 → 数据表。\n\n一起估计的是：扫描的画面；一个文件里的整条胶片；一张一个文件的画面（翻拍、一张张导入的扫描）里读法相同（输入 Gamma、位深）的。它们要是同一卷、用同样的设备和设置拍或扫的；至少 2 张有细节的画面才估计得出来，画面越多越准。估计会随画面内容偏：树叶多时蓝偏低，亮的灰越亮越蓝；能标定就标定。\n\n默认：扫描和翻拍的卷打开，一张张导入的单张关着。用着标定时它不参与转换，只在转换依据的 ⓘ 里作对照。「整卷同一白平衡 / 色阶」不受它影响：一张一个文件的画面各自一卷。"
  /// What the calibration switch does, with this preset's own numbers.
  var calibrationSwitchInfo: String {
    let p = m.profile, film = AppModel.uncalibrated(p, among: m.profiles).name
    let points = PresetTable.pointCount(p).map { "这个预设用了 \($0) 个中性点，" } ?? ""
    let roll = m.settings.rollSlopes.map {
      String(format: "本卷全卷斜率估计 R %.3f · B %.3f，标定 R %.3f · B %.3f。", $0.r, $0.b, p.slopes.r, p.slopes.b)
    } ?? ""
    return "打开：按「\(p.name)」的标定转换：三个通道的斜率；标定时那种光下的中性，白平衡按它配平，开着自动也一样；取到很暗的点时还有暗部趾部。\n\n关掉：这一卷按标定之前的胶片 \(film) 转换：斜率在「全卷斜率估计」开着时先用它，没有时用数据表；白平衡回到自动（对齐各通道的黑）或你取的中性灰；不用趾部。预设本身不变，别的卷照旧用它；可以 ⌘Z 撤销，在胶片菜单里重新选这个预设也会打开。\n\n\(points)\(roll)点少、明暗没拉开，或标定和全卷斜率估计差很多时，关掉比较一下。"
  }
  static let crosstalkInfo = "翻拍时相机的红、绿、蓝滤色片和光源的三种灯光谱有重叠：蓝灯有 34% 读进绿通道，绿灯约 12% 和 11% 读进红、蓝。每个通道掺了别的灯的光，转出来颜色发灰，要把饱和度拉到 1.8 左右才像 Capture One。\n\n打开后，从传感器读出的 RAW（无压缩 ARW）在算片基和密度之前，先在线性读数上把串色去掉。矩阵用翻拍页「光源标定」最近测的，没有标定时用 2026-10-29 用 IT8 色卡测的；它属于这台 A7R IV 和这组 RGB 灯，换了相机或灯就要重新标定。白光翻拍时关掉。\n\n整卷一起开关，可以 ⌘Z 撤销；取过的片基和中性灰跟着换算。下一卷沿用这里的选择。\n\n暗角和灯的不匀用「平场」一行里的空白帧补：用了它的照片，开关去串色时按同一张空白帧换算。"
  /// The film base: where it was read in a line, picking it or going back to the automatic one,
  /// and the fine adjustment folded under it.
  var baseSection: some View {
    PanelSection("片基", key: "base", info: "「取片基」只点未曝光的橙色片基（片间或片边），不点景物或片夹；「自动」：扫描的卷按整卷片间的未曝光区；翻拍和一张一个文件导入的照片，按这一张片边的未曝光片基（片边看不到时用最近一张看得到的），都没有时按本张最薄处估计。打开「标出」在单张上看取的是哪里。片边也不准时，在片头或片边取一次片基，点「整卷共用这个片基」，整卷都用它。取片基不改白平衡：自动的照旧自动，取过的中性灰留着。") {
      HStack(spacing: 6) {
        Button {
          m.useTool(.base)
        } label: {
          Label("取", systemImage: CanvasTool.base.symbol)
        }.buttonStyle(KeyStyle(latched: m.tool == .base)).help("取片基：点未曝光的橙色片基 · B")
        Button("自动") {
          m.change("自动片基") {
            $0.base = nil
            $0.basePicked = nil
          }
          m.announceAutoBase()
        }.help("回到自动片基：片间或片边测到的")
      }.font(.system(size: 11))
    } content: {
      VStack(alignment: .leading, spacing: 8) {
        if let f = m.selected {
          HStack(alignment: .firstTextBaseline) {
            Text(m.baseSource(f)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            // Where it was read: picked by hand on this frame, or at the edges of the frame its
            // base came from.
            if f.adjustments.base != nil, f.adjustments.basePicked != nil {
              Toggle("标出", isOn: $m.showBaseAreas).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                .help("在单张上标出手动取片基的地方")
            } else if f.adjustments.base == nil, f.adjustments.rollBasePicked != true,
              let i = m.frames.firstIndex(where: { $0.id == f.id }), let from = m.edgeBaseSource(i)
            {
              Toggle("标出", isOn: $m.showBaseAreas).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                .help(from == i ? "在单张上标出这一张片边里取作片基的地方" : "片基取自第 \(m.frames[from].name) 张的片边；切到那一张能看到标出的地方")
            }
          }
          // A frame whose edge reads apart from the roll's.
          let notes = m.baseNotes(f)
          if !notes.isEmpty {
            Text(notes).font(.system(size: 11)).foregroundStyle(Hardware.amberText).fixedSize(horizontal: false, vertical: true)
          }
        }
        if m.settings.rollBasePicked == true {
          HStack {
            Text("整卷共用手动取的片基").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("取消整卷片基") { m.unshareFilmBase() }.font(.system(size: 11))
          }
        } else if m.settings.base != nil {
          Button("整卷共用这个片基") { m.shareFilmBase() }.font(.system(size: 11))
            .help("把这一张取的片基用于整卷：拍一张片头或片边取片基，整卷共用。片间测不到片基的卷用得着，比如翻拍或一张一个文件导入的卷")
        }
        if let base = m.toneAnalysis?.base ?? m.settings.base ?? m.settings.rollBase {
          Text(String(format: "基准 RGB  %.3f  %.3f  %.3f", base.r, base.g, base.b)).font(
            .system(size: 11, design: .monospaced)
          ).foregroundStyle(.secondary)
        }
      }
    }
  }
  /// The frame's extent and straightening, in the single view; open while the crop tool is.
  var frameSection: some View {
    PanelSection("画面范围", key: "frame", open: false, info: m.selected?.scanPath != nil
      ? "标题旁的「裁切」和画面上方工具条里的一样：按下后在画面上拖动边和角，这里可以逐边微调、还原范围，再按一次结束。\n\n在原扫描范围内无损裁切。要扩大扫描区域，请回接触表调整画框并重扫。\n\n「拉直」让画面绕中心转动（正数顺时针，⌥ 拖动更细），裁去转出的空角，拖动时显示网格线；裁切时按 [ ] 每次 0.1°，加 ⇧ 每次 1°。「画线」后沿地平线、墙边或建筑竖线拖一条线，松手就按它拉直（裁切时按住 ⌥ 拖也一样）。接触表上的画框仍按胶片原样显示，拉直后保留的部分用虚线框标出。"
      : "画框周围保留了片基，可在单张中细调裁切，不会跳回接触表。\n\n标题旁的「裁切」和画面上方工具条里的一样：按下后在画面上拖动边和角，这里可以逐边微调、还原范围，再按一次结束。\n\n翻拍的照片可以「自动裁切」：找出片框的四条边（片边或片间的片基转入画面的地方），裁到画面以内一点，并按边拉直；「本张」只裁这一张，「整卷」整卷一起裁。同一卷翻拍时放大倍率不变，每张的画面大小差不多：哪张的一条边找错了（比如画面底部有一大片和片基一样淡的阴影，它的直边被当成了片框），就按其他张的画面大小改正。片框的边伸出照片的那一侧，裁在照片的边上。\n\n「拉直」让画面绕中心转动（正数顺时针，⌥ 拖动更细），裁去转出的空角，拖动时显示网格线；裁切时按 [ ] 每次 0.1°，加 ⇧ 每次 1°。「画线」后沿地平线、墙边或建筑竖线拖一条线，松手就按它拉直（裁切时按住 ⌥ 拖也一样）。接触表上的画框仍按胶片原样显示，拉直后保留的部分用虚线框标出。",
      forced: m.tool == .crop || m.tool == .region
    ) {
      // In the title, open or not: the crop key, which opens the section while cropping.
      cropKey
    } content: {
      VStack(alignment: .leading, spacing: 8) {
        if let f = m.selected, m.isSinglePicture(f) {
          HStack(spacing: 6) {
            Text("自动裁切").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("本张") { m.autoCrop(roll: false) }.font(.system(size: 11))
              .help("按片框的四条边裁到画面以内，并按边拉直。⌘Z 撤销，原文件不改")
            Button("整卷") { m.autoCrop(roll: true) }.font(.system(size: 11))
              .help("整卷每张都按片框自动裁切；哪张的边找错了，按其他张的画面大小改正。⌘Z 撤销，原文件不改")
          }
        }
        // The crop's shape, as Lightroom's 长宽比: kept while its corners and edges are dragged.
        HStack {
          Text("比例").font(.system(size: 12)).foregroundStyle(.secondary)
          Spacer()
          Picker("", selection: Binding(get: { m.cropRatio }, set: { m.setCropRatio($0) })) {
            ForEach(AppModel.CropRatio.allCases) { r in
              Text(r == .twoThree ? "2:3（135）" : r == .square ? "1:1（6×6）" : r == .sixSeven ? "6:7（6×7）" : r == .threeFour ? "3:4（6×4.5）" : r.rawValue).tag(r)
            }
          }.labelsHidden().fixedSize()
            .help("裁切的长宽比：选了以后画面范围马上变成这个比例（在现在的范围里取最大的一块，居中），拖角、拖边、拖新框都保持它；横竖跟着现在的裁切。自由不限")
        }
        VStack(spacing: 3) {
          HStack {
            Text("拉直").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            ValueField(title: "拉直", text: sliderText("%+.2f°", m.screenAngle), value: m.screenAngle, range: -45...45) {
              m.straighten($0)
            }
            Button("画线") {
              m.useTool(.crop)
              m.levelling = true
            }
            .font(.system(size: 11)).help("沿地平线、墙边或建筑竖线拖一条线，按它拉直（裁切时也可以按住 ⌥ 拖）")
            Button("归零") { m.straighten(0) }.font(.system(size: 11)).disabled(m.settings.angle == nil)
          }
          Fader(title: "拉直", value: Binding(get: { m.screenAngle }, set: { m.straighten($0) }), range: -45...45, detent: 0)
        }
        if m.tool == .crop, let crop = m.canvasCrop {
          ForEach(0..<4, id: \.self) { edge in cropStepper(edge, crop: crop) }
          Button("还原范围") { m.resetCrop() }.font(.system(size: 11))
        }
        if m.page != .capture { regionRow }
      }
    }
  }
  /// The de-masking region, under the picture's crop: what it is, its key, and back to following
  /// the picture.
  var regionRow: some View {
    let region = m.settings.analysisRegion, cyan = CanvasTool.region.colour.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
    return VStack(alignment: .leading, spacing: 4) {
      Divider()
      // Its name on one line: in the narrowest sidebar it wrapped beside its keys, the keys
      // going under it there instead.
      let name = Label("去色罩区域", systemImage: CanvasTool.region.symbol).font(.system(size: 12)).foregroundStyle(cyan ?? .primary)
        .lineLimit(1).fixedSize()
      let keys = HStack(spacing: 6) {
        Button {
          m.useTool(m.tool == .region ? .select : .region)
        } label: {
          Text(m.tool == .region ? "完成" : "框选").lineLimit(1).fixedSize()
        }.buttonStyle(KeyStyle(latched: m.tool == .region)).font(.system(size: 11)).disabled(m.selected == nil)
          .help("在画面上拖出青色的框：片基估计、白平衡和色阶只看框里 · M")
        Button("跟随画面") { m.setAnalysisRegion(nil) }.font(.system(size: 11)).disabled(region == nil)
          .help("不再单独框选：按画面裁切，去掉四边 5%；裁切里带着片边时只看片边以内")
      }
      WidthFit {
        HStack(spacing: 6) { name; Spacer(); keys }
      } compact: {
        VStack(alignment: .leading, spacing: 4) { name; keys }
      }
      Text(region.map { String(format: "框选了画面的 %.0f%%：片基估计、白平衡、色阶和高光只看青色框里，显示和导出仍按琥珀色的画面裁切", $0.width * $0.height * 100) }
        ?? (m.toneAnalysis?.followed.map { String(format: "跟随画面裁切：裁切里带着片边（片基、齿孔、边字），只看片边以内的 %.0f%%（青色虚线）。要避开漏光或一大片天空，框选只想让去色罩看的地方", $0.width * $0.height * 100) }
          ?? "跟随画面裁切（去掉四边 5%；裁切里带着片边时只看片边以内）。要避开漏光、片夹或一大片天空，框选只想让去色罩看的地方"))
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
  /// The crop tool, as on the bar over the picture: latched while cropping, pressed again to finish.
  /// ③'s crop and straightening, as Lightroom's crop overlay in Develop (R): the picture cropped
  /// and turned inside the frame ② cut, the de-masking left reading ②'s, so the colours stay.
  var compositionSection: some View {
    let composing = m.composing
    return PanelSection("裁切与拉直", key: "composition", open: false,
      info: "像 Lightroom 修改照片里的裁切（R）：按「裁切」或 R 后，画面在它自己的范围里转着显示，琥珀色的框保持正的。拖四角和边改大小，框里拖动移动，框外拖动旋转画面，框始终留在画面上，转出的空角不会进来；按住 ⇧ 拖角保持现在的比例，⌥ 拖一条线按它拉直，X 横竖互换，O 换叠加线（三分、网格、黄金分割、对角线），方向键移动一点，回车或再按 R 完成。\n\n这里只管构图：在 ② 定的画面范围里裁，去色罩的片基、白平衡和色阶照旧读 ② 的范围，裁切、旋转都不会让颜色变。要把片边或更大的扫描范围放进来，在 ② 的「画面范围」里改。拉直和 ② 的是同一个角度，最多 ±45°。「还原」回到整幅画面、不拉直。",
      forced: composing
    ) {
      Button {
        m.useTool(m.tool == .crop ? .select : .crop)
      } label: {
        Label {
          Text(composing ? "完成" : "裁切")
        } icon: {
          Image(systemName: CanvasTool.crop.symbol).foregroundStyle(CanvasTool.crop.colour.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .primary)
        }.lineLimit(1).fixedSize()
      }
      .buttonStyle(KeyStyle(latched: composing)).font(.system(size: 11)).disabled(m.selected == nil)
      .help(composing ? "完成裁切 · R 或回车" : "裁切和旋转画面，颜色不变 · R")
    } content: {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("比例").font(.system(size: 12)).foregroundStyle(.secondary)
          Spacer()
          Picker("", selection: Binding(get: { m.cropRatio }, set: { m.setCropRatio($0) })) {
            ForEach(AppModel.CropRatio.allCases) { r in
              Text(r == .twoThree ? "2:3（135）" : r == .square ? "1:1（6×6）" : r == .sixSeven ? "6:7（6×7）" : r == .threeFour ? "3:4（6×4.5）" : r.rawValue).tag(r)
            }
          }.labelsHidden().fixedSize()
            .help("裁切的长宽比：选了以后框马上变成这个比例（在现在的框里取最大的一块，居中），拖角、拖边都保持它。自由不限，拖角时按住 ⇧ 保持现在的比例")
          Button("横竖互换") { m.swapCompositionOrientation() }.font(.system(size: 11)).disabled(m.selected == nil)
            .help("框的长边和短边互换，绕中心，放不下时缩小 · X")
        }
        VStack(spacing: 3) {
          HStack {
            Text("拉直").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            ValueField(title: "拉直", text: sliderText("%+.2f°", m.screenAngle), value: m.screenAngle, range: -45...45) {
              m.straighten($0)
            }
            Button("画线") {
              m.useTool(.crop)
              m.levelling = true
            }
            .font(.system(size: 11)).help("沿地平线、墙边或建筑竖线拖一条线，按它拉直（裁切时也可以按住 ⌥ 拖）")
            Button("归零") { m.straighten(0) }.font(.system(size: 11)).disabled(m.settings.angle == nil)
          }
          Fader(title: "拉直", value: Binding(get: { m.screenAngle }, set: { m.straighten($0) }), range: -45...45, detent: 0)
        }
        HStack {
          Text("叠加").font(.system(size: 12)).foregroundStyle(.secondary)
          Spacer()
          Picker("", selection: $m.cropOverlay) {
            ForEach(AppModel.CropOverlay.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }.labelsHidden().fixedSize().help("裁切时框里画的线 · O 换下一种")
          Button("还原") { m.resetComposition() }.font(.system(size: 11))
            .disabled(m.settings.composition == nil && m.settings.angle == nil)
            .help("回到整幅画面，不拉直 · ⌘Z 撤销")
        }
        if let f = m.selected, let px = m.exportPixels(f) {
          Text(String(format: "导出 %.0f × %.0f 像素", px.width, px.height) + (m.settings.composition == nil ? "" : " · 已裁切"))
            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
      }
    }
  }
  var cropKey: some View {
    Button {
      m.useTool(m.tool == .crop ? .select : .crop)
    } label: {
      Label {
        Text("裁切")
      } icon: {
        Image(systemName: CanvasTool.crop.symbol).foregroundStyle(CanvasTool.crop.colour.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .primary)
      }.lineLimit(1).fixedSize()
    }
    .buttonStyle(KeyStyle(latched: m.tool == .crop)).font(.system(size: 11)).disabled(m.selected == nil)
    .help(m.tool == .crop ? "结束裁切 · C" : "在画面上裁切：拖动边和角，边栏里可以逐边微调 · C")
  }
  /// Whether the frame's white balance is the calibrated preset's neutral (`AppModel.balancesByCalibration`).
  var balancesByCalibration: Bool { m.balancesByCalibration }
  /// White balance: automatic or by hand, the roll as one, and the points picked on the frame.
  var balanceSection: some View {
    PanelSection("白平衡", key: "balance", info: "自动白平衡按画面估计，忽略外缘 5%（不改变导出范围），裁切里带着片边（片基、齿孔、边字）时只看片边以内；在「画面范围」里框选了去色罩区域时，只按青色框里估计。用本机或翻拍标定的预设时不按画面估计，按标定时记下的中性配平；这个中性是在标定时的光下定的（比如阳光），阴天、树荫、室内的照片会带上光的颜色，用「中性灰」或冷暖、绿 / 洋红调。\n\n「阴影冷暖」「阴影色调」只动暗部（亮度 0.2 最多，0.55 以上和纯黑不动），阳光下的灰不变：晴天的阴影由蓝天照亮，本来就偏蓝，阴影冷暖往右拨把它暖回来；远处的雾气、只有蓝层曝了光的阴影常常蓝里带紫，再把阴影色调往左（绿）拨；它只去掉相反的偏色，往绿只动偏紫的暗处，草和中性的沙不变。「阴影中性」用滴管点阴影里应为灰色的地方（背光的水泥、路面、石头），两个一起按它设定，之后还能拖滑块微调；点在树林这类本身有颜色的东西上会把它也变成灰。\n\n右上角的选单和 Lightroom 的白平衡一样：「原片」是胶片转换本来的样子，不按画面配平（负片只除片基，用标定预设时是标定的中性，反转片是片子本来的颜色）；「自动」按画面估计；取中性灰、拖冷暖或绿 / 洋红就是「自定义」。选原片或自动时，放弃取的中性灰，冷暖、绿 / 洋红归零，阴影冷暖、阴影色调和片基不动；⌘Z 撤销。\n\n「中性灰」用滴管点画面中应为灰色的地方，按这一点白平衡（变成自定义）；滴管也在画面上方的工具条里（N）。取过点以后旁边出现「清除取样」：放弃取样点，回到按画面估计，标定预设回到标定的中性；冷暖、绿 / 洋红和片基不动。\n\n反转片：片子本来的颜色就是画面，默认不自动白平衡，透过片子最亮处的光就是白。选「自动」时每个通道各自从最暗拉到最亮，适合褪色、偏色的片子；选「原片」回到片子本来的颜色。「中性灰」把那一点配成灰。「清除取样」放弃取样点，回到片子本来的颜色。", reset: resetKey(.balance)) {
      // As Lightroom's 白平衡 menu: 原片, 自动, 自定义; a grey picked or 冷暖 / 绿洋红 moved shows
      // 自定义, and 原片 or 自动 chosen sets them back to 0.
      // A narrow menu, as Lightroom's 「白平衡：原片 ▾」, so the section's name keeps its room.
      Menu {
        Button(m.balancesByCalibration ? "原片（标定的中性）" : "原片") { m.setBalanceMode(.asShot) }
        if !m.balancesByCalibration { Button("自动") { m.setBalanceMode(.auto) } }
        Button("自定义") { m.setBalanceMode(.custom) }
      } label: {
        Text(m.balanceMode == .asShot && m.balancesByCalibration ? "标定" : m.balanceMode.rawValue).font(.system(size: 11))
      }
      .menuStyle(.borderlessButton).fixedSize().disabled(m.selected == nil)
      .help(m.balancesByCalibration
        ? "原片：按标定预设记下的中性配平，放弃取的中性灰，冷暖、绿 / 洋红归零。自定义：取中性灰，或拖冷暖、绿 / 洋红。⌘Z 撤销"
        : m.settings.isSlide
          ? "原片：片子本来的颜色。自动：每个通道各自从最暗拉到最亮，适合褪色、偏色的片子。自定义：取中性灰，或拖冷暖、绿 / 洋红。选原片或自动时冷暖、绿 / 洋红归零。⌘Z 撤销"
          : "原片：只除片基，不按画面配平。自动：按画面估计（对齐各通道的黑）。自定义：取中性灰，或拖冷暖、绿 / 洋红。选原片或自动时放弃取的中性灰，冷暖、绿 / 洋红归零；阴影冷暖、阴影色调不动。⌘Z 撤销")
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        // A picture that is a file each has no roll to share with, and a calibrated preset balances
        // every frame by its one neutral already: shown then only to turn it off.
        if !m.settings.isSlide && ((m.selectedSharesRoll && !balancesByCalibration) || m.settings.sharedBalance == true) {
        SwitchRow("整卷同一白平衡", isOn: Binding(get: { m.settings.sharedBalance == true }, set: { m.setSharedBalance($0) }),
          info: "像冲印店印一卷那样，整卷用同一个配光：白平衡按整卷所有画面一起统计，卷里每张的颜色一致，不再各自按自己的暗部去配平（比如阴影里的天光不会把一张整体拉偏）。每张的明暗照旧。\n\n只替换交给软件的部分：哪一张取了中性灰，那一张按你的来。用标定预设时，白平衡本来就按标定的中性，整卷一致。",
          off: m.selected == nil || m.isWorking)
        }
        slider("冷暖", key: \.warmth, range: -1...1)
        slider("绿 / 洋红", key: \.tint, range: -1...1)
        slider("阴影冷暖", key: \.shadowWarmthAmount, range: -1...1)
        slider("阴影色调", key: \.shadowTintAmount, range: -1...1)
        // The picker, latched while in use and marked once a point is picked (the same picker lies
        // over the picture), and what lets the point go once there is one.
        HStack(spacing: 6) {
          Text("取样").font(.system(size: 12)).foregroundStyle(.secondary)
          Button {
            m.useTool(.neutral)
          } label: {
            // Picked: a tick for the dropper (the full dropper is the base's), the name as wide as before.
            Label("中性灰", systemImage: m.settings.neutralSample != nil ? "checkmark.circle" : CanvasTool.neutral.symbol)
          }.buttonStyle(KeyStyle(latched: m.tool == .neutral)).help("取中性灰：点画面中应为灰色的地方 · N")
          Button {
            m.useTool(.shadowNeutral)
          } label: {
            Label("阴影中性", systemImage: CanvasTool.shadowNeutral.symbol)
          }.buttonStyle(KeyStyle(latched: m.tool == .shadowNeutral)).disabled(m.selected == nil)
            .help("阴影中性：点阴影里应为灰色的地方（背光的水泥、路面、石头），按它设定阴影冷暖和阴影色调，亮处不变")
          if m.settings.neutralSample != nil {
            Spacer(minLength: 2)
            // A key of its own, so the two pickers keep their names beside it.
            Button {
              m.clearBalanceSamples()
            } label: {
              Image(systemName: "arrow.uturn.backward.circle")
            }.buttonStyle(.borderless).foregroundStyle(.secondary).font(.system(size: 13))
              .help("清除取样：" + (m.settings.isSlide ? "放弃取样点，回到片子本来的颜色" : "放弃中性灰取样点，回到自动白平衡"))
              .accessibilityLabel("清除取样")
          }
        }.font(.system(size: 11)).lineLimit(1).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
  /// Exposure and the tones, over the frame's histogram against what a screen shows.
  var toneSection: some View {
    PanelSection("影调", key: "tone", info: "曝光像放大时的印放曝光一样调整密度，在裁切前生效；−EV 可以找回高光。\n\n高光、阴影、白色、黑色和 Lightroom 的四个滑杆一样，都在剪切之前起作用：往回拉时，白点以上、黑以下的东西能拉回来。每个都给三个通道加减同样多（相当于那一处的曝光），颜色不变，明暗顺序也不会颠倒。\n\n高光、阴影看的是每处周围有多亮：大块的亮处（云、白墙、路牌）或暗处整块变暗、变亮，里面的纹理按原来的反差留着；明显的边上不出光晕。高光往左压暗亮处、找回层次，0.45 以下不动；阴影往右提亮暗处，黑本身不动。\n\n白色、黑色管两端，按每个像素自己最亮、最暗的通道：白色往左把最亮的一端整体拉下来（超出白的拉回来），往右推更多到白；黑色往左压深最暗的一端，往右提起来。\n\n以前的「压高光」已经并进白色：旧工程里压高光 p 读成白色 −p。", reset: resetKey(.tone)) {
      VStack(alignment: .leading, spacing: 10) {
        // In the single view, the frame's tones against what an ordinary screen shows of them.
        if let range = m.toneRange {
          HStack {
            Text("直方图").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            InfoButton(text: "屏幕上最终显示的这张：横轴从纯黑（0）到纯白（255），三条颜色是红、绿、蓝。所有调整都算在内（曝光、对比度、高光、阴影、白色、黑色、柔和的两端、中间调、曲线），拖哪个滑杆它都跟着变。左右两头有白条时，表示有像素切成了纯黑或纯白。\n\n下面几行说的是底片里比屏幕更多的东西：「白点以上」是有多少落在色阶的白点以上（屏幕上靠柔和的肩部收进来，或者切成白），「最亮的 0.1%」在白点以上几档；想把它们拉回来，用「白色」「高光」往左或「曝光」往负。「纯白」「纯黑」按屏幕上这张实际的像素数，有一个通道到顶或到底就算。\n\n纵向按平方根画，少量的高光也看得见。按整张的每个像素计数，只算裁切以内。")
          }
          ToneRangeView(range: range)
        }
        slider("曝光 · EV", key: \.exposure, range: -2...2, format: "%+.2f")
        slider("对比度", key: \.contrast, range: 0.5...1.6)
        slider("高光", key: \.highlightsAmount, range: -1...1, format: "%+.2f")
        slider("阴影", key: \.shadowsAmount, range: -1...1, format: "%+.2f")
        slider("白色", key: \.whitesAmount, range: -1...1, format: "%+.2f")
        slider("黑色", key: \.blacksAmount, range: -1...1, format: "%+.2f")
        if m.toneRange != nil && !m.settings.isSlide {
          HStack {
            Spacer()
            Button("自动白色、黑色") { m.autoWhitesBlacks() }
              .controlSize(.small)
              .help("像 Lightroom 里按住 Shift 双击「白色」「黑色」：把这张最亮的 0.1% 正好放到白、最暗的 0.1% 正好放到黑，不多切也不少用；只改这两个滑杆，可以 ⌘Z 撤销")
              .disabled(m.isWorking)
          }
        }
      }
    }
  }
  /// The ends: automatic, the roll as one, or set by hand.
  var levelsSection: some View {
    PanelSection("色阶", key: "levels", info: "自动：按画面的密度范围设定黑白两端。范围不到 4 档的画面（雾、霾、很平的光）不拉满到黑和白，以中间为准撑开到 4 档，保留它本来的灰和柔；要更硬，调「对比度」或关掉自动。两端之后再用「影调」里的白色、黑色（或「自动白色、黑色」）微调，中间调用曲线。\n\n「整卷同一色阶」：整卷用同一组黑白两端，按整卷所有画面一起统计，像冲印店一卷用一个印放曝光：暗的场景就是暗的，亮的就是亮的。每张仍可以用「曝光」微调。关了自动色阶的那一张按你的来。\n\n反转片：自动把最暗的 0.5% 定为黑、最亮的 0.5% 定为白，三个通道用同一对两端，颜色不变；关掉时扫描仪的裸光是白，片子显示得和看片台上一样暗。", reset: resetKey(.levels)) {
      Toggle("自动", isOn: bool(\.autoLevels)).toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 11))
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        if !m.settings.isSlide && (m.selectedSharesRoll || m.settings.sharedLevels == true) {
          SwitchRow("整卷同一色阶", isOn: Binding(get: { m.settings.sharedLevels == true }, set: { m.setSharedLevels($0) }),
            off: m.selected == nil || m.isWorking)
        }
      }
    }
  }
  var colourSection: some View {
    PanelSection("色彩", key: "colour", info: "纹理、清晰度、去朦胧、自然饱和度和 Lightroom 的「外观」一样，在转换之后起作用：纹理加强最细的起伏（皮肤、树叶、颗粒），清晰度加强中等尺度的局部反差，主要在中间调，黑和白不动；两个都给三个通道加减一样多，颜色不变，往左就是柔化。去朦胧按每处最暗的通道估出一层白雾，往右把它去掉，远景变深、颜色回来；往左加一层淡雾。自然饱和度只加不太鲜艳的颜色，已经很鲜艳的和肤色加得少；「饱和度」是所有颜色一起加。\n\n色彩降噪只平滑颜色、不动明度：传感器和去串色带来的彩色噪点（尤其是蓝黄）会去掉，胶片颗粒的明暗结构保留。翻拍的照片默认 1。\n\n柔和的暗部和高光：最暗的地方不硬切成纯黑，而是平滑地压下去，暗部的颜色和层次因此保留下来，并略微补一点暗部的饱和度；最亮的地方用柔和的肩部收向白，不硬顶到白。高光超出白点较多的画面，肩部按这张最亮的 0.1% 伸长（最多两档），阳光下的白边、亮云在普通屏幕上也留着层次；亮颜色收下来时颜色不变：最亮的通道走肩部，另外两个保持原来的距离，所以朝天空和朝太阳的两面白墙仍分得出冷暖，也不截掉一个通道；只有比这张最亮的 0.1% 还亮的地方才褪成白。肩部只收大块的明暗：白里的纹理和明暗过渡（路牌的白底、受光的金属杆）按原来的反差加回去，亮处不发平；暗的树叶到白路牌这种明显的边不算细节，边上不会出亮边。像相纸那样，中间段不变。", reset: resetKey(.colour)) {
      VStack(alignment: .leading, spacing: 10) {
        slider("纹理", key: \.textureAmount, range: -1...1, format: "%+.2f")
        slider("清晰度", key: \.clarityAmount, range: -1...1, format: "%+.2f")
        slider("去朦胧", key: \.dehazeAmount, range: -1...1, format: "%+.2f")
        slider("自然饱和度", key: \.vibranceAmount, range: -1...1, format: "%+.2f")
        slider("饱和度", key: \.saturation, range: 0...1.8)
        slider("色彩降噪", key: \.colourNoiseAmount, range: 0...2)
        // The soft ends are a negative's print: a slide or a positive file goes straight to its ends.
        if m.settings.inputIsNegative {
          SwitchRow("柔和的暗部和高光", isOn: bool(\.softEndsOn))
        }
      }
    }
  }
  /// Lightroom's colour mixer: one kind of move (hue, saturation, luminance) at a time, a slider for
  /// each of the eight hues; folded until wanted.
  var mixerSection: some View {
    PanelSection("混色器", key: "mixer", open: false, info: "和 Lightroom 的混色器（HSL）一样：八种颜色各自改色相（左右各最多 30°）、饱和度和明度，灰的东西不动，颜色越鲜艳改得越多。上面切色相、饱和度、明度。在转换之后、曲线之前起作用。", reset: resetKey(.mixer)) {
      VStack(alignment: .leading, spacing: 8) {
        Picker("", selection: $mixerKind) {
          ForEach(0..<3, id: \.self) { Text(ColourMixer.kinds[$0]).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
        ForEach(0..<ColourMixer.bands.count, id: \.self) { band in
          // The colour alone beside its track (the tab above says what moves); its full name for undo.
          slider("\(ColourMixer.bands[band].name) · \(ColourMixer.kinds[mixerKind])", key: \Adjustments.[mixer: band, kind: mixerKind], range: -1...1, format: "%+.2f",
            gradient: ColourMixer.track(band: band, kind: mixerKind), label: ColourMixer.bands[band].name)
        }
      }
    }
  }
  /// Lightroom's colour grading: a wheel each for the shadows, midtones and highlights, balance and
  /// blending under them; folded until wanted.
  var gradingSection: some View {
    PanelSection("色彩分级", key: "grading", open: false, info: "和 Lightroom 的色彩分级一样：阴影、中间调、高光各有一个色轮，拖动的方向是色相，离中心越远越浓；双击回到中心。明暗不变，只加颜色。「平衡」把阴影和高光的分界往暗或往亮挪，「混合」决定三段重叠多少。在转换之后、曲线之前起作用。", reset: resetKey(.grading)) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 8) {
          ForEach(0..<3, id: \.self) { part in
            let keys: [(WritableKeyPath<ColourGrading, Double>, WritableKeyPath<ColourGrading, Double>, String)] = [
              (\.shadowHue, \.shadowAmount, "阴影"), (\.midHue, \.midAmount, "中间调"), (\.highHue, \.highAmount, "高光")]
            GradingWheel(name: keys[part].2,
              hue: Binding(get: { m.settings[grading: keys[part].0] }, set: { v in m.change("色彩分级 · \(keys[part].2)") { $0[grading: keys[part].0] = v } }),
              amount: Binding(get: { m.settings[grading: keys[part].1] }, set: { v in m.change("色彩分级 · \(keys[part].2)") { $0[grading: keys[part].1] = v } }))
          }
        }
        slider("平衡", key: \Adjustments.[grading: \ColourGrading.balance], range: -1...1, format: "%+.2f")
        slider("混合", key: \Adjustments.[grading: \ColourGrading.blending], range: 0...1)
      }
    }
  }
  /// The curves, over the picture's histograms channel by channel; folded until wanted, and marked
  /// when they change the picture.
  var curvesSection: some View {
    PanelSection("曲线", key: "curves", open: false, info: CurveEditor.info) {
      if m.curvesBypassed {
        Text("暂不显示").font(.system(size: 11)).foregroundStyle(Hardware.amberText)
      } else if m.settings.curves != nil {
        Text("已调整").font(.system(size: 11)).foregroundStyle(Hardware.amberText)
      }
    } content: {
      CurveEditor(
        curves: Binding(
          get: { m.settings.curves ?? ToneCurves() },
          set: { value in
            m.change("曲线") { $0.curves = value.normalized }
            m.curveState.edits &+= 1
          }),
        histogram: m.histogram, channels: m.channelHistograms, state: m.curveState,
        targeting: Binding(get: { m.tool == .curve }, set: { m.tool = $0 ? .curve : .select }),
        bypassed: Binding(get: { m.curvesBypassed }, set: { m.curvesBypassed = $0 }),
        picking: Binding(get: { m.tool == .curvePick }, set: { m.useTool($0 ? .curvePick : .select) }),
        pickMode: Binding(get: { m.preferences.curvePick }, set: {
          m.preferences.curvePick = $0
          m.objectWillChange.send()
        }),
        settled: { m.fadeInNextPicture() },
        holding: { on in on ? m.windowGate.hold() : m.windowGate.release() })
    }
  }
  /// Per-frame deconvolution strength: a scan's by the scanner's measured profile, once there is
  /// one; a camera copy's by the copy stand's camera's, measured on the resolution target, its
  /// default by its shots and magnification.
  var sharpeningSection: some View {
    let frame = m.selected
    let shots = frame.flatMap(Sharpening.copyShots)
    let usable = shots != nil || m.preferences.sharpening != nil
    let strength = frame.map(m.sharpeningStrength) ?? 0
    let fallback = frame.map { f in shots.map { Sharpening.copyDefault($0, magnification: m.copyMagnification(f)) } ?? (f.sourcePath != nil ? 0 : Sharpening.defaultStrength) } ?? 0
    let info: String
    if let shots {
      let magnification = frame.flatMap(m.copyMagnification).map { String(format: "，约 %.2f 倍", $0) } ?? ""
      info = "翻拍按相机实测的模糊在线性数据上反卷积：A7R IV 和适马 70mm 微距在 f/4.5 下约 1.4 个传感器像素，在分辨率标靶上量出（0.39 倍和 0.96 倍一样大），所以同一份配置用于任何放大倍率。\n\n默认强度按合成方式：单张 20%、像素位移 4 张 30%、16 张 40%；放大倍率低于约 0.55 倍时再少 10%，那时胶片颗粒正好落在锐化提升最多的那一段。16 张的默认能拿回相机模糊掉的大部分细节（MTF50 提高约一半），暗部噪点仍不比不锐化的单张多；单张本来噪点和伪色就多，加得少些。再往上加，清晰度涨得慢，噪点涨得快。\n\n这一张：\(shots.title)\(magnification)。"
    } else if m.preferences.sharpening == nil {
      info = "在 ① 采集 · V850 的「扫描仪锐化」导入一张分辨率标靶的扫描，测出这台扫描仪的 MTF 后可用。翻拍的照片用相机自己的配置，不用这个。"
    } else {
      info = "按扫描仪实测的 MTF 在线性扫描数据上反卷积；默认温和，推到 0 关闭。导入的图像默认不锐化，它们可能来自其他扫描仪或相机。"
    }
    return PanelSection("锐化", key: "sharpening", open: false, info: info) {
      if !usable {
        Text("未配置").readout()
      } else {
        ValueField(title: "锐化强度", text: strength == 0 ? "关" : "\(Int((strength * 100).rounded()))%", value: strength, range: 0...1, scale: 100) { v in
          m.change("锐化") { $0.sharpening = v }
        }.disabled(m.selected == nil)
      }
    } content: {
      if usable {
        VStack(alignment: .leading, spacing: 4) {
          Fader(
            title: "锐化强度",
            value: Binding(get: { strength }, set: { v in m.change("锐化") { $0.sharpening = v } }),
            range: 0...1, detent: fallback)
          if let shots {
            Text("相机配置 · \(shots.title) · 默认 \(Int((fallback * 100).rounded()))%").font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }
      } else {
        Text("还没有这台扫描仪的锐化配置。").font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }
  /// How the file is read: as a negative or already positive, and its encoding.
  /// Whether how the frame is read is the user's to say: a file imported, whose encoding the app
  /// cannot know. Scans and the camera's readings are linear negatives (or the roll's slides) as
  /// made; shown on them too once their gamma was changed, to set it back.
  var readsAnImport: Bool { m.selected?.format == "导入" || m.settings.inputGamma != 1 }
  var inputSection: some View {
    PanelSection("输入设置", key: "input", open: false, info: "导入的文件编码未知，在这里说怎么读：已经反相的正片关掉「负片去色罩 / 反相」，输入 Gamma 是文件的编码（线性为 1.0，常见的 2.2）。本程序的扫描和相机读数本来就是线性负片，不显示这一节；反转片按 ② 胶片里的「本卷片种」。") {
      if !m.settings.inputIsNegative {
        Text(m.settings.isSlide ? "反转片" : "不反相").font(.system(size: 11)).foregroundStyle(Hardware.amberText)
      }
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        // A slide is the roll's 片种 to say, not a switch of its own.
        if !m.settings.isSlide {
          SwitchRow("负片去色罩 / 反相", isOn: bool(\.inputIsNegative))
        }
        slider("输入 Gamma", key: \.inputGamma, range: 1...3)
      }
    }
  }
  func cropStepper(_ edge: Int, crop: NormalRect) -> some View {
    let names = ["左", "上", "右", "下"]
    let values = [crop.x, crop.y, crop.x + crop.width, crop.y + crop.height]
    return HStack {
      Text(names[edge]).font(.system(size: 12))
      Spacer()
      Text(String(format: "%.1f%%", values[edge] * 100)).font(
        .system(size: 11, design: .monospaced))
      Button {
        m.adjustCropEdge(edge, delta: -0.001)
      } label: {
        Image(systemName: "minus")
      }.help("\(names[edge])边 −0.1%").accessibilityLabel("\(names[edge])边减 0.1%")
      Button {
        m.adjustCropEdge(edge, delta: 0.001)
      } label: {
        Image(systemName: "plus")
      }.help("\(names[edge])边 +0.1%").accessibilityLabel("\(names[edge])边加 0.1%")
    }.controlSize(.mini).disabled(m.isWorking || m.rendering)
  }
  /// A new status shows for a few seconds, then the line folds away unless work is under way; an
  /// export just done stays longer, for its files to be shown in Finder.
  func showStatus() {
    statusShown = true
    statusChange += 1
    let change = statusChange
    let shown: Double = m.exported?.status == m.activityStatus ? 20 : 6
    DispatchQueue.main.asyncAfter(deadline: .now() + shown) { if statusChange == change { statusShown = false } }
  }
  /// The status line: while something is under way, an update waits, or a while after it changed.
  var footerShown: Bool {
    statusShown || m.exporting || m.scanBatch.isActive || m.scanner.busy || m.updater.release != nil
  }
  var filmstrip: some View {
    VStack(spacing: 0) {
      // Ticking frames for a batch belongs to capturing; elsewhere the strip's menu and the 画面
      // menu tick them, and unticked frames lie dimmed.
      if m.page == .capture { tickRow }
      stripScroller
    }
  }
  var tickRow: some View {
      HStack(spacing: 12) {
        Toggle(
          "勾选当前",
          isOn: Binding(
            get: { m.selected?.enabled ?? false },
            set: { value in
              if let id = m.selectedID { m.setEnabled(id, enabled: value) }
            })
        )
        .toggleStyle(.switch).tint(Hardware.accent).disabled(m.selected == nil || m.isWorking)
        .help("勾选这一张用于扫描和导出。胶片条上没勾选的变暗；也可以在胶片条上右键勾选")
        Divider().frame(height: 14)
        Button("全部勾选") { m.setAllEnabled(true) }
          .disabled(m.frames.isEmpty || m.enabledCount == m.frames.count || m.isWorking)
          .help("勾选当前工程中的全部照片，用于批量扫描和导出")
        Button("全部不勾选") { m.setAllEnabled(false) }
          .disabled(m.enabledCount == 0 || m.isWorking)
          .help("取消全部扫描和导出勾选；不删除照片、不切换当前画面")
        Text("已选 \(m.enabledCount) / \(m.frames.count)").readout()
        Spacer()
        // On the copy stand, with no canvas to take the delete key, the strip deletes the pictures.
        if cameraStage {
          Button {
            m.removeSelected()
          } label: {
            Label("删除", systemImage: "trash")
          }.disabled(m.selected == nil || m.isWorking)
            .help("从这一卷删除当前这张，⌘Z 可以撤销；原文件留在这一卷的文件夹里。也可以在胶片条上右键某一张删除")
        }
      }.font(.system(size: 11)).controlSize(.mini).buttonStyle(.bordered)
        .padding(.horizontal, 18).padding(.top, 7).padding(.bottom, 2)
  }
  /// Lightroom's marks from the film strip's menu: on the frames chosen together (`nil`), or on
  /// `frame` alone, shown first.
  func marksMenu(_ frame: FilmFrame?) -> some View {
    let show = { if let frame, frame.id != m.selectedID { m.select(frame.id) } }
    let n = frame == nil ? m.selection.count : 1
    return Menu(n > 1 ? "所选的 \(n) 张的星级、旗标和标签" : "星级、旗标和标签") {
      ForEach(0...5, id: \.self) { stars in
        Button(stars == 0 ? "无星级（0）" : String(repeating: "★", count: stars) + "（\(stars)）") { show(); m.setRating(stars) }
      }
      Divider()
      Button("留用（P）") { show(); m.setFlag(1) }
      Button("不要（X）") { show(); m.setFlag(-1) }
      Button("取消旗标") { show(); m.setFlag(0) }
      Divider()
      ForEach(FrameLabel.allCases, id: \.self) { l in
        Button(l.name + "色标签" + (l.rawValue < 4 ? "（\(l.rawValue + 6)）" : "")) { show(); m.setLabel(l) }
      }
      Button("取消颜色标签") { show(); m.setLabel(nil) }
      Divider()
      // The roll's frames of a mark, chosen together.
      Menu("选择画面") {
        ForEach(AppModel.MarkChoice.groups.indices, id: \.self) { g in
          if g > 0 { Divider() }
          ForEach(AppModel.MarkChoice.groups[g], id: \.self) { choice in Button(choice.name) { m.selectMarked(choice) } }
        }
      }
    }.disabled(m.isWorking)
  }
  var stripScroller: some View {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: 12) {
            ForEach(m.frames) { f in
              VStack(spacing: 2) {
                ZStack {
                  Rectangle().fill(Color.black.opacity(0.55))
                  // A frame not ticked for scanning and export lies dimmed; the one shown has the border.
                  Group {
                    // Module ① shows the raw pictures, ② the converted ones.
                    if let cg = m.showsOriginal ? m.rawThumbnails[f.id] : m.showsDemasked ? m.demaskThumbnails[f.id] ?? m.thumbnails[f.id] : m.thumbnails[f.id] {
                      Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .padding(2)
                    } else {
                      // On the film, which is dark in either look.
                      Text(f.name).font(.system(size: 22, design: .monospaced)).foregroundStyle(
                        Color.white.opacity(0.55))
                    }
                  // Rejected (X), as Lightroom greys it, less than one not ticked.
                  }.opacity(f.enabled ? f.flag == -1 ? 0.5 : 1 : 0.35)
                }.frame(width: 84, height: 60)
                // Exported as it is now, changed since, or on its way out: in ②, where frames are exported.
                // Exporting is ③'s: its marks there, not over ②'s work.
                .overlay(alignment: .topTrailing) {
                  if m.page == .convert && m.convertStep == .grade { ExportMarkView(mark: m.exportMark(f), note: m.exportNote(f)).padding(3) }
                }
                // Lightroom's marks: the colour label, the stars, the flag.
                .overlay(alignment: .bottomLeading) { FrameMarks(frame: f).padding(3) }
                // A scanner roll's frame with only its preview so far: which are left to scan, at a
                // glance, after a batch that stopped.
                .overlay(alignment: .bottomTrailing) {
                  if f.sourcePath == nil && !f.hasFullResolution {
                    Text("预览").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                      .padding(.horizontal, 4).padding(.vertical, 1)
                      .background(Capsule().fill(Color.black.opacity(0.62)))
                      .padding(3).help("只有预览，还没正式扫描：勾上后「扫描所选」")
                  }
                }
                // Repaired in 去漏光: ③ grades the repaired picture.
                .overlay(alignment: .topLeading) {
                  if m.page != .capture, f.adjustments.leakFix != nil { LeakRepairMark().padding(3) }
                  else if m.page != .capture, m.leakJobs[f.id] != nil { LeakRepairMark(applied: false).padding(3) }
                }
                .accessibilityValue(f.enabled ? "已勾选" : "未勾选")
                .overlay(
                  // The frame shown, and those chosen with it (⌘ / ⇧) fainter.
                  Rectangle().stroke(
                    f.id == m.selectedID ? accent : m.alsoSelected.contains(f.id) ? accent.opacity(0.55)
                      : dropTarget == f.id ? Color.white.opacity(0.8) : Color.clear, lineWidth: 2)
                    .padding(-2)
                )
                // Dragged onto another frame, it takes that frame's place; the roll is numbered again.
                .draggable(f.id.uuidString) {
                  Text(f.name).font(.system(size: 14, weight: .semibold, design: .monospaced)).padding(8)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7))).foregroundStyle(.white)
                }
                .dropDestination(for: String.self) { items, _ in
                  guard let moved = items.first.flatMap(UUID.init(uuidString:)), moved != f.id, !m.isWorking else { return false }
                  m.moveFrame(moved, to: f.id)
                  return true
                } isTargeted: { over in dropTarget = over ? f.id : (dropTarget == f.id ? nil : dropTarget) }
                .onTapGesture {
                  // ⌘ adds a frame to those chosen, ⇧ takes the run; a plain click opens it: from the
                  // light table it grows to the middle, shown on its own.
                  guard !m.choose(f.id, modifiers: NSEvent.modifierFlags) else { return }
                  m.open(f.id)
                  m.focusCanvas()
                }.onTapGesture(count: 2) {
                  m.open(f.id)
                  m.focusCanvas()
                }
                .contextMenu {
                  if m.page != .leak {
                    // The frames chosen together when this is one of them, else this one.
                    let chosen = m.selection
                    if chosen.count > 1, chosen.contains(where: { $0.id == f.id }) {
                      // The frames chosen, all at once: what Lightroom's filmstrip does with several.
                      Button("导出所选的 \(chosen.count) 张…", systemImage: "square.and.arrow.up.on.square") { m.exportImages(m.selection) }
                        .disabled(m.isWorking)
                      Divider()
                      Button("顺时针旋转所选的 \(chosen.count) 张", systemImage: "rotate.right") { m.turnRoll(clockwise: true) }.disabled(m.isWorking)
                      Button("逆时针旋转所选的 \(chosen.count) 张", systemImage: "rotate.left") { m.turnRoll(clockwise: false) }.disabled(m.isWorking)
                      Button(m.tableMirrored ? "取消所选的水平镜像" : "水平镜像所选的 \(chosen.count) 张", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        m.mirrorRoll()
                      }.disabled(m.isWorking)
                      Button(m.selectionEnabled ? "取消勾选所选的 \(chosen.count) 张" : "勾选所选的 \(chosen.count) 张",
                        systemImage: m.selectionEnabled ? "circle" : "checkmark.circle") { m.setSelectionEnabled(!m.selectionEnabled) }.disabled(m.isWorking)
                      if m.copiedSettings != nil {
                        Button("粘贴\(AppModel.scopeName(m.stepScope))到所选的 \(chosen.count) 张", systemImage: "doc.on.clipboard") { m.pasteSettings(m.stepScope) }.disabled(m.isWorking || m.page != .convert)
                        Button("选择性粘贴到所选的 \(chosen.count) 张…", systemImage: "checklist") { m.choosingPaste = true }.disabled(m.isWorking || m.page != .convert)
                      }
                      marksMenu(nil)
                      Button("删除所选的 \(chosen.count) 张", systemImage: "trash", role: .destructive) { m.remove(m.selectionIDs) }.disabled(m.isWorking)
                    } else {
                      Button("导出这张…", systemImage: "square.and.arrow.up") {
                        if let now = m.frames.first(where: { $0.id == f.id }) { m.exportImages([now]) }
                      }.disabled(m.isWorking)
                      if m.exportStamps[f.id] != nil {
                        Button("在 Finder 中显示导出的文件", systemImage: "folder") { m.revealExport(f) }
                      }
                      Divider()
                      Button(f.enabled ? "取消勾选" : "勾选", systemImage: f.enabled ? "circle" : "checkmark.circle") {
                        m.setEnabled(f.id, enabled: !f.enabled)
                      }.disabled(m.isWorking)
                      marksMenu(f)
                      // 去漏光 as far as this frame has gone: its repair in ③, a job not taken there yet, or none.
                      if f.adjustments.leakFix != nil {
                        Button("在去漏光里改修复", systemImage: "wand.and.rays") { m.openInLeak(f.id) }.disabled(m.isWorking)
                        Button("去掉去漏光修复", systemImage: "xmark.circle") { m.removeLeakRepair(f.id) }.disabled(m.isWorking)
                      } else {
                        Button(m.leakJobs[f.id] != nil ? "在去漏光里接着修" : "在去漏光里打开", systemImage: "wand.and.rays") { m.openInLeak(f.id) }
                          .disabled(m.isWorking)
                      }
                      if m.page == .convert {
                        // The frame's own settings, as Lightroom copies and pastes them.
                        Button("拷贝这张的调整", systemImage: "doc.on.doc") {
                          if f.id != m.selectedID { m.select(f.id) }
                          m.copySettings()
                        }
                        if m.copiedSettings != nil, m.copiedSettings?.id != f.id {
                          Button("把拷贝的\(AppModel.scopeName(m.stepScope))粘贴到这张", systemImage: "doc.on.clipboard") {
                            if f.id != m.selectedID { m.select(f.id) }
                            m.pasteSettings(m.stepScope)
                          }.disabled(m.isWorking)
                          Button("选择性粘贴到这张…", systemImage: "checklist") {
                            if f.id != m.selectedID { m.select(f.id) }
                            m.choosingPaste = true
                          }.disabled(m.isWorking)
                        }
                      }
                      if m.isLinearPicture(f) && !m.blankFrameIDs.contains(f.id) {
                        Button("设成平场（这张是空白帧）", systemImage: "square.dashed") { m.makeFlat(from: f) }.disabled(m.flatsBlocked != nil)
                      }
                      Button("删除这张", systemImage: "trash", role: .destructive) { m.remove(f.id) }.disabled(m.isWorking)
                    }
                  }
                }
                // Edge print, as exposed along the film beside each frame.
                HStack {
                  Text("▸ \(f.name)")
                  Spacer()
                  Text(f.format)
                }.font(.system(size: 9, weight: .semibold, design: .monospaced))
                  .foregroundStyle(Hardware.edgePrint.opacity(0.85)).frame(width: 84)
              }.id(f.id)
            }
            if m.frames.isEmpty {
              Text("画面列表").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.3)).frame(height: 73)
                .padding(.horizontal, 30)
            }
          }.padding(.horizontal, 14).padding(.vertical, 11)
            .background(FilmBase(look: m.stripLook))
            .padding(.horizontal, 4).padding(.top, 4)
        }.frame(height: 114)
          // Its frames end where the strip does: scrolled past it they went on under the sidebar
          // and the inspector, whose glass showed them as a brown smear.
          .clipped()
          // Back from the library, the strip comes in on the frame shown.
          .onAppear { if let id = m.selectedID { proxy.scrollTo(id, anchor: .center) } }
          .onChange(of: m.selectedID) { _, id in
            // The strip follows the frame shown. Not animated: an animated scrollTo leaves this
            // horizontal strip where it was, in the change or out of it.
            guard let id else { return }
            proxy.scrollTo(id, anchor: .center)
          }
      }
  }
  /// The workspace's status line, and a scan's progress at its end with the key to cancel it.
  var footer: some View {
    HStack(spacing: 12) {
      HStack(spacing: 10) {
        Text(m.activityStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        // The export just done, its files selected in Finder.
        if let done = m.exported, done.status == m.activityStatus, !done.files.isEmpty {
          Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(done.files) }
            .buttonStyle(.link).font(.system(size: 11)).help("在 Finder 中选中导出的 \(done.files.count) 个文件")
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      UpdateNotice(m: m, updater: m.updater)
      // Frame by frame, with the key that stops it.
      if m.exporting && m.exportProgress.total > 0 { ExportProgressBar(m: m) }
      if m.scanBatch.isActive || m.scanner.busy {
        scanProgress
        Button("取消") { m.cancel() }.disabled(m.scanBatch.phase == .cancelling).controlSize(.small)
      }
    }.padding(.horizontal, 18).padding(.vertical, 7)
      .animation(.snappy(duration: 0.25), value: m.exporting)
  }
  func sectionTitle(_ text: String, symbol: String) -> some View { SectionTitle(text: text, symbol: symbol) }
  func labeled<V: View>(_ name: String, @ViewBuilder content: () -> V) -> some View {
    HStack {
      Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
      Spacer()
      content()
    }
  }
  func bool(_ key: WritableKeyPath<Adjustments, Bool>) -> Binding<Bool> {
    Binding(get: { m.settings[keyPath: key] }, set: { v in m.change { $0[keyPath: key] = v } })
  }
  func slider(
    _ title: String, key: WritableKeyPath<Adjustments, Double>, range: ClosedRange<Double>,
    format: String = "%.2f", gradient: [Color]? = nil, label: String? = nil
  ) -> some View {
    VStack(spacing: 3) {
      HStack {
        Text(label ?? title).font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        LiveValueField(live: LiveFigure.named(title), title: title, format: format, value: m.settings[keyPath: key], range: range) { v in
          LiveFigure.named(title).set(v)
          m.change(title) { $0[keyPath: key] = v }
        }
      }
      Fader(
        title: title,
        value: Binding(
          get: { m.settings[keyPath: key] },
          set: { v in
            LiveFigure.named(title).set(v)
            m.change(title) { $0[keyPath: key] = v }
          }),
        range: range, detent: Adjustments()[keyPath: key], gradient: gradient)
    }
  }
}

/// The picture being made: a bar for the steps done and the one under way, named; a turning
/// wheel until the first step says where it is.
struct RenderProgress: View {
  let step: (done: Double, label: String)?
  /// When the canvas last had a new picture.
  var pictureShownAt: () -> Date = { .distantPast }
  /// Shown only for a render that takes a while, so a slider's quick ones do not flash it, nor
  /// while the picture follows a slider, rendering all the while.
  @State private var due = false
  var body: some View {
    Group { if due { bar } }
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(350))
          if Date().timeIntervalSince(pictureShownAt()) >= 0.35 {
            due = true
            return
          }
        }
      }
  }
  var bar: some View {
    VStack(alignment: .trailing, spacing: 5) {
      if let step {
        ProgressView(value: step.done).progressViewStyle(.linear).tint(Hardware.amber).frame(width: 170)
          .animation(.easeOut(duration: 0.25), value: step.done)
        Text(step.label).font(.system(size: 11)).foregroundStyle(Color(white: 0.85))
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .floatingPlate(RoundedRectangle(cornerRadius: 7), text: Color(white: 0.9), opacity: 0.6)
    .allowsHitTesting(false)
    .accessibilityElement().accessibilityLabel("正在生成画面").accessibilityValue(step?.label ?? "")
  }
}

/// The AI assistant's key: a lamp, green while one is connected, amber while one may connect,
/// dark when it may not, and its name; the state in words in its tooltip, so the key stays narrow
/// in the middle of the toolbar. Its settings in a popover.
///
/// It draws its own capsule of glass, of the toolbar's height and fill, a little way from the
/// modules: on the toolbar's shared glass the two ran together through a neck. Its name dims
/// with the window, as the toolbar's own keys do.
struct AssistantKey<Panel: View>: View {
  @Gated var m: AppModel
  let panel: Panel
  @State private var open = false
  @Environment(\.controlActiveState) private var windowState
  var body: some View {
    let on = m.preferences.mcpEnabled, connected = m.mcpStatus.hasPrefix("已连接")
    Button {
      open.toggle()
    } label: {
      HStack(spacing: 6) {
        StatusLED(lamp: connected ? .ready : .busy, size: 7).opacity(on ? 1 : 0.25)
        Text("AI 助手").font(.system(size: 12, weight: .medium))
          .foregroundStyle(windowState == .inactive ? HierarchicalShapeStyle.tertiary : .primary)
      }
      .padding(.horizontal, 6).frame(height: 36)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .liquid(Capsule(), LiquidStyle(interactive: true)) { $0.background(Capsule().fill(.regularMaterial)) }
    .padding(.leading, 8)
    .help((connected ? "已连接" : on ? "等待连接" : "关闭") + " · " + m.mcpStatus)
    .popover(isPresented: $open, arrowEdge: .bottom) { panel.padding(16).frame(width: 320) }
    .accessibilityLabel("AI 助手").accessibilityValue(m.mcpStatus)
  }
}
