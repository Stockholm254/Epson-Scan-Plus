import Foundation

/// FilmLightLab's light-leak repair, revision 9, ported from its JavaScript engine so it runs on
/// this app's positives. A clean reference of the same photograph from an image model guides
/// smooth, local colour corrections; every output pixel is still computed from the original's,
/// so the model's objects, texture and grain never reach the result. Parameters and fitted models
/// keep FilmLightLab's JSON keys: its jobs read here, and the two engines can be compared.
enum LeakEngine {}

// MARK: - Images and parameters

/// RGB at 16 bits a sample, interleaved, in Adobe RGB (1998): what the engine reads and writes.
struct LeakImage {
  let width: Int
  let height: Int
  var data: [UInt16]
  var count: Int { width * height }
  var aspect: Double { Double(width) / Double(height) }
  @inline(__always) func rgb(_ i: Int) -> SIMD3<Double> {
    SIMD3(Double(data[i * 3]), Double(data[i * 3 + 1]), Double(data[i * 3 + 2])) / 65535
  }
  /// The pixel nearest (x, y), both 0–1 across the picture.
  @inline(__always) func index(_ x: Double, _ y: Double) -> Int {
    let xx = Int(clamp(jsRound(x * Double(width - 1)), 0, Double(width - 1)))
    let yy = Int(clamp(jsRound(y * Double(height - 1)), 0, Double(height - 1)))
    return yy * width + xx
  }
  @inline(__always) func at(_ x: Double, _ y: Double) -> SIMD3<Double> { rgb(index(x, y)) }
}

struct LeakPoint: Codable, Equatable { var x: Double, y: Double }

/// A leak region to correct, or a protected one, in the picture's 0–1 coordinates.
struct LeakRegion: Codable, Equatable, Identifiable {
  var id: String
  var name: String?
  /// ellipse, stroke (a brush path) or polygon.
  var shape: String
  /// chroma (remove the cast, keep the brightness) or fog (subtract the veil, restore the blacks).
  var mode: String?
  var x: Double?, y: Double?, rx: Double?, ry: Double?
  var amount: Double?, feather: Double?
  /// A clean point of the same material, whose colour the region is corrected to.
  var ref: LeakPoint?
  var enabled: Bool?
  var confidence: String?
  var detected: Bool?
  var approved: Bool?
  var points: [[Double]]?
  var radius: Double?
  var gaussian: Bool?
  var target: [Double]?, fog: [Double]?, ratios: [Double]?, channelRy: [Double]?, yFade: [Double]?
  /// A detected lamp's surroundings, so its own light is kept and the fog under it is not.
  var background: [Double]?
  var aspectRatio: Double?, fillRatio: Double?, areaFraction: Double?, redSignal: Double?
}

struct LeakCrop: Codable, Equatable { var x = 0.0, y = 0.0, w = 1.0, h = 1.0 }

/// A pair of matching points on the original and the reference, for a manual alignment.
struct LeakPair: Codable, Equatable { var source: [Double], target: [Double] }

struct LeakParams: Codable, Equatable {
  var rotation = 0
  var crop = LeakCrop()
  var exposure = 0.0, temperature = 0.0, tint = 0.0, contrast = 0.0
  /// auto, day or night.
  var sceneMode = "auto"
  var protectHighlights = true
  var regions: [LeakRegion] = []
  var protect: [LeakRegion] = []
  var sceneInfo: LeakScene?
  var referenceModel: LeakModel?
  init() {}
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
    crop = try c.decodeIfPresent(LeakCrop.self, forKey: .crop) ?? LeakCrop()
    exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
    temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
    tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
    contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
    sceneMode = try c.decodeIfPresent(String.self, forKey: .sceneMode) ?? "auto"
    protectHighlights = try c.decodeIfPresent(Bool.self, forKey: .protectHighlights) ?? true
    regions = try c.decodeIfPresent([LeakRegion].self, forKey: .regions) ?? []
    protect = try c.decodeIfPresent([LeakRegion].self, forKey: .protect) ?? []
    sceneInfo = try c.decodeIfPresent(LeakScene.self, forKey: .sceneInfo)
    // Models from FilmLightLab's earlier revisions are left out; starting again refits them, free.
    referenceModel = (try? c.decodeIfPresent(LeakModel.self, forKey: .referenceModel)).flatMap { $0 }
  }
  var hasGlobalColor: Bool { exposure != 0 || temperature != 0 || tint != 0 || contrast != 0 }
}

/// Day, night or mixed light, from the brightness of the original and the reference: an exposure
/// heuristic, not scene recognition, with a manual override.
struct LeakScene: Codable, Equatable {
  struct Stats: Codable, Equatable { var median, p80, dark, bright: Double }
  var revision = 1
  var requested: String
  var type: String
  var label: String
  var nightWeight: Double
  var confidence: Double
  var method = "brightness-distribution-heuristic-with-manual-override"
  var original: Stats
  var reference: Stats?
}

/// How far the result may darken or brighten where the reference asks it to, by how sure the leak
/// is: revision 9's chromatic and neutral (white) veil limits.
struct LeakTonePolicy: Codable, Equatable {
  var revision = 3
  var mode = "chromatic-and-neutral-veil"
  var dayLeakDarkenEV = 2.0, nightLeakDarkenEV = 5.0, dayOtherDarkenEV = 0.2, nightOtherDarkenEV = 0.35
  var maxBrightenEV = 0.25, highlightStart = 0.25, highlightEnd = 0.55
  var neutralDarkenEV = 5.0, neutralNightStart = 0.65, neutralNightEnd = 0.9
  var neutralEdgeInner = 0.10, neutralEdgeOuter = 0.24
  static let hybrid = LeakTonePolicy()
}

struct LeakAlignment: Codable, Equatable {
  struct Fine: Codable, Equatable { var scaleX, scaleY, dx, dy: Double }
  var H: [Double]
  var rotation: Int
  var scale: Double?
  var dx: Double?
  var dy: Double?
  var score: Double
  var fine: Fine?
  var method: String
  var reliable: Bool
}

/// A low-resolution field of values over the picture, read bilinearly.
struct LeakField: Codable, Equatable {
  var width: Int
  var height: Int
  var values: [Double]
  /// The reference's overall green and blue (gain, bias), for the neutral veil only.
  var baseline: [[Double]]?
  func sample(_ x: Double, _ y: Double) -> Double {
    // A damaged field reads as nothing rather than out of bounds.
    guard width >= 2, height >= 2, values.count == width * height else { return 0 }
    let fx = clamp(x) * Double(width - 1), fy = clamp(y) * Double(height - 1)
    let ix = min(width - 2, Int(fx.rounded(.down))), iy = min(height - 2, Int(fy.rounded(.down)))
    let ax = fx - Double(ix), ay = fy - Double(iy)
    let v = values, w = width
    return (1 - ay) * ((1 - ax) * v[iy * w + ix] + ax * v[iy * w + ix + 1])
      + ay * ((1 - ax) * v[(iy + 1) * w + ix] + ax * v[(iy + 1) * w + ix + 1])
  }
}

/// A small residual lattice over the picture and the original's brightness: colour corrections
/// (log gains), not reference pixels. The brightness axis keeps neighbouring materials apart.
struct LeakBilateral: Codable, Equatable {
  var width: Int, height: Int, depth: Int
  var range: [Double]
  var values: [[Double]]
  var amount: Double
}

struct LeakModel: Codable, Equatable {
  struct Grid: Codable, Equatable { var width: Int, height: Int, nodes: [Double] }
  struct Errors: Codable, Equatable { var rgb: Double, logRGB: Double }
  struct Diagnostics: Codable, Equatable {
    var training, calibration, heldOut: Int
    var heldOutBefore, heldOutAfter: Errors
    var residualAmount: Double
    var method = "interleaved-pair-holdout-not-quality-score"
  }
  var kind = "hybrid-veil-bilateral-v9"
  var revision = 9
  /// Per cell, for each output channel, three gains on R, G, B and an offset.
  var grid: Grid
  var H: [Double]
  var alignment: LeakAlignment
  var samples: Int
  var strength = 1.0
  var onlyRegions = false
  var error: Double
  var scenePolicy: LeakScene
  var tonePolicy: LeakTonePolicy
  var bilateral: LeakBilateral
  var veilField: LeakField
  var neutralField: LeakField
  var diagnostics: Diagnostics
  var sourceBase: String?

  /// What FilmLightLab's engine checks before applying a saved model: sizes that match and values
  /// in range, so a damaged file is refused instead of read out of bounds.
  func validate() throws {
    let fail = DeskError.message("参考匹配参数损坏，请点击“开始去漏光”重新拟合。")
    func field(_ f: LeakField) -> Bool {
      f.width >= 2 && f.height >= 2 && f.width * f.height <= 5000 && f.values.count == f.width * f.height
        && f.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }
    let b = bilateral, n = b.width * b.height * b.depth
    guard kind == "hybrid-veil-bilateral-v9", scenePolicy.revision == 1, (0...1).contains(scenePolicy.nightWeight),
      tonePolicy == .hybrid, field(veilField), field(neutralField),
      neutralField.baseline?.count == 2, neutralField.baseline?.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) == true,
      grid.width >= 2, grid.height >= 2, grid.nodes.count == grid.width * grid.height * 12, grid.nodes.count <= 5000,
      grid.nodes.allSatisfy(\.isFinite), H.count == 8, H.allSatisfy(\.isFinite),
      b.width >= 2, b.height >= 2, b.depth >= 2, n <= 5000, b.range.count == 2, b.range.allSatisfy(\.isFinite), b.range[1] > b.range[0],
      b.amount.isFinite, (0...1).contains(b.amount), b.values.count == 3, b.values.allSatisfy({ $0.count == n && $0.allSatisfy(\.isFinite) }),
      strength.isFinite
    else { throw fail }
  }
}

