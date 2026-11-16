import AppKit
import SwiftUI

/// 色阶 as Photoshop's Levels lays it out: the channel (RGB, 红, 绿, 蓝) and the three eyedroppers
/// over the histogram of the picture as it takes it in; under that the input's black, grey and
/// white points to drag (⌥ held on black or white shows what comes out pure black or white) with
/// their figures; the output's black and white over a gradient with theirs; then 自动, its options
/// and 预览. From 0.24 it is in the conversion (`Adjustments.printLevels`): its histogram runs past
/// 0 and 255 as far as the frame does, and its points with it.
struct LevelsPanel: View {
  @ObservedObject var m: AppModel
  @AppStorage("levelsChannel") private var channel = 0
  @AppStorage("levelsAutoOptions") private var optionsData = Data()
  @State private var showsOptions = false
  static let channelNames = ["RGB", "红", "绿", "蓝"]
  private var options: LevelsAutoOptions {
    get { (try? JSONDecoder().decode(LevelsAutoOptions.self, from: optionsData)) ?? LevelsAutoOptions() }
  }
  private func setOptions(_ o: LevelsAutoOptions) { optionsData = (try? JSONEncoder().encode(o)) ?? Data() }
  private var levels: Levels { m.settings.printLevels ?? Levels() }
  private var current: Levels.Channel { levels[channel] }
  /// The stretch drawn: 0–255 and past it as far as the frame goes, the points always in it.
  private var domain: ClosedRange<Double> {
    let d = (m.levelsHistogram ?? .empty).shownDomain
    return min(d.lowerBound, current.black)...max(d.upperBound, current.white)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 4) {
        // The channel, as Photoshop's 通道 menu.
        Picker("通道", selection: $channel) {
          ForEach(0..<4, id: \.self) { i in Text(Self.channelNames[i]).tag(i) }
        }
        .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
        .help("RGB：红、绿、蓝一起，三个通道各自的色阶之后再走这一层；红、绿、蓝：只调那一个通道")
        Spacer(minLength: 4)
        Button("自动") { m.autoLevelsLikePhotoshop(options) }
          .controlSize(.small).fixedSize().disabled(m.levelsHistogram == nil || m.isWorking)
          .help("按旁边选项里的算法和剪切比例自动设色阶，像 Photoshop 色阶里的「自动」；输出色阶不动，可以 ⌘Z 撤销")
        Button { showsOptions = true } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 10)) }
          .controlSize(.small).fixedSize()
          .help("自动颜色校正选项：算法、对齐中性中间调、两端剪切多少")
          .accessibilityLabel("自动选项")
          .popover(isPresented: $showsOptions, arrowEdge: .bottom) { optionsForm }
      }
      LevelsHistogramView(counts: (m.levelsHistogram ?? .empty).shown(channel), channel: channel,
        black: current.black, white: current.white, domain: domain)
      InputPoints(channel: current, domain: domain) { mark, v, option in
        switch mark {
        case .black:
          m.levelsClipping = option ? .black(channel) : nil
          m.changeLevels("色阶输入黑点") { $0[channel].black = min(max(Levels.printDomain.lowerBound, v), $0[channel].white - 2 / 255) }
        case .white:
          m.levelsClipping = option ? .white(channel) : nil
          m.changeLevels("色阶输入白点") { $0[channel].white = max(min(Levels.printDomain.upperBound, v), $0[channel].black + 2 / 255) }
        case .grey:
          m.changeLevels("色阶中间调") { $0[channel].gamma = $0[channel].gamma(at: v) }
        }
      } ended: { m.levelsClipping = nil } holding: { on in on ? m.windowGate.hold() : m.windowGate.release() }
      HStack(spacing: 6) {
        Text("输入色阶").font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer()
        figure("输入黑点", current.black * 255, Levels.printDomain.lowerBound * 255...Levels.printDomain.upperBound * 255 - 2, "%.0f") { v in
          m.changeLevels("色阶输入黑点") { $0[channel].black = min(v / 255, $0[channel].white - 2 / 255) }
        }
        figure("中间调", current.gamma, 0.10...9.99, "%.2f") { v in
          m.changeLevels("色阶中间调") { $0[channel].gamma = Levels.clampGamma(v) }
        }
        figure("输入白点", current.white * 255, Levels.printDomain.lowerBound * 255 + 2...Levels.printDomain.upperBound * 255, "%.0f") { v in
          m.changeLevels("色阶输入白点") { $0[channel].white = max(v / 255, $0[channel].black + 2 / 255) }
        }
      }
      OutputPoints(channel: current, end: channel == 0 ? .white : HistogramView.colours[channel - 1], set: { isBlack, v in
        m.changeLevels(isBlack ? "色阶输出黑点" : "色阶输出白点") { l in
          if isBlack { l[channel].outBlack = v } else { l[channel].outWhite = v }
        }
      }, holding: { on in on ? m.windowGate.hold() : m.windowGate.release() })
      HStack(spacing: 6) {
        Text("输出色阶").font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer()
        figure("输出黑点", current.outBlack * 255, 0...255, "%.0f") { v in m.changeLevels("色阶输出黑点") { $0[channel].outBlack = v / 255 } }
        figure("输出白点", current.outWhite * 255, 0...255, "%.0f") { v in m.changeLevels("色阶输出白点") { $0[channel].outWhite = v / 255 } }
      }
      HStack(spacing: 3) {
        eyedropper(.black, "黑场", .black, "在画面上点一处定为黑：这一处的红、绿、蓝各自的输入黑点设到它，像 Photoshop 的「在图像中取样以设置黑场」；读的是转换里色阶之前的值")
        eyedropper(.grey, "灰场", Color(white: 0.5), "在画面上点一处本来是灰的东西：红、绿、蓝各自的中间调调到让它成为中性灰，亮度不变")
        eyedropper(.white, "白场", .white, "在画面上点一处定为白：这一处的红、绿、蓝各自的输入白点设到它，冲过白的也读得到")
        Spacer(minLength: 4)
        Toggle("预览", isOn: Binding(get: { !m.levelsBypassed }, set: { m.levelsBypassed = !$0 }))
          .toggleStyle(.checkbox).font(.system(size: 11)).fixedSize()
          .help("关掉时画面暂时不带色阶，方便前后对比；设置不变")
        Button { m.changeLevels("复位" + Self.channelNames[channel] + "色阶", separate: true) { $0[channel] = Levels.Channel() } } label: {
          Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
        }
          .controlSize(.small).fixedSize().disabled(current.isIdentity)
          .help("复位：把这个通道的输入、中间调和输出放回原样")
          .accessibilityLabel("复位这个通道")
      }
    }
    .onDisappear { m.levelsPicker = nil }
  }
  /// An eyedropper with the point it sets beside it: a black, grey or white dot, as Photoshop's
  /// droppers are filled.
  private func eyedropper(_ picker: LevelsPicker, _ title: String, _ dot: Color, _ help: String) -> some View {
    Button { m.levelsPicker = m.levelsPicker == picker ? nil : picker } label: {
      HStack(spacing: 2) {
        Image(systemName: "eyedropper").font(.system(size: 10))
        Circle().fill(dot).overlay(Circle().stroke(Color.gray, lineWidth: 0.8)).frame(width: 8, height: 8)
      }
      .fixedSize()
    }
      .buttonStyle(KeyStyle(latched: m.levelsPicker == picker)).controlSize(.small).fixedSize()
      .help(help + "。再点一下放下吸管。")
      .accessibilityLabel(title + "吸管")
  }
  private func figure(_ title: String, _ value: Double, _ range: ClosedRange<Double>, _ format: String, _ set: @escaping (Double) -> Void) -> some View {
    ValueField(title: title, text: String(format: format, value), value: value, range: range, set: set)
      .frame(minWidth: 34, alignment: .trailing)
  }
  private var optionsForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("自动颜色校正选项").font(.system(size: 12, weight: .semibold))
      Picker("算法", selection: Binding(get: { options.algorithm }, set: { var o = options; o.algorithm = $0; setOptions(o) })) {
        ForEach(LevelsAutoOptions.Algorithm.allCases) { Text($0.name).tag($0) }
      }
      .pickerStyle(.radioGroup).font(.system(size: 11))
      Toggle("对齐中性中间调", isOn: Binding(get: { options.snapNeutralMidtones }, set: { var o = options; o.snapNeutralMidtones = $0; setOptions(o) }))
        .font(.system(size: 11))
      HStack {
        Text("剪切：阴影").font(.system(size: 11))
        ValueField(title: "阴影剪切", text: String(format: "%.2f%%", options.shadowClip), value: options.shadowClip, range: 0...9.99) { v in
          var o = options; o.shadowClip = v; setOptions(o)
        }
        Text("高光").font(.system(size: 11))
        ValueField(title: "高光剪切", text: String(format: "%.2f%%", options.highlightClip), value: options.highlightClip, range: 0...9.99) { v in
          var o = options; o.highlightClip = v; setOptions(o)
        }
      }
      Text("增强单色对比度：三个通道一起定两端，颜色不变。增强每通道的对比度：各通道各自定两端，两端的偏色去掉。查找深色与浅色：最暗、最亮那些像素的平均颜色定为黑和白。增强亮度和对比度：按亮度定两端，中间调让中等亮度落在中灰。对齐中性中间调：再把中间调里接近中性的颜色调成中性。剪切：两端各有多少像素切成纯黑、纯白。下次点「自动」按这里的选择。")
        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(width: 300, alignment: .leading)
      HStack {
        Button("恢复默认") { setOptions(LevelsAutoOptions()) }.controlSize(.small)
        Spacer()
        Button("应用") { m.autoLevelsLikePhotoshop(options); showsOptions = false }.controlSize(.small).keyboardShortcut(.defaultAction)
      }
    }
    .padding(14)
  }
}

