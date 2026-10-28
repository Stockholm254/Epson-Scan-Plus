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

/// The shutter release: a round glass key with an amber button set in it that glows while the
/// camera is ready, sinks a little when pressed, and gives off a ring of light each time the
/// shutter goes.
struct ShutterKey: View {
  let enabled: Bool
  /// The camera's count of shots taken: each new one flashes the ring.
  let shots: Int
  let action: () -> Void
  @State private var flash = 0.0
  var body: some View {
    Button(action: action) {
      ZStack {
        Circle().fill(Hardware.amber.opacity(enabled ? 0.95 : 0.3)).frame(width: 28, height: 28)
          .shadow(color: Hardware.amber.opacity(enabled ? 0.65 : 0), radius: 6)
          .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center)).frame(width: 26, height: 26))
        Circle().stroke(Color.white.opacity(0.9 * flash), lineWidth: 3)
          .frame(width: 46, height: 46).scaleEffect(1 + 0.35 * (1 - flash))
      }
      .frame(width: 50, height: 50)
      .background {
        if Hardware.glass {
          SystemGlassBackground(capsule: true, radius: 25, tint: NSColor(white: 0, alpha: 0.18))
        } else {
          Circle().fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
        }
      }
      .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.8))
      .contentShape(Circle())
    }
    .buttonStyle(ShutterPress())
    .disabled(!enabled)
    .keyboardShortcut(.space, modifiers: [])
    .help("拍摄（空格）")
    .accessibilityLabel("拍摄")
    .onChange(of: shots) {
      flash = 1
      withAnimation(.easeOut(duration: 0.5)) { flash = 0 }
    }
  }
}

/// The shutter sinking under the finger.
struct ShutterPress: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1)
      .brightness(configuration.isPressed ? -0.06 : 0)
      .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
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
  /// The glass bubble over a live frame (or any picture): `picture` about `point` (normalised),
  /// `magnification` times as large as it is shown at `shownWidth` points across, with `box`
  /// (normalised) outlined, `diameter` points at `backing` pixels a point.
  static func magnifier(
    _ picture: CGImage, at point: CGPoint, box: CGRect?, shownWidth: CGFloat, magnification: CGFloat = 4,
    diameter: CGFloat = 148, backing: CGFloat = 2
  ) -> CGImage? {
    let w = CGFloat(picture.width), h = CGFloat(picture.height)
    let scale = magnification * shownWidth / max(1, w) * backing
    let outline = box.map { CGRect(x: $0.minX * w, y: $0.minY * h, width: $0.width * w, height: $0.height * h) }
    return render(
      picture, center: CGPoint(x: point.x * w, y: point.y * h), scale: scale, crop: outline, dimOutside: 0,
      pixels: Int(diameter * backing))
  }
  /// A whole small picture under a glass bubble, filling most of it: the library's loupe.
  static func loupe(_ picture: CGImage, diameter: CGFloat = 112, backing: CGFloat = 2) -> CGImage? {
    let pixels = Int(diameter * backing)
    let scale = 0.86 * CGFloat(pixels) / CGFloat(max(picture.width, picture.height, 1))
    return render(
      picture, center: CGPoint(x: CGFloat(picture.width) / 2, y: CGFloat(picture.height) / 2), scale: scale,
      crop: nil, dimOutside: 0, pixels: pixels)
  }
}
