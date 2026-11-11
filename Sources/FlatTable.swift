import AppKit
import SwiftUI

/// A flat field as the flats table lists it: the copy light's, one in the library, or one only rolls
/// keep; how many of this roll's frames, and which other rolls, are divided by it.
struct FlatRow: Identifiable, Equatable {
  enum Kind: String { case light = "光源标定", library = "列表", rollOnly = "只在卷里" }
  let id: String
  let profile: FlatProfile?
  let kind: Kind
  /// This roll's frames divided by it, as they are now.
  let here: Int
  /// Other rolls in the library whose frames are divided by it.
  let rolls: [RollEntry]
  var deletable: Bool { kind == .library }
}

/// A frame of the open roll as the flats table lists it.
struct FlatFrameRow: Identifiable, Equatable {
  let id: UUID
  let name: String
  let flat: String
  let flatID: String?
  let blank: Bool
  let linear: Bool
  let size: (width: Int, height: Int)?
  static func == (a: FlatFrameRow, b: FlatFrameRow) -> Bool {
    a.id == b.id && a.name == b.name && a.flat == b.flat && a.flatID == b.flatID && a.blank == b.blank && a.linear == b.linear
      && a.size?.width == b.size?.width && a.size?.height == b.size?.height
  }
}

enum FlatTable {
  /// The flats table: the copy light's flat when there is one, the library's newest first, then the
  /// open roll's and other rolls' own copies of flats no longer in the library.
  static func rows(library: [FlatProfile], open: (folder: URL?, flats: [FlatProfile], frames: [FilmFrame]), light: LightCalibration?, rolls: [RollEntry]) -> [FlatRow] {
    func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    let openPath = open.folder.map(path)
    let others = rolls.filter { openPath != path($0.folder) }
    func here(_ id: String) -> Int { open.frames.filter { $0.flatID == id }.count }
    var rows = [FlatRow]()
    if light != nil {
      rows.append(FlatRow(id: "light", profile: nil, kind: .light, here: open.frames.filter { $0.flatID == nil && $0.flatField != nil }.count, rolls: []))
    }
    for p in library.reversed() {
      rows.append(FlatRow(id: p.id, profile: p, kind: .library, here: here(p.id), rolls: others.filter { $0.flatIDs.contains(p.id) }))
    }
    var known = Set(library.map(\.id))
    for p in open.flats + others.flatMap(\.flats) where !known.contains(p.id) {
      known.insert(p.id)
      rows.append(FlatRow(id: p.id, profile: p, kind: .rollOnly, here: here(p.id), rolls: others.filter { $0.flatIDs.contains(p.id) }))
    }
    return rows
  }
  /// A flat field drawn as its blank frame looks once evened out: white where it is brightest, each
  /// channel darker where it falls off, so a colour fall-off shows as a tint toward the edges.
  static func picture(_ flat: FlatField) -> NSImage? {
    let w = flat.width, h = flat.height
    guard w > 0, h > 0, flat.values.count == w * h * 3 else { return nil }
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<(w * h) {
      for c in 0..<3 { bytes[i * 4 + c] = UInt8(max(0, min(255, (Double(flat.values[i * 3 + c]) * 255).rounded()))) }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let image = CGImage(
        width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent)
    else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: w, height: h))
  }
  static func shares(_ flat: FlatField) -> String {
    let f = flat.falloff
    return String(format: "%.0f%% · %.0f%% · %.0f%%", f.r * 100, f.g * 100, f.b * 100)
  }
}

extension AppModel {
  /// The flats table over `rolls`, the library as last read.
  func flatRows(_ rolls: [RollEntry]) -> [FlatRow] {
    FlatTable.rows(library: preferences.flatProfiles, open: (sessionURL, rollFlats, frames), light: preferences.lightCalibration, rolls: rolls)
  }
  /// The open roll's frames as the flats table lists them, in roll order.
  var flatFrameRows: [FlatFrameRow] {
    let blanks = blankFrameIDs
    return frames.map { f in
      FlatFrameRow(id: f.id, name: f.name, flat: blanks.contains(f.id) ? "空白帧 · " + (rollFlats.first { $0.sourceFrame == f.id }?.name ?? "") : flatName(f),
        flatID: f.flatID, blank: blanks.contains(f.id), linear: isLinearPicture(f), size: pictureSize(f))
    }
  }
}

