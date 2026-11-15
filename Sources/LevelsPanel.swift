import AppKit
import SwiftUI

/// 色阶 as Photoshop's Levels lays it out: the channel (RGB, 红, 绿, 蓝) and the three eyedroppers
/// over the histogram of the picture before it; under that the input's black, grey and white
/// points to drag (⌥ held on black or white shows what they cut) with their figures; the output's
/// black and white over a gradient with theirs; then 自动, its options and 预览.
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
  private var levels: Levels { m.settings.levels ?? Levels() }
  private var current: Levels.Channel { levels[channel] }
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
        black: current.black, white: current.white)
      InputPoints(channel: current) { mark, v, option in
        switch mark {
        case .black:
          m.levelsClipping = option ? .black(channel) : nil
          m.changeLevels("色阶输入黑点") { $0[channel].black = min(max(0, v), $0[channel].white - 2 / 255) }
        case .white:
          m.levelsClipping = option ? .white(channel) : nil
          m.changeLevels("色阶输入白点") { $0[channel].white = max(min(1, v), $0[channel].black + 2 / 255) }
        case .grey:
          m.changeLevels("色阶中间调") { $0[channel].gamma = $0[channel].gamma(at: v) }
        }
      } ended: { m.levelsClipping = nil }
      HStack(spacing: 6) {
        Text("输入色阶").font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer()
        figure("输入黑点", current.black * 255, 0...253, "%.0f") { v in
          m.changeLevels("色阶输入黑点") { $0[channel].black = min(v / 255, $0[channel].white - 2 / 255) }
        }
        figure("中间调", current.gamma, 0.10...9.99, "%.2f") { v in
          m.changeLevels("色阶中间调") { $0[channel].gamma = Levels.clampGamma(v) }
        }
        figure("输入白点", current.white * 255, 2...255, "%.0f") { v in
          m.changeLevels("色阶输入白点") { $0[channel].white = max(v / 255, $0[channel].black + 2 / 255) }
        }
      }
      OutputPoints(channel: current, end: channel == 0 ? .white : HistogramView.colours[channel - 1]) { isBlack, v in
        m.changeLevels(isBlack ? "色阶输出黑点" : "色阶输出白点") { l in
          if isBlack { l[channel].outBlack = v } else { l[channel].outWhite = v }
        }
      }
      HStack(spacing: 6) {
        Text("输出色阶").font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer()
        figure("输出黑点", current.outBlack * 255, 0...255, "%.0f") { v in m.changeLevels("色阶输出黑点") { $0[channel].outBlack = v / 255 } }
        figure("输出白点", current.outWhite * 255, 0...255, "%.0f") { v in m.changeLevels("色阶输出白点") { $0[channel].outWhite = v / 255 } }
      }
      HStack(spacing: 3) {
        eyedropper(.black, "黑场", .black, "在画面上点一处定为黑：这一处的红、绿、蓝各自的输入黑点设到它，像 Photoshop 的「在图像中取样以设置黑场」")
        eyedropper(.grey, "灰场", Color(white: 0.5), "在画面上点一处本来是灰的东西：红、绿、蓝各自的中间调调到让它成为中性灰，亮度不变")
        eyedropper(.white, "白场", .white, "在画面上点一处定为白：这一处的红、绿、蓝各自的输入白点设到它")
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

/// The picture before 色阶 in 256 steps, as Photoshop's Levels draws it: the composite grey, a channel
/// in its colour, scaled to its tallest step short of the two ends (a black border or a white sky
/// would dwarf the rest); what the input points cut to black or white dimmed.
struct LevelsHistogramView: View {
  let counts: [Double]
  let channel: Int
  let black: Double, white: Double
  var body: some View {
    Canvas { ctx, size in
      let inner = counts.count > 2 ? Array(counts[1..<(counts.count - 1)]) : counts
      let peak = max(1e-9, inner.max() ?? 1)
      let colour = channel == 0 ? Color.white.opacity(0.75) : HistogramView.colours[channel - 1].opacity(0.85)
      let w = size.width / CGFloat(max(1, counts.count))
      var p = Path()
      for (i, v) in counts.enumerated() {
        let h = size.height * CGFloat(min(1, v / peak))
        p.addRect(CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(w, 1), height: h))
      }
      ctx.fill(p, with: .color(colour))
      ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * CGFloat(black), height: size.height)), with: .color(.black.opacity(0.45)))
      ctx.fill(Path(CGRect(x: size.width * CGFloat(white), y: 0, width: size.width * CGFloat(1 - white), height: size.height)),
        with: .color(.black.opacity(0.45)))
    }
    .frame(height: 84)
    .padding(4).background(PlotScreen())
    .accessibilityElement().accessibilityLabel("色阶直方图")
    .help("色阶之前的这张，横轴 0 到 255；暗下去的两边是输入黑点、白点切成纯黑、纯白的部分")
  }
}

