import Foundation

/// The film's edge around a copied frame on the 去漏光 page (`LeakEngine.pictureEdges`,
/// `cleanedEdges`): a picture with the film's black around it, yellow edge numbers on the left
/// strip, a leak's yellow line along the film's side and a glow over the whole right strip.
enum LightLeakEdgesTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let w = 900, h = 900
    let black = SIMD3(0.12, 0.12, 0.10), yellow = SIMD3(0.95, 0.72, 0.18), sky = SIMD3(0.45, 0.6, 0.88)
    // The photograph from 5% to 98% across and 4% to 97% down.
    func inPicture(_ x: Int, _ y: Int) -> Bool { x >= 45 && x < 882 && y >= 36 && y < 873 }
    func isDigit(_ x: Int, _ y: Int) -> Bool {
      // Three bold digits down the left strip, each 14 × 20 with 4-pixel strokes.
      for top in [400, 424, 448] where y >= top && y < top + 20 && x >= 16 && x < 30 {
        let dx = x - 16, dy = y - top
        if dx < 4 || dx >= 10 || dy < 4 || dy >= 16 { return true }
      }
      return false
    }
    var data = [UInt16](repeating: 0, count: w * h * 3)
    func put(_ x: Int, _ y: Int, _ p: SIMD3<Double>) {
      for c in 0..<3 { data[(y * w + x) * 3 + c] = UInt16(min(1, max(0, p[c])) * 65535) }
    }
    for y in 0..<h {
      for x in 0..<w {
        // A little grain everywhere, as on film.
        let grain = 0.012 * sin(Double(x * 37 + y * 91))
        var p = inPicture(x, y) ? sky * (0.9 + 0.1 * Double(y) / Double(h)) : black
        if !inPicture(x, y) {
          if isDigit(x, y) { p = yellow }
          if x >= 3 && x < 6 && y > 300 { p = SIMD3(0.8, 0.9, 0.3) }       // the side's leak line
          if x >= 882 { p = SIMD3(0.75, 0.78, 0.25) * (0.8 + 0.2 * Double(y) / Double(h)) }  // a glow
        }
        put(x, y, p + SIMD3(repeating: grain))
      }
    }
    let original = LeakImage(width: w, height: h, data: data)
    // The hint is the de-masking region as drawn: inside the photograph by a little on the left.
    let edges = LeakEngine.pictureEdges(original, near: [0.056, 0.045, 0.975, 0.965])
    let found = edges.compactMap { $0 }
    try check(found.count == 4 && abs(edges[0]! - 45.0 / 899) < 0.004 && abs(edges[1]! - 36.0 / 899) < 0.004
      && abs(edges[2]! - 882.0 / 899) < 0.004 && abs(edges[3]! - 873.0 / 899) < 0.004,
      "the photograph's edges are found along the film's edge near the de-masking region: " + edges.map { $0.map { String(format: "%.3f", $0) } ?? "–" }.joined(separator: " "))
    // What the reference did to the picture: anything; here it made the whole frame grey.
    var greyed = original
    for i in 0..<(w * h * 3) { greyed.data[i] = 30000 }
    let cleaned = LeakEngine.cleanedEdges(greyed, original: original, picture: edges)
    func at(_ x: Int, _ y: Int) -> SIMD3<Double> { cleaned.rgb(y * w + x) }
    func far(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
    let digit = at(17, 402), line = at(4, 600), glow = at(890, 500), base = at(20, 200), inside = at(400, 400)
    try check(far(digit, yellow) < 0.05, String(format: "the edge print keeps its own colour: %.2f %.2f %.2f", digit.x, digit.y, digit.z))
    try check(far(line, black) < 0.05 && far(glow, black) < 0.06 && far(base, black) < 0.04,
      String(format: "the leak's line along the side and the glow over the strip go back to the film's black: %.2f, %.2f (black %.2f)",
        line.y, glow.y, black.y))
    try check(far(inside, SIMD3(repeating: 30000.0 / 65535)) < 0.002, "the photograph is the repair's, as it was")
    // No film's edge found, nothing changes.
    try check(LeakEngine.cleanedEdges(greyed, original: original, picture: [nil, nil, nil, nil]).data == greyed.data,
      "where no film's edge is found the repair is left as it is")
  }
}
