import AppKit
import SwiftUI

/// A drag on the 去漏光 picture while it lasts: an ellipse being drawn, a protection being
/// painted, or a region being moved.
struct LeakDraft {
  var began = false
  var start: CGPoint?
  var now: CGPoint?
  var stroke: [[Double]] = []
  var moving: (id: String, start: CGPoint, original: CGPoint)?
}

/// The leak regions (salmon) and protections (teal) over the picture, as FilmLightLab draws them,
/// with the chosen region's clean point and what is being drawn.
struct LeakMasks: View {
  let params: LeakParams
  let selected: String?
  let draft: LeakDraft
  let brush: Double
  static let leak = Color(red: 0.984, green: 0.58, blue: 0.482)
  static let protect = Color(red: 0.557, green: 0.898, blue: 0.851)
  var body: some View {
    Canvas { ctx, size in
      for r in params.regions { draw(r, Self.leak, active: r.id == selected, in: &ctx, size) }
      for r in params.protect { draw(r, Self.protect, active: false, in: &ctx, size) }
      if let ref = params.regions.first(where: { $0.id == selected })?.ref {
        let c = CGPoint(x: ref.x * size.width, y: ref.y * size.height)
        var cross = Path()
        cross.move(to: CGPoint(x: c.x - 9, y: c.y))
        cross.addLine(to: CGPoint(x: c.x + 9, y: c.y))
        cross.move(to: CGPoint(x: c.x, y: c.y - 9))
        cross.addLine(to: CGPoint(x: c.x, y: c.y + 9))
        ctx.stroke(cross, with: .color(Color(red: 1, green: 0.914, blue: 0.706)), lineWidth: 2)
      }
      if let a = draft.start, let b = draft.now {
        let rect = CGRect(x: min(a.x, b.x) * size.width, y: min(a.y, b.y) * size.height,
          width: abs(b.x - a.x) * size.width, height: abs(b.y - a.y) * size.height)
        ctx.fill(Path(ellipseIn: rect), with: .color(Color(red: 1, green: 0.79, blue: 0.63).opacity(0.13)))
        ctx.stroke(Path(ellipseIn: rect), with: .color(Color(red: 1, green: 0.79, blue: 0.63)), lineWidth: 3)
      }
      if !draft.stroke.isEmpty {
        brushed(draft.stroke, radius: brush, Color(red: 0.706, green: 1, blue: 1), in: &ctx, size)
      }
    }
  }
  func draw(_ r: LeakRegion, _ color: Color, active: Bool, in ctx: inout GraphicsContext, _ size: CGSize) {
    let fill = r.enabled == false ? 0.1 : 0.13, line: CGFloat = active ? 3 : 1.5
    switch r.shape {
    case "stroke":
      brushed(r.points ?? [], radius: r.radius ?? 0.025, color.opacity(r.enabled == false ? 0.5 : 1), in: &ctx, size)
    case "polygon":
      let points = (r.points ?? []).map { CGPoint(x: $0[0] * size.width, y: $0[1] * size.height) }
      guard points.count > 2 else { return }
      var path = Path()
      path.addLines(points)
      path.closeSubpath()
      ctx.fill(path, with: .color(color.opacity(fill)))
      ctx.stroke(path, with: .color(color), lineWidth: line)
    default:
      guard let x = r.x, let y = r.y, let rx = r.rx, let ry = r.ry else { return }
      let path = Path(ellipseIn: CGRect(x: (x - rx) * size.width, y: (y - ry) * size.height, width: 2 * rx * size.width, height: 2 * ry * size.height))
      ctx.fill(path, with: .color(color.opacity(fill)))
      ctx.stroke(path, with: .color(color), lineWidth: line)
    }
  }
  /// A brush path: round, `radius` of the picture's width.
  func brushed(_ points: [[Double]], radius: Double, _ color: Color, in ctx: inout GraphicsContext, _ size: CGSize) {
    let r = radius * size.width, shown = points.map { CGPoint(x: $0[0] * size.width, y: $0[1] * size.height) }
    guard let first = shown.first else { return }
    if shown.count == 1 {
      ctx.fill(Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: 2 * r, height: 2 * r)), with: .color(color.opacity(0.28)))
      return
    }
    var path = Path()
    path.addLines(shown)
    ctx.stroke(path, with: .color(color.opacity(0.28)), style: StrokeStyle(lineWidth: 2 * r, lineCap: .round, lineJoin: .round))
  }
}

