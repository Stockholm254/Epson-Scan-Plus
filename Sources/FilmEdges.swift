import CoreGraphics
import Foundation

/// Only examines edge-connected bands. Interior bright objects are never removed.
enum FilmEdges {
  struct Line {
    var mean: RGB
    var deviation: Double
    var clipped: Double
    var borderFraction: Double
  }

  static func line(
    _ raster: Raster, vertical: Bool, coordinate: Int, from: Int, to: Int, base: RGB? = nil
  ) -> Line {
    let samples = (from..<max(from + 1, to)).map {
      raster.pixel(vertical ? coordinate : $0, vertical ? $0 : coordinate)
    }
    let mean = RGB(
      (0..<3).map { c in samples.reduce(0) { $0 + $1.values[c] } / Double(samples.count) })
    let variance = samples.reduce(0) { $0 + pow($1.g - mean.g, 2) } / Double(samples.count)
    let clipped = samples.filter { $0.values.min()! > 0.94 || $0.values.max()! < 0.045 }.count
    let borderCount = samples.filter { p in
      p.values.min()! > 0.94 || p.values.max()! < 0.045
        || (base.map { b in zip(p.values, b.values).allSatisfy { abs($0 - $1) < 0.04 } } ?? false)
    }.count
    return Line(
      mean: mean, deviation: sqrt(variance), clipped: Double(clipped) / Double(samples.count),
      borderFraction: Double(borderCount) / Double(samples.count))
  }

  /// Refine an aperture/cut interval using its measured shared inter-frame base color.
  /// A bounded search avoids following similar-colored subjects far into the image.
  static func contentBounds(
    _ raster: Raster, within box: CGRect, base: RGB? = nil,
    safety: Int = 1, trimDark: Bool = true
  ) -> CGRect {
    let x0 = max(0, Int(ceil(box.minX)))
    let x1 = min(raster.width, Int(floor(box.maxX)))
    let y0 = max(0, Int(ceil(box.minY)))
    let y1 = min(raster.height, Int(floor(box.maxY)))
    guard x1 - x0 >= 16, y1 - y0 >= 16 else { return box }
    func trim(vertical: Bool, reverse: Bool) -> Int {
      let start = vertical ? x0 : y0
      let end = vertical ? x1 : y1
      let crossStart = vertical ? y0 : x0
      let crossEnd = vertical ? y1 : x1
      let margin = max(1, (crossEnd - crossStart) / 8)
      let profiles = (start..<end).map {
        line(
          raster, vertical: vertical, coordinate: $0, from: crossStart + margin,
          to: crossEnd - margin, base: base)
      }
      let interior = profiles[(profiles.count / 4)..<(profiles.count * 3 / 4)]
      let middle = RGB(
        (0..<3).map { c in
          let sorted = interior.map { $0.mean.values[c] }.sorted()
          return sorted[sorted.count / 2]
        })
      let limit = max(2, Int(Double(end - start) * 0.10))
      var run = 0
      for d in 0..<limit {
        let p = profiles[reverse ? profiles.count - 1 - d : d]
        let dark = trimDark && (0..<3).allSatisfy { p.mean.values[$0] < middle.values[$0] * 0.72 }
        let gap =
          base.map { color in
            p.deviation < 0.025
              && zip(p.mean.values, color.values).allSatisfy { abs($0 - $1) < 0.028 }
          } ?? false
        // A slanted/defocused film end may mix clear transmission with base in
        // every pixel, so neither a pure-white nor a flat-base test can match it.
        let washedBase =
          base.map { color in
            zip(p.mean.values, color.values).allSatisfy { $0 >= $1 - 0.012 }
              && p.mean.g > color.g + 0.035
          } ?? false
        guard p.borderFraction > 0.72 || dark || gap || washedBase else { break }
        run = d + 1
      }
      // No confirmed inner edge: do not crop an arbitrary 10% from a dark/flat subject.
      return run == limit ? safety : run + (run > 0 ? max(2, safety) : safety)
    }
    let left = trim(vertical: true, reverse: false)
    let right = trim(vertical: true, reverse: true)
    let top = trim(vertical: false, reverse: false)
    let bottom = trim(vertical: false, reverse: true)
    return CGRect(
      x: x0 + left, y: y0 + top, width: x1 - x0 - left - right, height: y1 - y0 - top - bottom)
  }
}
