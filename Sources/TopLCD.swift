import SwiftUI

/// The camera's settings as a camera's top-plate display shows them: a monochrome LCD sunk into
/// the black body under a thick clear cover, its seven-segment figures leaning a little and
/// standing off the pale grey-green reflector behind them, so each throws a faint shadow down and
/// to the right. Every figure has its own cells, the unlit segments barely there, the digits
/// right-aligned in them as an LCD's are. Shutter and aperture large with the mode beside them;
/// under a printed rule ISO in its box, the exposure scale where the panel is wide enough, the
/// pictures taken in brackets and the battery's bars. In the dark appearance its lamp is on, the
/// orange backlight cameras light for night work. The pointer over it moves the shadows and the
/// cover's sheen a little, as looking at it from the side would.
struct TopLCD: View {
  /// The camera's own texts for them, as `CameraProperty.describe` gives them: 1/125, 0.5",
  /// f/5.6, ISO 100, +0.7 EV, M.
  var shutter: String
  var aperture: String
  var iso: String
  var bias: String? = nil
  var mode: String? = nil
  /// Pictures taken this session; nil hides the count.
  var shots: Int? = nil
  /// The battery's charge, 0–1; nil when not known.
  var battery: Double? = nil
  var connected = true
  /// Lit, as in the dark appearance; nil follows the appearance.
  var lit: Bool? = nil

  static let height: CGFloat = 92
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Where the pointer is over it, −0.5…0.5 each way from the middle.
  @State private var look = CGSize.zero

  var body: some View {
    GeometryReader { g in
      Canvas { ctx, size in
        Self.draw(&ctx, size: size, lcd: self, lit: lit ?? (scheme == .dark), look: look)
      }
      .onContinuousHover { phase in
        guard !reduceMotion else { return }
        switch phase {
        case .active(let p):
          look = CGSize(width: p.x / max(g.size.width, 1) - 0.5, height: p.y / max(g.size.height, 1) - 0.5)
        case .ended:
          withAnimation(.easeOut(duration: 0.35)) { look = .zero }
        }
      }
    }
    .frame(height: Self.height)
    .accessibilityElement()
    .accessibilityLabel("相机的设置")
    .accessibilityValue(spoken)
  }
  private var spoken: String {
    guard connected else { return "未连接" }
    var parts = ["快门 \(shutter)", "光圈 \(aperture)", iso]
    if let mode { parts.insert("\(mode) 档", at: 0) }
    if let bias { parts.append("曝光补偿 \(bias)") }
    if let shots { parts.append("已拍 \(shots) 张") }
    if let battery { parts.append("电量 \(Int((battery * 100).rounded()))%") }
    return parts.joined(separator: "，")
  }

  // MARK: What the figures say

  /// The shutter speed as the panel writes it: 125 for 1/125, 0"5 for half a second, 2" for two,
  /// buLb on B.
  static func shutterFace(_ text: String) -> String {
    if text == "B" { return "buLb" }
    if text.hasPrefix("1/") { return String(text.dropFirst(2)) }
    if text.hasSuffix("\""), let s = Double(text.dropLast()) {
      let whole = Int(s), tenth = Int(((s - Double(whole)) * 10).rounded())
      return tenth == 0 ? "\(whole)\"" : "\(whole)\"\(tenth)"
    }
    return text
  }
  /// The aperture: 5.6, 8.0, 11, 22.
  static func apertureFace(_ text: String) -> String {
    guard text.hasPrefix("f/"), let f = Double(text.dropFirst(2)) else { return text }
    return f >= 10 ? "\(Int(f.rounded()))" : String(format: "%.1f", f)
  }
  /// ISO: the number, or Auto.
  static func isoFace(_ text: String) -> String {
    let t = text.replacingOccurrences(of: "ISO ", with: "")
    return t == "AUTO" ? "Auto" : t
  }
  /// Exposure compensation in EV, from its text.
  static func biasValue(_ text: String?) -> Double? {
    guard let text else { return nil }
    let n = text.replacingOccurrences(of: " EV", with: "").replacingOccurrences(of: "±", with: "")
    return Double(n)
  }
  /// A figure's characters into the cells they light, a decimal point or a seconds mark joining
  /// the cell before it as an LCD's do.
  static func cells(_ s: String) -> [(glyph: Character, mark: Character?)] {
    var out = [(glyph: Character, mark: Character?)]()
    for c in s {
      if c == "." || c == "\"", !out.isEmpty, out[out.count - 1].mark == nil { out[out.count - 1].mark = c } else { out.append((c, nil)) }
    }
    return out
  }

  // MARK: Drawing

