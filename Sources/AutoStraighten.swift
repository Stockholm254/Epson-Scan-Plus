import CoreImage
import Foundation
import Vision

/// Lightroom's 自动 under its straightening: the horizon found in the picture as the screen shows
/// it (Vision's horizon detection, on this Mac), and the turn that levels it.
enum AutoStraighten {
  /// The clockwise turn on the screen, in degrees, that levels the horizon found in `picture`, as
  /// the screen shows it; nil where there is no clear one to go by.
  ///
  /// Vision's horizon detection often finds none in a picture all but level, and in some tilted a
  /// few degrees, that it finds once turned a little more. So the picture is read as it is and
  /// turned 4° either way, each reading less the turn given it; two at least must agree within
  /// 0.75° (a tree or a wall gave readings a degree and more apart), `agreed`.
  static func degrees(in picture: CGImage) -> Double? {
    let tilts = [0.0, probe, -probe].compactMap { turn -> Double? in
      guard let image = turn == 0 ? picture : turned(picture, by: turn), let found = tilt(in: image) else { return nil }
      return found - turn
    }
    return agreed(tilts).map { -$0 }
  }
  /// What readings agree on: all three within `agreement`, their middle one; else the closest two
  /// within it, between them; else nothing.
  static func agreed(_ readings: [Double]) -> Double? {
    let t = readings.sorted()
    if t.count == 3, t[2] - t[0] <= agreement { return t[1] }
    var best: (low: Double, high: Double)?
    for i in t.indices {
      for j in t.indices where j > i && t[j] - t[i] <= agreement {
        if best.map({ t[j] - t[i] < $0.high - $0.low }) ?? true { best = (t[i], t[j]) }
      }
    }
    return best.map { ($0.low + $0.high) / 2 }
  }
  static let probe = 4.0, agreement = 0.75
  /// How far the horizon Vision finds in `image` is turned clockwise on the screen, in degrees: as
  /// it reads (a picture turned 5° clockwise reads +5), whatever its documentation's axes.
  static func tilt(in image: CGImage) -> Double? {
    let request = VNDetectHorizonRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil, let horizon = request.results?.first else { return nil }
    return Double(horizon.angle) * 180 / .pi
  }
  /// `image` turned `degrees` clockwise on the screen about its middle, cut to a part inside it
  /// (a tenth off each side) so no corner is empty.
  static func turned(_ image: CGImage, by degrees: Double) -> CGImage? {
    let ci = CIImage(cgImage: image), e = ci.extent
    // Core Image's y is up: clockwise on the screen is a negative angle.
    let r = ci.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY)
      .concatenating(CGAffineTransform(rotationAngle: -degrees * .pi / 180))
      .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY)))
    let inner = e.insetBy(dx: e.width * 0.1, dy: e.height * 0.1).integral
    return context.createCGImage(r.cropped(to: inner), from: inner)
  }
  private static let context = CIContext(options: [.cacheIntermediates: false])
}

extension AppModel {
  /// The frame whose horizon is being looked for, off the main thread.
  private static var straighteningFrame: UUID?

