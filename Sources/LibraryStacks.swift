import CoreGraphics
import Foundation

/// Rolls the library lays one over another: the same film scanned again (to try a setting, after a
/// rescan) comes out as rolls whose sleeves look the same. And naming a roll that is not open.
extension RollLibrary {
  /// Names the roll whose project is `project`, as its own panel does when it is open; an empty
  /// name goes back to the date it was started.
  static func rename(_ project: URL, to name: String) throws {
    let data = try Data(contentsOf: project)
    var p = try JSONDecoder().decode(DeskProject.self, from: data)
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    p.rollName = trimmed.isEmpty ? nil : trimmed
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try e.encode(p).write(to: project, options: .atomic)
  }
  /// A 64-bit difference hash: the picture in 9 × 8 grey, a bit for each cell brighter than the one
  /// on its right. Alike pictures differ in few bits whatever their colour, tone or size.
  static func differenceHash(_ image: CGImage) -> UInt64 {
    let w = 9, h = 8
    var px = [UInt8](repeating: 0, count: w * h)
    let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
      guard let ctx = CGContext(
        data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      ctx.interpolationQuality = .medium
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return 0 }
    var bits: UInt64 = 0
    for y in 0..<h {
      for x in 0..<(w - 1) {
        bits <<= 1
        if px[y * w + x] > px[y * w + x + 1] { bits |= 1 }
      }
    }
    return bits
  }
  /// How unlike two frames are, in bits of 64. A negative against its positive flips every step
  /// of brightness, so the hash's complement is as close as the hash.
  static func unlikeness(_ a: UInt64, _ b: UInt64) -> Int {
    let d = (a ^ b).nonzeroBitCount
    return min(d, 64 - d)
  }
  /// The first three frames' hashes: from the positives the app keeps, else the frames cut from
  /// the film. Nil for a roll of fewer than three frames, too few to tell.
  static func fingerprint(_ entry: RollEntry) -> [UInt64]? {
    guard entry.frames.count >= 3 else { return nil }
    let first = Array(entry.frames.prefix(3))
    let thumbs = thumbnails(for: entry, limit: 3, maxPixels: 96)
    let hashes = first.compactMap { thumbs[$0.id].map { differenceHash($0.image) } }
    return hashes.count == first.count ? hashes : nil
  }
  /// Most bits two frames of the same film may differ by: a rescan or another conversion moves a
  /// few; another film's frames differ by about half of them.
  static let sameFrameBits = 10
  /// The rolls that hold the same film, each group newest first (`entries` are): as many frames,
  /// and the first three alike frame by frame. Joined pair by pair, so rolls alike through another
  /// lie in one stack; rolls alone are left out.
  static func sameFilmGroups(_ entries: [RollEntry], prints: [String: [UInt64]]) -> [[String]] {
    var parent = Array(entries.indices)
    func root(_ i: Int) -> Int {
      var i = i
      while parent[i] != i {
        parent[i] = parent[parent[i]]
        i = parent[i]
      }
      return i
    }
    for i in entries.indices {
      guard let a = prints[entries[i].id] else { continue }
      for j in entries.indices where j > i && entries[j].frames.count == entries[i].frames.count {
        guard let b = prints[entries[j].id], b.count == a.count,
          zip(a, b).allSatisfy({ unlikeness($0, $1) <= sameFrameBits })
        else { continue }
        parent[root(j)] = root(i)
      }
    }
    var groups = [Int: [String]]()
    for i in entries.indices { groups[root(i), default: []].append(entries[i].id) }
    // In the order of their newest rolls, each newest first, as `entries` lie.
    return groups.values.filter { $0.count > 1 }.sorted { a, b in
      (entries.firstIndex { $0.id == a[0] } ?? 0) < (entries.firstIndex { $0.id == b[0] } ?? 0)
    }
  }
}
