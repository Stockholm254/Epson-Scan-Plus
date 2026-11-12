import CoreGraphics
import CoreImage
import Foundation

/// A light-leak repair carried back from 去漏光 into the conversion, so ③ 调色 grades the repaired
/// picture: 去漏光 works on the frame as ② 去色罩 leaves it (`Kernels.negativeNeutral`), and what
/// it changed is measured back onto the print's straight line, before the exposure and the levels,
/// as each channel there times `a` plus `d`, both smooth across the frame (`LeakFixField`). The
/// conversion applies it there (`Kernels.negativeFixed`); everything after it, the white balance's
/// fine controls, the tones, levels, colour and curves, works on the repaired picture as on any
/// other, and a frame without one is converted exactly as before.
struct LeakFix: Codable, Equatable {
  /// The correction's file, in the roll's Repairs folder.
  var file: String
  /// The 去漏光 job it was measured from.
  var job: String?
  var made: Date
  /// How closely the correction gives the repair back on the job's picture, 0–255: the mean and
  /// the 99th percentile of each channel's difference.
  var meanError: Double?
  var worstError: Double?
}

/// The correction as stored: `a` and `d` for red, green and blue on a grid over the frame's
/// picture as the conversion reads it (before it is straightened, turned and mirrored), first row
/// at the top. Written as a small binary file: "EPLF", version, width, height, then the grid's
/// `a` and `d` as 16-bit floats, four to a cell (red, green, blue, and one).
struct LeakFixField: Equatable {
  var width: Int, height: Int
  /// Three to a cell, row after row.
  var a: [Float], d: [Float]

