import CoreGraphics
import Foundation

enum FrameDetector {
  // Detect illuminated apertures, then split strips using physical film dimensions
  // and low-texture inter-frame gaps. Manual rectangles always remain editable.
  static func detect(_ image: CGImage, physicalMM: CGSize, format: FilmFormat) -> [FilmFrame] {
    // Tuned on 150 dpi previews. Finer ones are averaged down to that first: at 600 dpi, grain
    // in the narrow gaps between frames moved frame edges by up to 9 mm from one scan to the next.
    let longest = Double(max(physicalMM.width, physicalMM.height))
    let limit = longest > 0 ? min(1500, Int(longest / 25.4 * 150)) : 1500
    let raster = ImagePipeline.shared.raster(ImagePipeline.shared.scaled(image, maxDimension: limit), maxDimension: 1500)
    let w = raster.width
    let h = raster.height
    var mask = [Bool](repeating: false, count: w * h)
    for y in 0..<h {
      for x in 0..<w {
        let p = raster.pixel(x, y)
        mask[y * w + x] = p.r > 0.07 && p.r > p.b * 1.08 && p.g > 0.018 && p.r < 0.995
      }
    }
    var seen = [Bool](repeating: false, count: w * h)
    var boxes = [CGRect]()
    for start in 0..<mask.count where mask[start] && !seen[start] {
      var queue = [start]
      var head = 0
      var minX = start % w
      var maxX = minX
      var minY = start / w
      var maxY = minY
      seen[start] = true
      while head < queue.count {
        let p = queue[head]
        head += 1
        let x = p % w
        let y = p / w
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
        where nx >= 0 && nx < w && ny >= 0 && ny < h {
          let q = ny * w + nx
          if mask[q] && !seen[q] {
            seen[q] = true
            queue.append(q)
          }
        }
      }
      let bw = maxX - minX + 1
      let bh = maxY - minY + 1
      if bw > 25 && bh > 25 && queue.count > bw * bh / 3 {
        boxes.append(CGRect(x: minX, y: minY, width: bw, height: bh))
      }
    }
    var frames = [FilmFrame]()
    for box in boxes.sorted(by: {
      abs($0.minX - $1.minX) > 20 ? $0.minX < $1.minX : $0.minY < $1.minY
    }) {
      let vertical = box.height >= box.width
      let short = vertical ? box.width : box.height
      let long = vertical ? box.height : box.width
      let pxPerMM = vertical ? CGFloat(w) / physicalMM.width : CGFloat(h) / physicalMM.height
      let shortMM = short / pxPerMM
      let longMM = long / pxPerMM
      guard shortMM > 14, shortMM < 80 else { continue }
      let is135 = format == .mm135 || (format == .auto && shortMM < 40)
      if format == .mm135 && shortMM > 40 { continue }
      if format != .auto && format != .mm135 && shortMM < 40 { continue }
      let target: CGFloat
      if is135 {
        target = 36
      } else {
        switch format {
        case .six45: target = 42
        case .six6: target = 56
        case .six9: target = 84
        default: target = 69
        }
      }
      var count = max(1, Int((longMM / (target + 2)).rounded()))
      if longMM < target * 1.5 { count = 1 }
      count = min(12, count)
      let length = Int(long)
      let cross = Int(short)
      var texture = [Double](repeating: 0, count: length)
      var brightness = [Double](repeating: 0, count: length)
      for t in 0..<length {
        var vals = [Double]()
        for s in max(1, cross / 10)..<max(2, cross - cross / 10) {
          let x = Int(box.minX) + (vertical ? s : t)
          let y = Int(box.minY) + (vertical ? t : s)
          vals.append(raster.pixel(x, y).g)
        }
        let mean = vals.reduce(0, +) / Double(max(1, vals.count))
        brightness[t] = mean
        texture[t] =
          vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, vals.count))
      }
      func findCuts(_ n: Int) -> (cuts: [Int], score: Double) {
        var cuts = [0]
        var total = 0.0
        if n > 1 {
          for i in 1..<n {
            let expected = Double(length) * Double(i) / Double(n)
            let radius = max(3, Int(4 * pxPerMM))
            let a = max(cuts.last! + 10, Int(expected) - radius)
            let b = min(length - 10, Int(expected) + radius)
            var best = Int(expected)
            var score = Double.infinity
            if a < b {
              for t in a...b {
                let local = texture[max(0, t - 1)...min(length - 1, t + 1)].reduce(0, +) / 3
                let s =
                  local * 30 - brightness[t] * 0.04 + pow(
                    (Double(t) - expected) / Double(radius), 2) * 0.006
                if s < score {
                  score = s
                  best = t
                }
              }
            }
            cuts.append(best)
            total += score
          }
        }
        cuts.append(length)
        return (cuts, n > 1 ? total / Double(n - 1) : 0)
      }
      // 120 is not one fixed aspect ratio: choose a physically plausible format
      // using actual inter-frame gaps, instead of assuming every strip is 6×7.
      if !is135 && (format == .auto || format == .medium) {
        var bestScore = Double.infinity
        for n in 1...8 {
          let frameMM = (Double(longMM) - Double(n - 1) * 2) / Double(n)
          let mismatch = [42.0, 56.0, 69.0, 84.0].map { abs(frameMM - $0) / $0 }.min()!
          guard mismatch < 0.22 else { continue }
          let score = findCuts(n).score + mismatch * 0.08
          if score < bestScore {
            bestScore = score
            count = n
          }
        }
      }
      let cuts = findCuts(count).cuts
      // Estimate the holder sides from the entire strip. A dark subject in one
      // frame must not move that frame's lateral aperture edge into the scene.
      let stripInterior = FilmEdges.contentBounds(raster, within: box)
      // Measure a shared film-base color at multiple predicted seams, rather than
      // treating the center of a potentially wide gap as the image boundary.
      var gapSamples = [RGB]()
      for cut in cuts.dropFirst().dropLast() {
        let radius = max(3, Int(pxPerMM * 2))
        var best: FilmEdges.Line?
        for t in max(0, cut - radius)...min(length - 1, cut + radius) {
          let line = FilmEdges.line(
            raster, vertical: !vertical,
            coordinate: Int(vertical ? box.minY : box.minX) + t,
            from: Int(vertical ? box.minX : box.minY) + cross / 8,
            to: Int(vertical ? box.maxX : box.maxY) - cross / 8)
          if line.deviation < 0.025, line.mean.r < 0.94, line.mean.r > line.mean.b * 1.15,
            best == nil || line.mean.g > best!.mean.g
          {
            best = line
          }
        }
        if let best { gapSamples.append(best.mean) }
      }
      let gapBase: RGB? =
        gapSamples.isEmpty
        ? nil
        : RGB(
          (0..<3).map { c in
            let values = gapSamples.map { $0.values[c] }.sorted()
            return values[values.count / 2]
          })
      for i in 0..<count {
        let start = CGFloat(cuts[i])
        let end = CGFloat(cuts[i + 1])
        let candidate: CGRect =
          vertical
          ? CGRect(
            x: stripInterior.minX, y: box.minY + start, width: stripInterior.width,
            height: end - start)
          : CGRect(
            x: box.minX + start, y: stripInterior.minY, width: end - start,
            height: stripInterior.height)
        let r = FilmEdges.contentBounds(raster, within: candidate, base: gapBase, trimDark: false)
        let normal = NormalRect(
          CGRect(
            x: r.minX / CGFloat(w), y: r.minY / CGFloat(h), width: r.width / CGFloat(w),
            height: r.height / CGFloat(h)))
        let label = is135 ? "135" : (format == .auto || format == .medium ? "120" : format.rawValue)
        frames.append(
          FilmFrame(name: String(format: "%02d", frames.count + 1), rect: normal, format: label))
      }
    }
    return frames
  }
}
