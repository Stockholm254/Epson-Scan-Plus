import AppKit
import SwiftUI

/// The left panel. In module ① the source and its settings, the scanner's (with storage) or the
/// camera's; in ② the film with its preset, calibrating it, its base and the frame's extent; in ③
/// the export settings. ⌘, comes back to ①'s.
extension ContentView {
  var leftPanel: some View {
    VStack(spacing: 0) {
      Group {
        if m.page == .capture {
          Picker("来源", selection: $m.captureSource) {
            ForEach(AppModel.CaptureSource.allCases, id: \.self) { Text($0.short).tag($0).help($0.rawValue) }
          }
        } else if m.page != .library {
          // ② the film, its preset and calibrating it, its base and the frame's extent; ③ exporting:
          // each step its own, named, not a tab of the other's.
          Text(m.convertStep == .demask ? "② 胶片与画面" : "③ 输出").font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
      }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.vertical, 10)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          // One tab over the other as they change, cross-fading, not one under the other.
          ZStack(alignment: .topLeading) {
            if m.page == .capture {
              switch m.captureSource {
              case .scanner: scanTab.transition(.opacity)
              case .camera: cameraTab.transition(.opacity)
              }
            } else {
              switch m.convertStep {
              case .demask: filmTab.transition(.opacity)
              case .grade: outputTab.transition(.opacity)
              }
            }
          }
          .animation(.easeInOut(duration: 0.18), value: m.convertStep)
          .animation(.easeInOut(duration: 0.18), value: m.captureSource)
          Spacer(minLength: 16)
        }.padding(16).buttonStyle(.bordered).controlSize(.small)
      }
    }
  }

  // MARK: Scan

  var scanTab: some View {
    VStack(alignment: .leading, spacing: 18) {
      titled("扫描仪", symbol: "scanner", info:
        "原始文件是未反相的负片，保留橙色色罩，作存档和重新转换用；去色罩的正片默认在扫完后导出到 Exports（格式和位置在 ③ 调色左栏的「输出」里）。无损压缩对扫描数据几乎无效（LZW 反而变大），因此不压缩。\n\n整幅预览用于识别画面、接触表和看片镜。600 dpi 时每张 35 mm 约 850 像素，未正式扫描的画面也能看清细节；300 dpi 并不比 600 dpi 快多少，所以不提供。\n\n扫描仪每次扫描都自己设定读数的高低：正式扫描的蓝色比预览高约 11%，比一张宽的窗口还每次不同。每张正式扫描到达时都和预览里同一块逐像素配准，换算到预览的标尺上，片基和全卷斜率估计都在这个标尺上测，所以整卷一致。原始文件不改动。\n\n反转片（幻灯片、正片）：扫描仪的读法和负片一样，都是线性、不反相的透射读数；区别在转换。反转片的读数本身就是画面，不去色罩、不用通道斜率，按线性读数配平和定色阶，再编码到屏幕。默认保留片子本来的颜色（不自动白平衡）。识别画面时找透光的画面，片框、片夹和片间未曝光的黑边都不算。反转片的暗部很密（最大密度 3 以上），最暗处的噪点比负片多，这台扫描仪的接口没有多次曝光。"
          + (m.scanner.ready ? "\n\n" + m.scanner.captureNote : ""))
      HStack(alignment: .top, spacing: 8) {
        StatusLED(lamp: lampState.lamp, size: 7).padding(.top, 4)
        Text(m.scanner.name).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 12) {
        labeled("胶片") {
          Picker("", selection: Binding(get: { m.reversalRoll }, set: { m.setReversal($0) })) {
            Text("彩色负片").tag(false)
            Text("反转片（正片）").tag(true)
          }.labelsHidden().disabled(m.isWorking)
            .help("这一卷是负片还是反转片；下一次预览沿用。还没正式扫描时切换会按新的片种重新识别画面。② 去色罩的「胶片」一节里也能切换")
        }
        labeled("来源") {
          Text(m.reversalRoll ? "透射光 · 不反相" : "透射光 · 保留负片").font(.system(size: 12)).foregroundStyle(.secondary)
        }
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
        SwitchRow("按行合并扫描", isOn: Binding(get: { m.preferences.rowScanning }, set: { m.preferences.rowScanning = $0 }),
          info: "并排的几张一次扫完，再分成每张的原始文件，和单独扫描的一样保存。按 V850 实测，一个装满的 135 片夹（18 张）从约 13 分钟缩短到约 9 分钟。\n\n只在合起来更快时才合并：片夹里只有一条胶片、或一排只勾了一张时照常逐张扫；隔着一条的两张也分开扫。\n\n比一张宽的扫描窗口，扫描仪每次校准的蓝色增益不同（实测 −0.4% 到 +3.8%），黑电平也会漂；每张扫描到达时都和预览对齐，修正后和单独扫描相差不到 0.15%。只用于 48-bit 接口。",
          off: m.isWorking)
      }
      HStack {
        Button("重新连接") { m.scanner.reconnect() }
        // Named for what it does: 「Epson…」 read as a cut-off label.
        Button("打开 Epson Scan 2") { m.openEpson() }
          .help("把扫描仪交给 Epson Scan 2 并打开它（用完回来点「重新连接」）")
      }.font(.system(size: 11)).disabled(m.isWorking)
      Divider()
      titled("存储", symbol: "externaldrive", info:
        "每次预览或导入会在这里新建工程文件夹：原始负片在 Originals，自动导出的正片在 Exports。更改位置只影响之后新建的工程。")
      Text((m.libraryURL.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
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
      Divider()
      titled("画面", symbol: "rectangle.dashed", info:
        "预览后自动识别画面。点接触表上的一张进入单张，在单张里用「画框」细调裁切：拖四角缩放，拖框内移动。漏掉的画面用「手动画框」在接触表上拖出新的画框。")
      labeled("规格") {
        Picker("", selection: Binding(get: { m.format }, set: { m.setFormat($0) })) {
          ForEach(FilmFormat.offered(keeping: m.format), id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden()
          .help("这一卷的画幅：扫描时按它识别画面，翻拍时按它算画面在胶片上的大小（看片镜的视场、导出的 dpi）；和 ② 去色罩「胶片」里的画幅是同一个")
      }
      Button {
        m.singleView = false
        m.detectFrames()
      } label: {
        Label("自动识别画面", systemImage: "rectangle.3.group")
      }.disabled(m.overview == nil || m.isWorking)
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
        }.disabled(m.selected == nil).help("删除所选画面（⌫）").accessibilityLabel("删除所选画面")
      }.disabled(m.isWorking)
      Divider()
      scannerSharpening
      Divider()
      scannerCalibration
    }
  }
  var scannerCalibration: some View {
    VStack(alignment: .leading, spacing: 10) {
      titled("扫描仪标定 · IT8", symbol: "squareshape.split.3x3", info:
        "用 IT8.7/1 透射色卡测量扫描仪的杂散光：它会抬高底片密实处的读数，使高光发灰。测量后，本程序的线性扫描在转换前扣除它。\n\n色卡放进 4×5 片夹，预览后用「画框」框出整张色卡，以 600 dpi 正式扫描，再在单张视图中按提示点 6 个点；点到第 4 个后会标出全部色块的位置，便于检查。参考文件须与色卡批号一致（MONT45 的 2022:07 批对应 MONT45.2022.07.txt）。")
      if let c = m.preferences.scannerCalibration {
        Text(c.reference).font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
        Text(String(format: "杂散光 R %.2f%% · G %.2f%% · B %.2f%%", c.flare.r * 100, c.flare.g * 100, c.flare.b * 100)).readout()
        // The patches' 3×3 fit is the slide dyes', which no negative is converted by: not shown.
        note(String(format: "灰阶最大误差 %.3f D，扣除后 %.3f D", c.grayErrorBefore, c.grayError))
        SwitchRow("转换前扣除杂散光", isOn: Binding(get: { m.preferences.removeFlare }, set: { m.preferences.removeFlare = $0; m.reapplyScannerCalibration() }))
      } else {
        note("尚未标定。")
      }
      HStack {
        Button(m.it8Reference == nil ? "① 导入参考文件…" : "参考：\(m.it8Reference!.batch.isEmpty ? m.it8Reference!.name : m.it8Reference!.batch)") { m.importIT8Reference() }
        if m.preferences.scannerCalibration != nil { Button("移除") { m.removeScannerCalibration() } }
      }.font(.system(size: 11)).disabled(m.isWorking)
      if m.it8Reference != nil {
        HStack {
          Button("② 在色卡上取点") { m.startIT8Marking() }.disabled(m.selected == nil || m.isWorking)
          Text("\(m.it8Marks.count) / 6").readout()
          if !m.it8Marks.isEmpty { Button("退一步") { m.undoIT8Mark() } }
        }.font(.system(size: 11))
        if m.tool == .it8 && m.it8Marks.count < IT8Layout.marks.count {
          note("下一个：\(IT8Layout.marks[m.it8Marks.count]) 的中心")
        }
        Button("③ 生成标定") { m.measureIT8() }.font(.system(size: 11))
          .disabled(m.it8Marks.count < IT8Layout.marks.count || m.isWorking)
      }
    }
  }
  var scannerSharpening: some View {
    VStack(alignment: .leading, spacing: 10) {
      titled("扫描仪锐化", symbol: "scope", info:
        "导入一张分辨率标靶的扫描（需带实心方块，如 USAF 1951 或 Vlad 标靶），程序自动测量横向和竖向 MTF；扫描时让标靶略微倾斜 1–5°。\n\n之后在线性扫描数据上按实测 MTF 反卷积；强度在调整面板逐张设置。配置只适用于测量时的片夹与对焦高度。")
      if let p = m.preferences.sharpening {
        let ppi = p.effectivePPI
        Text("\(p.source) · \(Int(p.targetDPI)) dpi").font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
        // On one line: worded out, the vertical figure wrapped onto a line of its own.
        Text("横向 \(Int(ppi.horizontal.rounded()).formatted()) · 竖向 \(Int(ppi.vertical.rounded()).formatted()) ppi").readout()
          .lineLimit(1).minimumScaleFactor(0.8)
        MTFChart(profile: p).frame(height: 110)
      } else {
        note("尚未建立配置。")
      }
      HStack {
        Button(m.preferences.sharpening == nil ? "导入标靶…" : "重新导入…") { m.importSharpeningTarget() }
          .disabled(m.measuringTarget)
        if m.preferences.sharpening != nil { Button("移除") { m.removeSharpeningProfile() }.disabled(m.measuringTarget) }
        if m.measuringTarget { ProgressView().controlSize(.small) }
      }.font(.system(size: 11))
      if let message = m.sharpeningMessage {
        Text(message).font(.system(size: 11)).foregroundStyle(m.measuringTarget ? Color.secondary : Color.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: Film

  /// Module ②'s film tab, under the film and its preset: calibrating the preset from neutral
  /// points, for this scanner or this copy session and named after the roll's film, so the film's
  /// preset menu lists it. Folded until wanted, held open while points are picked; managing the
  /// presets (use, export, delete, import) is in the presets table.
  var calibrationSection: some View {
    let copy = m.copyStandRoll
    return PanelSection(copy ? "翻拍预设标定" : "本机预设标定", key: "calibration", open: false, info: calibrationInfo(copy: copy),
      forced: m.tool == .calibrate || !m.calibrationPoints.isEmpty) {
      calibrationPanel
    }
  }
  /// Where this frame's channel slopes come from, in a line: the inspector's, with the whole of it
  /// (`conversionBasis`) behind its ⓘ.
  var conversionBasisShort: String {
    if m.settings.isSlide { return "反转片 · 扫描的读数就是画面，不用通道斜率" }
    // With the calibration switched off, what the film it was calibrated from comes to.
    // Where the slopes come from on a line, the three slopes under it: in the panel's width the
    // last slope wrapped onto a line of its own.
    let film = m.conversionProfile, p = film.slopes
    func slopes(_ s: RGB) -> String { String(format: "R %.3f · G %.3f · B %.3f", s.r, s.g, s.b) }
    if film.offsets != nil { return (film.id.contains("-copy-") ? "翻拍标定" : "本机标定") + "\n" + slopes(p) }
    if let s = m.settings.rollSlopes { return "全卷斜率估计\n" + slopes(s) }
    if film.setsChannelContrast { return "数据表" + (m.estimatesSlopes ? "" : "（全卷斜率估计关着）") + "\n" + slopes(p) }
    return "通用 · 每张按自己的画面拉伸各通道"
  }
  /// Letting an assistant over MCP read and adjust the conversion, and how to connect one.
  var assistantPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("AI 助手 · MCP").font(.system(size: 11, weight: .medium))
        Spacer()
        InfoButton(text: "让 Claude 等支持 MCP 的 AI 助手读取这张的转换状态（片基、通道斜率、白平衡、色阶、密度和直方图），看预览、取点，并调整去色罩和颜色，帮你判断偏色从哪里来。\n\n每次调整都能用 ⌘Z 撤销；助手不能扫描、删除或导出文件。只在本机通过只有你的账户能访问的连接工作，不经过网络。\n\nClaude Desktop：在设置 → 开发者 → 编辑配置里加入复制的配置后重启。Claude Code：在终端运行复制的命令。")
      }
      Toggle("允许 AI 助手读取和调整转换", isOn: Binding(get: { m.preferences.mcpEnabled }, set: { m.preferences.mcpEnabled = $0; m.updateMCP() }))
        .toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 11))
      Text(m.mcpStatus).font(.system(size: 11)).foregroundStyle(m.preferences.mcpEnabled ? Hardware.amberText : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Claude Desktop 配置") {
          copy("{\n  \"mcpServers\": {\n    \"epscan\": {\n      \"command\": \"\(m.mcpCommand)\",\n      \"args\": [\"--mcp\"]\n    }\n  }\n}")
        }
        .help("把 Claude Desktop 的配置复制到剪贴板")
        Button("Claude Code 命令") { copy("claude mcp add epscan -- \"\(m.mcpCommand)\" --mcp") }
          .help("把添加到 Claude Code 的命令复制到剪贴板")
      }.font(.system(size: 11)).controlSize(.mini)
    }
  }
  func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  /// Where this frame's channel slopes come from, in the order the pipeline uses them.
  var conversionBasis: String {
    // Why the roll's slopes were not estimated, as the estimate found it.
    let slopeWhy = m.selected.flatMap { m.rollSlopesWhy[$0.id] } ?? "本卷画面太少"
    if m.settings.isSlide {
      return "反转片：扫描的线性读数本身就是画面，不去色罩，也不用预设的通道斜率。按白平衡和色阶把线性的光配好，再按 Gamma 2.2 编码到屏幕，像在看片台上看片子。预设和胶片名只用来命名和记录。在 ① 采集 · 扫描仪的「胶片」里切回负片。"
    }
    let film = m.conversionProfile
    // The roll's calibrated preset, switched off: what it converts as instead, then how.
    let off = film.id == m.profile.id ? ""
      : "「\(calibrationSwitchTitle)」关着：这一卷按标定之前的胶片 \(film.name) 转换，预设「\(m.profile.name)」本身不变。"
    if film.offsets != nil {
      let own = m.profile.slopes
      guard let s = m.settings.rollSlopes else { return "本机标定预设 · \(m.profile.publication)" }
      // On the copy stand the roll's estimate follows what the pictures hold (much foliage puts its
      // blue low), so it is no sign the roll differs.
      if m.copyStandRoll {
        return String(format: "本机标定预设 · %@。对照：本卷按明暗过渡估计为 R %.3f · B %.3f（预设 R %.3f · B %.3f）；翻拍卷的这个估计会随画面内容偏，比如树叶多时蓝偏低，以标定为准。",
          m.profile.publication, s.r, s.b, own.r, own.b)
      }
      return String(format: "本机标定预设 · %@。对照：本卷按明暗过渡估计为 R %.3f · B %.3f（预设 R %.3f · B %.3f），相差很大时，这卷可能与标定时的胶片或冲洗不同。",
        m.profile.publication, s.r, s.b, own.r, own.b)
    }
    if !off.isEmpty {
      if let s = m.settings.rollSlopes {
        return off + String(format: "斜率按整卷画面里的明暗过渡自动估计：R %.3f · G %.3f · B %.3f。", s.r, s.g, s.b)
      }
      return off + (film.setsChannelContrast
        ? String(format: m.estimatesSlopes ? "估计不了斜率（\(slopeWhy)），按数据表：R %.3f · G %.3f · B %.3f。" : "「全卷斜率估计」关着，按数据表：R %.3f · G %.3f · B %.3f。",
          film.slopes.r, film.slopes.g, film.slopes.b)
        : "估计不了斜率（\(slopeWhy)），每张按自己的画面拉伸各通道。")
    }
    if let s = m.settings.rollSlopes {
      return m.copyStandRoll
        ? String(format: "这一卷没有用翻拍标定的预设，按整卷画面里的明暗过渡自动估计通道斜率：R %.3f · G %.3f · B %.3f。这个估计会随画面内容偏（树叶多时蓝偏低，亮的灰越亮越蓝）。同一次翻拍已经标定过的话，在检查器最上面的胶片菜单里选那一次的预设；没有的话，在白牌子、灰水泥这类本来中性的东西上取几个中性点，生成翻拍预设就准了。", s.r, s.g, s.b)
        : String(format: "这种胶片还没有本机标定，按整卷画面里的明暗过渡自动估计通道斜率：R %.3f · G %.3f · B %.3f。画面越多越准；拍一张灰卡可以标定。", s.r, s.g, s.b)
    }
    if film.setsChannelContrast {
      return !m.estimatesSlopes
        ? "按数据表斜率（\(film.publication)）：「全卷斜率估计」关着。这卷的画面是同一卷、同样的设备和设置拍或扫的话，可以打开它，按整卷画面里的明暗过渡估计斜率；能标定更准。"
        : "按数据表斜率（\(film.publication)；未能自动估计：\(slopeWhy)）。"
    }
    return "通用：每张按自己的画面拉伸各通道。"
  }
  /// What calibrating does and how, behind the section's ⓘ.
  func calibrationInfo(copy: Bool) -> String {
    copy
      ? "先在上面的「胶片」里选好胶片和预设，再在翻拍的画面上点选明暗不同、本来是中性的东西：白色的牌子或墙、灰色水泥、柏油路，最好是拍在胶片上的灰卡或灰阶：至少 3 个（两个点总在一条线上，点错了也看不出），跨度 0.3 D 以上，建议亮的和暗的各两样以上；可以跨画面、跨卷取点。\n\n原理：中性的东西三个通道反射得一样多，除掉片基以后，同一种光下的中性点从亮到暗落在一条直线上，斜率就是要标定的。所以所有点要在同一种光下：都在阳光下，或都在同一片阴影里（阴影里是天光，比阳光蓝）；中途调过翻拍灯的画面不要和之前的混。\n\n标定的是每个通道的反差（斜率），修好「越亮越偏蓝」这类随亮度变的偏色。预设还记下中性落在哪里，用它时白平衡按这一点配平，开着自动也一样：取点时那种光（比如阳光）下的灰出来是灰，别的光下拍的照片带着光的颜色，用取中性灰或冷暖调。胶片本身的色彩风格保留：不套相机色彩矩阵，也不用色卡。\n\n预设属于这一次翻拍：这台相机、这次架好的灯和这种胶片，名字里带着这一卷开拍的时间。新开的卷不会自动用它；同一次翻拍的其他卷，在胶片菜单里选它。在同一卷上再标定一次，会替换这一卷之前生成的预设，用过旧预设的工程各自留着副本。去串色在标定之前先做，标定不会替换它；标定和使用时，去串色要保持同一个状态（默认打开），预设的说明里记着标定时是哪个状态。\n\n取 4 个以上、其中有很暗的时，还会标定红、蓝通道的暗部趾部。\n\n标定出来的预设按这一卷的胶片命名，列在胶片菜单里这种胶片的预设下；在胶片架上换成这种胶片时，这次翻拍标定过的会自动用上。"
      : "先在上面的「胶片」里选好胶片和预设，再点选同一种胶片上明暗不同的中性灰（灰卡、白墙、灰色水泥）：至少 2 个，建议 3 个以上；可以跨画面、跨卷取点。\n\n取 4 个以上、其中有很暗的（如灰卡欠曝 2–3 档，绿色密度低于 0.25 D）时，还会标定红、蓝通道的暗部趾部，转换时据此还原暗部的层次和颜色。\n\n标定出来的预设按这一卷的胶片命名，列在胶片菜单里这种胶片的预设下；之后扫描或换成这种胶片时自动用上。"
  }
  /// Calibrating a preset for this scanner, or for the camera on the copy stand, from neutral points
  /// picked in single view.
  var calibrationPanel: some View {
    let picking = m.tool == .calibrate, copy = m.copyStandRoll
    let pickedGreens = m.calibrationPoints.map { $0.density[1] }
    let ready = m.calibrationPoints.count >= 2 && (pickedGreens.max() ?? 0) - (pickedGreens.min() ?? 0) >= FilmCalibration.minimumSpan
    // The points as listed: those being picked, else those the preset in use was made from.
    let rows = m.calibrationRows
    let greens = rows.compactMap(\.green)
    let span = (greens.max() ?? 0) - (greens.min() ?? 0)
    // The preset in use made here: its points are where adding begins, and each point picked or
    // taken out makes it again (`calibrateAsPicked`).
    let resumable = m.resumableCalibration
    let step =
      ready ? "③ 可以生成预设；再取几个点能检查一致性。"
      : resumable.map { n in picking
        ? "② 接着在单张画面上点选本来是中性的东西：每加一个点就重新生成这个预设（现在 \(n) 个点）；⌫ 去掉最后一个。"
        : "已有这个预设的 \(n) 个点：点「添加点」在它们上面接着点选，每加或去一个点就重新生成、替换这个预设；要从头标定，点「清除」。" }
      ?? (m.calibrationPoints.isEmpty ? (picking ? (copy ? "② 在单张画面上点选本来是中性的东西，比如白牌子、灰水泥；够两个、相差 0.3 D 以上就自动生成预设。" : "② 在单张画面上点选中性灰；够两个、相差 0.3 D 以上就自动生成预设。") : "① 点「取中性点」开始。")
      : "② 继续点选更亮或更暗的中性灰，跨度到 0.3 D 就自动生成预设。")
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button {
          m.useTool(picking ? .select : .calibrate)
        } label: {
          Label(picking ? "完成取点" : resumable != nil ? "添加点" : "取中性点", systemImage: CanvasTool.calibrate.symbol)
            .lineLimit(1).fixedSize()
        }.buttonStyle(KeyStyle(latched: picking)).disabled(m.selected == nil)
        .help(picking ? "结束取点" : resumable != nil ? "在「\(m.profile.name)」的中性点上接着点选，每加一个点就重新生成这个预设" : "在单张画面上点选中性灰；够两个、相差 0.3 D 就自动生成预设")
        Text(String(format: "%d 点 · %.2f D", rows.count, span)).readout()
        Spacer(minLength: 0)
      }
      Text(step).font(.system(size: 11)).foregroundStyle(ready ? Hardware.amberText : Color.secondary)
      // The points in density space, to turn and see which lie off the line, or as the channels'
      // curves: those being picked, else those the preset in use was calibrated from. Always here,
      // following each point added or taken out.
      let theirs = m.calibrationPoints.isEmpty
      let shown = theirs ? m.presetNeutralPoints : m.calibrationPoints
      if shown.count >= 2 {
        // Whose they are is said over the list below.
        NeutralSpaceView(points: shown, fit: theirs ? m.presetNeutralFit : m.calibrationFit)
      }
      // The points, a row each: the frame it is on (opened with the points marked), its green
      // density above the base, how far it lies off the line through them all, and a key to take
      // it out.
      if !rows.isEmpty {
        HStack {
          Text(m.calibrationPoints.isEmpty ? "「\(m.profile.name)」的中性点" : "中性点").font(.system(size: 11)).foregroundStyle(.secondary)
          Spacer()
          Toggle("标出", isOn: $m.showCalibrationPoints).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            .help("在 ② 的单张画面上标出这些中性点（取点时总是标出）")
        }
        VStack(spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
            // The frame's number now (frames are numbered again after one is deleted or moved),
            // else the one it had when the point was picked.
            let here = m.frames.first { $0.id == r.frame }
            HStack(spacing: 6) {
              Text("\(i + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
              Button("第 \(here?.name ?? r.name) 张") {
                m.showCalibrationPoints = true
                m.open(r.frame)
              }
              .buttonStyle(.link).font(.system(size: 11)).disabled(here == nil)
              .help(here.map { "打开第 \($0.name) 张，看中性 \(i + 1) 在哪里" } ?? "标定时的第 \(r.name) 张不在这一卷")
              Spacer(minLength: 4)
              Text(r.green.map { String(format: "G %.2f D", $0) } ?? "—").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
              Text(r.off.map { String(format: "偏 %.3f", $0) } ?? "").font(.system(size: 11)).monospacedDigit()
                .foregroundStyle((r.off ?? 0) > 0.03 ? Hardware.amberText : Color.secondary).frame(width: 62, alignment: .trailing)
                .help("离过所有点的那条线多远（红、蓝里大的那个，密度）；超过 0.03 D 的多半不是中性，或者光不一样")
              Button { m.removeCalibrationPoint(at: i) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .disabled(m.calibrationPoints.isEmpty && m.resumableCalibration == nil)
                .help(m.calibrationPoints.isEmpty ? "去掉这个点：接着这个预设标定，生成时用剩下的点替换它" : "去掉这个点")
                .accessibilityLabel("去掉中性点 \(i + 1)")
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(i % 2 == 0 ? Color.primary.opacity(0.045) : Color.clear)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
      }
      HStack(spacing: 8) {
        Button(copy ? "生成翻拍预设" : "生成 V850 预设") { m.makeScannerPreset() }.disabled(!ready)
        Button("清除") { m.clearCalibration() }.disabled(m.calibrationPoints.isEmpty && resumable == nil)
          .help(m.calibrationPoints.isEmpty && resumable != nil ? "不用这个预设的点，从头标定（预设本身留着）" : "去掉取的所有点")
        Button("管理…") {
          m.presetsFocus = m.profile.offsets != nil ? m.profile.id : nil
          m.showPresets = true
        }
        .help("在预设表格里看所有标定出来的预设、它们的中性点和在用的卷，选一个接着标定")
      }
    }
  }
  // MARK: Output

  /// What goes out, how, where and how big, then the key: the frames chosen, ticked or changed
  /// since their export, written straight into the folder shown. Under it the contact sheet, drawn
  /// as it will come out.
  var outputTab: some View {
    let format = Binding(
      get: { ExportFormat(rawValue: m.exportType) ?? .tiff },
      set: { m.exportType = $0.rawValue; m.preferences.exportFormat = $0 })
    let sheet = Binding(get: { m.preferences.sheet }, set: { m.preferences.sheet = $0 })
    let changed = m.changedSinceExport
    let scope = changed.isEmpty && m.exportScope == .changed ? AppModel.ExportScope.chosen : m.exportScope
    let items = m.exportItems(scope)
    let ticked = m.frames.filter(\.enabled)
    return VStack(alignment: .leading, spacing: 18) {
      titled("导出", symbol: "square.and.arrow.up", info:
        "上面选导出哪些：当前这张（⌘ / ⇧ 在胶片条或灯箱上点选几张时是所选的几张）、勾选的画面，或导出以后又改过调整的画面。按下面的键直接写进「位置」里的文件夹，不再弹出窗口；工具栏的「导出」和 ⌘E 仍会先问位置和格式；⌥⇧⌘E 和这个键一样，直接导出当前或所选的。\n\n胶片条上画面右上角的 ✓ 表示导出过、之后没再改；铅笔表示导出以后又改过调整或换了预设，再导出一次才是现在的样子。导出时等着的画面带虚线圈，正在写的那张带箭头；状态栏里有进度和「停止」，写完正在写的那张就停，写好的文件留着。\n\nsRGB 以外的色彩空间在转换后嵌入 ICC 配置文件，饱和度推到 sRGB 以外的颜色会保留；ProPhoto 请配合 16-bit 格式。\n\n文件名：{film} 胶片简称（如 portra160、velvia50）　{name} 胶片名　{frame} 片号　{roll} 工程文件夹　{date} 扫描日期。同名文件已存在时自动加序号，不会覆盖。导出文件写入胶片、片号、扫描仪和扫描日期等元数据。\n\n大小按画面的裁切、拉直和方向算；TIFF 不压缩，是准的，PNG 和 JPEG 按胶片扫描通常的压缩估计。\n\n扫描保存的是保留色罩的原始负片（Originals）；打开自动导出时，去色罩的正片在整批扫完后按当前调整和上面的格式导出到工程的 Exports 文件夹。为接触表进行的扫描不单独导出。")
      Picker("导出哪些", selection: Binding(get: { scope }, set: { m.exportScope = $0 })) {
        Text(m.multiSelected ? "所选 \(m.selection.count) 张" : "当前这张").tag(AppModel.ExportScope.chosen)
        Text("勾选 \(ticked.count) 张").tag(AppModel.ExportScope.ticked)
        if !changed.isEmpty { Text("改过 \(changed.count) 张").tag(AppModel.ExportScope.changed) }
      }.pickerStyle(.segmented).labelsHidden()
        .help("导出哪些画面：当前这张（或 ⌘ / ⇧ 点选的几张）、勾选的，或导出以后又改过的")
      exportPresetRow
      labeled("格式") {
        Picker("", selection: format) { ForEach(ExportFormat.allCases) { Text($0.title).tag($0) } }.labelsHidden()
      }
      if format.wrappedValue == .jpeg {
        VStack(spacing: 3) {
          HStack {
            Text("JPEG 质量").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            ValueField(title: "JPEG 质量", text: "\(Int((m.preferences.jpegQuality * 100).rounded()))", value: m.preferences.jpegQuality,
              range: 0.6...1, scale: 100) { m.preferences.jpegQuality = $0 }
          }
          Fader(title: "JPEG 质量", value: Binding(get: { m.preferences.jpegQuality }, set: { m.preferences.jpegQuality = $0 }),
            range: 0.6...1, detent: 0.97)
        }.transition(.opacity.combined(with: .move(edge: .top)))
      }
      labeled("色彩空间") {
        Picker("", selection: Binding(get: { m.preferences.exportColorSpace }, set: { m.preferences.exportColorSpace = $0 })) {
          ForEach(ExportColorSpace.allCases) { Text($0.title).tag($0) }
        }.labelsHidden()
      }
      // As Lightroom's 调整大小以适合 · 长边: the frame's own size, or smaller to a long edge.
      labeled("尺寸") {
        Picker("", selection: Binding(get: { m.preferences.exportLongEdge }, set: { m.preferences.exportLongEdge = $0 })) {
          Text("原尺寸").tag(0)
          Divider()
          ForEach(Preferences.longEdges, id: \.self) { px in Text("长边 \(String(px)) 像素").tag(px) }
        }.labelsHidden()
          .help("导出的大小：原尺寸，或把长边缩到这么多像素（只缩小、不放大，按原图调好色、锐化以后再缩）；dpi 跟着换算。1080 合适发社交网络，2048–3000 合适网页和屏幕")
      }
      if m.preferences.exportColorSpace == .proPhoto && !format.wrappedValue.sixteenBit {
        Text("ProPhoto 请配合 16-bit 格式，8-bit 容易出现色阶断层。").font(.system(size: 11)).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 4) {
        labeled("文件名") {
          TextField(ExportNaming.standard, text: Binding(get: { m.preferences.exportNameTemplate }, set: { m.preferences.exportNameTemplate = $0 }))
            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
        }
        // What it comes to, for the frame shown.
        Text("例：" + m.exportName(for: m.selected))
          .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .trailing)
          .help("按上面的模板，这一张导出时的文件名；同名已存在时自动加序号")
      }
      // As Lightroom's export metadata: who made it and the notice, in every file exported.
      labeled("作者") {
        TextField("不写", text: Binding(get: { m.preferences.exportArtist }, set: { m.preferences.exportArtist = $0 }))
          .textFieldStyle(.roundedBorder).font(.system(size: 11))
          .help("写进每个导出文件的作者（TIFF 的 Artist、IPTC 的 By-line、PNG 的 Author），Lightroom、照片 App 和访达都读得到；空着就不写")
      }
      labeled("版权") {
        TextField("比如 © 2026 某某", text: Binding(get: { m.preferences.exportCopyright }, set: { m.preferences.exportCopyright = $0 }))
          .textFieldStyle(.roundedBorder).font(.system(size: 11))
          .help("写进每个导出文件的版权声明（TIFF 的 Copyright、IPTC 的 Copyright Notice、PNG 的 Copyright）；空着就不写")
      }
      labeled("位置") { exportFolderMenu }
      exportSummary(items, format: format.wrappedValue)
      VStack(spacing: 6) {
        if m.exporting && m.exportProgress.total > 0 {
          // While it runs the key is its progress, with the key that stops it.
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(m.exportProgress.label).font(.system(size: 11)).monospacedDigit().lineLimit(1)
              Spacer()
              Button("停止") { m.stopExports() }.controlSize(.small).help("写完正在写的这张就停；写好的文件留着")
            }
            ProgressView(value: m.exportProgress.fraction)
          }.frame(minHeight: 28)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else {
          Button {
            m.exportHere(items)
          } label: {
            Label(exportKeyTitle(items.count, scope: scope), systemImage: "square.and.arrow.up")
              .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity)
          }.buttonStyle(KeyStyle(prominent: true)).controlSize(.regular)
            .disabled(items.isEmpty || m.isWorking || m.exportFolder == nil)
            .help("按上面的格式写进「位置」里的文件夹，不再弹出窗口")
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        Button("导出到其他位置…") { m.exportImages(items) }.buttonStyle(.link).font(.system(size: 11))
          .disabled(items.isEmpty || m.isWorking)
          .help("先选文件夹和格式，再导出这些画面")
      }.animation(.snappy(duration: 0.25), value: m.exporting)
      // The last export, its files a click away.
      if let done = m.exported, !m.exporting {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, ExportMarkView.green)
          Text(done.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(done.files) }
            .buttonStyle(.link).font(.system(size: 11)).help("在 Finder 中选中导出的 \(done.files.count) 个文件")
        }.transition(.move(edge: .top).combined(with: .opacity))
      }
      if !changed.isEmpty && scope != .changed {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "pencil.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.black, Hardware.amber)
          Text("\(changed.count) 张导出以后又改过：" + changed.prefix(6).map(\.name).joined(separator: "、") + (changed.count > 6 ? "…" : ""))
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("选它们") { withAnimation(.snappy) { m.exportScope = .changed } }.buttonStyle(.link).font(.system(size: 11))
        }.transition(.opacity)
      }
      SwitchRow("扫描后自动导出正片", isOn: Binding(get: { m.preferences.autoExport }, set: { m.preferences.autoExport = $0 }))
      Divider()
      titled("接触表", symbol: "square.grid.3x2", info:
        "把勾选的画面排成一张图片；上面的小图就是它排出来的样子，改排列、每行张数、背景和方向时跟着变。\n\n文件不超过 10 MB，方便发送：张数多、分辨率高（比如翻拍卷的预览有几千 dpi）时自动按比例缩小，不再报「过大」。格式在导出时选，和画面的导出分开记，默认 JPEG（16-bit TIFF 在 10 MB 里只放得下很小的一张）。\n\n「预览 · 立即导出」按整幅预览的分辨率（600 dpi 预览时每张 35 mm 约 850 像素）直接生成，不扫描；已正式扫描的画面按同样的分辨率读取。\n\n「1200 dpi · 先扫描」时，尚未扫描或低于 1200 dpi 的画面先以 1200 dpi 扫描，结果保存为这些画面的原始文件，再生成 1200 dpi 的接触表。")
      // As wide as the panel, as tall as the sheet's shape asks, within reason.
      let sheetAspect = SheetPreview.aspect(ticked, thumbnails: m.thumbnails, layout: m.preferences.sheet)
      let sheetFilm = m.preferences.sheet.showsFilm ? m.sheetFilm : nil
      SheetPreview(frames: ticked, thumbnails: m.thumbnails, layout: m.preferences.sheet, film: sheetFilm)
        .aspectRatio(max(0.9, sheetAspect), contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 240)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: m.preferences.sheet)
        .contentShape(Rectangle())
        .onTapGesture { if !ticked.isEmpty { sheetPreviewOpen = true } }
        .help("点一下放大看接触表排出来的样子")
        // Large, beside the panel, and still following the settings under it.
        .popover(isPresented: $sheetPreviewOpen, arrowEdge: .trailing) {
          SheetPreview(frames: ticked, thumbnails: m.thumbnails, layout: m.preferences.sheet, film: sheetFilm)
            .aspectRatio(max(0.5, sheetAspect), contentMode: .fit)
            .frame(width: 640).frame(maxHeight: 720).padding(16)
        }
        .overlay {
          if ticked.isEmpty {
            Text("没有勾选的画面").font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }
      // Only frames on the scanner's preview are scanned for it; pictures of their own files are used as they are.
      if m.frames.contains(where: { $0.sourcePath == nil }) {
        labeled("清晰度") {
          Picker("", selection: Binding(get: { m.preferences.sheet.resolution ?? .preview }, set: { m.preferences.sheet.resolution = $0 })) {
            Text("预览 · 立即导出").tag(ContactSheet.Resolution.preview)
            Text("1200 dpi · 先扫描").tag(ContactSheet.Resolution.scan)
          }.labelsHidden()
        }
      }
      // Named as the rows under it are.
      labeled("排列") {
        Picker("排列", selection: sheet.style) {
          Text("胶片条").tag(ContactSheet.Layout.Style.strips)
          Text("网格").tag(ContactSheet.Layout.Style.grid)
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
      }
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
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
      }
      labeled("方向") {
        Picker("", selection: sheet.followRotation) {
          Text("按每张旋转").tag(true)
          Text("胶片方向").tag(false)
        }.labelsHidden()
      }
      if m.preferences.sheet.style == .strips {
        SwitchRow("齿条", isOn: sheet.showsSprockets)
          .help("每条画成黑色的片边，带齿孔，片号和胶片名印在上面；关掉时照片直接排在相纸上")
      }
      SwitchRow("片号", isOn: sheet.numbers)
      SwitchRow("标题", isOn: sheet.title)
      SwitchRow("胶片图", isOn: sheet.showsFilm)
        .help("在接触表的页头画上这卷胶片：暗盒或 120 卷，和胶片架上的一样")
      Button {
        m.exportContactSheet()
      } label: {
        Label("导出接触表 · \(ticked.count) 张…", systemImage: "square.grid.3x2").frame(maxWidth: .infinity)
      }.buttonStyle(KeyStyle(prominent: true)).controlSize(.regular).disabled(ticked.isEmpty || m.isWorking)
    }
    .animation(.snappy(duration: 0.22), value: format.wrappedValue)
    .animation(.snappy(duration: 0.22), value: changed.count)
    .animation(.snappy(duration: 0.3), value: m.exportsDone)
  }
  /// The output key's words: how many, and where.
  func exportKeyTitle(_ count: Int, scope: AppModel.ExportScope) -> String {
    let what = scope == .chosen && count == 1 ? "导出这张" : "导出 \(count) 张"
    guard let folder = m.exportFolder else { return what }
    return what + "到「" + (m.exportsIntoRoll ? "本卷 Exports" : folder.lastPathComponent) + "」"
  }
  /// Where the output key writes: this roll's Exports, or a folder of its own for every roll.
  var exportFolderMenu: some View {
    let folder = m.exportFolder
    let intoRoll = m.exportsIntoRoll
    return Menu {
      Button {
        m.exportIntoRoll()
      } label: {
        Label("每一卷自己的 Exports 文件夹", systemImage: intoRoll ? "checkmark" : "folder")
      }
      if let folder, !intoRoll {
        Button {} label: { Label(folder.path, systemImage: "checkmark") }.disabled(true)
      }
      Button("选择其他文件夹…") { m.chooseExportFolder() }
      Divider()
      Button("在 Finder 中显示") { if let folder { reveal(folder) } }.disabled(folder == nil)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: intoRoll ? "archivebox" : "folder")
        Text(folder == nil ? "—" : intoRoll ? "本卷 Exports" : folder!.lastPathComponent).lineLimit(1).truncationMode(.middle)
      }.font(.system(size: 12))
    }
    .menuStyle(.borderlessButton).fixedSize()
    .help(folder.map { "导出到 " + $0.path + (intoRoll ? "（每一卷导出到自己的 Exports）" : "") } ?? "还没有打开的卷")
  }
  /// How big the files come out, and whether they fit where they go.
  /// Export presets, as Lightroom's: the app's three and the user's own; the current settings'
  /// name, or 自定义 when they are none of them.
  var exportPresetRow: some View {
    labeled("预设") {
      Menu(m.currentExportPreset?.name ?? "自定义") {
        ForEach(ExportPreset.builtins) { p in Button(p.name) { m.applyExportPreset(p) } }
        if !m.preferences.exportPresets.isEmpty {
          Divider()
          ForEach(m.preferences.exportPresets) { p in Button(p.name) { m.applyExportPreset(p) } }
        }
        Divider()
        Button("把现在的设置存为预设…") {
          let alert = NSAlert()
          alert.messageText = "存为导出预设"
          alert.informativeText = "格式、质量、色彩空间、尺寸和文件名存在一个名字下；导出的位置不存。"
          let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
          field.placeholderString = "比如：冲印 · TIFF 8-bit · sRGB"
          alert.accessoryView = field
          alert.addButton(withTitle: "存")
          alert.addButton(withTitle: "取消")
          alert.window.initialFirstResponder = field
          if alert.runModal() == .alertFirstButtonReturn { m.saveExportPreset(named: field.stringValue) }
        }
        if !m.preferences.exportPresets.isEmpty {
          Menu("删除预设") {
            ForEach(m.preferences.exportPresets) { p in Button(p.name, role: .destructive) { m.deleteExportPreset(p) } }
          }
        }
      }.fixedSize()
        .help("导出预设：一次换好格式、质量、色彩空间、尺寸和文件名，像 Lightroom 的导出预设；也能把现在的设置存成自己的")
    }
  }
  func exportSummary(_ items: [FilmFrame], format: ExportFormat) -> some View {
    let pixels = items.compactMap(m.exportedPixels)
    let shown = (m.selected.flatMap { s in items.first { $0.id == s.id } } ?? items.first).flatMap(m.exportedPixels)
    let quality = m.preferences.jpegQuality
    let total = pixels.reduce(0) { $0 + ExportEstimate.bytes($1, format: format, quality: quality) }
    let free = m.exportFolder.flatMap(ExportEstimate.freeSpace)
    let previews = items.filter { !$0.hasFullResolution }.count
    // Labels dim, figures lit, as on the scanner's LCD.
    func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
      HStack {
        Text(label).foregroundStyle(Hardware.lcdText.opacity(0.5))
        Spacer()
        Text(value).foregroundStyle(warn ? Color.orange : Hardware.lcdText.opacity(0.95))
      }
    }
    return VStack(alignment: .leading, spacing: 3) {
      if let s = shown {
        row("\(Int(s.width)) × \(Int(s.height))", String(format: "%.1f MP", s.width * s.height / 1e6))
      }
      row(items.count == 1 ? "1 个文件" : "\(items.count) 个文件", (format == .tiff || format == .tiff8 ? "" : "约 ") + ExportEstimate.text(total))
      if let free { row("剩余", ExportEstimate.text(free), warn: free < total * 1.05) }
      if previews > 0 {
        Text("其中 \(previews) 张还没正式扫描，按预览的分辨率导出").foregroundStyle(.orange).font(.system(size: 10.5))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .readout(10)
    .padding(.horizontal, 10).padding(.vertical, 8)
    .background(PlotScreen())
    .contentTransition(.numericText())
    .animation(.snappy, value: items.count)
    .accessibilityElement(children: .combine)
  }

  // MARK: Camera

  /// The A7R IV: what tethering will do, and until then what the camera's files need.
  var cameraTab: some View {
    VStack(alignment: .leading, spacing: 14) {
      titled("A7R IV 翻拍", symbol: "camera", info:
        "联机默认直连相机自己的 PTP（和 Imaging Edge 一样），也可以在下面改用 Sony Camera Remote SDK。A7R IV 只能用 USB 连接，相机的 USB 连接方式选「PC 遥控」。\n\n两种都能取实时取景、半按快门自动对焦、设对焦点、手动对焦步进、对焦放大，并把拍好的 RAW 直接传到电脑。直连时像素位移的开关和张数在连接里直接改，取景不停；用 SDK 时要先断开，用 PTP 改好再连上。电子快门、像素位移的间隔和 RAW 的压缩方式要在相机上设好。")
      CameraPanel(m: m, camera: m.camera)
      Divider()
      copyFlareSection
    }
  }
  /// The copy stand's stray light, measured on a copy of an IT8 target as the scanner's is.
  var copyFlareSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      titled("翻拍杂散光 · IT8", symbol: "squareshape.split.3x3", info:
        "镜头和翻拍台的杂散光会抬高底片密实处的读数，使高光发灰。用 IT8.7/1 透射色卡像翻拍底片一样拍一张（同一个镜头、灯和片夹），在 ② 的单张视图里按提示点 6 个点，生成后翻拍的原片在转换前扣除它。\n\n杂散光随曝光变：测量时记下那张的快门、ISO 和光圈，之后每张按自己的曝光换算；没有曝光信息的文件（不是相机原片）不扣。参考文件须与色卡批号一致。")
      if let c = m.preferences.copyFlare {
        Text(c.calibration.reference).font(.system(size: 11)).lineLimit(2).truncationMode(.middle)
        Text(String(format: "杂散光 R %.2f%% · G %.2f%% · B %.2f%%", c.calibration.flare.r * 100, c.calibration.flare.g * 100, c.calibration.flare.b * 100)).readout()
        note(String(format: "灰阶最大误差 %.3f D，扣除后 %.3f D", c.calibration.grayErrorBefore, c.calibration.grayError)
          + (c.exposure == nil ? "；测量的那张没有曝光信息，扣不了" : ""))
        SwitchRow("转换前扣除杂散光", isOn: Binding(get: { m.preferences.removeFlare }, set: { m.preferences.removeFlare = $0; m.reapplyScannerCalibration() }))
      } else {
        note("尚未标定。")
      }
      HStack {
        Button(m.it8Reference == nil ? "① 导入参考文件…" : "参考：\(m.it8Reference!.batch.isEmpty ? m.it8Reference!.name : m.it8Reference!.batch)") { m.importIT8Reference() }
        if m.preferences.copyFlare != nil {
          Button("移除") {
            m.preferences.copyFlare = nil
            m.reapplyScannerCalibration()
          }
        }
      }.font(.system(size: 11)).disabled(m.isWorking)
      if m.it8Reference != nil {
        HStack {
          Button("② 在色卡上取点") { m.startIT8Marking() }.disabled(m.selected?.sensorRead != true || m.isWorking)
            .help(m.selected?.sensorRead == true ? "在单张视图里依次点 6 个点" : "先在胶片条上选翻拍的色卡那一张（相机原片）")
          Text("\(m.it8Marks.count) / 6").readout()
          if !m.it8Marks.isEmpty { Button("退一步") { m.undoIT8Mark() } }
        }.font(.system(size: 11))
        if m.tool == .it8 && m.it8Marks.count < IT8Layout.marks.count {
          note("下一个：\(IT8Layout.marks[m.it8Marks.count]) 的中心")
        }
        Button("③ 生成标定") { m.measureIT8() }.font(.system(size: 11))
          .disabled(m.it8Marks.count < IT8Layout.marks.count || m.isWorking)
      }
    }
  }
  /// Module ①'s right panel: with the camera the last picture's focus check first, then the roll as
  /// the library files it.
  var rollPanel: some View {
    let full = m.frames.filter(\.hasFullResolution).count
    return ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if m.captureSource == .camera {
          FocusCheck(m: m, camera: m.camera)
          Divider()
        }
        sectionTitle("本卷", symbol: "archivebox")
        if m.sessionURL == nil {
          note("预览、扫描或导入之后，这一卷会自动放进库里。")
        } else {
          VStack(alignment: .leading, spacing: 4) {
            Text("卷名").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(m.sessionURL.flatMap { RollLibrary.started($0.lastPathComponent) }.map(RollLibrary.title) ?? "卷名", text: $m.rollName)
              .textFieldStyle(.roundedBorder)
          }
          labeled("胶片") {
            // The film as the shelf, ②'s film section and the library draw it.
            HStack(spacing: 6) {
              let now = NewProjectSheet.current(m)
              FilmObject(look: NewProjectSheet.look(now, m: m), gauge: NewProjectSheet.gauge(now, format: m.format))
                .frame(width: 18, height: 24)
              Text(FilmCalibration.film(m.filmName)).font(.system(size: 12)).lineLimit(1)
            }.help(m.filmName)
          }
          labeled("画面") { Text("\(m.frames.count) 张 · 全分辨率 \(full)").readout(10) }
          VStack(alignment: .leading, spacing: 4) {
            Text("备注").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("相机、镜头、冲洗、地点……", text: $m.rollNotes, axis: .vertical).lineLimit(3...6)
              .textFieldStyle(.roundedBorder)
          }
          if let url = m.sessionURL {
            labeled("文件夹") {
              Text(url.lastPathComponent).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
            Button("在 Finder 中显示") { reveal(url) }.font(.system(size: 11))
          }
        }
        Divider()
        Button {
          m.page = .library
        } label: {
          Label("回到库", systemImage: "archivebox").frame(maxWidth: .infinity)
        }.help("库（⇧⌘L）：所有的卷，新建工程和导入")
        Button {
          m.page = .convert
        } label: {
          Label("下一步：② 去色罩", systemImage: "arrow.right").frame(maxWidth: .infinity)
        }.buttonStyle(KeyStyle(prominent: true)).disabled(m.frames.isEmpty)
        note("胶片名和预设在 ② 去色罩里选。")
      }.padding(18).buttonStyle(.bordered).controlSize(.small)
    }
      .onChange(of: m.rollName) { m.saveProject() }
      .onChange(of: m.rollNotes) { m.saveProject() }
  }

  /// A section title with its longer explanation behind an ⓘ.
  func titled(_ text: String, symbol: String, info: String) -> some View {
    HStack {
      sectionTitle(text, symbol: symbol)
      Spacer()
      InfoButton(text: info, about: text)
    }
  }
  func note(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
  func reveal(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

/// A small ⓘ that opens a longer explanation, so the panel shows its controls and keeps the
/// reading for when it is wanted.
struct InfoButton: View {
  let text: String
  /// What it explains, for VoiceOver: "白平衡的说明" rather than a row of "说明".
  var about: String? = nil
  @State private var shown = false
  var body: some View {
    Button {
      shown.toggle()
    } label: {
      Image(systemName: shown ? "info.circle.fill" : "info.circle").font(.system(size: 12))
        .foregroundStyle(shown ? Hardware.amberText : Hardware.adaptive(NSColor(white: 0.6, alpha: 1), NSColor(white: 0.42, alpha: 1)))
    }.buttonStyle(.plain).help("说明").accessibilityLabel(about.map { "\($0)的说明" } ?? "说明")
      .popover(isPresented: $shown, arrowEdge: .trailing) {
        Text(text).font(.system(size: 12)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
          .frame(width: 320, alignment: .leading).padding(14).textSelection(.enabled)
      }
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
          Text("50%").font(.system(size: 9)).foregroundStyle(Hardware.lcdText.opacity(0.6)).offset(x: 2, y: 0.5 * h - 12)
          Text("10%").font(.system(size: 9)).foregroundStyle(Hardware.lcdText.opacity(0.6)).offset(x: 2, y: 0.9 * h - 12)
        }
      }.padding(4).background(PlotScreen())
      HStack(spacing: 10) {
        Label("横向", systemImage: "minus").foregroundStyle(Hardware.amber)
        Label("竖向", systemImage: "minus").foregroundStyle(vertical)
        Spacer()
        Text("0–\(Int(top)) lp/mm").foregroundStyle(.secondary)
      }.font(.system(size: 9))
    }
  }
}
