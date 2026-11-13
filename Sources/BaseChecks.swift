import Foundation

/// What a copy roll's film edges say beyond the base itself: a frame whose edge reads apart from
/// the rest of the roll (the light or the exposure changed partway). How to set the copy light is
/// ①'s 片基偏色 (`BaseBalance`), grey under daylight.
extension AppModel {
  /// How much denser this frame's own film edge reads than the median of the roll's other edges
  /// read alike, per channel, in density: a light turned or an exposure changed partway shows
  /// here. Nil without an edge of its own and two others to compare it with.
  func baseDrift(_ f: FilmFrame) -> RGB? {
    guard let mine = f.edgeBase?.base, isSinglePicture(f) else { return nil }
    let blanks = blankFrameIDs
    let others = frames.filter {
      $0.id != f.id && isSinglePicture($0) && !blanks.contains($0.id) && $0.adjustments.inputGamma == f.adjustments.inputGamma
        && $0.crosstalk == f.crosstalk && $0.flatID == f.flatID
    }.compactMap { $0.edgeBase?.base }
    guard others.count >= 2 else { return nil }
    func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
    return RGB((0..<3).map { c in
      log10(max(1e-6, median(others.map { $0.values[c] })) / max(1e-6, mine.values[c])) * f.adjustments.inputGamma
    })
  }
  /// Past this, in density, a frame's edge is said to read apart from the roll's.
  static let driftLimit = 0.03

  /// The check above in words, for the base's ⓘ and the strip over the single frame.
  func baseNotes(_ f: FilmFrame) -> String {
    var lines = [String]()
    if let d = baseDrift(f), d.values.map(abs).max()! > Self.driftLimit {
      lines.append(String(format: "这张片边的片基比本卷其他张密 R %+.2f · G %+.2f · B %+.2f D：中途调过灯或曝光？这一张按自己的片边去色罩。", d.r, d.g, d.b))
    }
    // The shown frame's picture clearer than its base in places: the base is too dense.
    if f.id == selectedID, let clearer = toneAnalysis?.clearerThanBase, clearer > 0.005 {
      lines.append(String(format: "画面里有 %.1f%% 比片基还透：没曝光的片基应该是最透的，这个片基可能取在了漏光、边字或暗角的片边上，暗部会被压黑、带色。换一处重新取片基，或检查平场。", clearer * 100))
    }
    return lines.joined(separator: "\n")
  }
}
