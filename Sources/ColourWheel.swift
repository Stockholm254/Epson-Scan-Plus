import SwiftUI

/// A colour wheel, as Lightroom's colour grading has: the hue round the rim, its amount from none at
/// the middle to all at the rim; dragged anywhere on it, the knob follows; a double click takes it
/// back to the middle. `hue` in degrees (0 red, 120 green, 240 blue), `amount` 0 to 1.
struct ColourWheel: View {
  @Binding var hue: Double
  @Binding var amount: Double
  var body: some View {
    GeometryReader { g in
      let size = min(g.size.width, g.size.height), r = size / 2
      let centre = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
      ZStack {
        Circle().fill(AngularGradient(
          gradient: Gradient(colors: stride(from: 0.0, through: 360, by: 30).map { Color(hue: $0 / 360, saturation: 0.75, brightness: 0.85) }),
          center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
        Circle().fill(RadialGradient(colors: [Color(white: 0.55), Color(white: 0.55).opacity(0)], center: .center, startRadius: 0, endRadius: r))
        Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
        // The knob: at the hue's angle (clockwise from the right on screen, as the gradient runs),
        // the amount's way out.
        let angle = hue * .pi / 180, out = amount * (r - 5)
        Circle().fill(Color.white).frame(width: 9, height: 9).shadow(radius: 1)
          .position(x: centre.x + CGFloat(cos(angle) * out), y: centre.y + CGFloat(sin(angle) * out))
      }
      .frame(width: size, height: size)
      .position(centre)
      .contentShape(Circle())
      .gesture(DragGesture(minimumDistance: 0).onChanged { v in
        let dx = Double(v.location.x - centre.x), dy = Double(v.location.y - centre.y)
        let reach = Double(r - 5)
        amount = min(1, (dx * dx + dy * dy).squareRoot() / max(reach, 1))
        hue = ((atan2(dy, dx) * 180 / .pi) + 360).truncatingRemainder(dividingBy: 360)
      })
      .onTapGesture(count: 2) { amount = 0 }
      .accessibilityElement()
      .accessibilityLabel("色轮")
      .accessibilityValue(String(format: "色相 %.0f°，浓度 %.0f%%", hue, amount * 100))
    }
  }
}

/// A frame's marks on the film strip, as Lightroom shows them: its colour label as a dot, its stars,
/// and its flag (a green flag picked, a red cross rejected); nothing when it has none.
struct FrameMarks: View {
  let frame: FilmFrame
  var body: some View {
    if frame.rating != nil || frame.flag != nil || frame.label != nil {
      HStack(spacing: 2) {
        if let l = frame.label.flatMap(FrameLabel.init(rawValue:)) {
          Circle().fill(Color(red: l.colour.r, green: l.colour.g, blue: l.colour.b)).frame(width: 7, height: 7)
        }
        if let r = frame.rating { Text(String(repeating: "★", count: r)).font(.system(size: 8)).foregroundStyle(.yellow) }
        if let flag = frame.flag {
          Image(systemName: flag > 0 ? "flag.fill" : "xmark").font(.system(size: 8, weight: .bold))
            .foregroundStyle(flag > 0 ? Color.green : Color.red)
        }
      }
      .padding(.horizontal, 3).padding(.vertical, 1)
      .background(Capsule().fill(Color.black.opacity(0.6)))
      .accessibilityElement().accessibilityLabel(AppModel.markWords(frame))
    }
  }
}
