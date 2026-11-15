import SwiftUI

/// What the roll's check reads of a frame, from the slope estimate's pass over the roll
/// (`ImagePipeline.EdgeRatios`): its darkest film above its base, per channel; the share of it
/// clearer than the base; its own ratios of red's and blue's density steps to green's (r, 1, b);
/// and whether its base was measured (picked, shared, or from the film's edge) rather than guessed
/// from its own thinnest film, against which the first two say nothing.
struct FrameFigures: Equatable {
  var darkest: RGB?
  var clearer: Double
  var own: RGB?
  var measuredBase: Bool
}

/// One guess the app made for the roll that looks wrong: what, why it matters and what to do, and
/// where to set it right.
struct RollCheckItem: Identifiable, Equatable {
  enum Fix: Equatable {
    /// To ② 去色罩 on that frame with 取片基.
    case pickBase(UUID)
  }
  let id: String
  let title: String
  let detail: String
  var fix: Fix? = nil
}

extension AppModel {
  /// The roll's own check: the guesses made for it that look wrong (its film base, its slope
  /// estimate, its 去串色 against the calibration), each with why and what to do. A base measured
  /// on sprocket holes, or a roll gone green-cyan without its calibration, showed only as a cast
  /// to be asked about, and took a long hunt each to find.
  var rollCheck: [RollCheckItem] {
    var items = [RollCheckItem]()
    let colour = frames.filter { $0.adjustments.inputIsNegative && !$0.adjustments.isMonochrome }
    let figures = colour.compactMap { f in frameFigures[f.id].map { (frame: f, figures: $0) } }
    let measured = figures.filter { $0.figures.measuredBase }
    func names(_ fs: [FilmFrame]) -> String {
      let shown = fs.prefix(4).map(\.name).joined(separator: "、")
      return fs.count > 4 ? "\(shown) 等 \(fs.count) 张" : shown
    }

    // A base denser than the picture: picked on exposed film.
    let denser = measured.filter { $0.figures.clearer > Self.clearerAllowed }
    if let first = denser.first {
      let share = denser.map(\.figures.clearer).max() ?? 0
      items.append(RollCheckItem(
        id: "base-denser", title: "片基比画面还密",
        detail: String(format: "第 %@ 张有多达 %.0f%% 的画面比片基还透，片基多半取在了曝过光的地方，暗部会被压黑、偏色。到 ② 去色罩用「取片基」点片间或片边没曝光的地方，或回到自动。", names(denser.map(\.frame)), share * 100),
        fix: .pickBase(first.frame.id)))
    }

    // Every frame's darkest far above its base: a base clearer than the film's own, measured on
    // sprocket holes not burnt out, or the bare light beside the film.
    let lifted = measured.filter { m in
      guard let d = m.figures.darkest else { return false }
      return d.values.filter { $0 > Self.darkestAllowed }.count >= 2
    }
    if let first = lifted.first, measured.count >= 2, Double(lifted.count) >= 0.6 * Double(measured.count) {
      let darkest = (0..<3).map { c in Self.median(lifted.compactMap { $0.figures.darkest?.values[c] }) }
      items.append(RollCheckItem(
        id: "base-clearer", title: "整卷最暗处都远高于片基",
        detail: String(format: "%d 张里有 %d 张，最暗的地方也比片基密：红 %.2f、绿 %.2f、蓝 %.2f D（中位）。片基多半量在了比真片基更透的地方，比如没过曝的齿孔或片外的灯光：暗部会偏色，全卷斜率估计也会偏。到 ② 去色罩用「取片基」点片间或边字旁没曝光的片基，再「整卷共用片基」。", measured.count, lifted.count, darkest[0], darkest[1], darkest[2]),
        fix: .pickBase(first.frame.id)))
    }

    // The roll's slope estimate: not made, or far from the calibration or data sheet.
    if estimatesSlopes, !colour.isEmpty {
      let calibrated = profile.offsets != nil && useCalibration
      let estimate = colour.lazy.compactMap(\.adjustments.rollSlopes).first
      let why = colour.lazy.compactMap { self.rollSlopesWhy[$0.id] }.first
      if estimate == nil, let why, slopeEstimateApplies {
        items.append(RollCheckItem(
          id: "estimate-none", title: "全卷斜率估计没估出来",
          detail: "\(why)。现在按「\(conversionProfile.name)」的数据表斜率转换；画面里有中性的灰时，可以给这种胶片做预设标定。"))
      }
      let reference: (slopes: RGB, name: String)? = calibrated
        ? (profile.slopes, "标定") : conversionProfile.setsChannelContrast ? (conversionProfile.slopes, "数据表") : nil
      let owns = figures.compactMap(\.figures.own)
      let spread = owns.count >= 3 ? (r: Self.spread(owns.map(\.r)), b: Self.spread(owns.map(\.b))) : nil
      let spreadWords = spread.map { String(format: "各张自己估出来的也相差不小（红 ±%.0f%%、蓝 ±%.0f%%）。", $0.r * 100, $0.b * 100) }
      if let estimate, let reference, estimate.g > 0, reference.slopes.g > 0 {
        let dr = (estimate.r / estimate.g) / (reference.slopes.r / reference.slopes.g) - 1
        let db = (estimate.b / estimate.g) / (reference.slopes.b / reference.slopes.g) - 1
        if max(abs(dr), abs(db)) > Self.estimateAllowed {
          let what = calibrated
            ? "用着标定时按标定转换。差这么多，多半是这卷的灯光、胶片或冲洗和标定时不同，值得用这卷重新标定。"
            : "现在按这个估计转换。估计会被画面内容带偏（树叶多时蓝偏低，阳光和阴影的交界多时红偏高、蓝偏低），片基没量准也会；画面里有中性的灰时，预设标定更可靠。"
          items.append(RollCheckItem(
            id: "estimate-far", title: "全卷估计和\(reference.name)差得多",
            detail: String(format: "按绿算，红的斜率差 %+.0f%%、蓝差 %+.0f%%。", dr * 100, db * 100) + what
              + (spread.map { max($0.r, $0.b) > Self.spreadAllowed } == true ? spreadWords ?? "" : "")))
        }
      } else if let spread, max(spread.r, spread.b) > Self.spreadAllowed * 1.5, slopeEstimateApplies, estimate != nil {
        items.append(RollCheckItem(
          id: "estimate-spread", title: "各张的斜率估计不一致",
          detail: (spreadWords ?? "") + "整卷取的是中位数，结果可能不稳；画面里有中性的灰时，预设标定更可靠。"))
      }
    }

    // 去串色 not as the calibration was made with.
    if let mismatch = calibrationReadingMismatch {
      items.append(RollCheckItem(id: "unmix", title: "去串色和标定时不一样", detail: mismatch))
    }
    return items
  }