// MARK: - Helpers

fileprivate func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
  let t = clamp((x - a) / (b - a))
  return t * t * (3 - 2 * t)
}
@inline(__always) fileprivate func luma(_ p: SIMD3<Double>) -> Double { 0.30 * p.x + 0.59 * p.y + 0.11 * p.z }
/// JavaScript's Math.round: halves round up.
@inline(__always) fileprivate func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }
/// The upper median, as FilmLightLab takes it.
fileprivate func median(_ values: [Double]) -> Double {
  values.isEmpty ? 0 : values.sorted()[values.count >> 1]
}
@inline(__always) fileprivate func floorInt(_ x: Double) -> Int { Int(x.rounded(.down)) }
@inline(__always) fileprivate func absMax(_ v: SIMD3<Double>) -> Double { max(abs(v.x), abs(v.y), abs(v.z)) }
/// `body` for every row at once, reading `input` and writing a new buffer of `count` samples.
fileprivate func eachRow(
  _ rows: Int, _ input: [UInt16], count: Int? = nil,
  _ body: (UnsafeBufferPointer<UInt16>, UnsafeMutableBufferPointer<UInt16>, Int) -> Void
) -> [UInt16] {
  var out = [UInt16](repeating: 0, count: count ?? input.count)
  input.withUnsafeBufferPointer { src in
    out.withUnsafeMutableBufferPointer { dst in
      let dst = dst
      DispatchQueue.concurrentPerform(iterations: rows) { y in body(src, dst, y) }
    }
  }
  return out
}

extension LeakRegion {
  /// How much of the region covers (x, y); a protection's falls to nothing at its edge.
  func weight(_ px: Double, _ py: Double, aspect: Double = 1, protection: Bool = false) -> Double {
    if enabled == false { return 0 }
    var d: Double
    if shape == "polygon" { return smooth(-0.002, 0.0025, Self.polygonDistance(px, py, points ?? [])) }
    if shape == "stroke" {
      d = .infinity
      let p = points ?? [], r = radius.flatMap { $0 == 0 ? nil : $0 } ?? 0.025
      for i in 0..<p.count {
        let a = p[i], b = p[min(i + 1, p.count - 1)]
        let dx = b[0] - a[0], dy = (b[1] - a[1]) / aspect, den = dx * dx + dy * dy
        let t = clamp(((px - a[0]) * dx + (py - a[1]) / aspect * dy) / (den == 0 ? 1 : den))
        d = min(d, hypot(px - a[0] - t * dx, (py - a[1]) / aspect - t * dy) / r)
      }
    } else {
      d = hypot(
        (px - (x ?? 0.5)) / max(0.004, rx.flatMap { $0 == 0 ? nil : $0 } ?? 0.15),
        (py - (y ?? 0.5)) / max(0.004, ry.flatMap { $0 == 0 ? nil : $0 } ?? 0.15))
    }
    if protection { return 1 - smooth(0.6, 1, d) }
    if gaussian == true { return d < 3 ? exp(-d * d) : 0 }
    return 1 - smooth(clamp(1 - (feather ?? 0.7), 0.05, 0.9), 1, d)
  }
  static func polygonDistance(_ x: Double, _ y: Double, _ points: [[Double]]) -> Double {
    var inside = false, d = Double.infinity
    var j = points.count - 1
    for i in 0..<points.count {
      let a = points[j], b = points[i]
      if (a[1] > y) != (b[1] > y) && x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0] { inside.toggle() }
      let dx = b[0] - a[0], dy = b[1] - a[1], den = dx * dx + dy * dy
      let t = clamp(((x - a[0]) * dx + (y - a[1]) * dy) / (den == 0 ? 1 : den))
      d = min(d, hypot(x - a[0] - t * dx, y - a[1] - t * dy))
      j = i
    }
    return inside ? d : -d
  }
  /// Where a protection can reach: outside this box its weight is nothing.
  func protectionBounds(aspect: Double) -> (x0: Double, x1: Double, y0: Double, y1: Double)? {
    switch shape {
    case "stroke":
      let p = points ?? [], r = radius.flatMap { $0 == 0 ? nil : $0 } ?? 0.025
      guard !p.isEmpty else { return nil }
      let xs = p.map { $0[0] }, ys = p.map { $0[1] }
      return (xs.min()! - r, xs.max()! + r, ys.min()! - r * aspect, ys.max()! + r * aspect)
    case "polygon": return nil
    default:
      let ex = max(0.004, rx.flatMap { $0 == 0 ? nil : $0 } ?? 0.15), ey = max(0.004, ry.flatMap { $0 == 0 ? nil : $0 } ?? 0.15)
      return ((x ?? 0.5) - ex, (x ?? 0.5) + ex, (y ?? 0.5) - ey, (y ?? 0.5) + ey)
    }
  }
}

// MARK: - Global colour, local regions (core)

extension LeakEngine {
  static func globalColor(_ p: SIMD3<Double>, _ params: LeakParams) -> SIMD3<Double> {
    let ev = params.exposure, t = params.temperature, g = params.tint, k = 1 + params.contrast / 100
    var q = p
    if ev != 0 || t != 0 || g != 0 {
      let shift = SIMD3(ev + t / 200, ev - g / 200, ev - t / 200)
      for c in 0..<3 { q[c] = pow(max(0, pow(p[c], 2.2) * pow(2, shift[c])), 1 / 2.2) }
    }
    if k != 1 {
      let y = luma(q), v = clamp(y, 0.00001, 0.99999), next = 1 / (1 + exp(-k * log(v / (1 - v))))
      q = q * next / (y == 0 ? 1 : y)
    }
    return q
  }
  /// The median of each channel in a small square around (x, y).
  static func sample(_ image: LeakImage, _ x: Double, _ y: Double, _ r: Double = 0.008) -> SIMD3<Double> {
    let w = image.width, h = image.height
    var a: [[Double]] = [[], [], []]
    let y0 = max(0, floorInt((y - r) * Double(h))), y1 = min(h, Int(((y + r) * Double(h)).rounded(.up)))
    let x0 = max(0, floorInt((x - r) * Double(w))), x1 = min(w, Int(((x + r) * Double(w)).rounded(.up)))
    if y0 < y1 && x0 < x1 {
      for yy in y0..<y1 { for xx in x0..<x1 { let p = image.rgb(yy * w + xx); for c in 0..<3 { a[c].append(p[c]) } } }
    }
    return SIMD3(median(a[0]), median(a[1]), median(a[2]))
  }

  /// The local regions' corrections over the picture, at most 900 cells across: fog to subtract
  /// (three channels) and a chroma weight with its target ratios (four). Nil when no region acts.
  struct RegionField { let width: Int, height: Int; var values: [Float] }
  static func compile(_ image: LeakImage, _ params: LeakParams, maxWidth: Int = 900) -> RegionField? {
    struct Active { var region: LeakRegion; var fog: SIMD3<Double>?; var ratios: SIMD3<Double>? }
    let regions: [Active] = params.regions.filter { $0.enabled != false }.compactMap { r in
      let src = globalColor(sample(image, r.x ?? 0.5, r.y ?? 0.5), params)
      let ref: SIMD3<Double>? = r.target.map { SIMD3($0[0], $0[1], $0[2]) }
        ?? r.ref.map { globalColor(sample(image, $0.x, $0.y), params) }
      guard ref != nil || r.fog != nil else { return nil }
      let y = ref.map(luma) ?? 1
      let fog = r.fog.map { SIMD3($0[0], $0[1], $0[2]) }
        ?? SIMD3((0..<3).map { pow(src[$0], 2.2) - pow(ref![$0], 2.2) })
      let ratios = r.ratios.map { SIMD3($0[0], $0[1], $0[2]) } ?? ref.map { $0 / (y == 0 ? 1 : y) }
      return Active(region: r, fog: fog, ratios: ratios)
    }
    guard !regions.isEmpty else { return nil }
    let W = min(maxWidth, image.width), H = max(2, Int(jsRound(Double(W) * Double(image.height) / Double(image.width))))
    let aspect = image.aspect
    var fields = [Float](repeating: 0, count: W * H * 7)
    for yy in 0..<H {
      for xx in 0..<W {
        let x = Double(xx) / Double(W - 1), y = Double(yy) / Double(H - 1), i = (yy * W + xx) * 7
        var protect = 0.0
        for r in params.protect { protect = max(protect, r.weight(x, y, aspect: aspect, protection: true)) }
        for a in regions {
          let r = a.region
          var w = r.weight(x, y, aspect: aspect) * (r.amount ?? 1) * (1 - protect)
          if let fade = r.yFade { w *= 1 - smooth(fade[0], fade[1], y) }
          if w < 1e-6 { continue }
          if r.mode == "fog", let fog = a.fog {
            for c in 0..<3 {
              var wc = w
              if let channelRy = r.channelRy, let rx = r.rx, let cx = r.x, let cy = r.y {
                wc = (r.amount ?? 1) * (1 - protect) * exp(-pow((x - cx) / rx, 2) - pow((y - cy) / channelRy[c], 2))
                if let fade = r.yFade { wc *= 1 - smooth(fade[0], fade[1], y) }
              }
              fields[i + c] = Float(Double(fields[i + c]) + wc * fog[c])
            }
          } else if let ratios = a.ratios {
            fields[i + 3] = Float(Double(fields[i + 3]) + w)
            for c in 0..<3 { fields[i + 4 + c] = Float(Double(fields[i + 4 + c]) + w * ratios[c]) }
          }
        }
      }
    }
    return RegionField(width: W, height: H, values: fields)
  }

