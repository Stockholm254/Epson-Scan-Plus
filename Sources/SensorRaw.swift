import CoreGraphics
import Foundation

/// An uncompressed Sony ARW's sensor data, found in its TIFF structure: the mosaic's size, bit
/// depth, where it lies in the file, its 2 × 2 colour pattern, the black level of each position
/// and the white level. Nil for a compressed ARW, or anything else, which the system's RAW engine
/// decodes instead.
struct SensorRaw {
  var width: Int, height: Int, bits: Int
  var offset: Int
  /// The colour at (0, 0), (1, 0), (0, 1) and (1, 1) of each 2 × 2 cell: 0 red, 1 green, 2 blue.
  var pattern: [Int]
  /// The black level at each of those four positions.
  var black: [Int]
  var white: Int
  /// The TIFF orientation the camera recorded (1 upright, 6 a quarter clockwise, 3, 8).
  var orientation: Int

  init?(_ data: Data) {
    guard data.count > 16, data[0] == 0x49, data[1] == 0x49, data[2] == 0x2A, data[3] == 0 else { return nil }
    func u16(_ at: Int) -> Int { at + 2 <= data.count ? Int(data[at]) | Int(data[at + 1]) << 8 : 0 }
    func u32(_ at: Int) -> Int { at + 4 <= data.count ? u16(at) | u16(at + 2) << 16 : 0 }
    /// A directory's entries by tag: each one's values, SHORT, LONG and BYTE alike, inline or not.
    func directory(_ at: Int) -> [Int: [Int]] {
      let n = u16(at)
      guard n > 0, n < 1000, at + 2 + 12 * n <= data.count else { return [:] }
      var tags = [Int: [Int]]()
      for i in 0..<n {
        let e = at + 2 + 12 * i
        let tag = u16(e), type = u16(e + 2), count = u32(e + 4)
        let size = [1: 1, 3: 2, 4: 4, 7: 1][type] ?? 0
        guard size > 0, count > 0, count <= 64 else { continue }
        let base = size * count <= 4 ? e + 8 : u32(e + 8)
        tags[tag] = (0..<count).map { k in size == 1 ? Int(data[min(data.count - 1, base + k)]) : size == 2 ? u16(base + 2 * k) : u32(base + 4 * k) }
      }
      return tags
    }
    let first = directory(u32(4))
    let candidates = [first] + (first[0x14A] ?? []).map(directory)
    guard
      let ifd = candidates.first(where: { $0[0x106]?.first == 32803 && $0[0x103]?.first == 1 }),
      let w = ifd[0x100]?.first, let h = ifd[0x101]?.first, let b = ifd[0x102]?.first, (12...16).contains(b),
      w >= 2, h >= 2, w % 2 == 0, h % 2 == 0,
      ifd[0x828D] == [2, 2], let p = ifd[0x828E], p.count == 4, p.allSatisfy({ (0...2).contains($0) }), Set(p) == [0, 1, 2],
      let strips = ifd[0x111], strips.count == 1, let bytes = ifd[0x117]?.first, bytes == w * h * 2,
      strips[0] + bytes <= data.count
    else { return nil }
    width = w; height = h; bits = b; offset = strips[0]; pattern = p
    // Sony's own black-level tag, else the DNG one; without either it is not known well enough.
    guard let levels = ifd[0x7310] ?? ifd[0xC61A], !levels.isEmpty else { return nil }
    let blacks = levels.count >= 4 ? Array(levels.prefix(4)) : Array(repeating: levels[0], count: 4)
    let top = ifd[0xC61D]?.first ?? (1 << b) - 1
    guard blacks.allSatisfy({ $0 < top }) else { return nil }
    black = blacks; white = top
    orientation = first[0x112]?.first ?? 1
  }

