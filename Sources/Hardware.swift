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
  /// The panels float as the system's Liquid Glass over the light table and the keys, lamps and
  /// readouts take its look. With EPSON_SCAN_PLUS_NO_GLASS set, for screenshots, which cannot catch
  /// the system's glass, the scanner console instead.
  static let glass = ProcessInfo.processInfo.environment["EPSON_SCAN_PLUS_NO_GLASS"] == nil
}

/// A key, as the system draws one: bordered, and filled with the accent when it leads its panel
/// or stands latched on. Its label keeps the system's colours, light on the fill: a colour set
/// inside the label shows on the fill too (macOS 27), and amber on amber reads as grey.
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
      // Blinked by Core Animation, in the window server. SwiftUI's phase animator updated the
      // window for it on every frame, in the toolbar laying the toolbar out again each time: two
      // thirds of the main thread's time while the assistant's lamp waited for one to connect, and
      // a zoom or a slider waited behind it.
      BlinkingLamp(lamp: led, size: size).frame(width: size, height: size)
    } else {
      led
    }
  }
}

/// A lamp drawn once by SwiftUI, its opacity going from 1 to 0.35 and back every 1.2 s.
private struct BlinkingLamp<Lamp: View>: NSViewRepresentable {
  var lamp: Lamp
  var size: CGFloat
  final class Host: NSView {
    let hosting: NSHostingView<Lamp>
    private(set) var size: CGFloat
    init(_ lamp: Lamp, size: CGFloat) {
      hosting = NSHostingView(rootView: lamp)
      self.size = size
      super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
      // Placed by its frame, and sized by nothing it shows: with its content's size as
      // constraints, every update of the window measured the lamp's own view again on the main
      // thread, a tenth of each step of a slider dragged while the lamp blinked.
      hosting.sizingOptions = []
      hosting.translatesAutoresizingMaskIntoConstraints = false
      hosting.wantsLayer = true
      addSubview(hosting)
      place(size)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
    /// Room round the lamp for its glow, which reaches past it.
    func place(_ size: CGFloat) {
      self.size = size
      hosting.frame = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: -size, dy: -size)
    }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      blink()
    }
    /// Again whenever the view comes into a window: AppKit may take a layer's animations away.
    func blink() {
      guard let layer = hosting.layer, layer.animation(forKey: "blink") == nil else { return }
      let blink = CABasicAnimation(keyPath: "opacity")
      blink.fromValue = 1.0
      blink.toValue = 0.35
      blink.duration = 0.6
      blink.autoreverses = true
      blink.repeatCount = .infinity
      blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer.add(blink, forKey: "blink")
    }
  }
  func makeNSView(context: Context) -> Host { Host(lamp, size: size) }
  /// The lamp is drawn once: it blinks in the window server, and a busy lamp is always amber.
  /// Only a new size draws it again.
  func updateNSView(_ view: Host, context: Context) {
    if view.size != size {
      view.hosting.rootView = lamp
      view.place(size)
    }
    view.blink()
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host, context: Context) -> CGSize? {
    CGSize(width: size, height: size)
  }
}

/// The dark screen a plot is drawn on, curves or histograms, in either look.
struct PlotScreen: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.78))
  }
}

/// The system's Liquid Glass, found at run time: built with an SDK from before macOS 26, this app
/// has no name for it, but the system draws it all the same.
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
  /// The plate under a control floating over the picture. The picture shows through the system's
  /// Liquid Glass, lensed at its rim: with the macOS 26 SDK through SwiftUI, which keeps the text
  /// legible by itself; built with an earlier one, the system's glass view behind light text, a
  /// little darkened. Without glass, a dark translucent plate.
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

