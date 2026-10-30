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
  @Environment(\.accessibilityReduceTransparency) private var opaque
  func body(content: Content) -> some View {
    let light = scheme == .light
    if opaque && !light {
      content.background(RoundedRectangle(cornerRadius: radius).fill(Color(white: 0.12)))
    } else if light {
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

/// The shutter release, as the system draws its leading action: a large round key of prominent
/// Liquid Glass in red (on earlier systems a prominent bordered one). While a picture is written and
/// sent it takes no press and shows the system's spinner; a ring goes off round it each time the
/// shutter goes.
struct ShutterKey: View {
  let enabled: Bool
  /// A picture still on its way: the key takes no press until it is in.
  var busy = false
  /// The camera's count of shots taken: each new one flashes the ring.
  let shots: Int
  let action: () -> Void
  @State private var flash = 0.0
  @Environment(\.accessibilityReduceMotion) private var still
  var body: some View {
    Button(action: action) {
      ZStack {
        Color.clear.frame(width: 40, height: 40)
        if busy { ProgressView().controlSize(.small) }
      }
    }
    .leadingAction(Color(red: 0.86, green: 0.16, blue: 0.13))
    .buttonBorderShape(.circle)
    .controlSize(.large)
    .overlay {
      Circle().stroke(Color.white.opacity(0.9 * flash), lineWidth: 3)
        .scaleEffect(still ? 1.05 : 1.05 + 0.3 * (1 - flash)).allowsHitTesting(false)
    }
    .disabled(!enabled)
    .keyboardShortcut(.space, modifiers: [])
    .help("拍摄（空格）")
    .accessibilityLabel("拍摄")
    .accessibilityValue(busy ? "照片传输中" : enabled ? "就绪" : "未连接")
    .onChange(of: shots) {
      flash = 1
      withAnimation(.easeOut(duration: 0.5)) { flash = 0 }
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

/// The ground of the copy stand: the live view as frost would show it, or plain grey until there is
/// one.
struct CopyStandBackdrop: View {
  @ObservedObject var camera: CameraController
  @Environment(\.accessibilityReduceTransparency) private var opaque
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    // Laid over a colour that takes the space offered, so filling it never makes the view larger.
    // In the dark appearance the same frost, taken down to dark grey.
    Color(white: scheme == .dark ? 0.13 : 0.88).overlay {
      if !opaque, let b = camera.liveBackdrop {
        Image(decorative: b, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
          .colorMultiply(Color(white: scheme == .dark ? 0.2 : 1))
      }
    }.clipped().allowsHitTesting(false)
  }
}

extension View {
  /// A pane on light glass: where the system has Liquid Glass, that glass alone, as the system draws
  /// it; before, frost: a veil of white with a fine grain, its rim lit from above, and a soft shadow
  /// as of a pane standing off what lies under it. With Reduce Transparency an opaque pane instead.
  func frost<S: InsettableShape>(_ shape: S, veil: Double, glassRadius: CGFloat, capsule: Bool = false) -> some View {
    modifier(FrostPane(shape: shape, veil: veil, glassRadius: glassRadius, capsule: capsule))
  }
}

private struct FrostPane<S: InsettableShape>: ViewModifier {
  let shape: S, veil: Double, glassRadius: CGFloat, capsule: Bool
  @Environment(\.accessibilityReduceTransparency) private var opaque
  @Environment(\.colorSchemeContrast) private var contrast
  func body(content: Content) -> some View {
    let strong = contrast == .increased
    if opaque {
      content.background(shape.fill(Color(white: 0.96)))
        .overlay(shape.strokeBorder(Color.black.opacity(strong ? 0.5 : 0.16), lineWidth: 1))
    } else if Hardware.glass {
      content.background(SystemGlassBackground(capsule: capsule, radius: glassRadius, tint: NSColor(white: 1, alpha: 0.25)))
        .overlay { if strong { shape.strokeBorder(Color.black.opacity(0.4), lineWidth: 1) } }
    } else {
      content
        .background {
          ZStack {
            shape.stroke(Color.black.opacity(0.12), lineWidth: 5).blur(radius: 7).offset(y: 4)
            shape.fill(Color.white.opacity(strong ? min(0.9, veil + 0.25) : veil))
          }
        }
        .overlay {
          if let grain = Frost.grain {
            Image(decorative: grain, scale: 2).resizable(resizingMode: .tile).opacity(0.05).blendMode(.multiply)
              .clipShape(shape).allowsHitTesting(false)
          }
        }
        .overlay(shape.strokeBorder(
          strong ? AnyShapeStyle(Color.black.opacity(0.45))
            : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.3), .black.opacity(0.07)], startPoint: .top, endPoint: .bottom)),
          lineWidth: 1))
    }
  }
}
