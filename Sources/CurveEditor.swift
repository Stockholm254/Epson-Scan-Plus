import SwiftUI

/// What the curves section shows and marks, shared with the canvas: the curve taken (the
/// parametric one, or the RGB, red, green or blue point curve), which the targeted adjustment on
/// the picture works on, and what lies under the pointer over the single frame. An object of its
/// own, so only the curves follow the pointer, not the whole window.
final class CurveState: ObservableObject {
  struct Reading: Equatable {
    /// The picture's values there before the curves, 0–1: where they lie on the curves' axis.
    var input: RGB
    /// Still over the picture. Off it the mark stays, dimmed, so the curve can be taken there; a
    /// new picture of the frame reads it again at the same place, another frame clears it.
    var over: Bool
  }
  @Published var reading: Reading?
  /// The point curve taken: 0 RGB, 1 red, 2 green, 3 blue.
  @Published var channel = 0
  /// The parametric curve taken, in place of a point curve.
  @Published var parametric = false
  /// Counts the editor's changes to the curves: the editor draws each at once, while the window
  /// waits for its gate (`WindowGate`) during a drag.
  @Published var edits = 0
}

/// Edits the curves as Lightroom's curve panel does. The parametric curve: four zones of the tones
/// moved by their sliders, or by dragging up or down over them on the plot, split where the marks
/// under the plot are dragged. The point curves (RGB, red, green, blue): drag a point to move it,
/// click empty space to add one, double-click a point or drag it well off the plot to remove it; the
/// end points also move sideways, to clip black or white. Behind each curve the histograms, and
/// for a channel the colours it gives above its line and below; on it the colour under the pointer.
struct CurveEditor: View {
  @Binding var curves: ToneCurves
  var histogram: [Double]
  /// Red, green and blue, on one scale; empty draws the brightness alone.
  var channels: [[Double]] = []
  @ObservedObject var state = CurveState()
  /// The targeted adjustment, the canvas's tool; nil leaves its key out.
  var targeting: Binding<Bool>? = nil
  /// The curves left off the picture for a while, to see it without them; nil leaves the key out.
  var bypassed: Binding<Bool>? = nil
  /// A change made at once (a preset, 重置): the picture's next render fades in.
  var settled: (() -> Void)? = nil
  @State private var dragging: Int?
  /// The point dragged off the plot and gone, for the rest of that drag.
  @State private var draggedOff = false
  /// The curves as a drag over the parametric plot began.
  @State private var dragStart: ToneCurves?
  /// The parametric zone whose reach shows on the plot: its slider under the pointer, or dragged.
  @State private var zoneShown: Int?
  @State private var splitDragged: Int?
  private var channel: Int { state.channel }
  static let names = ["RGB", "R", "G", "B"]
  static let colors = [
    Hardware.lcdText, Color(red: 1, green: 0.42, blue: 0.38), Color(red: 0.45, green: 0.9, blue: 0.5),
    Color(red: 0.45, green: 0.65, blue: 1),
  ]
  /// What each channel's curve gives below its line: cyan for red, magenta for green, yellow for blue.
  private static let opposites = [
    Hardware.lcdText, Color(red: 0.3, green: 0.85, blue: 0.85), Color(red: 0.9, green: 0.4, blue: 0.85),
    Color(red: 0.95, green: 0.85, blue: 0.3),
  ]
  /// Lightroom's point curve presets, in 8-bit levels between black and white.
  static let presets: [(name: String, levels: [(Double, Double)])] = [
    ("线性", []),
    ("中对比", [(32, 22), (64, 56), (128, 128), (192, 196)]),
    ("强对比", [(32, 16), (64, 50), (128, 128), (192, 202)]),
  ]
  static func preset(_ levels: [(Double, Double)]) -> ToneCurve {
    ToneCurve(points: [CurvePoint(x: 0, y: 0)] + levels.map { CurvePoint(x: $0.0 / 255, y: $0.1 / 255) } + [CurvePoint(x: 1, y: 1)])
  }
  private var parametric: ParametricCurve { curves.parametric ?? ParametricCurve() }
  private var pageName: String { state.parametric ? "参数" : Self.names[channel] }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      keys
      GeometryReader { g in
        plot(g.size)
          .contentShape(Rectangle())
          .gesture(drag(g.size))
          .simultaneousGesture(removal(g.size))
      }
      .aspectRatio(1, contentMode: .fit)
      .padding(4).background(PlotScreen())
      .accessibilityElement().accessibilityLabel("色调曲线 · \(pageName)")
      // How to use it is in the section's ⓘ and the plot's tooltip.
      .help(state.parametric
        ? "参数曲线：在曲线上按住上下拖，调那一段影调；或用下面的滑块，拖下方的三角移动分界"
        : "拖动控制点调整；点空白处添加，双击或拖出框外删除；两端还能横向拖，截掉黑或白")
      if state.parametric { parametricControls } else { pointControls }
    }
  }
  private var keys: some View {
    HStack(spacing: 5) {
      let parametricKey = Button("参数") { state.parametric = true }.buttonStyle(KeyStyle(latched: state.parametric))
      if state.parametric || parametric.isIdentity { parametricKey } else { parametricKey.foregroundStyle(Hardware.amberText) }
      ForEach(0..<4, id: \.self) { i in
        let latched = !state.parametric && channel == i
        let key = Button(Self.names[i]) {
          state.parametric = false
          state.channel = i
        }
        .buttonStyle(KeyStyle(latched: latched))
        // A channel with a curve in its colour; a colour on the key takes the place of its
        // latched fill, so the page shown keeps none.
        if latched || curves[i].isIdentity { key } else { key.foregroundStyle(Self.colors[i]) }
      }
      Spacer(minLength: 0)
    }.controlSize(.small).font(.system(size: 11))
  }
  /// Under the plot, beside 预设 and 重置: the eye and the targeted adjustment, as Lightroom has them
  /// over its curve, where the panel leaves room.
  @ViewBuilder private var tools: some View {
    if let targeting {
      Button { targeting.wrappedValue.toggle() } label: { Image(systemName: "scope") }
        .buttonStyle(KeyStyle(latched: targeting.wrappedValue))
        .help("目标调整：在单张照片上按住要调的地方上下拖，调它在\(pageName)曲线上的那一段 · Esc 退出")
        .accessibilityLabel("曲线目标调整")
    }
    if let bypassed {
      Button { bypassed.wrappedValue.toggle() } label: {
        Image(systemName: bypassed.wrappedValue ? "eye.slash" : "eye")
      }
      .buttonStyle(KeyStyle(latched: bypassed.wrappedValue))
      .help(bypassed.wrappedValue ? "照片暂不加曲线；再点一下加回来（只影响显示）" : "暂时不加曲线看照片，对比前后（只影响显示，不改设置）")
      .accessibilityLabel("暂不显示曲线")
    }
  }
  private var pointControls: some View {
    HStack(spacing: 6) {
      Menu("预设") {
        ForEach(Self.presets, id: \.name) { preset in
          Button(preset.name) { setAtOnce { $0[channel] = Self.preset(preset.levels) } }
        }
      }
      .fixedSize()
      .help("Lightroom 的点曲线预设，用在当前这条曲线上")
      tools
      Spacer(minLength: 0)
      Button("重置") { setAtOnce { $0[channel] = ToneCurve() } }.disabled(curves[channel].isIdentity)
    }.controlSize(.small).font(.system(size: 11))
  }
  /// A preset or 重置: the curve moves to it, and the picture fades to it, rather than jumping.
  private func setAtOnce(_ change: (inout ToneCurves) -> Void) {
    var next = curves
    change(&next)
    withAnimation(Liquid.settle) { curves = next }
    settled?()
  }
  private var parametricControls: some View {
    VStack(alignment: .leading, spacing: 4) {
      splitMarks
      // Lightroom's order: the lightest zone on top.
      ForEach([3, 2, 1, 0], id: \.self) { k in zoneRow(k) }
      HStack(spacing: 6) {
        tools
        Spacer(minLength: 0)
        Button("重置") { setAtOnce { $0.parametric = nil } }.disabled(curves.parametric == nil)
      }.controlSize(.small).font(.system(size: 11))
    }
  }
  /// The three splits as marks under the plot, dragged sideways; each keeps 0.05 from the next.
  private var splitMarks: some View {
    GeometryReader { g in
      let splits = parametric.splits
      ZStack(alignment: .topLeading) {
        ForEach(0..<3, id: \.self) { i in
          SplitMark().fill(splitDragged == i ? Hardware.accent : Hardware.lcdText.opacity(0.7))
            .frame(width: 10, height: 7).position(x: splits[i] * g.size.width, y: 5)
        }
      }
      .frame(width: g.size.width, height: g.size.height)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { d in
            var p = parametric
            let start = Double(d.startLocation.x / max(1, g.size.width))
            if splitDragged == nil { splitDragged = (0..<3).min { abs(p.splits[$0] - start) < abs(p.splits[$1] - start) } }
            guard let i = splitDragged else { return }
            let low = i == 0 ? 0.05 : p.splits[i - 1] + 0.05, high = i == 2 ? 0.95 : p.splits[i + 1] - 0.05
            p.splits[i] = min(high, max(low, Double(d.location.x / max(1, g.size.width))))
            curves.parametric = p
          }
          .onEnded { _ in splitDragged = nil })
    }
    .frame(height: 10).padding(.horizontal, 4)
    .help("拖动三角移动阴影、暗部、亮部、高光之间的分界")
  }
  private func zoneRow(_ k: Int) -> some View {
    let value = Binding<Double>(
      get: { parametric.amounts[k] },
      set: { v in
        var p = parametric
        var a = p.amounts
        a[k] = v
        p.amounts = a
        curves.parametric = p
      })
    let shown = Int((value.wrappedValue * 100).rounded())
    return HStack(spacing: 6) {
      Text(ParametricCurve.names[k]).font(.system(size: 11)).frame(width: 30, alignment: .leading)
      Fader(title: "参数曲线 · " + ParametricCurve.names[k], value: value, range: -1...1, detent: 0,
        gradient: [Color(white: 0.18), Color(white: 0.62), Color(white: 0.96)])
      Text(shown == 0 ? "0" : String(format: "%+d", shown))
        .font(.system(size: 10, design: .monospaced)).frame(width: 30, alignment: .trailing)
    }
    .onHover { inside in
      if inside { zoneShown = k } else if zoneShown == k { zoneShown = nil }
    }
  }
  private func onView(_ p: CurvePoint, _ size: CGSize) -> CGPoint {
    CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
  }
  private func distance(_ p: CurvePoint, _ location: CGPoint, _ size: CGSize) -> Double {
    let v = onView(p, size)
    return hypot(v.x - location.x, v.y - location.y)
  }
  private func plot(_ size: CGSize) -> some View {
    let onParametric = state.parametric
    let curve = onParametric ? parametric.curve : curves[channel]
    let color = onParametric ? Hardware.lcdText : Self.colors[channel]
    return ZStack {
      // A channel's colours: its own where its curve rises above the line, the opposite below;
      // another channel's cross-fading in.
      ZStack {
        if !onParametric && channel > 0 {
          LinearGradient(
            colors: [Self.colors[channel].opacity(0.2), Self.opposites[channel].opacity(0.16)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .id(channel).transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.18), value: channel)
      .animation(.easeInOut(duration: 0.18), value: onParametric)
      Path { p in
        for (i, v) in histogram.enumerated() {
          let x = Double(i) / Double(max(1, histogram.count - 1)) * size.width
          p.move(to: CGPoint(x: x, y: size.height))
          p.addLine(to: CGPoint(x: x, y: size.height * (1 - v * 0.9)))
        }
      }.stroke(Hardware.lcdText.opacity(channels.isEmpty ? 0.12 : 0.05), lineWidth: 2)
      // Each channel's histogram in its colour; the one being edited, or all three for RGB, brighter.
      Group {
        ForEach(Array(channels.prefix(3).enumerated()), id: \.offset) { i, values in
          let tone = Self.colors[i + 1], lit = onParametric || channel == 0 || channel == i + 1
          histogramShape(values, size).fill(tone.opacity(lit ? 0.16 : 0.06))
          histogramLine(values, size).stroke(tone.opacity(lit ? 0.55 : 0.2), lineWidth: 0.8)
        }
      }
      // Another channel's histogram brightens as the last one dims.
      .animation(.easeInOut(duration: 0.18), value: channel)
      Path { p in
        for i in 1..<4 {
          let f = Double(i) / 4
          p.move(to: CGPoint(x: f * size.width, y: 0))
          p.addLine(to: CGPoint(x: f * size.width, y: size.height))
          p.move(to: CGPoint(x: 0, y: f * size.height))
          p.addLine(to: CGPoint(x: size.width, y: f * size.height))
        }
        p.move(to: CGPoint(x: 0, y: size.height))
        p.addLine(to: CGPoint(x: size.width, y: 0))
      }.stroke(Hardware.lcdText.opacity(0.1), lineWidth: 0.5)
      if onParametric {
        // The splits, and the reach of the zone whose slider is under the pointer: between its
        // curve at −100 and at +100.
        Path { p in
          for s in parametric.splits {
            p.move(to: CGPoint(x: s * size.width, y: 0))
            p.addLine(to: CGPoint(x: s * size.width, y: size.height))
          }
        }.stroke(Hardware.lcdText.opacity(splitDragged == nil ? 0.25 : 0.5), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
        // The zone's reach comes up under the pointer and goes as it leaves.
        ZStack {
          if let k = zoneShown { reach(k, size).fill(Hardware.lcdText.opacity(0.14)).id(k).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: zoneShown)
      } else {
        // Every channel's curve, the one being edited on top.
        ForEach(0..<4, id: \.self) { i in
          if i != channel {
            CurveLine(curves[i]).stroke(Self.colors[i].opacity(curves[i].isIdentity ? 0.25 : 0.6), lineWidth: 1)
              .frame(width: size.width, height: size.height)
          }
        }
      }
      CurveLine(curve).stroke(color, lineWidth: 1.5).shadow(color: color.opacity(0.6), radius: 2)
        .frame(width: size.width, height: size.height)
      if let reading = state.reading {
        pointerMarks(reading, size)
      }
      if !onParametric {
        ForEach(Array(curve.points.enumerated()), id: \.offset) { i, p in
          Circle().fill(dragging == i ? color : Hardware.lcdGlass)
            .overlay(Circle().stroke(color, lineWidth: 1.5))
            .frame(width: 9, height: 9).position(onView(p, size))
        }
      }
      figures(size)
    }
  }
  /// The area a zone's amount reaches, its curve from −1 to 1 with the others as they are.
  private func reach(_ k: Int, _ size: CGSize) -> Path {
    var low = parametric, high = parametric
    var a = low.amounts
    a[k] = -1
    low.amounts = a
    a[k] = 1
    high.amounts = a
    let below = low.curve, above = high.curve
    return Path { p in
      for i in 0...64 {
        let x = Double(i) / 64, point = CGPoint(x: x * size.width, y: (1 - above.value(x)) * size.height)
        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
      }
      for i in (0...64).reversed() {
        let x = Double(i) / 64
        p.addLine(to: CGPoint(x: x * size.width, y: (1 - below.value(x)) * size.height))
      }
      p.closeSubpath()
    }
  }
  /// Where the pointer's colour lies on the curve being edited: on the parametric curve each
  /// channel's value before the curves; on the RGB curve, after the parametric one; on one
  /// channel's curve its own after the curves before it.
  struct PointerMark: Identifiable {
    /// 1 red, 2 green, 3 blue, as the keys count.
    var channel: Int
    var x: Double
    var y: Double
    var id: Int { channel }
  }
  static func pointerMarks(_ reading: CurveState.Reading, curves: ToneCurves, channel: Int, parametric: Bool = false) -> [PointerMark] {
    let first = curves.firstStage
    func before(_ v: Double) -> Double { first?.value(v) ?? v }
    return (0..<3).compactMap { c in
      let v = reading.input.values[c]
      if parametric { return PointerMark(channel: c + 1, x: v, y: before(v)) }
      guard channel == 0 || channel == c + 1 else { return nil }
      let x = channel == 0 ? before(v) : curves.rgb.value(before(v))
      return PointerMark(channel: c + 1, x: x, y: curves[channel].value(x))
    }
  }
  /// A line up through the histograms at each value under the pointer, and a dot where the curve
  /// takes it.
  private func pointerMarks(_ reading: CurveState.Reading, _ size: CGSize) -> some View {
    let marks = Self.pointerMarks(reading, curves: curves, channel: channel, parametric: state.parametric)
    let lit = reading.over ? 1.0 : 0.5
    return ZStack {
      ForEach(marks) { m in
        let tone = Self.colors[m.channel]
        Path { p in
          p.move(to: CGPoint(x: m.x * size.width, y: 0))
          p.addLine(to: CGPoint(x: m.x * size.width, y: size.height))
        }.stroke(tone.opacity(0.55 * lit), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        Circle().fill(tone.opacity(lit)).overlay(Circle().stroke(Hardware.lcdGlass, lineWidth: 1))
          .frame(width: 7, height: 7).position(x: m.x * size.width, y: (1 - m.y) * size.height)
      }
    }
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
  }
  /// In the corner the curves leave free: the point being dragged, input and output; else the
  /// values under the pointer, before and after the curve; 8-bit levels.
  private func figures(_ size: CGSize) -> some View {
    func level(_ v: Double) -> String { String(Int((v * 255).rounded())) }
    var text = "", lit = 1.0
    let points = curves[channel].points
    if !state.parametric, let i = dragging, i < points.count {
      text = "输入 " + level(points[i].x) + " → 输出 " + level(points[i].y)
    } else if let reading = state.reading {
      lit = reading.over ? 1 : 0.5
      text = Self.pointerMarks(reading, curves: curves, channel: channel, parametric: state.parametric).map { m in
        Self.names[m.channel] + " " + level(m.x) + (level(m.x) == level(m.y) ? "" : "→" + level(m.y))
      }.joined(separator: "  ")
    } else if state.parametric, let k = zoneShown {
      let e = parametric.edges
      text = ParametricCurve.names[k] + " " + level(e[k]) + "–" + level(e[k + 1])
    }
    return ZStack(alignment: .topLeading) {
      if !text.isEmpty {
        Text(text)
          .font(.system(size: 9, design: .monospaced)).foregroundStyle(Hardware.lcdText.opacity(0.4 + 0.5 * lit))
          .padding(.horizontal, 3).padding(.vertical, 1)
          .background(Hardware.lcdGlass.opacity(0.75), in: RoundedRectangle(cornerRadius: 2))
          .padding(3)
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .allowsHitTesting(false)
  }
  private func histogramLine(_ values: [Double], _ size: CGSize) -> Path {
    Path { p in
      for (i, v) in values.enumerated() {
        let point = CGPoint(x: Double(i) / Double(max(1, values.count - 1)) * size.width, y: size.height * (1 - v * 0.9))
        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
      }
    }
  }
  private func histogramShape(_ values: [Double], _ size: CGSize) -> Path {
    var p = histogramLine(values, size)
    p.addLine(to: CGPoint(x: size.width, y: size.height))
    p.addLine(to: CGPoint(x: 0, y: size.height))
    p.closeSubpath()
    return p
  }
  private func drag(_ size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { drag in
        if state.parametric {
          // Up or down over a zone moves its amount, as the targeted adjustment does on the picture.
          let start = dragStart ?? curves
          if dragStart == nil { dragStart = curves }
          let x = min(1, max(0, Double(drag.startLocation.x / size.width)))
          curves = start.targeted(at: x, channel: 0, parametric: true, by: Double(drag.startLocation.y - drag.location.y) / size.height)
          zoneShown = parametric.zone(x)
          return
        }
        guard !draggedOff else { return }
        let fx = Double(drag.location.x / size.width), fy = Double(drag.location.y / size.height)
        let point = CurvePoint(x: min(1, max(0, fx)), y: min(1, max(0, 1 - fy)))
        var curve = curves[channel]
        if dragging == nil {
          // Grab the nearest point within reach, or add one where the press landed.
          let near = curve.points.indices.min {
            distance(curve.points[$0], drag.startLocation, size) < distance(curve.points[$1], drag.startLocation, size)
          }
          if let near, distance(curve.points[near], drag.startLocation, size) < 10 {
            dragging = near
          } else if let at = curve.points.firstIndex(where: { $0.x > point.x }), at > 0,
            point.x - curve.points[at - 1].x > 0.02, curve.points[at].x - point.x > 0.02
          {
            curve.points.insert(point, at: at)
            dragging = at
          } else {
            return
          }
        }
        guard let i = dragging else { return }
        let last = curve.points.count - 1
        // Dragged well off the plot, an inner point goes, as in Lightroom.
        let reach: CGFloat = 24
        let off = drag.location.x < -reach || drag.location.x > size.width + reach
          || drag.location.y < -reach || drag.location.y > size.height + reach
        if off, i > 0, i < last {
          curve.points.remove(at: i)
          curves[channel] = curve
          dragging = nil
          draggedOff = true
          return
        }
        // The end points move sideways too, to clip black or white; the others stay between their
        // neighbours.
        let x = i == 0 ? min(curve.points[1].x - 0.01, point.x)
          : i == last ? max(curve.points[last - 1].x + 0.01, point.x)
          : min(curve.points[i + 1].x - 0.01, max(curve.points[i - 1].x + 0.01, point.x))
        curve.points[i] = CurvePoint(x: x, y: point.y)
        curves[channel] = curve
      }
      .onEnded { _ in
        dragging = nil
        draggedOff = false
        if dragStart != nil {
          dragStart = nil
          zoneShown = nil
        }
      }
  }
  private func removal(_ size: CGSize) -> some Gesture {
    SpatialTapGesture(count: 2).onEnded { tap in
      guard !state.parametric else { return }
      var curve = curves[channel]
      guard let i = curve.points.indices.dropFirst().dropLast().first(where: { distance(curve.points[$0], tap.location, size) < 10 })
      else { return }
      curve.points.remove(at: i)
      curves[channel] = curve
    }
  }
}

/// A split of the parametric curve under its plot: a small triangle pointing up at it.
/// A curve drawn through 65 of its values, which a preset or 重置 animates between value by value.
private struct CurveLine: Shape {
  var samples: CurveSamples
  init(_ curve: ToneCurve) { samples = CurveSamples(values: (0...64).map { curve.value(Double($0) / 64) }) }
  var animatableData: CurveSamples {
    get { samples }
    set { samples = newValue }
  }
  func path(in rect: CGRect) -> Path {
    Path { p in
      let v = samples.values
      guard v.count > 1 else { return }
      for (i, y) in v.enumerated() {
        let point = CGPoint(x: rect.minX + Double(i) / Double(v.count - 1) * rect.width, y: rect.minY + (1 - y) * rect.height)
        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
      }
    }
  }
}
/// A curve's values, as SwiftUI animates them: added, taken apart and scaled value by value.
struct CurveSamples: VectorArithmetic {
  var values: [Double]
  static var zero: CurveSamples { CurveSamples(values: []) }
  private static func combine(_ a: CurveSamples, _ b: CurveSamples, _ op: (Double, Double) -> Double) -> CurveSamples {
    let n = max(a.values.count, b.values.count)
    return CurveSamples(values: (0..<n).map { i in
      op(i < a.values.count ? a.values[i] : 0, i < b.values.count ? b.values[i] : 0)
    })
  }
  static func + (a: CurveSamples, b: CurveSamples) -> CurveSamples { combine(a, b, +) }
  static func - (a: CurveSamples, b: CurveSamples) -> CurveSamples { combine(a, b, -) }
  mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
  var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

private struct SplitMark: Shape {
  func path(in rect: CGRect) -> Path {
    Path { p in
      p.move(to: CGPoint(x: rect.midX, y: rect.minY))
      p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      p.closeSubpath()
    }
  }
}
