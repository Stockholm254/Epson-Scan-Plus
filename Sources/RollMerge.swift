import AppKit
import SwiftUI

/// Rolls of a kind merged into one (同类卷: scanned with scanned, a camera's with a camera's,
/// imported with imported): a film split over several holder loads or sessions, each of which made
/// a roll of its own before a roll could hold several previews (`RollPreviews.swift`), or the same
/// film scanned again. Each roll taken in has its folder moved whole into the target's `Merged`
/// folder, its project file kept there as it was (the library lists only its roots' folders, so it
/// is no roll of the library any more); its frames, previews, flats, exports and snapshots join the
/// target's, its pictures read where they now are.
extension AppModel {
  /// The rolls `target` can take in: of its kind, not itself; those of its film first, then the
  /// nearest in time.
  static func mergeCandidates(for target: RollEntry, among entries: [RollEntry]) -> [RollEntry] {
    entries.filter { $0.id != target.id && $0.source == target.source }
      .sorted { a, b in
        let (fa, fb) = (a.film == target.film, b.film == target.film)
        if fa != fb { return fa }
        return abs(a.date.timeIntervalSince(target.date)) < abs(b.date.timeIntervalSince(target.date))
      }
  }
  /// Merges the rolls of the projects `sources` into the roll of the project `target`, which is
  /// opened (the roll open saved first): one step, which ⌘Z does not take back, files having moved.
  /// The frames taken in.
  @discardableResult
  func mergeRolls(into target: URL, from sources: [URL]) throws -> Int {
    guard !isWorking else { throw DeskError.message("扫描、翻拍或导出进行时不能合并。") }
    let targetFolder = target.deletingLastPathComponent().standardizedFileURL
    let froms = sources.map(\.standardizedFileURL).filter { $0.deletingLastPathComponent().standardizedFileURL != targetFolder }
    guard !froms.isEmpty else { return 0 }
    saveProject()
    if projectURL?.standardizedFileURL != target.standardizedFileURL { loadProject(target) }
    guard projectURL?.standardizedFileURL == target.standardizedFileURL, let root = sessionURL else {
      throw DeskError.message("打不开要合并进去的那一卷。")
    }
    let files = FileManager.default
    let mergedFolder = root.appendingPathComponent("Merged", isDirectory: true)
    try files.createDirectory(at: mergedFolder, withIntermediateDirectories: true)
    var added = 0
    for project in froms {
      // Read first: one that cannot be read is left where it is.
      let p = try JSONDecoder().decode(DeskProject.self, from: Data(contentsOf: project))
      guard (1...2).contains(p.version) else { throw DeskError.message("「\(project.deletingLastPathComponent().lastPathComponent)」的工程版本不支持。") }
      let old = project.deletingLastPathComponent()
      var dest = mergedFolder.appendingPathComponent(old.lastPathComponent, isDirectory: true)
      var n = 2
      while files.fileExists(atPath: dest.path) {
        dest = mergedFolder.appendingPathComponent("\(old.lastPathComponent)-\(n)", isDirectory: true)
        n += 1
      }
      try files.moveItem(at: old, to: dest)
      /// A path the roll named inside its old folder, inside it where it is now.
      func moved(_ path: String) -> String {
        let o = old.standardizedFileURL.path
        return path.hasPrefix(o + "/") ? dest.path + path.dropFirst(o.count) : path
      }
      // A scanned roll's previews after the target's: the first its overview, then its others.
      var offset = 0
      if p.frames.contains(where: { $0.sourcePath == nil }) {
        if previews.isEmpty, let shown = shownPreview { previews = [shown] }
        offset = previews.count
        let first = ProjectFiles.resolve(moved(p.overviewPath), relative: p.overviewFile, in: dest)
        previews.append(Preview(url: URL(fileURLWithPath: first), dpi: p.overviewDPI,
          mm: CGSize(width: p.physicalWidthMM, height: p.physicalHeightMM), backend: p.scanBackendID, inputGamma: p.overviewInputGamma))
        for r in p.previews ?? [] {
          previews.append(Preview(url: URL(fileURLWithPath: ProjectFiles.resolve(moved(r.path), relative: r.file, in: dest)), dpi: r.dpi,
            mm: CGSize(width: r.widthMM, height: r.heightMM), backend: r.backendID, inputGamma: r.inputGamma))
        }
      }
      // Its flats, those the target has not.
      let known = Set(rollFlats.map(\.id))
      rollFlats += (p.flats ?? []).filter { !known.contains($0.id) }
      // Its frames, read where their files now are, numbered on from the target's.
      for saved in p.frames {
        var f = saved
        f.scanPath = f.scanPath.map { ProjectFiles.resolve(moved($0), relative: f.scanFile, in: dest) }
        f.sourcePath = f.sourcePath.map { ProjectFiles.resolve(moved($0), relative: f.sourceFile, in: dest) }
        (f.scanFile, f.sourceFile) = (nil, nil)
        if let fix = f.adjustments.leakFix {
          let here = moved(fix.file)
          let repairs = dest.appendingPathComponent("Repairs").appendingPathComponent(URL(fileURLWithPath: fix.file).lastPathComponent).path
          f.adjustments.leakFix?.file = files.fileExists(atPath: here) ? here : repairs
        }
        if f.sourcePath == nil {
          let k = offset + (f.preview ?? 0)
          f.preview = k == 0 ? nil : k
        }
        if f.flatID != nil, f.flatID != Self.noFlat, f.flatField == nil { f.flatField = resolvedFlat(f.flatID, crosstalk: f.crosstalk) }
        f.name = Self.frameName(after: frames)
        frames.append(f)
        added += 1
      }
      for (key, stamp) in p.exports ?? [:] { if let id = UUID(uuidString: key) { exportStamps[id] = stamp } }
      for (key, list) in p.snapshots ?? [:] { if let id = UUID(uuidString: key) { gradeSnapshots[id] = list } }
    }
    // Pictures a file each are numbered 01, 02, … in their order; a scan's numbered on.
    if Self.numberedInOrder(frames) { Self.renumber(&frames) }
    clearEdits()
    tablePrint = nil
    updateRollBase()
    updateRollSlopes()
    refresh()
    updateThumbnails()
    saveProject()
    status = "已把 \(froms.count) 卷合并进来：新增 \(added) 张；原来那几卷的文件夹在这一卷的 Merged 文件夹里"
    return added
  }
}

