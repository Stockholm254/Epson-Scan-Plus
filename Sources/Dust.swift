import Accelerate
import CoreGraphics
import Foundation

// MARK: The spots

/// A speck of dust, a hair or a fibre on the film: found on the negative or marked by hand, and filled
/// from the film around it as the frame is converted, before anything else reads the frame.
struct DustSpot: Codable, Equatable, Identifiable {
  var id = UUID()
  /// Its box, in the coordinates the frame's rect is in (the preview's, or its own file's, 0–1), so a
  /// new crop leaves it where it is on the film.
  var box: NormalRect
  /// Which cells of the box are dust: `columns` × `rows` of them, a bit each, row by row from the
  /// top, base64.
  var columns: Int
  var rows: Int
  var bits: String
  /// Left in the picture: the user said it is part of it, or not worth filling.
  var kept: Bool? = nil
  /// Marked by hand rather than found; a new search keeps it.
  var marked: Bool? = nil

  var filled: Bool { kept != true }

  init(box: NormalRect, columns: Int, rows: Int, mask: [Bool], marked: Bool = false) {
    self.box = box
    self.columns = columns
    self.rows = rows
    var bytes = [UInt8](repeating: 0, count: (mask.count + 7) / 8)
    for (i, on) in mask.enumerated() where on { bytes[i >> 3] |= 0x80 >> UInt8(i & 7) }
    bits = Data(bytes).base64EncodedString()
    self.marked = marked ? true : nil
  }
  /// The cells, a flag each.
  var mask: [Bool] {
    let bytes = [UInt8](Data(base64Encoded: bits) ?? Data())
    return (0..<(columns * rows)).map { i in i >> 3 < bytes.count && bytes[i >> 3] & (0x80 >> UInt8(i & 7)) != 0 }
  }
  /// Where it lies in a picture `width` × `height` pixels covering `rect`: its pixel box, and which of
  /// those pixels it takes. Each cell takes the pixel its middle falls in and each pixel the cell its
  /// middle falls in, so a spot neither vanishes in a small picture nor turns blocky in a large one.
  /// Nil when none of it is in the picture.
  func pixels(in rect: NormalRect, width: Int, height: Int) -> DustMask? {
    guard rect.width > 0, rect.height > 0, columns > 0, rows > 0 else { return nil }
    let fx0 = (box.x - rect.x) / rect.width * Double(width), fx1 = (box.x + box.width - rect.x) / rect.width * Double(width)
    let fy0 = (box.y - rect.y) / rect.height * Double(height), fy1 = (box.y + box.height - rect.y) / rect.height * Double(height)
    let x0 = max(0, Int(fx0.rounded(.down))), x1 = min(width, Int(fx1.rounded(.up)))
    let y0 = max(0, Int(fy0.rounded(.down))), y1 = min(height, Int(fy1.rounded(.up)))
    guard x1 > x0, y1 > y0, fx1 > fx0, fy1 > fy0 else { return nil }
    let w = x1 - x0, h = y1 - y0
    let cells = mask
    var out = [Bool](repeating: false, count: w * h)
    for ty in 0..<h {
      let gy = Int(((Double(y0 + ty) + 0.5 - fy0) / (fy1 - fy0) * Double(rows)).rounded(.down))
      guard gy >= 0, gy < rows else { continue }
      for tx in 0..<w {
        let gx = Int(((Double(x0 + tx) + 0.5 - fx0) / (fx1 - fx0) * Double(columns)).rounded(.down))
        if gx >= 0, gx < columns, cells[gy * columns + gx] { out[ty * w + tx] = true }
      }
    }
    for gy in 0..<rows {
      for gx in 0..<columns where cells[gy * columns + gx] {
        let tx = Int((fx0 + (Double(gx) + 0.5) / Double(columns) * (fx1 - fx0)).rounded(.down)) - x0
        let ty = Int((fy0 + (Double(gy) + 0.5) / Double(rows) * (fy1 - fy0)).rounded(.down)) - y0
        if tx >= 0, tx < w, ty >= 0, ty < h { out[ty * w + tx] = true }
      }
    }
    guard out.contains(true) else { return nil }
    return DustMask(x: x0, y: y0, width: w, height: h, cells: out)
  }
}

