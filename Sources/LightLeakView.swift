import AppKit
import SwiftUI

/// The 去漏光 page: the picture before and after on the left, the steps on the right, the roll's
/// filmstrip below to choose a frame from.
struct LeakPage: View {
  @ObservedObject var m: AppModel
  @ObservedObject var lab: LeakLab
  var body: some View {
    HStack(spacing: 0) {
      LeakViewer(lab: lab, choose: lab.chooseFile).frame(maxWidth: .infinity, maxHeight: .infinity)
      PanelDivider(
        width: Binding(get: { m.preferences.rightWidth + 40 }, set: { m.preferences.rightWidth = $0 - 40 }),
        range: (Preferences.rightWidths.lowerBound + 40)...(Preferences.rightWidths.upperBound + 40), panelOnLeft: false)
      LeakPanel(m: m, lab: lab).frame(width: m.preferences.rightWidth + 40).padding(Hardware.glass ? 8 : 0)
    }
    // In the glass look the picture runs on, blurred, behind the viewer's surround and the panel.
    .background { PictureExtension(image: lab.after ?? lab.before) }
    .onAppear {
      if lab.job == nil {
        if let f = m.selected, let origin = m.leakOrigin(f) { lab.open(origin: origin) } else { lab.restoreLast() }
      }
    }
    .onChange(of: m.selectedID) {
      if let f = m.selected, let origin = m.leakOrigin(f) { lab.open(origin: origin) }
    }
    .sheet(isPresented: $lab.showAPI) { LeakAPISheet(credentials: lab.credentials, shown: $lab.showAPI) }
    .sheet(isPresented: $lab.showGenerate) { LeakGenerateSheet(lab: lab, credentials: lab.credentials) }
    .sheet(isPresented: $lab.showAlign) { LeakAlignSheet(lab: lab) }
    .sheet(isPresented: $lab.showCrop) { LeakCropSheet(lab: lab) }
    .alert("无法完成去漏光", isPresented: Binding(get: { lab.errorText != nil }, set: { if !$0 { lab.errorText = nil } })) {
      Button("好") { lab.errorText = nil }
    } message: {
      Text(lab.errorText ?? "")
    }
  }
}

