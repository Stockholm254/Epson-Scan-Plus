import AppKit
import Foundation

/// One photograph's light-leak repair: where its original comes from, the base it is fitted on,
/// the reference and how it was made, and the parameters. FilmLightLab's job keys where they
/// overlap. Kept in the app's support folder, never in a photo library.
struct LeakJob: Codable, Identifiable {
  /// A frame of a roll in this app: its conversion as it was when the job began, so an export
  /// converts the frame the same way the base was.
  struct Origin: Codable {
    var project: String
    var frame: UUID
    var frameName: String
    var adjustments: Adjustments
    var profile: FilmProfile
  }
  struct Generated: Codable, Equatable {
    struct Usage: Codable, Equatable { var total_tokens: Int?, input_tokens: Int?, output_tokens: Int? }
    struct Uploaded: Codable, Equatable { var width: Int, height: Int, bytes: Int }
    struct Geometry: Codable, Equatable { var rotation: Int, crop: LeakCrop }
    var provider: String
    var model: String
    var quality: String
    var promptVersion: String
    var promptScene: String
    var size: String
    var requestId: String?
    var usage: Usage?
    var generatedAt: String
    var uploaded: Uploaded?
    var endpoint: String?
    var sourceBase: String?
    var sourceGeometry: Geometry?
  }
  struct Meta: Codable, Equatable { var width: Int, height: Int, previewWidth: Int, previewHeight: Int }
  var id: String
  var sourceName: String
  /// An imported original, copied into the job's folder.
  var source: String?
  var origin: Origin?
  var base: String?
  var guide: String?
  var guideName: String?
  var generatedAI: Generated?
  var params = LeakParams()
  var meta: Meta?
  var modified: Date?
  /// Matching points on the original and the reference, for a manual alignment.
  var pairs: [LeakPair]?
}

/// The 去漏光 page. One photograph at a time: a frame of the open roll or an imported positive,
/// shown before and after, repaired against a reference that is generated once (the only step
/// that calls the API) and refitted for free after every change of scene or orientation.
final class LeakLab: ObservableObject {
  @Published private(set) var job: LeakJob?
  @Published private(set) var params = LeakParams()
  @Published private(set) var before: CGImage?
  @Published private(set) var after: CGImage?
  @Published private(set) var reference: CGImage?
  /// How much of the picture, from the left, shows the original.
  @Published var wipe = 0.0
  @Published var holdOriginal = false
  @Published var showReference = false
  /// What is being done, while it is.
  @Published private(set) var busy: String?
  @Published private(set) var updating = false
  @Published var notice = "在下方胶片条选一张，或导入已去色罩、反相的正片。"
  @Published var errorText: String?
  @Published var showAPI = false
  @Published var showGenerate = false
  /// What an assistant asked the reference to be made with, filled into the confirmation it opens.
  var requestedQuality: String?
  var requestedNote: String?
  let credentials: LeakCredentials
  /// Where the jobs are kept, one folder each.
  let root: URL
  weak var undoManager: UndoManager?
  /// A roll frame's positive at full resolution, from the app, as the origin converts it.
  var renderFrame: ((LeakJob.Origin) throws -> CGImage)?
  private let preferences: Preferences?
  private var base: LeakImage?
  /// The reference, 640 px across, as the fit reads it.
  private var guide: LeakImage?
  private let queue = DispatchQueue(label: "epscan.leak", qos: .userInitiated)
  private var generation = 0
  private var pending: DispatchWorkItem?
  private var persisted = false