/// The module switch: the system's segmented control, each segment greyed out where its page
/// cannot open yet. A segment chosen calls `choose` with its index.
struct ModuleSwitch: NSViewRepresentable {
  let titles: [String]
  let selected: Int
  let enabled: [Bool]
  let help: String
  let choose: (Int) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(choose) }
  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
    control.setAccessibilityLabel("模块")
    return control
  }
  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    context.coordinator.choose = choose
    if control.segmentCount != titles.count { control.segmentCount = titles.count }
    let font = control.font ?? .systemFont(ofSize: NSFont.systemFontSize)
    if context.coordinator.greyed.count != titles.count { context.coordinator.greyed = Array(repeating: nil, count: titles.count) }
    for (i, title) in titles.enumerated() {
      if control.isEnabled(forSegment: i) != enabled[i] { control.setEnabled(enabled[i], forSegment: i) }
      // In the glass toolbar (macOS 26 on) a segment turned off is drawn as bright as the others,
      // so its title is drawn here instead, as a picture in the colour of text that cannot be used.
      let label = enabled[i] ? title : ""
      if control.label(forSegment: i) != label { control.setLabel(label, forSegment: i) }
      let greyed = enabled[i] ? nil : title
      if context.coordinator.greyed[i] != greyed {
        context.coordinator.greyed[i] = greyed
        control.setImage(greyed.map { Self.greyedTitle($0, font: font) }, forSegment: i)
      }
    }
    if control.selectedSegment != selected { control.selectedSegment = selected }
    control.toolTip = help
  }
  /// `title` as a picture, drawn when shown so that it follows the window's light or dark look. The
  /// system's own greys come out clear in the glass, and a segment turned off draws its picture at
  /// about half strength, so it is drawn at 70% white (or black): a third, as text that cannot be used.
  static func greyedTitle(_ title: String, font: NSFont) -> NSImage {
    let size = (title as NSString).size(withAttributes: [.font: font])
    let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { _ in
      let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      (title as NSString).draw(at: .zero, withAttributes: [.font: font, .foregroundColor: NSColor(white: dark ? 1 : 0, alpha: 0.7)])
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = title
    return image
  }
  final class Coordinator: NSObject {
    var choose: (Int) -> Void
    /// The segments drawn greyed, by their titles; nil where a segment shows its own label.
    var greyed = [String?]()
    init(_ choose: @escaping (Int) -> Void) { self.choose = choose }
    @objc func changed(_ control: NSSegmentedControl) { choose(control.selectedSegment) }
  }
}

/// A slider, the system's, a double click taking it back to `detent`. Where the slider has one, its
/// track is drawn shading from what its left end does to what its right end does.
struct Fader: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var detent: Double? = nil
  /// The track's colours, left to right; nil takes the slider's own by its title (`gradients`).
  var gradient: [Color]? = nil
  var body: some View {
    if let colours = gradient ?? Self.gradients[title] {
      GradientSlider(title: title, value: $value, range: range, detent: detent, colours: colours.map { NSColor($0) })
    } else {
      Slider(value: $value, in: range) { Text(title) }.labelsHidden().tint(Hardware.accent)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if let detent { value = detent } })
        .accessibilityLabel(title)
    }
  }
  private static let cool = Color(red: 0.35, green: 0.58, blue: 0.98), warm = Color(red: 0.98, green: 0.66, blue: 0.28)
  private static let green = Color(red: 0.32, green: 0.78, blue: 0.4), magenta = Color(red: 0.88, green: 0.36, blue: 0.78)
  private static func grey(_ w: Double) -> Color { Color(white: w) }
  /// What each slider does, left to right, by its title: colours toward the colour it gives, greys
  /// toward the lightness. Sliders whose ends are no colour or lightness (contrast, noise, gamma,
  /// sharpening, angles) have none.
  static let gradients: [String: [Color]] = [
    "冷暖": [cool, grey(0.62), warm],
    "冷 ↔ 暖": [cool, grey(0.62), warm],
    "绿 / 洋红": [green, grey(0.62), magenta],
    "阴影冷暖": [Color(red: 0.12, green: 0.22, blue: 0.48), grey(0.25), Color(red: 0.48, green: 0.3, blue: 0.1)],
    "阴影色调": [Color(red: 0.14, green: 0.4, blue: 0.18), grey(0.25), Color(red: 0.42, green: 0.14, blue: 0.38)],
    "曝光 · EV": [grey(0.06), grey(0.5), grey(0.95)],
    "曝光": [grey(0.06), grey(0.5), grey(0.95)],
    "高光": [grey(0.62), grey(1)],
    "阴影": [grey(0.02), grey(0.38)],
    "白色": [grey(0.72), grey(1)],
    "黑色": [grey(0), grey(0.28)],
    "中间调": [grey(0.22), grey(0.78)],
    "黑点": [grey(0.22), grey(0)],
    "白点": [grey(1), grey(0.74)],
    "饱和度": [grey(0.55), Color(red: 0.98, green: 0.42, blue: 0.22)],
  ]
}