/// A spot in a picture's pixels: its box and which of the box's pixels it takes.
struct DustMask: Equatable {
  var x: Int, y: Int, width: Int, height: Int
  var cells: [Bool]
  var area: Int { cells.reduce(0) { $0 + ($1 ? 1 : 0) } }
  /// The spot in a frame's coordinates, from a picture `size` of it covering `rect`.
  func spot(in rect: NormalRect, width W: Int, height H: Int, marked: Bool = false) -> DustSpot {
    let box = NormalRect(
      x: rect.x + Double(x) / Double(W) * rect.width, y: rect.y + Double(y) / Double(H) * rect.height,
      width: Double(width) / Double(W) * rect.width, height: Double(height) / Double(H) * rect.height)
    return DustSpot(box: box, columns: width, rows: height, mask: cells, marked: marked)
  }
}

/// A frame's dust: the spots, and whether they are filled.
struct DustState: Codable, Equatable {
  var on = true
  var spots = [DustSpot]()
  /// How hard the last search looked.
  var sensitivity: DustSensitivity? = nil
  var filledCount: Int { spots.filter(\.filled).count }
  /// Changes whenever what is filled does.
  var signature: String {
    guard on else { return "off" }
    return spots.filter(\.filled).map { "\($0.id.uuidString.prefix(8))\($0.box.x)\($0.box.y)\($0.bits.count)" }.joined(separator: ",")
  }
}

/// How far past the film's own grain a spot must stand out to be taken for dust.
enum DustSensitivity: String, Codable, CaseIterable {
  case low = "低", medium = "中", high = "高"
  /// Times the local grain's tail (about its 99.5th percentile), in every channel.
  var factor: Double {
    switch self {
    case .low: return 2.6
    case .medium: return 2.0
    case .high: return 1.6
    }
  }
}

// MARK: Reading pixels

