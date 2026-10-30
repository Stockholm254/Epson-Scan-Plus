import CoreGraphics
import Foundation

/// A copy shot cropped to its picture: inside the frame's own edges, turned level with them.
struct PictureCrop: Equatable {
  /// Normalised in the picture's own file from the top left; turned by `angle` it shows the
  /// picture alone.
  var rect: NormalRect
  /// Clockwise on the screen in degrees, as `Adjustments.angle`; nil when the frame lies level.
  var angle: Double?
  /// At how many of the frame's four edges it is cut; at the others, the shot's own.
  var edges: Int
}

/// A frame's edges found in a copy shot: for the top, bottom, left and right in turn, how far in
/// from that side of the shot (`k0`, in pixels of a shot `width` × `height`, at the side's middle)
/// and how it runs (`m`, its depth's change along the side), with the steps found on it; nil where
/// none was found.
struct FrameEdges: Equatable {
  struct Edge: Equatable { var k0: Double, m: Double, votes: Int }
  var edges: [Edge?]
  var width: Int, height: Int
  /// The picture's height (top to bottom) or width (left to right) as a share of the shot's, at
  /// its middle, where both edges were found.
  func span(_ pair: Int) -> Double? {
    guard let a = edges[2 * pair], let b = edges[2 * pair + 1] else { return nil }
    let across = Double(pair == 0 ? height : width)
    return (across - 1 - a.k0 - b.k0) / across
  }

  /// A roll's frames, copied at one magnification, so that its pictures are all about one size:
  /// where a frame's height or width is more than 2% of the shot off the roll's middle one, the
  /// edge further from where that side's edge lies on the roll's other frames (a straight shadow
  /// of the picture as clear as the base, taken for the edge) is put the roll's size from the
  /// other; an edge not found, likewise, if that falls inside the shot. Unchanged with fewer than
  /// three frames showing both edges.
  static func agreeing(_ roll: [FrameEdges?]) -> [FrameEdges?] {
    var roll = roll
    for pair in 0..<2 {
      let spans = roll.compactMap { $0?.span(pair) }
      guard spans.count >= 3 else { continue }
      let size = spans.sorted()[spans.count / 2]
      func middle(_ side: Int) -> Double? {
        let k = roll.compactMap { f in f?.edges[side].map { $0.k0 / Double(side < 2 ? f!.height : f!.width) } }.sorted()
        return k.isEmpty ? nil : k[k.count / 2]
      }
      let usual = [middle(2 * pair), middle(2 * pair + 1)]
      for i in roll.indices {
        guard var f = roll[i] else { continue }
        let across = Double(pair == 0 ? f.height : f.width), a = 2 * pair, b = a + 1
        // The one to move, and the one it is put the roll's size from.
        var move: Int?
        if let span = f.span(pair) {
          guard abs(span - size) > 0.02 else { continue }
          let off = [a, b].map { side in usual[side - a].map { abs(f.edges[side]!.k0 / across - $0) } ?? 0 }
          move = off[0] > off[1] ? a : b
        } else if f.edges[a] == nil, f.edges[b] != nil {
          move = a
        } else if f.edges[b] == nil, f.edges[a] != nil {
          move = b
        }
        guard let move, let from = f.edges[move == a ? b : a] else { continue }
        let k = across - 1 - from.k0 - size * across
        // Opposite sides run alike as seen from each.
        f.edges[move] = k >= 0 ? Edge(k0: k, m: -from.m, votes: 0) : nil
        roll[i] = f
      }
    }
    return roll
  }
}

