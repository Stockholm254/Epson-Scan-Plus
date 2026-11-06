import Foundation

/// Sony pixel shift without a camera: four mosaics sampled from a known colour scene the way the
/// A7R IV's sensor walks round a square compose back into that scene, every point's red, green and
/// blue as it was; four out of order or of different kinds are told.
enum PixelShiftTests {
  /// An uncompressed ARW laid out as the A7R IV writes one: IFD0 pointing to the sensor's SubIFD,
  /// 14-bit RGGB, black 512, white 16383, each photosite `value(x, y)` (black included).
  static func sensorARW(width w: Int, height h: Int, orientation: Int = 1, compression: Int = 1, value: (Int, Int) -> Int) -> Data {
    var d = Data()
    func u16(_ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8 & 0xFF)) }
    func u32(_ v: Int) { u16(v & 0xFFFF); u16(v >> 16) }
    func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) { u16(tag); u16(type); u32(count); u32(value) }
    let sub = 38, black = 176, strip = 184
    d.append(contentsOf: Array("II".utf8)); u16(42); u32(8)
    u16(2); entry(0x112, 3, 1, orientation); entry(0x14A, 4, 1, sub); u32(0)
    u16(11)
    entry(0x100, 3, 1, w); entry(0x101, 3, 1, h); entry(0x102, 3, 1, 14); entry(0x103, 3, 1, compression)
    entry(0x106, 3, 1, 32803); entry(0x111, 4, 1, strip); entry(0x117, 4, 1, w * h * 2)
    entry(0x828D, 3, 2, 2 | 2 << 16); entry(0x828E, 1, 4, 0 | 1 << 8 | 1 << 16 | 2 << 24)
    entry(0x7310, 3, 4, black); entry(0xC61D, 3, 1, 16383); u32(0)
    for _ in 0..<4 { u16(512) }
    for y in 0..<h { for x in 0..<w { u16(min(16383, max(0, value(x, y)))) } }
    return d
  }
  /// The colour at scene point (x, y), above black: every point different in each channel, and
  /// well above the level the greens' agreement is measured from.
  static func scene(_ x: Int, _ y: Int) -> [Int] {
    [2600 + 310 * x + 47 * y, 3000 + 230 * ((x * 7 + y * 3) % 11) + 13 * y, 2400 + 410 * ((x + 2 * y) % 5) + 29 * x]
  }
  /// The four shots of a group of `scene`: shot k's photosite (x, y) saw the scene point the
  /// sensor's walk put there, in its own colour (RGGB).
  static func shots(width w: Int, height h: Int, orientation: Int = 1) -> [Data] {
    SensorRaw.shiftOrder.map { d in
      sensorARW(width: w, height: h, orientation: orientation) { x, y in
        let colour = [0, 1, 1, 2][(y & 1) << 1 | (x & 1)]
        return 512 + scene(x - d.x, y - d.y)[colour]
      }
    }
  }

  /// A smooth colour scene at any point (u, v) of the first shot, above black, with detail enough
  /// everywhere to find a square by.
  static func smooth(_ u: Double, _ v: Double) -> [Double] {
    (0..<3).map { c in 4200 + 300 * Double(c) + 1500 * sin(2 * .pi * u / 9 + Double(c)) * cos(2 * .pi * v / 7 - Double(c)) + 4 * u }
  }
  /// The sixteen shots of a 16-shot group of `smooth` (or a flat grey), its squares at `squares`:
  /// each photosite saw the scene at its own place less its shot's and its square's offset.
  static func shots16(width w: Int, height h: Int, squares: [(x: Double, y: Double)] = SensorRaw.shiftGroups, flat: Bool = false) -> [Data] {
    squares.flatMap { g in
      SensorRaw.shiftOrder.map { d in
        sensorARW(width: w, height: h) { x, y in
          let colour = [0, 1, 1, 2][(y & 1) << 1 | (x & 1)]
          let value = flat ? 5000 : smooth(Double(x - d.x) - g.x, Double(y - d.y) - g.y)[colour]
          return 512 + Int(value.rounded())
        }
      }
    }
  }

  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let root = folder.appendingPathComponent("pixel-shift", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func write(_ files: [Data], _ name: String) throws -> [URL] {
      try files.enumerated().map { k, data in
        let url = root.appendingPathComponent("\(name)-\(k + 1).ARW")
        try data.write(to: url)
        return url
      }
    }
    let w = 12, h = 10, scale = 65535.0 / Double(16383 - 512)
    let urls = try write(shots(width: w, height: h), "group")
    let composed = try SensorRaw.pixelShiftRGB(urls)
    let bytes = composed.flatMap { $0.image.dataProvider?.data as Data? }
    func at(_ x: Int, _ y: Int, width: Int = w) -> [Int] {
      bytes.map { b in (0..<3).map { c in let i = 2 * (3 * (y * width + x) + c); return Int(b[i]) | Int(b[i + 1]) << 8 } } ?? []
    }
    // Inside the edge each point has all four shots' photosites; at the edge the nearest of the same colour stands in.
    var worst = 0
    for y in 1..<h { for x in 0..<(w - 1) {
      let want = scene(x, y).map { Int((Double($0) * scale).rounded()) }
      worst = max(worst, zip(at(x, y), want).map { abs($0 - $1) }.max() ?? 99)
    } }
    try check(composed?.image.width == w && composed?.image.height == h && composed?.image.bitsPerComponent == 16 && worst <= 1
      && composed?.greens == 0,
      "four shots walked round a square compose back into the scene, each point's red, green and blue as measured (off by \(worst) at most), the two greens the same")
    // Two of them swapped: each point's colours from the wrong places, and the greens tell.
    let swapped = try SensorRaw.pixelShiftRGB([urls[0], urls[3], urls[2], urls[1]])
    try check((swapped?.greens ?? 0) > AppModel.shiftGreensLimit,
      String(format: "four out of order are told by their greens: they differ by %.1f%%, the limit is %.0f%%", (swapped?.greens ?? 0) * 100, AppModel.shiftGreensLimit * 100))
    let turned = try SensorRaw.pixelShiftRGB(try write(shots(width: w, height: h, orientation: 6), "turned"))
    var others = try write(shots(width: w, height: h), "mixed")
    try sensorARW(width: w, height: h, compression: 32767) { _, _ in 1000 }.write(to: others[3])
    let compressed = try SensorRaw.pixelShiftRGB(others)
    try sensorARW(width: w + 2, height: h) { _, _ in 1000 }.write(to: others[3])
    let sizes = try SensorRaw.pixelShiftRGB(others)
    others.removeLast()
    let three = try SensorRaw.pixelShiftRGB(others)
    try check(turned?.image.width == h && turned?.image.height == w && compressed == nil && sizes == nil && three == nil,
      "a group is turned as the camera was held; a compressed ARW among them, one of another size or three of four compose nothing")

    // Sixteen shots: four squares a half photosite apart, found where they are and composed at
    // twice the sensor's resolution each way, every point the scene there.
    let w16 = 160, h16 = 120
    let sixteen = try SensorRaw.pixelShift16(try write(shots16(width: w16, height: h16), "sixteen"))
    let doubled = sixteen.flatMap { $0.image.dataProvider?.data as Data? }
    var off = 0.0
    if let doubled {
      for Y in stride(from: 8, to: 2 * h16 - 8, by: 3) { for X in stride(from: 8, to: 2 * w16 - 8, by: 3) {
        let want = smooth(Double(X) / 2, Double(Y) / 2)
        for c in 0..<3 {
          let i = 2 * (3 * (Y * 2 * w16 + X) + c), got = Double(Int(doubled[i]) | Int(doubled[i + 1]) << 8)
          off = max(off, abs(got / scale - want[c]) / want[c])
        }
      } }
    }
    let found = sixteen?.squares.map { String(format: "(%+.2f, %+.2f)", $0.x, $0.y) }.joined(separator: " ") ?? "-"
    try check(sixteen?.image.width == 2 * w16 && sixteen?.image.height == 2 * h16 && sixteen?.measured == true
      && (sixteen?.astray ?? 1) < 0.06 && off < 0.015,
      String(format: "sixteen shots compose at twice the resolution, the squares found where the camera put them (%@), every point within %.1f%% of the scene there", found, off * 100))
    // Supersampled: the doubled grid back at the sensor's size, point x on the first shot's photosite x.
    let native = try SensorRaw.pixelShift16(try write(shots16(width: w16, height: h16), "supersample"), supersample: true)
    let small = native.flatMap { $0.image.dataProvider?.data as Data? }
    var offNative = 0.0
    if let small {
      for y in stride(from: 6, to: h16 - 6, by: 2) { for x in stride(from: 6, to: w16 - 6, by: 2) {
        let want = smooth(Double(x), Double(y))
        for c in 0..<3 {
          let i = 2 * (3 * (y * w16 + x) + c), got = Double(Int(small[i]) | Int(small[i + 1]) << 8)
          offNative = max(offNative, abs(got / scale - want[c]) / want[c])
        }
      } }
    }
    try check(native?.image.width == w16 && native?.image.height == h16 && native?.supersampled == true && offNative < 0.02,
      String(format: "sixteen shots supersampled come back at the sensor's size, each point within %.1f%% of the scene at the first shot's photosite", offNative * 100))
    var astray = SensorRaw.shiftGroups
    astray[2] = (0, -0.15)
    let moved = try SensorRaw.pixelShift16(try write(shots16(width: w16, height: h16, squares: astray), "astray"))
    try check(moved.map { abs($0.squares[2].y + 0.15) < 0.05 && $0.astray > AppModel.shiftSquaresLimit } == true,
      String(format: "a square 0.35 px from its half step is found there (%+.2f) and told: astray %.2f, the limit %.2f",
        moved?.squares[2].y ?? 0, moved?.astray ?? 0, AppModel.shiftSquaresLimit))
    let flat = try SensorRaw.pixelShift16(try write(shots16(width: w16, height: h16, flat: true), "flat"))
    try check(flat.map { !$0.measured && $0.astray == 0 } == true,
      "a picture with no detail to find the squares by is composed with them where the camera means them")
  }
}