  static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("epscan").appendingPathComponent("LightLeak")
  }
  init(root: URL = LeakLab.defaultRoot, credentials: LeakCredentials = LeakCredentials(), preferences: Preferences? = nil) {
    self.root = root
    self.credentials = credentials
    self.preferences = preferences
  }

  var folder: URL? { job.map { root.appendingPathComponent($0.id) } }
  var hasBase: Bool { base != nil }
  var hasReference: Bool { job?.guide != nil }
  var model: LeakModel? { params.referenceModel }
  /// The reference is applied, to this base.
  var repaired: Bool { model.map { $0.strength > 0 && ($0.sourceBase == nil || $0.sourceBase == job?.base) } ?? false }

  // MARK: Opening

  struct Listing: Identifiable { var id: String, name: String, hasReference: Bool, modified: Date, frame: Bool }
  /// Jobs kept so far, the most recent first.
  func jobs() -> [Listing] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.compactMap { name -> Listing? in
      let url = root.appendingPathComponent(name).appendingPathComponent("job.json")
      guard let data = try? Data(contentsOf: url), let j = try? JSONDecoder().decode(LeakJob.self, from: data), j.base != nil else { return nil }
      return Listing(id: j.id, name: j.origin.map { "第 \($0.frameName) 张 · " + URL(fileURLWithPath: $0.project).deletingLastPathComponent().lastPathComponent } ?? j.sourceName,
        hasReference: j.guide != nil, modified: j.modified ?? .distantPast, frame: j.origin != nil)
    }.sorted { $0.modified > $1.modified }
  }
  /// The job for a frame of a roll, if one was kept.
  func existing(project: String, frame: UUID) -> String? {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.first { name in
      let url = root.appendingPathComponent(name).appendingPathComponent("job.json")
      guard let data = try? Data(contentsOf: url), let j = try? JSONDecoder().decode(LeakJob.self, from: data) else { return false }
      return j.origin?.project == project && j.origin?.frame == frame && j.base != nil
    }
  }
  func open(_ id: String) {
    guard busy == nil else { return }
    let folder = root.appendingPathComponent(id)
    run("读取任务") {
      let j = try JSONDecoder().decode(LeakJob.self, from: Data(contentsOf: folder.appendingPathComponent("job.json")))
      guard let name = j.base else { throw DeskError.message("这个任务没有正片预览。") }
      let base = try LeakImage(contentsOf: folder.appendingPathComponent(name))
      let guide = try j.guide.map { try self.loadGuide(folder.appendingPathComponent($0)) }
      return { self.show(j, base: base, guide: guide, persisted: true) }
    }
  }
  /// A frame of the open roll: its job if there is one, else a new one, kept once it is worked on.
  func open(origin: LeakJob.Origin) {
    guard busy == nil else { notice = "正在处理，请稍候。"; return }
    if job?.origin?.frame == origin.frame && job?.origin?.project == origin.project { return }
    if let id = existing(project: origin.project, frame: origin.frame) {
      open(id)
      return
    }
    guard let renderFrame else { return }
    run("读取正片") {
      let full = try LeakImage(renderFrame(origin))
      var j = LeakJob(id: UUID().uuidString.lowercased(), sourceName: "第 \(origin.frameName) 张", origin: origin)
      let base = Self.base(full, j.params)
      j.base = "base-\(Self.stamp()).tif"
      j.meta = .init(width: full.width, height: full.height, previewWidth: base.width, previewHeight: base.height)
      return { self.show(j, base: base, guide: nil, persisted: false) }
    }
  }
  /// An inverted positive from a file, copied into a new job; the file itself is not changed.
  func importFile(_ url: URL) {
    guard busy == nil else { return }
    run("复制并读取正片") {
      let ext = url.pathExtension.lowercased()
      guard ["tif", "tiff", "png", "jpg", "jpeg", "webp"].contains(ext) else {
        throw DeskError.message("请导入已经反相的正片 TIFF、PNG 或 JPEG；推荐带 ICC 的 16 位 TIFF。")
      }
      var j = LeakJob(id: UUID().uuidString.lowercased(), sourceName: url.lastPathComponent)
      let folder = self.root.appendingPathComponent(j.id)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let copy = "source-\(Self.stamp()).\(ext)"
      try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(copy))
      j.source = copy
      let full = try LeakImage(contentsOf: folder.appendingPathComponent(copy))
      let base = Self.base(full, j.params)
      j.base = "base-\(Self.stamp()).tif"
      j.meta = .init(width: full.width, height: full.height, previewWidth: base.width, previewHeight: base.height)
      try base.saveTIFF(to: folder.appendingPathComponent(j.base!))
      j.modified = Date()
      try Self.write(j, to: folder)
      return { self.show(j, base: base, guide: nil, persisted: true) }
    }
  }
  func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.tiff, .png, .jpeg]
    panel.message = "选择已去色罩、反相的正片。推荐带 ICC 的全分辨率 16 位 TIFF；原文件不改动。"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    importFile(url)
  }
  /// Opens the job used last, once, when the page is first shown.
  func restoreLast() {
    guard job == nil, let id = preferences?.leakJob,
      FileManager.default.fileExists(atPath: root.appendingPathComponent(id).appendingPathComponent("job.json").path)
    else { return }
    open(id)
  }
  private func show(_ j: LeakJob, base: LeakImage, guide: LeakImage?, persisted: Bool) {
    save()
    job = j
    params = j.params
    self.base = base
    self.guide = guide
    self.persisted = persisted
    before = base.cgImage()
    after = nil
    selectedRegion = nil
    tool = .inspect
    reference = j.guide.flatMap { try? ImagePipeline.shared.load(root.appendingPathComponent(j.id).appendingPathComponent($0), maxDimension: 1800) }
    showReference = false
    wipe = repaired ? 0.5 : 0
    undoManager?.removeAllActions(withTarget: self)
    if persisted { preferences?.leakJob = j.id }
    notice = repaired ? "已应用去漏光。拖动对比滑杆检查效果。"
      : j.guide != nil ? "已有参考图，点击「开始去漏光」在本地免费修复。" : "确认照片方向后，点击「开始去漏光」。"
    preview()
  }
  static func base(_ full: LeakImage, _ params: LeakParams) -> LeakImage {
    LeakEngine.resized(LeakEngine.cropped(full, rotation: params.rotation, crop: params.crop), width: 1800)
  }
  static func stamp() -> String { String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<1296), radix: 36) }
  private func loadGuide(_ url: URL) throws -> LeakImage {
    LeakEngine.resized(try LeakImage(contentsOf: url), width: 640)
  }

  // MARK: Saving

  private static func write(_ j: LeakJob, to folder: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(j).write(to: folder.appendingPathComponent("job.json"), options: .atomic)
  }
  /// The job's folder, with its base, written once there is something to keep.
  private func persist() throws {
    guard var j = job, let base, let folder else { return }
    if !persisted {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try base.saveTIFF(to: folder.appendingPathComponent(j.base!))
      persisted = true
      preferences?.leakJob = j.id
    }
    j.params = params
    j.modified = Date()
    try Self.write(j, to: folder)
    job = j
  }
  func save() {
    guard persisted else { return }
    try? persist()
  }

  // MARK: Changes

  /// A change of parameters, undoable; `refit` fits the reference again (free, local) after it.
  /// Changes with the same `step` within a second are one undo step (a fader dragged, a region
  /// moved); nil keeps each change a step of its own.
  func change(_ name: String, refit: Bool = false, step: String? = nil, _ edit: (inout LeakParams) -> Void) {
    // A fit, a generation or a turn under way puts its own parameters back when it ends: a change
    // now would be lost then, so none is taken.
    guard busy == nil else {
      notice = "正在处理，请稍候再调整。"
      return
    }
    var next = params
    edit(&next)
    guard next != params else { return }
    set(next, name: name, step: step)
    if refit && hasReference { fit() } else { save(); preview(soon: true) }
  }
  private var lastChange: (step: String, at: Date)?
  private func set(_ next: LeakParams, name: String, step: String?) {
    let old = params
    params = next
    guard let undoManager else { return }
    let replaying = undoManager.isUndoing || undoManager.isRedoing
    if replaying {
      lastChange = nil
    } else {
      let now = Date()
      defer { lastChange = step.map { ($0, now) } }
      // Repeats of one control within a second, a fader being dragged, are one step.
      if let step, let lastChange, lastChange.step == step, now.timeIntervalSince(lastChange.at) < 1, undoManager.canUndo { return }
    }
    // Without event grouping (tests, an assistant over MCP) each change is a group of its own.
    let grouping = !undoManager.groupsByEvent && !replaying
    if grouping { undoManager.beginUndoGrouping() }
    undoManager.registerUndo(withTarget: self) { lab in
      // A fit or a generation under way adds its model to the undone parameters when it ends; a
      // base being rebuilt would replace them, so not while it is.
      guard !lab.rebuilding else {
        lab.notice = "正在重建正片预览，这一步撤销没有生效，请稍候再试。"
        return
      }
      lab.set(old, name: name, step: step)
      lab.save()
      lab.preview()
    }
    undoManager.setActionName(name)
    if grouping { undoManager.endUndoGrouping() }
  }
  func setScene(_ mode: String) {
    change("场景", refit: true, step: "场景") {
      $0.sceneMode = mode
      $0.sceneInfo = nil
      $0.referenceModel = nil
    }
    if !hasReference { notice = "场景已切换。点击「开始去漏光」应用；不会因此调用 API。" }
  }
  func setStrength(_ value: Double) {
    guard params.referenceModel != nil else { return }
    change("去偏色强度", step: "去偏色强度") { $0.referenceModel?.strength = value }
  }
  func clearReferenceCorrection() {
    change("停用参考校正") { $0.referenceModel = nil }
    notice = "参考校正已停用。点击「开始去漏光」可重新应用，不调用 API。"
  }
  /// A quarter turn: a new base, and the reference matched to it again.
  func rotate(by delta: Int) {
    guard let j = job, busy == nil else { return }
    var next = params
    next.rotation = ((next.rotation + delta) % 360 + 360) % 360
    next.crop = LeakCrop()
    next.regions = []
    next.protect = []
    next.referenceModel = nil
    rebuild(j, next)
  }
  /// The frame converted as it is now, for a job begun before its conversion changed.
  func reload(origin: LeakJob.Origin) {
    guard var j = job, j.origin?.frame == origin.frame, busy == nil else { return }
    j.origin = origin
    var next = params
    next.referenceModel = nil
    // The framing is the same, so the landmarks still match.
    rebuild(j, next, pairs: j.pairs, name: "按当前调色重新载入")
  }
  private static let rebuildLabel = "重建正片预览"
  private var rebuilding: Bool { busy == Self.rebuildLabel }
  private func rebuild(_ j: LeakJob, _ next: LeakParams, pairs: [LeakPair]? = nil, name: String = "旋转 / 裁切", notice told: String? = nil) {
    run(Self.rebuildLabel) {
      let full = try self.original(j)
      let base = Self.base(full, next)
      var j = j
      // Landmarks on the old base no longer match.
      j.pairs = pairs
      j.base = "base-\(Self.stamp()).tif"
      j.meta = .init(width: full.width, height: full.height, previewWidth: base.width, previewHeight: base.height)
      // Written before the job names it: a job never points at a base that is not there.
      if let folder = self.onMain({ self.persisted ? self.folder : nil }) {
        try base.saveTIFF(to: folder.appendingPathComponent(j.base!))
      }
      return {
        self.place(j, base: base, params: next, name: name)
        if !self.hasReference { self.notice = told ?? "方向 / 裁切已更新。点击「开始去漏光」。" }
      }
    }
  }
  /// A base put in place with its job and parameters, as one undo step whose undo puts the one
  /// before back as it was, fitted or not, without rebuilding anything.
  private func place(_ j: LeakJob, base: LeakImage, params next: LeakParams, name: String) {
    if let undoManager, let oldJob = job, let oldBase = self.base {
      let oldParams = params
      let grouping = !undoManager.groupsByEvent && !undoManager.isUndoing && !undoManager.isRedoing
      if grouping { undoManager.beginUndoGrouping() }
      undoManager.registerUndo(withTarget: self) { lab in
        guard lab.busy == nil else {
          lab.notice = "正在处理，这一步撤销没有生效，请稍候再试。"
          return
        }
        lab.place(oldJob, base: oldBase, params: oldParams, name: name)
      }
      undoManager.setActionName(name)
      if grouping { undoManager.endUndoGrouping() }
    }
    lastChange = nil
    job = j
    self.base = base
    before = base.cgImage()
    // The old repair belongs to the old base; nothing is shown as repaired until this one is.
    after = nil
    params = next
    if region == nil { selectedRegion = nil }
    save()
    if hasReference && next.referenceModel == nil {
      fit(recorded: false)
    } else {
      preview()
    }
  }
  /// The original at full resolution: the imported file, or the frame converted as the job says.
  private func original(_ j: LeakJob) throws -> LeakImage {
    if let source = j.source, let folder { return try LeakImage(contentsOf: folder.appendingPathComponent(source)) }
    guard let origin = j.origin, let renderFrame else { throw DeskError.message("找不到这个任务的原片。") }
    return try LeakImage(renderFrame(origin))
  }

  // MARK: Regions, protection, landmarks, crop and presets

  /// What a drag on the picture does: compare, draw a leak region, place its clean point, or
  /// paint a protection.
  enum Tool: String { case inspect, ellipse, reference, protect }
  @Published var tool = Tool.inspect
  @Published var selectedRegion: String?
  /// The protection brush's radius, as a share of the picture's width.
  @Published var brush = 0.025
  @Published var showMasks = true
  @Published var sensitivity = 0.5
  @Published var showAlign = false
  @Published var showCrop = false
  var region: LeakRegion? { params.regions.first { $0.id == selectedRegion } }
  /// The job's matching points on the original and the reference.
  var pairs: [LeakPair] { job?.pairs ?? [] }

  /// A leak region drawn as an ellipse (0–1 of the picture): chosen, and waiting for a clean
  /// point of the same material.
  func addRegion(x: Double, y: Double, rx: Double, ry: Double) {
    let r = LeakRegion(
      id: UUID().uuidString.lowercased(), name: "手动区域 \(params.regions.count + 1)", shape: "ellipse", mode: "chroma",
      x: clamp(x), y: clamp(y), rx: max(0.005, rx), ry: max(0.005, ry), amount: 0.8, feather: 0.8)
    change("新建漏光区域") { $0.regions.append(r) }
    guard params.regions.contains(where: { $0.id == r.id }) else { return }
    selectedRegion = r.id
    tool = .reference
    notice = "区域已创建。现在在照片上点同材质、没有漏光的干净位置，作为颜色参考。"
  }
  /// The clean point the chosen region's colour is corrected to; what was measured before goes.
  func setReference(_ p: LeakPoint) {
    guard let id = selectedRegion, params.regions.contains(where: { $0.id == id }) else {
      notice = "先在列表里选择，或用「画区域」新建一个漏光区域。"
      return
    }
    change("区域参考点") { params in
      guard let i = params.regions.firstIndex(where: { $0.id == id }) else { return }
      params.regions[i].ref = LeakPoint(x: clamp(p.x), y: clamp(p.y))
      params.regions[i].target = nil
      params.regions[i].fog = nil
      params.regions[i].ratios = nil
      params.regions[i].channelRy = nil
      params.regions[i].gaussian = false
      params.regions[i].detected = false
    }
    tool = .inspect
  }
  /// A change to one region or protection; repeats of one control within a second are one step.
  func editRegion(_ id: String, _ name: String, joins: Bool = true, _ edit: (inout LeakRegion) -> Void) {
    change(name, step: joins ? name + "·" + id : nil) { p in
      if let i = p.regions.firstIndex(where: { $0.id == id }) {
        edit(&p.regions[i])
      } else if let i = p.protect.firstIndex(where: { $0.id == id }) {
        edit(&p.protect[i])
      }
    }
  }
  func moveRegion(_ id: String, x: Double, y: Double) {
    editRegion(id, "移动区域") {
      $0.x = clamp(x)
      $0.y = clamp(y)
    }
  }
  /// On or off; a suggestion turned on counts as approved, so the next fit keeps it.
  func setEnabled(_ id: String, _ on: Bool) {
    editRegion(id, on ? "启用区域" : "停用区域", joins: false) {
      $0.enabled = on
      $0.approved = on
    }
  }
  func deleteRegion(_ id: String) {
    change("删除区域") { p in
      p.regions.removeAll { $0.id == id }
      p.protect.removeAll { $0.id == id }
    }
    if selectedRegion == id && region == nil { selectedRegion = nil }
  }
  /// The leak region whose ellipse holds `p`, the nearest centre first, for picking and moving.
  func regionAt(_ p: LeakPoint) -> LeakRegion? {
    params.regions.filter { r in
      guard r.shape == "ellipse", let x = r.x, let y = r.y, let rx = r.rx, let ry = r.ry, rx > 0, ry > 0 else { return false }
      return pow((p.x - x) / rx, 2) + pow((p.y - y) / ry, 2) <= 1
    }.min { hypot(($0.x ?? 0) - p.x, ($0.y ?? 0) - p.y) < hypot(($1.x ?? 0) - p.x, ($1.y ?? 0) - p.y) }
  }
  /// A protection painted with the brush (points 0–1 of the picture), `radius` across or the
  /// brush's: nothing is corrected under it, whatever the fit or the detection says.
  @discardableResult func addProtection(_ points: [[Double]], radius: Double? = nil) -> String? {
    guard !points.isEmpty else { return nil }
    let r = LeakRegion(
      id: UUID().uuidString.lowercased(), name: "手绘保护区", shape: "stroke",
      points: Array(points.prefix(2000)).map { [clamp($0[0]), clamp($0[1])] }, radius: radius ?? brush)
    change("保护画笔") { $0.protect.append(r) }
    return params.protect.contains { $0.id == r.id } ? r.id : nil
  }
  /// Leak regions and lamp protections suggested from the picture. Suggested regions stay off
  /// until ticked; detected protections replace earlier detected ones; drawn ones stay.
  func detect() {
    guard let base, busy == nil else { return }
    let sensitivity = min(1, max(0.1, self.sensitivity))
    run("自动检测漏光区域") {
      let d = LeakEngine.detect(LeakEngine.resized(base, width: 320), sensitivity: sensitivity)
      return {
        self.change("自动检测") { p in
          p.regions = p.regions.filter { $0.detected != true } + d.regions.map { r in
            var r = r
            r.enabled = false
            r.detected = true
            return r
          }
          p.protect = Array((p.protect.filter { $0.detected != true } + d.protect.map { r in
            var r = r
            r.detected = true
            return r
          }).prefix(80))
        }
        self.selectedRegion = d.regions.first?.id ?? self.selectedRegion
        self.notice = d.message + "\n自动结果不是漏光定论：红色是候选校正（勾选后生效），青色是保护。"
      }
    }
  }
  /// Matching points, four or more, for when the automatic alignment is unsure; none aligns the
  /// reference as the same framing. The next fit uses them.
  func setPairs(_ list: [LeakPair]) {
    guard var j = job else { return }
    guard busy == nil else {
      notice = "正在处理，对应点没有保存，请稍候再设。"
      return
    }
    guard list.isEmpty || list.count >= 4 else {
      notice = "至少需要 4 对对应点；或清空后按相同构图对齐。"
      return
    }
    j.pairs = list.isEmpty ? nil : Array(list.prefix(20))
    job = j
    save()
    notice = list.isEmpty ? "已清空对应点，按相同构图对齐。" : "已设 \(min(20, list.count)) 对对应点。点击「开始去漏光」按对应点在本地重新拟合，不调用 API。"
  }
  /// The original turned as the job has it and not cut, about 900 pixels wide, for the crop sheet
  /// to draw the cut on.
  func uncutPreview(_ done: @escaping (CGImage?) -> Void) {
    guard let j = job else { return done(nil) }
    let rotation = params.rotation
    DispatchQueue.global(qos: .userInitiated).async {
      let image = (try? self.original(j)).map {
        LeakEngine.resized(LeakEngine.cropped($0, rotation: rotation, crop: LeakCrop()), width: 900).cgImage()
      }
      DispatchQueue.main.async { done(image) }
    }
  }
  /// A new crop of the turned original: a new base, the regions, protections and landmarks drawn
  /// on the old one cleared, and the reference matched again.
  func setCrop(_ crop: LeakCrop) {
    guard let j = job else { return }
    guard busy == nil else {
      notice = "正在处理，裁切没有应用，请稍候再试。"
      return
    }
    var c = crop
    c.x = min(0.9, max(0, c.x))
    c.y = min(0.9, max(0, c.y))
    c.w = min(1 - c.x, max(0.05, c.w))
    c.h = min(1 - c.y, max(0.05, c.h))
    c.angle = c.angle.map { min(45, max(-45, ($0 * 100).rounded() / 100)) }.flatMap { abs($0) < 0.005 ? nil : $0 }
    guard c != params.crop else { return }
    var next = params
    next.crop = c
    next.regions = []
    next.protect = []
    next.referenceModel = nil
    selectedRegion = nil
    rebuild(j, next, name: "裁切")
  }
  /// Parameters, regions and landmarks, in FilmLightLab's preset file: either app reads the
  /// other's. The fitted model and the scene judged belong to one photograph and are left out.
  struct Preset: Codable {
    var version = 1
    var name: String
    var params: LeakParams
    var pairs: [LeakPair]?
  }
  func savePreset(to url: URL) throws {
    var p = params
    p.referenceModel = nil
    p.sceneInfo = nil
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Preset(name: "Epson Scan plus 去漏光预设", params: p, pairs: job?.pairs)).write(to: url, options: .atomic)
    notice = "预设已保存到 \(url.lastPathComponent)。"
  }
  func loadPreset(from url: URL) {
    guard let j = job, busy == nil else { return }
    let preset: Preset
    do {
      preset = try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
    } catch {
      errorText = "不是有效的去漏光预设（Epson Scan plus 或 FilmLightLab）：\(error.localizedDescription)"
      return
    }
    var next = preset.params
    next.referenceModel = nil
    next.sceneInfo = nil
    let landmarks = (preset.pairs ?? []).count >= 4 ? Array((preset.pairs ?? []).prefix(20)) : nil
    selectedRegion = nil
    if next.rotation != params.rotation || next.crop != params.crop {
      rebuild(j, next, pairs: landmarks, name: "载入预设", notice: "预设已载入，方向 / 裁切按预设重建。区域位置按画幅比例保存，换了照片请检查并调整。")
      return
    }
    change("载入预设") { $0 = next }
    var k = j
    k.pairs = landmarks
    job = k
    save()
    notice = "预设已载入。区域位置按画幅比例保存，换了照片请检查并调整" + (hasReference ? "；点击「开始去漏光」重新拟合，不调用 API。" : "。")
  }
  func chooseSavePreset() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "去漏光预设.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try savePreset(to: url) } catch { errorText = error.localizedDescription }
  }
  func chooseLoadPreset() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.message = "选择去漏光预设（Epson Scan plus 或 FilmLightLab 导出的 JSON）。"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    loadPreset(from: url)
  }

  // MARK: Repairing

  /// 开始去漏光: with a reference, fitted here for free; without one, the API is asked for it.
  func start() {
    guard base != nil, busy == nil else { return }
    if hasReference {
      fit()
    } else if !credentials.configured {
      showAPI = true
      notice = "首次去漏光需要生成参考图：请在「API 管理」中设置 OpenAI API Key。不要把 Key 发到聊天中。"
    } else {
      showGenerate = true
    }
  }
  /// A fit's parameters over what changed while it ran (an undo, say): its model, the scene it
  /// judged and the protections it detected; the rest as it is now. Without `input`, always so.
  private func merged(_ fitted: LeakParams, over input: LeakParams?) -> LeakParams {
    if let input, params == input { return fitted }
    var p = params
    p.referenceModel = fitted.referenceModel
    p.sceneInfo = fitted.sceneInfo
    p.protect = p.protect.filter { $0.detected != true } + fitted.protect.filter { $0.detected == true }
    return p
  }
  /// The reference learned against the base, and the repair shown; `recorded` makes it an undo
  /// step of its own (not after a turn or a crop, whose step it belongs to).
  func fit(recorded: Bool = true) {
    guard let base, let guide, let j = job, let baseID = j.base else { return }
    let input = params
    pending?.cancel()
    generation += 1
    // The preview this replaces would have cleared it.
    updating = false
    run("拟合原片引导的边缘感知匹配") {
      let fitted = try LeakEngine.fitReference(base: base, guide: guide, params: input, pairs: j.pairs ?? [], baseID: baseID)
      let out = try LeakEngine.result(base, base: base, params: fitted)
      return {
        let next = self.merged(fitted, over: input)
        if recorded { self.set(next, name: "开始去漏光", step: nil) } else { self.params = next }
        if next == fitted { self.after = out.cgImage() } else { self.preview() }
        self.wipe = 0.5
        try? self.persist()
        let a = fitted.referenceModel?.alignment
        self.notice = "去漏光已应用：自动减除漏光亮雾，单独保护自然亮部和局部灯光，不锁定全图明暗。复用已有参考图，本次没有调用 API。"
          + ((a?.rotation ?? 0) != 0 ? "已自动匹配 \(a!.rotation)° 参考方向。" : "")
          + (a?.reliable == false ? "自动对齐不确定，请检查参考图与原片是否同一构图。" : "请检查灯光红晕和真实红色物体。")
      }
    }
  }
  /// A reference from a file: the same photograph, cleaned elsewhere.
  func importReference(_ url: URL) {
    guard job != nil, busy == nil else { return }
    run("读取参考图") {
      try self.onMain { try self.persist() }
      guard let folder = self.folder, var j = self.onMain({ self.job }) else { return {} }
      let name = "guide-\(Self.stamp()).\(url.pathExtension.lowercased())"
      try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
      let guide = try self.loadGuide(folder.appendingPathComponent(name))
      let shown = try? ImagePipeline.shared.load(folder.appendingPathComponent(name), maxDimension: 1800)
      j.guide = name
      j.guideName = url.lastPathComponent
      j.generatedAI = nil
      j.pairs = nil
      return {
        self.job = j
        self.guide = guide
        self.reference = shown
        self.change("导入参考图") { $0.referenceModel = nil }
        self.save()
        self.notice = "参考图已导入。检查构图一致后，点击「开始去漏光」。"
      }
    }
  }
  func chooseReference() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.tiff, .png, .jpeg]
    panel.message = "选择同一张照片的完整参考图（已去除漏光）。"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    importReference(url)
  }
  /// The reference made by the image model: the only paid step. The result is kept before it is
  /// fitted, so a failed fit never costs a second request.
  func generate(quality: String, note: String) {
    guard let base, job != nil, busy == nil else { return }
    let key = credentials.secret, model = credentials.model, input = params
    busy = "准备无 EXIF 正片缩图"
    queue.async {
      do {
        var prepared = try LeakEngine.prepare(base: base, params: input, target: nil)
        prepared.referenceModel = nil
        let jpeg = try base.jpeg(maxDimension: 1536, quality: 0.94)
        try self.onMain {
          try self.persist()
          self.busy = "OpenAI 生成中，可能数分钟（阶段进度，非模型百分比）"
        }
        let request = LeakOpenAI.Request(
          apiKey: key, model: model, quality: quality, jpeg: Self.withoutExif(jpeg.data), width: jpeg.width, height: jpeg.height,
          note: note, scene: prepared.sceneInfo?.type ?? "mixed")
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(bytes: Data, meta: LeakJob.Generated), Error>!
        Task {
          do { outcome = .success(try await LeakOpenAI.edit(request)) } catch { outcome = .failure(error) }
          semaphore.signal()
        }
        semaphore.wait()
        let generated = try outcome.get()
        try self.receive(generated, prepared: prepared)
      } catch {
        DispatchQueue.main.async {
          self.busy = nil
          self.errorText = error.localizedDescription
        }
      }
    }
  }
  /// A generated reference: saved, then fitted if it can be.
  func receive(_ generated: (bytes: Data, meta: LeakJob.Generated), prepared: LeakParams) throws {
    let (current, folder, job) = onMain { (self.base, self.folder, self.job) }
    guard let base = current, let folder, var j = job, let baseID = j.base else {
      throw DeskError.message("去漏光任务已关闭，参考图没有保存。")
    }
    let stamp = Self.stamp(), name = "guide-ai-\(stamp).png"
    guard let source = CGImageSourceCreateWithData(generated.bytes as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width * image.height <= 20_000_000
    else { throw DeskError.message("API 返回图像无法读取。") }
    try ImagePipeline.shared.savePNG(image, to: folder.appendingPathComponent(name))
    // Read back before the job names it, so a failure leaves the job as it was.
    let guide = LeakEngine.resized(try LeakImage(image), width: 640)
    let shown = try? ImagePipeline.shared.load(folder.appendingPathComponent(name), maxDimension: 1800)
    var meta = generated.meta
    meta.sourceBase = baseID
    meta.sourceGeometry = .init(rotation: prepared.rotation, crop: prepared.crop)
    j.guide = name
    j.guideName = "OpenAI · \(meta.model) · \(stamp)"
    j.generatedAI = meta
    j.pairs = nil
    try onMain {
      let old = self.job
      self.job = j
      do { try self.persist() } catch {
        self.job = old
        throw error
      }
      self.guide = guide
      self.reference = shown
      self.busy = "参考图已保存，拟合低频校正"
    }
    var params = prepared, warning: String
    do {
      if abs(log(guide.aspect / base.aspect)) > 0.08 { throw DeskError.message("模型改变了画幅比例，请先检查参考图与原片是否同一构图") }
      params = try LeakEngine.fitReference(base: base, guide: guide, params: prepared, baseID: baseID)
      let rotation = params.referenceModel?.alignment.rotation ?? 0
      warning = "去漏光已应用：自动减除漏光亮雾，单独保护自然高光和灯光信号，不锁定全图明暗。已自动匹配参考方向 \(rotation)°。请检查对比、灯光红晕和真实红色物体；之后重新应用这张参考图不调用 API。"
    } catch {
      warning = "参考图已生成并保存，但未自动应用：\(error.localizedDescription)。请检查后在本地重新应用，无需再次调用 API。"
    }
    let out = try LeakEngine.result(base, base: base, params: params)
    DispatchQueue.main.async {
      self.pending?.cancel()
      self.generation += 1
      self.updating = false
      self.guide = guide
      self.reference = shown
      let next = self.merged(params, over: nil)
      self.set(next, name: "生成参考图", step: nil)
      if next == params { self.after = out.cgImage() } else { self.preview() }
      self.wipe = 0.5
      self.save()
      self.busy = nil
      self.notice = warning
    }
  }
  /// A JPEG without its APP1 (Exif, XMP) segments: nothing about the file or the computer goes
  /// with the upload but the pixels and their colour profile.
  static func withoutExif(_ jpeg: Data) -> Data {
    let b = [UInt8](jpeg)
    guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return jpeg }
    var out: [UInt8] = [0xFF, 0xD8], i = 2
    while i + 4 <= b.count, b[i] == 0xFF {
      let marker = b[i + 1]
      if marker == 0xDA { break }
      let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
      guard length >= 2, i + 2 + length <= b.count else { return jpeg }
      if marker != 0xE1 { out += b[i..<(i + 2 + length)] }
      i += 2 + length
    }
    out += b[i...]
    return Data(out)
  }

  // MARK: Preview and export

  /// The repair on the base; `soon` waits for a slider to settle.
  func preview(soon: Bool = false) {
    pending?.cancel()
    guard let base else { return }
    generation += 1
    let id = generation, input = params
    updating = true
    let work = DispatchWorkItem {
      var out: LeakImage?, failure: String?
      do { out = try LeakEngine.result(base, base: base, params: input) } catch { failure = error.localizedDescription }
      DispatchQueue.main.async {
        guard id == self.generation else { return }
        self.updating = false
        self.after = out.map { $0.cgImage() }
        if let failure { self.errorText = failure }
      }
    }
    pending = work
    queue.asyncAfter(deadline: .now() + (soon ? 0.3 : 0), execute: work)
  }
  func chooseExport() {
    guard let j = job, repaired, busy == nil else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.tiff]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.stem(j.sourceName) + ".tif"
    panel.message = "16 位 Adobe RGB TIFF，并附 sRGB JPEG 预览与参数记录"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    export(to: url)
  }
  /// The repair at full resolution: a 16-bit Adobe RGB TIFF, an sRGB JPEG of the same pixels
  /// beside it and a record of the parameters. Nothing is written over but the chosen file.
  func export(to url: URL, completion: (() -> Void)? = nil) {
    guard let j = job, let base, busy == nil else { return }
    let input = params
    run("读取全分辨率像素") {
      let full = LeakEngine.cropped(try self.original(j), rotation: input.rotation, crop: input.crop)
      self.onMain { self.busy = "应用去漏光到全分辨率" }
      let out = try LeakEngine.result(full, base: base, params: input)
      try out.saveTIFF(to: url)
      let folder = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent
      var jpg = folder.appendingPathComponent(stem + ".jpg"), n = 1
      while FileManager.default.fileExists(atPath: jpg.path) {
        n += 1
        jpg = folder.appendingPathComponent("\(stem)-\(n).jpg")
      }
      try out.jpeg(quality: 0.95).data.write(to: jpg)
      struct Record: Encodable {
        var version = 1, sourceName: String, params: LeakParams, generatedAI: LeakJob.Generated?
        var width: Int, height: Int, colorSpace = "Adobe RGB (1998)", depth = 16
        var note = "参考图只提供平滑校正参数；所有输出结构来自原片。"
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(Record(sourceName: j.sourceName, params: input, generatedAI: j.generatedAI, width: out.width, height: out.height))
        .write(to: url.appendingPathExtension("json"), options: .atomic)
      return {
        self.notice = "已导出 \(out.width) × \(out.height) · RGB 16 位 · Adobe RGB 到 \(url.lastPathComponent)，并附 sRGB JPEG 与参数记录。原片未改动。"
        completion?()
      }
    }
  }
  static func stem(_ name: String) -> String {
    var value = (name as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping
      .replacingOccurrences(of: "[<>:\"/\\\\|?*\\x00-\\x1f\\x7f]", with: "_", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
    if value.isEmpty { value = "照片" }
    while value.utf8.count > 200 { value.removeLast() }
    return value + "_去漏光"
  }

  // MARK: Running

  /// `work` off the main thread, then what it returns on it; failures are shown.
  private func run(_ label: String, _ work: @escaping () throws -> () -> Void) {
    busy = label
    queue.async {
      do {
        let finish = try work()
        DispatchQueue.main.async {
          self.busy = nil
          finish()
        }
      } catch {
        DispatchQueue.main.async {
          self.busy = nil
          self.errorText = error.localizedDescription
        }
      }
    }
  }
  @discardableResult private func onMain<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try body() }
    return try DispatchQueue.main.sync(execute: body)
  }
  /// Waits for queued work, for tests and the command line.
  func wait(_ seconds: Double = 300) {
    let deadline = Date().addingTimeInterval(seconds)
    while (busy != nil || updating) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
  }
}

