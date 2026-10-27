import AppKit
import Metal

/// The loupes that can lie on the light table. Raw values are stored in settings.
enum LoupeStyle: String, CaseIterable {
  case pentax, mamiya
  var title: String { self == .pentax ? "Pentax 式 5.5×" : "Mamiya 式 4×" }
  /// Relative to the light table as it is on screen.
  var magnification: Double { self == .pentax ? 5.5 : 4 }
  /// The base's real diameter, so the loupe lies to the film's scale.
  var baseMM: Double { self == .pentax ? 48 : 56 }
  /// The top's height above the base, in base radii; the shader's profiles.
  var height: Double { self == .pentax ? 1.15 : 0.92 }
  var index: Int32 { self == .pentax ? 0 : 1 }
}

/// Ray-marches a loupe standing on the light table: a clear acrylic skirt that lets the table's
/// light through, a black body (knurled focusing grip and rubber eyecup, or a cone with a
/// chrome trim), and a coated eye lens showing the film beneath, magnified. The room has a
/// softbox up to the left; the lit table below shows in the glossy surfaces and the skirt.
/// Compiled from source on first use, like the light table.
final class LoupeRenderer {
  static let shared = LoupeRenderer()

  /// What lies on the table, in canvas points: the canvas as drawn (without the loupe), the
  /// scan it shows, and the frame under the loupe at its own resolution.
  struct Scene {
    var table: CGImage?
    var canvas: CGSize
    var film: CGImage?
    var filmRect = CGRect.zero
    var detail: CGImage?
    var detailRect = CGRect.zero
  }
  /// Where the loupe stands and how it is seen, in canvas points.
  struct Pose {
    var style: LoupeStyle
    var center: CGPoint
    var radius: CGFloat
    var lift: CGFloat = 0
    /// The viewer, above the table; perspective shows the barrel's far side away from the middle.
    var eye: SIMD3<Float>
  }

  private lazy var gpu: (queue: MTLCommandQueue, pipeline: MTLComputePipelineState)? = {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let library = try? device.makeLibrary(source: Self.source, options: nil),
      let function = library.makeFunction(name: "loupe"),
      let pipeline = try? device.makeComputePipelineState(function: function)
    else { return nil }
    return (queue, pipeline)
  }()
  /// Uploaded images, kept while the same image is passed in.
  private var textures = [Int: (image: CGImage, texture: MTLTexture)]()
  private lazy var blank: MTLTexture? = gpu.flatMap { texture(for: nil, slot: -1, queue: $0.queue) }

