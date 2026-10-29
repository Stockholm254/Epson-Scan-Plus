import AppKit
import SwiftUI

extension View {
  /// A pane of glass behind a group of controls floating over a picture: the system's Liquid Glass
  /// on macOS 26, lensing what lies under it, a little darkened so light text reads (on the copy
  /// stand's light glass frosted instead); before, a translucent plate of the same shape.
  func glassPane(radius: CGFloat = 16, darken: CGFloat = 0.28) -> some View {
    modifier(GlassPane(radius: radius, darken: darken))
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

private struct GlassPane: ViewModifier {
  let radius: CGFloat, darken: CGFloat
  @Environment(\.colorScheme) private var scheme
  func body(content: Content) -> some View {
    let light = scheme == .light
    if light {
      // Liquid Glass where the system has it, under a thin frost; frost alone before.
      content.frost(RoundedRectangle(cornerRadius: radius), veil: Hardware.glass ? 0.18 : 0.62, glassRadius: radius)
    } else if Hardware.glass {
      content.background(SystemGlassBackground(capsule: false, radius: radius, tint: NSColor(white: 0, alpha: darken)))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    } else {
      content.background(RoundedRectangle(cornerRadius: radius).fill(Color(white: 0.1).opacity(0.88)))
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
    .modifier(ShutterGlass(radius: d / 2 + 6))
    .contentShape(Circle())
  }
}

/// The drop of glass the release sits in: with SwiftUI's glass one that gives under the finger,
/// and the notes of pictures filed rise out of it; clear on light glass, smoked on the console.
private struct ShutterGlass: ViewModifier {
  let radius: CGFloat
  @Environment(\.colorScheme) private var scheme
  func body(content: Content) -> some View {
    let light = scheme == .light
    content.liquid(Circle(), LiquidStyle(tint: light ? .white.opacity(0.2) : .black.opacity(0.18), interactive: true)) { key in
      key.background {
        if Hardware.glass {
          SystemGlassBackground(capsule: true, radius: radius, tint: light ? NSColor(white: 1, alpha: 0.25) : NSColor(white: 0, alpha: 0.18))
        } else {
          Circle().fill(LinearGradient(colors: light ? [Color(white: 0.97), Color(white: 0.84)] : [Color(white: 0.24), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
            .overlay(Circle().stroke(Color.black.opacity(light ? 0.12 : 0), lineWidth: 0.5))
        }
      }
    }
  }
}

/// A note floating up over the picture on glass for a moment: a picture filed, a group complete.
struct GlassToast: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Hardware.ink)
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

/// Frosted glass on the copy stand: what lies under the panes is the live view, blurred far past
/// recognition, mostly grey and lightened, so the frost shows the light and dark of the negative
/// on the stand without its orange mask colouring the window; the panes over it are a veil of white
/// with a fine grain and a lit rim.
enum Frost {
  /// `image` as the ground under the panes: a few dozen pixels across, each the mean of what it
  /// covers, smoothed again, kept to a fifth of its colour and lifted to light grey.
  static func backdrop(_ image: CGImage) -> CGImage? {
    let w = 32, h = max(2, Int((Double(w) * Double(image.height) / Double(max(1, image.width))).rounded()))
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = px.withUnsafeMutableBytes { raw -> Bool in
      guard let ctx = CGContext(
        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: ImagePipeline.shared.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      ctx.interpolationQuality = .high
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return nil }
    var v = px.map { Double($0) / 255 }
    for _ in 0..<2 {
      var next = v
      for y in 0..<h {
        for x in 0..<w {
          for c in 0..<3 {
            var sum = 0.0, n = 0.0
            for dy in -1...1 {
              for dx in -1...1 {
                let yy = min(h - 1, max(0, y + dy)), xx = min(w - 1, max(0, x + dx))
                sum += v[(yy * w + xx) * 4 + c]
                n += 1
              }
            }
            next[(y * w + x) * 4 + c] = sum / n
          }
        }
      }
      v = next
    }
    for i in stride(from: 0, to: v.count, by: 4) {
      let l = 0.2126 * v[i] + 0.7152 * v[i + 1] + 0.0722 * v[i + 2]
      for c in 0..<3 {
        let kept = l + 0.2 * (v[i + c] - l)
        px[i + c] = UInt8(max(0, min(255, (0.62 + 0.34 * kept) * 255)))
      }
      px[i + 3] = 255
    }
    guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
    return CGImage(
      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: ImagePipeline.shared.outputSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
      shouldInterpolate: true, intent: .defaultIntent)
  }
  /// The frost's grain: grey noise, the same every time, laid over a pane in tiles.
  static let grain: CGImage? = {
    let n = 96
    var state: UInt32 = 0x9E37_79B9
    var px = [UInt8](repeating: 0, count: n * n * 4)
    for i in 0..<(n * n) {
      state = state &* 1_664_525 &+ 1_013_904_223
      let g = UInt8(truncatingIfNeeded: state >> 24)
      px[i * 4] = g; px[i * 4 + 1] = g; px[i * 4 + 2] = g; px[i * 4 + 3] = 255
    }
    guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
    return CGImage(
      width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: ImagePipeline.shared.outputSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)
  }()
}

/// The ground of the copy stand in light glass: the live view as frost would show it, or light grey
/// until there is one.
struct CopyStandBackdrop: View {
  @ObservedObject var camera: CameraController
  var body: some View {
    // Laid over a colour that takes the space offered, so filling it never makes the view larger.
    Color(white: 0.88).overlay {
      if let b = camera.liveBackdrop {
        Image(decorative: b, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
      }
    }.clipped().allowsHitTesting(false)
  }
}

extension View {
  /// A pane of frost on light glass: Liquid Glass where the system has it (`glassRadius`), a veil of
  /// white over it, a fine grain over all, its rim lit from above, and a soft shadow round it as of
  /// a pane standing a little off what lies under it.
  func frost<S: InsettableShape>(_ shape: S, veil: Double, glassRadius: CGFloat, capsule: Bool = false) -> some View {
    background {
      ZStack {
        shape.stroke(Color.black.opacity(0.12), lineWidth: 5).blur(radius: 7).offset(y: 4)
        if Hardware.glass { SystemGlassBackground(capsule: capsule, radius: glassRadius, tint: NSColor(white: 1, alpha: 0.25)) }
        shape.fill(Color.white.opacity(veil))
      }
    }
    .overlay {
      if let grain = Frost.grain {
        Image(decorative: grain, scale: 2).resizable(resizingMode: .tile).opacity(0.05).blendMode(.multiply)
          .clipShape(shape).allowsHitTesting(false)
      }
    }
    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.3), .black.opacity(0.07)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
  }
}
