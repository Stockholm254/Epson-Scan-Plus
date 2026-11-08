import CoreGraphics
import Foundation

/// The frames' dust: looked for, marked by hand, kept or filled, and filled as each frame is read.
extension AppModel {
  /// Whether `frame` can have its dust filled: a negative read at 16 bits (a scan, a copy shot, a
  /// 16-bit file of another scanner's); a positive or an 8-bit file has no density to look for dust by.
  func dustApplies(_ frame: FilmFrame) -> Bool {
    guard frame.adjustments.inputIsNegative else { return false }
    if let bits = frame.sourceBits { return bits >= 16 }
    return true
  }

  /// `image`, the frame's pixels as read, with its dust filled, when it has any to fill. The last
  /// few filled pictures are kept, so a slider dragged over the frame does not fill it again each step.
  func dustFilled(_ image: CGImage, _ frame: FilmFrame) -> CGImage {
    guard let dust = frame.dust, dust.on, dust.filledCount > 0, dustApplies(frame), image.bitsPerComponent == 16 else { return image }
    let provider = image.dataProvider.map { "\(ObjectIdentifier($0))" } ?? "-"
    let key = "\(frame.id) \(frame.rect) \(image.width)x\(image.height) \(provider) \(dust.signature)"
    if let kept = DustKept.shared.image(key) { return kept }
    let filled = DustFill.apply(dust.spots, to: image, rect: frame.rect)
    // Full resolution is kept by the zoom on its own.
    if image.width * image.height <= 16_000_000 { DustKept.shared.keep(filled, key) }
    return filled
  }

  /// Green over red that a spot's excess may reach and still be dust: between 1 and the film's grey
  /// (its green slope over its red), nearer 1.
  func dustGreenOverRed(_ frame: FilmFrame) -> Double {
    let s = ImagePipeline.slopes(frame.adjustments, conversionProfile).slopes.values
    let grey = s[0] > 0 ? s[1] / s[0] : 1.28
    return min(1.15, max(1.04, 1 + 0.3 * (grey - 1)))
  }

  /// Looks for dust on `ids` at full resolution, one frame after another, off the main thread. A
  /// frame's marks by hand stay, and so does any spot the user kept that is found again.
  func findDust(_ ids: [UUID], sensitivity: DustSensitivity = .medium) {
    guard dustSearch == nil else { return }
    let wanted = frames.filter { ids.contains($0.id) && dustApplies($0) }
    guard !wanted.isEmpty else {
      status = "这张不能除尘：只用于 16 位的负片（扫描、翻拍）"
      return
    }
    dustSearch = "找灰尘…"
    DispatchQueue.global(qos: .userInitiated).async {
      var results = [(UUID, [DustSpot])]()
      for (n, frame) in wanted.enumerated() {
        let label = wanted.count > 1 ? "找灰尘：第 \(n + 1) / \(wanted.count) 张" : "找灰尘"
        DispatchQueue.main.async { self.dustSearch = label }
        guard let image = try? self.dustFreeSource(for: frame, full: true) else { continue }
        var options = DustFinder.Options()
        options.factor = sensitivity.factor
        options.gamma = frame.adjustments.inputGamma
        options.greenOverRed = DispatchQueue.main.sync { self.dustGreenOverRed(frame) }
        let found = DustFinder.find(image, options: options) { done in
          DispatchQueue.main.async { self.dustSearch = label + " · \(Int(done * 100))%" }
        }
        results.append((frame.id, found.map { $0.spot(in: frame.rect, width: image.width, height: image.height) }))
      }
      DispatchQueue.main.async {
        self.dustSearch = nil
        self.recordEdit(wanted.count > 1 ? "整卷找灰尘" : "找灰尘")
        var total = 0
        for (id, spots) in results {
          guard let i = self.frames.firstIndex(where: { $0.id == id }) else { continue }
          let old = self.frames[i].dust?.spots ?? []
          let byHand = old.filter { $0.marked == true }
          let kept = old.filter { $0.kept == true && $0.marked != true }
          let merged = spots.map { spot -> DustSpot in
            var s = spot
            if kept.contains(where: { $0.box.cg.intersects(spot.box.cg) }) { s.kept = true }
            return s
          }.filter { s in !byHand.contains { $0.box.cg.intersects(s.box.cg) } } + byHand
          self.frames[i].dust = DustState(on: true, spots: merged, sensitivity: sensitivity)
          total += merged.count
        }
        self.status = results.count > 1 ? "找到灰尘 \(total) 处，\(results.count) 张" : "找到灰尘 \(total) 处"
        self.refresh()
        self.updateThumbnails()
        self.saveProject()
      }
    }
  }