/// The panel's 局部区域与保护: the drawing tools, automatic detection, the regions and protections
/// listed, the chosen region's settings, and the landmarks, crop and presets.
struct LeakRegionsSection: View {
  @ObservedObject var lab: LeakLab
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        SectionTitle(text: "局部区域与保护", symbol: "circle.dashed")
        Spacer()
        InfoButton(text: "在参考校正之外，手动处理局部漏光，或保护不该改动的地方。\n\n「画区域」在照片上拖出椭圆，再用「参考点」点同材质、没有漏光的干净位置：区域按它去色偏（保留亮度）或减雾（恢复暗部）。「保护」用画笔涂出真实的红色物体、灯光等，保护区里不做任何校正，手绘保护始终优先。\n\n「自动检测」找出候选区域（默认不启用，勾选后才生效）和灯光保护区；结果只是建议，不是漏光定论。\n\n「对应点」在自动对齐不确定时，手动标出原片和参考图上的同一位置（至少 4 对）。预设保存参数、区域和对应点，与 FilmLightLab 的预设文件通用；区域位置按画幅比例保存，换了照片需检查。")
      }
      Picker("工具", selection: $lab.tool) {
        Text("查看").tag(LeakLab.Tool.inspect)
        Text("画区域").tag(LeakLab.Tool.ellipse)
        Text("参考点").tag(LeakLab.Tool.reference)
        Text("保护").tag(LeakLab.Tool.protect)
      }.pickerStyle(.segmented).labelsHidden()
      Text(hint).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if lab.tool == .protect {
        HStack {
          Text("画笔").font(.system(size: 11)).foregroundStyle(.secondary)
          Fader(title: "画笔大小", value: $lab.brush, range: 0.005...0.08)
          Text("\(Int((lab.brush * 1000).rounded()))‰").readout()
        }
      }
      Toggle("在照片上显示区域", isOn: $lab.showMasks).toggleStyle(.switch).font(.system(size: 11))
      HStack {
        Button("自动检测") { lab.detect() }
        Text("灵敏度").font(.system(size: 11)).foregroundStyle(.secondary)
        Fader(title: "检测灵敏度", value: $lab.sensitivity, range: 0.1...1, detent: 0.5)
        Text("\(Int((lab.sensitivity * 100).rounded()))%").readout()
      }
      Text("漏光区域 \(lab.params.regions.count)").font(.system(size: 11, weight: .medium))
      if lab.params.regions.isEmpty {
        Text("自动检测，或用「画区域」在照片上拖出椭圆。").font(.system(size: 10)).foregroundStyle(.secondary)
      } else {
        rows(lab.params.regions, protection: false)
      }
      if let r = lab.region { controls(r) }
      if !lab.params.protect.isEmpty {
        Text("保护区 \(lab.params.protect.count)").font(.system(size: 11, weight: .medium))
        rows(lab.params.protect, protection: true)
        if lab.params.protect.contains(where: { $0.detected == true }) {
          Text("自动检测的保护区（灯光、红色小物体）每次「开始去漏光」都会重新检测，取消勾选只到下次拟合为止；手绘保护一直保留。")
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack {
        Button("对应点…") { lab.showAlign = true }.disabled(!lab.hasReference)
          .help("自动对齐不确定时，手动标出原片和参考图上的同一位置")
        Button("裁切…") { lab.showCrop = true }
      }
      HStack {
        Button("保存预设…") { lab.chooseSavePreset() }
        Button("载入预设…") { lab.chooseLoadPreset() }
      }
    }.disabled(!lab.hasBase || lab.busy != nil)
  }
  var hint: String {
    switch lab.tool {
    case .inspect: return "拖动照片比较前后；按住区域拖动可移动它。"
    case .ellipse: return "在照片上拖出椭圆，框住一处漏光。"
    case .reference: return lab.region == nil ? "先在列表里选一个区域。" : "点同材质、没有漏光的干净位置，作为「\(lab.region?.name ?? "区域")」的颜色参考。"
    case .protect: return "涂抹真实的红色物体、灯光等，保护区里不做校正。"
    }
  }
  func rows(_ list: [LeakRegion], protection: Bool) -> some View {
    VStack(spacing: 3) {
      ForEach(list) { r in
        HStack(spacing: 6) {
          Toggle("", isOn: Binding(get: { r.enabled != false }, set: { lab.setEnabled(r.id, $0) })).toggleStyle(.checkbox).labelsHidden()
          Circle().fill(protection ? LeakMasks.protect : LeakMasks.leak).frame(width: 7, height: 7)
          Text(r.name ?? "区域").font(.system(size: 11)).lineLimit(1)
          if let c = r.confidence { Text(c).font(.system(size: 9)).foregroundStyle(.secondary) }
          Spacer()
          Button {
            lab.deleteRegion(r.id)
          } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
          }.buttonStyle(.plain).help("删除")
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(r.id == lab.selectedRegion ? Hardware.amber.opacity(0.18) : Color.white.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { if !protection { lab.selectedRegion = r.id } }
      }
    }
  }
  func controls(_ r: LeakRegion) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("方式", selection: Binding(get: { r.mode ?? "chroma" }, set: { v in lab.editRegion(r.id, "区域方式") { $0.mode = v } })) {
        Text("去色偏（保留亮度）").tag("chroma")
        Text("减雾（恢复暗部）").tag("fog")
      }.font(.system(size: 11)).disabled(r.fog != nil || r.ratios != nil)
      amount("强度", r.amount ?? 1) { v in lab.editRegion(r.id, "区域强度") { $0.amount = v } }
      amount("羽化", r.feather ?? 0.7) { v in lab.editRegion(r.id, "区域羽化") { $0.feather = v } }
        .disabled(r.shape != "ellipse" || r.gaussian == true)
      Text(r.ref.map { String(format: "干净参考点：%.3f, %.3f", $0.x, $0.y) }
        ?? (r.target != nil || r.fog != nil ? "已标定的区域，可调强度。" : "尚未选参考点：用「参考点」点同材质、没有漏光的位置。"))
        .font(.system(size: 10)).foregroundStyle(r.ref == nil && r.target == nil && r.fog == nil ? Hardware.amber : .secondary)
    }.padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
  }
  func amount(_ title: String, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
    HStack {
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
      Fader(title: title, value: Binding(get: { value }, set: { set(($0 * 100).rounded() / 100) }), range: 0...1)
      Text("\(Int((value * 100).rounded()))%").readout()
    }
  }
}