/// 色阶's input as Photoshop's Levels draws it, over `domain` of the print's scale: the composite
/// grey, a channel in its colour, scaled to its tallest step short of the two ends; 0–255 on the
/// panel's own ground, past them on a darker one; what the input points cut dimmed.
struct LevelsHistogramView: View {
  let counts: [Double]
  let channel: Int
  let black: Double, white: Double
  var domain: ClosedRange<Double> = 0...1
  var body: some View {
    Canvas { ctx, size in
      let lo = domain.lowerBound, span = max(1e-6, domain.upperBound - domain.lowerBound)
      func x(_ v: Double) -> CGFloat { size.width * CGFloat((v - lo) / span) }
      // Past black and past white: a darker ground.
      if lo < 0 { ctx.fill(Path(CGRect(x: 0, y: 0, width: x(0), height: size.height)), with: .color(.black.opacity(0.35))) }
      if domain.upperBound > 1 { ctx.fill(Path(CGRect(x: x(1), y: 0, width: size.width - x(1), height: size.height)), with: .color(.black.opacity(0.35))) }
      let first = PrintLevelsInput.bin(lo), last = PrintLevelsInput.bin(domain.upperBound)
      let shownCounts = first <= last ? Array(counts[first...last]) : []
      let inner = shownCounts.count > 2 ? Array(shownCounts[1..<(shownCounts.count - 1)]) : shownCounts
      let peak = max(1e-9, inner.max() ?? 1)
      let colour = channel == 0 ? Color.white.opacity(0.75) : HistogramView.colours[channel - 1].opacity(0.85)
      let w = max(1, size.width / CGFloat(max(1, shownCounts.count)))
      var p = Path()
      for (k, v) in shownCounts.enumerated() where v > 0 {
        let h = size.height * CGFloat(min(1, v / peak))
        p.addRect(CGRect(x: x(PrintLevelsInput.value(first + k)) - w / 2, y: size.height - h, width: w, height: h))
      }
      ctx.fill(p, with: .color(colour))
      // 0 and 255.
      for v in [0.0, 1.0] where v > lo && v < domain.upperBound {
        ctx.stroke(Path { $0.move(to: CGPoint(x: x(v), y: 0)); $0.addLine(to: CGPoint(x: x(v), y: size.height)) },
          with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
      }
      ctx.fill(Path(CGRect(x: 0, y: 0, width: max(0, x(black)), height: size.height)), with: .color(.black.opacity(0.45)))
      ctx.fill(Path(CGRect(x: x(white), y: 0, width: max(0, size.width - x(white)), height: size.height)), with: .color(.black.opacity(0.45)))
    }
    .frame(height: 84)
    .padding(4).background(PlotScreen())
    .accessibilityElement().accessibilityLabel("色阶直方图")
    .help("色阶之前的这张，在转换里：虚线之间是 0 到 255，右边底色深的一段是冲过白的部分，左边是低于黑的部分；暗下去的两边是输入黑点、白点切掉的部分")
  }
}

/// The input's three points under the histogram: black (filled), grey and white (hollow). A press
/// within reach of one takes it where it is (the nearest, if two are close), and it then moves as
/// far as the hand: it doesn't jump to the pointer. The one held is drawn where the hand has it, the
/// window's own updates held meanwhile (`holding`), as a curve's point is; with ⌥ held on black or
/// white the picture shows what they cut. Until 0.23.17 the row was 12 points tall and the window's
/// update every half second stopped the point under the hand.
struct InputPoints: View {
  enum Mark { case black, grey, white }
  let channel: Levels.Channel
  /// The stretch of the print's scale the row spans, as the histogram over it does.
  var domain: ClosedRange<Double> = 0...1
  var set: (Mark, Double, Bool) -> Void
  var ended: () -> Void
  var holding: (Bool) -> Void = { _ in }
  @State private var held: (mark: Mark, offset: Double)?
  @State private var shown: (mark: Mark, value: Double)?
  /// How far from a point (in points) a press still takes it.
  static let reach: CGFloat = 14
  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      ZStack(alignment: .topLeading) {
        Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1).offset(y: 1)
        triangle(filled: .black, at: place(.black), w)
        triangle(filled: Color(white: 0.55), at: place(.grey), w)
        triangle(filled: .white, at: place(.white), w)
      }
      .frame(width: w, height: geo.size.height, alignment: .topLeading)
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { g in
          let span = Double(max(1, w)), lo = domain.lowerBound, range = max(1e-6, domain.upperBound - domain.lowerBound)
          if held == nil {
            let start = lo + Double(g.startLocation.x) / span * range
            let marks = [(Mark.black, channel.black), (.grey, channel.midPoint), (.white, channel.white)]
            guard let near = marks.min(by: { abs($0.1 - start) < abs($1.1 - start) }),
              abs(near.1 - start) / range * span <= Double(Self.reach) else { return }
            held = (near.0, near.1 - start)
            holding(true)
          }
          guard let held else { return }
          let v = min(domain.upperBound, max(lo, lo + Double(g.location.x) / span * range + held.offset))
          shown = (held.mark, v)
          holding(true)
          set(held.mark, v, NSEvent.modifierFlags.contains(.option) && held.mark != .grey)
        }
        .onEnded { _ in
          let was = held != nil
          held = nil
          shown = nil
          if was { holding(false) }
          ended()
        })
    }
    .frame(height: 20)
    .help("拖黑、灰、白三个三角：输入黑点、中间调、输入白点；拖黑或白时按住 ⌥，画面上显示切成纯黑或纯白的地方")
    .accessibilityElement().accessibilityLabel("输入色阶")
    .accessibilityValue(String(format: "黑点 %.0f，中间调 %.2f，白点 %.0f", channel.black * 255, channel.gamma, channel.white * 255))
  }
  /// Where a point is drawn: the one held where the hand has it, the grey between the ends as they
  /// are drawn.
  private func place(_ mark: Mark) -> Double {
    if let shown, shown.mark == mark { return shown.value }
    switch mark {
    case .black: return channel.black
    case .white: return channel.white
    case .grey: return channel.midPoint
    }
  }
  private func triangle(filled colour: Color, at v: Double, _ w: CGFloat) -> some View {
    let t = (v - domain.lowerBound) / max(1e-6, domain.upperBound - domain.lowerBound)
    return Triangle().fill(colour).overlay(Triangle().stroke(Color.gray, lineWidth: 0.8))
      .frame(width: 12, height: 11)
      .offset(x: CGFloat(min(1, max(0, t))) * w - 6, y: 3)
  }
}

