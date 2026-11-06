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

  /// Where the scene at (x, y) of the first of a 4-shot pixel-shift group lies in each shot: the
  /// sensor walks one photosite round a square, so every point is measured once in red, once in
  /// blue and twice in green. Measured on the A7R IV (2026-11-05, Vlad's test target): each shot's
  /// offset against the first matched this within 0.2 px, the diagonal one within 0.05 px. A
  /// 16-shot group is four of these squares, a half photosite apart.
  static let shiftOrder: [(x: Int, y: Int)] = [(0, 0), (0, -1), (1, -1), (1, 0)]

  /// The four shots of a pixel-shift group, in the order taken, composed at the sensor's full
  /// resolution: each point takes red, green and blue from the photosites the four shots put there,
  /// the two greens averaged, so no colour is interpolated from neighbours. Same scale and
  /// orientation as `nativeRGB`, so the rest of the conversion takes it as it takes one shot.
  /// `greens` is how far the two greens of a point differ, against their level, where it is bright
  /// enough for noise not to decide it: about 1 % when the four lie as they should, several times
  /// that when something moved between them. Nil when the four are not uncompressed ARWs of one
  /// size, pattern and levels.
  static func pixelShiftRGB(_ urls: [URL]) throws -> (image: CGImage, greens: Double)? {
    guard urls.count == shiftOrder.count else { return nil }
    // Mapped, and kept as NSData, whose bytes stay where they are while it lives.
    let files = try urls.map { try NSData(contentsOf: $0, options: .alwaysMapped) }
    let raws = files.compactMap { SensorRaw($0 as Data) }
    guard raws.count == files.count, let first = raws.first,
      raws.allSatisfy({ $0.width == first.width && $0.height == first.height && $0.pattern == first.pattern
        && $0.black == first.black && $0.white == first.white && $0.orientation == first.orientation })
    else { return nil }
    let w = first.width, h = first.height
    let range = Float(first.white - first.black.reduce(0, +) / 4), scale = Float(65535) / range
    let mosaic = Mosaic(bases: zip(files, raws).map { UInt(bitPattern: $0.0.bytes) + UInt($0.1.offset) },
      width: w, height: h, pattern: first.pattern, black: first.black)
    var out = Data(count: w * h * 6)
    var rows = [(difference: Double, level: Double)](repeating: (0, 0), count: h)
    // The greens are compared only where all four shots measured the point, not at the edge.
    let xs = (-(shiftOrder.map(\.x).min() ?? 0))...(w - 1 - (shiftOrder.map(\.x).max() ?? 0))
    let ys = (-(shiftOrder.map(\.y).min() ?? 0))...(h - 1 - (shiftOrder.map(\.y).max() ?? 0))
    withExtendedLifetime(files) {
      out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
        nonisolated(unsafe) let dst = target.baseAddress!.assumingMemoryBound(to: UInt16.self)
        rows.withUnsafeMutableBufferPointer { sums in
          nonisolated(unsafe) let row = sums.baseAddress!
          DispatchQueue.concurrentPerform(iterations: h) { y in
            var difference = 0.0, level = 0.0
            for x in 0..<w {
              let p = mosaic.composed(x, y)
              let g = (p.g1 + p.g2) / 2
              if g > 0.1 * range, xs.contains(x), ys.contains(y) { difference += Double(abs(p.g1 - p.g2)); level += Double(g) }
              let i = 3 * (y * w + x)
              dst[i] = UInt16(min(65535, (p.rgb.x * scale).rounded()))
              dst[i + 1] = UInt16(min(65535, (p.rgb.y * scale).rounded()))
              dst[i + 2] = UInt16(min(65535, (p.rgb.z * scale).rounded()))
            }
            row[y] = (difference, level)
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
    let level = rows.reduce(0) { $0 + $1.level }, difference = rows.reduce(0) { $0 + $1.difference }
    let turns = [6: 1, 3: 2, 8: 3][first.orientation] ?? 0
    guard let upright = turns == 0 ? image : ImagePipeline.shared.turned(image, quarterTurns: turns) else { return nil }
    return (upright, level > 0 ? difference / level : 0)
  }

  /// The photosites of the four shots of a pixel-shift group, read where they lie in the files.
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
