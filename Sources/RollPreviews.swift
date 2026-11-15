import AppKit
import SwiftUI

/// A scanned roll's previews: one for every holder load of the roll, kept together as one roll
/// rather than a roll each. The first is the project's own overview; each frame names the one it
/// lies on (`FilmFrame.preview`). The light table shows one at a time, a page each, and that one
/// (`activePreview`) is what `overview`, `overviewURL`, `physicalMM`, `overviewDPI`,
/// `overviewBackendID` and `overviewInputGamma` are, as they were when a roll had one; a frame's
/// own pixels come from its own preview whichever is shown.
extension AppModel {
  /// A preview's file and how it was read.
  struct Preview: Equatable {
    var url: URL
    var dpi: Double
    var mm: CGSize
    var backend: String?
    var inputGamma: Double?
  }
  /// A preview made while a roll with frames was open, not yet kept (`previewDecision`).
  struct PendingPreview {
    let image: CGImage
    /// At most 2200 pixels, as `overview` is.
    let working: CGImage
    let mm: CGSize
    let dpi: Double
    let backend: String?
    let inputGamma: Double?
  }
  /// What the bar under a preview just made asks: of one made over a roll with frames, to add it to
  /// that roll, make a new roll of it, or let it go; of one that began a new roll, to keep it.
  enum PreviewDecision: Equatable { case addOrNew, keepNew }

  /// The preview shown, as the overview's properties have it.
  var shownPreview: Preview? {
    overviewURL.map { Preview(url: $0, dpi: overviewDPI, mm: physicalMM, backend: overviewBackendID, inputGamma: overviewInputGamma) }
  }
  /// How many previews the roll has: none for a roll with no picture yet.
  var previewCount: Int { max(previews.count, overviewURL == nil ? 0 : 1) }
  /// Preview `i` as it is now: the one shown from the overview's properties, the others as kept.
  func preview(_ i: Int) -> Preview? {
    if i == activePreview { return shownPreview }
    return previews.indices.contains(i) ? previews[i] : nil
  }
  /// The preview a frame lies on: a scanned frame's own, the first for any other.
  func previewIndex(of f: FilmFrame) -> Int {
    guard f.sourcePath == nil else { return 0 }
    return min(max(0, f.preview ?? 0), max(0, previewCount - 1))
  }
  /// The file of the preview `f` lies on.
  func previewURL(of f: FilmFrame) -> URL? { preview(previewIndex(of: f))?.url }
  /// Preview `i`'s copy at most 2200 pixels across, read once.
  func workingCopy(_ i: Int) -> CGImage? {
    if i == activePreview { return overview }
    if let kept = previewCopies[i] { return kept }
    guard let p = preview(i), let copy = try? readWorkingCopy(p) else { return nil }
    previewCopies[i] = copy
    return copy
  }
  func readWorkingCopy(_ p: Preview) throws -> CGImage {
    overviewWorkingCopy(try ImagePipeline.shared.load(p.url, maxDimension: 2200), backend: p.backend)
  }
  /// Forgets the roll's previews, for a roll begun without one, or with files of its own.
  func forgetPreviews() {
    previews = []
    previewCopies = [:]
    activePreview = 0
    loadedPreview = nil
    pendingPreview = nil
    previewDecision = nil
  }
  /// Shows preview `i` on the light table: the overview's properties become its, the one shown
  /// before kept as it was.
  func activatePreview(_ i: Int) {
    guard i != activePreview, previews.indices.contains(i) else { return }
    if let shown = shownPreview, previews.indices.contains(activePreview) {
      previews[activePreview] = shown
      if let overview { previewCopies[activePreview] = overview }
    }
    let p = previews[i]
    let copy = previewCopies[i] ?? (try? readWorkingCopy(p))
    activePreview = i
    (overviewURL, overviewDPI, physicalMM, overviewBackendID, overviewInputGamma) = (p.url, p.dpi, p.mm, p.backend, p.inputGamma)
    overview = copy
    previewCopies[i] = copy
    tablePrint = nil
  }
  /// The preview shown follows what is shown: the light table's page, or the frame open alone.
  func followPreview() {
    guard previews.count > 1, pendingPreview == nil else { return }
    if singleView, let f = selected, f.sourcePath == nil {
      activatePreview(previewIndex(of: f))
    } else if !singleView, case .holder(let k) = shownContactPage {
      activatePreview(k)
    }
  }
  /// The previews a project keeps after its first, named as its other files are.
  func savedPreviews(in root: URL) -> [RollPreview]? {
    guard previewCount > 1 else { return nil }
    return (1..<previewCount).compactMap { i in
      preview(i).map { p in
        RollPreview(path: p.url.path, file: ProjectFiles.relative(p.url.path, to: root), dpi: p.dpi, widthMM: p.mm.width,
          heightMM: p.mm.height, backendID: p.backend, inputGamma: p.inputGamma)
      }
    }
  }
  /// A preview can be added to the roll open: one of a holder, with frames on it.
  var canAddPreview: Bool { sessionURL != nil && overviewURL != nil && frames.contains { $0.sourcePath == nil } }