/// Every flat field, and which of this roll's frames each divides; a group of frames chosen in the
/// lower table (⇧ and ⌘ click) given another flat, or none, at once. Flats in the library can be
/// renamed and deleted; a roll keeps its own copy of each it uses.
struct FlatManagerSheet: View {
  @ObservedObject var m: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var rolls = [RollEntry]()
  @State private var loaded = false
  @State private var flatSelection = Set<String>()
  @State private var frameSelection = Set<UUID>()
  @State private var said: String?
  @State private var renaming: FlatProfile?
  @State private var newName = ""
  @State private var deleting: [FlatRow]?
  /// The flat drawn as surfaces in 3D rather than as its blank.
  @State private var surface = false
  var body: some View {
    let rows = m.flatRows(rolls)
    let chosen = rows.filter { flatSelection.contains($0.id) }
    let single = chosen.count == 1 ? chosen[0] : nil
    let flat = single?.profile
    let frameRows = m.flatFrameRows
    let targets = frameSelection.isEmpty ? frameRows.filter { !$0.blank }.map(\.id) : frameRows.filter { frameSelection.contains($0.id) }.map(\.id)
    let blocked = m.flatsBlocked
    let unused = rows.filter { $0.deletable && $0.here == 0 && $0.rolls.isEmpty }
    let lightBack = m.preferences.lightCalibration != nil && m.frames.contains { targets.contains($0.id) && $0.crosstalk != nil }
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("平场").font(.system(size: 15, weight: .semibold))
        Text(m.frames.isEmpty ? "没有打开的卷" : "这一卷 \(Set(m.frames.compactMap(\.flatID)).count) 种 · \(m.frames.filter { $0.flatID != nil }.count) 张按空白帧补平")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Text(loaded ? "列表 \(m.preferences.flatProfiles.count) 个 · 图库 \(rolls.count) 卷" : "正在读图库…").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      HStack(alignment: .top, spacing: 12) {
        Table(rows, selection: $flatSelection) {
          TableColumn("平场") { r in
            HStack(spacing: 6) {
              Text(r.profile?.name ?? "光源标定").lineLimit(1)
              if r.here > 0 {
                Text("这一卷 \(r.here) 张").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                  .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Hardware.accent))
              }
            }
          }.width(min: 180, ideal: 230)
          TableColumn("类型") { r in Text(r.kind.rawValue).foregroundStyle(r.kind == .rollOnly ? .orange : .primary) }.width(min: 64, ideal: 72)
          TableColumn("最暗处 R · G · B") { r in
            Text(r.profile.map { FlatTable.shares($0.variant(nil)) } ?? m.preferences.lightCalibration.map { FlatTable.shares($0.flat) } ?? "—").monospacedDigit()
              .help("每个通道最暗的一格是最亮处的多少：越低暗角越重；三个差得多，边上就偏色")
          }.width(min: 130, ideal: 140)
          TableColumn("光圈") { r in Text(r.profile?.aperture.map { String(format: "f/%g", $0) } ?? "—").monospacedDigit() }.width(min: 44, ideal: 52)
          TableColumn("来源") { r in
            let text = r.profile?.source ?? m.preferences.lightCalibration.map { "红、绿、蓝灯各一张空白帧 · " + $0.date.formatted(date: .abbreviated, time: .shortened) + " · 只在去串色时" } ?? ""
            Text(text).lineLimit(1).truncationMode(.middle).help(text)
          }.width(min: 160, ideal: 260)
          TableColumn("在用的卷") { r in
            Text(r.kind == .light ? "—" : r.rolls.isEmpty ? (r.here > 0 ? "这一卷" : "—") : "\(r.rolls.count + (r.here > 0 ? 1 : 0)) 卷").monospacedDigit()
              .help(r.rolls.map { "\($0.title) · \($0.source.rawValue)" }.joined(separator: "\n"))
          }.width(min: 64, ideal: 72)
        }
        .frame(minHeight: 170)
        preview(single)
      }
      Table(frameRows, selection: $frameSelection) {
        TableColumn("片号") { f in Text(f.name).monospacedDigit() }.width(min: 40, ideal: 48)
        TableColumn("") { f in
          if let thumb = m.thumbnails[f.id] {
            Image(nsImage: NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))).resizable().aspectRatio(contentMode: .fit)
              .frame(width: 40, height: 26)
          } else {
            Color.clear.frame(width: 40, height: 26)
          }
        }.width(48)
        TableColumn("平场") { f in
          Text(f.flat).lineLimit(1)
            .foregroundStyle(f.blank ? Color.secondary : flat != nil && f.flatID == flat?.id ? Hardware.amberText : Color.primary)
        }.width(min: 160, ideal: 240)
        TableColumn("说明") { f in
          let note = !f.linear ? "不是线性读数（扫描或 JPEG），不补" : f.blank ? "空白帧，不补" : flat.map { p in f.size.map { p.fits(width: $0.width, height: $0.height) } ?? false } == false ? "⚠︎ 尺寸和「\(flat?.name ?? "")」的空白帧不同，不会补" : ""
          Text(note).font(.system(size: 11)).foregroundStyle(note.hasPrefix("⚠︎") ? .orange : .secondary).lineLimit(1)
        }.width(min: 160, ideal: 280)
      }
      .frame(minHeight: 220)
      Text(said ?? (frameSelection.isEmpty ? "下面没有选照片时，按钮作用于整卷（空白帧除外）；按住 Shift 点选一段，Command 点选几张。" : "已选 \(frameSelection.count) 张。"))
        .font(.system(size: 11)).foregroundStyle(said == nil ? .secondary : .primary).frame(maxWidth: .infinity, alignment: .leading)
      HStack {
        Button(flat.map { "把「\($0.name)」用到" + (frameSelection.isEmpty ? "整卷（\(targets.count) 张）" : " \(targets.count) 张") } ?? "用到选中的照片") {
          if let flat { said = m.applyFlat(flat, to: targets) }
        }
        .disabled(flat == nil || targets.isEmpty || blocked != nil)
        .help(blocked ?? (single?.kind == .light ? "光源标定的平场跟着去串色走：用「回到光源标定」" : "上面选一个平场，下面选要补的照片"))
        Button(lightBack ? "回到光源标定" : "不补平场") { said = m.applyFlat(nil, to: targets) }
          .disabled(targets.isEmpty || blocked != nil)
          .help(blocked ?? "选中的照片不再按空白帧补平：去串色开着、做过光源标定的，回到光源标定的平场；其余的不补")
        let one = frameSelection.count == 1 ? m.frames.first { frameSelection.contains($0.id) } : nil
        Button("设成平场") {
          if let one { m.makeFlat(from: one) }
          said = "正在量平场…"
        }
        .disabled(one == nil || one.map { !m.isLinearPicture($0) || m.blankFrameIDs.contains($0.id) } ?? true || blocked != nil)
        .help("下面选一张空白帧（拿走底片，用同样的镜头、光圈、放大倍率和灯拍的），量出新的平场，用到它所在的那一段")
        Spacer()
        Button("改名…") {
          renaming = flat
          newName = flat?.name ?? ""
        }.disabled(flat == nil)
        Button("恢复到列表") { for r in chosen where r.kind == .rollOnly { if let p = r.profile { m.keepFlat(p) } } }
          .disabled(!chosen.contains { $0.kind == .rollOnly })
          .help("把卷里保留的这份平场放回列表，别的卷也能用它")
        Button("清除没有卷在用的…") { deleting = unused }.disabled(!loaded || unused.isEmpty)
        Button("删除…") { deleting = chosen.filter(\.deletable) }.disabled(!chosen.contains(where: \.deletable))
        Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(18)
    .frame(minWidth: 1110, idealWidth: 1150, minHeight: 620)
    .onAppear {
      if let focus = m.flatsFocus { frameSelection = focus }
      m.flatsFocus = nil
      if let only = m.rollFlats.last, flatSelection.isEmpty { flatSelection = [only.id] }
      reload()
    }
    .onChange(of: m.measuringFlat) { _, measuring in if !measuring { said = m.status } }
    .alert("平场改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("名字", text: $newName)
      Button("改名") {
        if let renaming { m.renameFlat(renaming.id, to: newName) }
        renaming = nil
      }
      Button("取消", role: .cancel) { renaming = nil }
    } message: {
      Text("列表和这一卷里的名字一起改；别的卷里保留的那份照旧。")
    }
    .confirmationDialog(deleting.map { "删除 \($0.count) 个平场？" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
      Button("删除", role: .destructive) {
        if let deleting { m.deleteFlats(Set(deleting.map(\.id))) }
        flatSelection.subtract(deleting?.map(\.id) ?? [])
        deleting = nil
      }
      Button("取消", role: .cancel) { deleting = nil }
    } message: {
      Text(deleting.map { rows in
        let used = rows.filter { $0.here > 0 || !$0.rolls.isEmpty }
        return rows.prefix(6).compactMap { $0.profile.map { "「\($0.name)」" } }.joined(separator: "、") + (rows.count > 6 ? " 等" : "") + "将从列表中删除。"
          + (used.isEmpty ? "没有卷在用它们。" : "在用其中 \(used.count) 个的卷各自保留一份，照旧补平，之后也能在这里恢复到列表。")
      } ?? "")
    }
  }
  /// The selected flat drawn as its blank looks evened out, and how far each channel falls off.
  @ViewBuilder func preview(_ row: FlatRow?) -> some View {
    let field = row.flatMap { r in r.profile.map { $0.variant(nil) } ?? (r.kind == .light ? m.preferences.lightCalibration?.flat : nil) }
    VStack(alignment: .leading, spacing: 6) {
      ZStack {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06))
        if let field, surface {
          FlatSurfaceView(flat: field)
        } else if let field, let image = FlatTable.picture(field) {
          Image(nsImage: image).resizable().interpolation(.high).aspectRatio(CGFloat(field.width) / CGFloat(field.height), contentMode: .fit)
        } else {
          Text("选一个平场看它的暗角").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }.frame(width: 220, height: 147)
      // As the evened-out blank looks, or each light's fall-off as a surface to turn.
      Picker("", selection: $surface) {
        Text("平面").tag(false)
        Text("3D").tag(true)
      }.pickerStyle(.segmented).labelsHidden().controlSize(.small).disabled(field == nil)
        .help("3D：红、绿、蓝各一层，高低是这一处的光有多少；三层分开的地方，边上就偏色")
      if let field {
        Text("最暗处 R · G · B：" + FlatTable.shares(field)).font(.system(size: 11)).monospacedDigit()
      }
      if let p = row?.profile {
        Text(p.date.formatted(date: .abbreviated, time: .shortened) + " · \(p.width) × \(p.height)").font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }.frame(width: 220)
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