  /// A click on the single view with the dust tool, at `point` as the view shows it: on a spot it
  /// changes that spot (filled ↔ kept; one marked by hand goes); elsewhere it marks the speck there,
  /// as found around the click, or a small round spot where nothing stands out.
  func markDust(at point: CGPoint) {
    guard let i = selectedIndex, dustApplies(frames[i]) else {
      status = "这张不能除尘：只用于 16 位的负片（扫描、翻拍）"
      return
    }
    let frame = frames[i], crop = frame.rect
    let q = ImageGeometry.raw(point, settings: frame.adjustments, aspect: shownAspect(frame))
    let at = CGPoint(x: crop.x + q.x * crop.width, y: crop.y + q.y * crop.height)
    var dust = frame.dust ?? DustState()
    // A spot under the click, the smallest first; a little slack around small ones.
    let slack = 0.004 * max(crop.width, crop.height)
    if let j = dust.spots.indices.filter({ dust.spots[$0].box.cg.insetBy(dx: -slack, dy: -slack).contains(at) })
      .min(by: { dust.spots[$0].box.width * dust.spots[$0].box.height < dust.spots[$1].box.width * dust.spots[$1].box.height })
    {
      recordEdit("点选灰尘")
      if dust.spots[j].marked == true {
        dust.spots.remove(at: j)
        status = "已撤掉手动标的灰尘"
      } else {
        dust.spots[j].kept = dust.spots[j].kept == true ? nil : true
        status = dust.spots[j].kept == true ? "这一处留在画面里" : "这一处去掉"
      }
      dust.on = true
      frames[i].dust = dust
      refresh()
      updateThumbnails()
      saveProject()
      return
    }
    // Looked for around the click at the size the view reads, more keenly than a search.
    guard let image = try? dustFreeSource(for: frame, full: false, maxDimension: 3000) else { return }
    let W = image.width, H = image.height
    let px = Int(q.x * Double(W)), py = Int(q.y * Double(H))
    let r = max(24, Int(0.02 * Double(max(W, H))))
    let x0 = max(0, px - r), y0 = max(0, py - r), x1 = min(W, px + r), y1 = min(H, py + r)
    var spot: DustSpot?
    if x1 - x0 > 16, y1 - y0 > 16, let window = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) {
      var options = DustFinder.Options()
      options.factor = 1.3
      options.least = 0.1
      options.greenOverRed = nil
      options.edges = false
      options.gamma = frame.adjustments.inputGamma
      options.scale = Double(max(W, H)) / 9600
      let near = max(3, r / 6)
      let found = DustFinder.find(window, options: options).filter { m in
        (0..<m.height).contains { y in
          (0..<m.width).contains { x in
            m.cells[y * m.width + x] && abs(m.x + x + x0 - px) <= near && abs(m.y + y + y0 - py) <= near
          }
        }
      }
      // All of a wide soft speck, which stands out of the opening only at its thin parts; only what
      // stood out where all of it would lie across two films.
      let core = found.min(by: { $0.area < $1.area })
      var speck = DustFinder.wholeSpeck(at: (px - x0, py - y0), in: window, core: core, near: near, gamma: options.gamma) ?? core
      if let whole = speck, whole != core, DustFinder.twoFilms(whole, in: window, scale: options.scale ?? 1, gamma: options.gamma) {
        speck = core
      }
      if let m = speck {
        var placed = m
        (placed.x, placed.y) = (m.x + x0, m.y + y0)
        spot = placed.spot(in: crop, width: W, height: H, marked: true)
      }
    }
    if spot == nil {
      // Nothing stands out: a round spot the size of a small speck; but not across two films (a
      // click beside the dust, on the edge of a sculpture against the sky), which the fill would
      // carry one into the other.
      let radius = max(2, Int(0.0025 * Double(max(W, H))))
      let side = 2 * radius + 1
      var cells = [Bool](repeating: false, count: side * side)
      for y in 0..<side { for x in 0..<side where (x - radius) * (x - radius) + (y - radius) * (y - radius) <= radius * radius { cells[y * side + x] = true } }
      let round = DustMask(x: px - radius, y: py - radius, width: side, height: side, cells: cells)
      if DustFinder.twoFilms(round, in: image, scale: Double(max(W, H)) / 9600, gamma: frame.adjustments.inputGamma) {
        status = "这里压在两种胶片的交界上，补了会把一边带进另一边：点在灰尘的正中"
        return
      }
      spot = round.spot(in: crop, width: W, height: H, marked: true)
    }
    guard let spot else { return }
    recordEdit("点选灰尘")
    dust.spots.append(spot)
    dust.on = true
    frames[i].dust = dust
    status = "已去掉一处灰尘 · 共 \(dust.filledCount) 处"
    refresh()
    updateThumbnails()
    saveProject()
  }

  /// Fills the selected frame's dust, or leaves it all in.
  func setDustFilled(_ on: Bool) {
    guard let i = selectedIndex, frames[i].dust != nil else { return }
    recordEdit(on ? "去掉灰尘" : "不去灰尘")
    frames[i].dust?.on = on
    refresh()
    updateThumbnails()
    saveProject()
  }

  /// Forgets the selected frame's dust, found and marked.
  func clearDust() {
    guard let i = selectedIndex, frames[i].dust != nil else { return }
    recordEdit("清除灰尘")
    frames[i].dust = nil
    status = "已清除这一张的灰尘标记"
    refresh()
    updateThumbnails()
    saveProject()
  }
}

/// The last few dust-filled pictures, by what they were filled from.
final class DustKept {
  static let shared = DustKept()
  private let lock = NSLock()
  private var kept = [(key: String, image: CGImage)]()
  func image(_ key: String) -> CGImage? {
    lock.lock()
    defer { lock.unlock() }
    return kept.first { $0.key == key }?.image
  }
  func keep(_ image: CGImage, _ key: String) {
    lock.lock()
    defer { lock.unlock() }
    kept.removeAll { $0.key == key }
    kept.insert((key, image), at: 0)
    if kept.count > 4 { kept.removeLast(kept.count - 4) }
  }
}