  /// The sensor at its full resolution in its own colours: each photosite keeps what it measured,
  /// less the black level and scaled to the white, and the two colours it did not measure come
  /// from its neighbours along edges rather than across them. Green first, as Hamilton and Adams
  /// (1997) interpolate it, from the direction that changes least, here weighted between the two
  /// by how flat each is; then red and blue from their differences to green, which change slowly
  /// across an edge where the colours themselves do not. On fine detail it makes much less false
  /// colour than Malvar, He and Cutler's linear filter, which this app used before: on a zone plate
  /// the colour error is 3.6 dB lower, on a film frame made into a mosaic it is as close or closer,
  /// in the same time. No white balance and no colour matrix: each channel is what its colour of
  /// light made, which a negative lit by red, green and blue lights needs. 16 bits linear, upright
  /// as the camera was held.
  static func nativeRGB(_ url: URL) throws -> CGImage? {
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    guard let raw = SensorRaw(data) else { return nil }
    let w = raw.width, h = raw.height, pattern = raw.pattern
    let scale = Float(65535) / Float(raw.white - raw.black.reduce(0, +) / 4)
    /// The photosites less their black levels, then green everywhere.
    var mosaic = [Float](repeating: 0, count: w * h), green = mosaic
    data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      // Only read, row by row, while the rows are worked out together.
      nonisolated(unsafe) let samples = bytes.baseAddress!.advanced(by: raw.offset)
      let black = raw.black
      mosaic.withUnsafeMutableBufferPointer { target in
        nonisolated(unsafe) let m = target.baseAddress!
        DispatchQueue.concurrentPerform(iterations: h) { y in
          for x in 0..<w {
            let s = Int(samples.loadUnaligned(fromByteOffset: 2 * (y * w + x), as: UInt16.self).littleEndian)
            m[y * w + x] = Float(max(0, s - black[(y & 1) << 1 | (x & 1)]))
          }
        }
      }
    }
    /// Where (x, y) is, mirrored at the edges, which keeps its colour.
    @inline(__always) func at(_ x: Int, _ y: Int) -> Int {
      (y < 0 ? -y : y >= h ? 2 * h - 2 - y : y) * w + (x < 0 ? -x : x >= w ? 2 * w - 2 - x : x)
    }
    let flat: Float = 1e-3
    mosaic.withUnsafeBufferPointer { source in
      green.withUnsafeMutableBufferPointer { target in
        nonisolated(unsafe) let m = source.baseAddress!, g = target.baseAddress!
        DispatchQueue.concurrentPerform(iterations: h) { y in
          @inline(__always) func v(_ x: Int, _ y: Int) -> Float { m[at(x, y)] }
          for x in 0..<w {
            let c = v(x, y)
            if pattern[(y & 1) << 1 | (x & 1)] == 1 {
              g[y * w + x] = c
              continue
            }
            // Each direction's green, corrected by the curvature of the site's own colour, and how
            // much that direction changes: the greens beside, the own colour, the next greens out.
            let lh = 2 * c - v(x - 2, y) - v(x + 2, y), lv = 2 * c - v(x, y - 2) - v(x, y + 2)
            let gh = (v(x - 1, y) + v(x + 1, y)) / 2 + lh / 4, gv = (v(x, y - 1) + v(x, y + 1)) / 2 + lv / 4
            let dh = abs(v(x - 1, y) - v(x + 1, y)) + abs(lh) + (abs(v(x - 3, y) - v(x - 1, y)) + abs(v(x + 3, y) - v(x + 1, y))) / 2
            let dv = abs(v(x, y - 1) - v(x, y + 1)) + abs(lv) + (abs(v(x, y - 3) - v(x, y - 1)) + abs(v(x, y + 3) - v(x, y + 1))) / 2
            let wh = 1 / ((dh + flat) * (dh + flat)), wv = 1 / ((dv + flat) * (dv + flat))
            g[y * w + x] = (wh * gh + wv * gv) / (wh + wv)
          }
        }
      }
    }
    var out = Data(count: w * h * 6)
    mosaic.withUnsafeBufferPointer { source in
      green.withUnsafeBufferPointer { greens in
        out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
          nonisolated(unsafe) let m = source.baseAddress!, g = greens.baseAddress!
          nonisolated(unsafe) let dst = target.baseAddress!.assumingMemoryBound(to: UInt16.self)
          DispatchQueue.concurrentPerform(iterations: h) { y in
            /// A site's own colour less green there.
            @inline(__always) func diff(_ x: Int, _ y: Int) -> Float { let i = at(x, y); return m[i] - g[i] }
            @inline(__always) func put(_ i: Int, _ v: Float) { dst[i] = UInt16(min(65535, max(0, (v * scale).rounded()))) }
            for x in 0..<w {
              let i = y * w + x, k = (y & 1) << 1 | (x & 1), own = pattern[k], gi = g[i]
              var rgb = SIMD3<Float>(repeating: gi)
              if own == 1 {
                // A green: the colour beside it left and right, and the one above and below.
                rgb[pattern[k ^ 1]] = gi + (diff(x - 1, y) + diff(x + 1, y)) / 2
                rgb[pattern[k ^ 2]] = gi + (diff(x, y - 1) + diff(x, y + 1)) / 2
              } else {
                // The other colour on the diagonals, along the flatter one.
                let d1 = abs(diff(x - 1, y - 1) - diff(x + 1, y + 1)) + abs(2 * gi - g[at(x - 1, y - 1)] - g[at(x + 1, y + 1)])
                let d2 = abs(diff(x + 1, y - 1) - diff(x - 1, y + 1)) + abs(2 * gi - g[at(x + 1, y - 1)] - g[at(x - 1, y + 1)])
                let w1 = 1 / ((d1 + flat) * (d1 + flat)), w2 = 1 / ((d2 + flat) * (d2 + flat))
                let c1 = (diff(x - 1, y - 1) + diff(x + 1, y + 1)) / 2, c2 = (diff(x + 1, y - 1) + diff(x - 1, y + 1)) / 2
                rgb[own] = m[i]
                rgb[2 - own] = gi + (w1 * c1 + w2 * c2) / (w1 + w2)
              }
              put(3 * i, rgb[0])
              put(3 * i + 1, rgb[1])
              put(3 * i + 2, rgb[2])
            }
          }
        }
      }
    }
    guard let provider = CGDataProvider(data: out as CFData),
      let image = CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6,
        space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    let turns = [6: 1, 3: 2, 8: 3][raw.orientation] ?? 0
    return turns == 0 ? image : ImagePipeline.shared.turned(image, quarterTurns: turns)
  }

  /// Whether `other` is a mosaic of the same kind: size, depth, pattern, levels and orientation.
  func sameKind(as other: SensorRaw) -> Bool {
    width == other.width && height == other.height && bits == other.bits && pattern == other.pattern
      && black == other.black && white == other.white && orientation == other.orientation
  }

  /// Where the scene at (x, y) of the first of a 4-shot pixel-shift group lies in each shot: the
  /// sensor walks one photosite round a square, so every point is measured once in red, once in
  /// blue and twice in green. Measured on the A7R IV (2026-11-05, Vlad's test target): each shot's
  /// offset against the first matched this within 0.2 px, the diagonal one within 0.05 px.
  static let shiftOrder: [(x: Int, y: Int)] = [(0, 0), (0, -1), (1, -1), (1, 0)]
  /// A 16-shot group is four of those squares, shots 1–4, 5–8, 9–12 and 13–16, lying these far from
  /// the first, as the camera means them: a half photosite right, up, and both. On the target the
  /// halves came out 0.15–0.35 px from these, so a 16-shot group's are measured, not assumed.
  static let shiftGroups: [(x: Double, y: Double)] = [(0, 0), (0.5, 0), (0, -0.5), (0.5, -0.5)]

  /// The four shots of a pixel-shift group, in the order taken, composed at the sensor's full
  /// resolution: each point takes red, green and blue from the photosites the four shots put there,
  /// the two greens averaged, so no colour is interpolated from neighbours. Same scale and
  /// orientation as `nativeRGB`, so the rest of the conversion takes it as it takes one shot.
  /// `greens` is how far the two greens of a point differ, against their level, where it is bright
  /// enough for noise not to decide it: about 1 % when the four lie as they should, several times
  /// that when something moved between them. Nil when the four are not uncompressed ARWs of one
  /// size, pattern and levels.
  static func pixelShiftRGB(_ urls: [URL]) throws -> (image: CGImage, greens: Double)? {
    guard urls.count == shiftOrder.count, let group = try ShiftFiles(urls) else { return nil }
    let w = group.width, h = group.height
    var out = Data(count: w * h * 6)
    var greens = 0.0
    withExtendedLifetime(group) {
      out.withUnsafeMutableBytes { greens = group.compose(into: $0.baseAddress!.assumingMemoryBound(to: UInt16.self)) }
    }
    guard let image = group.upright(rgb48(out, width: w, height: h)) else { return nil }
    return (image, greens)
  }

  /// What a 16-shot group composed into: twice the sensor's resolution each way, how far the two
  /// greens of the worst square differ, and where each square was found against the first.
  struct Shift16 {
    var image: CGImage
    var greens: Double
    var squares: [(x: Double, y: Double)]
    /// Brought back to the sensor's size from the doubled grid.
    var supersampled = false
    /// False when the picture had too little detail to find the squares, which were then taken to
    /// lie where the camera means them.
    var measured: Bool
    /// The furthest any square lay from where the camera means it, in photosites.
    var astray: Double {
      zip(squares, SensorRaw.shiftGroups).map { (($0.x - $1.x) * ($0.x - $1.x) + ($0.y - $1.y) * ($0.y - $1.y)).squareRoot() }.max() ?? 0
    }
  }

  /// The sixteen shots of a pixel-shift group, in the order taken, composed at twice the sensor's
  /// resolution each way. Each square of four is composed as a 4-shot group is, every colour as
  /// measured; the second to fourth are found against the first to a hundredth of a photosite on
  /// their greens; then each point of the doubled grid takes its colour from the squares'
  /// nearest points, weighted by how near (σ 0.15 photosite), which with the squares a half apart
  /// is the one square that measured there. `supersample` brings the doubled grid back to the
  /// sensor's size (`supersampled(_:width:height:)`): the colours cleaner and the noise a little lower
  /// than 4 shots', a quarter of the size, the resolution as 4 shots'. Nil as for `pixelShiftRGB`.
  static func pixelShift16(_ urls: [URL], supersample: Bool = false) throws -> Shift16? {
    let n = shiftOrder.count
    guard urls.count == n * shiftGroups.count else { return nil }
    let groups = try (0..<shiftGroups.count).map { try ShiftFiles(Array(urls[$0 * n..<($0 + 1) * n])) }
    guard let first = groups.first ?? nil, groups.allSatisfy({ $0.map { $0.raw.sameKind(as: first.raw) } ?? false })
    else { return nil }
    let w = first.width, h = first.height
    let squares = (0..<groups.count).map { _ in UnsafeMutablePointer<UInt16>.allocate(capacity: w * h * 3) }
    defer { squares.forEach { $0.deallocate() } }
    var greens = 0.0
    withExtendedLifetime(groups) {
      for (k, group) in groups.enumerated() { greens = max(greens, group!.compose(into: squares[k])) }
    }
    // Where squares 2–4 lie against the first.
    var found = shiftGroups, measured = true
    for k in 1..<squares.count {
      if let at = Self.offset(of: squares[k], against: squares[0], width: w, height: h, near: shiftGroups[k]) { found[k] = at } else { measured = false }
    }
    if !measured { found = shiftGroups }
    // The doubled grid: point (X, Y) is (X / 2, Y / 2) of the first square. Each square's nearest
    // point and its weight, apart in x and y, so a point costs four lookups and no exponentials.
    let W = 2 * w, H = 2 * h, inverse = 1 / (2 * 0.15 * 0.15)
    func nearest(_ count: Int, _ size: Int, _ shift: Double) -> (index: [Int], weight: [Float]) {
      var index = [Int](repeating: 0, count: count), weight = [Float](repeating: 0, count: count)
      for i in 0..<count {
        let p = Double(i) / 2 + shift, r = min(max(p.rounded(), 0), Double(size - 1))
        index[i] = Int(r)
        weight[i] = Float(exp(-(p - r) * (p - r) * inverse))
      }
      return (index, weight)
    }
    let xs = found.map { nearest(W, w, $0.x) }, ys = found.map { nearest(H, h, $0.y) }
    var out = Data(count: W * H * 6)
    out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
      nonisolated(unsafe) let dst = target.baseAddress!.assumingMemoryBound(to: UInt16.self)
      nonisolated(unsafe) let sources = squares
      DispatchQueue.concurrentPerform(iterations: H) { Y in
        for X in 0..<W {
          var sum = SIMD3<Float>(repeating: 0), total: Float = 0
          for k in 0..<sources.count {
            let weight = xs[k].weight[X] * ys[k].weight[Y]
            let i = 3 * (ys[k].index[Y] * w + xs[k].index[X]), s = sources[k]
            sum += SIMD3(Float(s[i]), Float(s[i + 1]), Float(s[i + 2])) * weight
            total += weight
          }
          let v = sum / max(total, 1e-12), o = 3 * (Y * W + X)
          dst[o] = UInt16(min(65535, v.x.rounded())); dst[o + 1] = UInt16(min(65535, v.y.rounded())); dst[o + 2] = UInt16(min(65535, v.z.rounded()))
        }
      }
    }
    if supersample {
      let native = out.withUnsafeBytes { supersampled($0.baseAddress!.assumingMemoryBound(to: UInt16.self), width: W, height: H) }
      guard let image = first.upright(rgb48(native, width: w, height: h)) else { return nil }
      return Shift16(image: image, greens: greens, squares: found, supersampled: true, measured: measured)
    }
    guard let image = first.upright(rgb48(out, width: W, height: H)) else { return nil }
    return Shift16(image: image, greens: greens, squares: found, measured: measured)
  }

  /// A doubled grid, 16-bit RGB of `width` × `height`, brought back to half each way by a
  /// separable Lanczos-3: output point x lies on grid point 2x (which is the first shot's
  /// photosite x), taking the grid points 2x − 5 … 2x + 5, weighted L3(d / 2), L3(t) =
  /// 3 sin(πt) sin(πt / 3) / (πt)², the weights summing to 1, the edge repeated. A box over 2 × 2
  /// loses a little contrast at the finest bars (about 0.03 on Vlad's target) and is not used.
  static func supersampled(_ src: UnsafePointer<UInt16>, width W: Int, height H: Int) -> Data {
    let w = W / 2, h = H / 2
    func l3(_ t: Double) -> Double { t == 0 ? 1 : abs(t) >= 3 ? 0 : 3 * sin(.pi * t) * sin(.pi * t / 3) / (.pi * .pi * t * t) }
    let taps = Array(-5...5), raw = taps.map { l3(Double($0) / 2) }, total = raw.reduce(0, +)
    let weights = raw.map { Float($0 / total) }
    var out = Data(count: w * h * 6)
    out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
      nonisolated(unsafe) let dst = target.baseAddress!.assumingMemoryBound(to: UInt16.self)
      nonisolated(unsafe) let source = src
      DispatchQueue.concurrentPerform(iterations: h) { y in
        // Down the column first, into one row of the grid's width; then along it.
        var column = [Float](repeating: 0, count: 3 * W)
        for (k, d) in taps.enumerated() {
          let row = min(max(2 * y + d, 0), H - 1), weight = weights[k]
          for i in 0..<(3 * W) { column[i] += Float(source[3 * row * W + i]) * weight }
        }
        for x in 0..<w {
          var v = SIMD3<Float>(repeating: 0)
          for (k, d) in taps.enumerated() {
            let c = 3 * min(max(2 * x + d, 0), W - 1)
            v += SIMD3(column[c], column[c + 1], column[c + 2]) * weights[k]
          }
          let o = 3 * (y * w + x)
          dst[o] = UInt16(min(65535, max(0, v.x.rounded())))
          dst[o + 1] = UInt16(min(65535, max(0, v.y.rounded())))
          dst[o + 2] = UInt16(min(65535, max(0, v.z.rounded())))
        }
      }
    }
    return out
  }

  /// Where composite `b` lies against `a`, both 16-bit RGB of `width` × `height`: the scene at
  /// (x, y) of `a` at (x + dx, y + dy) in `b`, to 0.01 px, looked for within half a photosite of
  /// `near` on green, read between points linearly. Measured on the most detailed of nine places;
  /// nil when the picture has too little detail anywhere to tell.
  static func offset(of b: UnsafePointer<UInt16>, against a: UnsafePointer<UInt16>, width w: Int, height h: Int,
                     near: (x: Double, y: Double)) -> (x: Double, y: Double)? {
    @inline(__always) func green(_ p: UnsafePointer<UInt16>, _ x: Int, _ y: Int) -> Float { Float(p[3 * (y * w + x) + 1]) }
    let side = max(16, min(512, w / 4, h / 4) & ~1)
    var best = (detail: Float(0), x: 0, y: 0)
    for j in 1...3 { for i in 1...3 {
      let cx = w * i / 4, cy = h * j / 4
      var change: Float = 0, level: Float = 0
      for y in stride(from: cy - side / 2, to: cy + side / 2, by: 2) { for x in stride(from: cx - side / 2, to: cx + side / 2, by: 2) {
        let g = green(a, x, y)
        change += abs(green(a, x + 1, y) - g) + abs(green(a, x, y + 1) - g)
        level += g
      } }
      let detail = level > 0 ? change / level : 0
      if detail > best.detail { best = (detail, cx - side / 2, cy - side / 2) }
    } }
    guard best.detail > 0.005 else { return nil }
    let x0 = best.x, y0 = best.y
    func cost(_ dx: Double, _ dy: Double) -> Double {
      var e: Float = 0
      for y in stride(from: y0, to: y0 + side, by: 2) { for x in stride(from: x0, to: x0 + side, by: 2) {
        let fx = Double(x) + dx, fy = Double(y) + dy
        let ix = min(max(Int(fx.rounded(.down)), 0), w - 2), iy = min(max(Int(fy.rounded(.down)), 0), h - 2)
        let tx = Float(fx - Double(ix)), ty = Float(fy - Double(iy))
        let v = (green(b, ix, iy) * (1 - tx) + green(b, ix + 1, iy) * tx) * (1 - ty) + (green(b, ix, iy + 1) * (1 - tx) + green(b, ix + 1, iy + 1) * tx) * ty
        e += abs(v - green(a, x, y))
      } }
      return Double(e)
    }
    var at = (x: near.x, y: near.y, e: Double.infinity)
    for (step, reach) in [(0.05, 10), (0.01, 5)] {
      let centre = at
      for j in -reach...reach { for i in -reach...reach {
        let dx = centre.x + Double(i) * step, dy = centre.y + Double(j) * step
        let e = cost(dx, dy)
        if e < at.e { at = (dx, dy, e) }
      } }
    }
    return (at.x, at.y)
  }

  /// 16-bit linear RGB, `width` × `height`, as a picture.
  static func rgb48(_ data: Data, width w: Int, height h: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6,
      space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// The four shots of one square, mapped, checked to be uncompressed ARWs of one size, pattern
  /// and levels.
  final class ShiftFiles {
    /// Kept as NSData, whose bytes stay where they are while it lives.
    let files: [NSData]
    let raw: SensorRaw
    let mosaic: Mosaic
    var width: Int { raw.width }
    var height: Int { raw.height }
    init?(_ urls: [URL]) throws {
      files = try urls.map { try NSData(contentsOf: $0, options: .alwaysMapped) }
      let raws = files.compactMap { SensorRaw($0 as Data) }
      guard raws.count == files.count, let first = raws.first, raws.allSatisfy({ $0.sameKind(as: first) }) else { return nil }
      raw = first
      mosaic = Mosaic(bases: zip(files, raws).map { UInt(bitPattern: $0.0.bytes) + UInt($0.1.offset) },
        width: first.width, height: first.height, pattern: first.pattern, black: first.black)
    }
    /// Composes the square into `dst`, 16-bit RGB at the sensor's size; returns how far the two
    /// greens differ, against their level, where all four measured the point and it is bright
    /// enough for noise not to decide it.
    func compose(into dst: UnsafeMutablePointer<UInt16>) -> Double {
      let w = width, h = height, mosaic = mosaic
      let range = Float(raw.white - raw.black.reduce(0, +) / 4), scale = Float(65535) / range
      let order = SensorRaw.shiftOrder
      let xs = (-(order.map(\.x).min() ?? 0))...(w - 1 - (order.map(\.x).max() ?? 0))
      let ys = (-(order.map(\.y).min() ?? 0))...(h - 1 - (order.map(\.y).max() ?? 0))
      var rows = [(difference: Double, level: Double)](repeating: (0, 0), count: h)
      nonisolated(unsafe) let out = dst
      rows.withUnsafeMutableBufferPointer { sums in
        nonisolated(unsafe) let row = sums.baseAddress!
        DispatchQueue.concurrentPerform(iterations: h) { y in
          var difference = 0.0, level = 0.0
          for x in 0..<w {
            let p = mosaic.composed(x, y)
            let g = (p.g1 + p.g2) / 2
            if g > 0.1 * range, xs.contains(x), ys.contains(y) { difference += Double(abs(p.g1 - p.g2)); level += Double(g) }
            let i = 3 * (y * w + x)
            out[i] = UInt16(min(65535, (p.rgb.x * scale).rounded()))
            out[i + 1] = UInt16(min(65535, (p.rgb.y * scale).rounded()))
            out[i + 2] = UInt16(min(65535, (p.rgb.z * scale).rounded()))
          }
          row[y] = (difference, level)
        }
      }
      let level = rows.reduce(0) { $0 + $1.level }, difference = rows.reduce(0) { $0 + $1.difference }
      return level > 0 ? difference / level : 0
    }
    /// `image` turned as the camera was held.
    func upright(_ image: CGImage?) -> CGImage? {
      guard let image else { return nil }
      let turns = [6: 1, 3: 2, 8: 3][raw.orientation] ?? 0
      return turns == 0 ? image : ImagePipeline.shared.turned(image, quarterTurns: turns)
    }
  }

  /// The photosites of the four shots of a pixel-shift square, read where they lie in the files.
  struct Mosaic: Sendable {
    /// Where each shot's photosites begin in memory.
    let bases: [UInt]
    let width: Int, height: Int, pattern: [Int], black: [Int]
    /// The photosite (x, y) of shot `k`, less its black level, and its colour; past the edge, the
    /// nearest one of the same colour.
    @inline(__always) func at(_ k: Int, _ x: Int, _ y: Int) -> (colour: Int, value: Float) {
      let X = x < 0 ? x + 2 : x >= width ? x - 2 : x, Y = y < 0 ? y + 2 : y >= height ? y - 2 : y
      let s = Int(UnsafeRawPointer(bitPattern: bases[k])!.loadUnaligned(fromByteOffset: 2 * (Y * width + X), as: UInt16.self).littleEndian)
      let site = (Y & 1) << 1 | (X & 1)
      return (pattern[site], Float(max(0, s - black[site])))
    }
    /// Red, green and blue at (x, y) of the first shot, and the two greens it came from.
    @inline(__always) func composed(_ x: Int, _ y: Int) -> (rgb: SIMD3<Float>, g1: Float, g2: Float) {
      var sum = SIMD3<Float>(repeating: 0), seen = SIMD3<Float>(repeating: 0)
      var g1: Float = -1, g2: Float = -1
      for k in 0..<4 {
        let d = SensorRaw.shiftOrder[k], p = at(k, x + d.x, y + d.y)
        sum[p.colour] += p.value
        seen[p.colour] += 1
        if p.colour == 1 { if g1 < 0 { g1 = p.value } else { g2 = p.value } }
      }
      let rgb = sum / SIMD3(max(seen.x, 1), max(seen.y, 1), max(seen.z, 1))
      return (rgb, g1 < 0 ? rgb.y : g1, g2 < 0 ? rgb.y : g2)
    }
  }
}
