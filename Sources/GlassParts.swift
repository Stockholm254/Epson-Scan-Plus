import AppKit
import SwiftUI

extension View {
  /// A pane of glass behind a group of controls floating over a picture: the system's Liquid Glass
  /// on macOS 26, lensing what lies under it, a little darkened so light text reads; before, a dark
  /// translucent plate of the same shape.
  @ViewBuilder func glassPane(radius: CGFloat = 16, darken: CGFloat = 0.28) -> some View {
    if Hardware.glass {
      background(SystemGlassBackground(capsule: false, radius: radius, tint: NSColor(white: 0, alpha: darken)))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    } else {
      background(RoundedRectangle(cornerRadius: radius).fill(Color(white: 0.1).opacity(0.88)))
    }
  }
  /// Tinted glass, as a coloured gel is: the system's glass in `tint` on macOS 26, else a plate.
  @ViewBuilder func tintedGlass(_ tint: Color, strength: Double, radius: CGFloat) -> some View {
    if Hardware.glass {
      background(SystemGlassBackground(capsule: false, radius: radius, tint: NSColor(tint).withAlphaComponent(strength)))
    } else {
      background(RoundedRectangle(cornerRadius: radius).fill(tint.opacity(strength)))
    }
  }
}

/// The shutter release, as a camera's is: a domed amber button sunk in a well in a knurled metal
/// collar, a socket for a cable release in its middle, sinking under the finger. A lamp on the
/// collar shows green while the camera is ready and blinks red while a picture is written and
/// sent, as a card's access lamp does; a ring of light goes off each time the shutter goes.
struct ShutterKey: View {
  let enabled: Bool
  /// A picture still on its way: the key takes no press until it is in.
  var busy = false
  /// The camera's count of shots taken: each new one flashes the ring.
  let shots: Int
  let action: () -> Void
  @State private var flash = 0.0
  @State private var blink = false
  var body: some View {
    Button(action: action) { EmptyView() }
      .buttonStyle(ShutterPress(enabled: enabled, busy: busy, flash: flash, blink: blink))
      .disabled(!enabled)
      .keyboardShortcut(.space, modifiers: [])
      .help("拍摄（空格）")
      .accessibilityLabel("拍摄")
      .accessibilityValue(busy ? "照片传输中" : enabled ? "就绪" : "未连接")
      .onChange(of: shots) {
        flash = 1
        withAnimation(.easeOut(duration: 0.5)) { flash = 0 }
      }
      .onChange(of: busy, initial: true) { _, now in
        if now {
          withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { blink = true }
        } else {
          withAnimation(.easeOut(duration: 0.15)) { blink = false }
        }
      }
  }
}

/// The release drawn, the button sunk while `pressed`.
struct ShutterPress: ButtonStyle {
  let enabled: Bool, busy: Bool, flash: Double, blink: Bool
  static let size: CGFloat = 76
  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed && enabled
    let d = Self.size
    let lamp = busy ? Color(red: 1, green: 0.22, blue: 0.15) : enabled ? Color(red: 0.35, green: 1, blue: 0.45) : Color(white: 0.22)
    let lit = busy ? (blink ? 1.0 : 0.25) : enabled ? 1.0 : 0
    return ZStack {
      // The collar, turned and knurled, standing on the plate.
      Circle().fill(AngularGradient(
        colors: [0.62, 0.34, 0.7, 0.3, 0.58, 0.36, 0.66, 0.32, 0.62].map { Color(white: $0) }, center: .center))
        .shadow(color: .black.opacity(0.55), radius: 5, y: 3)
      Canvas { ctx, size in
        let c = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width / 2
        for i in 0..<90 {
          let a = Double(i) / 90 * 2 * .pi
          var tick = Path()
          tick.move(to: CGPoint(x: c.x + cos(a) * (r - 5.5), y: c.y + sin(a) * (r - 5.5)))
          tick.addLine(to: CGPoint(x: c.x + cos(a) * (r - 0.8), y: c.y + sin(a) * (r - 0.8)))
          ctx.stroke(tick, with: .color(.black.opacity(0.4)), lineWidth: 1.1)
        }
      }
      Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
      // The well the button sits in: lit from above, so its upper rim is in shadow.
      Circle().fill(Color(white: 0.05)).frame(width: d * 0.66, height: d * 0.66)
        .overlay(Circle().strokeBorder(LinearGradient(colors: [.black.opacity(0.9), .white.opacity(0.22)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
      // The button, domed, in the app's amber.
      ZStack {
        Circle().fill(RadialGradient(
          colors: enabled
            ? [Color(red: 1, green: 0.86, blue: 0.58), Hardware.amber, Color(red: 0.5, green: 0.24, blue: 0.04)]
            : [Color(white: 0.55), Color(white: 0.32), Color(white: 0.16)],
          center: UnitPoint(x: 0.4, y: 0.3), startRadius: 1, endRadius: d * 0.3))
        Ellipse().fill(LinearGradient(colors: [.white.opacity(pressed ? 0.35 : 0.7), .clear], startPoint: .top, endPoint: .bottom))
          .frame(width: d * 0.3, height: d * 0.15).offset(y: -d * 0.12)
        // The cable release's threaded socket.
        Circle().fill(RadialGradient(colors: [Color(white: 0.05), Color(white: 0.28)], center: .center, startRadius: 0, endRadius: d * 0.07))
          .frame(width: d * 0.13, height: d * 0.13)
          .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.6))
        Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.8)
      }
      .frame(width: d * 0.54, height: d * 0.54)
      .shadow(color: .black.opacity(pressed ? 0.3 : 0.7), radius: pressed ? 0.8 : 2.5, y: pressed ? 0.4 : 2)
      .scaleEffect(pressed ? 0.95 : 1).offset(y: pressed ? 1.2 : 0)
      .brightness(pressed ? -0.08 : 0)
      // The lamp, on the collar's upper right.
      Circle().fill(lamp.opacity(0.25 + 0.75 * lit)).frame(width: 6, height: 6)
        .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 0.6))
        .shadow(color: lamp.opacity(0.9 * lit), radius: 4)
        .offset(x: d * 0.3, y: -d * 0.3)
      Circle().stroke(Color.white.opacity(0.9 * flash), lineWidth: 3)
        .frame(width: d + 6, height: d + 6).scaleEffect(1 + 0.3 * (1 - flash))
    }
    .frame(width: d, height: d)
    .contentShape(Circle())
    .animation(.spring(response: 0.16, dampingFraction: 0.6), value: pressed)
  }
}

/// A note floating up over the picture on glass for a moment: a picture filed, a group complete.
struct GlassToast: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(white: 0.95))
      .padding(.horizontal, 14).padding(.vertical, 7)
      .glassPane(radius: 16, darken: 0.35)
      .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
  }
}

extension CropLens {
  /// A whole small picture under a glass bubble, filling most of it: the library's loupe.
  static func loupe(_ picture: CGImage, diameter: CGFloat = 112, backing: CGFloat = 2) -> CGImage? {
    let pixels = Int(diameter * backing)
    let scale = 0.86 * CGFloat(pixels) / CGFloat(max(picture.width, picture.height, 1))
    return render(
      picture, center: CGPoint(x: CGFloat(picture.width) / 2, y: CGFloat(picture.height) / 2), scale: scale,
      crop: nil, dimOutside: 0, pixels: pixels)
  }
}
