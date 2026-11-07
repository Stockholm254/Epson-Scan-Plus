import AppKit
import SwiftUI

/// A preset as the presets table lists it: what kind it is, and which rolls convert with it.
struct PresetRow: Identifiable, Equatable {
  enum Kind: String { case builtin = "内置", scanner = "V850 标定", copy = "翻拍标定", imported = "导入", rollOnly = "只在卷里" }
  let profile: FilmProfile
  let kind: Kind
  /// The rolls in the library that convert with it, newest first; the roll open as it is now.
  let rolls: [RollEntry]
  /// The roll open converts with it.
  let current: Bool
  var id: String { profile.id }
  /// Only presets made or imported here leave the list; a roll's own copy stays with the roll.
  var deletable: Bool { kind != .builtin && kind != .rollOnly }
}

enum PresetTable {
  /// How many neutral points a calibrated preset was made from: those it keeps, else what its
  /// source line says (presets from before it kept them); nil for any other preset.
  static func pointCount(_ p: FilmProfile) -> Int? {
    guard p.offsets != nil else { return nil }
    if let spots = p.spots, !spots.isEmpty { return spots.count }
    guard let r = p.publication.range(of: "[0-9]+ 个中性点", options: .regularExpression) else { return nil }
    return Int(p.publication[r].prefix { $0.isNumber })
  }
  /// A calibrated preset's points, a line each: the frame, the densities above the base and how far
  /// each lies off the preset's line, or only where it was for a preset that kept no reading.
  static func pointLines(_ p: FilmProfile) -> [String] {
    guard let offsets = p.offsets, let spots = p.spots else { return [] }
    return spots.enumerated().map { i, s in
      guard let value = s.value, let base = s.base else { return "\(i + 1) · 第 \(s.name) 张 · 只记了位置" }
      let point = NeutralPoint(frame: s.frame, value: value, base: base, gamma: s.gamma ?? 1)
      let d = point.density, off = point.misfit(slopes: p.slopes, offsets: offsets, toe: p.toe)
      return String(format: "%d · 第 %@ 张 · 密度 R %.3f  G %.3f  B %.3f · 偏离 R %+.3f  B %+.3f D", i + 1, s.name, d[0], d[1], d[2], off[0], off[1])
    }
  }
  static func kind(_ p: FilmProfile, builtin: Bool) -> PresetRow.Kind {
    if builtin { return .builtin }
    if p.id.contains("-copy-") { return .copy }
    if p.id.contains("-v850-") { return .scanner }
    return .imported
  }
  /// Every preset in the list, then each one only rolls keep a copy of (deleted from the list, or
  /// made on another computer), with the rolls converting with it. `open` is the roll open and
  /// the preset it converts with now, which its saved project may not show yet.
  static func rows(builtins: [FilmProfile], custom: [FilmProfile], rolls: [RollEntry], open: (folder: URL?, profile: FilmProfile)?) -> [PresetRow] {
    func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    let openPath = open?.folder.map(path)
    let using = rolls.map { r in (roll: r, profile: openPath == path(r.folder) ? open!.profile : r.profile) }
    let listed = builtins.map { (profile: $0, builtin: true) } + custom.map { (profile: $0, builtin: false) }
    var rows = listed.map { p in
      PresetRow(profile: p.profile, kind: kind(p.profile, builtin: p.builtin),
        rolls: using.filter { $0.profile.id == p.profile.id }.map(\.roll), current: open?.profile.id == p.profile.id)
    }
    var known = Set(listed.map(\.profile.id))
    // Those only in rolls, each as the newest roll using it keeps it.
    for u in using where !known.contains(u.profile.id) {
      known.insert(u.profile.id)
      rows.append(PresetRow(profile: u.profile, kind: .rollOnly, rolls: using.filter { $0.profile.id == u.profile.id }.map(\.roll),
        current: open?.profile.id == u.profile.id))
    }
    if let open, !known.contains(open.profile.id) {
      rows.append(PresetRow(profile: open.profile, kind: .rollOnly, rolls: [], current: true))
    }
    return rows
  }
}