  /// The loupe and its shadow over `frame` (canvas points) at `scale` pixels per point; nil without Metal.
  func render(frame: CGRect, scale: CGFloat, pose: Pose, scene: Scene, samples: Int = 4) -> CGImage? {
    let w = Int((frame.width * scale).rounded(.up)), h = Int((frame.height * scale).rounded(.up))
    guard let gpu, w > 0, h > 0, w <= 8192, h <= 8192 else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    descriptor.usage = .shaderWrite
    guard let output = gpu.queue.device.makeTexture(descriptor: descriptor),
      let table = texture(for: scene.table, slot: 0, queue: gpu.queue) ?? blank,
      let film = texture(for: scene.film, slot: 1, queue: gpu.queue) ?? blank,
      let detail = texture(for: scene.detail, slot: 2, queue: gpu.queue) ?? blank,
      let commands = gpu.queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
    else { return nil }
    func rect(_ r: CGRect, _ present: Bool) -> SIMD4<Float> {
      present ? SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)) : .zero
    }
    var p = Parameters(
      film: rect(scene.filmRect, scene.film != nil), detail: rect(scene.detailRect, scene.detail != nil),
      eye: SIMD4(pose.eye, 0),
      size: SIMD2(Float(w), Float(h)), origin: SIMD2(Float(frame.minX), Float(frame.minY)),
      canvas: SIMD2(Float(max(1, scene.canvas.width)), Float(max(1, scene.canvas.height))),
      center: SIMD2(Float(pose.center.x), Float(pose.center.y)),
      scale: Float(scale), radius: Float(pose.radius), lift: Float(pose.lift),
      magnification: Float(pose.style.magnification),
      // Lifted off the film, the loupe goes out of focus.
      blur: Float(min(3, pose.lift / pose.radius * 14)),
      style: pose.style.index, samples: Int32(samples == 1 ? 1 : 4), pad: 0)
    encoder.setComputePipelineState(gpu.pipeline)
    encoder.setTexture(output, index: 0)
    encoder.setTexture(table, index: 1)
    encoder.setTexture(film, index: 2)
    encoder.setTexture(detail, index: 3)
    encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 0)
    encoder.dispatchThreads(
      MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    guard commands.status == .completed else { return nil }
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    output.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// sRGB with mipmaps, so the shader reads linear light and can blur by level.
  private func texture(for image: CGImage?, slot: Int, queue: MTLCommandQueue) -> MTLTexture? {
    if let image, let kept = textures[slot], kept.image === image { return kept.texture }
    if slot >= 0 && image == nil { textures[slot] = nil; return nil }
    let w = min(8192, image?.width ?? 1), h = min(8192, image?.height ?? 1)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: true)
    descriptor.usage = .shaderRead
    guard let texture = queue.device.makeTexture(descriptor: descriptor) else { return nil }
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    if let image {
      guard
        let ctx = CGContext(
          data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      ctx.interpolationQuality = .high
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
    if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
      blit.generateMipmaps(for: texture)
      blit.endEncoding()
      commands.commit()
      commands.waitUntilCompleted()
    }
    if let image, slot >= 0 { textures[slot] = (image, texture) }
    return texture
  }

  private struct Parameters {
    var film: SIMD4<Float>, detail: SIMD4<Float>, eye: SIMD4<Float>
    var size: SIMD2<Float>, origin: SIMD2<Float>, canvas: SIMD2<Float>, center: SIMD2<Float>
    var scale: Float, radius: Float, lift: Float, magnification: Float, blur: Float
    var style: Int32, samples: Int32, pad: Int32
  }

  /// Canvas points, y down, z up towards the viewer. The loupe's shape is a profile turned
  /// about its axis, in units of the base radius. Light is computed linear and written as
  /// premultiplied sRGB.
  private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Loupe {
      float4 film; float4 detail; float4 eye;
      float2 size; float2 origin; float2 canvas; float2 center;
      float scale; float radius; float lift; float magnification; float blur;
      int style; int samples; int pad;
    };
    constexpr sampler smooth(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
    constant float3 kLight = float3(-0.28, -0.40, 0.87);

    static float box(float2 p, float2 lo, float2 hi, float r) {
      float2 q = abs(p - (lo + hi) * 0.5) - (hi - lo) * 0.5 + r;
      return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }
    static float polygon4(float2 p, float2 a, float2 b, float2 c, float2 d) {
      float2 v[4] = {a, b, c, d};
      float dist = dot(p - v[0], p - v[0]), s = 1.0;
      for (int i = 0, j = 3; i < 4; j = i, i++) {
        float2 e = v[j] - v[i], w = p - v[i];
        float2 q = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
        dist = min(dist, dot(q, q));
        bool3 k = bool3(p.y >= v[i].y, p.y < v[j].y, e.x * w.y > e.y * w.x);
        if (all(k) || all(!k)) s = -s;
      }
      return s * sqrt(dist);
    }
    // Materials: 1 clear acrylic skirt, 2 satin black body, 3 knurled grip, 4 rubber eyecup, 5 satin chrome.
    static float2 shape(float3 p, int style) {
      float2 q = float2(length(p.xy), p.z);
      float angle = atan2(p.y, p.x);
      float2 best = float2(1e5, 0.0);
      if (style == 0) {
        float skirt = polygon4(q, float2(0.90, 0.0), float2(1.0, 0.0), float2(0.93, 0.44), float2(0.85, 0.44)) - 0.008;
        float body = box(q, float2(0.30, 0.40), float2(0.875, 0.72), 0.02);
        float grip = box(q, float2(0.58, 0.72), float2(0.86, 1.02), 0.04);
        grip -= 0.0065 * smoothstep(0.80, 0.86, q.x) * smoothstep(0.75, 0.80, q.y) * (1.0 - smoothstep(0.96, 1.0, q.y))
          * (0.5 + 0.5 * cos(angle * 120.0));
        float cup = box(q, float2(0.60, 1.0), float2(0.77, 1.14), 0.06);
        if (skirt < best.x) best = float2(skirt, 1.0);
        if (body < best.x) best = float2(body, 2.0);
        if (grip < best.x) best = float2(grip, 3.0);
        if (cup < best.x) best = float2(cup, 4.0);
      } else {
        float skirt = polygon4(q, float2(0.93, 0.0), float2(1.0, 0.0), float2(0.95, 0.28), float2(0.88, 0.28)) - 0.006;
        float body = polygon4(q, float2(0.40, 0.26), float2(0.915, 0.26), float2(0.745, 0.86), float2(0.40, 0.86)) - 0.01;
        float trim = box(q, float2(0.67, 0.83), float2(0.765, 0.905), 0.02);
        if (skirt < best.x) best = float2(skirt, 1.0);
        if (body < best.x) best = float2(body, 2.0);
        if (trim < best.x) best = float2(trim, 5.0);
      }
      return best;
    }
    static float3 normalAt(float3 p, int style) {
      const float2 k = float2(1, -1);
      const float e = 0.0015;
      return normalize(k.xyy * shape(p + k.xyy * e, style).x + k.yyx * shape(p + k.yyx * e, style).x
        + k.yxy * shape(p + k.yxy * e, style).x + k.xxx * shape(p + k.xxx * e, style).x);
    }
    static float occlusion(float3 p, float3 n, int style) {
      float occ = 0.0, w = 1.0;
      for (int i = 1; i <= 4; i++) {
        float h = 0.025 * float(i);
        occ += (h - shape(p + n * h, style).x) * w;
        w *= 0.6;
      }
      return clamp(1.0 - 2.5 * occ, 0.25, 1.0);
    }
    static float3 tableAt(texture2d<float> table, constant Loupe& t, float2 p, float lod) {
      float2 uv = p / t.canvas;
      if (any(uv < 0.0) || any(uv > 1.0)) return float3(0.01);
      return table.sample(smooth, uv, level(lod)).rgb;
    }
    // What the lens magnifies: the frame at its own resolution, else the scan, else the table.
    static float3 filmAt(texture2d<float> table, texture2d<float> film, texture2d<float> detail,
                         constant Loupe& t, float2 p, float lod) {
      if (t.detail.z > 0) {
        float2 uv = (p - t.detail.xy) / t.detail.zw;
        if (all(uv >= 0.0) && all(uv <= 1.0)) return detail.sample(smooth, uv, level(lod)).rgb;
      }
      if (t.film.z > 0) {
        float2 uv = (p - t.film.xy) / t.film.zw;
        if (all(uv >= 0.0) && all(uv <= 1.0)) return film.sample(smooth, uv, level(lod)).rgb;
      }
      return tableAt(table, t, p, lod);
    }
    // The room: a dim ceiling, a large softbox up to the left and a smaller window to the right.
    static float panel(float3 d, float3 L, float2 extent, float rough) {
      float c = dot(d, L);
      if (c <= 0.0) return 0.0;
      float3 u = normalize(cross(L, float3(0, 0, 1))), v = cross(u, L);
      float2 x = abs(float2(dot(d, u), dot(d, v)) / c);
      float soft = 0.015 + rough * 0.9;
      float2 inside = 1.0 - smoothstep(extent - soft, extent + soft, x);
      return inside.x * inside.y;
    }
    static float3 room(float3 d, float rough) {
      float3 c = float3(0.03 + 0.05 * saturate(d.z));
      float energy = 1.0 / (1.0 + rough * 4.0);
      c += float3(1.0, 0.98, 0.94) * 3.2 * energy * panel(d, normalize(kLight), float2(0.30, 0.20), rough);
      c += float3(0.85, 0.9, 1.0) * 1.1 * energy * panel(d, normalize(float3(0.5, -0.1, 0.86)), float2(0.10, 0.22), rough);
      c += float3(0.3) * energy * panel(d, float3(0, 0, 1), float2(0.7, 0.7), rough);
      return c;
    }
    // Looking down, a reflection sees the lit table; looking up, the room.
    static float3 environment(texture2d<float> table, constant Loupe& t, float3 d, float3 from, float rough) {
      if (d.z < -0.02) {
        float3 x = from + d * (from.z / -d.z);
        return tableAt(table, t, x.xy, 1.0 + rough * 6.0) * 0.92;
      }
      return room(d, rough);
    }
    static float3 irradiance(float3 n, float3 glow) {
      float sky = 0.06 + 0.08 * saturate(n.z);
      float key = 0.8 * saturate(dot(n, normalize(kLight)));
      return float3(sky + key) + glow * (0.5 * saturate(-n.z) + 0.16 * (1.0 - abs(n.z)));
    }
    static float shadow(float2 P, constant Loupe& t, float top) {
      float R = t.radius;
      float d = (length(P - t.center) - R) / R;
      if (d < 0.0) return 0.0;
      float lifted = saturate(t.lift / (0.2 * R));
      float contact = (1.0 - smoothstep(0.0, 0.04 + 0.3 * lifted, d)) * mix(0.34, 0.07, lifted);
      float3 L = normalize(kLight);
      float2 k = -L.xy / L.z;
      float2 a = t.center + k * t.lift, b = t.center + k * (t.lift + top * R);
      float2 pa = P - a, ba = b - a;
      float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-3));
      float ds = length(pa - ba * h) - 0.8 * R;
      float pen = 0.06 * R + 0.25 * R * h + 0.3 * t.lift;
      float cast = (1.0 - smoothstep(-pen, pen, ds)) * 0.08;
      return max(contact, cast);
    }
    static float4 trace(float2 P, constant Loupe& t, texture2d<float> table, texture2d<float> film,
                        texture2d<float> detail, float3 glow) {
      float R = t.radius;
      float top = t.style == 0 ? 1.15 : 0.92;
      float lensZ = t.style == 0 ? 1.04 : 0.875, lensR = t.style == 0 ? 0.60 : 0.67;
      float skirtTop = t.style == 0 ? 0.44 : 0.28;
      float3 E = t.eye.xyz;
      float3 rd = normalize(float3(P, 0.0) - E);
      float3 base = float3(t.center, t.lift);
      float3 ro = (E - base) / R;
      float tStart = max(0.0, (ro.z - top) / -rd.z), tEnd = ro.z / -rd.z;
      float2 a = ro.xy + rd.xy * tStart, b = ro.xy + rd.xy * tEnd, ab = b - a;
      float closest = length(a + ab * saturate(dot(-a, ab) / max(dot(ab, ab), 1e-6)));
      if (closest > 1.02) return float4(0, 0, 0, shadow(P, t, top));
      float tLens = (ro.z - lensZ) / -rd.z;
      bool lens = length((ro + rd * tLens).xy) < lensR;
      float tMax = lens ? tLens : tEnd;
      float tt = tStart;
      float2 res = float2(1, 0);
      bool hit = false;
      for (int i = 0; i < 128 && tt < tMax; i++) {
        res = shape(ro + rd * tt, t.style);
        if (res.x < 0.0005) { hit = true; break; }
        tt += res.x * 0.8;
      }
      float3 V = -rd;
      if (hit) {
        float3 p = ro + rd * tt, n = normalAt(p, t.style), world = base + p * R;
        float nv = saturate(dot(n, V));
        if (res.y < 1.5) {
          // Clear acrylic: the table seen through the wall, light piped up to its top edge.
          float F = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
          float3 T = refract(rd, n, 1.0 / 1.49);
          if (length(T) < 0.5) T = rd;
          float3 x = world + T * (world.z / max(-T.z, 0.15));
          float3 seen = tableAt(table, t, x.xy, 0.8) * float3(0.93, 0.97, 0.96);
          float edge = smoothstep(skirtTop - 0.06, skirtTop, p.z) + 0.6 * (1.0 - smoothstep(0.0, 0.05, p.z));
          float3 piped = glow * (0.05 + 0.75 * edge) * float3(0.9, 1.0, 0.97);
          return float4(seen * (1.0 - F) * 0.95 + piped + environment(table, t, reflect(rd, n), world, 0.03) * F, 1);
        }
        float3 albedo = float3(0.022), f0 = float3(0.045);
        float rough = 0.3;
        if (res.y > 2.5 && res.y < 3.5) { albedo = float3(0.018); f0 = float3(0.04); rough = 0.42; }
        else if (res.y > 3.5 && res.y < 4.5) { albedo = float3(0.015); f0 = float3(0.04); rough = 0.5; }
        else if (res.y > 4.5) { albedo = float3(0.0); f0 = float3(0.62, 0.62, 0.64); rough = 0.24; }
        // A white focusing index on the body's front.
        float facing = atan2(p.y, p.x) - M_PI_F / 2.0;
        if (res.y > 1.5 && res.y < 2.5 && abs(facing) < 0.035 && p.z > (t.style == 0 ? 0.53 : 0.5) && p.z < (t.style == 0 ? 0.6 : 0.56)) {
          albedo = float3(0.7); rough = 0.5;
        }
        float3 F = f0 + (1.0 - f0) * pow(1.0 - nv, 5.0) * (1.0 - 0.7 * rough);
        float3 spec = environment(table, t, reflect(rd, n), world, rough) * F;
        return float4((albedo * irradiance(n, glow) + spec) * occlusion(p, n, t.style), 1);
      }
      if (lens) {
        float3 p = ro + rd * tLens, world = base + p * R;
        float rho = length(p.xy) / lensR;
        // The film under the axis, magnified, with a little distortion and lateral colour at the rim.
        float2 offset = p.xy * R * (1.0 - 0.035 * rho * rho) / t.magnification;
        float lod = t.blur + 0.5 * smoothstep(0.7, 1.0, rho);
        float spread = 1.0 + 0.008 * rho * rho;
        float3 c = float3(filmAt(table, film, detail, t, t.center + offset * spread, lod).r,
                          filmAt(table, film, detail, t, t.center + offset, lod).g,
                          filmAt(table, film, detail, t, t.center + offset / spread, lod).b);
        c *= 0.95 * (1.0 - 0.25 * smoothstep(0.55, 1.0, rho));
        c = mix(c, float3(0.004), smoothstep(0.93, 1.0, rho));
        // A domed, coated eye lens.
        float3 n = normalize(float3(p.xy / lensR * 0.32, 1.0));
        float F = 0.012 + 0.988 * pow(1.0 - saturate(dot(n, V)), 5.0);
        // Multicoating: violet face-on, turning green towards the rim.
        float3 coat = mix(float3(0.75, 0.45, 1.0), float3(0.5, 1.0, 0.6), smoothstep(0.4, 1.0, rho));
        float3 reflection = environment(table, t, reflect(rd, n), world, 0.01) * F * coat * 1.5;
        return float4(c * (1.0 - F) + reflection, 1);
      }
      return float4(0, 0, 0, shadow(P, t, top));
    }
    static float encode(float v) {
      v = clamp(v, 0.0, 1.0);
      return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
    }
    kernel void loupe(texture2d<float, access::write> out [[texture(0)]], texture2d<float> table [[texture(1)]],
                      texture2d<float> film [[texture(2)]], texture2d<float> detail [[texture(3)]],
                      constant Loupe& t [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
      // The table's light around the loupe, which its skirt gathers and its body reflects.
      float3 glow = tableAt(table, t, t.center, 6.0);
      const float2 grid[4] = {float2(0.375, 0.125), float2(0.875, 0.375), float2(0.125, 0.625), float2(0.625, 0.875)};
      float4 sum = float4(0);
      for (int s = 0; s < t.samples; s++) {
        float2 jitter = t.samples == 1 ? float2(0.5) : grid[s];
        float4 c = trace(t.origin + (float2(gid) + jitter) / t.scale, t, table, film, detail, glow);
        sum += float4(c.rgb * c.a, c.a);
      }
      sum /= float(t.samples);
      float3 c = sum.a > 0.0 ? sum.rgb / sum.a : float3(0);
      out.write(float4(encode(c.r), encode(c.g), encode(c.b), 1) * sum.a, gid);
    }
    """
}

/// The loupe lying beside the film on the light table. Drag it anywhere on the table; it shows
/// the film beneath it magnified, from the frame's own pixels. Double-click puts it back by the
/// edge; the right-click menu picks the loupe. The canvas below never redraws for it.
final class LoupeView: NSView {
  weak var canvas: FilmCanvasView?
  var style = LoupeStyle.pentax {
    didSet { if style != oldValue { layoutOnTable() } }
  }
  /// The base's centre, in canvas points; parked by the table's edge until moved.
  private(set) var center: CGPoint?
  private(set) var lift: CGFloat = 0
  private var grab: CGPoint?
  private var image: CGImage?
  private var liftTimer: Timer?
  private var renderPending = false
  /// While the canvas takes its own picture for the loupe to look through.
  var drawingSuppressed = false
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }
  override var acceptsFirstResponder: Bool { false }

  var radius: CGFloat { canvas?.loupeRadius(for: style) ?? 70 }
  /// The viewer sits in front of the table, looking down: the loupe shows its front, more so
  /// the further back it lies.
  private var eye: SIMD3<Float> {
    let b = canvas?.bounds ?? bounds
    return SIMD3(Float(b.midX), Float(b.maxY), Float(max(b.width, b.height) * 2.0))
  }
  var parkedCenter: CGPoint {
    guard let canvas else { return .zero }
    let glass = LightTable.glassRect(in: canvas.bounds), r = radius
    return CGPoint(x: glass.maxX - r - 20, y: glass.maxY - r - 20)
  }

  /// Keeps the loupe on the glass and its view around it, then shows it again.
  func layoutOnTable() {
    place()
    setNeedsRender()
  }
  private func place() {
    // Until the canvas has a size there is no glass to lie on.
    guard let canvas, canvas.bounds.width > LightTable.glassInset * 4, canvas.bounds.height > LightTable.glassInset * 4
    else { return }
    let glass = LightTable.glassRect(in: canvas.bounds), r = radius
    // Where it was put, kept as a fraction of the canvas; parked, it stays in its corner.
    var c = canvas.storedLoupeCenter ?? parkedCenter
    c.x = min(max(c.x, glass.minX + r * 0.4), max(glass.minX + r * 0.4, glass.maxX - r * 0.4))
    c.y = min(max(c.y, glass.minY + r * 0.4), max(glass.minY + r * 0.4, glass.maxY - r * 0.4))
    center = c
    // Room for the shadow and for the top leaning out under perspective.
    let half = r * 2.1
    frame = CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2).integral
  }
  /// The table or the film under the loupe changed.
  func setNeedsRender() {
    guard !renderPending else { return }
    renderPending = true
    DispatchQueue.main.async { [weak self] in
      self?.renderPending = false
      self?.renderNow()
    }
  }
  func renderNow() {
    guard let canvas, let center, !isHidden, bounds.width > 0 else { return }
    let pose = LoupeRenderer.Pose(style: style, center: center, radius: radius, lift: lift, eye: eye)
    image = LoupeRenderer.shared.render(
      frame: frame, scale: window?.backingScaleFactor ?? 2, pose: pose, scene: canvas.loupeScene())
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    guard !drawingSuppressed, let image else { return }
    NSImage(cgImage: image, size: bounds.size).draw(
      in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.none])
  }

  /// Only the loupe itself takes the mouse, not its shadow or the corners of its square.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, let center, let superview else { return nil }
    let p = superview.convert(point, to: canvas)
    let r = radius
    let e = eye, h = CGFloat(style.height) * r + lift
    let scale = CGFloat(e.z) / (CGFloat(e.z) - h)
    let top = CGPoint(x: CGFloat(e.x) + (center.x - CGFloat(e.x)) * scale, y: CGFloat(e.y) + (center.y - CGFloat(e.y)) * scale)
    return hypot(p.x - center.x, p.y - center.y) < r || hypot(p.x - top.x, p.y - top.y) < r * 0.85 ? self : nil
  }
  override func resetCursorRects() {
    guard let center else { return }
    let r = radius
    addCursorRect(convert(CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), from: canvas), cursor: .openHand)
  }
  override func mouseDown(with event: NSEvent) {
    guard let canvas, let center else { return }
    if event.clickCount == 2 { return park() }
    let p = canvas.convert(event.locationInWindow, from: nil)
    grab = CGPoint(x: p.x - center.x, y: p.y - center.y)
    NSCursor.closedHand.push()
    animateLift(to: radius * 0.1)
  }
  override func mouseDragged(with event: NSEvent) {
    guard let canvas, let grab else { return }
    let p = canvas.convert(event.locationInWindow, from: nil)
    move(to: CGPoint(x: p.x - grab.x, y: p.y - grab.y))
  }
  override func mouseUp(with event: NSEvent) {
    guard grab != nil else { return }
    grab = nil
    NSCursor.pop()
    animateLift(to: 0)
  }
  func move(to point: CGPoint) {
    canvas?.storedLoupeCenter = point
    moved()
  }
  /// Back by the table's edge, where it stays when the window changes size.
  @objc func park() {
    canvas?.storedLoupeCenter = nil
    moved()
  }
  private func moved() {
    place()
    renderNow()
    canvas?.loupeMoved()
    window?.invalidateCursorRects(for: self)
  }
  private func animateLift(to target: CGFloat) {
    liftTimer?.invalidate()
    let start = lift, began = Date()
    liftTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      let k = min(1, Date().timeIntervalSince(began) / 0.14)
      self.lift = start + (target - start) * CGFloat(1 - pow(1 - k, 3))
      self.renderNow()
      if k >= 1 { timer.invalidate() }
    }
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    for s in LoupeStyle.allCases {
      let item = NSMenuItem(title: s.title, action: #selector(choose(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = s.rawValue
      item.state = s == style ? .on : .off
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let back = NSMenuItem(title: "放回灯箱边", action: #selector(park), keyEquivalent: "")
    back.target = self
    menu.addItem(back)
    let hide = NSMenuItem(title: "收起看片镜", action: #selector(putAway), keyEquivalent: "")
    hide.target = self
    menu.addItem(hide)
    return menu
  }
  @objc private func choose(_ item: NSMenuItem) {
    guard let raw = item.representedObject as? String, let s = LoupeStyle(rawValue: raw) else { return }
    canvas?.model?.preferences.loupeStyle = s
  }
  @objc private func putAway() { canvas?.model?.preferences.showLoupe = false }
}
