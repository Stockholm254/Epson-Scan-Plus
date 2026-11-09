import Foundation

/// The film's edge around a copied frame: the rebate with its edge print, outside the photograph.
/// A reference of the photograph has no edge, so the reference's correction is not carried onto it
/// (it turned the yellow edge numbers white); the edge is cleaned on its own instead. Unexposed,
/// it is the film's black with the edge print on it, so what a leak put there (a glow over the
/// whole strip, a bright line along the film's side) is taken back to that black, grain kept, and
/// the edge print, small and compact, keeps its own colour.
extension LeakEngine {
  /// Where the photograph ends on each side of `image` (left, top, right, bottom, 0–1), searched
  /// near `hint` (the frame's de-masking region, drawn by hand about the photograph): the straight
  /// line along the whole side where the colour steps from the film's edge to the picture. Nil for
  /// a side with no such line, which is then left to the reference.
  static func pictureEdges(_ image: LeakImage, near hint: [Double]) -> [Double?] {
    let im = image.width > 900 ? resized(image, width: 900) : image
    let w = im.width, h = im.height
    // The step between the three columns (rows) outside a line and the three inside, row by row
    // along the middle of the side, by its largest channel.
    func step(_ vertical: Bool, _ at: Int, outward: Int) -> (fraction: Double, median: Double) {
      let n = vertical ? h : w, along = vertical ? w : h
      guard at - 4 >= 0, at + 4 < along else { return (0, 0) }
      var steps = [Double]()
      for t in stride(from: Int(Double(n) * 0.12), to: Int(Double(n) * 0.88), by: 2) {
        var outer = SIMD3<Double>(repeating: 0), inner = outer
        for k in 1...3 {
          let o = at + outward * k, i = at - outward * k
          outer += vertical ? im.rgb(t * w + o) : im.rgb(o * w + t)
          inner += vertical ? im.rgb(t * w + i) : im.rgb(i * w + t)
        }
        steps.append(absMax((outer - inner) / 3))
      }
      guard !steps.isEmpty else { return (0, 0) }
      return (Double(steps.filter { $0 > 0.06 }.count) / Double(steps.count), median(steps))
    }
    // Left, top, right, bottom: which way is outward, and where to look about the hint.
    let sides: [(vertical: Bool, outward: Int, hint: Double)] = [(true, -1, hint[0]), (false, -1, hint[1]), (true, 1, hint[2]), (false, 1, hint[3])]
    return sides.map { side -> Double? in
      let along = side.vertical ? w : h
      let lo = side.outward < 0 ? side.hint - 0.04 : side.hint - 0.02, hi = side.outward < 0 ? side.hint + 0.02 : side.hint + 0.04
      let from = max(4, Int(lo * Double(along))), to = min(along - 5, Int(hi * Double(along)))
      guard from < to else { return nil }
      var best: (at: Int, median: Double)?
      for at in from...to {
        let s = step(side.vertical, at, outward: side.outward)
        // A line along most of the side, as the film's edge is; an edge in the scene is not.
        guard s.fraction >= 0.8 else { continue }
        if best == nil || s.median > best!.median { best = (at, s.median) }
      }
      guard let best, best.median > 0.12 else { return nil }
      // A side whose edge is at the frame's own border has no film edge to clean.
      let edge = Double(best.at) / Double(along - 1)
      return side.outward < 0 ? (edge > 0.004 ? edge : nil) : (edge < 0.996 ? edge : nil)
    }
  }