/// The output's black and white over a gradient from black to white (the channel's colour on one),
/// taken and dragged as the input's are.
struct OutputPoints: View {
  let channel: Levels.Channel
  let end: Color
  var set: (Bool, Double) -> Void
  var holding: (Bool) -> Void = { _ in }
  @State private var held: (black: Bool, offset: Double)?
  @State private var shown: (black: Bool, value: Double)?
  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      ZStack(alignment: .topLeading) {
        LinearGradient(colors: [.black, end], startPoint: .leading, endPoint: .trailing)
          .frame(height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
        mark(.black, at: shown?.black == true ? shown!.value : channel.outBlack, w)
        mark(.white, at: shown?.black == false ? shown!.value : channel.outWhite, w)
      }
      .frame(width: w, height: geo.size.height, alignment: .topLeading)
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { g in
          let span = Double(max(1, w))
          if held == nil {
            let start = Double(g.startLocation.x) / span
            let black = abs(start - channel.outBlack) <= abs(start - channel.outWhite)
            let at = black ? channel.outBlack : channel.outWhite
            guard abs(at - start) * span <= Double(InputPoints.reach) else { return }
            held = (black, at - start)
            holding(true)
          }
          guard let held else { return }
          let v = min(1, max(0, Double(g.location.x) / span + held.offset))
          shown = (held.black, v)
          holding(true)
          set(held.black, v)
        }
        .onEnded { _ in
          let was = held != nil
          held = nil
          shown = nil
          if was { holding(false) }
        })
    }
    .frame(height: 24)
    .help("拖黑、白两个三角：输出的黑和白，最暗的印成多暗、最亮的印成多亮；交叉过去画面反相")
    .accessibilityElement().accessibilityLabel("输出色阶")
    .accessibilityValue(String(format: "黑 %.0f，白 %.0f", channel.outBlack * 255, channel.outWhite * 255))
  }
  private func mark(_ colour: Color, at v: Double, _ w: CGFloat) -> some View {
    Triangle().fill(colour).overlay(Triangle().stroke(Color.gray, lineWidth: 0.8))
      .frame(width: 12, height: 11)
      .offset(x: CGFloat(min(1, max(0, v))) * w - 6, y: 10)
  }
}

/// A triangle pointing up, as Photoshop's level points are.
struct Triangle: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: r.midX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
    p.closeSubpath()
    return p
  }
}
