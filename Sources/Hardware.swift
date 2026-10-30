import AppKit
import SwiftUI

/// The app's colours and the parts it shares: keys, lamps, readouts, sliders and film, most of
/// them the system's own.
enum Hardware {
  static let amber = Color(red: 0.91, green: 0.68, blue: 0.37)
  /// The tint of the controls that are the app's own amber, the leading actions, latched keys,
  /// switches and sliders: one colour for both appearances, set on them and not on the window, where
  /// it would take the pop-up menus' text away.
  static let accent = Color(red: 0.86, green: 0.56, blue: 0.18)
  static let lcdText = Color(red: 1.0, green: 0.75, blue: 0.4)
  static let lcdGlass = Color(red: 0.075, green: 0.068, blue: 0.052)
  static let greasePencil = Color(red: 0.86, green: 0.24, blue: 0.17)
  static let edgePrint = Color(red: 0.98, green: 0.71, blue: 0.4)
  static let filmBase = Color(red: 0.25, green: 0.13, blue: 0.06)
  /// A colour for each look, as the view's colour scheme is: `dark` in the dark console, `light`
  /// on the copy stand's light glass.
  /// With Increase Contrast each is taken a third of the way further from the ground it lies on:
  /// lighter on the dark console, darker on light glass.
  static func adaptive(_ dark: NSColor, _ light: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { a in
      switch a.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
      case .aqua?: return light
      case .accessibilityHighContrastAqua?: return light.blended(withFraction: 0.35, of: .black) ?? light
      case .accessibilityHighContrastDarkAqua?: return dark.blended(withFraction: 0.35, of: .white) ?? dark
      default: return dark
      }
    })
  }
  /// Text on a key or a pane: light on the console, dark ink on light glass.
  static let ink = adaptive(NSColor(white: 0.92, alpha: 1), NSColor(white: 0.13, alpha: 1))
  /// Amber that reads on either: the console's, or a deeper one on light glass.
  static let amberText = adaptive(NSColor(red: 0.91, green: 0.68, blue: 0.37, alpha: 1), NSColor(red: 0.66, green: 0.4, blue: 0.08, alpha: 1))
  /// The system draws Liquid Glass (macOS 26): the panels float as glass over the light table and
  /// the keys, lamps and readouts take its look. Before, the scanner console; also with
  /// EPSON_SCAN_PLUS_NO_GLASS set, for screenshots, which cannot catch the system's glass.
  static let glass = SystemGlass.viewClass != nil && ProcessInfo.processInfo.environment["EPSON_SCAN_PLUS_NO_GLASS"] == nil
}

/// A key, as the system draws one: bordered, and filled with the accent when it leads its panel
/// or stands latched on.
struct KeyStyle: PrimitiveButtonStyle {
  var prominent = false
  var latched = false
  @ViewBuilder func makeBody(configuration: Configuration) -> some View {
    if prominent || latched {
      Button(configuration).buttonStyle(.borderedProminent).tint(Hardware.accent)
    } else {
      Button(configuration).buttonStyle(.bordered)
    }
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

/// The dark screen a plot is drawn on, curves or histograms, in either look.
struct PlotScreen: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.78))
  }
}

/// The system's Liquid Glass on macOS 26, found at run time: this app is built with an SDK from
/// before it, but the system draws it all the same. Nil on earlier systems.
enum SystemGlass {
  static var viewClass: NSView.Type? { NSClassFromString("NSGlassEffectView") as? NSView.Type }
}

