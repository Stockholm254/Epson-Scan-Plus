import Foundation

/// A frame's grade undone: the colour map from one rendering of a frame to another of the same
/// frame and framing, fitted pixel for pixel. Old 去漏光 jobs were made of the graded positive;
/// reloaded from ② 去色罩's result, their reference (a clean version of the graded picture) is
/// mapped by it first, so the repair fitted to it does not carry the old grade into ③, which
/// grades the repaired picture again.
struct LeakGradeMap {
  /// Cells a side of the colour cube the map's residual is kept in.
  static let side = 17
  /// Two renderings closer than this (mean absolute, 0–1) need no map.
  static let negligible = 1.5 / 255
  /// A map missing the second rendering by more than this is not of the same picture: framed or
  /// cropped otherwise, or another frame.
  static let unusable = 6.0 / 255

  /// out = rows[c] · (r, g, b, 1): the map's broad part, in the pictures' own encoding (0–1).
  var rows: [SIMD4<Double>]
  /// What the broad part leaves, by colour, trilinear between the cube's cells.
  var residual: [SIMD3<Double>]
  /// How far the map misses the second picture on samples it was not fitted on, and how far apart
  /// the two pictures were there, both mean absolute 0–1.
  var error: Double
  var apart: Double

  /// What the map says of the two pictures: worth taking the reference by it; too close for it to
  /// matter (what is left is the sharpening and the like, which no colour map undoes); or not the
  /// same picture, framed otherwise.
  enum Verdict { case use, slight, mismatch }
  var verdict: Verdict {
    if error > Self.unusable || (apart > 4.0 / 255 && error > apart * 0.6) { return .mismatch }
    if apart < Self.negligible || error >= apart * 0.6 { return .slight }
    return .use
  }
  var usable: Bool { verdict == .use }

  /// The map taking `a`'s colours to `b`'s, read at `samples` × `samples` places across both
  /// (0–1, so the two may differ in size).
  static func fit(from a: LeakImage, to b: LeakImage, samples: Int = 240) -> LeakGradeMap {
    var pairs = [(x: SIMD3<Double>, y: SIMD3<Double>)]()
    pairs.reserveCapacity(samples * samples)
    for j in 0..<samples {
      for i in 0..<samples {
        let u = (Double(i) + 0.5) / Double(samples), v = (Double(j) + 0.5) / Double(samples)
        pairs.append((a.at(u, v), b.at(u, v)))
      }
    }
    // Every seventh pair held out, to say how well the map does where it was not fitted.
    let held = pairs.indices.filter { $0 % 7 == 3 }.map { pairs[$0] }
    let fitted = pairs.indices.filter { $0 % 7 != 3 }.map { pairs[$0] }

    // The broad part: an affine map of the three channels, least squares.
    var m = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
    var v = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3)
    for p in fitted {
      let x = [p.x.x, p.x.y, p.x.z, 1]
      for r in 0..<4 {
        for c in 0..<4 { m[r][c] += x[r] * x[c] }
        for k in 0..<3 { v[k][r] += x[r] * p.y[k] }
      }
    }
    let ridge = 1e-6 * Double(max(1, fitted.count))
    for r in 0..<4 { m[r][r] += ridge }
    let rows = (0..<3).map { k -> SIMD4<Double> in
      let s = solve(m, v[k]) ?? (k == 0 ? [1, 0, 0, 0] : k == 1 ? [0, 1, 0, 0] : [0, 0, 1, 0])
      return SIMD4(s[0], s[1], s[2], s[3])
    }
    var map = LeakGradeMap(rows: rows, residual: [SIMD3<Double>](repeating: .zero, count: side * side * side), error: 0, apart: 0)

    // What it leaves, by colour: spread into the cube's cells, each the weighted mean of what fell
    // near it (drawn a little toward none where little did).
    var sum = [SIMD3<Double>](repeating: .zero, count: side * side * side)
    var weight = [Double](repeating: 0, count: side * side * side)
    for p in fitted {
      let r = p.y - map.broad(p.x)
      map.corners(p.x) { cell, w in
        sum[cell] += w * r
        weight[cell] += w
      }
    }
    var known = [Bool](repeating: false, count: side * side * side)
    for cell in 0..<(side * side * side) where weight[cell] > 0.25 {
      map.residual[cell] = sum[cell] / (weight[cell] + 1)
      known[cell] = true
    }
    // Colours the first picture never showed (a reference's clean sky where the picture had a leak,
    // say): from their neighbours, fading to the broad part alone further out.
    for _ in 0..<48 {
      var next = map.residual
      for b in 0..<side { for g in 0..<side { for r in 0..<side {
        let cell = index(r, g, b)
        if known[cell] { continue }
        var total = SIMD3<Double>.zero, n = 0.0
        for (dr, dg, db) in [(-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1)] {
          let (rr, gg, bb) = (r + dr, g + dg, b + db)
          guard rr >= 0, rr < side, gg >= 0, gg < side, bb >= 0, bb < side else { continue }
          total += map.residual[index(rr, gg, bb)]
          n += 1
        }
        next[cell] = n > 0 ? 0.92 * total / n : .zero
      } } }
      map.residual = next
    }