enum DustPixels {
  /// `region` of `image` as 16-bit RGBA, linear as it is, rows from the top.
  static func rgba16(_ image: CGImage, x: Int, y: Int, width w: Int, height h: Int) -> [UInt16]? {
    guard w > 0, h > 0, let part = image.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { return nil }
    var buffer = [UInt16](repeating: 0, count: w * h * 4)
    let drawn = buffer.withUnsafeMutableBytes { p -> Bool in
      guard let ctx = CGContext(
        data: p.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
        space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.linearSRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
      else { return false }
      ctx.interpolationQuality = .none
      ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    return drawn ? buffer : nil
  }
  /// The density of a 16-bit reading: how much of the light the film keeps out, log10.
  @inline(__always) static func density(_ v: UInt16) -> Float { -log10f(max(Float(v), 16) / 65535) }
  /// Each channel's density less its grey opening (a minimum then a maximum over `k` × `k`): what is
  /// denser than everything around it within the kernel, small specks; and the density itself.
  static func excess(_ px: [UInt16], width w: Int, height h: Int, kernel k: Int) -> (excess: [[Float]], density: [[Float]]) {
    let n = w * h
    var excess = [[Float]](), densities = [[Float]]()
    var d = [Float](repeating: 0, count: n), mid = [Float](repeating: 0, count: n), open = [Float](repeating: 0, count: n)
    for c in 0..<3 {
      px.withUnsafeBufferPointer { p in
        for i in 0..<n { d[i] = density(p[i * 4 + c]) }
      }
      d.withUnsafeMutableBufferPointer { dp in
        mid.withUnsafeMutableBufferPointer { mp in
          open.withUnsafeMutableBufferPointer { op in
            var src = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var tmp = vImage_Buffer(data: mp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var dst = vImage_Buffer(data: op.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            _ = vImageMin_PlanarF(&src, &tmp, nil, 0, 0, vImagePixelCount(k), vImagePixelCount(k), vImage_Flags(kvImageNoFlags))
            _ = vImageMax_PlanarF(&tmp, &dst, nil, 0, 0, vImagePixelCount(k), vImagePixelCount(k), vImage_Flags(kvImageNoFlags))
          }
        }
      }
      var t = [Float](repeating: 0, count: n)
      for i in 0..<n { t[i] = max(0, d[i] - open[i]) }
      excess.append(t)
      densities.append(d)
    }
    return (excess, densities)
  }
}

// MARK: Finding

/// Dust on a negative, found from the picture alone.
///
/// - Dust keeps light out, so on the negative a speck is denser than the film around it. Each
///   channel's density less its grey opening is what stands above its surroundings; a speck stands
///   far above the film's own grain, which is measured block by block, so busy parts of the
///   picture need more: each channel's 99.5th percentile over the block and two blocks round it
///   each way. The window's top half percent is as big as the biggest spot taken, so a speck is
///   not its own grain (over nine blocks, one of 40 pixels in a small picture was), while a busy
///   pocket of grass or leaves still raises it (a median of blocks passed over those).
/// - A speck keeps out every colour, so it stands out in all three channels; a single channel with
///   hardly any light in it (a saturated colour) does not count.
/// - Dust takes the same share of each colour, so its green and red excesses are about equal; the
///   picture's own small bright things follow the film's layers, green above red (about 1.28 on
///   Portra). This is asked only where the film around is busy (its grain's tail well above the
///   frame's usual): green is read sharper than red, so a small speck's green stands higher at its
///   peak, and in a smooth sky a real speck would be turned away. Glints on water and the like sit
///   at the top of the film's curve and look neutral too: those are left for the user to keep.
/// - Small only: big bright things are the picture. Spots at the edge of the picture (its border) are
///   left out, and so are spots on a hard edge, where the film around them is two films.
enum DustFinder {
  struct Options {
    /// Past the grain's tail by this many times, in every channel, to start a spot.
    var factor = DustSensitivity.medium.factor
    /// And this much denser than its opening, on average over the channels (D).
    var least = 0.2
    /// The most green over red a spot's excess may have; nil takes any.
    var greenOverRed: Double? = 1.08
    /// Pixels of the picture for one of a 61-megapixel copy frame (9600 pixels across); nil reads
    /// it from the picture's size.
    var scale: Double? = nil
    /// Leave out spots that touch the picture's edge.
    var edges = true
    /// The file's encoding: its densities are the film's over this (a file in gamma 2.2 holds a
    /// speck of 1 D as 0.45), so the densities asked for are over it too.
    var gamma = 1.0
  }

  static func find(_ image: CGImage, options o: Options = Options(), progress: ((Double) -> Void)? = nil) -> [DustMask] {
    let W = image.width, H = image.height
    guard W >= 16, H >= 16 else { return [] }
    let s = o.scale ?? Double(max(W, H)) / 9600
    let g = Float(max(0.5, o.gamma))
    let k = max(5, Int((17 * s).rounded()) | 1)
    let block = max(24, Int((128 * s).rounded()))
    let core = block * max(1, 768 / block)
    let margin = 2 * block + k
    let tilesX = (W + core - 1) / core, tilesY = (H + core - 1) / core
    let blocksX = (W + block - 1) / block, blocksY = (H + block - 1) / block
    let bins = 512, binWidth: Float = 0.004
    var marks = [UInt8](repeating: 0, count: W * H)  // 1: grows a spot, 2: starts one
    // Each block's grain tail, for how busy the film is around a spot.
    var blockTails = [Float](repeating: 0, count: blocksX * blocksY * 3)
    let lock = NSLock()
    var done = 0
    marks.withUnsafeMutableBufferPointer { mp in
      let marked = mp.baseAddress!
      let tailsOut = blockTails.withUnsafeMutableBufferPointer { $0.baseAddress! }
      DispatchQueue.concurrentPerform(iterations: tilesX * tilesY) { t in
        let cx0 = (t % tilesX) * core, cy0 = (t / tilesX) * core
        let cx1 = min(W, cx0 + core), cy1 = min(H, cy0 + core)
        let bx0 = max(0, cx0 - margin), by0 = max(0, cy0 - margin)
        let bx1 = min(W, cx1 + margin), by1 = min(H, cy1 + margin)
        let bw = bx1 - bx0, bh = by1 - by0
        defer {
          lock.lock()
          done += 1
          let f = Double(done) / Double(tilesX * tilesY)
          lock.unlock()
          progress?(f)
        }
        guard let px = DustPixels.rgba16(image, x: bx0, y: by0, width: bw, height: bh) else { return }
        let (T, _) = DustPixels.excess(px, width: bw, height: bh, kernel: k)
        // The grain's tail, block by block: histograms of each block near the core, then each core
        // block's over it and its neighbours.
        let gx0 = max(0, cx0 / block - 2), gx1 = min(blocksX - 1, (cx1 - 1) / block + 2)
        let gy0 = max(0, cy0 / block - 2), gy1 = min(blocksY - 1, (cy1 - 1) / block + 2)
        let nbx = gx1 - gx0 + 1, nby = gy1 - gy0 + 1
        var counts = [Int32](repeating: 0, count: nbx * nby * 3 * bins)
        for y in max(by0, gy0 * block)..<min(by1, (gy1 + 1) * block) {
          let gy = y / block - gy0
          for x in max(bx0, gx0 * block)..<min(bx1, (gx1 + 1) * block) {
            let gx = x / block - gx0, i = (y - by0) * bw + (x - bx0)
            let base = (gy * nbx + gx) * 3 * bins
            for c in 0..<3 { counts[base + c * bins + min(bins - 1, Int(T[c][i] / binWidth))] += 1 }
          }
        }
        // Each block's tail: the 99.5th percentile over it and two blocks round it each way (25
        // blocks, 410 000 pixels at full size), whose top half percent is as big as the biggest
        // spot taken, so a speck is not its own grain, and a busy pocket still counts.
        var tails = [Float](repeating: 0.02 / g, count: nbx * nby * 3)
        var sum = [Int32](repeating: 0, count: bins)
        for gy in 0..<nby {
          for gx in 0..<nbx {
            for c in 0..<3 {
              for b in 0..<bins { sum[b] = 0 }
              var total: Int32 = 0
              for ny in max(0, gy - 2)...min(nby - 1, gy + 2) {
                for nx in max(0, gx - 2)...min(nbx - 1, gx + 2) {
                  let base = (ny * nbx + nx) * 3 * bins + c * bins
                  for b in 0..<bins { sum[b] += counts[base + b] }
                }
              }
              for b in 0..<bins { total += sum[b] }
              guard total > 0 else { continue }
              let want = Int32((Double(total) * 0.995).rounded(.up))
              var run: Int32 = 0, at = bins - 1
              for b in 0..<bins {
                run += sum[b]
                if run >= want { at = b; break }
              }
              tails[(gy * nbx + gx) * 3 + c] = max(0.02 / g, (Float(at) + 0.5) * binWidth)
            }
          }
        }
        for gy in (cy0 / block)...((cy1 - 1) / block) {
          for gx in (cx0 / block)...((cx1 - 1) / block) {
            for c in 0..<3 { tailsOut[(gy * blocksX + gx) * 3 + c] = tails[((gy - gy0) * nbx + gx - gx0) * 3 + c] }
          }
        }
        let factor = Float(o.factor), least = Float(o.least) / g, grows = 0.05 / g
        for y in cy0..<cy1 {
          let gy = y / block - gy0
          for x in cx0..<cx1 {
            let i = (y - by0) * bw + (x - bx0)
            let tail = (gy * nbx + (x / block - gx0)) * 3
            let rr = T[0][i] / tails[tail], gg = T[1][i] / tails[tail + 1], bb = T[2][i] / tails[tail + 2]
            let ratio = min(rr, min(gg, bb)), mean = (T[0][i] + T[1][i] + T[2][i]) / 3
            var m: UInt8 = 0
            if ratio > 0.7, mean > grows { m = 1 }
            if ratio > factor, mean > least { m = 3 }
            marked[y * W + x] = m
          }
        }
      }
    }
    // The frame's plain grain, each channel's tail where the film is smoothest: the lowest quarter
    // of the blocks (a frame mostly of trees would make its median busy).
    let usual: [Float] = (0..<3).map { c in
      let all = stride(from: c, to: blockTails.count, by: 3).map { blockTails[$0] }.filter { $0 > 0 }.sorted()
      return all.isEmpty ? 0.02 : all[all.count / 4]
    }
    // Spots: the pixels that grow, joined where they touch, that a starting pixel is in.
    let minArea = max(2, Int((3 * s * s).rounded())), maxArea = max(60, Int(2500 * s * s))
    let edge = o.edges ? max(4, Int((24 * s).rounded())) : 0
    let grow = max(1, Int((2 * s + 1).rounded()))
    var found = [DustMask]()
    var stack = [Int](), pixels = [Int]()
    for start in 0..<(W * H) where marks[start] & 1 != 0 && marks[start] & 4 == 0 {
      stack.removeAll(keepingCapacity: true)
      pixels.removeAll(keepingCapacity: true)
      stack.append(start)
      marks[start] |= 4
      var seeded = false, big = false, atEdge = false
      var minX = W, minY = H, maxX = 0, maxY = 0
      while let i = stack.popLast() {
        let x = i % W, y = i / W
        if marks[i] & 2 != 0 { seeded = true }
        if pixels.count <= maxArea { pixels.append(i) } else { big = true }
        if x < edge || y < edge || x >= W - edge || y >= H - edge { atEdge = true }
        (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
        for dy in -1...1 {
          let ny = y + dy
          guard ny >= 0, ny < H else { continue }
          for dx in -1...1 {
            let nx = x + dx
            guard nx >= 0, nx < W else { continue }
            let j = ny * W + nx
            if marks[j] & 1 != 0 && marks[j] & 4 == 0 {
              marks[j] |= 4
              stack.append(j)
            }
          }
        }
      }
      guard seeded, !big, !atEdge, pixels.count >= minArea else { continue }
      // How it stands out, channel by channel, at its core: dust takes as much green as red.
      let rx0 = max(0, minX - k - 1), ry0 = max(0, minY - k - 1)
      let rx1 = min(W, maxX + k + 2), ry1 = min(H, maxY + k + 2)
      let rw = rx1 - rx0, rh = ry1 - ry0
      guard let px = DustPixels.rgba16(image, x: rx0, y: ry0, width: rw, height: rh) else { continue }
      let local = pixels.map { ($0 / W - ry0) * rw + ($0 % W - rx0) }
      var inSpot = [Bool](repeating: false, count: rw * rh)
      for i in local { inSpot[i] = true }
      if twoFilms(px, width: rw, height: rh, spot: inSpot, depth: max(3, Int((6 * s).rounded())), gamma: g) { continue }
      let middle = ((minY + maxY) / 2 / block * blocksX + (minX + maxX) / 2 / block) * 3
      let busy = (0..<3).map { blockTails[middle + $0] / max(0.005, usual[$0]) }.reduce(0, +) / 3 > 1.5
      if busy, let ratio = o.greenOverRed {
        let (T, _) = DustPixels.excess(px, width: rw, height: rh, kernel: k)
        let peak = local.map { (T[0][$0] + T[1][$0] + T[2][$0]) / 3 }.max() ?? 0
        var e = [Float](repeating: 0, count: 3), n: Float = 0
        for i in local where (T[0][i] + T[1][i] + T[2][i]) / 3 >= 0.6 * peak {
          for c in 0..<3 { e[c] += T[c][i] }
          n += 1
        }
        if n > 0, e[0] / n > 0.08 / g, Double(e[1] / e[0]) > ratio { continue }
      }
      // The spot and a rim around it, where it fades into the film.
      let x0 = max(0, minX - grow), y0 = max(0, minY - grow)
      let x1 = min(W, maxX + grow + 1), y1 = min(H, maxY + grow + 1)
      let w = x1 - x0, h = y1 - y0
      var cells = [Bool](repeating: false, count: w * h)
      for i in pixels {
        let x = i % W - x0, y = i / W - y0
        for dy in -grow...grow {
          let yy = y + dy
          guard yy >= 0, yy < h else { continue }
          for dx in -grow...grow {
            let xx = x + dx
            if xx >= 0, xx < w { cells[yy * w + xx] = true }
          }
        }
      }
      found.append(DustMask(x: x0, y: y0, width: w, height: h, cells: cells))
    }
    return found.sorted { $0.area > $1.area }
  }

  /// Whether the film around a spot is two films (the film's border, a dark post against a pale
  /// wall, the sky against a yellow sculpture): filling from it would carry one into the other. Its
  /// ring, `depth` pixels deep around the spot's cells, spreads more than 0.4 D in a channel (dust
  /// in grain or leaves, under 0.3). `px` is RGBA, `spot` its cells.
  static func twoFilms(_ px: [UInt16], width rw: Int, height rh: Int, spot inSpot: [Bool], depth: Int, gamma g: Float) -> Bool {
    var ring = [Int]()
    for i in 0..<(rw * rh) where !inSpot[i] {
      let x = i % rw, y = i / rw
      var near = false
      for dy in -depth...depth where !near {
        let yy = y + dy
        guard yy >= 0, yy < rh else { continue }
        for dx in -depth...depth {
          let xx = x + dx
          if xx >= 0, xx < rw, inSpot[yy * rw + xx] { near = true; break }
        }
      }
      if near { ring.append(i) }
    }
    return (0..<3).contains { c in
      let v = ring.map { DustPixels.density(px[$0 * 4 + c]) }.sorted()
      guard v.count >= 10 else { return false }
      return v[v.count * 9 / 10] - v[v.count / 10] > 0.4 / g
    }
  }

  /// `twoFilms` for a spot marked on `image` (a click's round spot), read from the picture around it.
  static func twoFilms(_ mask: DustMask, in image: CGImage, scale s: Double, gamma: Double) -> Bool {
    let depth = max(3, Int((6 * s).rounded()))
    let x0 = max(0, mask.x - depth), y0 = max(0, mask.y - depth)
    let x1 = min(image.width, mask.x + mask.width + depth), y1 = min(image.height, mask.y + mask.height + depth)
    let w = x1 - x0, h = y1 - y0
    guard w > 0, h > 0, let px = DustPixels.rgba16(image, x: x0, y: y0, width: w, height: h) else { return false }
    var inSpot = [Bool](repeating: false, count: w * h)
    for y in 0..<mask.height {
      for x in 0..<mask.width where mask.cells[y * mask.width + x] {
        let xx = mask.x + x - x0, yy = mask.y + y - y0
        if xx >= 0, xx < w, yy >= 0, yy < h { inSpot[yy * w + xx] = true }
      }
    }
    return twoFilms(px, width: w, height: h, spot: inSpot, depth: depth, gamma: Float(max(0.5, gamma)))
  }

  /// All of a speck clicked on: in `window` (a small part of the picture around the click, at
  /// `click`), the pixels joined to `core` or to the click that are denser than the window's film in
  /// all three channels, by three of the grain's spreads, smoothed over 3 × 3. A wide soft speck
  /// (dust on the base side, out of focus) stands out of the opening only at its thin parts; this
  /// takes the rest. nil where nothing near the click is denser, or what is takes more than a fifth
  /// of the window: a pale thing of the picture, not a speck.
  static func wholeSpeck(at click: (x: Int, y: Int), in window: CGImage, core: DustMask?, near: Int, gamma: Double) -> DustMask? {
    let w = window.width, h = window.height
    guard w > 2, h > 2, let px = DustPixels.rgba16(window, x: 0, y: 0, width: w, height: h) else { return nil }
    let g = Float(max(0.5, gamma))
    var dense = [Bool](repeating: true, count: w * h)
    var d = [Float](repeating: 0, count: w * h), smooth = [Float](repeating: 0, count: w * h)
    for c in 0..<3 {
      for i in 0..<(w * h) { d[i] = DustPixels.density(px[i * 4 + c]) }
      for y in 0..<h {
        for x in 0..<w {
          var sum: Float = 0, n: Float = 0
          for yy in max(0, y - 1)...min(h - 1, y + 1) {
            for xx in max(0, x - 1)...min(w - 1, x + 1) { sum += d[yy * w + xx]; n += 1 }
          }
          smooth[y * w + x] = sum / n
        }
      }
      let median = smooth.sorted()[w * h / 2]
      let spread = smooth.map { abs($0 - median) }.sorted()[w * h / 2]
      let least = max(0.03 / g, 3 * 1.48 * spread)
      for i in 0..<(w * h) where smooth[i] - median <= least { dense[i] = false }
    }
    var inSpeck = [Bool](repeating: false, count: w * h), stack = [Int]()
    func take(_ x: Int, _ y: Int) {
      guard x >= 0, x < w, y >= 0, y < h else { return }
      let i = y * w + x
      if dense[i], !inSpeck[i] { inSpeck[i] = true; stack.append(i) }
    }
    for y in (click.y - near)...(click.y + near) { for x in (click.x - near)...(click.x + near) { take(x, y) } }
    if let core {
      for y in 0..<core.height { for x in 0..<core.width where core.cells[y * core.width + x] { take(core.x + x, core.y + y) } }
    }
    var count = 0, minX = w, minY = h, maxX = -1, maxY = -1
    while let i = stack.popLast() {
      count += 1
      if count > w * h / 5 { return nil }
      let x = i % w, y = i / w
      (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
      for dy in -1...1 { for dx in -1...1 { take(x + dx, y + dy) } }
    }
    guard count > 0 else { return nil }
    // Two pixels more all round, where it fades into the film, and the core's cells.
    let x0 = max(0, minX - 2), y0 = max(0, minY - 2), x1 = min(w, maxX + 3), y1 = min(h, maxY + 3)
    let mw = x1 - x0, mh = y1 - y0
    var cells = [Bool](repeating: false, count: mw * mh)
    for y in y0..<y1 {
      for x in x0..<x1 {
        var hit = false
        for yy in max(0, y - 2)...min(h - 1, y + 2) where !hit {
          for xx in max(0, x - 2)...min(w - 1, x + 2) where inSpeck[yy * w + xx] { hit = true; break }
        }
        cells[(y - y0) * mw + (x - x0)] = hit
      }
    }
    var whole = DustMask(x: x0, y: y0, width: mw, height: mh, cells: cells)
    if let core {
      // The core within the same box, or the box widened to hold it.
      let ux0 = min(whole.x, core.x), uy0 = min(whole.y, core.y)
      let ux1 = max(whole.x + whole.width, core.x + core.width), uy1 = max(whole.y + whole.height, core.y + core.height)
      var union = [Bool](repeating: false, count: (ux1 - ux0) * (uy1 - uy0))
      for m in [whole, core] {
        for y in 0..<m.height { for x in 0..<m.width where m.cells[y * m.width + x] { union[(m.y + y - uy0) * (ux1 - ux0) + (m.x + x - ux0)] = true } }
      }
      whole = DustMask(x: ux0, y: uy0, width: ux1 - ux0, height: uy1 - uy0, cells: union)
    }
    return whole
  }
}

// MARK: Filling

/// The spots filled from the film around them, on the negative as read (linear, before its mask is
/// taken off), so whatever converts it later converts the filled film as the rest.
///
/// - Each spot takes the smooth surface the film around it spans (a membrane through its rim, in
///   log), plus the grain of a nearby patch of clean film: that patch less its own membrane, so it
///   adds texture but no step at the rim.
/// - Repairs only take density away: no pixel comes out denser than it was, so a fill can never
///   leave a dark mark where there was none. Nor thinner than the thinnest film around it, so a
///   patch that reaches the clear film past the frame's edge cannot bring it in.
enum DustFill {
  static func apply(_ spots: [DustSpot], to image: CGImage, rect: NormalRect) -> CGImage {
    let W = image.width, H = image.height
    let all = spots.compactMap { s in s.pixels(in: rect, width: W, height: H).map { (s, $0) } }
    let filled = all.filter { $0.0.filled }.map(\.1)
    guard !filled.isEmpty, image.bitsPerComponent == 16 else { return image }
    let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.linearSRGB)!
    guard let ctx = CGContext(
      data: nil, width: W, height: H, bitsPerComponent: 16, bytesPerRow: W * 8, space: space,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
      let data = ctx.data
    else { return image }
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
    let p = data.bindMemory(to: UInt16.self, capacity: W * H * 4)
    let avoid = all.map { CGRect(x: $0.1.x - 2, y: $0.1.y - 2, width: $0.1.width + 4, height: $0.1.height + 4) }
    for mask in filled { fill(mask, in: p, width: W, height: H, avoiding: avoid) }
    return ctx.makeImage() ?? image
  }

  /// One spot filled in place.
  static func fill(_ m: DustMask, in p: UnsafeMutablePointer<UInt16>, width W: Int, height H: Int, avoiding: [CGRect]) {
    let pad = max(2, min(12, max(m.width, m.height) / 3))
    let rx0 = max(0, m.x - pad), ry0 = max(0, m.y - pad)
    let rx1 = min(W, m.x + m.width + pad), ry1 = min(H, m.y + m.height + pad)
    let rw = rx1 - rx0, rh = ry1 - ry0, n = rw * rh
    guard rw > 2, rh > 2 else { return }
    var inside = [Bool](repeating: false, count: n)
    for y in 0..<m.height {
      for x in 0..<m.width where m.cells[y * m.width + x] {
        let gx = m.x + x - rx0, gy = m.y + y - ry0
        if gx >= 0, gx < rw, gy >= 0, gy < rh { inside[gy * rw + gx] = true }
      }
    }
    let holes = (0..<n).filter { inside[$0] }
    guard !holes.isEmpty, holes.count < n else { return }
    // The film around it, two pixels deep: what the patch is matched by.
    var rim = [Int]()
    for i in 0..<n where !inside[i] {
      let x = i % rw, y = i / rw
      var near = false
      for dy in -2...2 where !near {
        for dx in -2...2 {
          let xx = x + dx, yy = y + dy
          if xx >= 0, xx < rw, yy >= 0, yy < rh, inside[yy * rw + xx] { near = true; break }
        }
      }
      if near { rim.append(i) }
    }
    func read(_ ox: Int, _ oy: Int) -> [[Double]] {
      (0..<3).map { c in
        (0..<n).map { i in log(Double(p[((oy + i / rw) * W + ox + i % rw) * 4 + c]) + 64) }
      }
    }
    let here = read(rx0, ry0)
    var smooth = here
    for c in 0..<3 { membrane(&smooth[c], inside: inside, holes: holes, width: rw, height: rh) }
    // The patch whose rim matches best, from rings around the spot, clear of every spot.
    var best: (score: Double, x: Int, y: Int)?
    let size = Double(max(rw, rh))
    for d in [1.3, 2.2, 3.5] {
      for step in 0..<12 {
        let angle = Double(step) / 12 * 2 * .pi + d
        let ox = rx0 + Int((cos(angle) * d * size).rounded()), oy = ry0 + Int((sin(angle) * d * size).rounded())
        guard ox >= 0, oy >= 0, ox + rw <= W, oy + rh <= H else { continue }
        let r = CGRect(x: ox, y: oy, width: rw, height: rh)
        guard !avoiding.contains(where: { $0.intersects(r) }) else { continue }
        var score = 0.0
        for c in 0..<3 {
          var a = 0.0, b = 0.0
          var them = [Double](), mine = [Double]()
          for i in rim {
            let v = log(Double(p[((oy + i / rw) * W + ox + i % rw) * 4 + c]) + 64)
            them.append(v)
            mine.append(here[c][i])
            a += v
            b += here[c][i]
          }
          a /= Double(rim.count)
          b /= Double(rim.count)
          for j in 0..<rim.count { score += pow((them[j] - a) - (mine[j] - b), 2) }
        }
        if best == nil || score < best!.score { best = (score, ox, oy) }
      }
    }
    var result = smooth
    // The film around it, each channel's thinnest and densest, that the fill stays between.
    let bounds: [(Double, Double)] = (0..<3).map { c in
      let v = rim.map { here[c][$0] }
      return (v.min() ?? 0, v.max() ?? 20)
    }
    if let best {
      let patch = read(best.x, best.y)
      for c in 0..<3 {
        var its = patch[c]
        membrane(&its, inside: inside, holes: holes, width: rw, height: rh)
        // Only the patch's grain: its detail held within three of its own spreads (by the median
        // of its deviations), so a patch that catches an edge or a leaf brings its grain, not those.
        let detail = holes.map { patch[c][$0] - its[$0] }
        let middle = detail.sorted()[detail.count / 2]
        let deviations = detail.map { abs($0 - middle) }.sorted()
        let limit = max(0.004, 3 * 1.48 * deviations[deviations.count / 2])
        for (j, i) in holes.enumerated() { result[c][i] = smooth[c][i] + max(-limit, min(limit, detail[j] - middle)) }
      }
    }
    for i in holes {
      let at = ((ry0 + i / rw) * W + rx0 + i % rw) * 4
      for c in 0..<3 {
        let log = min(bounds[c].1, max(bounds[c].0, result[c][i]))
        let v = UInt16(max(0, min(65535, (exp(log) - 64).rounded())))
        p[at + c] = max(p[at + c], v)
      }
    }
  }

  /// The holes in `values` filled with the smoothest surface through what is around them: each the
  /// mean of its neighbours (a membrane), by over-relaxed sweeps.
  static func membrane(_ values: inout [Double], inside: [Bool], holes: [Int], width w: Int, height h: Int) {
    var sum = 0.0, count = 0.0
    for i in holes {
      let x = i % w, y = i / w
      for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
        let xx = x + dx, yy = y + dy
        if xx >= 0, xx < w, yy >= 0, yy < h, !inside[yy * w + xx] {
          sum += values[yy * w + xx]
          count += 1
        }
      }
    }
    let start = count > 0 ? sum / count : 0
    for i in holes { values[i] = start }
    let sweeps = min(4000, 60 + 4 * max(w, h))
    for _ in 0..<sweeps {
      var change = 0.0
      for i in holes {
        let x = i % w, y = i / w
        var s = 0.0, k = 0.0
        if x > 0 { s += values[i - 1]; k += 1 }
        if x < w - 1 { s += values[i + 1]; k += 1 }
        if y > 0 { s += values[i - w]; k += 1 }
        if y < h - 1 { s += values[i + w]; k += 1 }
        guard k > 0 else { continue }
        let next = values[i] + 1.85 * (s / k - values[i])
        change = max(change, abs(next - values[i]))
        values[i] = next
      }
      if change < 1e-5 { break }
    }
  }
}