  /// 自动拉直: the frame shown, or each of those chosen (⌘ / ⇧), by the horizon in its own picture.
  /// Each is analysed as the export analyses it, on a small copy off the main thread (from the light
  /// table too, and right after another frame was shown, whose analysis was not this one's); those
  /// found, and unchanged meanwhile, levelled as one edit (⌘Z), ③'s crop kept on the picture as
  /// `straighten` keeps it. `done`, where given, is told in a line what came of it (the assistant's
  /// tool waits for it).
  func autoStraighten(done: ((String) -> Void)? = nil) {
    guard let shown = selected, !isWorking, Self.straighteningFrame == nil else {
      done?(selected == nil ? "没有选中的画面。" : "正在忙，稍后再自动拉直。")
      return
    }
    let chosen = multiSelected ? selection : [shown], profile = conversionProfile
    let wanted = chosen.map { f -> (FilmFrame, Adjustments) in
      var s = asShown(f).adjustments
      (s.angle, s.composition) = (nil, nil)
      return (f, s)
    }
    Self.straighteningFrame = shown.id
    status = chosen.count == 1 ? "正在找第 \(shown.name) 张的地平线…" : "正在找所选 \(chosen.count) 张的地平线…"
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let found = wanted.map { f, unturned -> Double? in
        autoreleasepool {
          guard let src = try? self.source(for: f, maxDimension: 1200) else { return nil }
          let analysis = ImagePipeline.shared.analyze(src, settings: f.adjustments, profile: profile)
          return ImagePipeline.shared.render(src, settings: unturned, profile: profile, analysis: analysis, negative: false)
            .flatMap(AutoStraighten.degrees).flatMap { abs($0) <= 45 ? $0 : nil }
        }
      }
      DispatchQueue.main.async {
        Self.straighteningFrame = nil
        var turns = [(index: Int, angle: Double)](), changed = 0, none = 0, level = [Double]()
        for (f, d) in zip(chosen, found) {
          // Changed meanwhile (a fader, a line drawn, turned or mirrored): left as it now is.
          guard let i = self.frames.firstIndex(where: { $0.id == f.id }), self.frames[i].adjustments == f.adjustments else {
            changed += 1
            continue
          }
          guard let d else { none += 1; continue }
          // Kept unmirrored, as `straighten` keeps it.
          let mirror: Double = self.frames[i].adjustments.flipHorizontal == true ? -1 : 1
          let a = (d * 100).rounded() / 100 * mirror
          if abs(a - (self.frames[i].adjustments.angle ?? 0)) < 0.005 { level.append(d); continue }
          turns.append((i, a))
        }
        if !turns.isEmpty {
          self.recordEdit("自动拉直", key: "自动拉直-\(UUID())")
          for (i, a) in turns {
            let aspect = self.frameAspect(self.frames[i])
            self.frames[i].adjustments.angle = abs(a) < 0.005 ? nil : a
            if let o = self.frames[i].adjustments.composition, let aspect {
              self.frames[i].adjustments.composition = ImageGeometry.shrunk(o, degrees: a, aspect: aspect)
            }
          }
          if turns.contains(where: { self.frames[$0.index].id == self.selectedID }) { self.showStraighteningGrid() }
          self.refresh()
          self.saveProject()
          self.updateThumbnails()
        }
        let note: String
        if chosen.count == 1 {
          let name = shown.name
          if changed > 0 {
            self.status = "第 \(name) 张在找地平线时改过，没有改动"
            note = "改过，没有拉直"
          } else if none > 0 {
            self.status = "第 \(name) 张没有找到清楚的地平线，没有改动；可以用「画线」沿一条应是水平或竖直的线拉直"
            note = "没有找到清楚的地平线"
          } else if let d = level.first {
            self.status = String(format: "第 %@ 张已经是平的（%+.2f°）", name, d)
            note = "已经是平的"
          } else {
            let line = String(format: "%+.2f°", turns[0].angle * (self.frames[turns[0].index].adjustments.flipHorizontal == true ? -1 : 1))
            self.status = "已自动拉直第 \(name) 张：\(line) · ⌘Z 撤销"
            note = "自动拉直 " + line
          }
        } else {
          var parts = [turns.isEmpty ? "所选 \(chosen.count) 张都没有拉直" : "已自动拉直所选的 \(turns.count) 张"]
          if none > 0 { parts.append("\(none) 张没有找到清楚的地平线") }
          if !level.isEmpty { parts.append("\(level.count) 张已经是平的") }
          if changed > 0 { parts.append("\(changed) 张在找地平线时改过") }
          self.status = parts.joined(separator: "，") + (turns.isEmpty ? "" : " · ⌘Z 撤销")
          note = turns.isEmpty ? "没有拉直" : "自动拉直 \(turns.count) 张"
        }
        self.noteOnCanvas(note)
        done?(self.status)
      }
    }
  }
}