/// Matching points on the original and the reference, clicked in pairs: one on the left, then the
/// same place on the right. Four or more; none aligns them as the same framing.
struct LeakAlignSheet: View {
  @ObservedObject var lab: LeakLab
  @State private var pairs: [LeakPair] = []
  @State private var pending: [Double]?
  @State private var warning: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("原片与参考图的对应点").font(.system(size: 13, weight: .semibold))
      Text("自动对齐不确定时：先在左边的原片上点一处，再在右边的参考图上点同一处。至少 4 对，尽量分散在四角附近；清空则按相同构图对齐。完成后点「开始去漏光」在本地重新拟合，不调用 API。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        board(lab.before, points: pairs.map(\.source) + (pending.map { [$0] } ?? [])) { p in pending = p }
        board(lab.reference, points: pairs.map(\.target)) { p in
          guard let s = pending, pairs.count < 20 else { return }
          pairs.append(LeakPair(source: s, target: p))
          pending = nil
        }
      }.frame(height: 320)
      Text(warning ?? info).font(.system(size: 11)).foregroundStyle(warning == nil ? .secondary : Hardware.amber)
      HStack {
        Button("撤回一点") {
          if pending != nil { pending = nil } else if !pairs.isEmpty { pairs.removeLast() }
        }
        Button("清空") {
          pairs = []
          pending = nil
        }
        Spacer()
        Button("取消") { lab.showAlign = false }.keyboardShortcut(.cancelAction)
        Button("完成") {
          guard pairs.isEmpty || pairs.count >= 4 else {
            warning = "请再补充对应点，至少需要 4 对；或清空后按相同构图使用。"
            return
          }
          lab.setPairs(pairs)
          lab.showAlign = false
        }
      }
    }.padding(20).frame(width: 780).buttonStyle(KeyStyle()).controlSize(.small)
      .onAppear { pairs = lab.pairs }
  }
  var info: String {
    "\(pairs.count) 对对应点"
      + (pending != nil ? " · 请点击右侧对应位置" : pairs.count > 0 && pairs.count < 4 ? " · 至少需要 4 对" : pairs.isEmpty ? " · 默认按相同构图对齐" : " · 将按对应点对齐")
  }
  func board(_ image: CGImage?, points: [[Double]], tap: @escaping ([Double]) -> Void) -> some View {
    GeometryReader { g in
      if let image {
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let w = min(g.size.width, g.size.height * aspect), h = w / aspect
        ZStack(alignment: .topLeading) {
          Image(decorative: image, scale: 1).resizable().interpolation(.high).frame(width: w, height: h)
          ForEach(points.indices, id: \.self) { i in
            ZStack {
              Circle().stroke(Hardware.amber, lineWidth: 2).frame(width: 14, height: 14)
              Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(Hardware.amber).offset(x: 14, y: -2)
            }.position(x: points[i][0] * w, y: points[i][1] * h)
          }
        }
        .frame(width: w, height: h)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { loc in tap([Double(min(1, max(0, loc.x / w))), Double(min(1, max(0, loc.y / h)))]) }
        .position(x: g.size.width / 2, y: g.size.height / 2)
      } else {
        Text("没有图像").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

/// The crop of the original, 0–1 of the turned picture.
struct LeakCropSheet: View {
  @ObservedObject var lab: LeakLab
  @State private var crop = LeakCrop()
  @State private var picture: CGImage?
  /// While the angle is being changed, and a moment after: a fine grid to line things up with.
  @State private var turning = 0
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("裁切原片").font(.system(size: 13, weight: .semibold))
      Text("按转好方向的原片取范围（0–1）。「拉直」让裁切范围绕中心转动（正数顺时针），裁去转出的空角，转动时显示网格线。裁切会重建正片预览，并清空区域、保护和对应点（它们的位置随画面改变）；已有参考图会在本地重新匹配，不调用 API。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      ZStack {
        if let picture {
          Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fit)
            .overlay(GeometryReader { g in
              CropRotationOverlay(crop: crop, aspect: Double(picture.width) / Double(max(1, picture.height)), fine: turning > 0)
                .frame(width: g.size.width, height: g.size.height)
            })
        } else {
          ProgressView().controlSize(.small)
        }
      }.frame(maxWidth: .infinity).frame(height: 220)
      row("左", \.x, 0...0.9)
      row("上", \.y, 0...0.9)
      row("宽", \.w, 0.1...1)
      row("高", \.h, 0.1...1)
      HStack {
        Text("拉直").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
        Fader(title: "拉直", value: Binding(get: { crop.angle ?? 0 }, set: { v in
          let a = (v * 100).rounded() / 100
          crop.angle = abs(a) < 0.005 ? nil : a
          turning += 1
          let mark = turning
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if turning == mark { turning = 0 } }
        }), range: -15...15, detent: 0)
        Text(String(format: "%+.2f°", crop.angle ?? 0)).readout()
      }
      HStack {
        Button("不裁切") { crop = LeakCrop() }
        Spacer()
        Button("取消") { lab.showCrop = false }.keyboardShortcut(.cancelAction)
        Button("应用") {
          lab.setCrop(crop)
          lab.showCrop = false
        }
      }
    }.padding(20).frame(width: 420).buttonStyle(KeyStyle()).controlSize(.small)
      .onAppear {
        crop = lab.params.crop
        lab.uncutPreview { picture = $0 }
      }
  }
  func row(_ title: String, _ key: WritableKeyPath<LeakCrop, Double>, _ range: ClosedRange<Double>) -> some View {
    HStack {
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
      Fader(title: "裁切" + title, value: Binding(get: { crop[keyPath: key] }, set: { crop[keyPath: key] = ($0 * 1000).rounded() / 1000 }), range: range)
      Text(String(format: "%.3f", crop[keyPath: key])).readout()
    }
  }
}