/// 合并进这一卷…: the library's rolls of the target's kind, to tick and merge into it.
struct MergeSheet: View {
  @ObservedObject var m: AppModel
  let target: RollEntry
  let candidates: [RollEntry]
  var merged: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var chosen = Set<String>()
  @State private var failure: String?
  var body: some View {
    let picked = candidates.filter { chosen.contains($0.id) }
    let otherFilms = Set(picked.map(\.film)).subtracting([target.film])
    VStack(alignment: .leading, spacing: 12) {
      Text("合并进「\(target.title)」").font(.system(size: 15, weight: .semibold))
      Text("勾选的卷的画面、预览和原图都并进这一卷：扫描的每次预览在接触表上占一页，一张一个文件的照片接在后面。原来那几卷的文件夹整个搬进这一卷的 Merged 文件夹里，不再单独出现在库里。合并不能用 ⌘Z 撤销。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if candidates.isEmpty {
        Text("库里没有同类的卷（扫描的只能并扫描的，翻拍的并翻拍的，导入的并导入的）。").font(.system(size: 12))
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(candidates) { e in
              Toggle(isOn: Binding(get: { chosen.contains(e.id) }, set: { on in if on { chosen.insert(e.id) } else { chosen.remove(e.id) } })) {
                HStack(spacing: 8) {
                  Text(e.title).font(.system(size: 13)).lineLimit(1)
                  Text(e.film).font(.system(size: 11)).foregroundStyle(e.film == target.film ? HierarchicalShapeStyle.secondary : .primary)
                  Spacer(minLength: 8)
                  Text("\(e.frames.count) 张").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
              }.toggleStyle(.checkbox).padding(.vertical, 2)
            }
          }
        }.frame(minHeight: 80, idealHeight: CGFloat(candidates.count) * 24 + 8, maxHeight: 320)
      }
      if !otherFilms.isEmpty {
        Text("勾选的卷里有别的胶片（\(otherFilms.sorted().joined(separator: "、"))）：合并后都按这一卷的「\(target.film)」转换。")
          .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
      if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(picked.isEmpty ? "合并" : "合并 \(picked.count) 卷") {
          do {
            try m.mergeRolls(into: target.project, from: picked.map(\.project))
            merged()
            dismiss()
          } catch { failure = error.localizedDescription }
        }.keyboardShortcut(.defaultAction).disabled(picked.isEmpty || m.isWorking)
      }
    }.padding(18).frame(width: 460)
  }
}
