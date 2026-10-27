import AppKit
import Metal

/// The contact view's light table: neutral opal glass over an LED panel, recessed in a brushed
/// aluminium frame, shaded per pixel by Metal and cached for the view's size. The shader is
/// compiled from source the first time it is needed, so building needs no Metal compiler. The
/// scan is drawn over the glass untouched.
final class LightTable {
  static let shared = LightTable()
  /// In points from the view's edge.
  static let frameInset: CGFloat = 4, frameRadius: CGFloat = 10
  static let glassInset: CGFloat = 14, glassRadius: CGFloat = 5
  static func glassRect(in bounds: CGRect) -> CGRect { bounds.insetBy(dx: glassInset, dy: glassInset) }

  private lazy var gpu: (queue: MTLCommandQueue, pipeline: MTLComputePipelineState)? = {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let library = try? device.makeLibrary(source: Self.source, options: nil),
      let function = library.makeFunction(name: "lightTable"),
      let pipeline = try? device.makeComputePipelineState(function: function)
    else { return nil }
    return (queue, pipeline)
  }()
  private var cached: (size: CGSize, scale: CGFloat, image: CGImage)?

  /// The table for a view of `size` points at `scale` pixels per point; nil without Metal.
  func image(size: CGSize, scale: CGFloat) -> CGImage? {
    if let cached, cached.size == size, cached.scale == scale { return cached.image }
    guard let image = render(size: size, scale: scale) else { return nil }
    cached = (size, scale, image)
    return image
  }

  private struct Parameters {
    var size: SIMD2<Float>
    var frameMin: SIMD2<Float>, frameMax: SIMD2<Float>
    var glassMin: SIMD2<Float>, glassMax: SIMD2<Float>
    var frameRadius: Float, glassRadius: Float, scale: Float
  }
  private func render(size: CGSize, scale: CGFloat) -> CGImage? {
    let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
    guard let gpu, w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    descriptor.usage = .shaderWrite
    guard let texture = gpu.queue.device.makeTexture(descriptor: descriptor),
      let commands = gpu.queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
    else { return nil }
    let s = Float(scale)
    func point(_ x: CGFloat, _ y: CGFloat) -> SIMD2<Float> { SIMD2(Float(x), Float(y)) * s }
    var p = Parameters(
      size: point(size.width, size.height),
      frameMin: point(Self.frameInset, Self.frameInset),
      frameMax: point(size.width - Self.frameInset, size.height - Self.frameInset),
      glassMin: point(Self.glassInset, Self.glassInset),
      glassMax: point(size.width - Self.glassInset, size.height - Self.glassInset),
      frameRadius: Float(Self.frameRadius) * s, glassRadius: Float(Self.glassRadius) * s, scale: s)
    encoder.setComputePipelineState(gpu.pipeline)
    encoder.setTexture(texture, index: 0)
    encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 0)
    encoder.dispatchThreads(
      MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
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

  /// Computed in linear light and written as premultiplied sRGB; the texture's first row is the
  /// top of the view, and the light comes from the upper left.
  private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Table {
      float2 size; float2 frameMin; float2 frameMax; float2 glassMin; float2 glassMax;
      float frameRadius; float glassRadius; float scale;
    };
    static float hash(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    static float noise(float2 p) {
      float2 i = floor(p), f = fract(p), u = f * f * (3 - 2 * f);
      return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
    }
    // Signed distance to a rounded rectangle: negative inside.
    static float box(float2 p, float2 lo, float2 hi, float r) {
      float2 q = abs(p - (lo + hi) * 0.5) - (hi - lo) * 0.5 + r;
      return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }
    static float2 outward(float2 p, float2 lo, float2 hi, float r) {
      float e = 0.5;
      return normalize(float2(box(p + float2(e, 0), lo, hi, r) - box(p - float2(e, 0), lo, hi, r),
                              box(p + float2(0, e), lo, hi, r) - box(p - float2(0, e), lo, hi, r)) + 1e-6);
    }
    static float encode(float v) {
      v = clamp(v, 0.0, 1.0);
      return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
    }
    kernel void lightTable(texture2d<float, access::write> out [[texture(0)]], constant Table& t [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
      float2 x = float2(gid) + 0.5, pt = x / t.scale;  // textures are sized in points
      float outer = box(x, t.frameMin, t.frameMax, t.frameRadius);
      float coverage = clamp(0.5 - outer, 0.0, 1.0);
      if (coverage <= 0) { out.write(float4(0), gid); return; }
      float d = box(x, t.glassMin, t.glassMax, t.glassRadius) / t.scale;  // points; negative on the glass
      float3 light;
      if (d < 0) {
        // Opal diffuser: neutral white, a little brighter at the centre, a fine grain, and the
        // frame's lip shading its edge.
        float2 uv = (x - (t.glassMin + t.glassMax) * 0.5) / ((t.glassMax - t.glassMin) * 0.5);
        float e = 0.92 * (1.0 - 0.06 * dot(uv, uv)) + (noise(pt * 0.8) - 0.5) * 0.012 + (hash(x) - 0.5) * 0.006;
        light = float3(e * (1.0 - 0.38 * exp(d / 4.0)));
      } else {
        // Each bar is brushed along its length; the bars meet in mitres at the corners.
        float sideways = max(t.glassMin.x - x.x, x.x - t.glassMax.x) / t.scale;
        float upright = max(t.glassMin.y - x.y, x.y - t.glassMax.y) / t.scale;
        bool side = sideways > upright;
        float along = side ? pt.y : pt.x, across = side ? pt.x : pt.y;
        float brush = noise(float2(along * 0.012, across * 1.7)) * 0.55 + noise(float2(along * 0.05, across * 5.0)) * 0.45;
        // A chamfer slopes down into the glass; the outer edge is rounded over.
        float3 n = float3(0, 0, 1);
        if (d < 8.0) {
          float slope = 0.9 * (1.0 - smoothstep(6.5, 8.0, d));
          n = normalize(float3(-outward(x, t.glassMin, t.glassMax, t.glassRadius) * slope, 1.0));
        }
        float edge = outer / t.scale;
        if (edge > -6.0) {
          n = normalize(float3(outward(x, t.frameMin, t.frameMax, t.frameRadius) * clamp((edge + 6.0) / 6.0, 0.0, 1.0) * 1.6, 1.0));
        }
        float3 L = normalize(float3(-0.3, -0.6, 0.75)), H = normalize(L + float3(0, 0, 1));
        float diffuse = max(dot(n, L), 0.0), specular = pow(max(dot(n, H), 0.0), 30.0);
        float a = 0.024 + 0.014 * brush;
        light = float3(a, a, a * 1.04) * (0.45 + 0.7 * diffuse) + (0.02 + 0.05 * brush) * specular;
        light += 0.12 * exp(-d / 2.5);  // glass light spilling over the lip
        if (sideways > 0 && upright > 0 && abs(sideways - upright) < 0.4 && d > 1.0) light *= 0.55;  // mitre seam
      }
      out.write(float4(encode(light.r), encode(light.g), encode(light.b), 1) * coverage, gid);
    }
    """
}
