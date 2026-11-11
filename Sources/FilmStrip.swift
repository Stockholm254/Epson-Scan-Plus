import AppKit
import Metal
import SwiftUI

/// The film the strip of frames is drawn on, shaded per pixel by Metal and tiled along it: the
/// base in the film's colour, a little cupped across its width so a soft band of the room's light
/// runs along it, its cut edges catching the light; for 135 the perforations punched through it,
/// open to what lies behind, each with the film's thickness lit on its far side. 120 has none.
final class FilmStripMaterial {
  static let shared = FilmStripMaterial()
  /// The perforations' pitch and size along the strip, in points; one tile holds a whole number.
  static let pitch: CGFloat = 12, hole = CGSize(width: 6, height: 4.5), inset: CGFloat = 3
  static let tileWidth: CGFloat = 12 * 40

  private lazy var gpu: (queue: MTLCommandQueue, pipeline: MTLComputePipelineState)? = {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let library = try? device.makeLibrary(source: Self.source, options: nil),
      let function = library.makeFunction(name: "filmStrip"),
      let pipeline = try? device.makeComputePipelineState(function: function)
    else { return nil }
    return (queue, pipeline)
  }()
  struct Look: Hashable {
    /// The base's colour, linear.
    var base: SIMD3<Float>
    var perforated: Bool
  }
  private struct Key: Hashable { var look: Look; var h: Int; var scale: Int }
  private var kept = [Key: CGImage]()

  /// A tile of the strip `height` points tall, `tileWidth` long, at `scale`.
  func tile(height: CGFloat, scale: CGFloat, look: Look) -> CGImage? {
    let key = Key(look: look, h: Int(height.rounded()), scale: Int((scale * 100).rounded()))
    if let made = kept[key] { return made }
    guard let made = render(height: CGFloat(key.h), scale: scale, look: look) else { return nil }
    if kept.count > 16 { kept.removeAll() }
    kept[key] = made
    return made
  }

  private struct Parameters {
    var size: SIMD2<Float>
    var base: SIMD3<Float>
    var scale: Float
    var pitch: Float, holeW: Float, holeH: Float, inset: Float
    var perforated: Float
  }
  private func render(height: CGFloat, scale: CGFloat, look: Look) -> CGImage? {
    let w = Int((Self.tileWidth * scale).rounded()), h = Int((height * scale).rounded())
    guard let gpu, w > 0, h > 0, h <= 4096 else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    descriptor.usage = .shaderWrite
    guard let texture = gpu.queue.device.makeTexture(descriptor: descriptor),
      let commands = gpu.queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
    else { return nil }
    var p = Parameters(
      size: SIMD2(Float(Self.tileWidth), Float(height)), base: look.base, scale: Float(scale),
      pitch: Float(Self.pitch), holeW: Float(Self.hole.width), holeH: Float(Self.hole.height), inset: Float(Self.inset),
      perforated: look.perforated ? 1 : 0)
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

  /// In points, the first row the strip's top; light from above and a little to the left.
  /// Premultiplied sRGB; the perforations clear.
  private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Strip { float2 size; float3 base; float scale; float pitch; float holeW; float holeH; float inset; float perforated; };
    static float hash(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    static float box(float2 p, float2 lo, float2 hi, float r) {
      float2 q = abs(p - (lo + hi) * 0.5) - (hi - lo) * 0.5 + r;
      return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }
    static float encode(float v) {
      v = clamp(v, 0.0, 1.0);
      return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
    }
    kernel void filmStrip(texture2d<float, access::write> out [[texture(0)]], constant Strip& s [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
      float2 p = (float2(gid) + 0.5) / s.scale;
      // The nearest perforation in its row, top or bottom.
      float d = 1e3;
      float2 lo = 0, hi = 0;
      if (s.perforated > 0.5) {
        float k = floor(p.x / s.pitch);
        float x0 = k * s.pitch + s.inset;
        bool top = p.y < s.size.y * 0.5;
        float y0 = top ? s.inset : s.size.y - s.inset - s.holeH;
        lo = float2(x0, y0); hi = float2(x0 + s.holeW, y0 + s.holeH);
        d = box(p, lo, hi, 1.2);
      }
      float coverage = clamp(d * s.scale + 0.5, 0.0, 1.0);
      if (coverage <= 0) { out.write(float4(0), gid); return; }
      // Cupped across its width: the normal tips up towards the top edge, down towards the bottom.
      float v = p.y / s.size.y;
      float3 n = normalize(float3(0, (v - 0.5) * 0.55, 1));
      float3 L = normalize(float3(-0.25, -0.75, 0.62)), H = normalize(L + float3(0, 0, 1));
      float diffuse = 0.82 + 0.3 * max(dot(n, L), 0.0);
      // The room's light seen in the gloss: only a band along the strip, where its curve faces it.
      float gloss = 0.045 * pow(max(dot(n, H), 0.0), 60.0);
      float3 c = s.base * diffuse * (1.0 + (hash(p * 3.1) - 0.5) * 0.03) + gloss;
      // The cut edges: the top catches the light, the bottom is in its own shade.
      float top = p.y, bottom = s.size.y - p.y;
      c += 0.05 * exp(-top / 0.45);
      c *= 1.0 - 0.35 * exp(-bottom / 0.7);
      // Round a perforation, the film's thickness: lit on the hole's lower wall, shaded on its upper.
      if (d < 1.4) {
        float rim = 1.0 - smoothstep(0.0, 1.4, d);
        float below = clamp((p.y - (lo.y + hi.y) * 0.5) / max(0.1, (hi.y - lo.y) * 0.5), -1.0, 1.0);
        c += rim * max(below, 0.0) * 0.06;
        c *= 1.0 - rim * max(-below, 0.0) * 0.35;
      }
      out.write(float4(encode(c.r), encode(c.g), encode(c.b), 1) * coverage, gid);
    }
    """
}

extension FilmStripMaterial.Look {
  /// The film's base as it looks on the strip: a colour negative's orange mask, black and white's
  /// grey, a slide's black.
  static let colour = Self(base: SIMD3(0.052, 0.016, 0.0051), perforated: true)
  static func of(kind: FilmStock.Kind?, mono: Bool, reversal: Bool, perforated: Bool) -> Self {
    var look = colour
    if reversal || kind == .slide {
      look.base = SIMD3(0.009, 0.008, 0.008)
    } else if mono || kind == .blackWhite {
      look.base = SIMD3(0.017, 0.018, 0.021)
    }
    look.perforated = perforated
    return look
  }
}

extension AppModel {
  /// The open roll's film as the strip of frames shows it: its kind's base, perforated unless 120.
  var stripLook: FilmStripMaterial.Look {
    let look = NewProjectSheet.look(NewProjectSheet.current(self), m: self)
    return .of(kind: look.kind, mono: look.mono, reversal: reversalRoll, perforated: !format.rawValue.hasPrefix("120"))
  }
}
