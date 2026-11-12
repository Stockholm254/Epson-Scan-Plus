import AppKit
import SwiftUI

/// The 去漏光 page: the picture before and after on the left, the steps on the right, the roll's
/// filmstrip below to choose a frame from.
struct LeakPage: View {
  @ObservedObject var m: AppModel
  @ObservedObject var lab: LeakLab
  /// The selected frame of the roll on the page: its job, opened or begun; with none selected, the
  /// job used last. An imported file stays open until a frame is picked.
  func follow() {
    guard let f = m.selected, let origin = m.leakOrigin(f) else {
      if lab.job == nil { lab.restoreLast() }
      return
    }
    if lab.job?.origin?.frame == origin.frame && lab.job?.origin?.project == origin.project { refresh() } else { lab.open(origin: origin) }
  }
  /// The job open, when it is the selected frame's and that frame's conversion changed since,
  /// converted again as it is now.
  func refresh() {
    guard lab.busy == nil, let f = m.selected, let origin = m.leakOrigin(f), lab.stale(for: origin) else { return }
    lab.reload(origin: origin)
  }
  var body: some View {
    // The panel is the window's inspector.
    LeakViewer(lab: lab, choose: lab.chooseFile, arriving: m.selectedID.flatMap { m.thumbnails[$0] })
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    // In the glass look the picture runs on, blurred, behind the viewer's surround and the panel.
    .background { PictureExtension(image: lab.after ?? lab.before) }
    // Arriving from ② or another frame picked: that frame, as it is converted now. A job opened,
    // or work finished, on the frame whose colour was changed in ② since: brought up to it.
    .onAppear { follow() }
    .onChange(of: m.selectedID) { follow() }
    .onChange(of: lab.job?.id) { refresh() }
    .onChange(of: lab.busy) { if lab.busy == nil { refresh() } }
    // ② changed while the page is open (⌘Z, an assistant's adjust, another preset): brought up to it.
    .onChange(of: m.selected?.adjustments) { refresh() }
    .onChange(of: m.profile.id) { refresh() }
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
  /// The frame on its way in, from the strip: shown dimmed while it is read.
  var arriving: CGImage? = nil
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
        // A frame of the roll faces as ② turns it: turned here, its repair could not go into ③.
        Group {
          Button {
            lab.rotate(by: -90)
          } label: {
            Image(systemName: "rotate.left")
          }.help(lab.geometryIsTheRolls ? "方向在 ② 去色罩里转（单张视图下面的旋转键）" : "左转 90°：重建正片预览；已有参考图会自动匹配方向，本地免费重算")
          Button {
            lab.rotate(by: 90)
          } label: {
            Image(systemName: "rotate.right")
          }.help(lab.geometryIsTheRolls ? "方向在 ② 去色罩里转（单张视图下面的旋转键）" : "右转 90°")
        }.disabled(lab.geometryIsTheRolls)
      }.buttonStyle(.bordered).controlSize(.small).disabled(!lab.hasBase || lab.busy != nil)
        .padding(.horizontal, 16).padding(.vertical, 10)
      ZStack {
        if let before = lab.before {
          picture(before)
        } else if lab.busy != nil, let small = arriving {
          // A frame of the roll on its way in from ②: its picture from the strip, dimmed, under the
          // progress, rather than the empty page flashing up.
          Image(decorative: small, scale: 1).resizable().aspectRatio(contentMode: .fit)
            .opacity(0.45).padding(40).transition(.opacity)
        } else {
          VStack(spacing: 12) {
            Image(systemName: "wand.and.rays").font(.system(size: 34)).foregroundStyle(Hardware.amber.opacity(0.8))
            Text("选择需要去漏光的照片").font(.system(size: 15, weight: .medium))
            Text("在下方胶片条点一张本卷的照片，按 ② 去色罩的结果处理；\n或导入其他软件已去色罩、反相的正片（推荐带 ICC 的 16 位 TIFF）。")
              .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("导入正片…", action: choose).buttonStyle(KeyStyle(prominent: true)).disabled(lab.busy != nil)
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
            .background(RoundedRectangle(cornerRadius: 4).fill(lab.holdOriginal ? Hardware.amber.opacity(0.35) : Color.primary.opacity(0.08)))
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60, perform: {}, onPressingChanged: { lab.holdOriginal = $0 })
            .accessibilityAddTraits(.isButton).help("按住时显示原片，松开回到当前对比")
        }
        // At most three lines, the whole of it under the pointer. Left to take its full height, it
        // is measured for the window's minimum at no width, a character to a line: a repair's
        // 72-character notice made the page taller than the window, the strip pushed out of it.
        Text(lab.notice).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1...3)
          .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).help(lab.notice)
      }.padding(.horizontal, 16).padding(.vertical, 10)
    }.background(Hardware.adaptive(NSColor(red: 0.105, green: 0.11, blue: 0.115, alpha: 1), NSColor(white: 0.93, alpha: 1)).opacity(Hardware.glass ? 0.45 : 1))
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
    Text(text).font(.system(size: 11, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 3)
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
        // A frame of the roll comes in as ② leaves it and is graded in ③: its own adjustments here
        // would show a picture ③ never gets. Shown on one only while some are left to set back.
        if !lab.geometryIsTheRolls || lab.adjusted {
          Divider()
          adjustments
        }
      }.padding(18).buttonStyle(.bordered).controlSize(.small)
    }
    // Back into the roll's flow, pinned under the sections: the repair into ③ 调色, or on without it.
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if frame != nil {
        VStack(spacing: 6) {
          Divider()
          let why = lab.whyNotIntoGrading
          Button {
            m.applyLeakRepair()
          } label: {
            Label("用到 ③ 调色", systemImage: "arrow.right").frame(maxWidth: .infinity)
          }.buttonStyle(KeyStyle(prominent: true)).controlSize(.regular)
            .disabled(why != nil || lab.busy != nil)
            .help(why ?? "把这次去漏光放进这张照片的转换：回到 ③ 调色，之后的调色、导出、接触表都在修好的照片上；原片不改，随时可以在 ③ 里去掉")
          if let why { note(why).frame(maxWidth: .infinity, alignment: .leading) }
          HStack {
            Button("返回 ② 去色罩") { m.station = .demask }.help("回到 ② 去色罩；这次的修改留在任务里，下次打开接着修")
            Spacer()
            Button("不修，到 ③ 调色") { m.station = .grade }.help("这张不用去漏光，直接到 ③ 调色")
          }.buttonStyle(.link).font(.system(size: 11))
        }.padding(.horizontal, 18).padding(.vertical, 10).background(.bar)
      }
    }
  }
  func header(_ text: String, symbol: String, info: String) -> some View {
    HStack {
      SectionTitle(text: text, symbol: symbol)
      Spacer()
      InfoButton(text: info)
    }
  }
  func note(_ text: String, color: Color = .secondary) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
  }
  /// The frame the job came from, while it is in the open roll.
  var frame: FilmFrame? {
    guard let origin = lab.job?.origin, origin.project == m.projectPath else { return nil }
    return m.frames.first { $0.id == origin.frame }
  }

  var photo: some View {
    VStack(alignment: .leading, spacing: 10) {
      header("照片", symbol: "photo", info: "去漏光在 ② 去色罩和 ③ 调色之间，可选。本卷的照片按 ② 去色罩的结果（去掉色罩、配好白平衡和黑白场，不带 ③ 的调色）在本机转换为 Adobe RGB 16 位正片后处理，不用先导出再导入。修好以后点「用到 ③ 调色」，修复就放进这张照片的转换里，回到 ③ 接着调色和导出；原片不改，随时可以在 ③ 里去掉。也可以照旧在这一页「导出」修好的正片（不带 ③ 的调色）。以前建立的任务是从调好色的正片开始的，只能导出。\n\n也可以导入其他软件（如 Capture One）已去色罩、反相的正片：推荐带 ICC 的全分辨率 16 位 TIFF；PNG、JPEG 也可导入，但 8 位输入不会增加真实色阶。原文件不改动，任务保存在 App 的支持文件夹里，不写入照片库。")
      if let j = lab.job {
        Text(j.sourceName).font(.system(size: 12, weight: .medium))
        if let meta = j.meta {
          Text("\(meta.width) × \(meta.height) · 预览 \(meta.previewWidth) × \(meta.previewHeight)").font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        if let origin = j.origin {
          if let f = frame, origin.neutral != true {
            // A job from before: made of the graded picture, it can only export. Drawn again from ②,
            // its regions, protections and reference stay, the reference fitted again here, free.
            note("这个任务是以前从调好色的正片开始的，只能导出。从 ② 的结果重新载入以后就能用到 ③ 调色；区域、保护和参考图都留着，参考图在本机重新拟合，不调用 API。", color: Hardware.amberText)
            Button("从 ② 的结果重新载入") { if let o = m.leakOrigin(f) { lab.reload(origin: o) } }.disabled(lab.busy != nil)
          } else if let f = frame {
            // ② changed since is brought up to it on its own (`refresh`).
            if !f.hasFullResolution { note("这张尚未正式扫描，用的是预览像素。", color: Hardware.amberText) }
          } else {
            note("来自工程「\(URL(fileURLWithPath: origin.project).deletingLastPathComponent().lastPathComponent)」；导出前需打开该工程。")
          }
        }
      } else {
        note("在胶片条点一张本卷的照片，或用工具栏的「导入正片」。")
      }
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
        Text("场景").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Picker("场景", selection: Binding(get: { lab.params.sceneMode }, set: { lab.setScene($0) })) {
          Text("自动判断").tag("auto")
          Text("白天 / 自然光").tag("day")
          Text("夜晚 / 点光源").tag("night")
        }.labelsHidden().frame(width: 140).disabled(!lab.hasBase || lab.busy != nil)
          .help("自动判断不确定时，可手动选择。不会因此调用 API。")
      }
      // What the scene was judged to be, once it has been; before that the picker's help says it.
      if lab.params.sceneInfo != nil { note(sceneHint) }
      HStack {
        Text(!lab.hasBase ? "等待照片" : lab.repaired ? "已应用去漏光" : "尚未去漏光").readout(11)
        Spacer()
      }
      if lab.repaired {
        // A frame of the roll goes on into ③; a file imported here leaves as a file.
        note(lab.whyNotIntoGrading == nil
          ? "先检查灯光红晕、红色物体和边缘，再点下面的「用到 ③ 调色」，在 ③ 里接着调色和导出。"
          : "可以用工具栏的「导出 16 位 TIFF」导出；先检查灯光红晕、红色物体和边缘。")
      }
      else if lab.hasBase { note("不去漏光也能导出：导出的是带基础调整和片边处理的原片。") }
      Button {
        lab.start()
      } label: {
        Label("开始去漏光", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
      }.buttonStyle(KeyStyle(prominent: true)).disabled(!lab.hasBase || lab.busy != nil)
      note(lab.hasReference ? "已有参考图：在本地去漏光，不产生费用。"
        : lab.regionsAct ? "没有参考图：只校正启用的局部区域，不调用 API。"
        : "首次会用 API 生成参考图（先确认上传和费用）；不想用 API，先在「局部区域与保护」里标出漏光。")
      SwitchRow(
        "保留灯光红晕和真实红色物体",
        isOn: Binding(get: { lab.params.protectHighlights }, set: { v in lab.change("保留灯光红晕") { $0.protectHighlights = v } }),
        off: !lab.hasBase || lab.busy != nil)
      // A frame of the roll, whose de-masking region says where the photograph is: the film's edge
      // around it is cleaned on its own.
      if LeakLab.pictureHint(lab.job, lab.params) != nil {
        SwitchRow(
          "片边去漏光，边字保留",
          isOn: Binding(get: { lab.params.filmEdges != false }, set: { v in lab.change("片边去漏光") { $0.filmEdges = v ? nil : false } }),
          off: !lab.hasBase || lab.busy != nil)
          .help("照片外一圈片边单独处理：参考图里没有片边，不按它校正；片边压回片基的黑，贴着胶片边的亮线和整条的漏光去掉，边字保留原来的颜色。照片和片边的分界在这张的去色罩区域附近找，找不到的那一边不动。")
      }
      VStack(spacing: 3) {
        HStack {
          Text("去偏色强度").font(.system(size: 12)).foregroundStyle(.secondary)
          Spacer()
          if let model = lab.model {
            ValueField(title: "去偏色强度", text: "\(Int((model.strength * 100).rounded()))%", value: model.strength, range: 0...1, scale: 100) {
              lab.setStrength($0)
            }.disabled(lab.busy != nil)
          } else {
            Text("未应用").readout()
          }
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
      header("参考图", symbol: "photo.on.rectangle", info: "参考图由 OpenAI 图像模型生成：只在你确认后上传最长边 1536 px、无 EXIF 的正片 JPEG 缩图及附加要求，原尺寸照片留在本机。每次 1 张，不自动重试；失败或超时仍可能已计费。\n\n已有参考图后，重新应用、换场景、旋转都在本地免费重算，不再调用 API。也可以导入在别处得到的同一张照片的干净参考图，比如用你自己订阅的图像模型（ChatGPT 等）按「导出缩图…」和「复制提示词」做的。\n\n没有参考图时，标出的局部区域也能单独去漏光，不调用 API。")
      Text(lab.job?.guideName ?? "尚无参考图").font(.system(size: 11, weight: .medium))
      // What the request was, for a bill or a question about it; out of the way otherwise.
      if let receipt {
        DisclosureGroup("生成记录") { note(receipt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          .font(.system(size: 11))
      }
      if lab.hasReference { note(fitInfo) }
      Text("OpenAI · \(credentials.model) · " + (credentials.configured ? (credentials.remembered ? "钥匙串已连接" : "临时 Key 已配置") : "尚未配置 Key（工具栏「API 管理」）"))
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
      PanelSection("用自己订阅的图像模型做", key: "leakOwnModel", open: false,
        info: "缩图和提示词与 API 用的一样，导出缩图时提示词一起复制。在 ChatGPT 等能改图的应用里上传缩图、粘贴提示词，下载生成的图，再用「导入已有参考图…」导回来。这样不用 API Key。",
        level: .sub
      ) {
        HStack {
          Button("导出缩图…") { lab.chooseReferenceUpload() }
          Button("复制提示词") { lab.copyReferencePrompt() }
        }.disabled(!lab.hasBase || lab.busy != nil)
      }
      if lab.model != nil {
        Button("停用参考校正") { lab.clearReferenceCorrection() }.disabled(lab.busy != nil)
      }
    }
  }

  var adjustments: some View {
    PanelSection("基础调整", key: "leakAdjust", info: "导入的文件没有 ② 和 ③，在这里调颜色和明暗，再用「导出」：在去漏光之前作用于原片，只在这一页。本卷的照片按 ② 去色罩的结果进来，颜色和明暗在 ③ 里调，没有这一节。\n\n曝光按线性光的 EV 调整，冷暖与绿 / 品红按通道调整，对比度为 S 形曲线。手动调整不受去漏光的限制。", symbol: "slider.horizontal.3") {
      VStack(alignment: .leading, spacing: 10) {
        if lab.geometryIsTheRolls {
          note("本卷照片的颜色和明暗在 ③ 调：这里的调整用到 ③ 时不带过去，归零后这一节就收起。")
        }
        fader("曝光", "%+.2f EV", \.exposure, -2...2)
        fader("冷 ↔ 暖", "%+.0f", \.temperature, -100...100)
        fader("绿 / 洋红", "%+.0f", \.tint, -100...100)
        fader("对比度", "%+.0f", \.contrast, -50...80)
      }
    }.disabled(!lab.hasBase || lab.busy != nil)
  }
  func fader(_ title: String, _ format: String, _ key: WritableKeyPath<LeakParams, Double>, _ range: ClosedRange<Double>) -> some View {
    let set: (Double) -> Void = { v in
      let step = range.upperBound - range.lowerBound > 10 ? 1.0 : 0.05
      lab.change(title) { $0[keyPath: key] = (v / step).rounded() * step }
    }
    return VStack(spacing: 3) {
      HStack {
        Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        ValueField(title: title, text: sliderText(format, lab.params[keyPath: key]), value: lab.params[keyPath: key], range: range, set: set)
      }
      Fader(title: title, value: Binding(get: { lab.params[keyPath: key] }, set: set), range: range, detent: 0)
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
      }.disabled(lab.busy != nil).help("导入已去色罩、反相的正片 TIFF、PNG 或 JPEG")
      history
      Button {
        lab.showAPI = true
      } label: {
        Label("API 管理", systemImage: "key")
      }
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
    }.leadingAction().disabled(!lab.exportable)
      .help(lab.repaired
        ? "导出原图裁切尺寸的 RGB 16 位 Adobe RGB TIFF，旁边附同一像素的 sRGB JPEG 预览和参数记录（.tif.json）。所有输出结构来自原片；只写入你选择的文件"
        : lab.hasBase ? "这张没有去漏光：导出的是带基础调整和片边处理的原片，原图裁切尺寸的 RGB 16 位 Adobe RGB TIFF，旁边附 sRGB JPEG 和参数记录；只写入你选择的文件"
        : "打开照片后可导出")
  }
}

/// The footer's readout on the 去漏光 page.
struct LeakStatus: View {
  @ObservedObject var lab: LeakLab
  var body: some View {
    HStack(spacing: 12) {
      if lab.busy != nil { ProgressView().controlSize(.small) }
      Text(lab.busy ?? (lab.hasBase ? "就绪 · 原片未改动" : "去漏光 · 选择一张照片")).font(.system(size: 11)).foregroundStyle(.secondary)
        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
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
        .font(.system(size: 11)).foregroundStyle(credentials.storageError == nil ? Color.secondary : Hardware.amberText)
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
          .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
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

/// A panel section's title, as the system sets one, its symbol in the accent.
struct SectionTitle: View {
  let text: String
  let symbol: String
  var body: some View {
    Label {
      Text(text).font(.system(size: 13, weight: .semibold))
    } icon: {
      Image(systemName: symbol).foregroundStyle(Hardware.amberText)
    }
  }
}