  /// The global colour and the local regions applied to `image`.
  static func render(_ image: LeakImage, _ params: LeakParams, _ field: RegionField?) -> LeakImage {
    guard field != nil || params.hasGlobalColor else { return image }
    let w = image.width, h = image.height
    // A scene measured (revision 1) lets bright fog be corrected; without one, highlights are gated.
    let gated = params.protectHighlights && params.sceneInfo?.revision != 1
    let out = eachRow(h, image.data) { src, dst, y in renderRow(src, dst, y, w, h, field, params, gated) }
    return LeakImage(width: w, height: h, data: out)
  }
  /// The seven region values at a pixel, bilinearly from the field.
  @inline(__always) private static func fieldValues(_ field: RegionField, _ fx: Double, _ fy: Double) -> [Double] {
    let W = field.width, H = field.height, v = field.values
    let ix = min(W - 2, floorInt(fx)), iy = min(H - 2, floorInt(fy))
    let ax = fx - Double(ix), ay = fy - Double(iy)
    let i00 = (iy * W + ix) * 7, i01 = (iy * W + ix + 1) * 7, i10 = ((iy + 1) * W + ix) * 7, i11 = ((iy + 1) * W + ix + 1) * 7
    var f = [Double](repeating: 0, count: 7)
    for c in 0..<7 {
      let top: Double = (1 - ax) * Double(v[i00 + c]) + ax * Double(v[i01 + c])
      let bottom: Double = (1 - ax) * Double(v[i10 + c]) + ax * Double(v[i11 + c])
      f[c] = (1 - ay) * top + ay * bottom
    }
    return f
  }
  private static func renderRow(
    _ src: UnsafeBufferPointer<UInt16>, _ dst: UnsafeMutableBufferPointer<UInt16>, _ y: Int, _ w: Int, _ h: Int,
    _ field: RegionField?, _ params: LeakParams, _ gated: Bool
  ) {
    let none = [Double](repeating: 0, count: 7)
    for x in 0..<w {
      let i = (y * w + x) * 3
      let f: [Double] = field.map { fieldValues($0, Double(x) / Double(w - 1) * Double($0.width - 1), Double(y) / Double(h - 1) * Double($0.height - 1)) } ?? none
      let p = globalColor(SIMD3(Double(src[i]), Double(src[i + 1]), Double(src[i + 2])) / 65535, params)
      let gate: Double = gated ? 1 - smooth(0.65, 0.94, p.max()) : 1
      var q = p
      for c in 0..<3 {
        let fog = f[c] * gate
        if abs(fog) < 1e-9 { continue }
        let e: Double = pow(max(0, p[c]), 2.2) - fog
        q[c] = pow(0.5 * (e + (e * e + 1e-8).squareRoot()), 1 / 2.2)
      }
      let a = clamp(f[3] * gate), l = luma(q)
      if a != 0 {
        for c in 0..<3 {
          let toward: Double = a * l * f[c + 4] / max(1e-9, f[3])
          q[c] = q[c] * (1 - a) + toward
        }
      }
      for c in 0..<3 { dst[i + c] = UInt16(jsRound(clamp(q[c]) * 65535)) }
    }
  }

  /// FilmLightLab's orientation and crop of the original.
  static func cropped(_ im: LeakImage, rotation: Int, crop c: LeakCrop) -> LeakImage {
    let rot = ((rotation % 360) + 360) % 360, swap = rot == 90 || rot == 270
    let W = swap ? im.height : im.width, H = swap ? im.width : im.height
    let left = Int(jsRound(clamp(c.x, 0, 0.98) * Double(W))), top = Int(jsRound(clamp(c.y, 0, 0.98) * Double(H)))
    let w = max(2, min(W - left, Int(jsRound(c.w * Double(W))))), h = max(2, min(H - top, Int(jsRound(c.h * Double(H)))))
    if rot == 0 && left == 0 && top == 0 && w == im.width && h == im.height { return im }
    let out = eachRow(h, im.data, count: w * h * 3) { src, dst, y in
      for x in 0..<w {
        let a = left + x, b = top + y
        var sx = a, sy = b
        switch rot {
        case 90: (sx, sy) = (b, im.height - 1 - a)
        case 180: (sx, sy) = (im.width - 1 - a, im.height - 1 - b)
        case 270: (sx, sy) = (im.width - 1 - b, a)
        default: break
        }
        let s = (sy * im.width + sx) * 3, d = (y * w + x) * 3
        dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]
      }
    }
    return LeakImage(width: w, height: h, data: out)
  }
}

// MARK: - Scene (day or night)

extension LeakEngine {
  static func statistics(_ image: LeakImage) -> LeakScene.Stats {
    var values = [Double](), dark = 0.0, bright = 0.0
    let stride = max(1, image.count / 25000)
    var i = 0
    while i < image.count {
      let v = luma(image.rgb(i))
      values.append(v)
      if v < 0.18 { dark += 1 }
      if v > 0.7 { bright += 1 }
      i += stride
    }
    values.sort()
    let n = Double(values.count)
    return .init(median: values[values.count >> 1], p80: values[floorInt(n * 0.8)], dark: dark / n, bright: bright / n)
  }
  static func daylight(_ s: LeakScene.Stats) -> Double {
    clamp(0.65 * smooth(0.24, 0.49, s.median) + 0.25 * (1 - smooth(0.12, 0.55, s.dark)) + 0.1 * smooth(0.01, 0.16, s.bright))
  }
  static func analyzeScene(_ source: LeakImage, _ target: LeakImage?, mode: String) throws -> LeakScene {
    guard ["auto", "day", "night"].contains(mode) else { throw DeskError.message("场景必须为自动、白天或夜晚。") }
    let original = statistics(source), reference = target.map(statistics)
    // A stained night picture can look bright; the clean reference is a second exposure cue.
    let score = reference.map { 0.7 * daylight($0) + 0.3 * daylight(original) } ?? daylight(original)
    let night = mode == "night" ? 1 : mode == "day" ? 0 : 1 - score
    let type = night > 0.65 ? "night" : night < 0.35 ? "day" : "mixed"
    let label = ["day": "白天 / 自然光", "night": "夜晚 / 点光源", "mixed": "黄昏 / 混合光"][type]!
    return LeakScene(
      requested: mode, type: type, label: label, nightWeight: night,
      confidence: mode == "auto" ? abs(score - 0.5) * 2 : 1, original: original, reference: reference)
  }
  /// Detected lamps kept by the scene: compact ones always at night; in daylight only with a
  /// compact red signal of their own, so surf, clouds and reflections are not taken for lamps.
  static func filterProtection(_ protect: [LeakRegion], _ scene: LeakScene) -> [LeakRegion] {
    protect.filter { r in
      guard r.name == "高光 / 红晕" else { return true }
      let aspect = r.aspectRatio ?? 1
      guard aspect < 3.2 && aspect > 1 / 3.2 && (r.fillRatio ?? 1) > 0.18 else { return false }
      if scene.nightWeight > 0.65 { return true }
      return (r.redSignal ?? 0) > 0.035 - 0.02 * scene.nightWeight
    }
  }
}

// MARK: - Detection: candidate leaks, lamps and small red objects

