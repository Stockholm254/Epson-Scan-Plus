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

/// The shutter release, as a camera's is: a glossy red button, a little domed, in a black collar
/// with a bright chamfer, sinking under the finger, the whole key in a drop of glass that gives
/// as it is pressed. A ring of light about the button shows amber while the camera is ready and
/// blinks red while a picture is written and sent; a ring goes off round it each time the shutter
/// goes.
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

/// The release drawn, the button sunk while pressed.
struct ShutterPress: ButtonStyle {
  let enabled: Bool, busy: Bool, flash: Double, blink: Bool
  static let size: CGFloat = 66
  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed && enabled
    let d = Self.size
    let ring = busy ? Color(red: 1, green: 0.25, blue: 0.2) : Hardware.amber
    let lit = busy ? (blink ? 1.0 : 0.2) : enabled ? 0.9 : 0
    return ZStack {
      Circle().fill(Color(white: 0.06))
        .overlay(Circle().strokeBorder(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.25)], startPoint: .top, endPoint: .bottom), lineWidth: 1.4))
        .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
      Circle().strokeBorder(ring.opacity(lit), lineWidth: 1.6)
        .frame(width: d * 0.86, height: d * 0.86)
        .shadow(color: ring.opacity(0.8 * lit), radius: 4)
      Circle().fill(RadialGradient(
        colors: enabled
          ? [Color(red: 1, green: 0.45, blue: 0.38), Color(red: 0.86, green: 0.12, blue: 0.1), Color(red: 0.45, green: 0.03, blue: 0.03)]
          : [Color(red: 0.5, green: 0.32, blue: 0.3), Color(red: 0.34, green: 0.16, blue: 0.15), Color(red: 0.18, green: 0.07, blue: 0.07)],
        center: UnitPoint(x: 0.45, y: 0.3), startRadius: 0, endRadius: d * 0.38))
        .overlay(Ellipse().fill(LinearGradient(colors: [.white.opacity(pressed ? 0.25 : 0.55), .clear], startPoint: .top, endPoint: .bottom))
          .frame(width: d * 0.36, height: d * 0.15).offset(y: -d * 0.17))
        .frame(width: d * 0.74, height: d * 0.74)
        .shadow(color: .black.opacity(pressed ? 0.3 : 0.6), radius: pressed ? 1 : 2.5, y: pressed ? 0.5 : 2)
        .scaleEffect(pressed ? 0.95 : 1).offset(y: pressed ? 1 : 0)
      Circle().stroke(Color.white.opacity(0.9 * flash), lineWidth: 3)
        .frame(width: d + 8, height: d + 8).scaleEffect(1 + 0.3 * (1 - flash))
    }
    .frame(width: d, height: d)
    .animation(.spring(response: 0.16, dampingFraction: 0.6), value: pressed)
    .padding(6)
    // With SwiftUI's glass a drop that gives under the finger, and the notes of pictures filed
    // rise out of it.
    .liquid(Circle(), LiquidStyle(tint: .black.opacity(0.18), interactive: true)) { key in
      key.background {
        if Hardware.glass {
          SystemGlassBackground(capsule: true, radius: d / 2 + 6, tint: NSColor(white: 0, alpha: 0.18))
        } else {
          Circle().fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
        }
      }
    }
    .contentShape(Circle())
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