  /// `repaired` with the film's edge outside `picture` (as `pictureEdges` gives it) taken from
  /// `original` instead, cleaned: its smooth level brought to the film's black, a long bright run
  /// along the edge (a leak's line) to that black too, the rest (grain, the edge print) kept above
  /// it as it is. Two pixels of blend at the line.
  static func cleanedEdges(_ repaired: LeakImage, original: LeakImage, picture: [Double?]) -> LeakImage {
    let w = original.width, h = original.height
    guard repaired.width == w, repaired.height == h, picture.contains(where: { $0 != nil }) else { return repaired }
    let x0 = picture[0] ?? 0, y0 = picture[1] ?? 0, x1 = picture[2] ?? 1, y1 = picture[3] ?? 1
    func outside(_ x: Double, _ y: Double) -> Bool { x < x0 || x > x1 || y < y0 || y > y1 }
    // The film's black: the darkest fifth of the edge, its median colour.
    var edgeSamples = [SIMD3<Double>]()
    let stepPixels = max(1, min(w, h) / 600)
    for yy in stride(from: 0, to: h, by: stepPixels) {
      for xx in stride(from: 0, to: w, by: stepPixels) {
        let x = Double(xx) / Double(w - 1), y = Double(yy) / Double(h - 1)
        if outside(x, y) { edgeSamples.append(original.rgb(yy * w + xx)) }
      }
    }
    guard edgeSamples.count >= 50 else { return repaired }
    let dark = edgeSamples.sorted { luma($0) < luma($1) }.prefix(max(10, edgeSamples.count / 5))
    let black = SIMD3((0..<3).map { c in median(dark.map { $0[c] }) })

    // The edge's own level, smooth: a low percentile in cells of a hundredth of the frame, then the
    // least within two cells all round, wider than an edge number's bold digits, never under
    // the film's black: a leak only adds light, and what is darker (the holder's edge beside the
    // film, pure black) is not film to measure by.
    let cell = max(4, max(w, h) / 100), cw = (w + cell - 1) / cell, ch = (h + cell - 1) / cell
    var level = [SIMD3<Double>?](repeating: nil, count: cw * ch)
    for cy in 0..<ch {
      for cx in 0..<cw {
        var values: [[Double]] = [[], [], []]
        let sub = max(1, cell / 8)
        for yy in stride(from: cy * cell, to: min(h, (cy + 1) * cell), by: sub) {
          for xx in stride(from: cx * cell, to: min(w, (cx + 1) * cell), by: sub) {
            guard outside(Double(xx) / Double(w - 1), Double(yy) / Double(h - 1)) else { continue }
            let p = original.rgb(yy * w + xx)
            for c in 0..<3 { values[c].append(p[c]) }
          }
        }
        if values[0].count >= 4 { level[cy * cw + cx] = SIMD3((0..<3).map { c in values[c].sorted()[values[c].count / 10] }) }
      }
    }
    var smooth = level
    for cy in 0..<ch {
      for cx in 0..<cw {
        guard level[cy * cw + cx] != nil else { continue }
        var least = level[cy * cw + cx]!
        for dy in -2...2 {
          for dx in -2...2 {
            let nx = cx + dx, ny = cy + dy
            guard nx >= 0, ny >= 0, nx < cw, ny < ch, let v = level[ny * cw + nx] else { continue }
            least = SIMD3(min(least.x, v.x), min(least.y, v.y), min(least.z, v.z))
          }
        }
        smooth[cy * cw + cx] = SIMD3(max(least.x, black.x), max(least.y, black.y), max(least.z, black.z))
      }
    }
    func levelAt(_ xx: Int, _ yy: Int) -> SIMD3<Double> { smooth[min(ch - 1, yy / cell) * cw + min(cw - 1, xx / cell)] ?? black }

    // What stands above that level, as marks. Light piped in along the film's side runs on along
    // it: an unbroken run of marks, down a column or along a row, longer than a twentieth of the
    // frame is the leak's; edge print never runs so far, each stroke and digit short of it, even
    // close to the side. Of the rest, a long thin line or a large patch is a leak's too; edge print
    // is neither, its digits standing a fortieth of the frame across. They are told apart after
    // the runs are taken out, so a glow joining the print to the side's line does not take it along.
    let scale = max(1, max(w, h) / 1800), mw = (w + scale - 1) / scale, mh = (h + scale - 1) / scale
    let side = Double(max(mw, mh))
    var mark = [UInt8](repeating: 0, count: mw * mh), leak = [Bool](repeating: false, count: mw * mh)
    for my in 0..<mh {
      for mx in 0..<mw {
        let xx = min(w - 1, mx * scale), yy = min(h - 1, my * scale)
        guard outside(Double(xx) / Double(w - 1), Double(yy) / Double(h - 1)),
          luma(original.rgb(yy * w + xx)) - luma(levelAt(xx, yy)) > 0.06
        else { continue }
        mark[my * mw + mx] = 1
      }
    }
    let run = Int(side / 20)
    func runs(_ count: Int, _ length: Int, _ index: (Int, Int) -> Int) {
      for line in 0..<count {
        var start = -1
        for t in 0...length {
          let on = t < length && mark[index(line, t)] == 1
          if on && start < 0 { start = t }
          if !on && start >= 0 {
            if t - start > run { for u in start..<t { leak[index(line, u)] = true } }
            start = -1
          }
        }
      }
    }
    runs(mw, mh) { x, y in y * mw + x }
    runs(mh, mw) { y, x in y * mw + x }
    for i in leak.indices where leak[i] { mark[i] = 0 }
    let longest = side / 20, thin = side / 150, patch = (side / 20) * (side / 20)
    for part in components(mark, mw, mh) {
      var lx = mw, hx = 0, ly = mh, hy = 0
      for i in part { let x = i % mw, y = i / mw; lx = min(lx, x); hx = max(hx, x); ly = min(ly, y); hy = max(hy, y) }
      let along = Double(max(hx - lx, hy - ly) + 1), across = Double(min(hx - lx, hy - ly) + 1)
      if (along > longest && across < thin) || Double(part.count) > patch { for i in part { leak[i] = true } }
    }

    var out = repaired
    let feather = 2.0
    out.data.withUnsafeMutableBufferPointer { dst in
      for yy in 0..<h {
        let y = Double(yy) / Double(h - 1)
        for xx in 0..<w {
          let x = Double(xx) / Double(w - 1)
          // How far outside the photograph, in pixels: 0 inside, blended over `feather`.
          let past = max((x0 - x) * Double(w - 1), (x - x1) * Double(w - 1), (y0 - y) * Double(h - 1), (y - y1) * Double(h - 1))
          guard past > -feather else { continue }
          let t = clamp((past + feather) / (2 * feather))
          let i = yy * w + xx, p = original.rgb(i)
          let m = (min(mh - 1, yy / scale)) * mw + min(mw - 1, xx / scale)
          let cleaned = leak[m] ? black : simdClamp(black + p - levelAt(xx, yy))
          let r = repaired.rgb(i), v = r + (cleaned - r) * t
          for c in 0..<3 { dst[i * 3 + c] = UInt16(jsRound(clamp(v[c]) * 65535)) }
        }
      }
    }
    return out
  }
}

@inline(__always) fileprivate func simdClamp(_ v: SIMD3<Double>) -> SIMD3<Double> {
  SIMD3(clamp(v.x), clamp(v.y), clamp(v.z))
}
// The engine's own helpers, which are private to its file.
@inline(__always) fileprivate func luma(_ p: SIMD3<Double>) -> Double { 0.30 * p.x + 0.59 * p.y + 0.11 * p.z }
@inline(__always) fileprivate func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }
fileprivate func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count >> 1] }
@inline(__always) fileprivate func absMax(_ v: SIMD3<Double>) -> Double { max(abs(v.x), abs(v.y), abs(v.z)) }