/// The system's slider with its track drawn in `colours`, left to right, and no accent fill: the
/// knob, the keys, scrolling and VoiceOver as any slider's. A double click takes it to `detent`.
struct GradientSlider: NSViewRepresentable {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var detent: Double?
  let colours: [NSColor]
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> DetentSlider {
    let slider = DetentSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
      target: context.coordinator, action: #selector(Coordinator.moved(_:)))
    slider.isContinuous = true
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return slider
  }
  func updateNSView(_ slider: DetentSlider, context: Context) {
    context.coordinator.parent = self
    if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
    if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
    // Set at once (自动调整, 重置调整), in an animated change, the knob moves there; otherwise, and
    // while the hand is on it, it is set.
    if (slider.glideTarget ?? slider.doubleValue) != value {
      if let _ = context.transaction.animation, !context.transaction.disablesAnimations, slider.window != nil {
        slider.glide(to: value)
      } else {
        slider.stopGlide()
        slider.doubleValue = value
      }
    }
    slider.detent = detent
    slider.isEnabled = context.environment.isEnabled
    if let cell = slider.cell as? GradientSliderCell, cell.colours != colours {
      cell.colours = colours
      slider.needsDisplay = true
    }
    slider.setAccessibilityLabel(title)
  }
  final class Coordinator: NSObject {
    var parent: GradientSlider
    init(_ parent: GradientSlider) { self.parent = parent }
    @objc func moved(_ slider: NSSlider) {
      if parent.value != slider.doubleValue { parent.value = slider.doubleValue }
    }
  }
}

/// A slider a double click sets to `detent`.
final class DetentSlider: NSSlider {
  var detent: Double?
  override class var cellClass: AnyClass? {
    get { GradientSliderCell.self }
    set {}
  }
  private var glideTimer: Timer?
  /// Where the knob is gliding to, while it does.
  private(set) var glideTarget: Double?
  /// The knob moved to `target` in a little over a quarter of a second, easing out (a tenth with
  /// Reduce Motion); the value is shown, not sent: it is the setting's already.
  func glide(to target: Double) {
    stopGlide()
    let start = doubleValue, began = CACurrentMediaTime()
    let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.28
    guard abs(target - start) > 1e-12 else { return }
    glideTarget = target
    let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      let k = min(1, (CACurrentMediaTime() - began) / duration)
      self.doubleValue = start + (target - start) * (1 - pow(1 - k, 3))
      if k >= 1 { self.stopGlide() }
    }
    RunLoop.main.add(timer, forMode: .common)
    glideTimer = timer
  }
  /// The glide stopped where the knob is, or set by the hand.
  func stopGlide() {
    glideTimer?.invalidate()
    glideTimer = nil
    if let target = glideTarget {
      glideTarget = nil
      doubleValue = target
    }
  }
  override func mouseDown(with event: NSEvent) {
    stopGlide()
    if event.clickCount == 2, let detent {
      doubleValue = detent
      sendAction(action, to: target)
      return
    }
    super.mouseDown(with: event)
  }
}

/// The track as a rounded bar of the slider's colours, under the system's knob.
final class GradientSliderCell: NSSliderCell {
  var colours = [NSColor]()
  override func drawBar(inside rect: NSRect, flipped: Bool) {
    guard colours.count > 1, let gradient = NSGradient(colors: colours) else { return super.drawBar(inside: rect, flipped: flipped) }
    let height: CGFloat = 5
    let bar = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    let path = NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2)
    NSGraphicsContext.saveGraphicsState()
    if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }
    gradient.draw(in: path, angle: 0)
    // An edge, so that the ends near the panel's own colour still show where the track is.
    NSColor.separatorColor.setStroke()
    path.lineWidth = 0.5
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
  }
}