/// Over the uncut original: the cut, and once turned the part kept, the largest rectangle of the
/// cut's shape inside it turned back onto the original, with thirds (and a finer grid while
/// turning) across it; outside it darkened.
struct CropRotationOverlay: View {
  let crop: LeakCrop
  /// The original's width over its height.
  let aspect: Double
  var fine: Bool
  var body: some View {
    Canvas { ctx, size in
      let cut = CGRect(x: crop.x * size.width, y: crop.y * size.height, width: crop.w * size.width, height: crop.h * size.height)
      let degrees = crop.angle ?? 0
      let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { c -> CGPoint in
        let q = ImageGeometry.straightened(c, degrees: degrees, aspect: crop.w * aspect / max(0.0001, crop.h), inverse: true)
        return CGPoint(x: cut.minX + q.x * cut.width, y: cut.minY + q.y * cut.height)
      }
      var kept = Path()
      kept.addLines(corners)
      kept.closeSubpath()
      var outside = Path(CGRect(origin: .zero, size: size))
      outside.addPath(kept)
      ctx.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
      func at(_ u: Double, _ v: Double) -> CGPoint {
        let top = CGPoint(x: corners[0].x + (corners[1].x - corners[0].x) * u, y: corners[0].y + (corners[1].y - corners[0].y) * u)
        let bottom = CGPoint(x: corners[3].x + (corners[2].x - corners[3].x) * u, y: corners[3].y + (corners[2].y - corners[3].y) * u)
        return CGPoint(x: top.x + (bottom.x - top.x) * v, y: top.y + (bottom.y - top.y) * v)
      }
      func lines(_ across: Int, _ down: Int, _ opacity: Double, _ width: CGFloat) {
        var path = Path()
        for i in 1..<max(1, across) {
          path.move(to: at(Double(i) / Double(across), 0))
          path.addLine(to: at(Double(i) / Double(across), 1))
        }
        for j in 1..<max(1, down) {
          path.move(to: at(0, Double(j) / Double(down)))
          path.addLine(to: at(1, Double(j) / Double(down)))
        }
        ctx.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: width + 1)
        ctx.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: width)
      }
      if abs(degrees) > 0.0001 {
        if fine { lines(max(3, Int(cut.width / 24)), max(3, Int(cut.height / 24)), 0.28, 0.5) }
        lines(3, 3, 0.7, 0.75)
        ctx.stroke(Path(cut), with: .color(Hardware.amber.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
      }
      ctx.stroke(kept, with: .color(Hardware.amber), lineWidth: 2)
    }
    .allowsHitTesting(false)
  }
}
