import SwiftUI

/// Edits the RGB curve and the per-channel curves: drag a point to move it, click empty space to
/// add one, double-click a point to remove it. The end points move only up and down.
struct CurveEditor: View {
  @Binding var curves: ToneCurves
  var histogram: [Double]
  /// Red, green and blue, on one scale; empty draws the brightness alone.
  var channels: [[Double]] = []
  @State private var channel = 0
  @State private var dragging: Int?
  private static let names = ["RGB", "R", "G", "B"]
  private static let colors = [
    Hardware.lcdText, Color(red: 1, green: 0.42, blue: 0.38), Color(red: 0.45, green: 0.9, blue: 0.5),
    Color(red: 0.45, green: 0.65, blue: 1),
  ]
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
      .accessibilityElement().accessibilityLabel("色调曲线 · \(Self.names[channel])")
      Text("拖动控制点调整；点空白处添加，双击控制点删除。各通道曲线在 RGB 曲线之后生效。背后是正片的红、绿、蓝直方图。")
        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
  private var keys: some View {
    HStack(spacing: 6) {
      ForEach(0..<4, id: \.self) { i in
        Button(Self.names[i]) { channel = i }
          .buttonStyle(KeyStyle(latched: channel == i))
          .foregroundStyle(curves[i].isIdentity ? Color(white: 0.85) : Self.colors[i])
      }
      Spacer()
      Button("重置") { curves[channel] = ToneCurve() }.disabled(curves[channel].isIdentity)
    }.controlSize(.small).font(.system(size: 11))
  }
  private func onView(_ p: CurvePoint, _ size: CGSize) -> CGPoint {
    CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
  }
  private func distance(_ p: CurvePoint, _ location: CGPoint, _ size: CGSize) -> Double {
    let v = onView(p, size)
    return hypot(v.x - location.x, v.y - location.y)
  }
  private func plot(_ size: CGSize) -> some View {
    let curve = curves[channel], color = Self.colors[channel]
    return ZStack {
      Path { p in
        for (i, v) in histogram.enumerated() {
          let x = Double(i) / Double(max(1, histogram.count - 1)) * size.width
          p.move(to: CGPoint(x: x, y: size.height))
          p.addLine(to: CGPoint(x: x, y: size.height * (1 - v * 0.9)))
        }
      }.stroke(Hardware.lcdText.opacity(channels.isEmpty ? 0.12 : 0.05), lineWidth: 2)
      // Each channel's histogram in its colour; the one being edited, or all three for RGB, brighter.
      ForEach(Array(channels.prefix(3).enumerated()), id: \.offset) { i, values in
        let tone = Self.colors[i + 1], lit = channel == 0 || channel == i + 1
        histogramShape(values, size).fill(tone.opacity(lit ? 0.16 : 0.06))
        histogramLine(values, size).stroke(tone.opacity(lit ? 0.55 : 0.2), lineWidth: 0.8)
      }
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
      // Every channel's curve, the one being edited on top.
      ForEach(0..<4, id: \.self) { i in
        if i != channel {
          path(curves[i], size).stroke(Self.colors[i].opacity(curves[i].isIdentity ? 0.25 : 0.6), lineWidth: 1)
        }
      }
      path(curve, size).stroke(color, lineWidth: 1.5).shadow(color: color.opacity(0.6), radius: 2)
      ForEach(Array(curve.points.enumerated()), id: \.offset) { i, p in
        Circle().fill(dragging == i ? color : Hardware.lcdGlass)
          .overlay(Circle().stroke(color, lineWidth: 1.5))
          .frame(width: 9, height: 9).position(onView(p, size))
      }
    }
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
  private func path(_ curve: ToneCurve, _ size: CGSize) -> Path {
    Path { p in
      for i in 0...64 {
        let x = Double(i) / 64
        let point = CGPoint(x: x * size.width, y: (1 - curve.value(x)) * size.height)
        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
      }
    }
  }
  private func drag(_ size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { drag in
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
        // End points keep their x; inner points stay between their neighbours.
        let x = i == 0 ? 0 : i == last ? 1 : min(curve.points[i + 1].x - 0.01, max(curve.points[i - 1].x + 0.01, point.x))
        curve.points[i] = CurvePoint(x: x, y: point.y)
        curves[channel] = curve
      }
      .onEnded { _ in dragging = nil }
  }
  private func removal(_ size: CGSize) -> some Gesture {
    SpatialTapGesture(count: 2).onEnded { tap in
      var curve = curves[channel]
      guard let i = curve.points.indices.dropFirst().dropLast().first(where: { distance(curve.points[$0], tap.location, size) < 10 })
      else { return }
      curve.points.remove(at: i)
      curves[channel] = curve
    }
  }
}