  static let magic: [UInt8] = Array("EPLF".utf8)
  func write(to url: URL) throws {
    var data = Data(Self.magic)
    for v in [UInt32(1), UInt32(width), UInt32(height)] { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    for plane in [a, d] {
      var halves = [Float16](repeating: 1, count: width * height * 4)
      for i in 0..<(width * height) {
        for c in 0..<3 { halves[i * 4 + c] = Float16(plane[i * 3 + c]) }
      }
      halves.withUnsafeBytes { data.append(contentsOf: $0) }
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }
  init(width: Int, height: Int, a: [Float], d: [Float]) {
    (self.width, self.height, self.a, self.d) = (width, height, a, d)
  }
  init(contentsOf url: URL) throws {
    let data = try Data(contentsOf: url)
    func word(_ at: Int) -> Int { Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian }) }
    guard data.count >= 16, Array(data.prefix(4)) == Self.magic, word(4) == 1 else { throw DeskError.message("去漏光的校正文件读不了：\(url.lastPathComponent)") }
    let w = word(8), h = word(12), n = w * h
    guard w > 0, h > 0, w <= 4096, h <= 4096, data.count == 16 + n * 4 * 2 * 2 else {
      throw DeskError.message("去漏光的校正文件不完整：\(url.lastPathComponent)")
    }
    var planes = [[Float]]()
    data.withUnsafeBytes { raw in
      for p in 0..<2 {
        var plane = [Float](repeating: 0, count: n * 3)
        let start = 16 + p * n * 8
        for i in 0..<n {
          for c in 0..<3 { plane[i * 3 + c] = Float(raw.loadUnaligned(fromByteOffset: start + (i * 4 + c) * 2, as: Float16.self)) }
        }
        planes.append(plane)
      }
    }
    self.init(width: w, height: h, a: planes[0], d: planes[1])
  }
  /// `a` and `d` at (x, y), 0–1 across the picture as the conversion reads it, between the cells as
  /// the kernel reads them, held at the edges.
  func sample(_ x: Double, _ y: Double) -> (a: [Double], d: [Double]) {
    let fx = min(Double(width) - 1, max(0, x * Double(width) - 0.5)), fy = min(Double(height) - 1, max(0, y * Double(height) - 0.5))
    let x0 = Int(fx), y0 = Int(fy), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
    let tx = fx - Double(x0), ty = fy - Double(y0)
    func at(_ plane: [Float], _ c: Int) -> Double {
      func v(_ xx: Int, _ yy: Int) -> Double { Double(plane[(yy * width + xx) * 3 + c]) }
      let top = v(x0, y0) + (v(x1, y0) - v(x0, y0)) * tx, bottom = v(x0, y1) + (v(x1, y1) - v(x0, y1)) * tx
      return top + (bottom - top) * ty
    }
    return ((0..<3).map { at(a, $0) }, (0..<3).map { at(d, $0) })
  }
  /// One of the planes as a picture, `width` × `height`, red, green and blue, the first row at the
  /// top of the picture: a bitmap's first row is its top in Core Image too, as a CGImage's is.
  func image(_ plane: [Float]) -> CIImage {
    var rgba = [Float](repeating: 1, count: width * height * 4)
    for i in 0..<(width * height) {
      for c in 0..<3 { rgba[i * 4 + c] = plane[i * 3 + c] }
    }
    return CIImage(bitmapData: Data(bytes: rgba, count: rgba.count * 4), bytesPerRow: width * 16,
      size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
  }
}

/// The corrections read once each, as pictures, and spread over the picture the kernel converts.
final class LeakFixStore: @unchecked Sendable {
  static let shared = LeakFixStore()
  private final class Planes { let a: CIImage, d: CIImage; init(a: CIImage, d: CIImage) { (self.a, self.d) = (a, d) } }
  private final class Grid { let field: LeakFixField; init(_ field: LeakFixField) { self.field = field } }
  private let cache = NSCache<NSString, Planes>()
  private let grids = NSCache<NSString, Grid>()
  /// `fix`'s grid itself, read once: for what is worked out on the CPU (the statistics, the pickers).
  func field(_ fix: LeakFix) -> LeakFixField? {
    let key = fix.file as NSString
    if let kept = grids.object(forKey: key) { return kept.field }
    guard let field = try? LeakFixField(contentsOf: URL(fileURLWithPath: fix.file)) else { return nil }
    grids.setObject(Grid(field), forKey: key)
    return field
  }
  /// `fix`'s correction over `extent`, the picture the kernel converts: nil when its file is gone.
  func planes(_ fix: LeakFix, over extent: CGRect) -> (a: CIImage, d: CIImage)? {
    let key = fix.file as NSString
    var planes = cache.object(forKey: key)
    if planes == nil, let field = try? LeakFixField(contentsOf: URL(fileURLWithPath: fix.file)) {
      planes = Planes(a: field.image(field.a), d: field.image(field.d))
      cache.setObject(planes!, forKey: key)
    }
    guard let planes else { return nil }
    func spread(_ i: CIImage) -> CIImage {
      // Each cell's value at its middle, smoothly between, held at the edges.
      let e = i.extent
      return i.clampedToExtent()
        .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
          .concatenating(CGAffineTransform(scaleX: extent.width / e.width, y: extent.height / e.height))
          .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
        .cropped(to: extent)
    }
    return (spread(planes.a), spread(planes.d))
  }
  /// Forgets a correction read before: its file was written again.
  func forget(_ file: String) {
    cache.removeObject(forKey: file as NSString)
    grids.removeObject(forKey: file as NSString)
  }
}

/// How 去漏光's picture (`Kernels.negativeNeutral`) shows the print's straight line, per channel,
/// and back: what `LeakFix.measure` reads the repair off.
struct LeakNeutralScale: Equatable {
  var negative: Bool
  var low: Double, high: Double
  /// A positive's encoding power for the screen.
  var encode: Double
  /// The frame's analysis on the picture: each channel's gain and white balance, between the
  /// film's own reading (where the repair goes) and the straight line.
  var gain: [Double] = [1, 1, 1]
  var balance: [Double] = [0, 0, 0]
  /// The film's reading in channel `c` a value of the picture shows, and back: what a repair is
  /// measured and applied on, before the gain, the white balance and all of ③.
  func reading(_ n: Double, _ c: Int) -> Double { (straight(n) - balance[c]) / max(gain[c], 0.000001) }
  func shown(reading r: Double, _ c: Int) -> Double { shown(r * gain[c] + balance[c]) }
  /// The picture's value, 0–1, for a reading on the straight line.
  func shown(_ s: Double) -> Double {
    if negative { return (s - low) / max(high - low, 0.001) }
    let t = (s - low) / max(high - low, 0.000001)
    return t < 0 ? -pow(-t, encode) : pow(t, encode)
  }
  /// The reading on the straight line a value of the picture shows.
  func straight(_ n: Double) -> Double {
    if negative { return n * max(high - low, 0.001) + low }
    let t = n < 0 ? -pow(-n, 1 / encode) : pow(n, 1 / encode)
    return t * max(high - low, 0.000001) + low
  }
}

extension LeakFix {
  /// The repair `after` made of `before`, both 去漏光's picture of a frame (`Kernels.negativeNeutral`,
  /// sRGB values 0–1, `width` × `height`, red, green and blue, row after row from the top), read
  /// back onto the straight line through `scale` as `after ≈ a × before + d` there, each channel by
  /// itself, smooth over the picture: a guided filter's local lines, `radius` pixels round, pulled
  /// towards a = 1 where the picture has little to tell them apart. Clipped values say nothing and
  /// are left out. Returned on the same grid as the picture, with how far the correction misses the
  /// repair (0–255, the mean and the 99th percentile).
  static func measure(before: [Float], after: [Float], width: Int, height: Int, scale: LeakNeutralScale, radius: Int)
    -> (a: [Float], d: [Float], mean: Double, worst: Double)
  {
    let n = width * height
    var a = [Float](repeating: 1, count: n * 3), d = [Float](repeating: 0, count: n * 3)
    // Summed areas of a plane, (width + 1) × (height + 1), for the boxes' sums.
    func summed(_ v: [Double]) -> [Double] {
      var s = [Double](repeating: 0, count: (width + 1) * (height + 1))
      for y in 0..<height {
        var row = 0.0
        for x in 0..<width {
          row += v[y * width + x]
          s[(y + 1) * (width + 1) + x + 1] = s[y * (width + 1) + x + 1] + row
        }
      }
      return s
    }
    func box(_ s: [Double], _ x: Int, _ y: Int) -> Double {
      let x0 = max(0, x - radius), x1 = min(width, x + radius + 1), y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
      return s[y1 * (width + 1) + x1] - s[y0 * (width + 1) + x1] - s[y1 * (width + 1) + x0] + s[y0 * (width + 1) + x0]
    }
    // How much the local line may lean from 1 (a plain shift): 0.002 on the straight line, squared,
    // in the reading's units.
    var reproduced = [Double](), residuals = [Double]()
    reproduced.reserveCapacity(n * 3)
    for c in 0..<3 {
      let eps = 0.002 / pow(max(scale.gain[c], 0.01), 2)
      var w = [Double](repeating: 0, count: n), x = w, y = w
      for i in 0..<n {
        let b = Double(before[i * 3 + c]), f = Double(after[i * 3 + c])
        guard b > 0.003, b < 0.997, f > 0.003, f < 0.997 else { continue }
        w[i] = 1
        x[i] = scale.reading(b, c)
        y[i] = scale.reading(f, c)
      }
      let sw = summed(w)
      let sx = summed((0..<n).map { w[$0] * x[$0] }), sy = summed((0..<n).map { w[$0] * y[$0] })
      let sxx = summed((0..<n).map { w[$0] * x[$0] * x[$0] }), sxy = summed((0..<n).map { w[$0] * x[$0] * y[$0] })
      var la = [Double](repeating: 1, count: n), ld = [Double](repeating: 0, count: n), lw = [Double](repeating: 0, count: n)
      for yy in 0..<height {
        for xx in 0..<width {
          let i = yy * width + xx
          let count = box(sw, xx, yy)
          guard count >= 4 else { continue }
          let mx = box(sx, xx, yy) / count, my = box(sy, xx, yy) / count
          let vx = max(0, box(sxx, xx, yy) / count - mx * mx), cxy = box(sxy, xx, yy) / count - mx * my
          let k = min(4, max(0.25, (cxy + eps) / (vx + eps)))
          la[i] = k
          ld[i] = my - k * mx
          lw[i] = 1
        }
      }
      // The lines averaged over the same boxes, where they were found.
      let sa = summed((0..<n).map { lw[$0] * la[$0] }), sd = summed((0..<n).map { lw[$0] * ld[$0] }), sl = summed(lw)
      for yy in 0..<height {
        for xx in 0..<width {
          let i = yy * width + xx, count = box(sl, xx, yy)
          if count > 0 {
            a[i * 3 + c] = Float(box(sa, xx, yy) / count)
            d[i * 3 + c] = Float(box(sd, xx, yy) / count)
          }
          guard w[i] > 0 else { continue }
          let got = scale.shown(reading: Double(a[i * 3 + c]) * x[i] + Double(d[i * 3 + c]), c)
          residuals.append(abs(got - Double(after[i * 3 + c])) * 255)
        }
      }
    }
    reproduced = residuals
    let mean = reproduced.isEmpty ? 0 : reproduced.reduce(0, +) / Double(reproduced.count)
    var worst = 0.0
    if !reproduced.isEmpty {
      reproduced.sort()
      worst = reproduced[min(reproduced.count - 1, Int(Double(reproduced.count) * 0.99))]
    }
    return (a, d, mean, worst)
  }
  /// A plane on one grid, sampled onto another by `place`: each cell of the new one, as 0–1 across
  /// it from the top left, to where it lies on the first (0–1 too), read there between its cells.
  static func resampled(_ plane: [Float], width: Int, height: Int, to w: Int, _ h: Int, place: (CGPoint) -> CGPoint) -> [Float] {
    var out = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
      for x in 0..<w {
        let p = place(CGPoint(x: (Double(x) + 0.5) / Double(w), y: (Double(y) + 0.5) / Double(h)))
        let fx = min(Double(width) - 1, max(0, Double(p.x) * Double(width) - 0.5))
        let fy = min(Double(height) - 1, max(0, Double(p.y) * Double(height) - 0.5))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        for c in 0..<3 {
          func at(_ xx: Int, _ yy: Int) -> Float { plane[(yy * width + xx) * 3 + c] }
          let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * tx, bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * tx
          out[(y * w + x) * 3 + c] = top + (bottom - top) * ty
        }
      }
    }
    return out
  }
  /// The cells of a plane averaged down by whole blocks to at most `longest` across.
  static func shrunk(_ plane: [Float], width: Int, height: Int, longest: Int) -> (plane: [Float], width: Int, height: Int) {
    let step = max(1, Int((Double(max(width, height)) / Double(longest)).rounded(.up)))
    let w = max(1, width / step), h = max(1, height / step)
    var out = [Float](repeating: 0, count: w * h * 3)
    for y in 0..<h {
      for x in 0..<w {
        for c in 0..<3 {
          var sum: Float = 0
          for yy in (y * step)..<min(height, (y + 1) * step) {
            for xx in (x * step)..<min(width, (x + 1) * step) { sum += plane[(yy * width + xx) * 3 + c] }
          }
          out[(y * w + x) * 3 + c] = sum / Float(step * step)
        }
      }
    }
    return (out, w, h)
  }
}
