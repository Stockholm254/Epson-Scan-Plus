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
  /// 0.75° (a tree or a wall gave readings a degree and more apart), and the middle one is taken.
  static func degrees(in picture: CGImage) -> Double? {
    let tilts = [0.0, probe, -probe].compactMap { turn -> Double? in
      guard let image = turn == 0 ? picture : turned(picture, by: turn), let found = tilt(in: image) else { return nil }
      return found - turn
    }.sorted()
    guard tilts.count >= 2, let low = tilts.first, let high = tilts.last, high - low <= agreement else { return nil }
    let tilt = tilts.count == 3 ? tilts[1] : (low + high) / 2
    return -tilt
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

  /// 自动拉直 the selected frame: its picture as shown, unturned, read on a small copy off the main
  /// thread; the horizon found levelled as one edit (⌘Z), ③'s crop kept on the picture as
  /// `straighten` keeps it.
  /// `done`, where given, is told in a line what came of it (the assistant's tool waits for it).
  func autoStraighten(done: ((String) -> Void)? = nil) {
    guard let frame = selected, !isWorking, Self.straighteningFrame == nil else {
      done?(selected == nil ? "没有选中的画面。" : "正在忙，稍后再自动拉直。")
      return
    }
    // Several chosen (⌘ / ⇧): each by its own horizon, as one edit.
    if multiSelected { return autoStraightenChosen(done: done) }
    guard let analysis = toneAnalysis else {
      status = "画面还在分析，稍后再自动拉直"
      done?(status)
      return
    }
    let profile = conversionProfile
    var settings = asShown(frame).adjustments
    (settings.angle, settings.composition) = (nil, nil)
    Self.straighteningFrame = frame.id
    status = "正在找第 \(frame.name) 张的地平线…"
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let picture = (try? self.source(for: frame, maxDimension: 1200)).flatMap {
        ImagePipeline.shared.render($0, settings: settings, profile: profile, analysis: analysis, negative: false)
      }
      let found = picture.flatMap(AutoStraighten.degrees)
      DispatchQueue.main.async {
        Self.straighteningFrame = nil
        guard self.selectedID == frame.id else {
          done?("第 \(frame.name) 张在找地平线时换了画面，没有改动。")
          return
        }
        defer { done?(self.status) }
        guard let d = found, abs(d) <= 45 else {
          self.status = "第 \(frame.name) 张没有找到清楚的地平线，没有改动；可以用「画线」沿一条应是水平或竖直的线拉直"
          self.noteOnCanvas("没有找到清楚的地平线")
          return
        }
        let was = self.screenAngle
        // Its own step in 编辑 › 撤销, apart from a drag of the slider just before.
        self.straighten(d, named: "自动拉直")
        let line = String(format: "%+.2f°", self.screenAngle)
        if abs(self.screenAngle - was) < 0.005 {
          self.status = "第 \(frame.name) 张已经是平的（\(line)）"
          self.noteOnCanvas("已经是平的")
        } else {
          self.status = "已自动拉直第 \(frame.name) 张：\(line) · ⌘Z 撤销"
          self.noteOnCanvas("自动拉直 " + line)
        }
      }
    }
  }
  /// 自动拉直 the frames chosen (⌘ / ⇧), each by the horizon in its own picture, analysed as the
  /// export analyses it; those found levelled as one edit, the others left as they are.
  private func autoStraightenChosen(done: ((String) -> Void)?) {
    let chosen = selection, profile = conversionProfile
    let wanted = chosen.map { f -> (FilmFrame, Adjustments) in
      var s = asShown(f).adjustments
      (s.angle, s.composition) = (nil, nil)
      return (f, s)
    }
    Self.straighteningFrame = selectedID
    status = "正在找所选 \(chosen.count) 张的地平线…"
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let found = wanted.map { f, shown -> Double? in
        autoreleasepool {
          guard let src = try? self.source(for: f, maxDimension: 1200) else { return nil }
          let analysis = ImagePipeline.shared.analyze(src, settings: f.adjustments, profile: profile)
          return ImagePipeline.shared.render(src, settings: shown, profile: profile, analysis: analysis, negative: false)
            .flatMap(AutoStraighten.degrees).flatMap { abs($0) <= 45 ? $0 : nil }
        }
      }
      DispatchQueue.main.async {
        Self.straighteningFrame = nil
        // Those changed meanwhile are left as they now are.
        let turns = zip(chosen, found).compactMap { f, d -> (Int, Double)? in
          guard let d, let i = self.frames.firstIndex(where: { $0.id == f.id }), self.frames[i].adjustments == f.adjustments else { return nil }
          return (i, d)
        }
        if !turns.isEmpty {
          self.recordEdit("自动拉直", key: "自动拉直-\(UUID())")
          for (i, d) in turns {
            let a = (d * 100).rounded() / 100 * (self.frames[i].adjustments.flipHorizontal == true ? -1 : 1)
            let aspect = self.frameAspect(self.frames[i])
            self.frames[i].adjustments.angle = abs(a) < 0.005 ? nil : a
            if let o = self.frames[i].adjustments.composition, let aspect {
              self.frames[i].adjustments.composition = ImageGeometry.shrunk(o, degrees: a, aspect: aspect)
            }
          }
          self.refresh()
          self.saveProject()
          self.updateThumbnails()
        }
        let missed = chosen.count - turns.count
        self.status = turns.isEmpty
          ? "所选 \(chosen.count) 张都没有找到清楚的地平线，没有改动"
          : "已自动拉直所选的 \(turns.count) 张" + (missed > 0 ? "，\(missed) 张没有找到清楚的地平线、没有改动" : "") + " · ⌘Z 撤销"
        self.noteOnCanvas(turns.isEmpty ? "没有找到清楚的地平线" : "自动拉直 \(turns.count) 张")
        done?(self.status)
      }
    }
  }
}
