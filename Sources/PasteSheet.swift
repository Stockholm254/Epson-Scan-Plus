import SwiftUI

/// 选择性粘贴 (⌥⇧⌘V), as Lightroom's 拷贝设置 dialog: the copied frame's settings listed one by one
/// with what each is on it, ticked as last time; only those ticked are pasted, as one edit.
struct PasteSheet: View {
  @ObservedObject var m: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var chosen = Set<SettingsGroup>()
  /// The step the sheet was opened in: its settings are the ones listed.
  @State private var scope = SettingsScope.all

  var body: some View {
    let copied = m.copiedSettings
    let a = copied?.adjustments ?? Adjustments()
    let groups = m.pasteGroups(scope)
    let ticked = groups.filter(chosen.contains)
    let targets = m.pasteTargets.count
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("选择性粘贴").font(.system(size: 15, weight: .semibold))
        Spacer()
        Text(copied.map { "从第 \($0.name) 张 · 到" + (m.multiSelected ? "所选的 \(targets) 张" : "这张") } ?? "没有拷贝的调整")
          .font(.system(size: 12)).foregroundStyle(.secondary)
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
      .frame(minHeight: 200, idealHeight: CGFloat(groups.count) * 27 + 60, maxHeight: 480)
      Text(scope == .demasking
        ? "每张自己的方向、去色罩区域和去漏光修复不粘贴；翻拍画面按自己的平场和去串色读出的片基、中性灰取样留着自己的。"
        : "灰色的是拷贝的那张没有改过的，粘贴就是把这一项设回默认。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("只选改过的") { chosen = chosen.subtracting(groups).union(groups.filter { $0.isSet(in: a, plain: plain(a)) }) }
          .help("只勾拷贝的那张和新画面不一样的设置")
        Spacer()
        Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(ticked.isEmpty ? "粘贴" : "粘贴 \(ticked.count) 项") {
          m.pasteChosen = chosen
          m.pasteSettings(scope, only: chosen)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(ticked.isEmpty || copied == nil || m.isWorking)
      }
    }
    .padding(18)
    .frame(width: 460)
    .onAppear {
      scope = m.stepScope
      chosen = m.pasteChosen
    }
  }

  /// One group: ticked or not, its name, and what the copied frame has of it (grey when that is
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

  /// A new frame as the copied one would start: a slide's or a copy shot's own defaults, so they
  /// do not read as changed.
  private func plain(_ a: Adjustments) -> Adjustments {
    var p = Adjustments()
    if a.isSlide { p.setReversal(true) }
    if m.copiedSettings?.sensorRead == true { p.colourNoise = 1 }
    p.inputGamma = a.inputGamma
    p.inputIsNegative = a.inputIsNegative
    return p
  }
}
