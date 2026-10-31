import CoreImage

/// The app's own Core Image kernels, written in Metal and compiled the first time each is used,
/// while the app runs, so building it needs no Metal compiler; the system keeps what it compiled, so
/// only the first run after one changes waits for it (about a third of a second each). They replace
/// kernels in the Core Image Kernel Language, deprecated since macOS 10.14, and give the same
/// pixels: within 1e-6 of what those gave.
///
/// Each is compiled from a source of its own. Given a library of two kernels, Core Image runs
/// whichever of them a context rendered first for the other as well (seen on macOS 27.2: the
/// unclipped conversion came out clipped), so no library holds two.
enum Kernels {
  /// A negative's (or a positive's) encoded readings to the picture, as `ImagePipeline.output` sets
  /// it up, clipped to 0–1.
  static let negative = color("negative", conversion + """
    [[stitchable]] float4 negative(coreimage::sample_t p, NEGATIVE_ARGS) {
      return float4(clamp(positive(p, NEGATIVE_PASS), float3(0.0), float3(1.0)), 1.0);
    }
    """)
  /// The same without the final clip: colours the saturation control pushes past sRGB stay, for
  /// exports into a wider colour space.
  static let negativeUnclipped = color("negativeUnclipped", conversion + """
    [[stitchable]] float4 negativeUnclipped(coreimage::sample_t p, NEGATIVE_ARGS) {
      return float4(positive(p, NEGATIVE_PASS), 1.0);
    }
    """)
  /// Each pixel's colour apart from its lightness (luma), and the two put back together.
  static let colourOf = color("colourOf", """
    [[stitchable]] float4 colourOf(coreimage::sample_t p) {
      float l = dot(p.rgb, float3(0.2126, 0.7152, 0.0722));
      return float4(p.rgb - float3(l), p.a);
    }
    """)
  static let withColour = color("withColour", """
    [[stitchable]] float4 withColour(coreimage::sample_t p, coreimage::sample_t c) {
      float l = dot(p.rgb, float3(0.2126, 0.7152, 0.0722));
      return float4(float3(l) + c.rgb, p.a);
    }
    """)
  /// A copy shot divided by its light's fall-off, each channel by its own, and never by less than
  /// 0.05 of the light, where the fall-off grid has next to nothing.
  static let flatten = color("flatten", """
    [[stitchable]] float4 flatten(coreimage::sample_t p, coreimage::sample_t f) {
      return float4(p.rgb / max(f.rgb, float3(0.05)), p.a);
    }
    """)
  /// Tone curves as a lookup: each channel reads its own entry from an `n` × 1 table.
  static let curves = compiled("curves", """
    [[stitchable]] float4 curves(coreimage::sampler image, coreimage::sampler table, float n) {
      float4 p = image.sample(image.coord());
      float3 at = clamp(p.rgb, float3(0.0), float3(1.0)) * (n - 1.0) + 0.5;
      return float4(table.sample(table.transform(float2(at.r, 0.5))).r,
                    table.sample(table.transform(float2(at.g, 0.5))).g,
                    table.sample(table.transform(float2(at.b, 0.5))).b, p.a);
    }
    """)

  private static func compiled(_ name: String, _ source: String) -> CIKernel? {
    let kernels = try? CIKernel.kernels(withMetalString: "#include <CoreImage/CoreImage.h>\nusing namespace metal;\n" + source)
    return kernels?.first { $0.name == name }
  }
  private static func color(_ name: String, _ source: String) -> CIColorKernel? { compiled(name, source) as? CIColorKernel }

  /// The conversion both `negative` kernels share, up to its final clip.
  private static let conversion = """
    #define NEGATIVE_ARGS float3 base, float3 slope, float3 toe, float3 gain, float3 balance, float4 levels, float4 tone, float4 color, float4 ends, float inverted, float2 fade, float2 lights
    #define NEGATIVE_PASS base, slope, toe, gain, balance, levels, tone, color, ends, inverted, fade, lights

    // Exposure (tone.x, in EV) is a print exposure: a shift of log exposure, 0.30103 per stop,
    // applied before the levels and clipping so −EV recovers highlights. Positive input scales the
    // linear value instead, through its encoding gamma.
    static float3 positive(float4 p, NEGATIVE_ARGS) {
      float3 v = max(p.rgb, float3(0.000001));
      float3 e = log(max(base, float3(0.000001)) / v) * (color.w / 2.302585093) / slope;
      e += toe * log(max(float3(1.0) - exp(-e / max(toe, float3(0.000001))), float3(0.02)));
      float3 b = balance;
      if (fade.x > 0.0) { b *= min((1.0 - exp(-max((e.r + e.g + e.b) / 3.0, 0.0) / fade.x)) / fade.y, 1.0); }
      float3 q = (e * gain + b + float3(tone.x * 0.30103) - float3(levels.x)) / max(levels.y - levels.x, 0.001);
      if (inverted < 0.5) { q = v * pow(2.0, tone.x / max(color.w, 0.1)); }
      q = (q - float3(levels.z)) / max(levels.w - levels.z, 0.01);
      q += float3(color.x * 0.12 + color.y * 0.05, -color.y * 0.10, -color.x * 0.12 + color.y * 0.05);
      q = (q - float3(0.5)) * tone.z + float3(0.5);
      // Each side's curve only works out its own side, so a far value (the holder, opaque) does not
      // overflow the other's exp into infinity and come out as nothing.
      if (ends.x > 0.0) { float3 t = float3(ends.x); q = mix(t * exp(min(q, t) / t - float3(1.0)), q, step(t, q)); }
      if (ends.y < 1.0) { float r = 1.0 - ends.y; float3 o = max(q, float3(ends.y)) - float3(ends.y); q = mix(q, float3(ends.y) + r * (float3(1.0) - exp(-o / r)), step(float3(ends.y), q)); }
      q = clamp(q, float3(0.0), float3(1.0));
      // Shadows and highlights: the dark tones (most at a third) and the light ones (most at two
      // thirds) moved by up to 0.12, black and white held, every tone still in order.
      float3 r = float3(1.0) - q;
      q += lights.x * 0.81 * q * r * r + lights.y * 0.81 * q * q * r;
      q = pow(q, float3(1.0 / max(tone.y, 0.1)));
      float l = dot(q, float3(0.2126, 0.7152, 0.0722));
      return mix(float3(l), q, float3(tone.w * (1.0 + ends.z * (1.0 - l) * (1.0 - l))));
    }

    """
}
