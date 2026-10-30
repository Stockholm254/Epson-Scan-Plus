import CoreGraphics
import Foundation

/// The film base read off the unexposed film at a picture's edges: in a copy shot the rebate and
/// the gaps beside the frame, the least dense film there is, as C1's base pick takes it. Nil `base`
/// when the edges show none (cropped to the picture, or only the holder and bare light there).
struct EdgeBase: Codable, Equatable {
  var base: RGB?
  /// Where it was read, in the picture's own file normalised from the top left: cells of a grid
  /// about a hundred across, a run of them a box.
  var areas: [NormalRect]
}

extension ImagePipeline {
  /// The unexposed film along `image`'s edges. Along each side, the frame's own edge first: the
  /// straight line where, across a good part of the side, the film turns denser going in. Only the
  /// film outside it is the rebate or a gap; a deep shadow of the picture that reaches the edge,
  /// nearly as clear and of nearly the base's colour, lies inside it, and a side without such a line
  /// gives nothing. Of the film outside, what is clear and even: below clipping (bare light past
  /// the film), nearly as clear as the clearest of the picture or clearer (the base is the least
  /// dense film there is; the copy light falls off towards the edges), and the same along the side
  /// (not grain, edge print or a sprocket's rim). Of that, the colour most of it shares, so bare
  /// light and the holder do not mix in.
  func edgeBase(_ image: CGImage) -> EdgeBase {
    let s = samples(image, maxDimension: 960), w = s.width, h = s.height
    guard w > 40, h > 40 else { return EdgeBase(base: nil, areas: []) }
    // Smoothed first: the base's grain alone would break its evenness.
    let smooth = smoothed(s), bare = bareLight(s)
    func at(_ x: Int, _ y: Int) -> RGB { smooth[y * w + x] }
    func clipped(_ x: Int, _ y: Int) -> Bool { bare[min(h - 1, max(0, y)) * w + min(w - 1, max(0, x))] }
    // The picture's clearest film, inside its margins: the base is at least as clear, lit as well.
    var inner = [Double]()
    for y in stride(from: h / 10, to: h - h / 10, by: 2) {
      for x in stride(from: w / 10, to: w - w / 10, by: 2) {
        let p = at(x, y)
        if !clipped(x, y) { inner.append(p.g) }
      }
    }
    guard !inner.isEmpty else { return EdgeBase(base: nil, areas: []) }
    let clearest = quantile(inner, 0.995)
    let bandX = max(6, w / 8), bandY = max(6, h / 8)
    // Each side's frame line, counted from the side's edge in: the first place, within the outer
    // eighth, where the film is denser 4 px further in (by over 0.05 D in green) across at least 30%
    // of the side's middle, with film, not clipped bare light, outside it in most of those places.
    // Bare light against the rebate makes a step further out, which this passes over; an edge in the
    // picture lies further in.
    func frameLine(_ side: Int) -> Int? {
      let depth = side < 2 ? bandY : bandX
      for k in 2..<(depth - 2) {
        var denser = 0, filmOutside = 0, n = 0
        func look(_ ox: Int, _ oy: Int, _ ix: Int, _ iy: Int) {
          n += 1
          guard log(max(1e-6, at(ox, oy).g) / max(1e-6, at(ix, iy).g)) > 0.12 else { return }
          denser += 1
          if !clipped(ox, oy) { filmOutside += 1 }
        }
        if side < 2 {
          let y = side == 0 ? k : h - 1 - k, out = side == 0 ? y - 2 : y + 2, inside = side == 0 ? y + 2 : y - 2
          for x in stride(from: bandX, to: w - bandX, by: 2) { look(x, out, x, inside) }
        } else {
          let x = side == 2 ? k : w - 1 - k, out = side == 2 ? x - 2 : x + 2, inside = side == 2 ? x + 2 : x - 2
          for y in stride(from: bandY, to: h - bandY, by: 2) { look(out, y, inside, y) }
        }
        if n > 0, Double(denser) >= 0.3 * Double(n), 2 * filmOutside >= denser { return k }
      }
      return nil
    }
    let lines = (0..<4).map(frameLine)
    struct Candidate { let x: Int, y: Int, v: RGB, side: Int }
    var found = [Candidate]()
    for y in 0..<h {
      for x in 0..<w {
        // The side it lies along, and how far in from that side's edge.
        let (side, k): (Int, Int) = y < bandY ? (0, y) : y >= h - bandY ? (1, h - 1 - y) : x < bandX ? (2, x) : x >= w - bandX ? (3, w - 1 - x) : (-1, 0)
        guard side >= 0, let line = lines[side], k < line - 1 else { continue }
        let v = at(x, y)
        guard !clipped(x, y), min(v.r, v.g, v.b) > 0.002, v.g >= clearest * 0.6 else { continue }
        // Even along the side: within 4% of the film two pixels either way, every channel, once
        // smoothed. Across, a band of base may be only a few pixels wide.
        let along = side < 2 ? [at(max(0, x - 2), y), at(min(w - 1, x + 2), y)] : [at(x, max(0, y - 2)), at(x, min(h - 1, y + 2))]
        let even = along.allSatisfy { n in
          (0..<3).allSatisfy { abs(log(max(1e-6, n.values[$0]) / v.values[$0])) < 0.04 }
        }
        if even { found.append(Candidate(x: x, y: y, v: v, side: side)) }
      }
    }
    // The colour most of it shares, in steps of 4% of red and blue against green.
    func colour(_ v: RGB) -> (Double, Double) { (log(v.r / v.g), log(v.b / v.g)) }
    var counts = [String: Int]()
    for c in found {
      let (a, b) = colour(c.v)
      counts["\(Int((a / 0.04).rounded())) \(Int((b / 0.04).rounded()))", default: 0] += 1
    }
    guard let mode = counts.max(by: { $0.value < $1.value })?.key else { return EdgeBase(base: nil, areas: []) }
    let parts = mode.split(separator: " ").compactMap { Double($0) }
    let centre = (parts[0] * 0.04, parts[1] * 0.04)
    var members = found.filter { c in
      let (a, b) = colour(c.v)
      return abs(a - centre.0) < 0.06 && abs(b - centre.1) < 0.06
    }
    // Of that colour, the clearest: within 8% of its brightest, as the base is the clearest film.
    let clearestOfIt = quantile(members.map(\.v.g), 0.9)
    members = members.filter { abs(log($0.v.g / clearestOfIt)) < 0.08 }
    // The rebate and the gaps run along the whole side: only a row (along the top or bottom) or a
    // column (along a side) with a good part of it so counts (sprocket holes, edge print and grain
    // take the rest), not a clear patch of the picture.
    var rows = [Int: Int](), columns = [Int: Int]()
    for c in members {
      if c.side < 2 { rows[c.y, default: 0] += 1 } else { columns[c.x, default: 0] += 1 }
    }
    members = members.filter { c in
      c.side < 2 ? Double(rows[c.y] ?? 0) >= 0.3 * Double(w - 4) : Double(columns[c.x] ?? 0) >= 0.3 * Double(h - 2 * bandY)
    }
    // Only the film joined to the picture's border through more of it: the rebate and the gaps,
    // not a patch of the picture near its edge that happens to be as clear and of that colour.
    var member = [Bool](repeating: false, count: w * h), joined = [Bool](repeating: false, count: w * h)
    for c in members { member[c.y * w + c.x] = true }
    var queue = members.filter { $0.x <= 4 || $0.x >= w - 5 || $0.y <= 4 || $0.y >= h - 5 }.map { $0.y * w + $0.x }
    for i in queue { joined[i] = true }
    while let i = queue.popLast() {
      let x = i % w, y = i / w
      for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
        let j = ny * w + nx
        if member[j] && !joined[j] {
          joined[j] = true
          queue.append(j)
        }
      }
    }
    members = members.filter { joined[$0.y * w + $0.x] }
    guard members.count >= max(30, w * h / 2000) else { return EdgeBase(base: nil, areas: []) }
    let base = RGB((0..<3).map { c in quantile(members.map { $0.v.values[c] }, 0.5) })
    // Where, on a grid of cells about a hundred across: each row's runs of cells, a run one box,
    // and the same run on the rows below it the same box.
    let gw = 96, gh = max(1, Int((Double(gw) * Double(h) / Double(w)).rounded()))
    var cells = Set<Int>()
    for c in members { cells.insert(min(gh - 1, c.y * gh / h) * gw + min(gw - 1, c.x * gw / w)) }
    var runs = [(x: Int, length: Int, y: Int, rows: Int)]()
    for gy in 0..<gh {
      var gx = 0
      while gx < gw {
        guard cells.contains(gy * gw + gx) else { gx += 1; continue }
        let start = gx
        while gx < gw && cells.contains(gy * gw + gx) { gx += 1 }
        if let i = runs.lastIndex(where: { $0.x == start && $0.length == gx - start && $0.y + $0.rows == gy }) {
          runs[i].rows += 1
        } else {
          runs.append((start, gx - start, gy, 1))
        }
      }
    }
    let areas = runs.map {
      NormalRect(x: Double($0.x) / Double(gw), y: Double($0.y) / Double(gh), width: Double($0.length) / Double(gw), height: Double($0.rows) / Double(gh))
    }
    return EdgeBase(base: base, areas: areas)
  }
  /// `s` smoothed by a 3 × 3 box.
  func smoothed(_ s: Samples) -> [RGB] {
    let w = s.width, h = s.height
    var smooth = [RGB](repeating: .zero, count: w * h)
    for y in 0..<h {
      for x in 0..<w {
        var sum = [0.0, 0.0, 0.0]
        for dy in -1...1 {
          for dx in -1...1 {
            let p = s.pixel(x + dx, y + dy)
            sum[0] += p.r
            sum[1] += p.g
            sum[2] += p.b
          }
        }
        smooth[y * w + x] = RGB(sum.map { $0 / 9 })
      }
    }
    return smooth
  }
  /// Where `s` shows bare light past the film, and 3 px about it: shrunk and smoothed, its rim reads
  /// as film that is not clipped. Each channel clips where a pile of pixels sits at its very top
  /// (read as full by the sensor however the file scales it), else at nearly 1.
  func bareLight(_ s: Samples) -> [Bool] {
    let w = s.width, h = s.height
    let clip = (0..<3).map { c -> Double in
      var top = 0.0
      for i in stride(from: c, to: s.values.count, by: 4) { top = max(top, Double(s.values[i])) }
      var piled = 0
      for i in stride(from: c, to: s.values.count, by: 4) where Double(s.values[i]) >= top - 0.002 { piled += 1 }
      return top > 0.3 && piled >= w * h / 500 ? top - 0.004 : 0.99
    }
    var bare = [Bool](repeating: false, count: w * h)
    for y in 0..<h {
      for x in 0..<w {
        let p = s.pixel(x, y)
        guard p.r >= clip[0] || p.g >= clip[1] || p.b >= clip[2] else { continue }
        for yy in max(0, y - 3)...min(h - 1, y + 3) { for xx in max(0, x - 3)...min(w - 1, x + 3) { bare[yy * w + xx] = true } }
      }
    }
    return bare
  }
  /// One base for a roll from its frames' edges: those whose base shares the colour most of them
  /// have (within 4%), their median. Which frames it came from, with it.
  func rollEdgeBase(_ bases: [(id: UUID, base: RGB)]) -> (base: RGB, from: [UUID])? {
    guard !bases.isEmpty else { return nil }
    func colour(_ v: RGB) -> (Double, Double) { (log(v.r / v.g), log(v.b / v.g)) }
    let a = quantile(bases.map { colour($0.base).0 }, 0.5), b = quantile(bases.map { colour($0.base).1 }, 0.5)
    let agreeing = bases.filter { abs(colour($0.base).0 - a) < 0.04 && abs(colour($0.base).1 - b) < 0.04 }
    guard !agreeing.isEmpty else { return nil }
    return (RGB((0..<3).map { c in quantile(agreeing.map { $0.base.values[c] }, 0.5) }), agreeing.map(\.id))
  }
}
