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
  @ObservedObject var m: AppModel
  @State var showInfo = false
  /// The window's, which the Edit menu's Undo and Redo use.
  @Environment(\.undoManager) private var undoManager
  /// The sidebar shown or hidden by the toolbar's key: in module ① it holds the source's settings
  /// and stays out; in module ② only calibration and the export settings, so it is put away until
  /// wanted and the picture has the room. The 去漏光 page has none.
  @State private var captureSidebar = NavigationSplitViewVisibility.all
  @AppStorage("convertSidebarShown") private var convertSidebarShown = false
  @State private var inspector = true
  /// The status line shows a while after it changes, and stays while something is under way.
  @State private var statusShown = true
  @State private var statusChange = 0
  var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: {
        switch m.page {
        case .leak: return .detailOnly
        case .convert: return convertSidebarShown ? .all : .detailOnly
        case .capture: return captureSidebar
        }
      },
      set: { v in
        switch m.page {
        case .leak: break
        case .convert: convertSidebarShown = v != .detailOnly
        case .capture: captureSidebar = v
        }
      })
  }
  /// Module ②'s sidebar, opened on calibrating the preset.
  func openCalibration() {
    m.panelTab = .calibration
    withAnimation(Liquid.flow) { convertSidebarShown = true }
  }
  /// Module ②'s sidebar, opened on the export settings.
  func openExportSettings() {
    m.panelTab = .output
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
      leftPanel
        .navigationSplitViewColumnWidth(min: Preferences.leftWidths.lowerBound, ideal: m.preferences.leftWidth, max: Preferences.leftWidths.upperBound)
    } detail: {
      VStack(spacing: 0) {
        if m.page == .leak { LeakPage(m: m, lab: m.leak) } else { workspace }
        filmstrip
        if m.page == .leak {
          if m.leak.busy != nil { LeakStatus(lab: m.leak) }
        } else if footerShown {
          footer.transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(Liquid.flow, value: footerShown)
      .inspector(isPresented: $inspector) {
        Group { if m.page == .leak { LeakPanel(m: m, lab: m.leak) } else { rightPanel } }
          .inspectorColumnWidth(min: Preferences.rightWidths.lowerBound, ideal: m.preferences.rightWidth, max: Preferences.rightWidths.upperBound + 40)
      }
    }
    .navigationTitle(windowTitle)
    .navigationSubtitle(windowSubtitle)
    .toolbar { toolbarContent }
    .onChange(of: m.activityStatus) {
      // A new status shows for a few seconds, then the line folds away unless work is under way.
      statusShown = true
      statusChange += 1
      let change = statusChange
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if statusChange == change { statusShown = false } }
    }
    .onChange(of: m.tool) { _, tool in
      // Picking neutral points calibrates the preset, whose list is in module ②'s sidebar.
      if tool == .calibrate, m.page == .convert, !convertSidebarShown { openCalibration() }
    }
    .copyStandGlass(cameraStage, camera: m.camera)
    .frame(minWidth: 1120, minHeight: 760)
    .alert(
      "无法完成操作",
      isPresented: Binding(get: { m.errorText != nil }, set: { if !$0 { m.errorText = nil } })
    ) {
      Button("好") { m.errorText = nil }
    } message: {
      Text(m.errorText ?? "")
    }
    .sheet(isPresented: $showInfo) { profileInfo }
    .sheet(isPresented: $m.showLibrary) { LibrarySheet(m: m) }
    .sheet(isPresented: $m.showPresets) { PresetManagerSheet(m: m) }
    .sheet(isPresented: $m.showUpdates) { UpdateSheet(m: m, updater: m.updater) }
    .onChange(of: m.tool) { m.refresh() }
    .onAppear {
      m.undoManager = undoManager
      if m.page == .leak { m.leak.undoManager = undoManager }
    }
    .onChange(of: undoManager) { _, new in
      m.undoManager = new
      if m.page == .leak { m.leak.undoManager = new }
    }
    .onChange(of: m.page) { _, page in
      if page == .leak { m.leak.undoManager = undoManager } else { m.leak.save() }
    }
    .onChange(of: m.settingsRequests) { withAnimation(Liquid.flow) { captureSidebar = .all } }
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
        Button {
          m.showLibrary = true
        } label: {
          Label("库", systemImage: "archivebox")
        }.help("所有扫描、翻拍和导入的胶卷（⇧⌘L）")
        if m.page == .capture {
          Button {
            m.importImages()
          } label: {
            Label("导入", systemImage: "square.and.arrow.down")
          }.help("导入 TIFF、PNG 或 JPEG（⌘O），复制到库里新的一卷，原文件不动；编码未知的按 Gamma 2.2 读，可以在 ② 去色罩的「输入设置」里改")
        }
        if m.page == .convert {
          Button {
            if let id = m.selectedID { m.openInLeak(id) }
          } label: {
            Label("去漏光", systemImage: "wand.and.rays")
          }.help("在去漏光页打开选中的这张，按它现在的调色（⌥⌘L）").disabled(m.selected == nil || m.isWorking)
        }
      }
    }
    ToolbarItem(placement: .principal) {
      Picker("模块", selection: $m.page) {
        ForEach(AppModel.Page.allCases, id: \.self) { p in Text("\(p.number) \(p.rawValue)").tag(p) }
      }.pickerStyle(.segmented).labelsHidden().help("模块（⌥⌘1–3）")
    }
    // The assistant by the modules, in the middle, clear of the inspector's part of the toolbar.
    ToolbarItem(placement: .status) { AssistantKey(m: m, panel: assistantPanel) }
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
      } else if m.page == .convert {
        // Exporting, with its settings behind it in the sidebar.
        Menu {
          Button("导出当前…") { m.exportImages(all: false) }.disabled(m.selected == nil || m.isWorking)
          Button("导出勾选的 \(m.enabledCount) 张…") { m.exportImages(all: true) }.disabled(m.enabledCount == 0 || m.isWorking)
          Button("导出接触表…") { m.exportContactSheet() }.disabled(m.enabledCount == 0 || m.isWorking)
          Divider()
          Button("导出设置…") { openExportSettings() }
        } label: {
          Label("导出", systemImage: "square.and.arrow.up")
        } primaryAction: {
          if m.selected != nil && !m.isWorking { m.exportImages(all: false) }
        }
        .help("导出当前这张（⌘E）；点箭头导出勾选的画面、接触表，或改格式和文件名")
      }
    }
    ToolbarItem(placement: .primaryAction) {
      Button {
        inspector.toggle()
      } label: {
        Label(inspector ? "隐藏检查器" : "显示检查器", systemImage: "sidebar.trailing")
      }.help(inspector ? "隐藏右边的检查器" : "显示右边的检查器")
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
      .help((hint.map { $0 + "\n" } ?? "") + "整批进度按张数计算，包含当前这张的扫描进度；不是剩余时间估算")
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
      Picker("视图", selection: Binding(get: { m.singleView }, set: { m.showSingle($0) })) {
        Text("接触表").tag(false)
        Text("单张").tag(true)
      }.pickerStyle(.segmented).frame(width: 150)
        // A preview being read shows on the light table as it comes.
        .disabled(m.previewShowing)
        .help(m.previewShowing ? "预览扫描中，画面在接触表上逐渐出现；扫完后才能看单张" : "接触表 / 单张（⌘1）")
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
      // Capturing places the frames; the pickers belong to taking the mask off.
      ForEach(m.page == .capture ? [CanvasTool.select, .crop] : [CanvasTool.select, .crop, .base, .neutral], id: \.self) { t in
        Button {
          m.useTool(t)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: t.symbol).frame(width: 16, height: 14)
            if let label = t.label { Text(label).font(.system(size: 11)) }
          }
        }.buttonStyle(KeyStyle(latched: m.tool == t)).controlSize(.small).help(t.help)
          .accessibilityLabel(t.rawValue)
      }
      // Only the single frame zooms; the light table always shows the whole roll.
      if m.singleView {
        Divider().frame(height: 18)
        Button {
          m.fitView()
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
      HStack(spacing: 8) { orientationControls }.glassBar()
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
    } else {
      Text("\(m.frames.count) 个画面").font(.system(size: 12, weight: .medium, design: .monospaced))
    }
    if !compact && !m.sourceSummary.isEmpty {
      Text(m.sourceSummary).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
    }
  }
  /// What is shown, the negative or the positive, one choice on the light table and for the single
  /// frame; and the single frame's zoom.
  @ViewBuilder var displayControls: some View {
    Picker("显示", selection: $m.showNegative) {
      Text("负片").tag(true)
      Text("正片").tag(false)
    }.pickerStyle(.segmented).labelsHidden().frame(width: 100)
      .help("负片：扫描或翻拍的原样。正片：每张按各自的调色显示，接触表上片边与片夹按本卷片基反相")
      .onChange(of: m.showNegative) { m.refresh() }
    if m.singleView {
      Text(String(format: "%.1f×", m.zoom)).font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary).help("相对适合窗口的缩放倍率")
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
      }.help(m.syncOrientation ? "全部逆时针旋转 90° · ⇧⌘R" : "逆时针旋转 90° · ⇧⌘R")
      Button {
        m.turn(clockwise: true)
      } label: {
        Image(systemName: "rotate.right")
      }.help(m.syncOrientation ? "全部顺时针旋转 90° · ⌘R" : "顺时针旋转 90° · ⌘R")
      Button {
        m.toggleMirror()
      } label: {
        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
      }.buttonStyle(KeyStyle(latched: m.settings.flipHorizontal == true)).help(
        m.syncOrientation ? "全部水平镜像：修正整卷胶片正反面方向" : "水平镜像：修正胶片正反面方向")
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
      }.help("全卷逆时针旋转 90°：改变每张在单张视图和导出中的方向；转过 90° 的画面在横排的灯箱上也正立").disabled(m.frames.isEmpty)
      Button {
        m.turnRoll(clockwise: true)
      } label: {
        Image(systemName: "rotate.right")
      }.help("全卷顺时针旋转 90°：改变每张在单张视图和导出中的方向；转过 90° 的画面在横排的灯箱上也正立").disabled(m.frames.isEmpty)
      Button {
        m.mirrorRoll()
      } label: {
        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
      }.buttonStyle(KeyStyle(latched: m.rollMirrored)).help(m.rollMirrored ? "取消全卷水平镜像" : "全卷水平镜像：修正胶片正反面放反").disabled(m.frames.isEmpty)
    }
  }
  /// What floats over the picture: the render in progress, the frame's resolution, the tool's hint.
  @ViewBuilder var canvasOverlays: some View {
      if m.rendering { RenderProgress(step: m.renderStep, pictureShownAt: { m.pictureShownAt }).padding(14) }
      if m.singleView && !m.rendering {
        VStack(alignment: .trailing, spacing: 6) {
          if let frame = m.selected, !frame.hasFullResolution {
            Text(
              frame.needsRescan
                ? "裁切超出原扫描 · 需重扫"
                : m.overviewDPI >= 600 ? "\(Int(m.overviewDPI)) dpi 预览 · 正式扫描后更清晰" : "低清预览 · 正式扫描后查看细节"
            ).font(.system(size: 11)).foregroundStyle(accent)
              .padding(7).floatingPlate(RoundedRectangle(cornerRadius: 5), text: accent, opacity: 0.65)
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
  }
  /// Module ① with the camera: the live view takes the canvas's place.
  var cameraStage: Bool { m.page == .capture && m.captureSource == .camera }
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
        ViewThatFits(in: .horizontal) {
          glassToolRow
          glassToolRow.labelStyle(.iconOnly)
        }.lineLimit(1).padding(.horizontal, inset).padding(.top, inset)
        ZStack(alignment: .topTrailing) {
          Color.clear
          canvasOverlays
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        ViewThatFits(in: .horizontal) {
          bottomBars(compact: false)
          bottomBars(compact: true)
        }.lineLimit(1).buttonStyle(.bordered).controlSize(.small).padding(.horizontal, inset).padding(.bottom, inset)
          .animation(Liquid.flow, value: m.singleView)
          .animation(Liquid.flow, value: m.contactPages.count)
      }
    }
  }
  /// Module ① keeps the roll's name and notes on the right; module ② the adjustments.
  @ViewBuilder var rightPanel: some View {
    if m.page == .capture { rollPanel } else { adjustPanel }
  }
  /// Module ②'s inspector, in the order a frame is worked on: the film and where its slopes come
  /// from, the film base, the frame's extent, white balance, tone, levels and colour; then what is
  /// reached for less (curves, sharpening, input) folded away. Every section folds, and opens as it
  /// was left.
  var adjustPanel: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          sectionTitle("调整", symbol: "slider.horizontal.3")
          Spacer()
          Button("重置") { m.resetAdjustments() }.font(.system(size: 11))
            .help("把这一张的调整恢复默认；输入 Gamma、方向和整卷估计保留")
            .disabled(frameControlsOff)
        }
        // The roll's film stays at hand while exporting, which works from the preset it began with.
        filmSection
        Group {
        // A slide has no mask to divide by.
        if !m.settings.isSlide {
          Divider()
          baseSection
        }
        if m.singleView {
          Divider()
          frameSection
        }
        Divider()
        balanceSection
        Divider()
        toneSection
        Divider()
        levelsSection
        Divider()
        colourSection
        Divider()
        DustSection(m: m)
        Divider()
        curvesSection
        Divider()
        // The scanner's measured MTF is no lens's: on the copy stand only where it was set, to be taken off.
        if !m.copyStandRoll || (m.selected.map(Sharpening.strength(for:)) ?? 0) > 0 {
          sharpeningSection
          Divider()
        }
        inputSection
        Button {
          m.applyToRoll()
        } label: {
          Label("同步到本卷", systemImage: "square.on.square")
        }.frame(maxWidth: .infinity).padding(.top, 4)
          .help("把这一张的调整用到本卷每一张")
        }.disabled(frameControlsOff)
      }.padding(18)
        .buttonStyle(.bordered).controlSize(.small)
    }
  }
  /// The frame's own controls wait for a frame, and for an export to finish.
  private var frameControlsOff: Bool { m.selected == nil || m.exporting }
  /// A preset as the film menu names it: with the day it was calibrated where another preset has
  /// its name (two calibrations of one film on the V850 are both "Kodak Portra 160 · V850").
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
        Menu {
          ForEach(m.profiles) { p in
            Button {
              m.chooseProfile(p)
            } label: {
              if p.id == m.profile.id { Label(presetTitle(p), systemImage: "checkmark") } else { Text(presetTitle(p)) }
            }
          }
          Divider()
          Button("管理预设…") { m.showPresets = true }
          Button("配置与技术文档…") { showInfo = true }
          Button(m.copyStandRoll ? "翻拍预设标定…" : "本机预设标定…") { openCalibration() }
        } label: {
          Text(presetTitle(m.profile)).lineLimit(1)
        }
        .menuStyle(.button).frame(maxWidth: .infinity, alignment: .leading)
        .help("这一卷用的预设：通道斜率和标定的中性。也可以在下面输入胶片名")
        labeled("胶片名") {
          HStack(spacing: 6) {
            TextField("胶片名", text: $m.filmName).textFieldStyle(.roundedBorder).font(.system(size: 12))
              .onSubmit { m.matchFilm() }
              .help("这一卷的胶片名，库里也显示；回车或「应用」后，收录的胶片换成对应的预设")
            Button("应用") { m.matchFilm() }.controlSize(.small).help("按胶片名换成收录的预设；没有收录的用通用配置")
          }
        }
        Text(conversionBasisShort).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        if m.hasSensorPictures {
          HStack {
            Toggle(m.preferences.lightCalibration == nil ? "去串色 · RGB 光源" : "去串色和平场 · RGB 光源",
              isOn: Binding(get: { m.crosstalkRemoved }, set: { m.removeCrosstalk($0) }))
              .toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 12)).disabled(m.isWorking)
            Spacer()
            InfoButton(text: Self.crosstalkInfo)
          }
        }
        if m.hasSinglePictures {
          HStack {
            Toggle("单张一起做整卷估计", isOn: Binding(get: { m.poolPictures }, set: { m.setPoolPictures($0) }))
              .toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 12))
            Spacer()
            InfoButton(text: "一张一个文件的画面（翻拍，或一张张导入的扫描）一起估计通道斜率。只在它们是同一卷、用同样的设备和设置拍或扫时打开；读法不同（Gamma、位深）的文件不会混在一起。")
          }
        }
      }
    }
  }
  static let crosstalkInfo = "翻拍时相机的红、绿、蓝滤色片和光源的三种灯光谱有重叠：蓝灯有 34% 读进绿通道，绿灯约 12% 和 11% 读进红、蓝。每个通道掺了别的灯的光，转出来颜色发灰，要把饱和度拉到 1.8 左右才像 Capture One。\n\n打开后，从传感器读出的 RAW（无压缩 ARW）在算片基和密度之前，先在线性读数上把串色去掉；在翻拍页做过「光源标定」的话，再除以平场，把灯照在四周偏暗的地方补平。没有标定时，矩阵用 2026-10-29 用 IT8 色卡测的，没有平场。矩阵属于这台 A7R IV 和这组 RGB 灯；换了相机或灯就要重新标定。白光翻拍时关掉。\n\n整卷一起开关，可以 ⌘Z 撤销；取过的片基、中性灰和高光跟着换算。下一卷沿用这里的选择。"
  /// The film base: where it was read in a line, picking it or going back to the automatic one,
  /// and the fine adjustment folded under it.
  var baseSection: some View {
    PanelSection("片基", key: "base", info: "「取片基」只点未曝光的橙色片基（片间或片边），不点景物或片夹；「自动」：扫描的卷按整卷片间的未曝光区；翻拍和一张一个文件导入的照片，按这一张片边的未曝光片基（片边看不到时用最近一张看得到的），都没有时按本张最薄处估计。打开「标出」在单张上看取的是哪里。片边也不准时，在片头或片边取一次片基，点「整卷共用这个片基」，整卷都用它。\n\n微调按 EV 逐通道改变片基，不会被自动白平衡抵消。") {
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
            $0.baseFine = nil
          }
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
        PanelSection("微调 · EV", key: "baseFine", open: false, level: .sub) {
          if m.settings.baseFine != nil {
            Button("归零") { m.change("片基微调") { $0.baseFine = nil } }.font(.system(size: 11))
          }
        } content: {
          VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<3, id: \.self) { channel in baseSlider(channel) }
            if let base = m.toneAnalysis?.base ?? m.settings.base ?? m.settings.rollBase {
              Text(String(format: "基准 RGB  %.3f  %.3f  %.3f", base.r, base.g, base.b)).font(
                .system(size: 11, design: .monospaced)
              ).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }
  /// The frame's extent and straightening, in the single view; open while the crop tool is.
  var frameSection: some View {
    PanelSection("画面范围", key: "frame", open: false, info: m.selected?.scanPath != nil
      ? "标题旁的「裁切」和画面上方工具条里的一样：按下后在画面上拖动边和角，这里可以逐边微调、还原范围，再按一次结束。\n\n在原扫描范围内无损裁切。要扩大扫描区域，请回接触表调整画框并重扫。\n\n「拉直」让画面绕中心转动（正数顺时针，⌥ 拖动更细），裁去转出的空角，拖动时显示网格线；裁切时按 [ ] 每次 0.1°，加 ⇧ 每次 1°。「画线」后沿地平线、墙边或建筑竖线拖一条线，松手就按它拉直（裁切时按住 ⌥ 拖也一样）。接触表上的画框仍按胶片原样显示，拉直后保留的部分用虚线框标出。"
      : "画框周围保留了片基，可在单张中细调裁切，不会跳回接触表。\n\n标题旁的「裁切」和画面上方工具条里的一样：按下后在画面上拖动边和角，这里可以逐边微调、还原范围，再按一次结束。\n\n翻拍的照片可以「自动裁切」：找出片框的四条边（片边或片间的片基转入画面的地方），裁到画面以内一点，并按边拉直；「本张」只裁这一张，「整卷」整卷一起裁。同一卷翻拍时放大倍率不变，每张的画面大小差不多：哪张的一条边找错了（比如画面底部有一大片和片基一样淡的阴影，它的直边被当成了片框），就按其他张的画面大小改正。片框的边伸出照片的那一侧，裁在照片的边上。\n\n「拉直」让画面绕中心转动（正数顺时针，⌥ 拖动更细），裁去转出的空角，拖动时显示网格线；裁切时按 [ ] 每次 0.1°，加 ⇧ 每次 1°。「画线」后沿地平线、墙边或建筑竖线拖一条线，松手就按它拉直（裁切时按住 ⌥ 拖也一样）。接触表上的画框仍按胶片原样显示，拉直后保留的部分用虚线框标出。",
      forced: m.tool == .crop
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
        VStack(spacing: 3) {
          HStack {
            Text("拉直").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%+.2f°", m.screenAngle)).readout()
            Button("画线") {
              m.useTool(.crop)
              m.levelling = true
            }
            .font(.system(size: 11)).help("沿地平线、墙边或建筑竖线拖一条线，按它拉直（裁切时也可以按住 ⌥ 拖）")
            Button("归零") { m.straighten(0) }.font(.system(size: 11)).disabled(m.settings.angle == nil)
          }
          Fader(title: "拉直", value: Binding(get: { m.screenAngle }, set: { m.straighten($0) }), range: -15...15, detent: 0)
        }
        if m.tool == .crop, let crop = m.canvasCrop {
          ForEach(0..<4, id: \.self) { edge in cropStepper(edge, crop: crop) }
          Button("还原范围") { m.resetCrop() }.font(.system(size: 11))
        }
      }
    }
  }
  /// The crop tool, as on the bar over the picture: latched while cropping, pressed again to finish.
  var cropKey: some View {
    Button {
      m.useTool(m.tool == .crop ? .select : .crop)
    } label: {
      Label("裁切", systemImage: CanvasTool.crop.symbol).lineLimit(1).fixedSize()
    }
    .buttonStyle(KeyStyle(latched: m.tool == .crop)).font(.system(size: 11)).disabled(m.selected == nil)
    .help(m.tool == .crop ? "结束裁切 · C" : "在画面上裁切：拖动边和角，边栏里可以逐边微调 · C")
  }
  /// White balance: automatic or by hand, the roll as one, and the points picked on the frame.
  var balanceSection: some View {
    PanelSection("白平衡", key: "balance", info: "自动白平衡按画面估计，忽略外缘 5%（不改变导出范围）。用本机或翻拍标定的预设时不按画面估计，按标定时记下的中性配平，开不开「自动」都一样；这个中性是在标定时的光下定的（比如阳光），阴天、树荫、室内的照片会带上光的颜色，用「中性灰」或冷暖、绿 / 洋红调。\n\n「阴影冷暖」只动暗部，越亮作用越小，阳光下的灰不变：晴天的阴影由蓝天照亮，本来就偏蓝，往右拨把它暖回来。\n\n「中性灰」用滴管点画面中应为灰色的地方，按这一点自动白平衡（「自动」保持开着）；滴管也在画面上方的工具条里（N）。取过点以后旁边出现「清除取样」：放弃取样点，打开「自动」，按画面估计，标定预设回到标定的中性；冷暖、绿 / 洋红和片基不动。\n\n反转片：片子本来的颜色就是画面，默认不自动白平衡，透过片子最亮处的光就是白。打开「自动」时每个通道各自从最暗拉到最亮，适合褪色、偏色的片子。「中性灰」把那一点配成灰。「清除取样」放弃取样点，回到片子本来的颜色。") {
      Toggle(
        "自动",
        isOn: Binding(
          get: { m.settings.autoWhiteBalance },
          set: { v in
            m.change("自动白平衡") {
              $0.autoWhiteBalance = v
              $0.manualBalance = nil
              $0.neutralSample = nil
            }
          })
      ).toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 11))
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        if !m.settings.isSlide {
        HStack {
          Toggle("整卷同一白平衡", isOn: Binding(get: { m.settings.sharedBalance == true }, set: { m.setSharedBalance($0) }))
            .toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 12)).disabled(m.selected == nil || m.isWorking)
          Spacer()
          InfoButton(text: "像冲印店印一卷那样，整卷用同一个配光：白平衡按整卷所有画面一起统计，卷里每张的颜色一致，不再各自按自己的暗部去配平（比如阴影里的天光不会把一张整体拉偏）。每张的明暗照旧。\n\n只替换交给软件的部分：哪一张取了中性灰，或关了自动白平衡，那一张按你的来。用标定预设时，白平衡本来就按标定的中性，整卷一致。")
        }
        }
        slider("冷暖", key: \.warmth, range: -1...1)
        slider("绿 / 洋红", key: \.tint, range: -1...1)
        slider("阴影冷暖", key: \.shadowWarmthAmount, range: -1...1)
        // The picker, latched while in use and marked once a point is picked (the same picker lies
        // over the picture), and what lets the point go once there is one.
        HStack(spacing: 6) {
          Text("取样").font(.system(size: 12)).foregroundStyle(.secondary)
          Button {
            m.useTool(.neutral)
          } label: {
            Label(m.settings.neutralSample != nil ? "中性灰 ✓" : "中性灰", systemImage: CanvasTool.neutral.symbol)
          }.buttonStyle(KeyStyle(latched: m.tool == .neutral)).help("取中性灰：点画面中应为灰色的地方 · N")
          if m.settings.neutralSample != nil || m.settings.manualBalance != nil {
            Spacer(minLength: 4)
            Button("清除取样") { m.clearBalanceSamples() }
              .help(m.settings.isSlide ? "放弃取样点，回到片子本来的颜色" : "放弃中性灰取样点，回到自动白平衡")
          }
        }.font(.system(size: 11)).lineLimit(1)
        if m.settings.manualBalance != nil {
          Text("保留了旧版中性点；可点「清除取样」使用新版校正。").font(.system(size: 11)).foregroundStyle(accent)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
  /// Exposure and the tones, over the frame's histogram against what a screen shows.
  var toneSection: some View {
    PanelSection("影调", key: "tone", info: "曝光像放大时的印放曝光一样调整密度，在裁切前生效；−EV 可以找回高光。\n\n高光、阴影只动亮部或暗部：阴影往右提亮暗部、往左压暗；高光往左压暗亮部、找回层次，往右提亮。黑和白两端不动，明暗顺序也不会颠倒。\n\n压高光只把亮部往下压，白也跟着下来，到 1 时白在 0.85，像 C1 那样不顶满；亮度 0.45 以下不动，三个通道压一样多，颜色不变，最亮处的层次也留着。") {
      VStack(alignment: .leading, spacing: 10) {
        // In the single view, the frame's tones against what an ordinary screen shows of them.
        if let range = m.toneRange {
          HStack {
            Text("直方图 · SDR 范围").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            InfoButton(text: "按印放曝光画的直方图，比屏幕能显示的范围宽：标着「黑」「白」的竖线是色阶的黑点和白点，「+1」「+2」是白点以上一档、两档。\n\n亮的一段是普通（SDR）屏幕上有层次的范围，从屏幕上的黑到屏幕上的白；两边暗下去的部分在屏幕上已是纯黑或纯白。柔和的高光把白点以上的一段收进这个范围，亮的一段因此伸过「白」。高光落在暗下去的部分时，可以把「曝光」往负调，或把「高光」往负调让肩部伸得更远。\n\n下面的「纯白」「纯黑」按屏幕上这张实际的像素数，有一个通道到顶或到底就算，色彩降噪等两端之后的处理也算在内。\n\n纵向按平方根画，少量的高光也看得见。按整张的每个像素计数，只算裁切以内；曲线算在屏幕范围里。")
          }
          ToneRangeView(range: range)
        }
        slider("曝光 · EV", key: \.exposure, range: -2...2, format: "%+.2f")
        slider("对比度", key: \.contrast, range: 0.5...1.6)
        slider("高光", key: \.highlightsAmount, range: -1...1, format: "%+.2f")
        slider("压高光", key: \.pressHighlightsAmount, range: 0...1)
        slider("阴影", key: \.shadowsAmount, range: -1...1, format: "%+.2f")
      }
    }
  }
  /// The ends: automatic, the roll as one, or set by hand.
  var levelsSection: some View {
    PanelSection("色阶", key: "levels", info: "自动：按画面的密度范围设定黑白两端。范围不到 4 档的画面（雾、霾、很平的光）不拉满到黑和白，以中间为准撑开到 4 档，保留它本来的灰和柔；要更硬，调「对比度」或关掉自动。关闭后用黑点、白点和中间调手动设定。\n\n「整卷同一色阶」：整卷用同一组黑白两端，按整卷所有画面一起统计，像冲印店一卷用一个印放曝光：暗的场景就是暗的，亮的就是亮的。每张仍可以用「曝光」微调。关了自动色阶的那一张按你的来。\n\n反转片：自动把最暗的 0.5% 定为黑、最亮的 0.5% 定为白，三个通道用同一对两端，颜色不变；关掉时扫描仪的裸光是白，片子显示得和看片台上一样暗。") {
      Toggle("自动", isOn: bool(\.autoLevels)).toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 11))
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        if !m.settings.isSlide {
          Toggle("整卷同一色阶", isOn: Binding(get: { m.settings.sharedLevels == true }, set: { m.setSharedLevels($0) }))
            .toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 12)).disabled(m.selected == nil || m.isWorking)
        }
        slider("黑点", key: \.black, range: 0...0.4)
        slider("白点", key: \.white, range: 0.6...1)
        slider("中间调", key: \.midtone, range: 0.4...2)
      }
    }
  }
  var colourSection: some View {
    PanelSection("色彩", key: "colour", info: "色彩降噪只平滑颜色、不动明度：传感器和去串色带来的彩色噪点（尤其是蓝黄）会去掉，胶片颗粒的明暗结构保留。翻拍的照片默认 1。\n\n柔和的暗部和高光：最暗的地方不硬切成纯黑，而是平滑地压下去，暗部的颜色和层次因此保留下来，并略微补一点暗部的饱和度；最亮的地方用柔和的肩部收向白，不硬顶到白。高光超出白点较多的画面，肩部按这张最亮的 0.1% 伸长（最多两档），阳光下的白边、亮云在普通屏幕上也留着层次；亮颜色收下来时颜色不变：最亮的通道走肩部，另外两个保持原来的距离，所以朝天空和朝太阳的两面白墙仍分得出冷暖，也不截掉一个通道；只有比这张最亮的 0.1% 还亮的地方才褪成白。「高光」往负调时肩部伸得更远。像相纸那样，中间段不变。") {
      VStack(alignment: .leading, spacing: 10) {
        slider("饱和度", key: \.saturation, range: 0...1.8)
        slider("色彩降噪", key: \.colourNoiseAmount, range: 0...2)
        Toggle("柔和的暗部和高光", isOn: bool(\.softEndsOn)).toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 12))
      }
    }
  }
  /// The curves, over the picture's histograms channel by channel; folded until wanted, and marked
  /// when they change the picture.
  var curvesSection: some View {
    PanelSection("曲线", key: "curves", open: false, info: "拖动控制点调整；点空白处添加，双击控制点删除。各通道曲线在 RGB 曲线之后生效。背后是正片的红、绿、蓝直方图。") {
      if m.settings.curves != nil {
        Text("已调整").font(.system(size: 11)).foregroundStyle(Hardware.amberText)
      }
    } content: {
      CurveEditor(
        curves: Binding(
          get: { m.settings.curves ?? ToneCurves() },
          set: { value in m.change("曲线") { $0.curves = value.isIdentity ? nil : value } }),
        histogram: m.histogram, channels: m.channelHistograms)
    }
  }
  /// Per-frame deconvolution strength, once the scanner has a measured profile.
  var sharpeningSection: some View {
    let imported = m.selected?.sourcePath != nil
    let strength = m.selected.map(Sharpening.strength(for:)) ?? 0
    return PanelSection("锐化", key: "sharpening", open: false, info: m.preferences.sharpening == nil
      ? "在 ① 采集 · V850 的「扫描仪锐化」导入一张分辨率标靶的扫描，测出这台扫描仪的 MTF 后可用。"
      : "按扫描仪实测的 MTF 在线性扫描数据上反卷积；默认温和，推到 0 关闭。导入的图像默认不锐化，它们可能来自其他扫描仪或相机。"
    ) {
      Text(m.preferences.sharpening == nil ? "未配置" : strength == 0 ? "关" : "\(Int((strength * 100).rounded()))%").readout()
    } content: {
      if m.preferences.sharpening != nil {
        Fader(
          title: "锐化强度",
          value: Binding(get: { strength }, set: { v in m.change("锐化") { $0.sharpening = v } }),
          range: 0...1, detent: imported ? 0 : Sharpening.defaultStrength)
      } else {
        Text("还没有这台扫描仪的锐化配置。").font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }
  /// How the file is read: as a negative or already positive, and its encoding.
  var inputSection: some View {
    PanelSection("输入设置", key: "input", open: false, info: "本程序的 48-bit 扫描是线性的，输入 Gamma 为 1.0；编码未知的导入文件默认 2.2。已经反相的文件请关闭「负片去色罩 / 反相」。") {
      if !m.settings.inputIsNegative {
        Text(m.settings.isSlide ? "反转片" : "不反相").font(.system(size: 11)).foregroundStyle(Hardware.amberText)
      }
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        Toggle("负片去色罩 / 反相", isOn: bool(\.inputIsNegative)).toggleStyle(.switch).tint(Hardware.accent)
          .font(.system(size: 12))
        slider("输入 Gamma", key: \.inputGamma, range: 1...3)
      }
    }
  }
  func baseSlider(_ channel: Int) -> some View {
    let names = ["R · 红", "G · 绿", "B · 蓝"]
    return VStack(spacing: 2) {
      HStack {
        Text(names[channel]).font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Text(String(format: "%+.3f", (m.settings.baseFine ?? .zero).values[channel])).readout()
      }
      Fader(
        title: "片基微调 " + names[channel],
        value: Binding(
          get: { (m.settings.baseFine ?? .zero).values[channel] },
          set: { m.adjustBase(channel, value: $0) }), range: -0.5...0.5, detent: 0)
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
                    if let cg = m.thumbnails[f.id] {
                      Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .padding(2)
                    } else {
                      // On the film, which is dark in either look.
                      Text(f.name).font(.system(size: 22, design: .monospaced)).foregroundStyle(
                        Color.white.opacity(0.55))
                    }
                  }.opacity(f.enabled ? 1 : 0.35)
                }.frame(width: 84, height: 60)
                .accessibilityValue(f.enabled ? "已勾选" : "未勾选")
                .overlay(
                  Rectangle().stroke(f.id == m.selectedID ? accent : Color.clear, lineWidth: 2)
                    .padding(-2)
                ).onTapGesture {
                  // From the light table it grows to the middle, shown on its own.
                  m.open(f.id)
                  m.focusCanvas()
                }.onTapGesture(count: 2) {
                  m.open(f.id)
                  m.focusCanvas()
                }
                .contextMenu {
                  if m.page != .leak {
                    Button(f.enabled ? "取消勾选" : "勾选", systemImage: f.enabled ? "circle" : "checkmark.circle") {
                      m.setEnabled(f.id, enabled: !f.enabled)
                    }.disabled(m.isWorking)
                    Button("在去漏光里打开", systemImage: "wand.and.rays") { m.openInLeak(f.id) }.disabled(m.isWorking)
                    Button("删除这张", systemImage: "trash", role: .destructive) { m.remove(f.id) }.disabled(m.isWorking)
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
            .background(FilmBase())
            .padding(.horizontal, 4).padding(.top, 4)
        }.frame(height: 114)
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
      if m.exporting { ProgressView().controlSize(.small) }
      Text(m.activityStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
      UpdateNotice(m: m, updater: m.updater)
      if m.scanBatch.isActive || m.scanner.busy {
        scanProgress
        Button("取消") { m.cancel() }.disabled(m.scanBatch.phase == .cancelling).controlSize(.small)
      }
    }.padding(.horizontal, 18).padding(.vertical, 7)
  }
  var profileInfo: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(m.profile.name).font(.title2)
      Text(m.profile.process + " · ISO \(m.profile.iso)")
      Text(m.profile.publication).foregroundStyle(.secondary)
      Text(m.profile.notes).font(.system(size: 12))
      Text(
        String(
          format: "中段密度斜率近似  R %.2f · G %.2f · B %.2f", m.profile.slopes.r, m.profile.slopes.g,
          m.profile.slopes.b)
      ).font(.system(size: 11, design: .monospaced))
      if let url = URL(string: m.profile.sourceURL) { Link("打开官方技术文档", destination: url) }
      Divider()
      Text("输入已收录胶片名称会应用对应配置。未收录的胶片使用通用配置，也可以在胶片菜单的「管理预设…」打开的预设表格里导入附有来源和通道斜率的 JSON 文件。").font(.system(size: 12))
      HStack {
        Spacer()
        Button("完成") { showInfo = false }.keyboardShortcut(.defaultAction)
      }
    }.padding(28).frame(width: 440)
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
    format: String = "%.2f"
  ) -> some View {
    VStack(spacing: 3) {
      HStack {
        Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Text(String(format: format, m.settings[keyPath: key])).readout()
      }
      Fader(
        title: title,
        value: Binding(
          get: { m.settings[keyPath: key] }, set: { v in m.change(title) { $0[keyPath: key] = v } }),
        range: range, detent: Adjustments()[keyPath: key])
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
struct AssistantKey<Panel: View>: View {
  @ObservedObject var m: AppModel
  let panel: Panel
  @State private var open = false
  var body: some View {
    let on = m.preferences.mcpEnabled, connected = m.mcpStatus.hasPrefix("已连接")
    Button {
      open.toggle()
    } label: {
      HStack(spacing: 6) {
        StatusLED(lamp: connected ? .ready : .busy, size: 7).opacity(on ? 1 : 0.25)
        Text("AI 助手").font(.system(size: 12, weight: .medium))
      }
    }
    .help((connected ? "已连接" : on ? "等待连接" : "关闭") + " · " + m.mcpStatus)
    .popover(isPresented: $open, arrowEdge: .bottom) { panel.padding(16).frame(width: 320) }
    .accessibilityLabel("AI 助手").accessibilityValue(m.mcpStatus)
  }
}