  /// Share of a frame's film clearer than its base past which the base is too dense; darkest
  /// density above the base past which (in two channels) it is too clear; the estimate's distance
  /// from the calibration or data sheet, and the spread of the frames' own, past which it is told.
  static let clearerAllowed = 0.02, darkestAllowed = 0.3, estimateAllowed = 0.12, spreadAllowed = 0.15

  static func median(_ a: [Double]) -> Double {
    let s = a.sorted()
    return s.isEmpty ? 0 : s[s.count / 2]
  }
  /// Half the spread of the middle half, over the median.
  static func spread(_ a: [Double]) -> Double {
    let s = a.sorted()
    guard s.count >= 3, let mid = Optional(median(s)), mid > 0 else { return 0 }
    let q1 = s[Int(Double(s.count - 1) * 0.25)], q3 = s[Int(Double(s.count - 1) * 0.75)]
    return (q3 - q1) / 2 / mid
  }

  /// Where a check's fix is set: the frame, in ② 去色罩, with 取片基.
  func applyCheckFix(_ fix: RollCheckItem.Fix) {
    switch fix {
    case .pickBase(let id):
      if selectedID != id { select(id) }
      if page != .convert { page = .convert }
      if convertStep != .demask { convertStep = .demask }
      if !singleView { singleView = true }
      tool = .base
    }
  }
}

/// The roll's check at the head of ②'s and ③'s inspector: a line while anything looks wrong, opened
/// for what and what to do, each with a key to where it is set right.
struct RollCheckRow: View {
  @Gated var m: AppModel
  @State private var open = false
  var body: some View {
    let items = m.rollCheck
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Button {
          withAnimation(.snappy(duration: 0.2)) { open.toggle() }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(items.count == 1 ? items[0].title : "检查：\(items.count) 处可疑").font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
              .rotationEffect(.degrees(open ? 90 : 0))
          }.contentShape(Rectangle())
        }.buttonStyle(.plain)
          .help("App 替这一卷猜的片基或斜率看起来不对：点开看是什么、怎么改")
        if open {
          ForEach(items) { item in
            VStack(alignment: .leading, spacing: 4) {
              if items.count > 1 { Text(item.title).font(.system(size: 11, weight: .semibold)) }
              Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              if let fix = item.fix {
                switch fix {
                case .pickBase: Button("去取片基") { m.applyCheckFix(fix) }.controlSize(.small)
                }
              }
            }
          }
        }
      }.padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.25), lineWidth: 0.5))
    }
  }
}