extension LeakEngine {
  struct Detection {
    var regions: [LeakRegion]
    var protect: [LeakRegion]
    var baseline: Double
    var threshold: Double
    var message: String
  }
  /// A box blur of radius `r`, rows then columns, as FilmLightLab's (single-precision values).
  static func boxBlur(_ a: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
    var t = [Float](repeating: 0, count: a.count), o = [Float](repeating: 0, count: a.count)
    let n = Double(2 * r + 1)
    for y in 0..<h {
      for x in 0..<w {
        var s = 0.0
        for k in -r...r { s += Double(a[y * w + min(w - 1, max(0, x + k))]) }
        t[y * w + x] = Float(s / n)
      }
    }
    for y in 0..<h {
      for x in 0..<w {
        var s = 0.0
        for k in -r...r { s += Double(t[min(h - 1, max(0, y + k)) * w + x]) }
        o[y * w + x] = Float(s / n)
      }
    }
    return o
  }
  /// Four-connected runs of equal non-zero labels, each in the order it was flooded.
  static func components(_ mask: [UInt8], _ w: Int, _ h: Int) -> [[Int]] {
    var seen = [Bool](repeating: false, count: mask.count), out = [[Int]]()
    for i in 0..<mask.count where mask[i] != 0 && !seen[i] {
      var queue = [i], at = 0
      seen[i] = true
      while at < queue.count {
        let p = queue[at], x = p % w
        at += 1
        for k in [-1, 1, -w, w] {
          let n = p + k
          if n < 0 || n >= mask.count || seen[n] || mask[n] != mask[i] || (k == -1 && x == 0) || (k == 1 && x == w - 1) { continue }
          seen[n] = true
          queue.append(n)
        }
      }
      out.append(queue)
    }
    return out
  }
  static func detect(_ image: LeakImage, sensitivity: Double = 0.5) -> Detection {
    let w = image.width, h = image.height, n = w * h
    var red = [Float](repeating: 0, count: n), light = [Float](repeating: 0, count: n), rgb = [Float](repeating: 0, count: n * 3)
    var base = [Double]()
    for i in 0..<n {
      let p = image.rgb(i)
      for c in 0..<3 { rgb[i * 3 + c] = Float(p[c]) }
      red[i] = Float(log((p.x + 0.025) / (p.y + 0.025)))
      light[i] = Float(luma(p))
      let x = Double(i % w) / Double(w), y = Double(i / w) / Double(h), l = Double(light[i])
      if x > 0.22 && x < 0.78 && y > 0.25 && l > 0.06 && l < 0.75 { base.append(Double(red[i])) }
    }
    let baseline = median(base.isEmpty ? red.map(Double.init) : base)
    let mad = median(base.map { abs($0 - baseline) })
    let threshold = baseline + max(0.17, 0.9 * mad) + (1 - sensitivity) * 0.20
    let smoothed = boxBlur(red, w, h, max(3, Int(jsRound(Double(w) * 0.025))))
    var labels = [UInt8](repeating: 0, count: n)
    for i in 0..<n where Double(smoothed[i]) > threshold && Double(light[i]) > 0.025 && Double(light[i]) < 0.8 {
      labels[i] = Double(light[i]) < 0.24 ? 1 : 2
    }
    let selected = components(labels, w, h).enumerated().filter { Double($0.element.count) / Double(n) > 0.004 }
      .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
      .prefix(6).map(\.element)
    var regions = [LeakRegion]()
    for pts in selected {
      var sx = 0, sy = 0, minx = w, miny = h, maxx = 0, maxy = 0, excess = 0.0
      for i in pts {
        let x = i % w, y = i / w
        sx += x; sy += y
        minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
        excess += Double(smoothed[i]) - threshold
      }
      let cx = Double(sx) / Double(pts.count) / Double(w), cy = Double(sy) / Double(pts.count) / Double(h)
      let edge = Double(minx) < Double(w) * 0.08 || Double(maxx) > Double(w) * 0.92 || Double(miny) < Double(h) * 0.08 || Double(maxy) > Double(h) * 0.92
      if !edge && Double(pts.count) / Double(n) < 0.015 { continue }
      if Double(maxx - minx) / Double(w) < 0.035 || Double(maxy - miny) / Double(h) < 0.035 { continue }
      let src = sample(image, cx, cy, 0.015)
      var ref: LeakPoint?, best = Double.infinity
      var yy = 4
      while yy < h - 4 {
        var xx = 4
        while xx < w - 4 {
          let i = yy * w + xx
          if labels[i] == 0 && Double(smoothed[i]) <= baseline + 0.09 && Double(light[i]) >= 0.04 && Double(light[i]) <= 0.8 {
            let distance = hypot(Double(xx) / Double(w) - cx, Double(yy) / Double(h) - cy)
            let colorDistance = abs(Double(rgb[i * 3 + 2]) - src.z) * 3 + abs(Double(rgb[i * 3 + 1]) - src.y) * 1.2
            let score = distance * 0.4 + colorDistance
            if score < best { best = score; ref = LeakPoint(x: Double(xx) / Double(w), y: Double(yy) / Double(h)) }
          }
          xx += 3
        }
        yy += 3
      }
      guard let ref else { continue }
      regions.append(LeakRegion(
        id: UUID().uuidString.lowercased(), name: "自动区域 \(regions.count + 1)", shape: "ellipse", mode: "chroma", x: cx, y: cy,
        rx: clamp(Double(maxx - minx) / Double(w) * 0.62, 0.045, 0.6), ry: clamp(Double(maxy - miny) / Double(h) * 0.62, 0.045, 0.6),
        amount: 0.70, feather: 0.8, ref: ref, enabled: true,
        confidence: edge && excess / Double(pts.count) > 0.22 ? "较高" : "建议复核", detected: true))
    }
    var highlights = [UInt8](repeating: 0, count: n), reds = [UInt8](repeating: 0, count: n)
    let nearLight = boxBlur(light, w, h, max(3, Int(jsRound(Double(w) * 0.025))))
    let nearRed = boxBlur(red, w, h, max(4, Int(jsRound(Double(w) * 0.035))))
    for i in 0..<n {
      let r = Double(rgb[i * 3]), g = Double(rgb[i * 3 + 1]), b = Double(rgb[i * 3 + 2])
      if max(r, g, b) > 0.43 && Double(light[i]) > 0.28 && Double(light[i]) - Double(nearLight[i]) > 0.10 { highlights[i] = 1 }
      if r > 0.18 && r > (g + 0.015) * 1.45 && Double(red[i]) - Double(nearRed[i]) > 0.32 { reds[i] = 1 }
    }
    var protect = [LeakRegion]()
    for (mask, kind) in [(highlights, "高光 / 红晕"), (reds, "小型红色物体")] {
      let lamp = kind == "高光 / 红晕"
      for p in components(mask, w, h) {
        if p.count < (lamp ? 1 : 2) || Double(p.count) / Double(n) > (lamp ? 0.008 : 0.0025) { continue }
        var sx = 0, sy = 0, minx = w, miny = h, maxx = 0, maxy = 0
        for i in p {
          let x = i % w, y = i / w
          sx += x; sy += y
          minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
        }
        if Double(maxx - minx) / Double(w) > 0.09 || Double(maxy - miny) / Double(h) > 0.09 { continue }
        let cx = Double(sx) / Double(p.count), cy = Double(sy) / Double(p.count)
        let channel = lamp ? light : red
        var peak = -Double.infinity
        for i in p { peak = max(peak, Double(channel[i])) }
        var ring = (0..<16).map { k -> Double in
          let a = Double(k) * .pi / 8
          let xx = Int(clamp(jsRound(cx + cos(a) * Double(w) * 0.02), 0, Double(w - 1)))
          let yy = Int(clamp(jsRound(cy + sin(a) * Double(w) * 0.02), 0, Double(h - 1)))
          return Double(channel[yy * w + xx])
        }
        ring.sort()
        if peak - ring[12] < (lamp ? 0.085 : 0.24) { continue }
        if protect.contains(where: { hypot(($0.x ?? 0) - cx / Double(w), (($0.y ?? 0) - cy / Double(h)) * Double(h) / Double(w)) < 0.014 }) { continue }
        if protect.count >= 28 { break }
        let background = (0..<3).map { c in
          median((0..<24).map { k -> Double in
            let a = Double(k) * .pi / 12
            let xx = Int(clamp(jsRound(cx + cos(a) * Double(w) * 0.025), 0, Double(w - 1)))
            let yy = Int(clamp(jsRound(cy + sin(a) * Double(w) * 0.025), 0, Double(h - 1)))
            return Double(rgb[(yy * w + xx) * 3 + c])
          })
        }
        var redSignal = 0.0
        for i in p {
          let d = (0..<3).map { max(0, Double(rgb[i * 3 + $0]) - background[$0]) }
          redSignal = max(redSignal, d[0] - 0.5 * (d[1] + d[2]))
        }
        let fw = Double(w), fh = Double(h)
        protect.append(LeakRegion(
          id: UUID().uuidString.lowercased(), name: kind, shape: "ellipse",
          x: Double(sx) / Double(p.count) / fw, y: Double(sy) / Double(p.count) / fh,
          rx: max(0.014, Double(maxx - minx) / fw * 0.8 + 0.008), ry: max(0.014 * fw / fh, Double(maxy - miny) / fh * 0.8 + 0.008 * fw / fh),
          enabled: true, background: background,
          aspectRatio: Double(maxx - minx + 1) / Double(maxy - miny + 1),
          fillRatio: Double(p.count) / Double((maxx - minx + 1) * (maxy - miny + 1)), areaFraction: Double(p.count) / Double(n),
          redSignal: redSignal))
      }
    }
    return Detection(
      regions: regions, protect: protect, baseline: baseline, threshold: threshold,
      message: regions.isEmpty ? "没有找到足够可靠的大范围漏光。可调高灵敏度或手动画区域。" : "发现 \(regions.count) 个候选区域；请检查参考点及真实红色物体。")
  }

  /// The parameters a fit starts from: the scene measured, suggested leak regions left off until
  /// approved, and the scene's lamp protections in place of earlier detected ones.
  static func prepare(base: LeakImage, params input: LeakParams, target: LeakImage?) throws -> LeakParams {
    var params = input
    let small = resized(base, width: 320)
    let scene = try analyzeScene(small, target, mode: params.sceneMode)
    params.sceneInfo = scene
    let detection = detect(small, sensitivity: 0.5)
    params.regions = params.regions.map { r in
      var r = r
      if r.detected == true && r.approved != true { r.enabled = false }
      return r
    }
    let detected = filterProtection(detection.protect, scene).map { r -> LeakRegion in
      var r = r
      r.detected = true
      return r
    }
    params.protect = Array((params.protect.filter { $0.detected != true } + detected).prefix(80))
    return params
  }

