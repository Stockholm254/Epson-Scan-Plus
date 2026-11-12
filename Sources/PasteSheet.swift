import SwiftUI

/// One frame's settings listed group by group, with what each is on it, the ones wanted ticked:
/// - 选择性粘贴 (⌥⇧⌘V), as Lightroom's 拷贝设置 dialog: the copied frame's, pasted to the frame
///   shown or those chosen;
/// - 选择性同步, as its 同步设置: the frame shown's, to the frames chosen with it or the roll;
/// - 存为调色预设, as its 新建修改照片预设: the frame shown's grading, kept under a name.
/// Paste and sync tick what was ticked last time; a preset starts with what the frame has changed.
struct PasteSheet: View {
  enum Purpose { case paste, sync, preset }
  @ObservedObject var m: AppModel
  var purpose = Purpose.paste
  @Environment(\.dismiss) private var dismiss
  @State private var chosen = Set<SettingsGroup>()
  /// The step the sheet was opened in: its settings are the ones listed.
  @State private var scope = SettingsScope.all
  @State private var name = ""

  /// The frame whose settings are listed.
  private var source: FilmFrame? { purpose == .paste ? m.copiedSettings : m.selected }
  private var verb: String {
    switch purpose {
    case .paste: return "粘贴"
    case .sync: return "同步"
    case .preset: return "存为预设"
    }
  }

  var body: some View {
    let copied = source
    let a = settings
    let groups = purpose == .preset
      ? AppModel.presetGroups.filter { $0 != .otherGrading || $0.isSet(in: a) }
      : m.pasteGroups(scope, from: a)
    let ticked = groups.filter(chosen.contains)
    let targets = purpose == .sync ? (m.multiSelected ? m.selection.count - 1 : max(0, m.frames.count - 1)) : m.pasteTargets.count
    let named = name.trimmingCharacters(in: .whitespacesAndNewlines)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(purpose == .preset ? "存为调色预设" : "选择性" + verb).font(.system(size: 15, weight: .semibold))
        Spacer()
        Text(copied.map { "从第 \($0.name) 张" + destination(targets) } ?? "没有拷贝的调整")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if purpose == .preset {
        TextField("预设名称", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 13))
        if m.preferences.gradingPresets.contains(where: { $0.name == named }) {
          Text("已经有叫「\(named)」的预设，存的时候会替换它。").font(.system(size: 11)).foregroundStyle(.orange)
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach([SettingsScope.grading, .demasking], id: \.self) { part in
            let rows = groups.filter { $0.scope == part }
            if !rows.isEmpty {
              VStack(alignment: .leading, spacing: 2) {
                HStack {
                  Text(part == .grading ? "③ 调色" : "② 去色罩").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                  Spacer()
                  Button(rows.allSatisfy(chosen.contains) ? "全不选" : "全选") {
                    if rows.allSatisfy(chosen.contains) { chosen.subtract(rows) } else { chosen.formUnion(rows) }
                  }.buttonStyle(.link).font(.system(size: 12))
                }.padding(.bottom, 2)
                ForEach(rows) { g in row(g, a) }
              }
            }
          }
        }.padding(.vertical, 2)
      }
      .frame(minHeight: 120, idealHeight: CGFloat(groups.count) * 25 + 34, maxHeight: 480)
      Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("只选改过的") { chosen = chosen.subtracting(groups).union(groups.filter { $0.isSet(in: a, plain: plain(a)) }) }
          .help("只勾\(purpose == .paste ? "拷贝的那张" : "这张")和新画面不一样的设置")
        Spacer()
        Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(ticked.isEmpty ? verb : "\(verb)（\(ticked.count) 项）") {
          switch purpose {
          case .paste:
            m.pasteChosen = chosen
            m.pasteSettings(scope, only: chosen)
          case .sync:
            m.pasteChosen = chosen
            m.syncSettings(only: chosen)
          case .preset:
            m.saveGradingPreset(named: named, groups: chosen)
          }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(ticked.isEmpty || copied == nil || m.isWorking || (purpose == .preset ? named.isEmpty : targets == 0))
      }
    }
    .padding(18)
    .frame(width: 460)
    .onAppear {
      if purpose == .preset {
        scope = .grading
        let a = settings
        chosen = Set(AppModel.presetGroups.filter { $0.isSet(in: a, plain: plain(a)) })
        name = "调色预设 \(m.preferences.gradingPresets.count + 1)"
      } else {
        scope = m.stepScope
        chosen = m.pasteChosen
      }
    }
  }

  /// The listed frame's settings: a preset's without the grey picked on its own picture.
  private var settings: Adjustments {
    let a = source?.adjustments ?? Adjustments()
    return purpose == .preset ? AppModel.presetGrading(a) : a
  }
  private func destination(_ targets: Int) -> String {
    switch purpose {
    case .paste: return " · 到" + (m.multiSelected ? "所选的 \(targets) 张" : "这张")
    case .sync: return " · 到" + (m.multiSelected ? "所选的另外 \(targets) 张" : "本卷另外 \(targets) 张")
    case .preset: return ""
    }
  }
  private var note: String {
    switch (purpose, scope) {
    case (.preset, _):
      return "预设只记调色，套用时只改勾上的这几项。白平衡里取的中性灰不记（换一张就不是灰了），记成自动加上冷暖、绿 / 洋红；「整卷同一白平衡、色阶」是这一卷的，不记。"
    case (_, .demasking):
      return "每张自己的方向、去色罩区域和去漏光修复不\(verb)；翻拍画面按自己的平场和去串色读出的片基、中性灰取样留着自己的。"
    default:
      return "灰色的是\(purpose == .paste ? "拷贝的那张" : "这张")没有改过的，\(verb)就是把这一项设回默认。"
    }
  }

  /// One group: ticked or not, its name, and what the listed frame has of it (grey when that is
  /// a new frame's).
  private func row(_ g: SettingsGroup, _ a: Adjustments) -> some View {
    let set = g.isSet(in: a, plain: plain(a))
    return Toggle(isOn: Binding(get: { chosen.contains(g) }, set: { on in if on { chosen.insert(g) } else { chosen.remove(g) } })) {
      HStack(spacing: 8) {
        Text(g.name).font(.system(size: 13))
        Spacer(minLength: 12)
        Text(g.summary(of: a)).font(.system(size: 12)).monospacedDigit()
          .foregroundStyle(set ? HierarchicalShapeStyle.primary : .tertiary).lineLimit(1).truncationMode(.middle)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .toggleStyle(.checkbox)
    .padding(.vertical, 3)
  }

  /// A new frame as the listed one would start: a slide's or a copy shot's own defaults, so they
  /// do not read as changed.
  private func plain(_ a: Adjustments) -> Adjustments {
    var p = Adjustments()
    if a.isSlide { p.setReversal(true) }
    if source?.sensorRead == true { p.colourNoise = 1 }
    p.inputGamma = a.inputGamma
    p.inputIsNegative = a.inputIsNegative
    return p
  }
}
