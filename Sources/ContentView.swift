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
  /// The sidebar shown or hidden by the toolbar's key; the 去漏光 page has none.
  @State private var sidebar = NavigationSplitViewVisibility.all
  @State private var inspector = true
  var body: some View {
    // The system's window: a sidebar for the module's settings, the workspace with the film strip
    // under it, and an inspector for the frame, all under the system's toolbar.
    NavigationSplitView(columnVisibility: Binding(get: { m.page == .leak ? .detailOnly : sidebar }, set: { if m.page != .leak { sidebar = $0 } })) {
      leftPanel
        .navigationSplitViewColumnWidth(min: Preferences.leftWidths.lowerBound, ideal: m.preferences.leftWidth, max: Preferences.leftWidths.upperBound)
    } detail: {
      VStack(spacing: 0) {
        if m.page == .leak { LeakPage(m: m, lab: m.leak) } else { workspace }
        filmstrip
        if m.page == .leak { LeakStatus(lab: m.leak) } else { footer }
      }
      .inspector(isPresented: $inspector) {
        Group { if m.page == .leak { LeakPanel(m: m, lab: m.leak) } else { rightPanel } }
          .inspectorColumnWidth(min: Preferences.rightWidths.lowerBound, ideal: m.preferences.rightWidth, max: Preferences.rightWidths.upperBound + 40)
      }
    }
    .navigationTitle("Epson Scan plus")
    .toolbar { toolbarContent }
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
  }
  /// The window's toolbar, the system's: the scanner's lamp by the title, the modules in the
  /// middle with the assistant, the module's keys after the title, and the module's leading
  /// action and the inspector's key at the trailing end. A scan's progress is in the workspace's
  /// status line, where it never lies across into the inspector. The system groups them
  /// on its glass and folds what does not fit into its overflow menu.
  @ToolbarContentBuilder var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .navigation) { scannerLamp }
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
          }.help("导入 TIFF、PNG 或 JPEG，放进库里新的一卷")
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
        Label("看片镜", systemImage: "circle.circle").font(.system(size: 11)).foregroundStyle(
          m.preferences.showLoupe ? Hardware.amberText : Color.primary)
      }.buttonStyle(KeyStyle(latched: m.preferences.showLoupe)).controlSize(.small)
        .help("看片镜：点一下放到所选画面上，拖动放大细看，再点一下收起 · Z。接触表和单张都能用；右键选择型号")
      if !m.singleView {
        Button {
          m.preferences.contactLandscape.toggle()
          m.fitView()
        } label: {
          Label("横排", systemImage: "rectangle.landscape.rotate").font(.system(size: 11)).foregroundStyle(
            m.preferences.contactLandscape ? Hardware.amberText : Color.primary)
        }.buttonStyle(KeyStyle(latched: m.preferences.contactLandscape)).controlSize(.small)
          .help("把竖放的片夹横过来摆在灯箱上，胶片条横向排开，更好地利用宽屏。方向跟随多数画面的旋转，都没有旋转时顺时针转")
      }
  }
  /// The canvas tools, and fitting the picture.
  @ViewBuilder var toolControls: some View {
      // Capturing places the frames; the pickers belong to taking the mask off.
      ForEach(m.page == .capture ? [CanvasTool.select, .crop] : [CanvasTool.select, .crop, .base, .neutral, .highlight], id: \.self) { t in
        Button {
          m.useTool(t)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: t.symbol).frame(width: 16, height: 14)
            if let label = t.label { Text(label).font(.system(size: 11)) }
          }.foregroundStyle(m.tool == t ? Hardware.amberText : Color.primary)
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
  @ViewBuilder var placeLabel: some View {
      Text(m.singleView ? "第 \(m.selected?.name ?? "—") 张" : "\(m.frames.count) 个画面").font(
        .system(size: 11, design: .monospaced))
  }
  /// Zoom, turning, mirroring and what is shown.
  @ViewBuilder var viewingControls: some View {
      if m.singleView {
        Text(String(format: "%.1f×", m.zoom)).font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary).help("相对适合窗口的缩放倍率")
      }
      if !m.singleView {
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
            .foregroundStyle(m.contactMirrored ? Hardware.amberText : Color.primary)
        }.buttonStyle(KeyStyle(latched: m.contactMirrored)).help("全卷水平镜像：修正胶片正反面放反").disabled(m.frames.isEmpty)
        Picker("显示", selection: $m.contactPositive) {
          Text("原片").tag(false)
          Text("反相").tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
          .help("反相：每张按各自的调色显示为正片，片边与片夹按本卷片基反相")
          .onChange(of: m.contactPositive) { m.refresh() }
      }
      if m.singleView {
        Button {
          m.navigate(-1)
        } label: {
          Image(systemName: "chevron.left")
        }.disabled(!m.canNavigate(-1)).help("上一张 · ←")
        Button {
          m.navigate(1)
        } label: {
          Image(systemName: "chevron.right")
        }.disabled(!m.canNavigate(1)).help("下一张 · →")
        Toggle("负片", isOn: $m.showNegative).toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 11))
          .onChange(of: m.showNegative) { m.refresh() }
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
            .foregroundStyle(m.settings.flipHorizontal == true ? Hardware.amberText : Color.primary)
        }.buttonStyle(KeyStyle(latched: m.settings.flipHorizontal == true)).help(
          m.syncOrientation ? "全部水平镜像：修正整卷胶片正反面方向" : "水平镜像：修正胶片正反面方向")
        Button {
          m.syncOrientation.toggle()
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "link")
            Text("同步全部")
          }.font(.system(size: 11))
            .foregroundStyle(m.syncOrientation ? Hardware.amberText : Color.primary)
        }.buttonStyle(KeyStyle(latched: m.syncOrientation))
          .help("开启后，旋转和水平镜像同步应用到本卷全部照片")
      }
      Text(m.sourceSummary).font(.system(size: 10, design: .monospaced)).foregroundStyle(
        .secondary)
  }
  /// What floats over the picture: the render in progress, the frame's resolution, the tool's hint.
  @ViewBuilder var canvasOverlays: some View {
      if m.rendering { RenderProgress(step: m.renderStep).padding(14) }
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
        HStack(spacing: 10) {
          placeLabel.glassBar()
          if !m.singleView && m.contactPages.count > 1 { pageControl.glassBar() }
          Spacer()
          HStack(spacing: 8) { viewingControls }.glassBar()
        }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal, inset).padding(.bottom, inset)
      }
    }
  }
  /// Module ① keeps the roll's name and notes on the right; module ② the adjustments.
  @ViewBuilder var rightPanel: some View {
    if m.page == .capture { rollPanel } else { adjustPanel }
  }
  var adjustPanel: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          sectionTitle("调整", symbol: "slider.horizontal.3")
          Spacer()
          Button("重置") { m.resetAdjustments() }.font(.system(size: 11))
        }
        // The curves first, over the picture's histograms channel by channel.
        CurveEditor(
          curves: Binding(
            get: { m.settings.curves ?? ToneCurves() },
            set: { value in m.change("曲线") { $0.curves = value.isIdentity ? nil : value } }),
          histogram: m.histogram, channels: m.channelHistograms)
        Toggle("负片去色罩 / 反相", isOn: bool(\.inputIsNegative)).toggleStyle(.switch).tint(Hardware.accent)
          .font(.system(size: 11))
        HStack {
          Button {
            m.useTool(.base)
          } label: {
            Label("取片基", systemImage: CanvasTool.base.symbol)
          }
          Button("自动片基") {
            m.change("自动片基") {
              $0.base = nil
              $0.baseFine = nil
            }
          }
        }.font(.system(size: 11))
        if m.settings.rollBasePicked == true {
          HStack {
            Text("整卷共用手动取的片基").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button("取消整卷片基") { m.unshareFilmBase() }.font(.system(size: 11))
          }
        } else if m.settings.base != nil {
          Button("整卷共用这个片基") { m.shareFilmBase() }.font(.system(size: 11))
            .help("把这一张取的片基用于整卷：拍一张片头或片边取片基，整卷共用。片间测不到片基的卷用得着，比如翻拍或一张一个文件导入的卷")
        }
        VStack(alignment: .leading, spacing: 7) {
          HStack {
            Text("片基微调 · EV").font(.system(size: 11, weight: .medium))
            Spacer()
            Button("归零") { m.change("片基微调") { $0.baseFine = nil } }.font(.system(size: 10))
            InfoButton(text: "「取片基」只点未曝光的橙色片基（片间或片边），不点景物或片夹；「自动片基」按整卷片间的未曝光区或本张最薄处估计。片间测不到片基的卷（翻拍，或一张一个文件导入），在片头或片边取一次片基，点「整卷共用这个片基」，整卷都用它。\n\n微调按 EV 逐通道改变片基，不会被自动白平衡抵消。")
          }
          ForEach(0..<3, id: \.self) { channel in baseSlider(channel) }
          if let base = m.toneAnalysis?.base ?? m.settings.base ?? m.settings.rollBase {
            Text(String(format: "基准 RGB  %.3f  %.3f  %.3f", base.r, base.g, base.b)).font(
              .system(size: 9, design: .monospaced)
            ).foregroundStyle(.secondary)
            Text(m.settings.base != nil ? "片基来自手动取样" : m.settings.rollBasePicked == true ? "片基来自整卷共用的手动取样" : m.settings.rollBase != nil ? "片基来自整卷片间未曝光区" : "片基按本张最薄的片区估计")
              .font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
        if m.singleView {
          Divider()
          HStack {
            Text("画面范围").font(.system(size: 12, weight: .medium))
            Spacer()
            Button(m.tool == .crop ? "完成" : "微调") { m.useTool(m.tool == .crop ? .select : .crop) }
              .font(.system(size: 11))
            InfoButton(text: m.selected?.scanPath != nil
              ? "在原扫描范围内无损裁切。要扩大扫描区域，请回接触表调整画框并重扫。\n\n「拉直」让画面绕中心转动（正数顺时针，⌥ 拖动更细），裁去转出的空角，拖动时显示网格线；裁切时按 [ ] 每次 0.1°，加 ⇧ 每次 1°。「画线」后沿地平线、墙边或建筑竖线拖一条线，松手就按它拉直（裁切时按住 ⌥ 拖也一样）。接触表上的画框仍按胶片原样显示，拉直后保留的部分用虚线框标出。"
              : "画框周围保留了片基，可在单张中细调裁切，不会跳回接触表。\n\n「拉直」让画面绕中心转动（正数顺时针，⌥ 拖动更细），裁去转出的空角，拖动时显示网格线；裁切时按 [ ] 每次 0.1°，加 ⇧ 每次 1°。「画线」后沿地平线、墙边或建筑竖线拖一条线，松手就按它拉直（裁切时按住 ⌥ 拖也一样）。接触表上的画框仍按胶片原样显示，拉直后保留的部分用虚线框标出。")
          }
          VStack(spacing: 3) {
            HStack {
              Text("拉直").font(.system(size: 11)).foregroundStyle(.secondary)
              Spacer()
              Text(String(format: "%+.2f°", m.screenAngle)).readout()
              Button("画线") {
                m.useTool(.crop)
                m.levelling = true
              }
              .font(.system(size: 10)).help("沿地平线、墙边或建筑竖线拖一条线，按它拉直（裁切时也可以按住 ⌥ 拖）")
              Button("归零") { m.straighten(0) }.font(.system(size: 10)).disabled(m.settings.angle == nil)
            }
            Fader(title: "拉直", value: Binding(get: { m.screenAngle }, set: { m.straighten($0) }), range: -15...15, detent: 0)
          }
          if m.tool == .crop, let crop = m.canvasCrop {
            ForEach(0..<4, id: \.self) { edge in cropStepper(edge, crop: crop) }
            Button("还原范围") { m.resetCrop() }.font(.system(size: 11))
          }
        }
        Divider()
        HStack {
          Text("白平衡").font(.system(size: 12, weight: .medium))
          Spacer()
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
          InfoButton(text: "自动白平衡按画面估计，忽略外缘 5%（不改变导出范围）。「取中性灰」用滴管点画面中应为灰色的地方，按这一点自动白平衡（「自动」保持开着）。「取高光」（Dmax）点负片上最密、正片里应为纯白的地方，比如阳光下的白墙或高光反射：各通道从暗部（或取过的中性灰）拉到这一点，它在正片里是白色。「重算白平衡」放弃取样点，按画面重新估计。")
        }
        slider("冷暖", key: \.warmth, range: -1...1)
        slider("绿 / 洋红", key: \.tint, range: -1...1)
        Button {
          m.useTool(.neutral)
        } label: {
          Label("取中性灰", systemImage: CanvasTool.neutral.symbol)
        }.font(.system(size: 11))
        HStack {
          Button {
            m.useTool(.highlight)
          } label: {
            Label("取高光（Dmax）", systemImage: CanvasTool.highlight.symbol)
          }.font(.system(size: 11))
          if m.settings.highlightSample != nil {
            Button("清除高光点") { m.change("清除高光点") { $0.highlightSample = nil } }.font(.system(size: 11))
          }
        }
        Button("重算白平衡") { m.recalculateWhiteBalance() }.font(.system(size: 11))
        if m.settings.manualBalance != nil {
          Text("保留了旧版中性点；可点「重算白平衡」使用新版校正。").font(.system(size: 10)).foregroundStyle(accent)
            .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        HStack {
          Text("色阶").font(.system(size: 12, weight: .medium))
          Spacer()
          Toggle("自动", isOn: bool(\.autoLevels)).toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 11))
          InfoButton(text: "自动：按画面的密度范围设定黑白两端。关闭后用黑点、白点和中间调手动设定。")
        }
        slider("黑点", key: \.black, range: 0...0.4)
        slider("白点", key: \.white, range: 0.6...1)
        slider("中间调", key: \.midtone, range: 0.4...2)
        Divider()
        HStack {
          Text("影调").font(.system(size: 12, weight: .medium))
          Spacer()
          InfoButton(text: "曝光像放大时的印放曝光一样调整密度，在裁切前生效；−EV 可以找回高光。")
        }
        slider("曝光 · EV", key: \.exposure, range: -2...2, format: "%+.2f")
        slider("对比度", key: \.contrast, range: 0.5...1.6)
        Divider()
        Text("色彩").font(.system(size: 12, weight: .medium))
        slider("饱和度", key: \.saturation, range: 0...1.8)
        Divider()
        sharpeningControl
        DisclosureGroup {
          slider("输入 Gamma", key: \.inputGamma, range: 1...3)
        } label: {
          HStack {
            Text("输入设置")
            Spacer()
            InfoButton(text: "本程序的 48-bit 扫描是线性的，输入 Gamma 为 1.0；编码未知的导入文件默认 2.2。已经反相的文件请关闭「负片去色罩 / 反相」。")
          }
        }.font(.system(size: 11))
        Button {
          m.applyToRoll()
        } label: {
          Label("同步到本卷", systemImage: "square.on.square")
        }.frame(maxWidth: .infinity)
      }.padding(18).disabled(m.selected == nil || m.exporting)
        .buttonStyle(.bordered).controlSize(.small)
    }
  }
  /// Per-frame deconvolution strength, once the scanner has a measured profile.
  var sharpeningControl: some View {
    let imported = m.selected?.sourcePath != nil
    let strength = m.selected.map(Sharpening.strength(for:)) ?? 0
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("锐化").font(.system(size: 12, weight: .medium))
        Spacer()
        if m.preferences.sharpening == nil {
          Text("未配置").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        InfoButton(text: m.preferences.sharpening == nil
          ? "在「扫描」页的「扫描仪锐化」导入一张分辨率标靶的扫描，测出这台扫描仪的 MTF 后可用。"
          : "按扫描仪实测的 MTF 在线性扫描数据上反卷积；默认温和，推到 0 关闭。导入的图像默认不锐化，它们可能来自其他扫描仪或相机。")
      }
      if m.preferences.sharpening != nil {
        VStack(spacing: 3) {
          HStack {
            Text("强度").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(strength == 0 ? "关" : "\(Int((strength * 100).rounded()))%").readout()
          }
          Fader(
            title: "锐化强度",
            value: Binding(get: { strength }, set: { v in m.change("锐化") { $0.sharpening = v } }),
            range: 0...1, detent: imported ? 0 : Sharpening.defaultStrength)
        }
      }
    }
  }
  func baseSlider(_ channel: Int) -> some View {
    let names = ["R · 红", "G · 绿", "B · 蓝"]
    return VStack(spacing: 2) {
      HStack {
        Text(names[channel]).font(.system(size: 10)).foregroundStyle(.secondary)
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
      Text(names[edge]).font(.system(size: 11))
      Spacer()
      Text(String(format: "%.1f%%", values[edge] * 100)).font(
        .system(size: 10, design: .monospaced))
      Button {
        m.adjustCropEdge(edge, delta: -0.001)
      } label: {
        Image(systemName: "minus")
      }
      Button {
        m.adjustCropEdge(edge, delta: 0.001)
      } label: {
        Image(systemName: "plus")
      }
    }.controlSize(.mini).disabled(m.isWorking || m.rendering)
  }
  var filmstrip: some View {
    VStack(spacing: 0) {
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
        Divider().frame(height: 14)
        Button("全选") { m.setAllEnabled(true) }
          .disabled(m.frames.isEmpty || m.enabledCount == m.frames.count || m.isWorking)
          .help("勾选当前工程中的全部照片，用于批量扫描和导出")
        Button("全不选") { m.setAllEnabled(false) }
          .disabled(m.enabledCount == 0 || m.isWorking)
          .help("取消全部扫描和导出勾选；不删除照片、不切换当前画面")
        Text("已选 \(m.enabledCount) / \(m.frames.count)").readout()
        Spacer()
      }.font(.system(size: 11)).controlSize(.mini).buttonStyle(.bordered)
        .padding(.horizontal, 18).padding(.top, 7).padding(.bottom, 2)
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: 12) {
            ForEach(m.frames) { f in
              VStack(spacing: 2) {
                ZStack {
                  Rectangle().fill(Color.black.opacity(0.55))
                  if let cg = m.thumbnails[f.id] {
                    Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fit)
                      .padding(2)
                  } else {
                    // On the film, which is dark in either look.
                    Text(f.name).font(.system(size: 22, design: .monospaced)).foregroundStyle(
                      Color.white.opacity(0.55))
                  }
                  if f.hasFullResolution {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).frame(
                      maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing
                    ).padding(4)
                  }
                }.frame(width: 84, height: 60)
                .overlay(alignment: .topLeading) {
                  Toggle(
                    "勾选",
                    isOn: Binding(
                      get: { f.enabled }, set: { value in m.setEnabled(f.id, enabled: value) })
                  )
                  .toggleStyle(GreasePencilCheck()).disabled(m.isWorking).padding(2)
                }
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
            if let id { proxy.scrollTo(id, anchor: .center) }
          }
      }
    }
  }
  /// The workspace's status line, and a scan's progress at its end with the key to cancel it.
  var footer: some View {
    HStack(spacing: 12) {
      if m.exporting { ProgressView().controlSize(.small) }
      Text(m.activityStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
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
      Text("输入已收录胶片名称会应用对应配置。未收录的胶片使用通用配置，也可以导入附有来源和通道斜率的 JSON 文件。").font(.system(size: 12))
      HStack {
        Button("导入配置…") { m.importProfile() }
        Spacer()
        Button("完成") { showInfo = false }.keyboardShortcut(.defaultAction)
      }
    }.padding(28).frame(width: 440)
  }
  func sectionTitle(_ text: String, symbol: String) -> some View { SectionTitle(text: text, symbol: symbol) }
  func labeled<V: View>(_ name: String, @ViewBuilder content: () -> V) -> some View {
    HStack {
      Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
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
        Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
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
  /// Shown only for a render that takes a while, so a slider's quick ones do not flash it.
  @State private var due = false
  var body: some View {
    Group { if due { bar } }
      .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { due = true } }
  }
  var bar: some View {
    VStack(alignment: .trailing, spacing: 5) {
      if let step {
        ProgressView(value: step.done).progressViewStyle(.linear).tint(Hardware.amber).frame(width: 170)
          .animation(.easeOut(duration: 0.25), value: step.done)
        Text(step.label).font(.system(size: 10)).foregroundStyle(Color(white: 0.85))
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