/// The picture: the repair, with the original wiped in from the left or held to compare.
struct LeakViewer: View {
  @ObservedObject var lab: LeakLab
  var choose: () -> Void
  @State private var draft = LeakDraft()
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(lab.job.map { title($0) } ?? "尚未选择照片").font(.system(size: 12, weight: .medium)).lineLimit(1)
        Spacer()
        if lab.reference != nil {
          Picker("显示", selection: $lab.showReference) {
            Text("结果").tag(false)
            Text("参考图").tag(true)
          }.pickerStyle(.segmented).frame(width: 130).help("参考图只提供平滑的色彩校正；结果的每个像素都来自原片")
        }
        Button {
          lab.rotate(by: -90)
        } label: {
          Image(systemName: "rotate.left")
        }.help("左转 90°：重建正片预览；已有参考图会自动匹配方向，本地免费重算")
        Button {
          lab.rotate(by: 90)
        } label: {
          Image(systemName: "rotate.right")
        }.help("右转 90°")
      }.buttonStyle(HardwareKeyStyle()).controlSize(.small).disabled(!lab.hasBase || lab.busy != nil)
        .padding(.horizontal, 16).padding(.vertical, 10)
      ZStack {
        if let before = lab.before {
          picture(before)
        } else {
          VStack(spacing: 12) {
            Image(systemName: "wand.and.rays").font(.system(size: 34)).foregroundStyle(Hardware.amber.opacity(0.8))
            Text("选择需要去漏光的照片").font(.system(size: 15, weight: .medium))
            Text("在下方胶片条点一张本卷的照片，按它当前的调色处理；\n或导入其他软件已去色罩、反相的正片（推荐带 ICC 的 16 位 TIFF）。")
              .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("导入正片…", action: choose).buttonStyle(HardwareKeyStyle(prominent: true)).disabled(lab.busy != nil)
          }
        }
        if let busy = lab.busy {
          VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(busy).font(.system(size: 11))
          }.padding(14).floatingPlate(RoundedRectangle(cornerRadius: 8), text: Color(white: 0.92), opacity: 0.78)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Text("修复前").font(.system(size: 11)).foregroundStyle(.secondary)
          Fader(title: "前后对比", value: $lab.wipe, range: 0...1).disabled(lab.after == nil || lab.showReference)
          Text("去漏光后").font(.system(size: 11)).foregroundStyle(.secondary)
          Text("按住看原片").font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(lab.holdOriginal ? Hardware.amber.opacity(0.35) : Color.white.opacity(0.08)))
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60, perform: {}, onPressingChanged: { lab.holdOriginal = $0 })
            .accessibilityAddTraits(.isButton).help("按住时显示原片，松开回到当前对比")
        }
        Text(lab.notice).font(.system(size: 11)).foregroundStyle(Color(white: 0.82)).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
      }.padding(.horizontal, 16).padding(.vertical, 10)
    }.background(Color(red: 0.105, green: 0.11, blue: 0.115).opacity(Hardware.glass ? 0.45 : 1))
  }
  func title(_ j: LeakJob) -> String {
    let size = j.meta.map { " · \($0.width) × \($0.height)" } ?? ""
    return j.sourceName + size + " · 正片输入"
  }
  /// The repair, the original over its left part up to the wipe, both fitted to the space.
  func picture(_ before: CGImage) -> some View {
    GeometryReader { g in
      let shown = lab.showReference ? (lab.reference ?? before) : (lab.after ?? before)
      let aspect = Double(shown.width) / Double(shown.height)
      let w = min(g.size.width - 24, (g.size.height - 24) * aspect), h = w / aspect
      let wipe = lab.holdOriginal ? 1 : (lab.after == nil || lab.showReference ? 0 : lab.wipe)
      ZStack(alignment: .topLeading) {
        Image(decorative: shown, scale: 1).resizable().interpolation(.high)
        if !lab.showReference {
          Image(decorative: before, scale: 1).resizable().interpolation(.high)
            .mask(alignment: .leading) { Rectangle().frame(width: w * wipe) }
          if wipe > 0 && wipe < 1 {
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 1.5).offset(x: w * wipe - 0.75)
          }
          // A glass handle on the line: drag it, or anywhere on the picture, to move the line.
          if lab.after != nil && !lab.holdOriginal {
            // With SwiftUI's glass a tall lens of clear glass, the picture seen through it.
            Image(systemName: "arrow.left.and.right").font(.system(size: 13, weight: .semibold))
              .frame(width: Liquid.available ? 30 : 38, height: Liquid.available ? 72 : 38)
              .liquid(Capsule(), LiquidStyle(clear: true)) { $0.floatingPlate(Circle(), text: Color(white: 0.95), opacity: 0.6) }
              .position(x: min(max(w * wipe, 22), w - 22), y: h / 2)
              .allowsHitTesting(false)
          }
        }
        HStack {
          if !lab.showReference && wipe > 0 { tag("修复前") }
          Spacer()
          if lab.showReference { tag("参考图") } else if wipe < 1 { tag(lab.repaired && lab.after != nil ? "去漏光后" : "尚未去漏光") }
        }.padding(8)
      }
      .frame(width: w, height: h)
      .overlay {
        if lab.showMasks && !lab.showReference {
          LeakMasks(params: lab.params, selected: lab.selectedRegion, draft: draft, brush: lab.brush).allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { drag in self.drag(drag.location, w: w, h: h) }
          .onEnded { drag in self.finish(drag.location, w: w, h: h) })
      .overlay(alignment: .bottomTrailing) {
        if lab.updating { ProgressView().controlSize(.mini).padding(8) }
      }
      .position(x: g.size.width / 2, y: g.size.height / 2)
    }
  }
  /// A drag on the picture: compares (or moves the region under it) when looking; draws a
  /// region, places its clean point or paints a protection with the tools.
  func drag(_ location: CGPoint, w: CGFloat, h: CGFloat) {
    // The tools draw on the original; on the reference they would land in the wrong place.
    guard lab.busy == nil, lab.tool == .inspect || !lab.showReference else { return }
    let p = CGPoint(x: min(1, max(0, location.x / w)), y: min(1, max(0, location.y / h)))
    let first = !draft.began
    draft.began = true
    switch lab.tool {
    case .inspect:
      if first, lab.showMasks, !lab.showReference, let hit = lab.regionAt(LeakPoint(x: p.x, y: p.y)) {
        lab.selectedRegion = hit.id
        draft.moving = (hit.id, p, CGPoint(x: hit.x ?? 0.5, y: hit.y ?? 0.5))
      }
      if let m = draft.moving {
        lab.moveRegion(m.id, x: m.original.x + p.x - m.start.x, y: m.original.y + p.y - m.start.y)
      } else if lab.after != nil, !lab.showReference {
        lab.wipe = Double(p.x)
      }
    case .ellipse:
      if first { draft.start = p }
      draft.now = p
    case .reference:
      break
    case .protect:
      let q = [Double(p.x), Double(p.y)]
      if let last = draft.stroke.last {
        if hypot(q[0] - last[0], q[1] - last[1]) > 0.003 && draft.stroke.count < 2000 { draft.stroke.append(q) }
      } else {
        draft.stroke.append(q)
      }
    }
  }
  func finish(_ location: CGPoint, w: CGFloat, h: CGFloat) {
    defer { draft = LeakDraft() }
    guard lab.busy == nil, draft.began, lab.tool == .inspect || !lab.showReference else { return }
    let p = CGPoint(x: min(1, max(0, location.x / w)), y: min(1, max(0, location.y / h)))
    switch lab.tool {
    case .ellipse:
      guard let a = draft.start else { return }
      let b = draft.now ?? p
      if abs(b.x - a.x) > 0.01 || abs(b.y - a.y) > 0.01 {
        lab.addRegion(x: Double(a.x + b.x) / 2, y: Double(a.y + b.y) / 2, rx: Double(abs(b.x - a.x)) / 2, ry: Double(abs(b.y - a.y)) / 2)
      }
    case .reference:
      lab.setReference(LeakPoint(x: p.x, y: p.y))
    case .protect:
      lab.addProtection(draft.stroke)
    case .inspect:
      break
    }
  }
  func tag(_ text: String) -> some View {
    Text(text).font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 3)
      .floatingPlate(Capsule(), text: Color(white: 0.92), opacity: 0.6)
  }
}