  struct Colours {
    let top: Color, bottom: Color, ink: Color, shadow: Color, ghost: Double
  }
  /// Unlit: the reflector a pale grey-green, as daylight shows it. Lit: the orange lamp behind it.
  static func colours(lit: Bool) -> Colours {
    lit
      ? Colours(top: Color(red: 0.93, green: 0.62, blue: 0.27), bottom: Color(red: 0.78, green: 0.45, blue: 0.15),
        ink: Color(red: 0.14, green: 0.06, blue: 0.02), shadow: Color(red: 0.35, green: 0.12, blue: 0).opacity(0.36), ghost: 0.03)
      : Colours(top: Color(red: 0.80, green: 0.82, blue: 0.77), bottom: Color(red: 0.69, green: 0.72, blue: 0.67),
        ink: Color(red: 0.09, green: 0.10, blue: 0.09), shadow: Color.black.opacity(0.28), ghost: 0.022)
  }

  static func draw(_ ctx: inout GraphicsContext, size: CGSize, lcd: TopLCD, lit: Bool, look: CGSize) {
    let c = colours(lit: lit)
    let body = CGRect(origin: .zero, size: size)
    // The body round the window: black plastic with a fine grain, lit from above.
    ctx.fill(Path(roundedRect: body, cornerRadius: 10), with: .linearGradient(
      Gradient(colors: [Color(white: 0.17), Color(white: 0.07)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    var grain = Path()
    var seed: UInt32 = 7
    for _ in 0..<Int(size.width * size.height / 40) {
      seed = seed &* 1103515245 &+ 12345
      let x = CGFloat((seed >> 16) % 1000) / 1000 * size.width
      seed = seed &* 1103515245 &+ 12345
      let y = CGFloat((seed >> 16) % 1000) / 1000 * size.height
      grain.addRect(CGRect(x: x, y: y, width: 0.7, height: 0.7))
    }
    ctx.fill(grain, with: .color(.white.opacity(0.06)))
    ctx.stroke(Path(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 9.5), with: .linearGradient(
      Gradient(colors: [.white.opacity(0.16), .white.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)), lineWidth: 1)
    // The window, sunk into it: a dark well where the body turns down, then the LCD.
    let window = body.insetBy(dx: 7, dy: 7)
    ctx.fill(Path(roundedRect: window.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 7), with: .color(.black.opacity(0.9)))
    let screen = window.insetBy(dx: 2.5, dy: 2.5)
    // The cover's chamfered edge between the well and the screen, catching the light above it.
    ctx.stroke(Path(roundedRect: window.insetBy(dx: 0.9, dy: 0.9), cornerRadius: 5.6), with: .linearGradient(
      Gradient(colors: [Color(white: 0.62), Color(white: 0.3), Color(white: 0.12)]),
      startPoint: CGPoint(x: window.minX, y: window.minY), endPoint: CGPoint(x: window.minX + window.width * 0.25, y: window.maxY)), lineWidth: 1.8)
    ctx.fill(Path(roundedRect: screen, cornerRadius: 4.5), with: .linearGradient(
      Gradient(colors: [c.top, c.bottom]), startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
    if lit {
      // The lamp is brighter in the middle than at the ends.
      ctx.fill(Path(roundedRect: screen, cornerRadius: 4.5), with: .radialGradient(
        Gradient(colors: [Color(red: 1, green: 0.8, blue: 0.45).opacity(0.45), .clear]),
        center: CGPoint(x: screen.midX, y: screen.midY), startRadius: 0, endRadius: screen.width * 0.6))
    }
    // The well's own shadow on the screen's top and left edges, under the cover.
    ctx.stroke(Path(roundedRect: screen.insetBy(dx: 1.2, dy: 1.2), cornerRadius: 3.8), with: .linearGradient(
      Gradient(colors: [.black.opacity(0.28), .clear]), startPoint: CGPoint(x: screen.minX, y: screen.minY),
      endPoint: CGPoint(x: screen.minX + 14, y: screen.minY + 10)), lineWidth: 2.4)

    // Where the figures go.
    let pad: CGFloat = 9
    let big = min(screen.height * 0.42, screen.width * 0.14)
    let small = (big * 0.52).rounded(.down)
    let row1 = screen.minY + 7, row2 = screen.maxY - 7 - small
    var segments = Path(), ghost = Path()
    func figure(_ s: String, cellsCount n: Int, rightEdge: CGFloat, top: CGFloat, height h: CGFloat) -> CGFloat {
      let shown = cells(s).suffix(n)
      let x0 = rightEdge - CGFloat(n) * SevenSegment.advance(h) - h * SevenSegment.slant
      for i in 0..<n {
        ghost.addPath(SevenSegment.glyph("8", at: CGPoint(x: x0 + CGFloat(i) * SevenSegment.advance(h), y: top), height: h))
      }
      for (i, cell) in shown.enumerated() {
        let x = x0 + CGFloat(n - shown.count + i) * SevenSegment.advance(h)
        segments.addPath(SevenSegment.glyph(cell.glyph, at: CGPoint(x: x, y: top), height: h))
        if let mark = cell.mark { segments.addPath(SevenSegment.mark(mark, after: CGPoint(x: x, y: top), height: h)) }
      }
      return x0
    }
    var printed = Path()
    var texts = [(String, CGPoint, CGFloat, UnitPoint)]()
    // Row 1: the mode at the left, the shutter after it, the aperture at the right with its F.
    let modeSize = (big * 0.46).rounded()
    if let mode = lcd.mode, lcd.connected, mode.count <= 2 {
      texts.append((mode, CGPoint(x: screen.minX + pad, y: row1 + 1), modeSize, .topLeading))
    }
    let shutterRight = screen.minX + pad + modeSize * 0.9 + 4 * SevenSegment.advance(big) + big * SevenSegment.slant + 4
    _ = figure(lcd.connected ? shutterFace(lcd.shutter) : "----", cellsCount: 4, rightEdge: shutterRight, top: row1, height: big)
    let apertureLeft = figure(lcd.connected ? apertureFace(lcd.aperture) : "--", cellsCount: 2, rightEdge: screen.maxX - pad, top: row1, height: big)
    let fh = (big * 0.56).rounded()
    segments.addPath(SevenSegment.glyph("F", at: CGPoint(x: apertureLeft - SevenSegment.advance(fh) - 1, y: row1 + big - fh), height: fh))
    // The printed rule between the rows, broken in the middle as on the panel.
    let ruleY = ((row1 + big + row2) / 2).rounded()
    printed.addRect(CGRect(x: screen.minX + pad, y: ruleY, width: screen.width * 0.42 - pad, height: 0.8))
    printed.addRect(CGRect(x: screen.maxX - screen.width * 0.42, y: ruleY, width: screen.width * 0.42 - pad, height: 0.8))
    // Row 2: ISO in its box with the figure after it.
    let tag = CGRect(x: screen.minX + pad, y: row2 + small * 0.12, width: (small * 1.7).rounded(), height: (small * 0.76).rounded())
    printed.addPath(Path(roundedRect: tag, cornerRadius: 1.4).strokedPath(StrokeStyle(lineWidth: 0.9)))
    texts.append(("ISO", CGPoint(x: tag.midX, y: tag.midY), (small * 0.52).rounded(), .center))
    let isoRight = tag.maxX + 4 + 5 * SevenSegment.advance(small) + small * SevenSegment.slant
    _ = figure(lcd.connected ? isoFace(lcd.iso) : "---", cellsCount: 5, rightEdge: isoRight, top: row2, height: small)
    // At the right the battery, the pictures in brackets before it.
    let cellW = (small * 1.5).rounded()
    let batteryRect = CGRect(x: screen.maxX - pad - cellW - 1.5, y: row2 + small * 0.16, width: cellW, height: (small * 0.7).rounded())
    segments.addPath(battery(batteryRect, charge: lcd.connected ? lcd.battery : nil))
    var rightBlock = batteryRect.minX
    if lcd.shots != nil || !lcd.connected {
      let count = lcd.connected ? lcd.shots.map { "\(min($0, 9999))" } ?? "" : ""
      let closeX = batteryRect.minX - 7
      let left = figure(count, cellsCount: 4, rightEdge: closeX - 2.5, top: row2, height: small)
      printed.addPath(bracket(x: left - 2, top: row2 - 1, height: small + 2, opening: true))
      printed.addPath(bracket(x: closeX, top: row2 - 1, height: small + 2, opening: false))
      rightBlock = left - 4
    }
    // The exposure scale between them, when there is room: −3 to +3 in thirds, the current
    // compensation marked under it.
    let room = rightBlock - isoRight - 12
    if room >= 58 {
      let w = min(room, 112), x0 = isoRight + 6 + (room - w) / 2
      let span = w - 18, mid = row2 + small * 0.36
      printed.addRect(CGRect(x: x0, y: mid - 0.5, width: 4.5, height: 1))
      printed.addRect(CGRect(x: x0 + w - 4.5, y: mid - 0.5, width: 4.5, height: 1))
      printed.addRect(CGRect(x: x0 + w - 2.75, y: mid - 2.25, width: 1, height: 4.5))
      for i in 0...18 {
        let x = x0 + 9 + span * CGFloat(i) / 18
        let whole = i % 3 == 0
        let tall: CGFloat = i == 9 ? small * 0.5 : whole ? small * 0.32 : 1.3
        printed.addRect(CGRect(x: x - (whole ? 0.6 : 0.65), y: mid - tall / 2, width: whole ? 1.2 : 1.3, height: tall))
      }
      if lcd.connected, let ev = biasValue(lcd.bias) {
        let at = x0 + 9 + span * CGFloat((max(-3, min(3, (ev * 3).rounded() / 3)) + 3) / 6)
        var mark = Path()
        mark.move(to: CGPoint(x: at, y: row2 + small * 0.62))
        mark.addLine(to: CGPoint(x: at + 2.6, y: row2 + small + 0.5))
        mark.addLine(to: CGPoint(x: at - 2.6, y: row2 + small + 0.5))
        mark.closeSubpath()
        segments.addPath(mark)
      }
    }

    // The unlit segments, barely there; then the lit ones and the printed marks, each with its
    // shadow on the reflector a little down and to the right of it, moving as the pointer does.
    ctx.fill(ghost, with: .color(c.ink.opacity(c.ghost)))
    var marks = ctx
    marks.addFilter(.shadow(color: c.shadow, radius: 1, x: 1.7 + look.width * 1.6, y: 2.1 + look.height * 1.2))
    let ink = GraphicsContext.Shading.linearGradient(
      Gradient(colors: [c.ink.opacity(0.86), c.ink]), startPoint: CGPoint(x: 0, y: screen.minY), endPoint: CGPoint(x: 0, y: screen.maxY))
    marks.fill(segments, with: ink)
    marks.fill(printed, with: .color(c.ink.opacity(0.92)))
    for (text, at, size, anchor) in texts {
      marks.draw(Text(text).font(.system(size: size, weight: .heavy, design: .rounded)).foregroundStyle(c.ink), at: at, anchor: anchor)
    }

    // The cover over it, thick and clear: the room's light in it as a soft band across the upper
    // left, its bevel bright along the top and dark at the bottom.
    let sheenX = screen.minX + screen.width * (0.05 - look.width * 0.12)
    ctx.fill(Path(roundedRect: screen, cornerRadius: 4.5), with: .linearGradient(
      Gradient(stops: [
        .init(color: .white.opacity(lit ? 0.16 : 0.26), location: 0), .init(color: .white.opacity(0.06), location: 0.4),
        .init(color: .clear, location: 0.58),
      ]),
      startPoint: CGPoint(x: sheenX, y: screen.minY), endPoint: CGPoint(x: sheenX + screen.width * 0.32, y: screen.maxY)))
    ctx.stroke(Path(roundedRect: screen.insetBy(dx: 0.6, dy: 0.6), cornerRadius: 4), with: .linearGradient(
      Gradient(colors: [.white.opacity(0.55), .white.opacity(0.1), .black.opacity(0.35)]),
      startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.minX + screen.width * 0.3, y: screen.maxY)), lineWidth: 1.2)
  }

  /// The battery as panels draw it: an outline with its terminal, up to three bars inside.
  static func battery(_ r: CGRect, charge: Double?) -> Path {
    var p = Path(roundedRect: r, cornerRadius: 1.2).strokedPath(StrokeStyle(lineWidth: 1))
    p.addRect(CGRect(x: r.maxX, y: r.midY - r.height * 0.22, width: 1.6, height: r.height * 0.44))
    let w = (r.width - 3) / 3
    for i in 0..<bars(charge) {
      p.addRect(CGRect(x: r.minX + 1.5 + CGFloat(i) * w + 0.5, y: r.minY + 1.8, width: w - 1, height: r.height - 3.6))
    }
    return p
  }
  /// How many of the battery's three bars show.
  static func bars(_ charge: Double?) -> Int { charge.map { c in c > 0.66 ? 3 : c > 0.33 ? 2 : c > 0.05 ? 1 : 0 } ?? 0 }
  static func bracket(x: CGFloat, top: CGFloat, height: CGFloat, opening: Bool) -> Path {
    let arm: CGFloat = 2.2
    var p = Path()
    p.move(to: CGPoint(x: x + (opening ? arm : -arm), y: top))
    p.addLine(to: CGPoint(x: x, y: top))
    p.addLine(to: CGPoint(x: x, y: top + height))
    p.addLine(to: CGPoint(x: x + (opening ? arm : -arm), y: top + height))
    return p.strokedPath(StrokeStyle(lineWidth: 1.1))
  }
}

/// Figures as a seven-segment display draws them, leaning as camera panels' do: each of the seven
/// bars a hexagon pointed at both ends with a hair's gap between them; digits, the dash and the
/// few letters a camera spells with them (Auto, buLb, F).
enum SevenSegment {
  /// Which of a–g each character lights: a top, b upper right, c lower right, d bottom, e lower
  /// left, f upper left, g middle.
  static let segments: [Character: String] = [
    "0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg", "5": "acdfg", "6": "acdefg", "7": "abc", "8": "abcdefg",
    "9": "abcdfg", "-": "g", "F": "aefg", "r": "eg", "A": "abcefg", "b": "cdefg", "C": "adef", "c": "deg", "d": "bcdeg",
    "E": "adefg", "H": "bcefg", "L": "def", "P": "abefg", "S": "acdfg", "o": "cdeg", "n": "ceg", "u": "cde", "U": "bcdef",
    "t": "defg",
  ]
  static let slant: CGFloat = 0.13
  /// The step from one cell to the next.
  static func advance(_ h: CGFloat) -> CGFloat { h * 0.68 }
  static func width(_ h: CGFloat) -> CGFloat { h * 0.5 }

  static func glyph(_ c: Character, at o: CGPoint, height h: CGFloat) -> Path {
    let w = width(h), t = h * 0.125, gap = h * 0.022
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x + (h - y) * slant, y: o.y + y) }
    /// A bar between two corners of the figure, pointed at both ends.
    func bar(from a: CGPoint, to b: CGPoint) -> Path {
      var p = Path()
      let s = t / 2
      let pts: [(CGFloat, CGFloat)] = a.y == b.y
        ? [(a.x + gap, a.y), (a.x + gap + s, a.y - s), (b.x - gap - s, a.y - s), (b.x - gap, a.y), (b.x - gap - s, a.y + s), (a.x + gap + s, a.y + s)]
        : [(a.x, a.y + gap), (a.x + s, a.y + gap + s), (a.x + s, b.y - gap - s), (a.x, b.y - gap), (a.x - s, b.y - gap - s), (a.x - s, a.y + gap + s)]
      p.addLines(pts.map { pt($0.0, $0.1) })
      p.closeSubpath()
      return p
    }
    let l = t / 2, r = w - t / 2, top = t / 2, m = h / 2, bottom = h - t / 2
    var path = Path()
    for s in segments[c] ?? "" {
      switch s {
      case "a": path.addPath(bar(from: CGPoint(x: l, y: top), to: CGPoint(x: r, y: top)))
      case "b": path.addPath(bar(from: CGPoint(x: r, y: top), to: CGPoint(x: r, y: m)))
      case "c": path.addPath(bar(from: CGPoint(x: r, y: m), to: CGPoint(x: r, y: bottom)))
      case "d": path.addPath(bar(from: CGPoint(x: l, y: bottom), to: CGPoint(x: r, y: bottom)))
      case "e": path.addPath(bar(from: CGPoint(x: l, y: m), to: CGPoint(x: l, y: bottom)))
      case "f": path.addPath(bar(from: CGPoint(x: l, y: top), to: CGPoint(x: l, y: m)))
      case "g": path.addPath(bar(from: CGPoint(x: l, y: m), to: CGPoint(x: r, y: m)))
      default: break
      }
    }
    return path
  }
  /// A decimal point at the foot of the cell's right side, or the seconds mark at its head.
  static func mark(_ c: Character, after o: CGPoint, height h: CGFloat) -> Path {
    let t = h * 0.125, x = o.x + width(h) + (advance(h) - width(h)) / 2
    var p = Path()
    if c == "." {
      p.addEllipse(in: CGRect(x: x - t * 0.48, y: o.y + h - t * 0.96, width: t * 0.96, height: t * 0.96))
    } else {
      // Two short ticks leaning with the figures, in the gap at the top between the cells.
      let mid = o.x + width(h) + h * slant + (advance(h) - width(h)) / 2 - h * 0.01, drop = h * 0.26
      for dx in [-h * 0.038, h * 0.038] {
        let x0 = mid + dx, lean = drop * slant
        var tick = Path()
        tick.addLines([
          CGPoint(x: x0 - h * 0.02, y: o.y), CGPoint(x: x0 + h * 0.02, y: o.y),
          CGPoint(x: x0 + h * 0.008 - lean, y: o.y + drop), CGPoint(x: x0 - h * 0.012 - lean, y: o.y + drop),
        ])
        tick.closeSubpath()
        p.addPath(tick)
      }
    }
    return p
  }
}
