import AppKit
import SwiftUI

/// Parts for the scanner-console look: metal keys, lamps, LCD readouts, faders and film.
/// Every custom control keeps a native accessibility representation.
enum Hardware {
  static let amber = Color(red: 0.91, green: 0.68, blue: 0.37)
  static let lcdText = Color(red: 1.0, green: 0.75, blue: 0.4)
  static let lcdGlass = Color(red: 0.075, green: 0.068, blue: 0.052)
  static let greasePencil = Color(red: 0.86, green: 0.24, blue: 0.17)
  static let edgePrint = Color(red: 0.98, green: 0.71, blue: 0.4)
  static let filmBase = Color(red: 0.25, green: 0.13, blue: 0.06)
  static let metal = LinearGradient(
    colors: [Color(white: 0.175), Color(white: 0.135)], startPoint: .top, endPoint: .bottom)
}

/// A raised console key. `latched` holds it pressed in, for lamp toggles that are on.
struct HardwareKeyStyle: ButtonStyle {
  var prominent = false
  var latched = false
  func makeBody(configuration: Configuration) -> some View {
    HardwareKey(
      label: configuration.label, pressed: configuration.isPressed || latched, prominent: prominent)
  }
}

private struct HardwareKey<Label: View>: View {
  let label: Label
  let pressed: Bool
  let prominent: Bool
  @Environment(\.isEnabled) private var enabled
  @Environment(\.controlSize) private var size
  var body: some View {
    let compact = size == .mini || size == .small
    let face =
      prominent
      ? [Color(red: 0.96, green: 0.77, blue: 0.48), Color(red: 0.8, green: 0.55, blue: 0.24)]
      : [Color(white: 0.33), Color(white: 0.21)]
    let shape = RoundedRectangle(cornerRadius: compact ? 4 : 5)
    label
      .foregroundStyle(prominent ? Color(red: 0.22, green: 0.13, blue: 0.03) : Color(white: 0.9))
      .padding(.horizontal, compact ? 7 : 11).padding(.vertical, compact ? 2.5 : 5)
      .background(
        shape.fill(
          LinearGradient(
            colors: pressed ? face.reversed() : face, startPoint: .top, endPoint: .bottom)
        )
        .brightness(pressed ? -0.06 : 0)
        .overlay(
          shape.strokeBorder(
            LinearGradient(
              colors: [.white.opacity(pressed ? 0.04 : 0.2), .clear], startPoint: .top,
              endPoint: .center), lineWidth: 1)
        )
        .overlay(shape.stroke(.black.opacity(0.8), lineWidth: 1))
        .shadow(
          color: .black.opacity(pressed ? 0.25 : 0.6), radius: pressed ? 0.5 : 1.5,
          y: pressed ? 0.5 : 2)
      )
      .offset(y: pressed ? 1 : 0)
      .opacity(enabled ? 1 : 0.4)
      .contentShape(shape)
  }
}

/// A latching key with a lamp, for on/off settings.
struct LEDToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 5) {
        Circle().fill(configuration.isOn ? Hardware.amber : Color(white: 0.12))
          .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 0.5))
          .frame(width: 6, height: 6)
          .shadow(color: configuration.isOn ? Hardware.amber.opacity(0.9) : .clear, radius: 3)
        configuration.label
      }
    }
    .buttonStyle(HardwareKeyStyle(latched: configuration.isOn))
    .accessibilityValue(configuration.isOn ? "开" : "关")
    .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
  }
}

/// A panel lamp: green ready, amber blinking while busy, red when the scanner is not ready.
struct StatusLED: View {
  enum Lamp { case ready, busy, fault }
  var lamp: Lamp
  var size: CGFloat = 9
  private var color: Color {
    switch lamp {
    case .ready: return Color(red: 0.36, green: 0.86, blue: 0.42)
    case .busy: return Hardware.amber
    case .fault: return Color(red: 0.92, green: 0.3, blue: 0.24)
    }
  }
  var body: some View {
    let led = Circle().fill(color)
      .overlay(
        Circle().fill(
          RadialGradient(
            colors: [.white.opacity(0.75), .clear], center: UnitPoint(x: 0.35, y: 0.3),
            startRadius: 0, endRadius: size * 0.45))
      )
      .overlay(Circle().stroke(.black.opacity(0.7), lineWidth: 1))
      .frame(width: size, height: size)
      .shadow(color: color.opacity(0.8), radius: size * 0.5)
    if lamp == .busy {
      led.phaseAnimator([1.0, 0.35]) { content, level in content.opacity(level) } animation: { _ in
        .easeInOut(duration: 0.6)
      }
    } else {
      led
    }
  }
}

/// Dark glass behind an LCD readout.
struct LCDGlass: View {
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 3)
    shape.fill(Hardware.lcdGlass)
      .overlay(
        shape.fill(
          LinearGradient(
            colors: [.black.opacity(0.55), .clear], startPoint: .top,
            endPoint: UnitPoint(x: 0.5, y: 0.35)))
      )
      .overlay(shape.stroke(.black, lineWidth: 1))
      .overlay(shape.inset(by: -1).stroke(.white.opacity(0.07), lineWidth: 1))
  }
}

extension View {
  /// Amber segment-display text on dark glass.
  func lcd(_ fontSize: CGFloat = 10) -> some View {
    font(.system(size: fontSize, weight: .medium, design: .monospaced))
      .foregroundStyle(Hardware.lcdText)
      .shadow(color: Hardware.lcdText.opacity(0.55), radius: 2)
      .padding(.horizontal, 5).padding(.vertical, 2)
      .background(LCDGlass())
  }
}

