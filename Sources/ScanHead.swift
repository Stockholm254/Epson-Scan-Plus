import AppKit
import Metal

/// Images handed to the GPU as sRGB textures with mipmaps, kept while the same image is passed in;
/// and a rendered texture back as an image. Shared by the loupe and the scan head.
final class TextureCache {
  private var kept = [Int: (image: CGImage, texture: MTLTexture)]()
  /// `slot` -1 makes a blank white texture and keeps nothing.
  func texture(for image: CGImage?, slot: Int, queue: MTLCommandQueue) -> MTLTexture? {
    if let image, let k = kept[slot], k.image === image { return k.texture }
    if slot >= 0 && image == nil { kept[slot] = nil; return nil }
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
    if let image, slot >= 0 { kept[slot] = (image, texture) }
    return texture
  }
  /// A finished premultiplied sRGB output texture as an image.
  static func image(_ output: MTLTexture) -> CGImage? {
    let w = output.width, h = output.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    output.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}

/// Ray-marches the scanner's head passing over the frame being scanned: a satin black carriage
/// with a brushed aluminium top, riding a little above the film, its lamp showing as a bright
/// line along both sides and lighting the band of film beneath it. It stands in the loupe's room,
/// so the two look alike, and casts its shadow down to the right as the loupe does.
final class ScanHeadRenderer {
  static let shared = ScanHeadRenderer()

  /// The head over the table, in canvas points: from `a` along `axis` for `length`, moving
  /// along `travel`; `width` across, `height` tall, `gap` above the film.
  struct Pose: Equatable {
    var a: CGPoint
    var axis: CGVector
    var travel: CGVector
    var length: CGFloat
    var width: CGFloat
    var height: CGFloat
    var gap: CGFloat
    var lamp: CGFloat = 1
    var eye: SIMD3<Float>
    func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
      CGPoint(x: a.x + axis.dx * u + travel.dx * v, y: a.y + axis.dy * u + travel.dy * v)
    }
    /// Where the scanner reads: the middle of the line under the lamp.
    var line: (CGPoint, CGPoint) { (point(0, 0), point(length, 0)) }
    /// The head, its shadow and the light it spills, with room for leaning under perspective.
    var bounds: CGRect {
      let m = width * 2.8 + gap + 6
      let corners = [point(-m, -m), point(length + m, -m), point(-m, m), point(length + m, m)]
      let xs = corners.map(\.x), ys = corners.map(\.y)
      return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
  }

  private lazy var gpu: (queue: MTLCommandQueue, pipeline: MTLComputePipelineState)? = {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let library = try? device.makeLibrary(source: Self.source, options: nil),
      let function = library.makeFunction(name: "scanHead"),
      let pipeline = try? device.makeComputePipelineState(function: function)
    else { return nil }
    return (queue, pipeline)
  }()
  private let textures = TextureCache()

  /// The head, its light and shadow over `frame` (canvas points) on `table`, the canvas as drawn;
  /// nil without Metal.
  func render(frame: CGRect, scale: CGFloat, pose: Pose, table: CGImage?, canvas: CGSize, samples: Int = 4) -> CGImage? {
    let w = Int((frame.width * scale).rounded(.up)), h = Int((frame.height * scale).rounded(.up))
    guard let gpu, w > 0, h > 0, w <= 8192, h <= 8192 else { return nil }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    descriptor.usage = .shaderWrite
    guard let output = gpu.queue.device.makeTexture(descriptor: descriptor),
      let tableTexture = textures.texture(for: table, slot: 0, queue: gpu.queue) ?? textures.texture(for: nil, slot: -1, queue: gpu.queue),
      let commands = gpu.queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
    else { return nil }
    var p = Parameters(
      eye: SIMD4(pose.eye, 0), size: SIMD2(Float(w), Float(h)), origin: SIMD2(Float(frame.minX), Float(frame.minY)),
      canvas: SIMD2(Float(max(1, canvas.width)), Float(max(1, canvas.height))),
      a: SIMD2(Float(pose.a.x), Float(pose.a.y)), axis: SIMD2(Float(pose.axis.dx), Float(pose.axis.dy)),
      travel: SIMD2(Float(pose.travel.dx), Float(pose.travel.dy)),
      length: Float(pose.length), width: Float(pose.width), height: Float(pose.height), gap: Float(pose.gap),
      scale: Float(scale), lamp: Float(pose.lamp), samples: Int32(samples == 1 ? 1 : 4), pad: 0)
    encoder.setComputePipelineState(gpu.pipeline)
    encoder.setTexture(output, index: 0)
    encoder.setTexture(tableTexture, index: 1)
    encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 0)
    encoder.dispatchThreads(
      MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    guard commands.status == .completed else { return nil }
    return TextureCache.image(output)
  }

  private struct Parameters {
    var eye: SIMD4<Float>
    var size: SIMD2<Float>, origin: SIMD2<Float>, canvas: SIMD2<Float>, a: SIMD2<Float>, axis: SIMD2<Float>, travel: SIMD2<Float>
    var length: Float, width: Float, height: Float, gap: Float, scale: Float, lamp: Float
    var samples: Int32, pad: Int32
  }