/// The steps: the photograph, the repair, the reference, basic adjustments and export.
struct LeakPanel: View {
  @ObservedObject var m: AppModel
  @ObservedObject var lab: LeakLab
  @ObservedObject private var credentials: LeakCredentials
  init(m: AppModel, lab: LeakLab) {
    self.m = m
    self.lab = lab
    credentials = lab.credentials
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        photo
        Divider()
        repair
        Divider()
        reference
        Divider()
        LeakRegionsSection(lab: lab)
        Divider()
        adjustments
        Divider()
        export
      }.padding(18).buttonStyle(HardwareKeyStyle()).controlSize(.small)
    }.consolePanel()
  }
  func header(_ text: String, symbol: String, info: String) -> some View {
    HStack {
      SectionTitle(text: text, symbol: symbol)
      Spacer()
      InfoButton(text: info)
    }
  }
  func note(_ text: String, color: Color = .secondary) -> some View {
    Text(text).font(.system(size: 10)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
  }
  /// The frame the job came from, while it is in the open roll.
  var frame: FilmFrame? {
    guard let origin = lab.job?.origin, origin.project == m.projectPath else { return nil }
    return m.frames.first { $0.id == origin.frame }
  }

  var photo: some View {
    VStack(alignment: .leading, spacing: 10) {
      header("照片", symbol: "photo", info: "本卷的照片按它当前的调色在本机转换为 Adobe RGB 16 位正片后处理，不用先导出再导入；导出时按建立任务时的调色重新转换全分辨率。\n\n也可以导入其他软件（如 Capture One）已去色罩、反相的正片：推荐带 ICC 的全分辨率 16 位 TIFF；PNG、JPEG 也可导入，但 8 位输入不会增加真实色阶。原文件不改动，任务保存在 App 的支持文件夹里，不写入照片库。")
      if let j = lab.job {
        Text(j.sourceName).font(.system(size: 12, weight: .medium))
        if let meta = j.meta {
          Text("\(meta.width) × \(meta.height) · 预览 \(meta.previewWidth) × \(meta.previewHeight)").font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        if let origin = j.origin {
          if let f = frame {
            if !f.hasFullResolution { note("这张尚未正式扫描，用的是预览像素；正式扫描后点「按当前调色重新载入」。", color: Hardware.amber) }
            if f.adjustments != origin.adjustments {
              note("这张的调色在建立任务后改过；导出仍按建立任务时的调色。", color: Hardware.amber)
              Button("按当前调色重新载入") { if let o = m.leakOrigin(f) { lab.reload(origin: o) } }.disabled(lab.busy != nil)
            }
          } else {
            note("来自工程「\(URL(fileURLWithPath: origin.project).deletingLastPathComponent().lastPathComponent)」；导出前需打开该工程。")
          }
        }
      } else {
        note("尚未选择照片")
      }
      Button {
        lab.chooseFile()
      } label: {
        Label("导入正片…", systemImage: "square.and.arrow.down")
      }.disabled(lab.busy != nil)
    }
  }

  var sceneHint: String {
    guard let s = lab.params.sceneInfo else { return "自动判断不确定时，可手动选择。不会因此调用 API。" }
    return "\(s.requested == "auto" ? "自动判断" : "手动选择")：\(s.label)" + (s.requested == "auto" && s.confidence < 0.35 ? "（判断不确定，可手动指定）" : "")
  }
  var repair: some View {
    VStack(alignment: .leading, spacing: 10) {
      header("去漏光", symbol: "wand.and.rays", info: "FilmLightLab 修订 9 的匹配算法：参考图只指导平滑的色彩和明暗校正，不复制 AI 生成的物体、纹理与结构；按污染程度分区减雾，夜景边缘的白色亮雾单独校正，自然亮部与局部灯光单独保护，不锁定全图亮度。\n\n场景判断按原片和参考图的亮度分布估计，是曝光启发式，不是语义识别；混合光时可手动指定。\n\n颗粒幅度及颜色会改变，不是无损恢复；已饱和或丢失的信息无法恢复，真实红色物体和灯光红晕仍需检查。")
      HStack {
        Text("场景").font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer()
        Picker("场景", selection: Binding(get: { lab.params.sceneMode }, set: { lab.setScene($0) })) {
          Text("自动判断").tag("auto")
          Text("白天 / 自然光").tag("day")
          Text("夜晚 / 点光源").tag("night")
        }.labelsHidden().frame(width: 140).disabled(!lab.hasBase || lab.busy != nil)
      }
      note(sceneHint)
      HStack {
        Text(!lab.hasBase ? "等待照片" : lab.repaired ? "已应用去漏光" : "尚未去漏光").lcd(11)
        Spacer()
      }
      Button {
        lab.start()
      } label: {
        Label("开始去漏光", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
      }.buttonStyle(HardwareKeyStyle(prominent: true)).disabled(!lab.hasBase || lab.busy != nil)
      note(lab.hasReference ? "已有参考图，点击即在本地去漏光，不产生 API 费用。" : "首次点击会通过 API 生成参考图；确认上传与费用后自动去漏光。")
      Toggle(
        "保留灯光红晕和真实红色物体",
        isOn: Binding(get: { lab.params.protectHighlights }, set: { v in lab.change("保留灯光红晕") { $0.protectHighlights = v } })
      ).toggleStyle(LEDToggleStyle()).font(.system(size: 11)).disabled(!lab.hasBase || lab.busy != nil)
      VStack(spacing: 3) {
        HStack {
          Text("去偏色强度").font(.system(size: 11)).foregroundStyle(.secondary)
          Spacer()
          Text(lab.model.map { "\(Int(($0.strength * 100).rounded()))%" } ?? "未应用").lcd()
        }
        Fader(
          title: "去偏色强度", value: Binding(get: { lab.model?.strength ?? 0 }, set: { lab.setStrength($0) }), range: 0...1, detent: 1
        ).disabled(lab.model == nil || lab.busy != nil)
      }
    }
  }

  var receipt: String? {
    guard let g = lab.job?.generatedAI else { return nil }
    let prompt = g.promptVersion == LeakOpenAI.promptVersion ? "保曝光 v2" : "旧版 / 未记录"
    let tokens = g.usage?.total_tokens.map { " · \($0) tokens" } ?? ""
    return "\(g.model) · \(g.quality) · \(g.generatedAt)\n提示词 \(prompt) · 请求 \(g.requestId ?? "未提供 ID")\(tokens)"
  }
  var fitInfo: String {
    guard let model = lab.model else { return "参考校正未应用。" }
    let a = model.alignment
    return "已应用 · 修订 \(model.revision) · \(a.rotation)° 自动方向匹配" + (a.reliable ? "" : "（对齐不确定）") + " · \(model.samples) 个样本"
  }
  var reference: some View {
    VStack(alignment: .leading, spacing: 10) {
      header("参考图", symbol: "photo.on.rectangle", info: "参考图由 OpenAI 图像模型生成：只在你确认后上传最长边 1536 px、无 EXIF 的正片 JPEG 缩图及附加要求，原尺寸照片留在本机。每次 1 张，不自动重试；失败或超时仍可能已计费。\n\n已有参考图后，重新应用、换场景、旋转都在本地免费重算，不再调用 API。也可以导入在别处得到的同一张照片的干净参考图。")
      Text(lab.job?.guideName ?? "尚无参考图").font(.system(size: 11, weight: .medium))
      if let receipt { note(receipt).textSelection(.enabled) }
      if lab.hasReference { note(fitInfo) }
      Text("OpenAI · \(credentials.model) · " + (credentials.configured ? (credentials.remembered ? "钥匙串已连接" : "临时 Key 已配置") : "尚未配置 Key"))
        .font(.system(size: 10)).foregroundStyle(.secondary)
      Button {
        if credentials.configured { lab.showGenerate = true } else { lab.showAPI = true }
      } label: {
        Label(lab.hasReference ? "重新生成参考图（调用 API）" : "生成参考图（调用 API）", systemImage: "sparkles")
      }.disabled(!lab.hasBase || lab.busy != nil)
      Button {
        lab.chooseReference()
      } label: {
        Label("导入已有参考图…", systemImage: "square.and.arrow.down.on.square")
      }.disabled(!lab.hasBase || lab.busy != nil)
      HStack {
        Button("停用参考校正") { lab.clearReferenceCorrection() }.disabled(lab.model == nil || lab.busy != nil)
        Button("API 管理…") { lab.showAPI = true }
      }
    }
  }

  var adjustments: some View {
    VStack(alignment: .leading, spacing: 10) {
      header("基础调整", symbol: "slider.horizontal.3", info: "在去漏光之前作用于原片：曝光按线性光的 EV 调整，冷暖与绿 / 品红按通道调整，对比度为 S 形曲线。手动调整不受去漏光的限制。")
      fader("曝光", "%+.2f EV", \.exposure, -2...2)
      fader("冷 ↔ 暖", "%+.0f", \.temperature, -100...100)
      fader("绿 ↔ 品红", "%+.0f", \.tint, -100...100)
      fader("对比度", "%+.0f", \.contrast, -50...80)
    }.disabled(!lab.hasBase || lab.busy != nil)
  }
  func fader(_ title: String, _ format: String, _ key: WritableKeyPath<LeakParams, Double>, _ range: ClosedRange<Double>) -> some View {
    VStack(spacing: 3) {
      HStack {
        Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer()
        Text(String(format: format, lab.params[keyPath: key])).lcd()
      }
      Fader(title: title, value: Binding(get: { lab.params[keyPath: key] }, set: { v in
        let step = range.upperBound - range.lowerBound > 10 ? 1.0 : 0.05
        lab.change(title) { $0[keyPath: key] = (v / step).rounded() * step }
      }), range: range, detent: 0)
    }
  }

  var export: some View {
    VStack(alignment: .leading, spacing: 10) {
      header("导出", symbol: "square.and.arrow.up", info: "导出原图裁切尺寸的 RGB 16 位 Adobe RGB TIFF，旁边附同一像素的 sRGB JPEG 预览和参数记录（.tif.json）。参考图只提供平滑校正参数，所有输出结构来自原片。只写入你选择的文件，不覆盖其他文件。")
      Button {
        lab.chooseExport()
      } label: {
        Label("导出 16 位 TIFF…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
      }.buttonStyle(HardwareKeyStyle(prominent: true)).disabled(!lab.repaired || lab.busy != nil)
      note(lab.repaired ? "可以导出。请先检查灯光红晕、红色物体及边缘。" : "完成去漏光后可导出。")
    }
  }
}

/// The toolbar's keys on the 去漏光 page.
struct LeakToolbar: View {
  @ObservedObject var lab: LeakLab
  var body: some View {
    HStack(spacing: 16) {
      Button {
        lab.chooseFile()
      } label: {
        Label("导入正片", systemImage: "square.and.arrow.down")
      }.disabled(lab.busy != nil).help("导入已去色罩、反相的正片 TIFF、PNG 或 JPEG").toolbarGlass("left-0")
      // The menu is not a key: with SwiftUI's glass it gets a drop of its own, in the next place.
      if Liquid.available {
        history.padding(.horizontal, 12).padding(.vertical, 5)
          .liquid(Capsule(), LiquidStyle(interactive: true)) { $0 }.toolbarGlass("left-1")
      } else {
        history
      }
      Button {
        lab.showAPI = true
      } label: {
        Label("API 管理", systemImage: "key")
      }.toolbarGlass("left-2")
    }
  }
  var history: some View {
    Menu {
      let jobs = lab.jobs()
      if jobs.isEmpty { Text("暂无任务记录") }
      ForEach(jobs.prefix(30)) { j in
        Button(j.name + (j.hasReference ? " · 已有参考图" : "") + " · " + j.modified.formatted(date: .abbreviated, time: .shortened)) { lab.open(j.id) }
      }
      Divider()
      Button("在 Finder 中显示任务文件夹") {
        try? FileManager.default.createDirectory(at: lab.root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([lab.root])
      }
    } label: {
      Label("历史任务", systemImage: "clock.arrow.circlepath")
    }.menuStyle(.borderlessButton).fixedSize().disabled(lab.busy != nil)
  }
}

/// The export key, at the toolbar's right on the 去漏光 page.
struct LeakExportKey: View {
  @ObservedObject var lab: LeakLab
  var body: some View {
    Button {
      lab.chooseExport()
    } label: {
      Label("导出 16 位 TIFF", systemImage: "square.and.arrow.up")
    }.buttonStyle(HardwareKeyStyle(prominent: true)).disabled(!lab.repaired || lab.busy != nil)
  }
}

/// The footer's readout on the 去漏光 page.
struct LeakStatus: View {
  @ObservedObject var lab: LeakLab
  var body: some View {
    HStack(spacing: 12) {
      if lab.busy != nil { ProgressView().controlSize(.small) }
      Text(lab.busy ?? (lab.hasBase ? "就绪 · 原片未改动" : "去漏光 · 选择一张照片")).lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading).lcd(11)
    }.padding(.horizontal, 18).padding(.vertical, 7)
  }
}

/// The API key: typed here, kept in memory or the Keychain, never shown again.
struct LeakAPISheet: View {
  @ObservedObject var credentials: LeakCredentials
  @Binding var shown: Bool
  @State private var key = ""
  @State private var model = LeakOpenAI.defaultModel
  @State private var remember = true
  @State private var confirmClear = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("API 管理").font(.title2)
      Text("Key 不写入照片任务、预设、日志或文件。不要把 Key 发到聊天中。").font(.system(size: 12)).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text("OpenAI API Key").font(.system(size: 12, weight: .medium))
        SecureField(credentials.configured ? "已配置；留空保留当前 Key" : "输入 Key", text: $key).textFieldStyle(.roundedBorder)
      }
      Picker("模型", selection: $model) {
        ForEach(LeakOpenAI.models, id: \.self) { Text($0).tag($0) }
      }
      Toggle("保存在 macOS 钥匙串，下次自动连接", isOn: $remember)
      Text(credentials.storageError ?? (credentials.configured
        ? (credentials.remembered ? "已从 macOS 钥匙串连接，重启后自动读取。Key 不会回显。" : "当前 Key 只在本次内存中；退出后清除。")
        : "当前没有 API Key。输入后保存；此操作不会联网验证，也不会消费额度。"))
        .font(.system(size: 11)).foregroundStyle(credentials.storageError == nil ? Color.secondary : Hardware.amber)
        .fixedSize(horizontal: false, vertical: true)
      Text("保存设置不会发起生成或产生费用。ChatGPT 订阅登录目前不支持图像生成，仍使用你的 API 账户计费。首次或 App 更新后 macOS 可能请求钥匙串授权。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let error { Text(error).font(.system(size: 11)).foregroundStyle(Hardware.greasePencil) }
      HStack {
        if credentials.storageError != nil { Button("重新读取钥匙串") { credentials.restore(interactive: true) } }
        Button("移除 Key") { confirmClear = true }.disabled(!credentials.configured && !credentials.remembered)
        Spacer()
        Button("取消") { close() }.keyboardShortcut(.cancelAction)
        Button("保存设置") {
          do {
            try credentials.update(apiKey: key, model: model, remember: remember)
            close()
          } catch { self.error = error.localizedDescription }
        }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 460)
      .onAppear {
        model = credentials.model
        remember = credentials.remembered || !credentials.configured
      }
      .confirmationDialog("移除 Key？", isPresented: $confirmClear) {
        Button("移除", role: .destructive) {
          credentials.clear()
          key = ""
        }
      } message: {
        Text("移除本 App 保存在钥匙串里的 Key 并清除本次连接。不会删除照片或参考图，也不会撤销 API 平台上的 Key。")
      }
  }
  func close() {
    key = ""
    shown = false
  }
}

/// The paid step, said plainly before it is taken.
struct LeakGenerateSheet: View {
  @ObservedObject var lab: LeakLab
  @ObservedObject var credentials: LeakCredentials
  @State private var quality = "high"
  @State private var note = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("生成参考图并去漏光").font(.title2)
      Text("点击下方按钮后，会将照片缩图（最长边 1536 px、无 EXIF）发送至 OpenAI，并由你的 API 账户计费。原尺寸照片留在本机。")
        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
      Text("本次模型：\(credentials.model) · 返回参考图后自动在本地拟合，不自动导出。").font(.system(size: 11)).foregroundStyle(.secondary)
      Picker("质量", selection: $quality) {
        Text("High").tag("high")
        Text("Medium").tag("medium")
      }.pickerStyle(.segmented).frame(width: 220)
      VStack(alignment: .leading, spacing: 4) {
        Text("附加要求（可选）").font(.system(size: 12, weight: .medium))
        TextEditor(text: $note).font(.system(size: 12)).frame(height: 64)
          .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.15)))
          .onChange(of: note) { if note.count > 2000 { note = String(note.prefix(2000)) } }
      }
      Text("提示词要求保持原始曝光和自然高光；本地按污染程度自动减雾，单独保护亮部和局部灯光，不照搬参考曝光。只生成 1 张，不自动重试；失败或超时仍可能已计费。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("取消") { lab.showGenerate = false }.keyboardShortcut(.cancelAction)
        Button("生成并去漏光（调用 API）") {
          lab.showGenerate = false
          lab.generate(quality: quality, note: note)
        }.disabled(!credentials.configured)
      }
    }.padding(24).frame(width: 480)
      .onAppear {
        quality = lab.requestedQuality ?? quality
        note = lab.requestedNote ?? note
        lab.requestedQuality = nil
        lab.requestedNote = nil
      }
  }
}

/// A panel section's title, engraved into the metal.
struct SectionTitle: View {
  let text: String
  let symbol: String
  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: symbol).foregroundStyle(Hardware.amber)
      Text(text).font(.system(size: 12, weight: .semibold)).tracking(1.5)
        .foregroundStyle(Color(white: 0.8))
    }
    .shadow(color: .black.opacity(0.9), radius: 0, y: -0.5)
    .shadow(color: .white.opacity(0.08), radius: 0, y: 0.75)
  }
}