/// A console fader. Drag the cap (hold Option for fine control), click the slot to jump,
/// double-click to return to `detent`, or use the arrow keys (Shift for larger steps).
struct Fader: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var detent: Double? = nil
  @Environment(\.isEnabled) private var enabled
  @FocusState private var focused: Bool
  @State private var grab: (value: Double, x: CGFloat, fine: Bool)?
  private let cap = CGSize(width: 12, height: 18)
  private var span: Double { range.upperBound - range.lowerBound }
  private func clamped(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
  var body: some View {
    GeometryReader { g in
      let travel = max(1, g.size.width - cap.width)
      let offset = { (v: Double) in CGFloat((clamped(v) - range.lowerBound) / span) * travel }
      ZStack(alignment: .topLeading) {
        Canvas { ctx, size in
          for i in 0...10 {
            let x = cap.width / 2 + travel * CGFloat(i) / 10
            ctx.fill(
              Path(CGRect(x: x - 0.5, y: 1, width: 1, height: i % 5 == 0 ? 4 : 2.5)),
              with: .color(.white.opacity(0.22)))
          }
          if let detent {
            let x = cap.width / 2 + offset(detent)
            ctx.fill(
              Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)),
              with: .color(Hardware.amber.opacity(0.35)))
          }
        }
        RoundedRectangle(cornerRadius: 2)
          .fill(LinearGradient(colors: [.black, Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
          .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.8), lineWidth: 0.5))
          .frame(width: travel + 4, height: 4)
          .offset(x: cap.width / 2 - 2, y: 9)
        FaderCap(enabled: enabled, focused: focused)
          .frame(width: cap.width, height: cap.height)
          .offset(x: offset(value), y: 2)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { drag in
            let fine = NSEvent.modifierFlags.contains(.option)
            if grab == nil {
              // Pressing the cap moves it relative to the pointer; pressing the slot jumps there.
              if abs(drag.startLocation.x - (offset(value) + cap.width / 2)) > cap.width {
                value = clamped(range.lowerBound + Double((drag.startLocation.x - cap.width / 2) / travel) * span)
              }
              grab = (value, drag.location.x, fine)
            } else if grab?.fine != fine {
              grab = (value, drag.location.x, fine)
            }
            guard let grab else { return }
            value = clamped(grab.value + Double((drag.location.x - grab.x) / travel) * span * (fine ? 0.1 : 1))
          }
          .onEnded { _ in grab = nil }
      )
      .simultaneousGesture(TapGesture(count: 2).onEnded { if let detent { value = detent } })
    }
    .frame(height: 22)
    .focusable(enabled)
    .focused($focused)
    .focusEffectDisabled()
    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
      let step = span / (press.modifiers.contains(.shift) ? 10 : 100)
      let up = press.key == .rightArrow || press.key == .upArrow
      value = clamped(value + (up ? step : -step))
      return .handled
    }
    .accessibilityRepresentation {
      Slider(value: $value, in: range) { Text(title) }
    }
  }
}

private struct FaderCap: View {
  let enabled: Bool
  let focused: Bool
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 2.5)
    shape.fill(
      LinearGradient(
        colors: enabled ? [Color(white: 0.9), Color(white: 0.6)] : [Color(white: 0.5), Color(white: 0.38)],
        startPoint: .top, endPoint: .bottom)
    )
    .overlay(
      HStack(spacing: 2) {
        Rectangle().fill(.black.opacity(0.28)).frame(width: 1)
        Rectangle().fill(Color(red: 0.55, green: 0.3, blue: 0.08)).frame(width: 1.5)
        Rectangle().fill(.black.opacity(0.28)).frame(width: 1)
      }.padding(.vertical, 3)
    )
    .overlay(shape.stroke(.black.opacity(0.75), lineWidth: 0.75))
    .overlay(shape.stroke(Hardware.amber, lineWidth: focused ? 1.5 : 0))
    .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1.5)
  }
}

/// 135 film base behind the thumbnails, perforated along both edges.
struct FilmBase: View {
  var body: some View {
    Canvas { ctx, size in
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Hardware.filmBase))
      ctx.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .linearGradient(
          Gradient(colors: [.white.opacity(0.07), .clear, .black.opacity(0.12)]),
          startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
      let hole = CGSize(width: 6, height: 4.5)
      for y in [3, size.height - 3 - hole.height] {
        for x in stride(from: 3, to: size.width - hole.width, by: 12) {
          ctx.fill(
            Path(roundedRect: CGRect(origin: CGPoint(x: x, y: y), size: hole), cornerRadius: 1.2),
            with: .color(Color(white: 0.085)))
        }
      }
    }
  }
}

/// A china-marker tick on the frame, the way frames are marked on a contact sheet.
struct GreasePencilCheck: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      ZStack {
        if configuration.isOn {
          Path { p in
            p.move(to: CGPoint(x: 2, y: 8.5))
            p.addQuadCurve(to: CGPoint(x: 6.5, y: 14), control: CGPoint(x: 4, y: 12))
            p.addQuadCurve(to: CGPoint(x: 16, y: 1.5), control: CGPoint(x: 9, y: 6))
          }
          .stroke(Hardware.greasePencil, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
          .shadow(color: .black.opacity(0.5), radius: 0.5, y: 0.5)
        } else {
          Circle().fill(.black.opacity(0.45))
            .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
            .frame(width: 12, height: 12)
        }
      }
      .frame(width: 18, height: 16).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("勾选，用于扫描和导出")
    .accessibilityValue(configuration.isOn ? "已勾选" : "未勾选")
  }
}