/// The input's three points under the histogram: black (filled), grey and white (hollow). A press
/// takes the nearest; with ⌥ held on black or white the picture shows what they cut.
struct InputPoints: View {
  enum Mark { case black, grey, white }
  let channel: Levels.Channel
  var set: (Mark, Double, Bool) -> Void
  var ended: () -> Void
  @State private var held: Mark?
  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      ZStack(alignment: .topLeading) {
        Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1).offset(y: 1)
        triangle(filled: .black, at: channel.black, w)
        triangle(filled: Color(white: 0.55), at: channel.midPoint, w)
        triangle(filled: .white, at: channel.white, w)
      }
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { g in
          let v = Double(min(max(0, g.location.x), w) / max(1, w))
          if held == nil {
            let start = Double(g.startLocation.x / max(1, w))
            held = [(Mark.black, channel.black), (.grey, channel.midPoint), (.white, channel.white)]
              .min { abs($0.1 - start) < abs($1.1 - start) }?.0
          }
          if let held { set(held, v, NSEvent.modifierFlags.contains(.option) && held != .grey) }
        }
        .onEnded { _ in
          held = nil
          ended()
        })
    }
    .frame(height: 12)
    .help("拖黑、灰、白三个三角：输入黑点、中间调、输入白点；拖黑或白时按住 ⌥，画面上显示切成纯黑或纯白的地方")
    .accessibilityElement().accessibilityLabel("输入色阶")
    .accessibilityValue(String(format: "黑点 %.0f，中间调 %.2f，白点 %.0f", channel.black * 255, channel.gamma, channel.white * 255))
  }
  private func triangle(filled colour: Color, at v: Double, _ w: CGFloat) -> some View {
    Triangle().fill(colour).overlay(Triangle().stroke(Color.gray, lineWidth: 0.8))
      .frame(width: 10, height: 9)
      .offset(x: CGFloat(min(1, max(0, v))) * w - 5, y: 2)
  }
}

/// The output's black and white over a gradient from black to white (the channel's colour on one).
struct OutputPoints: View {
  let channel: Levels.Channel
  let end: Color
  var set: (Bool, Double) -> Void
  @State private var holdsBlack: Bool?
  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      ZStack(alignment: .topLeading) {
        LinearGradient(colors: [.black, end], startPoint: .leading, endPoint: .trailing)
          .frame(height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
        mark(.black, at: channel.outBlack, w)
        mark(.white, at: channel.outWhite, w)
      }
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { g in
          let v = Double(min(max(0, g.location.x), w) / max(1, w))
          if holdsBlack == nil {
            let start = Double(g.startLocation.x / max(1, w))
            holdsBlack = abs(start - channel.outBlack) <= abs(start - channel.outWhite)
          }
          if let holdsBlack { set(holdsBlack, v) }
        }
        .onEnded { _ in holdsBlack = nil })
    }
    .frame(height: 19)
    .help("拖黑、白两个三角：输出的黑和白，最暗的印成多暗、最亮的印成多亮；交叉过去画面反相")
    .accessibilityElement().accessibilityLabel("输出色阶")
    .accessibilityValue(String(format: "黑 %.0f，白 %.0f", channel.outBlack * 255, channel.outWhite * 255))
  }
  private func mark(_ colour: Color, at v: Double, _ w: CGFloat) -> some View {
    Triangle().fill(colour).overlay(Triangle().stroke(Color.gray, lineWidth: 0.8))
      .frame(width: 10, height: 9)
      .offset(x: CGFloat(min(1, max(0, v))) * w - 5, y: 10)
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