  /// Detected protections the reference disagrees with are dropped: a lamp must still stand out
  /// there. Hand-drawn ones always stay; reference pixels are never copied.
  static func refineProtection(_ params: inout LeakParams, target: LeakImage, model: LeakModel) {
    func at(_ x: Double, _ y: Double) -> SIMD3<Double> {
      let (u, v) = point(model.H, x, y)
      return target.at(u, v)
    }
    params.protect = params.protect.filter { r in
      guard r.detected == true, let rx = r.x, let ry = r.y else { return true }
      let isLight = r.name == "高光 / 红晕"
      func value(_ p: SIMD3<Double>) -> Double { isLight ? luma(p) : log((p.x + 0.025) / (p.y + 0.025)) }
      let ring = (0..<24).map { k -> Double in
        let a = Double(k) * .pi / 12
        return value(at(rx + cos(a) * 0.025, ry + sin(a) * 0.025 * Double(target.width) / Double(target.height)))
      }
      var peak = -Double.infinity
      for y in -2...2 { for x in -2...2 { peak = max(peak, value(at(rx + Double(x) * 0.003, ry + Double(y) * 0.003))) } }
      return peak - median(ring) > (isLight ? 0.075 : 0.20)
    }
  }
}

// MARK: - Alignment

extension LeakEngine {
  static let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0]
  @inline(__always) static func point(_ H: [Double], _ x: Double, _ y: Double) -> (Double, Double) {
    let d = H[6] * x + H[7] * y + 1
    return ((H[0] * x + H[1] * y + H[2]) / d, (H[3] * x + H[4] * y + H[5]) / d)
  }
  static func mapping(_ rotation: Int = 0, _ scale: Double = 1, _ dx: Double = 0, _ dy: Double = 0) -> [Double] {
    let a = (1 - scale) / 2 + dx, b = (1 - scale) / 2 + dy
    switch rotation {
    case 90: return [0, scale, b, -scale, 0, 1 - a, 0, 0]
    case 180: return [-scale, 0, 1 - a, 0, -scale, 1 - b, 0, 0]
    case 270: return [0, -scale, 1 - b, scale, 0, a, 0, 0]
    default: return [scale, 0, a, 0, scale, b, 0, 0]
    }
  }
  /// Gauss–Jordan with partial pivoting; a degenerate system is refused.
  static func solve(_ A: [[Double]], _ b: [Double]) throws -> [Double] {
    var a = A.enumerated().map { $0.element + [b[$0.offset]] }
    let n = b.count
    for k in 0..<n {
      var p = k
      for i in (k + 1)..<n where abs(a[i][k]) > abs(a[p][k]) { p = i }
      a.swapAt(p, k)
      let d = a[k][k]
      if abs(d) < 1e-10 { throw DeskError.message("对齐点退化，请分散选择四个角附近的点。") }
      for j in k...n { a[k][j] /= d }
      for i in 0..<n where i != k {
        let v = a[i][k]
        for j in k...n { a[i][j] -= v * a[k][j] }
      }
    }
    return a.map { $0[n] }
  }
  static func homography(_ pairs: [LeakPair]) throws -> [Double] {
    guard pairs.count >= 4 else { return identity }
    var A = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8), b = [Double](repeating: 0, count: 8)
    for pair in pairs {
      let x = pair.source[0], y = pair.source[1], u = pair.target[0], v = pair.target[1]
      for (f, t) in [([x, y, 1, 0, 0, 0, -u * x, -u * y], u), ([0, 0, 0, x, y, 1, -v * x, -v * y], v)] {
        for i in 0..<8 {
          b[i] += f[i] * t
          for j in 0..<8 { A[i][j] += f[i] * f[j] }
        }
      }
    }
    return try solve(A, b)
  }
  /// The reference's orientation and placement on the original, by correlating their edges:
  /// a quarter turn first, then scale and shift, then a fine fit.
  static func align(_ source: LeakImage, _ target: LeakImage) -> LeakAlignment {
    func gray(_ im: LeakImage, _ x: Double, _ y: Double) -> Double {
      let i = im.index(x, y) * 3
      return log(0.03 + (0.75 * Double(im.data[i + 1]) + 0.25 * Double(im.data[i + 2])) / 65535)
    }
    var samples = [(x: Double, y: Double, gx: Double, gy: Double)]()
    var y = 0.07
    while y < 0.94 {
      var x = 0.07
      while x < 0.94 {
        let gx = gray(source, x + 0.007, y) - gray(source, x - 0.007, y), gy = gray(source, x, y + 0.010) - gray(source, x, y - 0.010)
        if hypot(gx, gy) > 0.025 { samples.append((x, y, clamp(gx, -0.4, 0.4), clamp(gy, -0.4, 0.4))) }
        x += 0.025
      }
      y += 0.025
    }
    func score(_ H: [Double]) -> Double {
      var ab = 0.0, aa = 0.0, bb = 0.0, n = 0
      for s in samples {
        let uv = point(H, s.x, s.y)
        if uv.0 < 0.03 || uv.1 < 0.03 || uv.0 > 0.97 || uv.1 > 0.97 { continue }
        let a = point(H, s.x + 0.007, s.y), b = point(H, s.x - 0.007, s.y), c = point(H, s.x, s.y + 0.010), d = point(H, s.x, s.y - 0.010)
        let gx = clamp(gray(target, a.0, a.1) - gray(target, b.0, b.1), -0.4, 0.4)
        let gy = clamp(gray(target, c.0, c.1) - gray(target, d.0, d.1), -0.4, 0.4)
        ab += gx * s.gx + gy * s.gy
        aa += s.gx * s.gx + s.gy * s.gy
        bb += gx * gx + gy * gy
        n += 1
      }
      return n < 20 ? 0 : ab / (aa * bb == 0 ? 1 : (aa * bb).squareRoot())
    }
    var best = LeakAlignment(H: mapping(), rotation: 0, scale: 1, dx: 0, dy: 0, score: -.infinity, method: "green-edge-correlation", reliable: false)
    for rotation in [0, 90, 180, 270] {
      let H = mapping(rotation), s = score(H)
      if s > best.score { best = LeakAlignment(H: H, rotation: rotation, scale: 1, dx: 0, dy: 0, score: s, method: best.method, reliable: false) }
    }
    if best.score > 0.1 {
      let rotation = best.rotation
      for scale in [0.96, 0.98, 1, 1.02, 1.04] {
        for iy in -4...4 {
          for ix in -4...4 {
            let dx = Double(ix) * 0.01, dy = Double(iy) * 0.01, H = mapping(rotation, scale, dx, dy)
            let s = score(H) - 0.015 * (abs(dx) + abs(dy) + abs(scale - 1))
            if s > best.score + 0.002 {
              best = LeakAlignment(H: H, rotation: rotation, scale: scale, dx: dx, dy: dy, score: s, method: best.method, reliable: false)
            }
          }
        }
      }
    }
    if best.score > 0.25 {
      let base = best.H
      var fine = [1.0, 1, 0, 0]
      func transform(_ p: [Double]) -> [Double] {
        [p[0] * base[0], p[0] * base[1], p[0] * base[2] + (1 - p[0]) / 2 + p[2],
         p[1] * base[3], p[1] * base[4], p[1] * base[5] + (1 - p[1]) / 2 + p[3], 0, 0]
      }
      var value = score(base)
      for step in [0.003, 0.001, 0.0004] {
        for _ in 0..<2 {
          for k in 0..<4 {
            var next = fine[k], nextValue = value
            for sign in [-1.0, 1] {
              var p = fine
              p[k] += sign * step
              if abs(p[k] - (k < 2 ? 1 : 0)) > (k < 2 ? 0.015 : 0.012) { continue }
              let v = score(transform(p))
              if v > nextValue + 0.00005 { nextValue = v; next = p[k] }
            }
            fine[k] = next
            value = nextValue
          }
        }
      }
      if value > score(base) + 0.0005 {
        best.H = transform(fine)
        best.score = value
        best.fine = .init(scaleX: fine[0], scaleY: fine[1], dx: fine[2], dy: fine[3])
      }
    }
    if !best.score.isFinite || best.score < 0.08 {
      best = LeakAlignment(H: mapping(), rotation: 0, scale: 1, dx: 0, dy: 0, score: 0, method: best.method, reliable: false)
    }
    best.reliable = best.score > 0.25
    return best
  }
}

// MARK: - Fitting the reference (colour transfer, residual lattice, veils)

extension LeakEngine {
  struct Sample {
    var x: Double, y: Double
    /// The original's RGB and a 1, for an affine fit.
    var a: SIMD4<Double>
    var b: SIMD3<Double>
    var w: Double
    var index = 0
    var q = SIMD3<Double>(repeating: 0)
    var d = SIMD3<Double>(repeating: 0)
    var rgb: SIMD3<Double> { SIMD3(a.x, a.y, a.z) }
  }
  /// Pairs of smooth, unclipped original and reference colours on a fine grid.
  static func collect(_ source: LeakImage, _ target: LeakImage, _ H: [Double]) -> [Sample] {
    var samples = [Sample]()
    var y = 0.008
    while y < 0.999 {
      var x = 0.008
      while x < 0.999 {
        defer { x += 0.009 }
        let uv = point(H, x, y)
        if uv.0 < 0 || uv.0 > 1 || uv.1 < 0 || uv.1 > 1 { continue }
        let a = source.at(x, y), b = target.at(uv.0, uv.1)
        if a.max() > 0.98 || b.max() > 0.98 { continue }
        let a2 = source.at(x + 0.005, y + 0.005), uv2 = point(H, x + 0.005, y + 0.005), b2 = target.at(uv2.0, uv2.1)
        let edge = max(absMax(a - a2), absMax(b - b2))
        if edge > 0.1 { continue }
        samples.append(Sample(x: x, y: y, a: SIMD4(a, 1), b: b, w: 1 / (1 + edge * 20)))
      }
      y += 0.009
    }
    return samples
  }
  @inline(__always) static func gridCoefficients(_ grid: LeakModel.Grid, _ nodes: [SIMD16<Double>], _ x: Double, _ y: Double) -> SIMD16<Double> {
    let W = grid.width, H = grid.height
    let fx = clamp(x) * Double(W - 1), fy = clamp(y) * Double(H - 1)
    let ix = min(W - 2, floorInt(fx)), iy = min(H - 2, floorInt(fy)), ax = fx - Double(ix), ay = fy - Double(iy)
    return (1 - ay) * ((1 - ax) * nodes[iy * W + ix] + ax * nodes[iy * W + ix + 1])
      + ay * ((1 - ax) * nodes[(iy + 1) * W + ix] + ax * nodes[(iy + 1) * W + ix + 1])
  }
  static func packed(_ grid: LeakModel.Grid) -> [SIMD16<Double>] {
    (0..<(grid.width * grid.height)).map { n in
      var v = SIMD16<Double>(repeating: 0)
      for c in 0..<12 { v[c] = grid.nodes[n * 12 + c] }
      return v
    }
  }
  @inline(__always) static func affine(_ k: SIMD16<Double>, _ c: Int, _ a: SIMD4<Double>) -> Double {
    0 + a.x * k[c * 4] + a.y * k[c * 4 + 1] + a.z * k[c * 4 + 2] + a.w * k[c * 4 + 3]
  }

