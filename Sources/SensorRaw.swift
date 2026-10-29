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
  /// from its neighbours by Malvar, He and Cutler's gradient-corrected linear interpolation (2004),
  /// sharper than bilinear and with less colour at edges. No white balance and no colour matrix:
  /// each channel is what its colour of light made, which a negative lit by red, green and blue
  /// lights needs. 16 bits linear, upright as the camera was held.
  static func nativeRGB(_ url: URL) throws -> CGImage? {
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    guard let raw = SensorRaw(data) else { return nil }
    let w = raw.width, h = raw.height
    let black = raw.black.map { Int32($0) }, pattern = raw.pattern
    let scale = 65535.0 / 16 / Double(raw.white - raw.black.reduce(0, +) / 4)
    var out = Data(count: w * h * 6)
    data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      // Only read, row by row, while the rows are worked out together.
      nonisolated(unsafe) let samples = bytes.baseAddress!.advanced(by: raw.offset)
      out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
        let dst = target.baseAddress!.assumingMemoryBound(to: UInt16.self)
        DispatchQueue.concurrentPerform(iterations: h) { y in
          /// The photosite at (x, y) less its black level, mirrored at the edges, which keeps its colour.
          @inline(__always) func v(_ x: Int, _ y: Int) -> Int32 {
            let cx = x < 0 ? -x : x >= w ? 2 * w - 2 - x : x, cy = y < 0 ? -y : y >= h ? 2 * h - 2 - y : y
            let s = Int32(samples.loadUnaligned(fromByteOffset: 2 * (cy * w + cx), as: UInt16.self).littleEndian)
            return max(0, s - black[(cy & 1) << 1 | (cx & 1)])
          }
          for x in 0..<w {
            let k = (y & 1) << 1 | (x & 1), own = pattern[k]
            let c = v(x, y)
            let h1 = v(x - 1, y) + v(x + 1, y), v1 = v(x, y - 1) + v(x, y + 1)
            let h2 = v(x - 2, y) + v(x + 2, y), v2 = v(x, y - 2) + v(x, y + 2)
            let d = v(x - 1, y - 1) + v(x + 1, y - 1) + v(x - 1, y + 1) + v(x + 1, y + 1)
            // In sixteenths: the kernels of the paper, doubled to stay whole.
            var rgb: (Int32, Int32, Int32)
            if own == 1 {
              // A green: the colour beside it left and right, and the one above and below.
              let across = 10 * c + 8 * h1 - 2 * h2 - 2 * d + v2, along = 10 * c + 8 * v1 - 2 * v2 - 2 * d + h2
              rgb = pattern[k ^ 1] == 0 ? (across, 16 * c, along) : (along, 16 * c, across)
            } else {
              let green = 8 * c + 4 * (h1 + v1) - 2 * (h2 + v2), other = 12 * c + 4 * d - 3 * (h2 + v2)
              rgb = own == 0 ? (16 * c, green, other) : (other, green, 16 * c)
            }
            let i = 3 * (y * w + x)
            dst[i] = UInt16(min(65535, max(0, (Double(rgb.0) * scale).rounded())))
            dst[i + 1] = UInt16(min(65535, max(0, (Double(rgb.1) * scale).rounded())))
            dst[i + 2] = UInt16(min(65535, max(0, (Double(rgb.2) * scale).rounded())))
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
}
