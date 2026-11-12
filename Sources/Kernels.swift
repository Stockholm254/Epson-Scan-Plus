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
  /// the same either way. `lit` is the frame's local lightness (`ImagePipeline.lightBase`): with
  /// fade.w the shoulder takes the pixel's lightness less its fine detail, the detail added back
  /// after it (`ended`); without, it is not read.
  static let negative = color("negative", conversion + """
    [[stitchable]] float4 negative(coreimage::sample_t p, coreimage::sample_t lit, NEGATIVE_ARGS) {
      return float4(clamp(graded(p, true, float3(1.0), float3(0.0), lit.r, NEGATIVE_PASS), float3(0.0), float3(1.0)), 1.0);
    }
    """)
  /// The tones first and the saturation after them, without the final clip: colours the saturation
  /// control pushes past sRGB stay, for exports into a wider colour space.
  static let negativeUnclipped = color("negativeUnclipped", conversion + """
    [[stitchable]] float4 negativeUnclipped(coreimage::sample_t p, coreimage::sample_t lit, NEGATIVE_ARGS) {
      return float4(saturated(graded(p, false, float3(1.0), float3(0.0), lit.r, NEGATIVE_PASS), tone, ends, local), 1.0);
    }
    """)
  /// What `negative` takes into its ends, unclipped: each channel on the print's straight line,
  /// black at 0 and white at 1, past them as far as the negative goes (`ImagePipeline.toneRange`).
  static let negativeRange = color("negativeRange", conversion + """
    [[stitchable]] float4 negativeRange(coreimage::sample_t p, NEGATIVE_ARGS) {
      return float4(toned(p, true, float3(1.0), float3(0.0), NEGATIVE_PASS), 1.0);
    }
    """)
  /// The three again for a frame with a light-leak repair (`LeakFix`): each pixel's reading on the
  /// print's straight line, before the exposure and levels, corrected as the repair measured,
  /// `a` times it plus `d`, from two pictures of the correction as large as the frame's. Everything
  /// after it, the whole of ③ 调色, works on the repaired picture as on any other.
  static let negativeFixed = color("negativeFixed", conversion + """
    [[stitchable]] float4 negativeFixed(coreimage::sample_t p, coreimage::sample_t a, coreimage::sample_t d, coreimage::sample_t lit, NEGATIVE_ARGS) {
      return float4(clamp(graded(p, true, a.rgb, d.rgb, lit.r, NEGATIVE_PASS), float3(0.0), float3(1.0)), 1.0);
    }
    """)
  static let negativeUnclippedFixed = color("negativeUnclippedFixed", conversion + """
    [[stitchable]] float4 negativeUnclippedFixed(coreimage::sample_t p, coreimage::sample_t a, coreimage::sample_t d, coreimage::sample_t lit, NEGATIVE_ARGS) {
      return float4(saturated(graded(p, false, a.rgb, d.rgb, lit.r, NEGATIVE_PASS), tone, ends, local), 1.0);
    }
    """)
  static let negativeRangeFixed = color("negativeRangeFixed", conversion + """
    [[stitchable]] float4 negativeRangeFixed(coreimage::sample_t p, coreimage::sample_t a, coreimage::sample_t d, NEGATIVE_ARGS) {
      return float4(toned(p, true, a.rgb, d.rgb, NEGATIVE_PASS), 1.0);
    }
    """)
  /// The picture 去漏光 repairs: the negative taken off its mask and put on the print's scale, black
  /// at 0 and white at 1 (`printed`), with none of ③'s grading after it, clipped. `LeakFix` reads
  /// the repair back off it onto the straight line, where the fixed kernels put it.
  static let negativeNeutral = color("negativeNeutral", conversion + """
    [[stitchable]] float4 negativeNeutral(coreimage::sample_t p, NEGATIVE_ARGS) {
      float faded;
      float3 s = straight(p, float3(1.0), float3(0.0), faded, NEGATIVE_PASS);
      return float4(clamp(printed(s, NEGATIVE_PASS), float3(0.0), float3(1.0)), 1.0);
    }
    """)
  /// A guided filter on a picture's own lightness (He, Sun and Tang), in three steps between
  /// Gaussian blurs (`ImagePipeline.guided`): the lightness and its square; from their local means, how
  /// much of each pixel's own value its smoothed value keeps (a, where the variance is large against
  /// `eps`, at an edge, nearly all) and the local mean for the rest (b); and, with those averaged,
  /// a times the pixel plus b. Core Image's own CIGuidedFilter leaves a picture guided by itself as
  /// it was.
  static let guideSquare = color("guideSquare", """
    [[stitchable]] float4 guideSquare(coreimage::sample_t p) {
      return float4(p.r, p.r * p.r, 0.0, 1.0);
    }
    """)
  static let guideCoefficients = color("guideCoefficients", """
    [[stitchable]] float4 guideCoefficients(coreimage::sample_t m, float eps) {
      float a = max(m.g - m.r * m.r, 0.0);
      a = a / (a + eps);
      return float4(a, (1.0 - a) * m.r, 0.0, 1.0);
    }
    """)
  static let guideApply = color("guideApply", """
    [[stitchable]] float4 guideApply(coreimage::sample_t p, coreimage::sample_t ab) {
      float v = ab.r * p.r + ab.g;
      return float4(v, v, v, 1.0);
    }
    """)
  /// Lightroom's presence on the picture as shown (`ImagePipeline.looks`), amounts −1 to 1: texture
  /// the finest detail against `fine`; clarity the midtones' local contrast against `broad` (most
  /// at mid-grey, none at black or white); both moving every channel by the same, so the colour
  /// stays. Dehaze lifts the haze off, its veil read as the darkest channel smoothed (`haze`), up
  /// to six tenths of it at 1, as a veil of white light (I − h)/(1 − h), so what it veiled comes back
  /// darker and in colour; less than 0 lays a pale veil on.
  static let presence = color("presence", """
    [[stitchable]] float4 presence(coreimage::sample_t p, coreimage::sample_t fine, coreimage::sample_t broad, coreimage::sample_t haze, float4 amounts) {
      float3 luma = float3(0.2126, 0.7152, 0.0722);
      float l = dot(p.rgb, luma), lf = dot(fine.rgb, luma), lb = dot(broad.rgb, luma);
      float mid = clamp(4.0 * l * (1.0 - l), 0.0, 1.0);
      float3 q = p.rgb + float3(amounts.x * 1.2 * (l - lf) + amounts.y * 0.8 * (lf - lb) * mid);
      if (amounts.z > 0.0) {
        float h = 0.6 * amounts.z * clamp(haze.r, 0.0, 0.8);
        q = (q - float3(h)) / max(1.0 - h, 0.2);
      } else if (amounts.z < 0.0) {
        q = mix(q, float3(0.85), -amounts.z * 0.35);
      }
      return float4(q, p.a);
    }
    """)
  /// Lightroom's colour mixer on the picture as shown: each pixel's hue looked up in `table` (a
  /// degree a step, from `ColourMixer.table`): its hue turned, its saturation scaled, its colour
  /// made lighter or darker, all of it as far as the pixel has colour (none for a grey, all from a
  /// quarter saturation up). What lies past 0 or 1 in a wide export goes back on unchanged.
  static let mixer = compiled("mixer", """
    [[stitchable]] float4 mixer(coreimage::sampler image, coreimage::sampler table) {
      float4 p = image.sample(image.coord());
      float3 c = clamp(p.rgb, float3(0.0), float3(1.0));
      float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b)), d = mx - mn;
      if (d < 0.00001) { return p; }
      float h = mx == c.r ? fmod((c.g - c.b) / d + 6.0, 6.0) : (mx == c.g ? (c.b - c.r) / d + 2.0 : (c.r - c.g) / d + 4.0);
      h /= 6.0;
      float4 m = table.sample(table.transform(float2(h * 360.0, 0.5)));
      float s = d / max(mx, 0.00001), w = smoothstep(0.0, 0.25, s);
      float h2 = fract(h + m.r * w + 1.0) * 6.0;
      float s2 = clamp(s * (1.0 + m.g * w), 0.0, 1.0);
      float f = h2 - floor(h2);
      float pv = mx * (1.0 - s2), qv = mx * (1.0 - s2 * f), tv = mx * (1.0 - s2 * (1.0 - f));
      int k = int(floor(h2)) % 6;
      float3 rgb = k == 0 ? float3(mx, tv, pv) : k == 1 ? float3(qv, mx, pv) : k == 2 ? float3(pv, mx, tv)
        : k == 3 ? float3(pv, qv, mx) : k == 4 ? float3(tv, pv, mx) : float3(mx, pv, qv);
      rgb *= max(0.0, 1.0 + 0.5 * m.b * w);
      return float4(rgb + (p.rgb - c), p.a);
    }
    """)
  /// Lightroom's colour grading on the picture as shown: the shadows, midtones and highlights each
  /// with their tint added (`ColourGrading.tint`, no lightness of its own), shared out by the
  /// pixel's lightness: the shadows' fading out up to `shape.x`'s pivot (0.5, moved by the balance
  /// a quarter either way), the highlights' fading in from it, over `shape.y`'s blending; then the
  /// lightness put back as it was.
  static let grade = color("grade", """
    [[stitchable]] float4 grade(coreimage::sample_t p, float4 shadows, float4 midtones, float4 highlights, float4 shape) {
      float3 luma = float3(0.2126, 0.7152, 0.0722);
      float l = clamp(dot(p.rgb, luma), 0.0, 1.0);
      float pivot = 0.5 + 0.25 * shape.x, width = 0.1 + 0.4 * clamp(shape.y, 0.0, 1.0);
      float ws = 1.0 - smoothstep(pivot - width, pivot, l), wh = smoothstep(pivot, pivot + width, l);
      float wm = max(0.0, 1.0 - ws - wh);
      float3 q = p.rgb + shadows.xyz * ws + midtones.xyz * wm + highlights.xyz * wh;
      q += float3(dot(p.rgb - q, luma));
      return float4(q, p.a);
    }
    """)
  /// Clipping shown (J), as Lightroom shows it: where a channel of the picture as shown is white, red;
  /// where one is black, blue; the rest as it is.
  static let clipMark = color("clipMark", """
    [[stitchable]] float4 clipMark(coreimage::sample_t p) {
      float mx = max(p.r, max(p.g, p.b)), mn = min(p.r, min(p.g, p.b));
      if (mx >= 0.998) { return float4(1.0, 0.12, 0.12, p.a); }
      if (mn <= 0.002) { return float4(0.1, 0.35, 1.0, p.a); }
      return p;
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
    #define NEGATIVE_ARGS float3 base, float3 slope, float3 toe, float3 gain, float3 balance, float4 levels, float4 tone, float4 color, float4 ends, float inverted, float4 fade, float4 lights, float4 shoulder, float encode, float4 local
    #define NEGATIVE_PASS base, slope, toe, gain, balance, levels, tone, color, ends, inverted, fade, lights, shoulder, encode, local

    // Saturation (tone.w) about each pixel's lightness, more in the shadows (ends.z); and vibrance
    // (local.z, −1 to 1), as Lightroom's: more for the colours that have little, none for those
    // already strong, and half for skin (red over green over blue, green about half way).
    static float3 saturated(float3 q, float4 tone, float4 ends, float4 local) {
      float l = dot(q, float3(0.2126, 0.7152, 0.0722)), m = clamp(l, 0.0, 1.0);
      float amount = tone.w * (1.0 + ends.z * (1.0 - m) * (1.0 - m));
      if (local.z != 0.0) {
        float mx = max(q.r, max(q.g, q.b)), mn = min(q.r, min(q.g, q.b));
        float s = clamp((mx - mn) / max(abs(mx), 0.0001), 0.0, 1.0);
        float skin = q.r > q.g && q.g > q.b ? 1.0 - smoothstep(0.1, 0.3, abs((q.g - q.b) / max(q.r - q.b, 0.0001) - 0.45)) : 0.0;
        amount *= max(0.0, 1.0 + local.z * (1.0 - s) * (1.0 - s) * (1.0 - 0.5 * skin));
      }
      return mix(float3(l), q, float3(amount));
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
    // Each channel on the print's straight line, before the print exposure and the levels: log
    // exposure for a negative, linear light for a positive. A light-leak repair's correction (`a`
    // times it plus `d`; 1 and 0 without one) goes on the reading as ② leaves it, the film's
    // exposure, before the gain and white balance the frame's analysis gives and anything ③ sets,
    // so none of them moves the repair, nor it them. `faded` is how far the white balance has
    // faded in (`ImagePipeline.unexposedFade`), 1 on a positive.
    static float3 straight(float4 p, float3 a, float3 d, thread float &faded, NEGATIVE_ARGS) {
      float3 v = max(p.rgb, float3(0.000001));
      faded = 1.0;
      if (inverted < 0.5) { return (pow(v, float3(color.w)) * a + d) * gain + balance; }
      float3 e = log(max(base, float3(0.000001)) / v) * (color.w / 2.302585093) / slope;
      e += toe * log(max(float3(1.0) - exp(-e / max(toe, float3(0.000001))), float3(0.02)));
      e = e * a + d;
      float3 b = balance;
      if (fade.x > 0.0) { faded = min((1.0 - exp(-max((e.r + e.g + e.b) / 3.0, 0.0) / fade.x)) / fade.y, 1.0); b *= faded; }
      return e * gain + b;
    }
    // The straight line on the print's scale, black at 0 and white at 1 (levels.x, levels.y), with
    // the print exposure; a positive's linear light encoded for the screen.
    static float3 printed(float3 s, NEGATIVE_ARGS) {
      if (inverted < 0.5) {
        float3 t = (s - float3(levels.x)) / max(levels.y - levels.x, 0.000001) * pow(2.0, tone.x);
        return sign(t) * pow(abs(t), float3(encode));
      }
      return (s + float3(tone.x * 0.30103) - float3(levels.x)) / max(levels.y - levels.x, 0.001);
    }
    static float3 toned(float4 p, bool first, float3 fa, float3 fd, NEGATIVE_ARGS) {
      float faded;
      float3 q = printed(straight(p, fa, fd, faded, NEGATIVE_PASS), NEGATIVE_PASS);
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
      if (first) { q = saturated(q, tone, ends, local); }
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
    // The shoulder over `q`: rolled off each by itself, a bright colour's channels close up towards
    // white: a white lit by the sky and one lit by the sun come out one white, and a blue sky past
    // white in its blue alone turns cyan. With ends.w the brightest channel takes the shoulder and
    // the others keep their distance below it, so the colour and its hue stay as the shoulder brings
    // it down; a sky that far past white comes out a deeper blue. Past the frame's brightest (a
    // little past white without the longer shoulder) everything closes up, as a print's highlights
    // wash out.
    static float3 rolledOff(float3 q, float4 ends, float4 shoulder, float4 local) {
      float3 each = shouldered(q, ends, shoulder);
      float m = max(q.r, max(q.g, q.b));
      float top = shouldered(float3(m), ends, shoulder).x;
      float3 kept = q + (top - m);
      // Every channel brought down as far as the brightest, a colour well past white comes out
      // darker than rolled off each by itself. local.x (0-1) lifts it that far back towards the
      // lightness it would have had, the others' distances below the brightest made smaller
      // together, so the hue stays, the colour a little paler.
      if (local.x > 0.0) {
        float3 luma = float3(0.2126, 0.7152, 0.0722);
        float now = dot(kept, luma);
        float aim = now + local.x * max(dot(each, luma) - now, 0.0);
        kept = float3(top) - (float3(top) - kept) * clamp((top - aim) / max(top - now, 0.00001), 0.0, 1.0);
      }
      float far = shoulder.w > 0.0 ? shoulder.x + shoulder.y : 1.1;
      return mix(each, kept, ends.w * (1.0 - smoothstep(far, far + 0.3, m)));
    }
    // The ends, the clip and the midtone. `detail` is how far the pixel's
    // brightest channel lies above or below its surroundings' (`graded`): the shoulder takes the
    // pixel without it and it goes back on after, so a white sign or a lit metal keeps its texture
    // and shading at full contrast while the light around them still rolls off towards white.
    // Under the shoulder's knee taking it off and putting it back is nothing.
    static float3 ended(float3 q, float detail, NEGATIVE_ARGS) {
      // Each side's curve only works out its own side, so a far value (the holder, opaque) does not
      // overflow the other's exp into infinity and come out as nothing.
      if (ends.x > 0.0) { float3 t = float3(ends.x); q = mix(t * exp(min(q, t) / t - float3(1.0)), q, step(t, q)); }
      if (ends.y < 1.0) {
        float3 below = rolledOff(q - float3(detail), ends, shoulder, local);
        // Detail above its surroundings goes back whole up to half the room left under white, and
        // past that eases towards three quarters of it, so a texture near white is kept and nothing
        // reaches white; in the midtones, with room to spare, and below its surroundings, as it was.
        float room = max(1.0 - max(below.r, max(below.g, below.b)), 0.0001), whole = 0.5 * room;
        float added = detail > whole ? whole + 0.5 * whole * (1.0 - exp(-(detail - whole) / (0.5 * whole))) : detail;
        float3 kept = below + float3(added);
        // A bright line or rim, more above its surroundings than fits under white, would have its
        // gradation pressed into the last of the room: it comes out as the shoulder alone made it,
        // as far as its detail did not fit.
        if (detail > 0.0) { kept = mix(rolledOff(q, ends, shoulder, local), kept, added / detail); }
        q = kept;
      }
      q = clamp(q, float3(0.0), float3(1.0));
      return pow(q, float3(1.0 / max(tone.y, 0.1)));
    }
    // The tones, and with `first` the saturation ahead of the ends. With fade.w, the pixel's fine
    // detail for the shoulder (`ended`): its brightest channel, saturated as `lit` was measured,
    // less `lit`, no further than fade.w either way, so a sharp edge's step stays in the light
    // the shoulder rolls off and leaves no bright rim beside it.
    //
    // Then highlights, shadows, whites and blacks (lights.y, .x, .z, .w, −1 to 1, brighter up), as
    // Lightroom has them, before the ends and the clip, so pulling them down brings back what lay
    // past white or under black. Each moves every channel by the same, up to 0.15: on this scale
    // that is the same exposure for the three, so the colour stays. How much goes by lightness:
    // highlights and shadows by the light round the pixel (`lit`, with local.y), so a bright cloud
    // or a white sign comes down whole with its texture, and a dark shade lifts with its own;
    // whites and blacks by the pixel's own brightest and darkest channel, the ends of the range.
    // Highlights: full from 0.85 up (past white too), none under 0.45. Shadows: most about 0.25-0.3,
    // none at black or over 0.65, so the black stays. Whites: full at white and past it, none under
    // 0.5. Blacks: full at black and under it, none over 0.5. Every tone stays in order.
    static float3 graded(float4 p, bool first, float3 fa, float3 fd, float lit, NEGATIVE_ARGS) {
      float3 q = toned(p, first, fa, fd, NEGATIVE_PASS);
      float3 s = first ? q : saturated(q, tone, ends, local);
      float m = max(s.r, max(s.g, s.b)), n = min(s.r, min(s.g, s.b));
      float detail = fade.w > 0.0 ? clamp(m - lit, -fade.w, fade.w) : 0.0;
      float around = local.y > 0.5 ? lit : m;
      float shift = lights.y * 0.15 * smoothstep(0.45, 0.85, around)
        + lights.x * 0.12 * smoothstep(0.0, 0.25, around) * (1.0 - smoothstep(0.3, 0.65, around))
        + lights.z * 0.15 * smoothstep(0.5, 1.0, m)
        + lights.w * 0.15 * (1.0 - smoothstep(0.0, 0.5, n));
      return ended(q + float3(shift), detail, NEGATIVE_PASS);
    }

    """
}