/// A pane of the system's Liquid Glass behind a plate: what lies under it shows through, lensed at
/// its rim. It never takes the mouse.
struct SystemGlassBackground: NSViewRepresentable {
  var capsule: Bool
  var radius: CGFloat
  /// Darkens the glass a little, so light text stays legible over the bright light table.
  var tint: NSColor
  final class Host: NSView {
    let glass: NSView?
    var capsule = false, radius: CGFloat = 8
    init() {
      glass = SystemGlass.viewClass?.init(frame: .zero)
      super.init(frame: .zero)
      if let glass { addSubview(glass) }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
      super.layout()
      guard let glass else { return }
      glass.frame = bounds
      // Found by name at run time: only what this system's class answers to is set.
      if glass.responds(to: NSSelectorFromString("setCornerRadius:")) {
        glass.setValue(Double(capsule ? bounds.height / 2 : radius), forKey: "cornerRadius")
      }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
  func makeNSView(context: Context) -> Host { Host() }
  func updateNSView(_ host: Host, context: Context) {
    // Light glass where the view is in the light look, though the window is dark.
    host.appearance = NSAppearance(named: context.environment.colorScheme == .light ? .aqua : .darkAqua)
    host.capsule = capsule
    host.radius = radius
    if let glass = host.glass, glass.responds(to: NSSelectorFromString("setTintColor:")) { glass.setValue(tint, forKey: "tintColor") }
    host.needsLayout = true
  }
}

extension View {
  /// The plate under a control floating over the picture. Where the system has Liquid Glass
  /// (macOS 26) the picture shows through it, lensed at its rim: with its SDK through SwiftUI,
  /// which keeps the text legible by itself; built with an earlier one, the system's glass view
  /// behind light text, a little darkened. Before macOS 26, a dark translucent plate.
  @ViewBuilder func floatingPlate<S: Shape>(_ shape: S, text: Color, opacity: Double) -> some View {
    liquid(shape) { content in
      if Hardware.glass {
        content.foregroundStyle(text).background(
          SystemGlassBackground(
            capsule: shape is Capsule || shape is Circle, radius: (shape as? RoundedRectangle)?.cornerSize.width ?? 8,
            tint: NSColor(white: 0, alpha: opacity * 0.45)))
      } else {
        content.foregroundStyle(text).background(.black.opacity(opacity), in: shape)
      }
    }
  }
  /// A readout: figures in the system's monospaced type, secondary to the labels beside them.
  func readout(_ fontSize: CGFloat = 10) -> some View { modifier(Readout(fontSize: fontSize)) }
  /// A group of controls floating over the picture: a capsule of Liquid Glass, or a dark one.
  func glassBar() -> some View { modifier(GlassBar()) }
}

private struct Readout: ViewModifier {
  let fontSize: CGFloat
  func body(content: Content) -> some View {
    content.font(.system(size: fontSize + 1, weight: .medium, design: .monospaced)).monospacedDigit()
      .foregroundStyle(.secondary)
  }
}

private struct GlassBar: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceTransparency) private var opaque
  func body(content: Content) -> some View {
    let light = scheme == .light
    if opaque && !light {
      content.padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Color(white: 0.12)))
        .contentShape(Capsule())
    } else if light {
      content.padding(.horizontal, 8).padding(.vertical, 5)
        .frost(Capsule(), veil: Hardware.glass ? 0.18 : 0.62, glassRadius: 18, capsule: true)
        .contentShape(Capsule())
    } else if Hardware.glass {
      content.padding(.horizontal, 8).padding(.vertical, 5)
        .background(SystemGlassBackground(capsule: true, radius: 18, tint: NSColor(white: 0, alpha: 0.28)))
        .contentShape(Capsule())
    } else {
      content.padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Color(white: 0.1).opacity(0.88)))
        .contentShape(Capsule())
    }
  }
}

/// A slider, the system's, a double click taking it back to `detent`.
struct Fader: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var detent: Double? = nil
  var body: some View {
    Slider(value: $value, in: range) { Text(title) }.labelsHidden().tint(Hardware.accent)
      .simultaneousGesture(TapGesture(count: 2).onEnded { if let detent { value = detent } })
      .accessibilityLabel(title)
  }
}

/// 135 film base behind the thumbnails, perforated along both edges.
struct FilmBase: View {
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    // The perforations show what lies behind the film: the dark console, or light glass.
    let hole = scheme == .light ? Color(white: 0.84) : Color(white: 0.085)
    return Canvas { ctx, size in
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Hardware.filmBase))
      ctx.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .linearGradient(
          Gradient(colors: [.white.opacity(0.07), .clear, .black.opacity(0.12)]),
          startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
      let perforation = CGSize(width: 6, height: 4.5)
      for y in [3, size.height - 3 - perforation.height] {
        for x in stride(from: 3, to: size.width - perforation.width, by: 12) {
          ctx.fill(
            Path(roundedRect: CGRect(origin: CGPoint(x: x, y: y), size: perforation), cornerRadius: 1.2),
            with: .color(hole))
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