  /// In the head's own frame: u along it from `a`, v the way it moves, z up from the film.
  private static let source = LoupeRenderer.lighting + """
    struct Head {
      float4 eye;
      float2 size; float2 origin; float2 canvas; float2 a; float2 axis; float2 travel;
      float length; float width; float height; float gap; float scale; float lamp;
      int samples; int pad;
    };
    constexpr sampler smooth(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);

    static float roundBox(float3 p, float3 b, float r) {
      float3 q = abs(p) - b + r;
      return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
    }
    // Materials: 1 satin black body, 2 brushed aluminium top, 3 the lamp.
    static float2 shape(float3 q, constant Head& h) {
      float L = h.length, W = h.width, H = h.height, g = h.gap;
      float r = min(W, H) * 0.24;
      float body = roundBox(q - float3(L * 0.5, 0.0, g + H * 0.5), float3(L * 0.5, W * 0.5, H * 0.5), r);
      float plate = roundBox(q - float3(L * 0.5, 0.0, g + H), float3(L * 0.5 - r * 1.6, W * 0.5 - r * 1.2, H * 0.07), H * 0.05);
      // Along the bottom, a little wider than the body, so it shows down both sides.
      float lamp = roundBox(q - float3(L * 0.5, 0.0, g + H * 0.14), float3(L * 0.5 - r, W * 0.64, H * 0.1), H * 0.05);
      float2 best = float2(body, 1.0);
      if (plate < best.x) best = float2(plate, 2.0);
      if (lamp < best.x) best = float2(lamp, 3.0);
      return best;
    }
    static float3 normalAt(float3 p, constant Head& h) {
      const float2 k = float2(1, -1);
      const float e = 0.02;
      return normalize(k.xyy * shape(p + k.xyy * e, h).x + k.yyx * shape(p + k.yyx * e, h).x
        + k.yxy * shape(p + k.yxy * e, h).x + k.xxx * shape(p + k.xxx * e, h).x);
    }
    static float2 local(float2 p, constant Head& h) { float2 d = p - h.a; return float2(dot(d, h.axis), dot(d, h.travel)); }
    static float3 tableAt(texture2d<float> table, constant Head& h, float2 p, float lod) {
      float2 uv = p / h.canvas;
      if (any(uv < 0.0) || any(uv > 1.0)) return float3(0.01);
      return table.sample(smooth, uv, level(lod)).rgb;
    }
    static float3 environment(texture2d<float> table, constant Head& h, float3 d, float3 from, float rough) {
      if (d.z < -0.02) {
        float3 x = from + d * (from.z / -d.z);
        return tableAt(table, h, x.xy, 1.0 + rough * 6.0) * 0.92;
      }
      return room(d, rough);
    }
    static float3 irradiance(float3 n, float3 glow) {
      float sky = 0.06 + 0.08 * saturate(n.z);
      float key = 0.8 * saturate(dot(n, normalize(kLight)));
      return float3(sky + key) + glow * (0.5 * saturate(-n.z) + 0.16 * (1.0 - abs(n.z)));
    }
    // The film under the head: lit by its lamp, the light spilling out from under both sides and
    // fading away from them, and shaded where the head stands between it and the softbox.
    static float4 onTable(float2 P, constant Head& h, texture2d<float> table) {
      float2 q = local(P, h);
      float W = h.width;
      float along = smoothstep(-W * 0.4, W * 0.3, q.x) * (1.0 - smoothstep(h.length - W * 0.3, h.length + W * 0.4, q.x));
      float sigma = W * 0.55 + h.gap * 0.5, out = max(abs(q.y) - W * 0.5, 0.0);
      float pool = h.lamp * along * exp(-out * out / (2.0 * sigma * sigma));
      float3 L = normalize(kLight);
      float mid = h.gap + h.height * 0.55;
      float2 s = local(P + L.xy / L.z * mid, h);
      float2 dq = abs(s - float2(h.length * 0.5, 0.0)) - float2(h.length * 0.5, W * 0.5);
      float d = length(max(dq, 0.0)) + min(max(dq.x, dq.y), 0.0);
      float pen = mid * 0.35 + 1.0;
      float shade = 0.32 * (1.0 - smoothstep(-pen, pen, d));
      if (pool < 0.003 && shade < 0.003) return float4(0);
      float3 c = tableAt(table, h, P, 0.0) * (1.0 - shade) * (1.0 + 2.4 * pool) + float3(0.9, 0.96, 1.0) * 0.1 * pool;
      return float4(c, 1);
    }
    static float4 trace(float2 P, constant Head& h, texture2d<float> table, float3 glow) {
      float3 E = h.eye.xyz;
      float3 rdw = normalize(float3(P, 0.0) - E);
      float2 ea = local(E.xy, h);
      float3 ro = float3(ea, E.z), rd = float3(dot(rdw.xy, h.axis), dot(rdw.xy, h.travel), rdw.z);
      float top = h.gap + h.height + 1.0;
      float tStart = max(0.0, (ro.z - top) / -rd.z), tEnd = (ro.z - max(0.0, h.gap - 1.0)) / -rd.z;
      float2 p0 = (ro + rd * tStart).xy, p1 = (ro + rd * tEnd).xy;
      float m = h.width * 0.6 + 1.0;
      bool outside = max(p0.x, p1.x) < -m || min(p0.x, p1.x) > h.length + m || max(p0.y, p1.y) < -m || min(p0.y, p1.y) > m;
      float tt = tStart;
      float2 res = float2(1, 0);
      bool hit = false;
      for (int i = 0; i < 96 && !outside && tt < tEnd; i++) {
        res = shape(ro + rd * tt, h);
        if (res.x < 0.002) { hit = true; break; }
        tt += max(res.x * 0.9, 0.01);
      }
      if (!hit) return onTable(P, h, table);
      if (res.y > 2.5) return float4(float3(0.82, 0.93, 1.0) * (1.5 + 3.0 * h.lamp), 1);
      float3 p = ro + rd * tt, nl = normalAt(p, h);
      float3 n = normalize(float3(h.axis * nl.x + h.travel * nl.y, nl.z)), world = E + rdw * tt;
      float nv = saturate(dot(n, -rdw));
      float3 albedo = float3(0.025), f0 = float3(0.045);
      float rough = 0.34;
      if (res.y > 1.5) {
        // Brushed along the head: fine streaks across it.
        float grain = fract(sin(floor(p.y * 4.0) * 12.9898 + 4.1) * 43758.5453);
        albedo = float3(0.0);
        f0 = float3(0.72, 0.73, 0.75) * (0.88 + 0.2 * grain);
        rough = 0.2 + 0.1 * grain;
      }
      float3 F = f0 + (1.0 - f0) * pow(1.0 - nv, 5.0) * (1.0 - 0.7 * rough);
      float3 spec = environment(table, h, reflect(rdw, n), world, rough) * F;
      return float4(albedo * irradiance(n, glow) + spec, 1);
    }
    kernel void scanHead(texture2d<float, access::write> out [[texture(0)]], texture2d<float> table [[texture(1)]],
                         constant Head& h [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
      // The table's light under the head, which its sides and bottom pick up.
      float3 glow = tableAt(table, h, h.a + h.axis * h.length * 0.5, 6.0);
      const float2 grid[4] = {float2(0.375, 0.125), float2(0.875, 0.375), float2(0.125, 0.625), float2(0.625, 0.875)};
      float4 sum = float4(0);
      for (int s = 0; s < h.samples; s++) {
        float2 jitter = h.samples == 1 ? float2(0.5) : grid[s];
        float4 c = trace(h.origin + (float2(gid) + jitter) / h.scale, h, table, glow);
        sum += float4(c.rgb * c.a, c.a);
      }
      sum /= float(h.samples);
      float3 c = sum.a > 0.0 ? sum.rgb / sum.a : float3(0);
      out.write(float4(encode(c.r), encode(c.g), encode(c.b), 1) * sum.a, gid);
    }
    """
}

/// The head over the frame being scanned, moving as the scan goes, in either view. It takes no
/// clicks; the canvas asks it to follow on every change and it glides to the reported progress.
final class ScanHeadView: NSView {
  weak var canvas: FilmCanvasView?
  /// While the canvas takes its own picture for the overlays to look through.
  var drawingSuppressed = false
  private(set) var pose: ScanHeadRenderer.Pose?
  private(set) var progress = 0.0
  private var target = 0.0
  private var frameID: UUID?
  private(set) var image: CGImage?
  private var timer: Timer?
  private var renderPending = false
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }
  override var acceptsFirstResponder: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// The frame the scanner is reading and how far it has got; nil when it is not scanning one.
  func follow(frame id: UUID?, progress p: Double) {
    guard let id else { return stop() }
    let p = clamp(p)
    if id != frameID {
      frameID = id
      progress = p
      target = p
      setNeedsRender()
    } else {
      target = max(target, p)
    }
    if pose == nil { setNeedsRender() }
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.glide() }
    }
  }
  private func glide() {
    let step = target - progress
    guard abs(step) > 0.0004 else { return }
    progress += step * 0.25
    renderNow()
  }
  func stop() {
    timer?.invalidate()
    timer = nil
    frameID = nil
    pose = nil
    image = nil
    isHidden = true
  }
  func setNeedsRender() {
    guard !renderPending else { return }
    renderPending = true
    DispatchQueue.main.async { [weak self] in
      self?.renderPending = false
      self?.renderNow()
    }
  }
  func renderNow() {
    guard let canvas, let frameID, let pose = canvas.scanHeadPose(frame: frameID, progress: progress) else {
      pose = nil
      isHidden = true
      return
    }
    let region = pose.bounds.intersection(canvas.bounds).integral
    guard !region.isEmpty else { return isHidden = true }
    self.pose = pose
    frame = region
    isHidden = false
    image = ScanHeadRenderer.shared.render(
      frame: region, scale: window?.backingScaleFactor ?? 2, pose: pose, table: canvas.tableSnapshot(), canvas: canvas.bounds.size)
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    guard !drawingSuppressed, let image else { return }
    NSImage(cgImage: image, size: bounds.size).draw(
      in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.none])
  }
}
