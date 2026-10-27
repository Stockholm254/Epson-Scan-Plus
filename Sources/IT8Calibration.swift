import CoreGraphics
import CoreImage
import Foundation

/// An IT8.7/1 transparency target's reference data: the maker's CGATS text, with an XYZ per patch
/// (D50, Y = 100 for clear film).
struct IT8Reference {
  var name: String
  var batch: String
  var patches: [String: (x: Double, y: Double, z: Double)]

  static func parse(_ text: String, name: String) throws -> IT8Reference {
    let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
    func keyword(_ key: String) -> String? {
      lines.first { $0.hasPrefix(key + " ") || $0.hasPrefix(key + "\t") }.map {
        $0.dropFirst(key.count).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      }
    }
    guard let formatStart = lines.firstIndex(of: "BEGIN_DATA_FORMAT"), let formatEnd = lines.firstIndex(of: "END_DATA_FORMAT"),
      let dataStart = lines.firstIndex(of: "BEGIN_DATA"), let dataEnd = lines.firstIndex(of: "END_DATA"),
      formatStart < formatEnd, dataStart < dataEnd
    else { throw DeskError.message("不是 CGATS 格式的 IT8 参考文件。") }
    let fields = lines[(formatStart + 1)..<formatEnd].joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init)
    guard let id = fields.firstIndex(of: "SAMPLE_ID"), let x = fields.firstIndex(of: "XYZ_X"),
      let y = fields.firstIndex(of: "XYZ_Y"), let z = fields.firstIndex(of: "XYZ_Z")
    else { throw DeskError.message("参考文件缺少 SAMPLE_ID 或 XYZ_X / XYZ_Y / XYZ_Z 列。") }
    var patches = [String: (x: Double, y: Double, z: Double)]()
    for line in lines[(dataStart + 1)..<dataEnd] where !line.hasPrefix("#") {
      let v = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard v.count > max(id, x, y, z), let px = Double(v[x]), let py = Double(v[y]), let pz = Double(v[z]) else { continue }
      patches[v[id]] = (px, py, pz)
    }
    let reference = IT8Reference(name: keyword("DESCRIPTOR") ?? name, batch: keyword("PROD_DATE") ?? "", patches: patches)
    guard IT8Layout.grid.allSatisfy({ patches[$0] != nil }), IT8Layout.grays.allSatisfy({ patches[$0] != nil }) else {
      throw DeskError.message("参考文件不完整：IT8.7/1 需要 A01–L22 的 264 个色块和 Dmin、GS01–GS22、Dmax 的 24 级灰阶。")
    }
    return reference
  }
}

/// Where an IT8.7/1 target's patches lie in a scan, from six points clicked on it: the centres of
/// the colour grid's corner patches and of the grey scale's two ends.
enum IT8Layout {
  static let rows = Array("ABCDEFGHIJKL").map(String.init)
  static let grid = rows.flatMap { r in (1...22).map { r + String(format: "%02d", $0) } }
  static let grays = ["Dmin"] + (1...22).map { String(format: "GS%02d", $0) } + ["Dmax"]
  static let marks = ["色块 A01（左上）", "色块 A22（右上）", "色块 L01（左下）", "色块 L22（右下）", "灰阶 Dmin（最亮一端）", "灰阶 Dmax（最暗一端）"]
  /// Patch centres, in the same coordinates as `marks`: the grid once four are set, the greys at six.
  static func centres(_ marks: [CGPoint]) -> [String: CGPoint] {
    var out = [String: CGPoint]()
    if marks.count >= 4 {
      let (a1, a22, l1, l22) = (marks[0], marks[1], marks[2], marks[3])
      for (r, row) in rows.enumerated() {
        for c in 1...22 {
          let u = Double(c - 1) / 21, v = Double(r) / 11
          func lerp(_ p: CGPoint, _ q: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t) }
          out[row + String(format: "%02d", c)] = lerp(lerp(a1, a22, u), lerp(l1, l22, u), v)
        }
      }
    }
    if marks.count >= 6 {
      for (i, id) in grays.enumerated() {
        let t = Double(i) / 23
        out[id] = CGPoint(x: marks[4].x + (marks[5].x - marks[4].x) * t, y: marks[4].y + (marks[5].y - marks[4].y) * t)
      }
    }
    return out
  }
  /// Half the side of the square sampled around each centre: 30 % of the patch pitch.
  static func sampleRadius(_ marks: [CGPoint]) -> Double {
    guard marks.count >= 4 else { return 0.01 }
    return 0.3 * min(hypot(marks[1].x - marks[0].x, marks[1].y - marks[0].y) / 21, hypot(marks[2].x - marks[0].x, marks[2].y - marks[0].y) / 11)
  }
  /// Each patch's median raw value in `image` (linear, as scanned), at centres in 0–1 of it.
  static func sample(_ image: CGImage, marks: [CGPoint]) throws -> [String: RGB] {
    let pipe = ImagePipeline.shared, radius = sampleRadius(marks)
    var values = [String: RGB]()
    for (id, c) in centres(marks) {
      let r = NormalRect(x: max(0, c.x - radius), y: max(0, c.y - radius), width: 2 * radius, height: 2 * radius)
      let s = pipe.samples(try pipe.crop(image, rect: r), maxDimension: 40)
      values[id] = RGB((0..<3).map { ch in pipe.quantile((0..<(s.width * s.height)).map { Double(s.values[$0 * 4 + ch]) }, 0.5) })
    }
    return values
  }
}