extension AppModel {
  /// The presets table over `rolls`, the library as last read.
  func presetRows(_ rolls: [RollEntry]) -> [PresetRow] {
    PresetTable.rows(builtins: FilmProfile.builtins, custom: preferences.customProfiles, rolls: rolls,
      open: frames.isEmpty && sessionURL == nil ? nil : (sessionURL, profile))
  }
  func deleteCustomProfiles(_ ids: Set<String>) {
    preferences.customProfiles.removeAll { ids.contains($0.id) }
    profiles = FilmProfile.builtins + preferences.customProfiles
  }
}

/// Every preset, which rolls convert with each, and the one this roll uses; presets made or
/// imported here can be deleted, one at a time or all those no roll uses, and a roll's own copy of
/// one deleted put back in the list.
struct PresetManagerSheet: View {
  @ObservedObject var m: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var rolls = [RollEntry]()
  @State private var loaded = false
  @State private var selection = Set<String>()
  @State private var deleting: [PresetRow]?
  var body: some View {
    let rows = m.presetRows(rolls)
    let chosen = rows.filter { selection.contains($0.id) }
    let single = chosen.count == 1 ? chosen[0] : nil
    let unused = rows.filter { $0.deletable && $0.rolls.isEmpty && !$0.current }
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("预设").font(.system(size: 15, weight: .semibold))
        Text(m.frames.isEmpty && m.sessionURL == nil ? "没有打开的卷" : "这一卷在用「\(m.profile.name)」")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Text(loaded ? "图库 \(rolls.count) 卷" : "正在读图库…").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Table(rows, selection: $selection) {
        TableColumn("预设") { r in
          HStack(spacing: 6) {
            Text(r.profile.name).lineLimit(1)
            if r.current {
              Text("这一卷").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Hardware.accent))
            }
          }
        }.width(min: 200, ideal: 260)
        TableColumn("类型") { r in Text(r.kind.rawValue).foregroundStyle(r.kind == .rollOnly ? .orange : .primary) }.width(min: 76, ideal: 84)
        TableColumn("斜率 R · G · B") { r in
          Text(String(format: "%.3f · %.3f · %.3f", r.profile.slopes.r, r.profile.slopes.g, r.profile.slopes.b)).monospacedDigit()
        }.width(min: 150, ideal: 160)
        TableColumn("中性点") { r in
          Text(PresetTable.pointCount(r.profile).map { "\($0) 个" } ?? "—").monospacedDigit()
            .help(r.profile.offsets == nil ? "不是标定出来的预设" : "标定用的中性点；选中这一行在下面看每个点")
        }.width(min: 56, ideal: 64)
        TableColumn("来源") { r in Text(r.profile.publication).lineLimit(1).truncationMode(.middle).help(r.profile.publication + "\n\n" + r.profile.notes) }
          .width(min: 160, ideal: 300)
        TableColumn("在用的卷") { r in
          Text(r.rolls.isEmpty ? (r.current ? "这一卷" : "—") : "\(r.rolls.count) 卷").monospacedDigit()
            .help(r.rolls.map { "\($0.title) · \($0.source.rawValue)" }.joined(separator: "\n"))
        }.width(min: 72, ideal: 80)
      }
      .frame(minHeight: 260)
      detail(single)
      HStack {
        Button("用到这一卷") { single.map { m.chooseProfile($0.profile) } }
          .disabled(single == nil || single?.current == true || (m.frames.isEmpty && m.sessionURL == nil))
        let blocked: String? = !m.calibrationPoints.isEmpty ? "左栏的预设标定里正在取 \(m.calibrationPoints.count) 个点：先生成预设或清除。"
          : single.map { m.whyNotTakenUp($0.profile) } ?? "选一个本机或翻拍标定的预设。"
        Button("接着标定") {
          if let single { m.takeUpCalibration(single.profile) }
          dismiss()
        }
        .disabled(blocked != nil)
        .help(blocked ?? "这一卷用它，把它的中性点取回到左栏的预设标定里，接着加点；重新生成就替换它")
        Button("导出…") { single.map { m.exportProfile($0.profile) } }.disabled(single == nil)
        Button("恢复到列表") { for r in chosen where r.kind == .rollOnly { m.keepProfile(r.profile) } }
          .disabled(!chosen.contains { $0.kind == .rollOnly })
          .help("把卷里保留的这份预设放回列表，别的卷也能选它")
        Button("导入 JSON…") { m.importProfile() }
        Spacer()
        Button("清除没有卷在用的…") { deleting = unused }.disabled(!loaded || unused.isEmpty)
          .help("删除本机标定或导入、图库里没有卷在用、这一卷也没在用的预设")
        Button("删除…") { deleting = chosen.filter(\.deletable) }.disabled(!chosen.contains(where: \.deletable))
        Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(18)
    .frame(minWidth: 1110, idealWidth: 1150, minHeight: 520)
    .onAppear {
      if let focus = m.presetsFocus { selection = [focus] }
      m.presetsFocus = nil
      reload()
    }
    .confirmationDialog(deleting.map { "删除 \($0.count) 个预设？" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
      Button("删除", role: .destructive) {
        if let deleting { m.deleteCustomProfiles(Set(deleting.map(\.id))) }
        selection.subtract(deleting?.map(\.id) ?? [])
        deleting = nil
      }
      Button("取消", role: .cancel) { deleting = nil }
    } message: {
      Text(deleting.map(Self.consequence) ?? "")
    }
  }
  /// What deleting `rows` does to the rolls using them.
  static func consequence(_ rows: [PresetRow]) -> String {
    let used = rows.filter { !$0.rolls.isEmpty || $0.current }
    let names = rows.prefix(6).map { "「\($0.profile.name)」" }.joined(separator: "、") + (rows.count > 6 ? " 等" : "")
    return names + "将从列表中删除。"
      + (used.isEmpty
        ? "没有卷在用它们，删除后就没有了；需要的话先导出。"
        : "在用其中 \(used.count) 个的卷各自保留一份，照旧能打开和转换，之后也能在这里恢复到列表。")
  }
  @ViewBuilder func detail(_ row: PresetRow?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let row {
        Text(row.profile.notes).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        let points = PresetTable.pointLines(row.profile)
        if !points.isEmpty {
          Text("中性点").font(.system(size: 11, weight: .medium)).padding(.top, 2)
          ForEach(Array(points.prefix(12).enumerated()), id: \.offset) { _, line in
            Text(line).font(.system(size: 11)).monospacedDigit().textSelection(.enabled)
          }
          if points.count > 12 { Text("等 \(points.count) 个").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        if row.rolls.isEmpty {
          Text(row.current ? "只有这一卷在用（还没存进图库）。" : "图库里没有卷在用它。").font(.system(size: 11))
        } else {
          Text("在用的卷：" + row.rolls.prefix(8).map { "\($0.title)（\($0.source.rawValue)）" }.joined(separator: "、")
            + (row.rolls.count > 8 ? " 等 \(row.rolls.count) 卷" : "")).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text("选一行看它的说明、标定用的中性点和在用的卷；⌘ 点选可以多选。标定出来的预设可以「接着标定」：把中性点取回到左栏的预设标定里，加点后重新生成。内置预设不能删除；删除本机预设时，在用它的卷各自保留一份。")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
  }
  func reload() {
    let roots = m.libraryRoots
    loaded = false
    DispatchQueue.global(qos: .userInitiated).async {
      let found = RollLibrary.scan(roots)
      DispatchQueue.main.async {
        rolls = found
        loaded = true
      }
    }
  }
}
