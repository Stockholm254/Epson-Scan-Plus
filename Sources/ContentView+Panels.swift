import AppKit
import SwiftUI

/// The left panel: scanning and storage, film and presets, and output, in three tabs. This is
/// also where every setting lives; ⌘, opens the scan tab.
extension ContentView {
  var leftPanel: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        ForEach(AppModel.PanelTab.allCases, id: \.self) { tab in
          Button {
            m.panelTab = tab
          } label: {
            Text(tab.rawValue).frame(maxWidth: .infinity)
              .foregroundStyle(m.panelTab == tab ? Hardware.amber : Color(white: 0.8))
          }.buttonStyle(HardwareKeyStyle(latched: m.panelTab == tab))
        }
      }.controlSize(.small).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          switch m.panelTab {
          case .scan: scanTab
          case .film: filmTab
          case .output: outputTab
          }
          Spacer(minLength: 16)
        }.padding(16).buttonStyle(HardwareKeyStyle()).controlSize(.small)
      }
    }.background(Hardware.metal)
  }

  // MARK: Scan

  var scanTab: some View {
    VStack(alignment: .leading, spacing: 18) {
      sectionTitle("扫描仪", symbol: "scanner")
      HStack(alignment: .top, spacing: 8) {
        StatusLED(lamp: lampState.lamp, size: 7).padding(.top, 4)
        Text(m.scanner.name).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 12) {
        labeled("来源") { Text("透射光 · 保留负片").font(.system(size: 12)).foregroundStyle(.secondary) }
        labeled("分辨率") {
          Picker("", selection: $m.dpi) {
            ForEach(m.scanner.supportedDPI, id: \.self) { Text("\($0) dpi").tag($0) }
          }.labelsHidden().disabled(m.isWorking)
        }
        labeled("预览") {
          Picker("", selection: Binding(get: { m.preferences.previewDPI }, set: { m.preferences.previewDPI = $0 })) {
            Text("600 dpi · 约 80 秒").tag(600)
            Text("150 dpi · 约 50 秒").tag(150)
          }.labelsHidden().disabled(m.isWorking)
        }
        labeled("采集位深") {
          Text(m.scanner.ready ? "\(m.scanner.bits * 3)-bit RGB" : "待检测").font(.system(size: 12, design: .monospaced))
        }
        labeled("原始文件") { Text("TIFF · 16-bit 线性").font(.system(size: 12)).foregroundStyle(.secondary) }
      }
      note("原始文件是未反相的负片，保留橙色色罩，作存档和重新转换用；去色罩的正片默认在扫完后导出到 Exports（见「输出」）。无损压缩对扫描数据几乎无效（LZW 反而变大），因此不压缩。")
      note("整幅预览用于识别画面、接触表和看片镜。600 dpi 时每张 35 mm 约 850 像素，未正式扫描的画面也能看清细节；300 dpi 并不比 600 dpi 快多少，所以不提供。")
      if m.scanner.ready { note(m.scanner.captureNote) }
      HStack {
        Button("重新连接") { m.scanner.reconnect() }
        Button("Epson…") { m.openEpson() }
      }.font(.system(size: 11)).disabled(m.isWorking)
      Divider()
      sectionTitle("存储", symbol: "externaldrive")
      Text((m.libraryURL.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
      HStack {
        Button("选择…") { m.chooseLibrary() }
        Button("显示") { reveal(m.libraryURL) }
        Button("默认") { m.setLibrary(Preferences.defaultLibraryURL) }.disabled(m.preferences.libraryPath == nil)
      }.font(.system(size: 11))
      if let session = m.sessionURL {
        Button("当前工程：\(session.lastPathComponent)") { reveal(session) }.buttonStyle(.link).font(.system(size: 11))
          .lineLimit(1).truncationMode(.middle).help(session.path)
      }
      note("每次预览或导入会在这里新建工程文件夹：原始负片在 Originals，自动导出的正片在 Exports。更改位置只影响之后新建的工程。")
      Divider()
      sectionTitle("画面", symbol: "rectangle.dashed")
      labeled("规格") {
        Picker("", selection: $m.format) {
          ForEach(FilmFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden()
      }
      Button {
        m.singleView = false
        m.detectFrames()
      } label: {
        Label("自动识别画面", systemImage: "rectangle.3.group")
      }.disabled(m.overview == nil || m.isWorking)
      Button("收紧现有边界") { m.tightenExistingBorders() }
        .font(.system(size: 11))
        .help("仅收紧已有画面框；保留逐张调色和原始扫描，可在单张中还原范围")
        .disabled(m.frames.isEmpty || m.selected?.sourcePath != nil || m.isWorking || m.rendering)
      HStack {
        Button {
          m.singleView = false
          m.tool = .crop
          m.refresh()
        } label: {
          Label("手动画框", systemImage: "crop")
        }
        Button {
          m.removeSelected()
        } label: {
          Image(systemName: "trash")
        }.disabled(m.selected == nil)
      }.disabled(m.isWorking)
      note("拖动框内移动，拖动四角缩放。双击画面进入单张。")
      Divider()
      scannerSharpening
    }
  }
  var scannerSharpening: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("扫描仪锐化", symbol: "scope")
      if let p = m.preferences.sharpening {
        let ppi = p.effectivePPI
        Text("\(p.source) · \(Int(p.targetDPI)) dpi").font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
        Text("横向约 \(Int(ppi.horizontal.rounded())) ppi · 竖向约 \(Int(ppi.vertical.rounded())) ppi").lcd()
        MTFChart(profile: p).frame(height: 110)
      } else {
        note("尚未建立配置。导入一张分辨率标靶的扫描（需带实心方块，如 USAF 1951 或 Vlad 标靶），程序自动测量横向和竖向 MTF；扫描时让标靶略微倾斜 1–5°。")
      }
      HStack {
        Button(m.preferences.sharpening == nil ? "导入标靶…" : "重新导入…") { m.importSharpeningTarget() }
          .disabled(m.measuringTarget)
        if m.preferences.sharpening != nil { Button("移除") { m.removeSharpeningProfile() }.disabled(m.measuringTarget) }
        if m.measuringTarget { ProgressView().controlSize(.small) }
      }.font(.system(size: 11))
      if let message = m.sharpeningMessage {
        Text(message).font(.system(size: 10)).foregroundStyle(m.measuringTarget ? Color.secondary : Color.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      note("在线性扫描数据上按实测 MTF 反卷积；强度在调整面板逐张设置。配置只适用于测量时的片夹与对焦高度。")
    }
  }

  // MARK: Film

  var filmTab: some View {
    VStack(alignment: .leading, spacing: 18) {
      sectionTitle("胶片", symbol: "film")
      TextField("输入胶片类型", text: $m.filmName).textFieldStyle(.roundedBorder).onSubmit { m.matchFilm() }
      HStack {
        Button("应用") { m.matchFilm() }
        Menu("预设") { ForEach(m.profiles) { p in Button(p.name) { m.chooseProfile(p) } } }
      }
      Text(m.profile.publication).font(.system(size: 10)).foregroundStyle(.secondary)
      Button("配置与技术文档…") { showInfo = true }.font(.system(size: 11))
      VStack(alignment: .leading, spacing: 4) {
        Text("转换依据").font(.system(size: 11, weight: .medium))
        Text(conversionBasis).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      calibrationPanel
      Divider()
      customPresets
    }
  }
  /// Where this frame's channel slopes come from, in the order the pipeline uses them.
  var conversionBasis: String {
    if m.profile.offsets != nil {
      let own = m.profile.slopes
      guard let s = m.settings.rollSlopes else { return "本机标定预设 · \(m.profile.publication)" }
      return String(format: "本机标定预设 · %@。对照：本卷按明暗过渡估计为 R %.3f · B %.3f（预设 R %.3f · B %.3f），相差很大时，这卷可能与标定时的胶片或冲洗不同。",
        m.profile.publication, s.r, s.b, own.r, own.b)
    }
    if let s = m.settings.rollSlopes {
      return String(format: "这种胶片还没有本机标定，按整卷画面里的明暗过渡自动估计通道斜率：R %.3f · G %.3f · B %.3f。画面越多越准；拍一张灰卡可以标定。", s.r, s.g, s.b)
    }
    if m.profile.setsChannelContrast { return "按 Kodak 数据表斜率（本卷画面太少，未能自动估计）。" }
    return "通用：每张按自己的画面拉伸各通道。"
  }
  /// Calibrating a preset for this scanner from neutral points picked in single view.
  var calibrationPanel: some View {
    let picking = m.tool == .calibrate
    let greens = m.calibrationPoints.map { $0.density[1] }
    let span = (greens.max() ?? 0) - (greens.min() ?? 0)
    let ready = m.calibrationPoints.count >= 2 && span >= FilmCalibration.minimumSpan
    let step =
      ready ? "③ 可以生成预设；再取几个点能检查一致性。"
      : m.calibrationPoints.isEmpty ? (picking ? "② 在单张画面上点选中性灰。" : "① 点「取中性点」开始。")
      : "② 继续点选更亮或更暗的中性灰，跨度需 0.3 D 以上。"
    return VStack(alignment: .leading, spacing: 8) {
      Text("本机预设标定").font(.system(size: 11, weight: .medium))
      HStack(spacing: 8) {
        Button {
          m.useTool(picking ? .select : .calibrate)
        } label: {
          Label(picking ? "完成取点" : "取中性点", systemImage: "scope").lineLimit(1).fixedSize()
        }.buttonStyle(HardwareKeyStyle(latched: picking)).disabled(m.selected == nil)
        Text(String(format: "%d 点 · %.2f D", m.calibrationPoints.count, span)).lcd()
      }
      Text(step).font(.system(size: 11)).foregroundStyle(ready ? Hardware.amber : Color.secondary)
      HStack(spacing: 8) {
        Button("生成 V850 预设") { m.makeScannerPreset() }.disabled(!ready)
        Button("清除") { m.clearCalibration() }.disabled(m.calibrationPoints.isEmpty)
      }
      note("先在「预设」中选好胶片，再点选同一种胶片上明暗不同的中性灰（灰卡、白墙、灰色水泥）：至少 2 个，建议 3 个以上；可以跨画面、跨卷取点。")
    }
  }
  var customPresets: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("本机预设").font(.system(size: 11, weight: .medium))
      if m.preferences.customProfiles.isEmpty {
        note("还没有本机标定或导入的预设。")
      }
      ForEach(m.preferences.customProfiles) { p in
        VStack(alignment: .leading, spacing: 4) {
          Text(p.name).font(.system(size: 11))
          Text(String(format: "R %.3f · G %.3f · B %.3f", p.slopes.r, p.slopes.g, p.slopes.b)).lcd(9)
          HStack {
            Button("使用") { m.chooseProfile(p) }.disabled(m.profile == p)
            Button("导出…") { m.exportProfile(p) }
            Button("删除") { m.deleteCustomProfile(p.id) }
          }.font(.system(size: 10)).controlSize(.mini)
        }
      }
      Button("导入 JSON…") { m.importProfile() }.font(.system(size: 11))
      note("删除只从列表中移除，已经使用它的工程保留自己的副本。")
    }
  }

  // MARK: Output

  var outputTab: some View {
    let format = Binding(
      get: { ExportFormat(rawValue: m.exportType) ?? .tiff },
      set: { m.exportType = $0.rawValue; m.preferences.exportFormat = $0 })
    let sheet = Binding(get: { m.preferences.sheet }, set: { m.preferences.sheet = $0 })
    return VStack(alignment: .leading, spacing: 18) {
      sectionTitle("导出", symbol: "square.and.arrow.up")
      labeled("格式") {
        Picker("", selection: format) { ForEach(ExportFormat.allCases) { Text($0.title).tag($0) } }.labelsHidden()
      }
      if format.wrappedValue == .jpeg {
        VStack(spacing: 3) {
          HStack {
            Text("JPEG 质量").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text("\(Int((m.preferences.jpegQuality * 100).rounded()))").lcd()
          }
          Fader(title: "JPEG 质量", value: Binding(get: { m.preferences.jpegQuality }, set: { m.preferences.jpegQuality = $0 }),
            range: 0.6...1, detent: 0.97)
        }
      }
      HStack {
        Button("导出当前…") { m.exportImages(all: false) }.disabled(m.selected == nil || m.isWorking)
        Button("导出勾选…") { m.exportImages(all: true) }.disabled(m.enabledCount == 0 || m.isWorking)
      }.font(.system(size: 11))
      Toggle("扫描后自动导出正片", isOn: Binding(get: { m.preferences.autoExport }, set: { m.preferences.autoExport = $0 }))
        .toggleStyle(LEDToggleStyle()).font(.system(size: 11))
      note("扫描保存的是保留色罩的原始负片（Originals）；去色罩的正片默认在整批扫完后按当前调整和上面的格式导出到工程的 Exports 文件夹。之后改了调整需要重新导出；为接触表进行的扫描不单独导出。")
      Divider()
      sectionTitle("接触表", symbol: "square.grid.3x2")
      Picker("排列", selection: sheet.style) {
        Text("胶片条").tag(ContactSheet.Layout.Style.strips)
        Text("网格").tag(ContactSheet.Layout.Style.grid)
      }.pickerStyle(.segmented).labelsHidden()
      labeled(m.preferences.sheet.style == .strips ? "每条" : "每行") {
        Picker("", selection: sheet.columns) {
          Text(m.preferences.sheet.style == .strips ? "自动（6）" : "自动").tag(0)
          ForEach(3...8, id: \.self) { Text("\($0) 张").tag($0) }
        }.labelsHidden()
      }
      labeled("背景") {
        Picker("", selection: sheet.whitePaper) {
          Text("白色相纸").tag(true)
          Text("黑色").tag(false)
        }.labelsHidden()
      }
      labeled("方向") {
        Picker("", selection: sheet.followRotation) {
          Text("按每张旋转").tag(true)
          Text("胶片方向").tag(false)
        }.labelsHidden()
      }
      HStack {
        Toggle("片号", isOn: sheet.numbers).toggleStyle(LEDToggleStyle())
        Toggle("标题", isOn: sheet.title).toggleStyle(LEDToggleStyle())
      }.font(.system(size: 11))
      Button {
        m.exportContactSheet()
      } label: {
        Label("导出接触表…", systemImage: "square.grid.3x2")
      }.buttonStyle(HardwareKeyStyle(prominent: true)).disabled(m.enabledCount == 0 || m.isWorking)
      note("把勾选的画面排成一张 1200 dpi 图片，格式同上。尚未扫描或低于 1200 dpi 的画面会先以 1200 dpi 扫描。")
    }
  }

  func note(_ text: String) -> some View {
    Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
  func reveal(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

/// A draggable edge between a side panel and the workspace; the width is kept in settings.
struct PanelDivider: View {
  @Binding var width: Double
  let range: ClosedRange<Double>
  /// The panel sits left of the divider (dragging right widens it) or right of it.
  let panelOnLeft: Bool
  @State private var start: Double?
  var body: some View {
    Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1)
      .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()))
      .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { drag in
            let base = start ?? width
            start = base
            let delta = Double(drag.translation.width) * (panelOnLeft ? 1 : -1)
            width = min(range.upperBound, max(range.lowerBound, base + delta))
          }
          .onEnded { _ in start = nil })
      .help("拖动调整面板宽度")
      .zIndex(1)  // keep the grab area above the workspace next to it
  }
}

/// The measured horizontal and vertical MTF against lp/mm, with 50% and 10% guides.
struct MTFChart: View {
  let profile: SharpeningProfile
  var body: some View {
    let top = max(profile.horizontal.last?.cyclesPerMM ?? 1, profile.vertical.last?.cyclesPerMM ?? 1)
    let vertical = Color(red: 0.55, green: 0.78, blue: 0.95)
    VStack(alignment: .leading, spacing: 4) {
      GeometryReader { g in
        let w = g.size.width, h = g.size.height
        let point = { (p: SharpeningProfile.Point) in CGPoint(x: p.cyclesPerMM / top * w, y: (1 - p.mtf) * h) }
        ZStack(alignment: .topLeading) {
          Path { p in
            for level in [0.5, 0.1] {
              p.move(to: CGPoint(x: 0, y: (1 - level) * h))
              p.addLine(to: CGPoint(x: w, y: (1 - level) * h))
            }
            for f in stride(from: 10.0, to: top, by: 10) {
              p.move(to: CGPoint(x: f / top * w, y: 0))
              p.addLine(to: CGPoint(x: f / top * w, y: h))
            }
          }.stroke(Hardware.lcdText.opacity(0.15), lineWidth: 0.5)
          Path { p in p.addLines(profile.horizontal.map(point)) }.stroke(Hardware.amber, lineWidth: 1.5)
          Path { p in p.addLines(profile.vertical.map(point)) }.stroke(vertical, lineWidth: 1.5)
          Text("50%").font(.system(size: 9)).foregroundStyle(.secondary).offset(x: 2, y: 0.5 * h - 12)
          Text("10%").font(.system(size: 9)).foregroundStyle(.secondary).offset(x: 2, y: 0.9 * h - 12)
        }
      }.padding(4).background(LCDGlass())
      HStack(spacing: 10) {
        Label("横向", systemImage: "minus").foregroundStyle(Hardware.amber)
        Label("竖向", systemImage: "minus").foregroundStyle(vertical)
        Spacer()
        Text("0–\(Int(top)) lp/mm").foregroundStyle(.secondary)
      }.font(.system(size: 9))
    }
  }
}
