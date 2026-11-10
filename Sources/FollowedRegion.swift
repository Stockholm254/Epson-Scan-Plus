import CoreGraphics
import Foundation

/// The de-masking region while it follows the picture (`Adjustments.analysisRegion` nil): the crop
/// less its outer 5%, and less the film's own edge where the crop takes some in. A copy cropped
/// wide keeps the rebate round the photograph: unexposed base with the edge print on it, on 135
/// the sprocket holes, past them the holder or bare light. None of it is the photograph, and read
/// as if it were it moved the base estimate, the white balance and the levels: a slide's Dmax rebate
/// was its black, a negative's print its highlights. Where the film's edge is found, the region
/// starts 1.5% inside it, never nearer the crop's side than the 5% it always left out, so a crop
/// with no film edge in it reads exactly what it did.
extension ImagePipeline {
  /// How far in from the top, bottom, left and right of `s` (a frame's picture as cropped, unturned,
  /// brought to about 480 pixels) the photograph starts where the film's edge lies inside the crop,
  /// as a share of the crop's height or width; nil for a side with none found.
  ///
  /// Along each side, every place within its outer 30% where film like the edge (`slide`: as dark as
  /// the darkest film, the rebate's Dmax; else at least 0.6 as clear as `base`, a negative's picked
  /// base or the roll's, without which only the sprocket holes are looked for) or bare light
  /// steps to the picture, four pixels on, by over 0.12 in log green; of those, the straight lines,
  /// turned up to 3° either way, that over half the lines across the side fall on. Of those lines,
  /// the ones with the film's edge outside them: at least 85% of what lies outside is like the edge
  /// or bare light, under half of it bare light (the film's cut edge, the holder's), even (on a
  /// negative 70% of its steps along the side within 0.012, as the base's grain is; on a slide half),
  /// and on a negative 60% or more of it at least 0.85 as clear as the base, not a shade nearly as
  /// clear. Of those, the deepest with at least 70% of the most-voted one's lines:
  /// edge print, the holes' rims and a rim of light at the film's cut edge make lines further out.
  ///
  /// On 135 the sprocket holes are looked for too: four or more bright openings in a row along the
  /// side, each 25–80% of their pitch long and the row 35–85% of it deep, the pitch steady within
  /// 15% (the holes are 1.98 mm along the film by 2.79 across, every 4.75 mm, and the frame starts
  /// about 0.7 mm, 0.15 of the pitch, inside them). The picture's own edge stands where it lies past
  /// them; where it was not found (a slide's night frame, as dark as its rebate) or lies at them, the
  /// picture is put 0.2 of the pitch inside the holes.
  func filmEdgeDepths(_ s: Samples, slide: Bool, gamma: Double = 1, base: RGB? = nil) -> [Double?] {
    let w = s.width, h = s.height, none: [Double?] = [nil, nil, nil, nil]
    guard w >= 60, h >= 60 else { return none }
    let smooth = smoothed(s), bare = bareLight(s), gamma = max(0.1, gamma)
    var g = [Double](repeating: 0, count: w * h), film = [Double]()
    film.reserveCapacity(w * h)
    for i in 0..<(w * h) {
      g[i] = log(max(1e-6, smooth[i].g)) * gamma
      if !bare[i] { film.append(g[i]) }
    }
    guard film.count >= w * h / 4 else { return none }
    // The film's edge is the darkest film on a slide; on a negative the base, and only where it is
    // known: the clearest film stands for it badly, a rim of light at the film's cut edge (not
    // clipped) being clearer still and a shade of the picture as clear where there is no rebate.
    let known = slide ? nil : base.map { log(max(1e-6, $0.g)) * gamma }
    let ref = known ?? quantile(film, 0.005)
    // Like the film's edge; bright as a sprocket hole (a slide's holes need not clip).
    var edge = [Bool](repeating: false, count: w * h), bright = bare
    for i in 0..<(w * h) {
      edge[i] = bare[i] || (slide ? g[i] <= ref + 0.3 : g[i] >= ref + log(0.6))
      if slide, g[i] >= ref + log(10) { bright[i] = true }
    }
    let baseLevel = known.map { $0 + log(0.85) }
    /// The picture's edge on `side` with the sprocket holes along it taken into account: its own
    /// where that lies past them, else 0.2 of their pitch inside them.
    func holeDepth(_ side: Int, picture: Double? = nil) -> Double? {
      guard let holes = sprocketHoles(side) else { return picture }
      if let picture, picture > holes.inner + 0.05 * holes.pitch { return picture }
      return holes.inner + 0.2 * holes.pitch
    }
    /// The inner edge of a row of 135 sprocket holes along `side` and their pitch, as shares of
    /// the depth across that side; nil without one.
    func sprocketHoles(_ side: Int) -> (inner: Double, pitch: Double)? {
      let deep = side < 2 ? h : w, along = side < 2 ? w : h, depth = deep * 3 / 10
      func lit(_ k: Int, _ t: Int) -> Bool {
        switch side {
        case 0: return bright[k * w + t]
        case 1: return bright[(h - 1 - k) * w + t]
        case 2: return bright[t * w + k]
        default: return bright[t * w + (w - 1 - k)]
        }
      }
      var rows = [(k: Int, pitch: Double)]()
      for k in 0..<depth {
        // The openings wholly inside the side.
        var runs = [(Int, Int)](), t = 0
        while t < along {
          guard lit(k, t) else { t += 1; continue }
          let start = t
          while t < along && lit(k, t) { t += 1 }
          if start > 0 && t < along { runs.append((start, t)) }
        }
        guard runs.count >= 4 else { continue }
        let lengths = runs.map { Double($0.1 - $0.0) }
        let centres = runs.map { Double($0.0 + $0.1) / 2 }
        let gaps = zip(centres.dropFirst(), centres).map { $0 - $1 }
        func spread(_ v: [Double]) -> Double {
          let mean = v.reduce(0, +) / Double(v.count)
          return sqrt(v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count))
        }
        let pitch = quantile(gaps, 0.5), length = quantile(lengths, 0.5)
        let meanLength = lengths.reduce(0, +) / Double(lengths.count)
        guard spread(lengths) <= 0.25 * meanLength, spread(gaps) <= 0.15 * pitch,
          length >= 0.25 * pitch, length <= 0.8 * pitch
        else { continue }
        rows.append((k, pitch))
      }
      guard !rows.isEmpty else { return nil }
      // The longest run of such rows, two missed between allowed.
      var runs = [[(k: Int, pitch: Double)]]()
      for r in rows {
        if let last = runs.last?.last, r.k - last.k <= 3 { runs[runs.count - 1].append(r) } else { runs.append([r]) }
      }
      let run = runs.max { $0.count < $1.count }!
      let pitch = quantile(run.map(\.pitch), 0.5), height = Double(run.last!.k - run.first!.k + 1)
      guard height >= 0.35 * pitch, height <= 0.85 * pitch else { return nil }
      // Bare light is grown 3 px (`bareLight`).
      return (Double(run.last!.k - 3 + 1) / Double(deep), pitch / Double(deep))
    }
    return (0..<4).map { side in
      // Depth k in from the side, at t along it.
      let deep = side < 2 ? h : w, along = side < 2 ? w : h
      func at(_ k: Int, _ t: Int) -> Int {
        switch side {
        case 0: return k * w + t
        case 1: return (h - 1 - k) * w + t
        case 2: return t * w + k
        default: return t * w + (w - 1 - k)
        }
      }
      let depth = deep * 3 / 10, lo = along / 10, hi = along - along / 10, lines = hi - lo
      guard depth > 6, lines > 10 else { return nil }
      guard slide || known != nil else { return holeDepth(side) }
      // Each line's steps, each at its steepest.
      var steps = [(t: Int, k: Int)]()
      for t in lo..<hi {
        var best: (k: Int, step: Double)?
        for k in 2..<depth {
          let o = at(k - 2, t), i = at(k + 2, t)
          let step = slide ? g[i] - g[o] : g[o] - g[i]
          if edge[o], !bare[i], step > 0.12, !bare[o] || !edge[i] {
            if best == nil || step > best!.step { best = (k, step) }
          } else if let b = best {
            steps.append((t, b.k))
            best = nil
          }
        }
        if let b = best { steps.append((t, b.k)) }
      }
      // The lines they fall on: at each tilt, how many lines across the side have a step within a
      // pixel of each depth at the side's middle; the tilt most fall on, for each depth.
      let shift = Int(ceil(tan(3 * Double.pi / 180) * Double(along) / 2)) + 2
      var lines0 = [Int: (votes: Int, m: Double)]()
      for a in stride(from: -3.0, through: 3.0001, by: 0.1) {
        let m = tan(a * .pi / 180)
        var count = [Int](repeating: 0, count: depth + 2 * shift + 2), last = [Int](repeating: -1, count: count.count)
        for p in steps {
          let k0 = Int((Double(p.k) - m * (Double(p.t) - Double(along) / 2)).rounded()) + shift
          for b in (k0 - 1)...(k0 + 1) where b >= 0 && b < count.count && last[b] != p.t {
            count[b] += 1
            last[b] = p.t
          }
        }
        for (b, n) in count.enumerated() where 2 * n >= lines && n > (lines0[b - shift]?.votes ?? 0) {
          lines0[b - shift] = (n, m)
        }
      }
      guard !lines0.isEmpty else { return holeDepth(side) }
      // What lies outside each: per line across the side, running counts from the side in.
      let rows = depth + shift + 2
      func running(_ value: (Int, Int) -> Bool) -> [[Int32]] {
        (lo..<hi).map { t in
          var c = [Int32](repeating: 0, count: rows + 1)
          for k in 0..<rows { c[k + 1] = c[k] + (k < deep && value(k, t) ? 1 : 0) }
          return c
        }
      }
      let likeEdge = running { k, t in edge[at(k, t)] }
      let bareRun = running { k, t in bare[at(k, t)] }
      let clearEdge = baseLevel.map { level in running { k, t in edge[at(k, t)] && !bare[at(k, t)] && g[at(k, t)] >= level } }
      let edgeFilm = running { k, t in edge[at(k, t)] && !bare[at(k, t)] }
      // Pairs two apart along the side, both film: all of them, and those stepping over 0.012.
      let pairs = running { k, t in t + 2 < hi && !bare[at(k, t)] && !bare[at(k, t + 2)] }
      let busy = running { k, t in t + 2 < hi && !bare[at(k, t)] && !bare[at(k, t + 2)] && abs(g[at(k, t + 2)] - g[at(k, t)]) > 0.012 }
      var found = [(votes: Int, depth: Double)]()
      for (k0, line) in lines0 {
        // Rows outside the line, at each place along the side.
        var n = [Int](repeating: 0, count: lines)
        for t in lo..<hi {
          let e = Double(k0) + line.m * (Double(t) - Double(along) / 2)
          n[t - lo] = min(rows, max(0, Int(ceil(e - 1))))
        }
        var all = 0, like = 0, bareN = 0, pairN = 0, busyN = 0, edgeN = 0, clearN = 0
        for j in 0..<lines {
          all += n[j]
          like += Int(likeEdge[j][n[j]])
          bareN += Int(bareRun[j][n[j]])
          edgeN += Int(edgeFilm[j][n[j]])
          clearN += Int(clearEdge?[j][n[j]] ?? 0)
          let both = j + 2 < lines ? min(n[j], n[j + 2]) : 0
          pairN += Int(pairs[j][both])
          busyN += Int(busy[j][both])
        }
        // A slide's Dmax reads noisier in log than a negative's base.
        guard all > 0, Double(like) >= 0.85 * Double(all), 2 * bareN < all, slide ? 2 * busyN <= pairN : 10 * busyN <= 3 * pairN else { continue }
        if clearEdge != nil, 10 * clearN < 6 * edgeN { continue }
        found.append((line.votes, (Double(k0) + abs(line.m) * Double(along) / 2) / Double(deep)))
      }
      guard let top = found.map(\.votes).max() else { return holeDepth(side) }
      let picture = found.filter { 10 * $0.votes >= 7 * top }.map(\.depth).max()
      return holeDepth(side, picture: picture)
    }
  }

  /// The part of `image` (a frame's picture as cropped, unturned) the de-masking statistics read
  /// while its region follows the picture, where the film's edge lies inside the crop: on each
  /// side 1.5% inside the edge, and no nearer the side than 5%. Nil where no edge reaches that far
  /// in, or the picture is a positive's: the crop is then read less its outer 5% (`analysisPart`).
  func followedRegion(_ image: CGImage, settings: Adjustments) -> NormalRect? {
    guard settings.inputIsNegative || settings.isSlide else { return nil }
    let s = samples(image, maxDimension: 480)
    let depths = filmEdgeDepths(
      s, slide: settings.isSlide, gamma: settings.inputGamma,
      base: settings.inputIsNegative ? settings.base ?? settings.rollBase : nil)
    let inset = depths.map { d in max(0.05, (d ?? 0) + 0.015) }
    guard inset.contains(where: { $0 > 0.05 + 1e-9 }) else { return nil }
    // Rounded to a thousandth, so that a picture read at another size lands on the same part.
    let r = inset.map { ($0 * 1000).rounded() / 1000 }
    let region = NormalRect(x: r[2], y: r[0], width: 1 - r[2] - r[3], height: 1 - r[0] - r[1])
    guard region.width >= 0.3, region.height >= 0.3 else { return nil }
    return region
  }
}
