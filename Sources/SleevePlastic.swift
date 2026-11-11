import AppKit
import Metal
import SwiftUI

/// The clear polyethylene of a negative sleeve's strip, shaded per pixel by Metal and cached for
/// the strip's size: the sheet's soft waves catching a softbox up to the left, a faint milky haze,
/// and the welded seams along the strip's top and bottom, a raised bright line with a shadow under
/// it. Drawn over the pockets' pictures; only light and the seams' shadows, nothing opaque.
final class SleevePlastic {
  static let shared = SleevePlastic()

  private lazy var gpu: (queue: MTLCommandQueue, pipeline: MTLComputePipelineState)? = {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let library = try? device.makeLibrary(source: Self.source, options: nil),
      let function = library.makeFunction(name: "sleevePlastic"),
      let pipeline = try? device.makeComputePipelineState(function: function)
    else { return nil }
    return (queue, pipeline)
  }()
  private struct Key: Hashable { var w: Int, h: Int, scale: Int, seed: Int }
  private var kept = [Key: CGImage]()
  private let lock = NSLock()

  /// The plastic over a strip of `size` points at `scale`; `seed` varies its waves from strip to
  /// strip. Nil without Metal.
  func image(size: CGSize, scale: CGFloat, seed: Int = 0) -> CGImage? {
    let key = Key(w: Int(size.width.rounded()), h: Int(size.height.rounded()), scale: Int((scale * 100).rounded()), seed: seed % 6)
    if let made = lock.withLock({ kept[key] }) { return made }
    guard let made = render(size: size, scale: scale, seed: Float(key.seed)) else { return nil }
    lock.withLock {
      if kept.count > 64 { kept.removeAll() }
      kept[key] = made
    }
    return made
  }

  private struct Parameters {
    var size: SIMD2<Float>
    var scale: Float
    var seed: Float
  }
  private func render(size: CGSize, scale: CGFloat, seed: Float) -> CGImage? {
    let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
    guard let gpu, w > 0, h > 0, w <= 8192, h <= 8192 else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    descriptor.usage = .shaderWrite
    guard let texture = gpu.queue.device.makeTexture(descriptor: descriptor),
      let commands = gpu.queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
    else { return nil }
    var p = Parameters(size: SIMD2(Float(size.width), Float(size.height)), scale: Float(scale), seed: seed)
    encoder.setComputePipelineState(gpu.pipeline)
    encoder.setTexture(texture, index: 0)
    encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 0)
    encoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    guard commands.status == .completed else { return nil }
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// In points; the first row is the strip's top, the light from the upper left. Written as
  /// premultiplied sRGB: white where the plastic shines, black where a seam shades.
  private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Strip { float2 size; float scale; float seed; };
    static float hash(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    static float noise(float2 p) {
      float2 i = floor(p), f = fract(p), u = f * f * (3 - 2 * f);
      return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
    }
    // The sheet's height: long soft waves along the strip, smaller ripples on them.
    static float sheet(float2 p, float seed) {
      float2 q = p + seed * 37.0;
      return noise(q * float2(0.018, 0.05)) * 1.0 + noise(q * float2(0.05, 0.11)) * 0.35 + noise(q * 0.2) * 0.06;
    }
    static float encode(float v) {
      v = clamp(v, 0.0, 1.0);
      return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
    }
    kernel void sleevePlastic(texture2d<float, access::write> out [[texture(0)]], constant Strip& s [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
      float2 p = (float2(gid) + 0.5) / s.scale;
      float e = 0.6;
      float hx = sheet(p + float2(e, 0), s.seed) - sheet(p - float2(e, 0), s.seed);
      float hy = sheet(p + float2(0, e), s.seed) - sheet(p - float2(0, e), s.seed);
      float3 n = normalize(float3(-hx * 2.2, -hy * 2.2, 1.0));
      // The softbox, up and to the left, seen in the sheet: a broad glow and a tighter glint.
      float3 L = normalize(float3(-0.45, -0.55, 0.7)), H = normalize(L + float3(0, 0, 1));
      float facing = max(dot(n, H), 0.0);
      float shine = 0.05 * pow(facing, 8.0) + 0.16 * pow(facing, 90.0);
      // Brighter towards the light's corner, as a sheet held under a lamp.
      float2 uv = p / s.size;
      shine *= 0.55 + 0.6 * (1.0 - uv.x) * (1.0 - 0.5 * uv.y);
      float haze = 0.035;
      // The welds along the top and bottom: a raised line, lit on its top, its shadow inside.
      float top = p.y, bottom = s.size.y - p.y;
      float edge = min(top, bottom);
      float weld = exp(-pow((edge - 1.0) / 0.55, 2.0)) * (top < bottom ? 0.32 : 0.18);
      float shade = exp(-pow((edge - 2.4) / 0.9, 2.0)) * 0.14;
      float light = clamp(haze + shine + weld, 0.0, 0.6);
      float alpha = clamp(light + shade, 0.0, 0.7);
      float white = alpha > 0 ? light / alpha : 0;
      float c = encode(white);
      out.write(float4(c * alpha, c * alpha, c * alpha, alpha), gid);
    }
    """
}

/// The plastic over a strip, sized to it.
struct SleevePlasticOverlay: View {
  var seed = 0
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    GeometryReader { g in
      if let image = SleevePlastic.shared.image(size: g.size, scale: displayScale, seed: seed) {
        Image(decorative: image, scale: displayScale).resizable()
      }
    }.allowsHitTesting(false)
  }
}

/// A sleeve page held up to the light: it tips a little towards the pointer as it moves over it,
/// and a reflection of the light runs across it the other way.
struct SleeveTilt: ViewModifier {
  /// The pointer over the page, from −1 to 1 across and down; nil when it is elsewhere.
  @State private var at: CGPoint?
  @State private var size = CGSize(width: 1, height: 1)
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  static let most: Double = 3.5
  func body(content: Content) -> some View {
    let p = at ?? .zero
    return content
      .overlay {
        if at != nil {
          // The softbox's reflection, sliding opposite the tilt.
          LinearGradient(
            stops: [
              .init(color: .clear, location: max(0, 0.30 - 0.25 * p.x)),
              .init(color: .white.opacity(0.09), location: max(0.01, 0.42 - 0.25 * p.x)),
              .init(color: .clear, location: max(0.02, 0.56 - 0.25 * p.x)),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
          )
          .blendMode(.plusLighter).allowsHitTesting(false).transition(.opacity)
        }
      }
      .rotation3DEffect(.degrees(reduceMotion ? 0 : -Self.most * Double(p.y)), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
      .rotation3DEffect(.degrees(reduceMotion ? 0 : Self.most * Double(p.x)), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
      .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case .active(let q):
          let next = CGPoint(x: max(-1, min(1, q.x / max(1, size.width) * 2 - 1)), y: max(-1, min(1, q.y / max(1, size.height) * 2 - 1)))
          if at == nil {
            withAnimation(.easeOut(duration: 0.2)) { at = next }
          } else {
            withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.85)) { at = next }
          }
        case .ended:
          withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { at = nil }
        }
      }
  }
}
