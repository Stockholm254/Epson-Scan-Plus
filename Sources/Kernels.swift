import CoreImage

/// The app's own Core Image kernels, written in Metal and compiled the first time each is used,
/// while the app runs, so building it needs no Metal compiler; the system keeps what it compiled, so
/// only the first run after one changes waits for it (about a third of a second each). They replaced
/// kernels in the Core Image Kernel Language, deprecated since macOS 10.14, and gave the same
/// pixels: within 1e-6 of what those gave.
///
/// Each is compiled from a source of its own. Given a library of two kernels, Core Image runs
/// whichever of them a context rendered first for the other as well (seen on macOS 27.2: the
/// unclipped conversion came out clipped), so no library holds two.
enum Kernels {
  /// A negative's (or a positive's) encoded readings to the picture, as `ImagePipeline.output` sets
  /// it up, clipped to 0–1. The saturation comes before the ends, as a print's colour is in its
  /// dyes before the paper's curve: a bright colour it takes past white rolls off into the shoulder
  /// with every channel graded, a bright blue sky keeping its gradation, instead of a channel
  /// being cut. In between the ends, with the midtone at 1 and shadows and highlights at 0, it is
  /// the same either way.
  static let negative = color("negative", conversion + """
    [[stitchable]] float4 negative(coreimage::sample_t p, NEGATIVE_ARGS) {
      return float4(clamp(graded(p, true, NEGATIVE_PASS), float3(0.0), float3(1.0)), 1.0);
    }
    """)
  /// The tones first and the saturation after them, without the final clip: colours the saturation
  /// control pushes past sRGB stay, for exports into a wider colour space.
  static let negativeUnclipped = color("negativeUnclipped", conversion + """
    [[stitchable]] float4 negativeUnclipped(coreimage::sample_t p, NEGATIVE_ARGS) {
      return float4(saturated(graded(p, false, NEGATIVE_PASS), tone, ends), 1.0);
    }
    """)
  /// What `negative` takes into its ends, unclipped: each channel on the print's straight line,
  /// black at 0 and white at 1, past them as far as the negative goes (`ImagePipeline.toneRange`).
  static let negativeRange = color("negativeRange", conversion + """
    [[stitchable]] float4 negativeRange(coreimage::sample_t p, NEGATIVE_ARGS) {
      return float4(toned(p, true, NEGATIVE_PASS), 1.0);
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

  /// The conversion the `negative` kernels share, up to its final clip: the tones (`graded`) and the
  /// saturation, in one order or the other.
  private static let conversion = """
    #define NEGATIVE_ARGS float3 base, float3 slope, float3 toe, float3 gain, float3 balance, float4 levels, float4 tone, float4 color, float4 ends, float inverted, float4 fade, float4 lights, float4 shoulder, float encode
    #define NEGATIVE_PASS base, slope, toe, gain, balance, levels, tone, color, ends, inverted, fade, lights, shoulder, encode

    // Saturation (tone.w) about each pixel's lightness, more in the shadows (ends.z).
    static float3 saturated(float3 q, float4 tone, float4 ends) {
      float l = dot(q, float3(0.2126, 0.7152, 0.0722)), m = clamp(l, 0.0, 1.0);
      return mix(float3(l), q, float3(tone.w * (1.0 + ends.z * (1.0 - m) * (1.0 - m))));
    }
    // The tones up to the ends, and with `first` the saturation: on the print's straight line,
    // black at 0 and white at 1, unclipped.
    //
    // Exposure (tone.x, in EV) is a print exposure: a shift of log exposure, 0.30103 per stop,
    // applied before the levels and clipping so −EV recovers highlights.
    //
    // Positive input (a slide, or a file already positive) is light, not density: decoded by its
    // gamma (color.w) to linear, each channel through its gain and black (gain, balance), the ends
    // (levels.x, levels.y) and the exposure, a scale, then encoded for the screen (`encode`, a
    // power). A file already positive comes through with nothing in front, encoded as it came.
    static float3 toned(float4 p, bool first, NEGATIVE_ARGS) {
      float3 v = max(p.rgb, float3(0.000001));
      float3 q;
      // How far the white balance has faded in (`ImagePipeline.unexposedFade`): 1 on a positive.
      float faded = 1.0;
      if (inverted < 0.5) {
        float3 t = pow(v, float3(color.w)) * gain + balance;
        t = (t - float3(levels.x)) / max(levels.y - levels.x, 0.000001) * pow(2.0, tone.x);
        q = sign(t) * pow(abs(t), float3(encode));
      } else {
        float3 e = log(max(base, float3(0.000001)) / v) * (color.w / 2.302585093) / slope;
        e += toe * log(max(float3(1.0) - exp(-e / max(toe, float3(0.000001))), float3(0.02)));
        float3 b = balance;
        if (fade.x > 0.0) { faded = min((1.0 - exp(-max((e.r + e.g + e.b) / 3.0, 0.0) / fade.x)) / fade.y, 1.0); b *= faded; }
        q = (e * gain + b + float3(tone.x * 0.30103) - float3(levels.x)) / max(levels.y - levels.x, 0.001);
      }
      q = (q - float3(levels.z)) / max(levels.w - levels.z, 0.01);
      // Shadow warmth (color.z): red up and blue down by up to 0.2 in the dark tones, all of it at a
      // lightness of 0.2 and none over 0.55, so the sunlit greys keep their balance; none at black
      // either, which took no light to colour and would only turn red.
      // Shadow tint (fade.z), in the same tones: green up and red and blue down (negative), or the
      // other way, by up to 0.2 in green, the shape of the overall tint doubled. It only takes out
      // the opposite cast: green goes where green lies under red and blue's mean (violet haze,
      // magenta shade), by 0.05 in full, so grass and neutral sand stay as they are; magenta
      // where green lies over it. The cast is read as shown, warmth and tint included; shadow
      // warmth moves red and blue alike either way, so it leaves the cast as it was.
      // `ImagePipeline.shadowBalance` solves the two for a picked grey in shadow; keep them alike.
      float l = dot(q, float3(0.2126, 0.7152, 0.0722));
      float dark = smoothstep(0.03, 0.2, l) * (1.0 - smoothstep(0.2, 0.55, l));
      // Warmth (color.x) and tint (color.y), white balance as much as the picked grey's: they fade
      // in with it, so film that took no light stays a neutral black in a warm or a cool print.
      float3 balanced = faded * float3(color.x * 0.12 + color.y * 0.05, -color.y * 0.10, -color.x * 0.12 + color.y * 0.05);
      float violet = (q.r + q.b) * 0.5 - q.g + (balanced.r + balanced.b) * 0.5 - balanced.g;
      float opposite = smoothstep(0.0, 0.05, fade.z < 0.0 ? violet : -violet);
      q += float3(color.z * 0.2 * dark, 0.0, -color.z * 0.2 * dark);
      q += float3(fade.z * 0.1, -fade.z * 0.2, fade.z * 0.1) * dark * opposite;
      q += balanced;
      q = (q - float3(0.5)) * tone.z + float3(0.5);
      if (first) { q = saturated(q, tone, ends); }
      return q;
    }
    // The shoulder each value takes: from ends.y it rolls off towards white. Highlights running
    // further past white than that holds (`ImagePipeline.shoulder`) go from shoulder.x along a log
    // curve to 0.98 at the frame's brightest, then out to white, that curve taking over by shoulder.w.
    static float3 shouldered(float3 q, float4 ends, float4 shoulder) {
      float r = 1.0 - ends.y; float3 o = max(q, float3(ends.y)) - float3(ends.y);
      float3 rolled = mix(q, float3(ends.y) + r * (float3(1.0) - exp(-o / r)), step(float3(ends.y), q));
      if (shoulder.w > 0.0) {
        float k = shoulder.x, span = shoulder.y, c = shoulder.z;
        float3 x = max(q - float3(k), float3(0.0));
        float3 eased = float3(k) + (0.98 - k) * log(float3(1.0) + c * min(x, float3(span))) / log(1.0 + c * span);
        float3 past = float3(0.98) + 0.02 * (float3(1.0) - exp(-max(x - float3(span), float3(0.0)) / (0.02 * (1.0 + c * span))));
        rolled = mix(rolled, mix(q, mix(eased, past, step(float3(span), x)), step(float3(k), q)), shoulder.w);
      }
      return rolled;
    }
    // The ends, the clip, shadows and highlights, and the midtone.
    static float3 ended(float3 q, NEGATIVE_ARGS) {
      // Each side's curve only works out its own side, so a far value (the holder, opaque) does not
      // overflow the other's exp into infinity and come out as nothing.
      if (ends.x > 0.0) { float3 t = float3(ends.x); q = mix(t * exp(min(q, t) / t - float3(1.0)), q, step(t, q)); }
      if (ends.y < 1.0) {
        // Rolled off each by itself, a bright colour's channels close up towards white: a white lit
        // by the sky and one lit by the sun come out one white, and a blue sky past white in its
        // blue alone turns cyan. With ends.w the brightest channel takes the shoulder and the others
        // keep their distance below it, so the colour and its hue stay as the shoulder brings it
        // down; a sky that far past white comes out a deeper blue. Past the frame's brightest (a
        // little past white without the longer shoulder) everything closes up, as a print's
        // highlights wash out.
        float3 each = shouldered(q, ends, shoulder);
        float m = max(q.r, max(q.g, q.b));
        float top = shouldered(float3(m), ends, shoulder).x;
        float3 kept = q + (top - m);
        // Every channel brought down as far as the brightest, a colour well past white comes out
        // darker than rolled off each by itself. lights.w (0-1) lifts it that far back towards the
        // lightness it would have had, the others' distances below the brightest made smaller
        // together, so the hue stays, the colour a little paler.
        if (lights.w > 0.0) {
          float3 luma = float3(0.2126, 0.7152, 0.0722);
          float now = dot(kept, luma);
          float aim = now + lights.w * max(dot(each, luma) - now, 0.0);
          kept = float3(top) - (float3(top) - kept) * clamp((top - aim) / max(top - now, 0.00001), 0.0, 1.0);
        }
        float far = shoulder.w > 0.0 ? shoulder.x + shoulder.y : 1.1;
        q = mix(each, kept, ends.w * (1.0 - smoothstep(far, far + 0.3, m)));
      }
      q = clamp(q, float3(0.0), float3(1.0));
      // Highlights pressed down (lights.z, 0–1): every channel lowered by the same, up to 0.15, so
      // the colour stays; how much goes by lightness, so a blue sky or a red, bright in one channel
      // but not light, is left as it is. Nothing under 0.45, white at 0.85 at 1, and the gradation
      // at the top kept, the lowering levelling off there.
      if (lights.z > 0.0) { q -= float3(lights.z * 0.15 * smoothstep(0.45, 1.0, dot(q, float3(0.2126, 0.7152, 0.0722)))); }
      // Shadows and highlights: the dark tones (most at a third) and the light ones (most at two
      // thirds) moved by up to 0.12, black and white held, every tone still in order.
      float3 r = float3(1.0) - q;
      q += lights.x * 0.81 * q * r * r + lights.y * 0.81 * q * q * r;
      return pow(q, float3(1.0 / max(tone.y, 0.1)));
    }
    // The tones, and with `first` the saturation ahead of the ends.
    static float3 graded(float4 p, bool first, NEGATIVE_ARGS) {
      return ended(toned(p, first, NEGATIVE_PASS), NEGATIVE_PASS);
    }

    """
}