/// A slider's figure that can be typed into: shown as its readout, a click makes it a field.
/// Return, or clicking elsewhere, sets what was typed, within the slider's `range`; Escape keeps
/// the value as it was. `scale` is how much bigger the figure is than the value (100 for a
/// percentage); units and signs around the number (°, %, ‰, a full-width minus) may stay.
struct ValueField: View {
  let title: String
  /// The readout as the slider shows it.
  let text: String
  let value: Double
  let range: ClosedRange<Double>
  var scale: Double = 1
  let set: (Double) -> Void
  @Environment(\.isEnabled) private var enabled
  @State private var editing = false
  @State private var draft = ""
  @FocusState private var focused: Bool
  var body: some View {
    if editing {
      TextField(title, text: $draft)
        .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).multilineTextAlignment(.trailing)
        .frame(width: 72).controlSize(.small).focused($focused)
        .onSubmit(commit)
        .onExitCommand { editing = false }
        .onChange(of: focused) { _, now in if !now { commit() } }
        .onAppear { DispatchQueue.main.async { focused = true } }
        .accessibilityLabel(title)
    } else {
      Text(text).readout()
        .padding(.horizontal, 3).contentShape(Rectangle())
        .onTapGesture {
          guard enabled else { return }
          draft = Self.figure(text) ?? Self.plain(value * scale)
          editing = true
        }
        .help(enabled ? "点一下输入数值" : "")
        .accessibilityLabel(title).accessibilityValue(text)
        .accessibilityAddTraits(enabled ? .isButton : [])
    }
  }
  private func commit() {
    guard editing else { return }
    editing = false
    guard let typed = Self.number(draft) else { return }
    set(min(range.upperBound, max(range.lowerBound, typed / scale)))
  }
  /// The number in what was typed: units and spaces dropped, full-width figures and minus signs,
  /// and a decimal comma, read as ASCII. Nil when there is none.
  static func number(_ typed: String) -> Double? {
    var t = typed.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? typed
    for (from, to) in [("−", "-"), ("–", "-"), ("，", "."), (",", "."), ("。", ".")] { t = t.replacingOccurrences(of: from, with: to) }
    let kept = t.filter { "0123456789.+-".contains($0) }
    return kept.isEmpty ? nil : Double(kept)
  }
  /// The readout's figure, its units dropped, to start the field from; nil when it has none ("关").
  static func figure(_ text: String) -> String? {
    let kept = text.filter { "0123456789.+-".contains($0) }
    return kept.contains(where: \.isNumber) ? kept : nil
  }
  static func plain(_ v: Double) -> String { String(format: "%g", v) }
}

/// 135 film base behind the thumbnails, perforated along both edges.
struct FilmBase: View {
  /// The film's base and whether it is perforated (135) or not (120).
  var look: FilmStripMaterial.Look = .colour
  @Environment(\.colorScheme) private var scheme
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    GeometryReader { g in
      if let tile = FilmStripMaterial.shared.tile(height: g.size.height, scale: displayScale, look: look) {
        // Shaded once for its height, repeated along it; the perforations open to what is behind.
        Image(decorative: tile, scale: displayScale).resizable(resizingMode: .tile)
          .frame(width: g.size.width, height: g.size.height)
      } else {
        flat
      }
    }
  }
  /// Without Metal: the base, a gradient, and the perforations in what lies behind the film.
  var flat: some View {
    let hole = scheme == .light ? Color(white: 0.84) : Color(white: 0.085)
    let base = Color(.sRGB, red: Double(look.base.x).squareRoot(), green: Double(look.base.y).squareRoot(), blue: Double(look.base.z).squareRoot())
    return Canvas { ctx, size in
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
      ctx.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .linearGradient(
          Gradient(colors: [.white.opacity(0.07), .clear, .black.opacity(0.12)]),
          startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
      guard look.perforated else { return }
      let perforation = FilmStripMaterial.hole
      for y in [3, size.height - 3 - perforation.height] {
        for x in stride(from: 3, to: size.width - perforation.width, by: FilmStripMaterial.pitch) {
          ctx.fill(
            Path(roundedRect: CGRect(origin: CGPoint(x: x, y: y), size: perforation), cornerRadius: 1.2),
            with: .color(hole))
        }
      }
    }
  }
}