extension AppModel {
  /// The open project's file.
  var projectPath: String? { sessionURL?.appendingPathComponent(projectFileName).path }
  /// What a light-leak job keeps of a frame of the open roll: its conversion as it is now.
  func leakOrigin(_ frame: FilmFrame) -> LeakJob.Origin? {
    projectPath.map { LeakJob.Origin(project: $0, frame: frame.id, frameName: frame.name, adjustments: frame.adjustments, profile: profile) }
  }
  /// A frame of the open roll at full resolution, converted as `origin` says and as an export
  /// would convert it.
  func leakPositive(_ origin: LeakJob.Origin) throws -> CGImage {
    // What the open roll says, read on the main thread: the lab asks from its own queue.
    let read = { (self.projectPath, self.frames.first { $0.id == origin.frame }, self.preferences.sharpening) }
    let (path, found, sharpening) = Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    guard path == origin.project, var frame = found else {
      let roll = URL(fileURLWithPath: origin.project).deletingLastPathComponent().lastPathComponent
      throw DeskError.message("请先打开第 \(origin.frameName) 张所在的工程「\(roll)」。")
    }
    frame.adjustments = origin.adjustments
    let image = try source(for: frame, full: true)
    let sharpener = Sharpening.sharpener(sharpening, frame: frame, maxDimension: nil)
    // Unclipped, as the renderer computes it: the engine converts it into Adobe RGB exactly.
    let pipeline = ImagePipeline.shared
    let ci = try pipeline.output(image, settings: frame.adjustments, profile: origin.profile, sharpener: sharpener, extendedRange: true)
    guard let cg = pipeline.context.createCGImage(ci, from: ci.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
    else { throw DeskError.message("无法生成正片。") }
    return cg
  }
  func makeLeakLab() -> LeakLab {
    let lab = LeakLab(preferences: preferences)
    lab.renderFrame = { [weak self] origin in
      guard let self else { throw DeskError.message("App 正在关闭。") }
      return try self.leakPositive(origin)
    }
    lab.credentials.restore()
    return lab
  }
}