  /// Per cell of a coarse grid, for each channel, a robust affine fit from the original's RGB to
  /// the reference's, over the samples nearby.
  static func fitGrid(_ source: LeakImage, _ target: LeakImage, pairs: [LeakPair], scene: LeakScene?)
    throws -> (grid: LeakModel.Grid, alignment: LeakAlignment, samples: Int, error: Double)
  {
    let alignment = pairs.count >= 4
      ? LeakAlignment(H: try homography(pairs), rotation: 0, score: 1, method: "manual-landmarks", reliable: true)
      : align(source, target)
    let samples = collect(source, target, alignment.H).enumerated().filter { $0.offset % 10 >= 2 }.map(\.element)
    guard samples.count >= 100 else { throw DeskError.message("有效参考样本不足，请检查方向、画幅和对齐。") }
    let aspect = source.aspect
    let W = max(3, min(21, floorInt((390 * aspect).squareRoot()))), H = max(3, min(120, Int(jsRound(Double(W) / aspect))))
    let sx = 0.035, sy = sx * aspect
    var nodes = [Double]()
    nodes.reserveCapacity(W * H * 12)
    let ridgeScale = scene.map { 1 + 0.35 * (1 - $0.nightWeight) } ?? 1
    for gy in 0..<H {
      for gx in 0..<W {
        let x = Double(gx) / Double(W - 1), y = Double(gy) / Double(H - 1)
        var local = [(s: Int, w: Double)]()
        for expansion in [1.0, 2, 4] {
          local = []
          for (i, s) in samples.enumerated() {
            let u = (s.x - x) / (sx * expansion), v = (s.y - y) / (sy * expansion)
            let w = s.w * exp(-0.5 * (u * u + v * v))
            if w > 0.003 { local.append((i, w)) }
          }
          if local.count >= 8 { break }
        }
        for c in 0..<3 {
          var m = SIMD4<Double>(repeating: 0)
          m[c] = 1
          for it in 0..<3 {
            var A = [[Double]](repeating: [0, 0, 0, 0], count: 4), b = [0.0, 0, 0, 0], sw = 0.0
            for (index, w) in local {
              let s = samples[index], target = s.b[c]
              let e = target - (0 + s.a.x * m.x + s.a.y * m.y + s.a.z * m.z + s.a.w * m.w)
              let k = w * (it > 0 ? min(1, 0.04 / max(0.001, abs(e))) : 1)
              sw += k
              for i in 0..<4 {
                b[i] += k * s.a[i] * target
                for j in 0..<4 { A[i][j] += k * s.a[i] * s.a[j] }
              }
            }
            if sw < 0.00001 { break }
            let ridge = sw * 0.0006 * ridgeScale
            for i in 0..<3 { A[i][i] += ridge }
            b[c] += ridge
            A[3][3] += 1e-7
            let solved = try solve(A, b)
            m = SIMD4(solved[0], solved[1], solved[2], solved[3])
          }
          nodes += [m.x, m.y, m.z, m.w]
        }
      }
    }
    let grid = LeakModel.Grid(width: W, height: H, nodes: nodes), packedNodes = packed(grid)
    var error = 0.0
    for s in samples {
      let k = gridCoefficients(grid, packedNodes, s.x, s.y)
      for c in 0..<3 { error += abs(affine(k, c, s.a) - s.b[c]) }
    }
    return (grid, alignment, samples.count, error / Double(samples.count) / 3)
  }

  // The residual lattice.
  @inline(__always) static func guide(_ p: SIMD3<Double>) -> Double { log(0.03 + 0.75 * p.y + 0.25 * p.z) }
  @inline(__always) static func corners(_ f: LeakBilateral, _ x: Double, _ y: Double, _ p: SIMD3<Double>, _ visit: (Int, Double) -> Void) {
    let W = f.width, H = f.height, D = f.depth
    let fx = clamp(x) * Double(W - 1), fy = clamp(y) * Double(H - 1)
    let fz = clamp((guide(p) - f.range[0]) / (f.range[1] - f.range[0])) * Double(D - 1)
    let ix = min(W - 2, floorInt(fx)), iy = min(H - 2, floorInt(fy)), iz = min(D - 2, floorInt(fz))
    let ax = fx - Double(ix), ay = fy - Double(iy), az = fz - Double(iz)
    for z in 0..<2 {
      for yy in 0..<2 {
        for xx in 0..<2 {
          visit(((iz + z) * H + iy + yy) * W + ix + xx, (xx == 1 ? ax : 1 - ax) * (yy == 1 ? ay : 1 - ay) * (z == 1 ? az : 1 - az))
        }
      }
    }
  }
  static func sample(_ f: LeakBilateral, _ cells: [SIMD3<Double>], _ x: Double, _ y: Double, _ p: SIMD3<Double>, amount: Double? = nil) -> SIMD3<Double> {
    var out = SIMD3<Double>(repeating: 0)
    corners(f, x, y, p) { i, w in out += w * cells[i] }
    return out * (amount ?? f.amount)
  }
  static func cells(_ f: LeakBilateral) -> [SIMD3<Double>] {
    (0..<f.values[0].count).map { SIMD3(f.values[0][$0], f.values[1][$0], f.values[2][$0]) }
  }
  static func latticeBlur(_ input: [Double], _ W: Int, _ H: Int, _ D: Int) -> [Double] {
    var a = input
    for (stride, dim, range) in [(1, W, false), (W, H, false), (W * H, D, true)] {
      var out = [Double](repeating: 0, count: a.count)
      let center = range ? 8.0 : 2
      for i in 0..<a.count {
        let at = (i / stride) % dim, lo = at > 0 ? i - stride : i, hi = at < dim - 1 ? i + stride : i
        out[i] = (a[lo] + center * a[i] + a[hi]) / (center + 2)
      }
      a = out
    }
    return a
  }
  static func fitBilateral(_ samples: [Sample], aspect: Double, scene: LeakScene?) -> LeakBilateral {
    let sorted = samples.map { guide($0.rgb) }.sorted(), n = Double(sorted.count)
    let lo = sorted[floorInt(n * 0.005)], hi = sorted[floorInt(n * 0.995)], D = 8
    let W = max(3, min(28, floorInt((4600 * aspect / Double(D)).squareRoot())))
    let H = max(3, min(4800 / W / D, Int(jsRound(Double(W) / aspect))))
    let N = W * H * D
    let minSpan = scene?.revision == 1 ? 0.12 + 0.06 * (1 - scene!.nightWeight) : 0.12
    var field = LeakBilateral(width: W, height: H, depth: D, range: [lo, max(lo + minSpan, hi)],
      values: [[Double]](repeating: [Double](repeating: 0, count: N), count: 3), amount: 1)
    for iter in 0..<3 {
      let current = cells(field)
      var den = [Double](repeating: 0, count: N)
      var num = [[Double]](repeating: [Double](repeating: 0, count: N), count: 3)
      for s in samples {
        let prediction = iter > 0 ? sample(field, current, s.x, s.y, s.rgb) : SIMD3(repeating: 0)
        let error = absMax(s.d - prediction), robust = iter > 0 ? min(1, 0.12 / max(0.001, error)) : 1, w = s.w * robust
        corners(field, s.x, s.y, s.rgb) { i, k in
          den[i] += w * k
          for c in 0..<3 { num[c][i] += w * k * s.d[c] }
        }
      }
      // Normalized convolution fills unobserved cells without smoothing the original's pixels; weak
      // diffusion along the brightness axis limits leakage across materials.
      for _ in 0..<2 {
        den = latticeBlur(den, W, H, D)
        num = num.map { latticeBlur($0, W, H, D) }
      }
      field.values = num.map { a in a.indices.map { clamp(a[$0] / (den[$0] + 0.018), -0.55, 0.55) } }
    }
    return field
  }

