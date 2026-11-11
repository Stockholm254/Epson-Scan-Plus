import Foundation

/// What a copy roll's film edges say beyond the base itself: a frame whose edge reads apart from
/// the rest of the roll (the light or the exposure changed partway), and, on the copy stand, how
/// to set the three lights so the base fills each channel alike.
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

  /// The copy light set so the film base reads about three quarters of full in each of the
  /// camera's channels, as the sensor took it (its crosstalk not taken out, which is what clips):
  /// each light's factor from where it is now, the strongest channel's at 1. Nil but for a copy
  /// read from the sensor with its base found on its edge.
  func lightRatio(_ f: FilmFrame) -> (reads: RGB, factors: RGB)? {
    guard f.sensorRead == true, f.adjustments.inputGamma == 1, let read = f.edgeBase?.base else { return nil }
    let raw = Crosstalk.moved(read, from: f.crosstalk, to: nil)
    guard raw.values.allSatisfy({ $0 > 0.002 }) else { return nil }
    let most = raw.values.max()!
    return (raw, RGB(raw.values.map { most / $0 }))
  }

  /// The checks above in a few lines, for the base's ⓘ and the strip over the single frame.
  func baseNotes(_ f: FilmFrame) -> String {
    var lines = [String]()
    if let d = baseDrift(f), d.values.map(abs).max()! > Self.driftLimit {
      lines.append(String(format: "这张片边的片基比本卷其他张密 R %+.2f · G %+.2f · B %+.2f D：中途调过灯或曝光？这一张按自己的片边去色罩。", d.r, d.g, d.b))
    }
    if let l = lightRatio(f) {
      let weakest = l.factors.values.max()!
      var line = String(format: "片基读数（相机原始，满格的比例）R %.0f%% · G %.0f%% · B %.0f%%。", l.reads.r * 100, l.reads.g * 100, l.reads.b * 100)
      if weakest > 1.25 {
        line += String(format: "让三个通道一样满：红灯 ×%.2f · 绿灯 ×%.2f · 蓝灯 ×%.2f（按最亮的一路不变），再调曝光让片基到 70–80%%。", l.factors.r, l.factors.g, l.factors.b)
      } else if (l.reads.values.max() ?? 0) < 0.6 {
        line += "三路已经相近；曝光还可以加，让片基到 70–80%。"
      } else {
        line += "三路相近，曝光合适。"
      }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }
}