/// This scanner measured on an IT8.7/1 target: the stray light each channel adds (a fraction of
/// its reading for clear film), from the grey scale; and how well a 3×3 matrix maps its readings to
/// the target's colours. Conversion subtracts the stray light from the scanner's linear scans; the
/// matrix belongs to the target's slide dyes, not a negative's, so it is only reported.
struct ScannerCalibration: Codable, Equatable {
  var reference: String
  var created: Date
  /// Raw reading for clear film, per channel.
  var white: RGB
  /// Stray light, as a fraction of `white`.
  var flare: RGB
  /// Largest grey-scale error in density, without and with the stray light taken out.
  var grayErrorBefore: Double
  var grayError: Double
  /// Corrected readings (0–1 of clear film) to XYZ, row by row.
  var matrix: [Double]
  var meanDeltaE: Double
  var maxDeltaE: Double
  /// What to subtract from raw readings.
  var offset: RGB { RGB((0..<3).map { white.values[$0] * flare.values[$0] }) }

  static func measure(_ readings: [String: RGB], reference: IT8Reference, created: Date = Date()) throws -> ScannerCalibration {
    let grays = IT8Layout.grays.compactMap { id in readings[id].map { (t: reference.patches[id]!.y / 100, v: $0) } }
    guard grays.count == 24, grays.allSatisfy({ $0.v.values.allSatisfy { $0 > 0 } }) else {
      throw DeskError.message("灰阶没有读到：请确认 6 个点依次点在色块 A01、A22、L01、L22 和灰阶两端的中心。")
    }
    // Per channel, readings v = white · (T + flare) against the grey scale's transmission T,
    // fitted in density so the dense end counts as much as the light end.
    var white = [Double](), flare = [Double](), before = 0.0, after = 0.0
    for c in 0..<3 {
      func fit(_ f: Double) -> (white: Double, error: Double) {
        let logs = grays.map { log10($0.v.values[c]) - log10($0.t + f) }
        let a = logs.reduce(0, +) / Double(logs.count)
        return (pow(10, a), logs.map { abs($0 - a) }.max()!)
      }
      var best = (f: 0.0, error: Double.infinity, white: 1.0)
      for f in stride(from: 0.0, through: 0.03, by: 0.00002) {
        let r = fit(f)
        if r.error < best.error { best = (f, r.error, r.white) }
      }
      white.append(best.white)
      flare.append(best.f)
      before = max(before, fit(0).error)
      after = max(after, best.error)
    }
    // A matrix from corrected readings to XYZ over every patch, by least squares row by row.
    let ids = IT8Layout.grid + IT8Layout.grays
    let rgb = ids.compactMap { id in readings[id].map { v in (id, (0..<3).map { v.values[$0] / white[$0] - flare[$0] }) } }
    guard rgb.count == ids.count else { throw DeskError.message("有色块没有读到，请重新点选 6 个点。") }
    var ata = [[Double]](repeating: [0, 0, 0], count: 3)
    for (_, v) in rgb { for i in 0..<3 { for j in 0..<3 { ata[i][j] += v[i] * v[j] } } }
    guard let inverse = invert(ata) else { throw DeskError.message("色块读数无法拟合：请确认扫描的是 IT8 色卡本身。") }
    var matrix = [Double]()
    for row in 0..<3 {
      var aty = [0.0, 0.0, 0.0]
      for (id, v) in rgb {
        let p = reference.patches[id]!, target = [p.x, p.y, p.z][row] / 100
        for i in 0..<3 { aty[i] += v[i] * target }
      }
      for j in 0..<3 { matrix.append(inverse[j][0] * aty[0] + inverse[j][1] * aty[1] + inverse[j][2] * aty[2]) }
    }
    var errors = [Double]()
    for (id, v) in rgb {
      let p = reference.patches[id]!
      var xyz = [0.0, 0.0, 0.0]
      for r in 0..<3 { xyz[r] = (matrix[r * 3] * v[0] + matrix[r * 3 + 1] * v[1] + matrix[r * 3 + 2] * v[2]) * 100 }
      errors.append(deltaE(lab(xyz[0], xyz[1], xyz[2]), lab(p.x, p.y, p.z)))
    }
    return ScannerCalibration(
      reference: reference.name + (reference.batch.isEmpty ? "" : " · " + reference.batch), created: created,
      white: RGB(white), flare: RGB(flare), grayErrorBefore: before, grayError: after, matrix: matrix,
      meanDeltaE: errors.reduce(0, +) / Double(errors.count), maxDeltaE: errors.max()!)
  }
  private static func invert(_ m: [[Double]]) -> [[Double]]? {
    let a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], i = m[2][2]
    let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    guard abs(det) > 1e-12 else { return nil }
    return [
      [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
      [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
      [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det],
    ]
  }
  /// CIE L*a*b* under D50.
  static func lab(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
    func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
    let fx = f(x / 96.42), fy = f(y / 100), fz = f(z / 82.49)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
  }
  static func deltaE(_ p: (Double, Double, Double), _ q: (Double, Double, Double)) -> Double {
    ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1) + (p.2 - q.2) * (p.2 - q.2)).squareRoot()
  }
}

extension ImagePipeline {
  /// `image` with `offset` taken from each channel's raw reading: the scanner's stray light.
  func removingFlare(_ offset: RGB, from image: CGImage) -> CGImage {
    let filter = CIFilter(name: "CIColorMatrix")!
    filter.setValue(CIImage(cgImage: image, options: [.colorSpace: NSNull()]), forKey: kCIInputImageKey)
    filter.setValue(CIVector(x: -offset.r, y: -offset.g, z: -offset.b, w: 0), forKey: "inputBiasVector")
    guard let out = filter.outputImage,
      let cg = context.createCGImage(out.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height)),
        from: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA16,
        colorSpace: image.colorSpace ?? outputSpace)
    else { return image }
    return cg
  }
}