  // Veils: how sure a leak is, and where the night's white edge fog is.
  static func leakEvidence(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let sa = a.x + a.y + a.z, sb = b.x + b.y + b.z
    if sa <= 0.003 || sb <= 0.003 { return 0 }
    // An exposure change alone keeps the chromatic fractions: a leak lowers red's share and red itself.
    return smooth(0.025, 0.18, a.x / sa - b.x / sb) * smooth(0.05, 0.5, (a.x - b.x) / (a.x + 0.03))
  }
  static func fitVeilField(_ samples: [Sample], _ W: Int, _ H: Int, aspect: Double) -> LeakField {
    var values = [Double]()
    let sx = 0.055, sy = sx * aspect
    for gy in 0..<H {
      for gx in 0..<W {
        let x = Double(gx) / Double(W - 1), y = Double(gy) / Double(H - 1)
        var value = 0.0, total = 0.0
        for s in samples {
          let dx = (s.x - x) / sx, dy = (s.y - y) / sy
          if abs(dx) > 3 || abs(dy) > 3 { continue }
          let w = s.w * exp(-0.5 * (dx * dx + dy * dy))
          value += w * leakEvidence(s.rgb, s.b)
          total += w
        }
        values.append(clamp(value / max(1e-9, total)))
      }
    }
    return LeakField(width: W, height: H, values: values)
  }
  /// The reference's overall exposure and colour, from the interior: a uniform exposure change is
  /// not a local white fog.
  static func neutralBaseline(_ samples: [Sample]) -> [[Double]] {
    let interior = samples.filter { $0.x > 0.18 && $0.x < 0.82 && $0.y > 0.18 && $0.y < 0.82 }
    let set = interior.count >= 40 ? interior : samples
    return [1, 2].map { c -> [Double] in
      var gain = 1.0, bias = 0.0
      for it in 0..<4 {
        var sw = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sab = 0.0
        for s in set {
          let a = s.a[c], b = s.b[c], err = b - (gain * a + bias), w = s.w * (it > 0 ? min(1, 0.04 / max(0.001, abs(err))) : 1)
          sw += w; sa += w * a; sb += w * b; saa += w * a * a; sab += w * a * b
        }
        if sw < 1e-9 { break }
        let variance = saa - sa * sa / sw
        if variance < sw * 1e-6 {
          gain = 1
          bias = (sb - sa) / sw
          break
        }
        gain = clamp((sab - sa * sb / sw) / variance, 0.1, 4)
        bias = clamp((sb - gain * sa) / sw, -0.5, 0.5)
      }
      return [gain, bias]
    }
  }
  static func neutralEvidence(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ baseline: [[Double]]) -> Double {
    let expected = [clamp(baseline[0][0] * a.y + baseline[0][1]), clamp(baseline[1][0] * a.z + baseline[1][1])]
    let lift = min(expected[0] - b.y, expected[1] - b.z)
    return smooth(0.025, 0.13, lift) * smooth(0.10, 0.38, lift / max(0.04, min(expected[0], expected[1])))
  }
  static func fitNeutralField(_ samples: [Sample], _ W: Int, _ H: Int, aspect: Double, scene: LeakScene?, policy p: LeakTonePolicy) -> LeakField {
    let night = smooth(p.neutralNightStart, p.neutralNightEnd, scene?.nightWeight ?? 0), baseline = neutralBaseline(samples)
    var values = [Double]()
    let sx = 0.04, sy = sx * aspect
    for gy in 0..<H {
      for gx in 0..<W {
        let x = Double(gx) / Double(W - 1), y = Double(gy) / Double(H - 1)
        let edge = 1 - smooth(p.neutralEdgeInner, p.neutralEdgeOuter, min(x, 1 - x, y, 1 - y))
        var sum = 0.0, total = 0.0
        if night * edge > 0 {
          for s in samples {
            let dx = (s.x - x) / sx, dy = (s.y - y) / sy
            if abs(dx) > 3 || abs(dy) > 3 { continue }
            let w = s.w * exp(-0.5 * (dx * dx + dy * dy))
            sum += w * neutralEvidence(s.rgb, s.b, baseline)
            total += w
          }
        }
        values.append(clamp(night * edge * sum / max(1e-9, total)))
      }
    }
    return LeakField(width: W, height: H, values: values, baseline: baseline)
  }

  /// Revision 9's model: a local RGB grid, a residual lattice whose strength is chosen on samples it
  /// was not fitted on, and the chromatic and neutral veil fields that set how far it may darken.
  /// `source` and `target` are the corrected original and the reference, blurred small previews.
  static func fitModel(_ source: LeakImage, _ target: LeakImage, pairs: [LeakPair] = [], scene: LeakScene) throws -> LeakModel {
    let policy = LeakTonePolicy.hybrid
    let (grid, alignment, count, _) = try fitGrid(source, target, pairs: pairs, scene: scene)
    let nodes = packed(grid)
    let all = collect(source, target, alignment.H).enumerated().map { i, s -> Sample in
      var s = s
      s.index = i
      let k = gridCoefficients(grid, nodes, s.x, s.y)
      s.q = SIMD3((0..<3).map { clamp(affine(k, $0, s.a)) })
      s.d = SIMD3((0..<3).map { clamp(log((s.b[$0] + 0.008) / (s.q[$0] + 0.008)), -0.7, 0.7) })
      return s
    }
    let training = all.filter { $0.index % 10 >= 2 }, calibration = all.filter { $0.index % 10 == 1 }, test = all.filter { $0.index % 10 == 0 }
    var field = fitBilateral(training, aspect: source.aspect, scene: scene)
    let fieldCells = cells(field)
    func errors(_ samples: [Sample], _ amount: Double?) -> LeakModel.Errors {
      var absolute = 0.0, logarithmic = 0.0
      for s in samples {
        let r = amount.map { sample(field, fieldCells, s.x, s.y, s.rgb, amount: $0) } ?? SIMD3(repeating: 0)
        for c in 0..<3 {
          let v = clamp((s.q[c] + 0.008) * exp(r[c]) - 0.008)
          absolute += abs(v - s.b[c])
          logarithmic += abs(log((v + 0.008) / (s.b[c] + 0.008)))
        }
      }
      let n = max(1, Double(samples.count * 3))
      return .init(rgb: absolute / n, logRGB: logarithmic / n)
    }
    var amount = 0.0, best = errors(calibration, nil).logRGB
    for a in [0.35, 0.65, 1] {
      let e = errors(calibration, a).logRGB
      if e < best * 0.995 { best = e; amount = a }
    }
    field.amount = amount
    let before = errors(test, nil), after = errors(test, amount)
    return LeakModel(
      grid: grid, H: alignment.H, alignment: alignment, samples: count, error: after.rgb,
      scenePolicy: scene, tonePolicy: policy, bilateral: field,
      veilField: fitVeilField(training, grid.width, grid.height, aspect: source.aspect),
      neutralField: fitNeutralField(training, grid.width, grid.height, aspect: source.aspect, scene: scene, policy: policy),
      diagnostics: .init(training: training.count, calibration: calibration.count, heldOut: test.count,
        heldOutBefore: before, heldOutAfter: after, residualAmount: amount))
  }
}

// MARK: - Tone: separating the leak's veil from the picture's light

extension LeakEngine {
  // Adobe RGB (1998) as FilmLightLab's bundled profile states it: a 563/256 gamma per channel and the
  // Y row of its (D50) colourants for luminance.
  static let gamma = 2.19921875
  static let weights: SIMD3<Double> = {
    let y = SIMD3(0.3111114501953125, 0.62567138671875, 0.0632171630859375)
    return y / (y.x + y.y + y.z)
  }()
  static let decodeTable: [Double] = (0...65535).map { pow(Double($0) / 65535, gamma) }
  @inline(__always) static func decode(_ p: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(decodeTable[Int(jsRound(clamp(p.x) * 65535))], decodeTable[Int(jsRound(clamp(p.y) * 65535))], decodeTable[Int(jsRound(clamp(p.z) * 65535))])
  }
  @inline(__always) static func luminance(_ p: SIMD3<Double>) -> Double { 0 + p.x * weights.x + p.y * weights.y + p.z * weights.z }