extension ImagePipeline {
  /// Where the picture lies in a copy shot `image`, as the camera took it, cropped as `crop(_:)`.
  func pictureCrop(_ image: CGImage, inset: Double = 0.005) -> PictureCrop? {
    frameEdges(image).flatMap { crop($0, inset: inset) }
  }
  /// The frame's edges in a copy shot `image`: along each side the straight line where the clear
  /// film outside (the gap to the next frame or the rebate, as clear as the base) turns denser
  /// going in. Along each line across the side (its middle four fifths), the outermost such step
  /// within the outer 30% counts, and of all of them the straight line most fall on, turned up to
  /// 3° either way, is the edge: edge print or a scratch move a few, not the line. Nil when the
  /// shot is too small to look at.
  func frameEdges(_ image: CGImage) -> FrameEdges? {
    let s = samples(image, maxDimension: 1200), w = s.width, h = s.height
    guard w > 80, h > 80 else { return nil }
    let smooth = smoothed(s), bare = bareLight(s)
    func g(_ x: Int, _ y: Int) -> Double { log(max(1e-6, smooth[y * w + x].g)) }
    func clipped(_ x: Int, _ y: Int) -> Bool { bare[y * w + x] }
    // The picture's clearest film, inside its margins: the gaps and the rebate are about as clear.
    var inner = [Double]()
    for y in stride(from: h / 10, to: h - h / 10, by: 2) {
      for x in stride(from: w / 10, to: w - w / 10, by: 2) where !clipped(x, y) { inner.append(g(x, y)) }
    }
    guard !inner.isEmpty else { return nil }
    let clear = quantile(inner, 0.995) + log(0.6)
    typealias Edge = FrameEdges.Edge
    // Side 0 the top, 1 the bottom, 2 the left, 3 the right: depth k in from it, at t along it
    // from its middle.
    func edge(_ side: Int) -> Edge? {
      let across = side < 2 ? w : h, depth = (side < 2 ? h : w) * 3 / 10
      func point(_ t: Int, _ k: Int) -> (Int, Int) {
        switch side {
        case 0: return (t, k)
        case 1: return (t, h - 1 - k)
        case 2: return (k, t)
        default: return (w - 1 - k, t)
        }
      }
      var steps = [(t: Double, k: Double)](), lines = 0
      for t in stride(from: across / 10, to: across - across / 10, by: 2) {
        lines += 1
        for k in 2..<depth {
          let (ox, oy) = point(t, k - 2), (ix, iy) = point(t, k + 2)
          guard !clipped(ox, oy), !clipped(ix, iy), g(ox, oy) >= clear, g(ox, oy) - g(ix, iy) > 0.12 else { continue }
          steps.append((Double(t - across / 2), Double(k)))
          break
        }
      }
      guard steps.count >= lines / 4 else { return nil }
      // The straight line most steps fall on: each angle's offsets, counted within a pixel.
      var best = Edge(k0: 0, m: 0, votes: 0)
      for a in stride(from: -3.0, through: 3.0, by: 0.05) {
        let m = tan(a * .pi / 180)
        var bins = [Int](repeating: 0, count: depth + 2 * across / 10 + 4)
        let shift = across / 10 + 2
        for p in steps {
          let k0 = Int((p.k - m * p.t).rounded()) + shift
          if k0 >= 0 && k0 < bins.count { bins[k0] += 1 }
        }
        for i in 1..<(bins.count - 1) where bins[i - 1] + bins[i] + bins[i + 1] > best.votes {
          best = Edge(k0: Double(i - shift), m: m, votes: bins[i - 1] + bins[i] + bins[i + 1])
        }
      }
      guard best.votes >= lines / 4 else { return nil }
      // Fitted again to the steps on it.
      let on = steps.filter { abs($0.k - best.k0 - best.m * $0.t) <= 1.5 }
      let n = Double(on.count), st = on.map(\.t).reduce(0, +), sk = on.map(\.k).reduce(0, +)
      let stt = on.map { $0.t * $0.t }.reduce(0, +), stk = on.map { $0.t * $0.k }.reduce(0, +)
      let d = n * stt - st * st
      guard d > 0 else { return best }
      let m = (n * stk - st * sk) / d
      return Edge(k0: (sk - m * st) / n, m: m, votes: on.count)
    }
    return FrameEdges(edges: (0..<4).map(edge), width: w, height: h)
  }
  /// The crop of a copy shot from its frame's `found` edges: the picture `inset` (of its shorter
  /// side) inside them, turned level with them. A side without one (the picture runs past the
  /// shot) is cut at the shot's edge. Nil when no edge is found.
  func crop(_ found: FrameEdges, inset: Double = 0.005) -> PictureCrop? {
    typealias Edge = FrameEdges.Edge
    let edges = found.edges, w = found.width, h = found.height
    let measured = edges.indices.filter { edges[$0] != nil }
    guard !measured.isEmpty else { return nil }
    // The tilt from the edges found in the shot, not those put from the roll's size.
    let found = measured.filter { edges[$0]!.votes > 0 }
    // How far the picture is turned clockwise, from each edge found, weighted by its steps.
    func tilt(_ side: Int, _ e: Edge) -> Double { (side == 0 || side == 3 ? 1 : -1) * atan(e.m) }
    let votes = found.map { Double(edges[$0]!.votes) }.reduce(0, +)
    let phi = votes > 0 ? found.map { tilt($0, edges[$0]!) * Double(edges[$0]!.votes) }.reduce(0, +) / votes : 0
    // Each side as a line through a point, along a direction, in pixels; a side not found, the
    // shot's own edge turned with the rest, kept inside the shot.
    let c = cos(phi), sn = sin(phi)
    func line(_ side: Int) -> (p: CGPoint, d: CGVector) {
      let along = side < 2 ? CGVector(dx: c, dy: sn) : CGVector(dx: -sn, dy: c)
      let e = edges[side] ?? Edge(k0: abs(tan(phi)) * Double(side < 2 ? w : h) / 2, m: 0, votes: 0)
      let k = e.k0
      switch side {
      case 0: return (CGPoint(x: Double(w) / 2, y: k), along)
      case 1: return (CGPoint(x: Double(w) / 2, y: Double(h - 1) - k), along)
      case 2: return (CGPoint(x: k, y: Double(h) / 2), along)
      default: return (CGPoint(x: Double(w - 1) - k, y: Double(h) / 2), along)
      }
    }
    func meet(_ a: (p: CGPoint, d: CGVector), _ b: (p: CGPoint, d: CGVector)) -> CGPoint {
      let det = a.d.dx * b.d.dy - a.d.dy * b.d.dx
      let u = ((b.p.x - a.p.x) * b.d.dy - (b.p.y - a.p.y) * b.d.dx) / det
      return CGPoint(x: a.p.x + u * a.d.dx, y: a.p.y + u * a.d.dy)
    }
    let top = line(0), bottom = line(1), left = line(2), right = line(3)
    let corners = [meet(top, left), meet(top, right), meet(bottom, right), meet(bottom, left)]
    let centre = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
    func length(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(b.x - a.x), Double(b.y - a.y)) }
    let width = (length(corners[0], corners[1]) + length(corners[3], corners[2])) / 2
    let height = (length(corners[0], corners[3]) + length(corners[1], corners[2])) / 2
    let cut = inset * min(width, height)
    let kept = (width: width - 2 * cut, height: height - 2 * cut)
    guard kept.width > Double(w) / 4, kept.height > Double(h) / 4 else { return nil }
    // Turned back by the tilt, the frame shows the largest rectangle of its own shape inside: the
    // crop is that much larger than the picture, and no larger than the shot allows about its middle.
    let degrees = abs(phi) * 180 / .pi < 0.03 ? 0 : -phi * 180 / .pi
    let k = ImageGeometry.keep(degrees, aspect: kept.width / kept.height)
    var cw = kept.width / k, ch = kept.height / k
    let fits = min(1, 2 * Double(centre.x) / cw, 2 * (Double(w) - Double(centre.x)) / cw, 2 * Double(centre.y) / ch, 2 * (Double(h) - Double(centre.y)) / ch)
    cw *= fits
    ch *= fits
    let rect = NormalRect(
      x: (Double(centre.x) - cw / 2) / Double(w), y: (Double(centre.y) - ch / 2) / Double(h),
      width: cw / Double(w), height: ch / Double(h))
    return PictureCrop(rect: rect, angle: degrees == 0 ? nil : (degrees * 100).rounded() / 100, edges: measured.count)
  }
}