    var missed = 0.0, apart = 0.0
    for p in held {
      let d = map.apply(p.x) - p.y, e = p.x - p.y
      missed += (abs(d.x) + abs(d.y) + abs(d.z)) / 3
      apart += (abs(e.x) + abs(e.y) + abs(e.z)) / 3
    }
    let n = Double(max(1, held.count))
    map.error = missed / n
    map.apart = apart / n
    return map
  }

  @inline(__always) static func index(_ r: Int, _ g: Int, _ b: Int) -> Int { (b * side + g) * side + r }
  @inline(__always) func broad(_ p: SIMD3<Double>) -> SIMD3<Double> {
    let x = SIMD4(p.x, p.y, p.z, 1)
    return SIMD3((rows[0] * x).sum(), (rows[1] * x).sum(), (rows[2] * x).sum())
  }
  /// The cube's eight cells around a colour, with their trilinear weights.
  @inline(__always) func corners(_ p: SIMD3<Double>, _ each: (Int, Double) -> Void) {
    let s = Double(Self.side - 1)
    let t = SIMD3(min(max(p.x, 0), 1), min(max(p.y, 0), 1), min(max(p.z, 0), 1)) * s
    let r0 = min(Int(t.x), Self.side - 2), g0 = min(Int(t.y), Self.side - 2), b0 = min(Int(t.z), Self.side - 2)
    let f = t - SIMD3(Double(r0), Double(g0), Double(b0))
    for k in 0..<8 {
      let (dr, dg, db) = (k & 1, (k >> 1) & 1, (k >> 2) & 1)
      let w = (dr == 1 ? f.x : 1 - f.x) * (dg == 1 ? f.y : 1 - f.y) * (db == 1 ? f.z : 1 - f.z)
      if w > 0 { each(Self.index(r0 + dr, g0 + dg, b0 + db), w) }
    }
  }
  /// One colour mapped, 0–1.
  func apply(_ p: SIMD3<Double>) -> SIMD3<Double> {
    var r = SIMD3<Double>.zero
    corners(p) { cell, w in r += w * residual[cell] }
    let out = broad(p) + r
    return SIMD3(min(max(out.x, 0), 1), min(max(out.y, 0), 1), min(max(out.z, 0), 1))
  }
  /// A picture mapped, pixel by pixel.
  func apply(_ image: LeakImage) -> LeakImage {
    var data = image.data
    let rows = 64
    data.withUnsafeMutableBufferPointer { buffer in
      let out = buffer
      // Bands of rows apart, each written by one thread.
      DispatchQueue.concurrentPerform(iterations: (image.height + rows - 1) / rows) { band in
        for y in (band * rows)..<min(image.height, (band + 1) * rows) {
          for x in 0..<image.width {
            let i = y * image.width + x
            let q = apply(image.rgb(i)) * 65535
            out[i * 3] = UInt16(q.x.rounded())
            out[i * 3 + 1] = UInt16(q.y.rounded())
            out[i * 3 + 2] = UInt16(q.z.rounded())
          }
        }
      }
    }
    return LeakImage(width: image.width, height: image.height, data: data)
  }

  /// m · x = v for a small square system, by elimination with partial pivoting.
  private static func solve(_ m: [[Double]], _ v: [Double]) -> [Double]? {
    let n = v.count
    var a = m, b = v
    for c in 0..<n {
      guard let p = (c..<n).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[p][c]) > 1e-12 else { return nil }
      a.swapAt(c, p); b.swapAt(c, p)
      for r in (c + 1)..<n {
        let f = a[r][c] / a[c][c]
        for k in c..<n { a[r][k] -= f * a[c][k] }
        b[r] -= f * b[c]
      }
    }
    var x = [Double](repeating: 0, count: n)
    for r in stride(from: n - 1, through: 0, by: -1) {
      var s = b[r]
      for k in (r + 1)..<n { s -= a[r][k] * x[k] }
      x[r] = s / a[r][r]
    }
    return x
  }
}