  /// 加到这一卷: the preview kept with the roll open as its next holder load, shown on a page of
  /// its own, its frames found on it and numbered on from the roll's.
  func addPendingPreview() {
    guard let p = pendingPreview, let root = sessionURL, !isWorking else { return }
    do {
      let k = max(1, previewCount)
      var url = root.appendingPathComponent("overview-\(k + 1).tif")
      var n = k + 1
      while FileManager.default.fileExists(atPath: url.path) {
        n += 1
        url = root.appendingPathComponent("overview-\(n).tif")
      }
      try ImagePipeline.shared.saveTIFF(p.image, to: url, dpi: Int(p.dpi))
      overviewCache.keep(p.image, for: url)
      if previews.isEmpty, let shown = shownPreview { previews = [shown] }
      previews.append(Preview(url: url, dpi: p.dpi, mm: p.mm, backend: p.backend, inputGamma: p.inputGamma))
      previewCopies[previews.count - 1] = p.working
      pendingPreview = nil
      previewDecision = nil
      activatePreview(previews.count - 1)
      loadedPreview = activePreview
      singleView = false
      showNegative = false
      sourceSummary = "透扫预览 · \(Int(p.dpi)) dpi · 第 \(activePreview + 1) 次"
      contactPage = contactPages.firstIndex(of: .holder(activePreview)) ?? contactPage
      detectFrames()
    } catch { errorText = error.localizedDescription }
  }
  /// 存成新的一卷: the preview a roll of its own, as a preview always was before; the roll open
  /// stays in the library.
  func pendingAsNewRoll() {
    guard let p = pendingPreview, !isWorking else { return }
    pendingPreview = nil
    previewDecision = nil
    saveProject()
    beginRoll(with: p.image, size: p.mm, dpi: p.dpi)
  }
  /// 不保留: the preview let go, the roll open as it was.
  func discardPendingPreview() {
    guard pendingPreview != nil else { return }
    pendingPreview = nil
    previewDecision = nil
    status = "这次预览没有保留"
    refresh()
  }
  /// 保留 the new roll a preview began: the bar goes.
  func keepNewRoll() {
    previewDecision = nil
    status = "预览存进库里的新一卷"
  }
  /// 不保留 the new roll a preview began: put away (`discardRollFolder`, the Trash), the window an
  /// empty new project again.
  func discardNewRoll() {
    guard previewDecision == .keepNew, let root = sessionURL, !isWorking else { return }
    previewDecision = nil
    newProject()
    discardRollFolder(root)
    status = "这次预览没有保留：那一卷移到了废纸篓"
  }

  /// Scanning frames of a roll of several previews: only those on the holder on the scanner (the
  /// last preview made, else the roll's last) can be; of others the user is asked whether that
  /// holder has been put back. The ids to scan, nil to scan none.
  func scannableOnHolder(_ ids: [UUID]) -> [UUID]? {
    guard previewCount > 1 else { return ids }
    let targets = ids.compactMap { id in frames.first { $0.id == id } }
    let loaded = loadedPreview ?? previewCount - 1
    let off = targets.filter { previewIndex(of: $0) != loaded }
    guard !off.isEmpty else { return ids }
    let others = Set(off.map { previewIndex(of: $0) }).sorted()
    switch askPutBack(off.count, others, loaded, targets.count - off.count) {
    case .onScanner:
      let on = targets.filter { previewIndex(of: $0) == loaded }.map(\.id)
      return on.isEmpty ? nil : on
    case .putBack:
      guard others.count == 1 else { return nil }
      loadedPreview = others[0]
      return ids.filter { id in frames.first { $0.id == id }.map { previewIndex(of: $0) == others[0] } ?? false }
    case .cancel:
      return nil
    }
  }
  enum PutBackChoice { case onScanner, putBack, cancel }
}

/// Under the light table after a preview: over a roll with frames, whether to add the preview to it
/// as its next holder load, make a new roll of it, or let it go; of a new roll the preview began,
/// whether to keep it. It stays until answered, or until frames are scanned or a roll is opened.
struct PreviewDecisionBar: View {
  @ObservedObject var m: AppModel
  let decision: AppModel.PreviewDecision
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "rectangle.stack.badge.plus").foregroundStyle(Hardware.accent)
      switch decision {
      case .addOrNew:
        Text("这次预览").font(.system(size: 12, weight: .semibold))
        Text("加到这一卷就是它的第 \(max(2, m.previewCount + 1)) 次预览，接触表上另起一页，新识别的画面接着编号")
          .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 8)
        Button("不保留") { m.discardPendingPreview() }
          .help("这次预览不要了，回到这一卷原来的样子")
        Button("存成新的一卷") { m.pendingAsNewRoll() }
          .help("像以前一样，把这次预览存成库里新的一卷；现在这一卷留在库里")
        Button("加到这一卷") { m.addPendingPreview() }
          .buttonStyle(.borderedProminent).tint(Hardware.accent)
          .help("这次预览和它识别出的画面加进现在这一卷：同一卷胶片分几次放进片夹时用")
      case .keepNew:
        Text("预览存成了新的一卷").font(.system(size: 12, weight: .semibold))
        Text("不保留就把这一卷移到废纸篓").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 8)
        Button("不保留") { m.discardNewRoll() }
          .help("这次预览不要了：这一卷移到废纸篓，回到空的新工程")
        Button("保留") { m.keepNewRoll() }
          .buttonStyle(.borderedProminent).tint(Hardware.accent)
      }
    }
    .controlSize(.small)
    .disabled(m.isWorking)
    .padding(.horizontal, 18).padding(.vertical, 7)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(decision == .addOrNew ? "这次预览：加到这一卷、存成新的一卷或不保留" : "预览存成了新的一卷：保留或不保留")
  }
}