  struct ToneContext { var nightWeight = 0.0, leakConfidence = 0.0, emissive = 0.0, neutralConfidence = 0.0 }
  static func limits(_ Y: Double, _ p: LeakTonePolicy, _ c: ToneContext) -> (darken: Double, brighten: Double) {
    let night = clamp(c.nightWeight), leak = clamp(c.leakConfidence)
    let other = p.dayOtherDarkenEV * (1 - night) + p.nightOtherDarkenEV * night
    let cap = p.dayLeakDarkenEV * (1 - night) + p.nightLeakDarkenEV * night
    let headroom = (1 - smooth(p.highlightStart, p.highlightEnd, Y)) * (1 - clamp(c.emissive))
    let darken = (other + (cap - other) * leak) * headroom
    return (max(darken, p.neutralDarkenEV * clamp(c.neutralConfidence) * (1 - clamp(c.emissive))), p.maxBrightenEV * headroom)
  }
  /// The reference's colour at a luminance it may move to only within the limits; a colour outside
  /// the gamut is drawn toward neutral at that luminance through a smooth knee, never clipped.
  static func separate(_ source: SIMD3<Double>, _ predicted: SIMD3<Double>, _ p: LeakTonePolicy, _ context: ToneContext) -> SIMD3<Double> {
    let a = decode(source), b = decode(predicted), Y = luminance(a), Z = luminance(b)
    if Y <= 0 { return SIMD3(repeating: 0) }
    let bound = limits(Y, p, context)
    let ev = clamp(log2(max(1e-9, Z) / Y) * 1, -bound.darken, bound.brighten), target = clamp(Y * pow(2, ev))
    let color = Z > 1e-9 ? b : a, z = Z > 1e-9 ? Z : Y, q = color * target / z
    var capacity = Double.infinity
    for c in 0..<3 {
      let d = q[c] - target
      if d > 0 { capacity = min(capacity, (1 - target) / d) } else if d < 0 { capacity = min(capacity, -target / d) }
    }
    var saturation = min(1, capacity)
    if capacity > 0 && capacity < 4.0 / 3 {
      let usage = 1 / capacity
      saturation = capacity * (1 - 0.0625 / (usage - 0.5))
    }
    return SIMD3((0..<3).map { pow(clamp(target + saturation * (q[$0] - target)), 1 / gamma) })
  }
  /// A lamp's own light: how far a pixel stands above the median of its ring of neighbours.
  static func localEmission(_ src: UnsafeBufferPointer<UInt16>, _ w: Int, _ h: Int, _ xx: Int, _ yy: Int, _ Y: Double) -> Double {
    if Y < 0.08 { return 0 }
    let r = max(2, Int(jsRound(Double(w) * 0.012)))
    var values = [Double]()
    values.reserveCapacity(8)
    for (dx, dy) in [(-r, -r), (0, -r), (r, -r), (-r, 0), (r, 0), (-r, r), (0, r), (r, r)] {
      let x = xx + dx, y = yy + dy
      if x < 0 || x >= w || y < 0 || y >= h { continue }
      let i = (y * w + x) * 3
      values.append(luminance(decode(SIMD3(Double(src[i]), Double(src[i + 1]), Double(src[i + 2])) / 65535)))
    }
    if values.count < 3 { return 0 }
    values.sort()
    let delta = max(0, Y - values[values.count >> 1])
    return smooth(0.08, 0.25, delta) * smooth(0.15, 0.5, delta / max(1e-9, Y))
  }
}

// MARK: - Applying a model

extension LeakEngine {
  /// The fitted reference applied to `image`: its local colour corrections, held back where hand
  /// protection says, with detected lamps keeping their own light, and the veil limits on how far
  /// each pixel may darken. Strength 0 and full protection leave pixels exactly as they were.
  static func apply(_ image: LeakImage, _ model: LeakModel?, _ params: LeakParams) throws -> LeakImage {
    guard let model, model.strength != 0 else { return image }
    try model.validate()
    let applier = Applier(model: model, params: params, width: image.width, height: image.height)
    let out = eachRow(image.height, image.data) { src, dst, y in applier.row(src, dst, y) }
    return LeakImage(width: image.width, height: image.height, data: out)
  }
  private struct Lamp {
    var region: LeakRegion, x: Double, y: Double, rx: Double, ry: Double
    var background: SIMD3<Double>, backgroundY: Double
  }
  private struct Applier {
    let model: LeakModel, params: LeakParams, w: Int, h: Int, aspect: Double
    let manual: [LeakRegion]
    let bounds: [(x0: Double, x1: Double, y0: Double, y1: Double)?]
    let lamps: [Lamp]
    let nodes: [SIMD16<Double>]
    let lattice: [SIMD3<Double>]?
    init(model: LeakModel, params: LeakParams, width: Int, height: Int) {
      self.model = model
      self.params = params
      w = width
      h = height
      aspect = Double(width) / Double(height)
      manual = params.protect.filter { $0.detected != true }
      let aspect = self.aspect
      bounds = manual.map { $0.protectionBounds(aspect: aspect) }
      lamps = (params.protectHighlights ? params.protect : []).compactMap { r -> Lamp? in
        guard r.detected == true, r.enabled != false, let b = r.background, b.count == 3,
          let x = r.x, let y = r.y, let rx = r.rx, let ry = r.ry
        else { return nil }
        let background = SIMD3(b[0], b[1], b[2])
        return Lamp(region: r, x: x, y: y, rx: rx, ry: ry, background: background, backgroundY: luminance(decode(background)))
      }
      nodes = packed(model.grid)
      lattice = model.bilateral.amount != 0 ? cells(model.bilateral) : nil
    }
    /// The grid's affine coefficients at (x, y), scaled by the residual lattice for this colour.
    @inline(__always) func coefficients(_ x: Double, _ y: Double, _ p: SIMD3<Double>) -> SIMD16<Double> {
      var k = gridCoefficients(model.grid, nodes, x, y)
      guard let lattice else { return k }
      let r = sample(model.bilateral, lattice, x, y, p)
      for c in 0..<3 {
        let g = exp(r[c])
        for j in 0..<3 { k[c * 4 + j] *= g }
        k[c * 4 + 3] = (k[c * 4 + 3] + 0.008) * g - 0.008
      }
      return k
    }
    @inline(__always) func gains(_ k: SIMD16<Double>, _ c: Int, _ v: SIMD3<Double>) -> Double {
      let s: Double = 0 + v.x * k[c * 4] + v.y * k[c * 4 + 1]
      return s + v.z * k[c * 4 + 2]
    }
    func row(_ src: UnsafeBufferPointer<UInt16>, _ dst: UnsafeMutableBufferPointer<UInt16>, _ yy: Int) {
      let y = Double(yy) / Double(h - 1)
      let row = lamps.filter { abs(y - $0.y) < $0.ry }
      let rowManual = manual.indices.filter { i in bounds[i].map { y >= $0.y0 && y <= $0.y1 } ?? true }
      for xx in 0..<w {
        let x = Double(xx) / Double(w - 1), i = (yy * w + xx) * 3
        let p = SIMD3(Double(src[i]), Double(src[i + 1]), Double(src[i + 2])) / 65535
        var mask = 1.0
        for m in rowManual {
          if let b = bounds[m], x < b.x0 || x > b.x1 { continue }
          mask = min(mask, 1 - manual[m].weight(x, y, aspect: aspect, protection: true))
        }
        if model.onlyRegions {
          var region = 0.0
          for r in params.regions { region = max(region, r.weight(x, y, aspect: aspect)) }
          mask *= region
        }
        let a = clamp(model.strength * mask)
        if a == 0 {
          dst[i] = src[i]; dst[i + 1] = src[i + 1]; dst[i + 2] = src[i + 2]
          continue
        }
        let k = coefficients(x, y, p)
        var q = SIMD3<Double>(repeating: 0)
        for c in 0..<3 {
          let mapped: Double = k[c * 4 + 3] + gains(k, c, p)
          q[c] = p[c] + a * (mapped - p[c])
        }
        // A detected lamp keeps its own light above its surroundings, not the fog under it.
        var restore = SIMD3<Double>(repeating: 0), emissive = 0.0
        let neutral = model.neutralField.sample(x, y)
        let Y: Double = !row.isEmpty || neutral > 0.01 ? luminance(decode(p)) : 0
        for lamp in row where abs(x - lamp.x) < lamp.rx {
          let t = lamp.region.weight(x, y, aspect: aspect, protection: true)
          if t == 0 { continue }
          let d = simdMax(p - lamp.background, SIMD3(repeating: 0))
          for c in 0..<3 { restore[c] = max(restore[c], t * (d[c] - gains(k, c, d))) }
        }
        q += a * restore
        for lamp in row where abs(x - lamp.x) < lamp.rx {
          let t = lamp.region.weight(x, y, aspect: aspect, protection: true)
          emissive = max(emissive, t * smooth(0.15, 0.7, (Y - lamp.backgroundY) / max(1e-9, Y)))
        }
        if neutral > 0.01 && params.protectHighlights {
          let predicted = luminance(decode(q))
          emissive = max(emissive, localEmission(src, w, h, xx, yy, Y) * smooth(0.08, 0.25, predicted))
        }
        let context = ToneContext(
          nightWeight: model.scenePolicy.nightWeight, leakConfidence: model.veilField.sample(x, y), emissive: emissive, neutralConfidence: neutral)
        let value = separate(p, q, model.tonePolicy, context)
        for c in 0..<3 { dst[i + c] = UInt16(jsRound(value[c] * 65535)) }
      }
    }
  }

  /// FilmLightLab's “开始去漏光” with a reference: the scene and protections measured, the local
  /// regions applied, the model fitted on blurred 640 px previews, and the detected lamps checked
  /// against the reference. `guide` is the reference at 640 px across.
  static func fitReference(base: LeakImage, guide: LeakImage, params: LeakParams, pairs: [LeakPair] = [], baseID: String) throws -> LeakParams {
    var prepared = try prepare(base: base, params: params, target: guide)
    prepared.referenceModel = nil
    let corrected = render(base, prepared, compile(base, prepared))
    guard let scene = prepared.sceneInfo else { throw DeskError.message("无法判断场景。") }
    var model = try fitModel(
      resized(corrected, width: 640, blur: 3), resized(guide, width: 640, blur: 3), pairs: pairs, scene: scene)
    refineProtection(&prepared, target: guide, model: model)
    model.sourceBase = baseID
    prepared.referenceModel = model
    return prepared
  }
  /// The repaired picture: regions compiled on the base (they are resolution-free), then applied
  /// with the model to `image`, the base for a preview or the full-resolution original for export.
  static func result(_ image: LeakImage, base: LeakImage, params: LeakParams) throws -> LeakImage {
    let out = render(image, params, compile(base, params))
    return try apply(out, params.referenceModel, params)
  }
}

@inline(__always) fileprivate func simdMax(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
  SIMD3(max(a.x, b.x), max(a.y, b.y), max(a.z, b.z))
}
