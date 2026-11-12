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
    /// The roll's film as named, its format and the frame's dpi when the job began, for the export:
    /// nil in jobs from before they were kept.
    var film: String? = nil
    var format: String? = nil
    var dpi: Int? = nil
    /// True when the job's picture is the frame as ② 去色罩 leaves it, with none of ③'s grading
    /// (`ImagePipeline.neutral`): its repair can be taken into ③ (`AppModel.applyLeakRepair`).
    /// Nil in jobs from before, made of the graded picture: they export as before.
    var neutral: Bool? = nil
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
/// that calls the API), imported, or made with the user's own image model, and refitted for free
/// after every change of scene or orientation; or, without one, by the local regions alone, drawn
/// here or by an assistant over MCP.
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
  /// The frame as the job's picture shows it (`ImagePipeline.neutral`), at most `longest` pixels
  /// across, and the scale it is on: what the repair is measured on to take it into ③.
  var renderNeutral: ((LeakJob.Origin, Int) throws -> (image: CGImage, scale: LeakNeutralScale))?
  private let preferences: Preferences?
  private var base: LeakImage? {
    didSet { baseRevision += 1 }
  }
  /// Counted up with each new base, so a preview of the one before is never shown on this one.
  private var baseRevision = 0
  /// The reference, 640 px across, as the fit reads it.
  private var guide: LeakImage?
  private let queue = DispatchQueue(label: "epscan.leak", qos: .userInitiated)
  private var generation = 0
  /// The preview asked for last, not yet begun (`previewLock`): a fader dragged asks for one each
  /// step, and the queue takes the newest when its turn comes.
  private var wantedPreview: (id: Int, base: LeakImage, baseRevision: Int, params: LeakParams, picture: [Double]?)?
  private var previewQueued = false
  private let previewLock = NSLock()
  /// The newest preview shown, and the oldest that may be: a fit or a generation sets it past the
  /// previews it replaces.
  private var shownPreview = 0
  private var previewFloor = 0
  /// Previews asked for before now are not shown: what replaces them is under way.
  private func dropPreviews() {
    generation += 1
    previewFloor = generation
    previewLock.lock()
    wantedPreview = nil
    previewLock.unlock()
  }
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
  /// Local regions act on the picture: those enabled (detected ones are not until ticked).
  var regionsAct: Bool { params.regions.contains { $0.enabled != false } }
  /// The repair is applied to this base: the reference's correction, or local regions, with or
  /// without one.
  var repaired: Bool { (model.map { $0.strength > 0 && ($0.sourceBase == nil || $0.sourceBase == job?.base) } ?? false) || regionsAct }
  /// Whether the page can export: a picture open and nothing running. Without a repair (strength
  /// 0, no reference, no region on) the export is the picture with its basic adjustments and the
  /// film's edge cleaned.
  var exportable: Bool { job != nil && hasBase && busy == nil }

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
  /// About where the photograph lies in the job's picture, as left, top, right, bottom (0–1): the
  /// frame's de-masking region, drawn on the roll about the photograph, turned as its positive is,
  /// then as the job turns and crops it. Nil for an imported file, or a frame without one.
  static func pictureHint(_ job: LeakJob?, _ params: LeakParams) -> [Double]? {
    guard let origin = job?.origin, let r = origin.adjustments.analysisRegion, let meta = job?.meta else { return nil }
    let s = origin.adjustments
    // The positive is turned; straightening reads the unturned picture's shape.
    let turned = Double(meta.width) / Double(max(1, meta.height))
    let aspect = (((s.rotation % 4) + 4) % 4) % 2 == 1 ? 1 / turned : turned
    let corners = [(r.x, r.y), (r.x + r.width, r.y), (r.x, r.y + r.height), (r.x + r.width, r.y + r.height)].map { c -> (Double, Double) in
      let d = ImageGeometry.display(CGPoint(x: c.0, y: c.1), settings: s, aspect: aspect)
      var (u, v) = (Double(d.x), Double(d.y))
      // As `LeakEngine.cropped` turns the positive (degrees clockwise) and cuts it.
      switch ((params.rotation % 360) + 360) % 360 {
      case 90: (u, v) = (1 - v, u)
      case 180: (u, v) = (1 - u, 1 - v)
      case 270: (u, v) = (v, 1 - u)
      default: break
      }
      let c = params.crop
      u = (u - c.x) / max(1e-6, c.w)
      v = (v - c.y) / max(1e-6, c.h)
      if let degrees = c.angle, abs(degrees) > 0.0001 {
        let k = ImageGeometry.keep(degrees, aspect: c.w * turned / max(1e-6, c.h))
        (u, v) = (0.5 + (u - 0.5) / k, 0.5 + (v - 0.5) / k)
      }
      return (u, v)
    }
    let xs = corners.map(\.0), ys = corners.map(\.1)
    return [xs.min()!, ys.min()!, xs.max()!, ys.max()!]
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
  /// The frame converted as it is now, for a job begun before its conversion changed. A repair
  /// fitted on the old conversion is fitted again on the new one, from the same reference, free.
  func reload(origin: LeakJob.Origin) {
    guard var j = job, j.origin?.frame == origin.frame, busy == nil else { return }
    let refit = params.referenceModel != nil && hasReference
    j.origin = origin
    var next = params
    next.referenceModel = nil
    // The framing is the same, so the landmarks still match.
    rebuild(j, next, pairs: j.pairs, name: "按当前调色重新载入") { if refit { self.fit() } }
  }
  /// Whether the job open is `origin`'s frame, converted otherwise than it is now.
  func stale(for origin: LeakJob.Origin) -> Bool {
    guard let o = job?.origin, o.frame == origin.frame, o.project == origin.project else { return false }
    // A job of the frame as ② leaves it changes only with ②; ③'s grading comes after it.
    if o.neutral == true { return !AppModel.sameDemasking(o.adjustments, origin.adjustments) || o.profile != origin.profile }
    return o.adjustments != origin.adjustments || o.profile != origin.profile
  }
  private static let rebuildLabel = "重建正片预览"
  private var rebuilding: Bool { busy == Self.rebuildLabel }
  private func rebuild(_ j: LeakJob, _ next: LeakParams, pairs: [LeakPair]? = nil, name: String = "旋转 / 裁切", notice told: String? = nil,
                       then: (() -> Void)? = nil) {
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
        then?()
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

  /// 开始去漏光: with a reference, fitted here for free; without one, the local regions alone when
  /// some are drawn or ticked, free too; with neither, the API is asked for a reference.
  func start() {
    guard base != nil, busy == nil else { return }
    if hasReference {
      fit()
    } else if regionsAct {
      try? persist()
      preview()
      wipe = 0.5
      let n = params.regions.filter { $0.enabled != false }.count
      notice = "已按 \(n) 个局部区域去漏光：没有参考图，只校正标出的区域，其余像素不变，没有调用 API。请检查区域边缘和真实红色物体。"
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
    dropPreviews()
    // The preview this replaces would have cleared it.
    updating = false
    run("拟合原片引导的边缘感知匹配") {
      let fitted = try LeakEngine.fitReference(base: base, guide: guide, params: input, pairs: j.pairs ?? [], baseID: baseID)
      let out = try LeakEngine.result(base, base: base, params: fitted, picture: Self.pictureHint(j, fitted))
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
  /// What to ask an image model of the user's own for (a subscription's image editing, say): the
  /// prompt the API is sent, for this photograph's scene.
  func referencePrompt() throws -> (text: String, scene: String) {
    let (current, input) = onMain { (self.base, self.params) }
    guard let current else { throw DeskError.message("去漏光页还没有照片。") }
    let scene = try LeakEngine.prepare(base: current, params: input, target: nil).sceneInfo?.type ?? "mixed"
    return (LeakOpenAI.buildPrompt(scene: scene, note: ""), scene)
  }
  /// The photograph to upload there, as the API is sent it: 1536 px at most, no Exif.
  func referenceThumbnail() throws -> Data {
    guard let current = onMain({ self.base }) else { throw DeskError.message("去漏光页还没有照片。") }
    return Self.withoutExif(try current.jpeg(maxDimension: 1536, quality: 0.94).data)
  }
  /// Saves the thumbnail where the user chooses, and puts the prompt on the clipboard.
  func chooseReferenceUpload() {
    guard let j = job, base != nil, busy == nil else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.jpeg]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.stem(j.sourceName) + "-参考图用.jpg"
    panel.message = "最长边 1536 px、无 EXIF 的缩图，上传到你自己的图像模型；提示词同时复制到剪贴板"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    run("准备缩图和提示词") {
      let prompt = try self.referencePrompt()
      try self.referenceThumbnail().write(to: url, options: .atomic)
      return {
        Self.copy(prompt.text)
        self.notice = "缩图已存为「\(url.lastPathComponent)」，提示词（英文）已复制。在 ChatGPT 等能改图的应用里上传缩图、粘贴提示词，下载生成的图，再用「导入已有参考图…」导回来；不调用 API。"
      }
    }
  }
  func copyReferencePrompt() {
    guard base != nil, busy == nil else { return }
    run("准备提示词") {
      let prompt = try self.referencePrompt()
      return {
        Self.copy(prompt.text)
        self.notice = "提示词（英文，按\(["day": "白天", "night": "夜晚"][prompt.scene] ?? "混合光")场景）已复制。配合「导出缩图…」存下的缩图，在你自己的图像模型里用。"
      }
    }
  }
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
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
    let out = try LeakEngine.result(base, base: base, params: params, picture: Self.pictureHint(j, params))
    DispatchQueue.main.async {
      self.dropPreviews()
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
  /// The repair as the parameters are now, on the queue. Throttled rather than put off: while a
  /// fader moves, each preview begins as the one before ends, with the parameters asked for last,
  /// and every one newer than the picture shown is shown. Put off 0.3 s, a drag showed nothing
  /// until the hand stopped.
  func preview(soon: Bool = false) {
    guard let base else { return }
    generation += 1
    updating = true
    previewLock.lock()
    wantedPreview = (generation, base, baseRevision, params, Self.pictureHint(job, params))
    let queued = previewQueued
    previewQueued = true
    previewLock.unlock()
    if !queued { queue.asyncAfter(deadline: .now() + (soon ? 0.015 : 0)) { [weak self] in self?.runPreview() } }
  }
  private func runPreview() {
    previewLock.lock()
    let wanted = wantedPreview
    wantedPreview = nil
    previewQueued = false
    previewLock.unlock()
    guard let w = wanted else { return }
    var out: LeakImage?, failure: String?
    do { out = try LeakEngine.result(w.base, base: w.base, params: w.params, picture: w.picture) } catch { failure = error.localizedDescription }
    let picture = out.map { $0.cgImage() }
    DispatchQueue.main.async {
      guard w.id >= self.previewFloor, w.id > self.shownPreview, w.baseRevision == self.baseRevision else { return }
      self.shownPreview = w.id
      self.after = picture
      if let failure { self.errorText = failure }
      if w.id == self.generation { self.updating = false }
    }
  }
  func chooseExport() {
    guard let j = job, exportable else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.tiff]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.stem(j.sourceName) + ".tif"
    panel.message = repaired ? "16 位 Adobe RGB TIFF，并附 sRGB JPEG 预览与参数记录"
      : "这张没有去漏光：导出带基础调整和片边处理的原片，16 位 Adobe RGB TIFF，并附 sRGB JPEG 预览与参数记录"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    export(to: url)
  }
  /// The repair at full resolution: a 16-bit Adobe RGB TIFF, an sRGB JPEG of the same pixels
  /// beside it and a record of the parameters. Nothing is written over but the chosen file.
  /// Without a repair it is the picture with its basic adjustments and the film's edge cleaned.
  func export(to url: URL, completion: (() -> Void)? = nil) {
    guard let j = job, let base, busy == nil else { return }
    var input = params
    let leakFixed = repaired
    // A fit left from before the picture was turned or cropped is not this picture's.
    if !leakFixed, let m = input.referenceModel, m.sourceBase != nil, m.sourceBase != j.base { input.referenceModel = nil }
    run("读取全分辨率像素") {
      let full = LeakEngine.cropped(try self.original(j), rotation: input.rotation, crop: input.crop)
      self.onMain { self.busy = "应用去漏光到全分辨率" }
      let out = try LeakEngine.result(full, base: base, params: input, picture: Self.pictureHint(j, input))
      // At the frame's own dpi (a copy's as the roll's format gives it), else 300.
      try out.saveTIFF(to: url, dpi: j.origin?.dpi ?? 300)
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
        var leakRepaired: Bool, note: String
        var film: String?, format: String?, dpi: Int?
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(Record(sourceName: j.sourceName, params: input, generatedAI: j.generatedAI, width: out.width, height: out.height,
        leakRepaired: leakFixed,
        note: leakFixed ? "参考图只提供平滑校正参数；所有输出结构来自原片。" : "没有去漏光：只有基础调整和片边处理；所有输出结构来自原片。",
        film: j.origin?.film, format: j.origin?.format, dpi: j.origin?.dpi))
        .write(to: url.appendingPathExtension("json"), options: .atomic)
      return {
        self.notice = "已导出 \(out.width) × \(out.height) · RGB 16 位 · Adobe RGB 到 \(url.lastPathComponent)"
          + (leakFixed ? "" : "（这张没有去漏光，是带基础调整和片边处理的原片）")
          + "，并附 sRGB JPEG 与参数记录。原片未改动。"
        completion?()
      }
    }
  }
  /// A frame of the roll as ② leaves it: its orientation and crop are ②'s, not turned or cut here.
  var geometryIsTheRolls: Bool { job?.origin?.neutral == true }
  /// Whether the repair can go into ③ 调色: a frame of the open roll, its job made of the frame as
  /// ② leaves it, not turned or cut here (that is ②'s to do), and something repaired. Else why not.
  var whyNotIntoGrading: String? {
    guard let j = job, j.origin != nil else { return "导入的照片不在卷里：去漏光以后用「导出」" }
    guard j.origin?.neutral == true else { return "这个任务是从调好色的正片开始的（以前的做法）：在「照片」一节点「从 ② 的结果重新载入」，区域和参考图都留着" }
    guard params.rotation == 0, params.crop == LeakCrop() else { return "方向和裁切请在 ② 去色罩里改；去漏光里的旋转和裁切去掉以后才能用到调色" }
    guard repaired else { return "还没有去漏光" }
    return nil
  }
  /// The repair measured back onto the conversion (`LeakFix.measure`): the frame's picture drawn
  /// again as the job's was, repaired with the job's settings but none of the page's basic
  /// adjustments (exposure, warmth, tint and contrast are ③'s now), and the change read off it
  /// onto the straight line; then put on a grid over the frame's picture as the conversion reads
  /// it, `place` taking each point of that to where it shows. `completion` on the main thread.
  func measureRepair(gridAspect: Double, place: @escaping (CGPoint) -> CGPoint,
    completion: @escaping (Result<(field: LeakFixField, mean: Double, worst: Double), Error>) -> Void)
  {
    guard let j = job, let origin = j.origin, let base, let renderNeutral, whyNotIntoGrading == nil else {
      completion(.failure(DeskError.message(whyNotIntoGrading ?? "没有可以用到调色的去漏光。")))
      return
    }
    var input = params
    (input.exposure, input.temperature, input.tint, input.contrast) = (0, 0, 0, 0)
    run("把去漏光用到调色") {
      do {
        let drawn = try renderNeutral(origin, max(base.width, base.height) + 200)
        let before = LeakEngine.resized(try LeakImage(drawn.image), width: base.width)
        let after = try LeakEngine.result(before, base: base, params: input, picture: Self.pictureHint(j, input))
        // Measured at half the page's size at most: the correction is smooth, the boxes 1/80 across.
        let k = min(1, 900 / Double(max(before.width, before.height)))
        let w = max(8, Int(Double(before.width) * k)), h = max(8, Int(Double(before.height) * k))
        let m = LeakFix.measure(before: Self.screenValues(before, w, h), after: Self.screenValues(after, w, h),
          width: w, height: h, scale: drawn.scale, radius: max(4, max(w, h) / 80))
        // Kept as a grid of at most 160 across, over the picture as the conversion reads it.
        let (sa, sw, sh) = LeakFix.shrunk(m.a, width: w, height: h, longest: 160)
        let (sd, _, _) = LeakFix.shrunk(m.d, width: w, height: h, longest: 160)
        let gw = gridAspect >= 1 ? 160 : max(8, Int((160 * gridAspect).rounded()))
        let gh = gridAspect >= 1 ? max(8, Int((160 / gridAspect).rounded())) : 160
        let field = LeakFixField(width: gw, height: gh,
          a: LeakFix.resampled(sa, width: sw, height: sh, to: gw, gh, place: place),
          d: LeakFix.resampled(sd, width: sw, height: sh, to: gw, gh, place: place))
        return { completion(.success((field, m.mean, m.worst))) }
      } catch {
        return { completion(.failure(error)) }
      }
    }
  }
  /// A picture's values as the screen's sRGB, 0–1, `width` × `height`, row after row from the top.
  static func screenValues(_ image: LeakImage, _ width: Int, _ height: Int) -> [Float] {
    var rgba = [Float](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    rgba.withUnsafeMutableBytes { raw in
      guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 32, bytesPerRow: width * 16, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return }
      ctx.interpolationQuality = .high
      ctx.draw(image.cgImage(), in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var rgb = [Float](repeating: 0, count: width * height * 3)
    for i in 0..<(width * height) { for c in 0..<3 { rgb[i * 3 + c] = rgba[i * 4 + c] } }
    return rgb
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
  /// From taking the mask off to the 去漏光 page: the frame selected and opened there as it is
  /// converted now; a job already made of it opens as it was left.
  func openInLeak(_ id: UUID) {
    guard let f = frames.first(where: { $0.id == id }), let origin = leakOrigin(f) else { return }
    if selectedID != id { select(id) }
    page = .leak
    leak.open(origin: origin)
  }
  /// What a light-leak job keeps of a frame of the open roll: its conversion as it is now. The
  /// job's picture is the frame as ② leaves it (`neutral`), so its repair can go into ③.
  func leakOrigin(_ frame: FilmFrame) -> LeakJob.Origin? {
    projectPath.map {
      var origin = LeakJob.Origin(project: $0, frame: frame.id, frameName: frame.name, adjustments: frame.adjustments, profile: conversionProfile,
        film: filmName, format: format.shortMM == nil ? nil : format.rawValue,
        dpi: frame.hasFullResolution ? pixelDPI(frame).map { Int($0.rounded()) } : nil)
      origin.adjustments.leakFix = nil
      origin.neutral = true
      return origin
    }
  }
  /// The frame of `origin` as 去漏光 works on it (`ImagePipeline.neutral`), at most `longest`
  /// pixels across (nil, at full resolution), as the job converts it.
  func leakNeutral(_ origin: LeakJob.Origin, longest: Int?) throws -> (image: CGImage, scale: LeakNeutralScale) {
    let read = { (self.projectPath, self.frames.first { $0.id == origin.frame }) }
    let (path, found) = Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    guard path == origin.project, var frame = found else {
      let roll = URL(fileURLWithPath: origin.project).deletingLastPathComponent().lastPathComponent
      throw DeskError.message("请先打开第 \(origin.frameName) 张所在的工程「\(roll)」。")
    }
    frame.adjustments = origin.adjustments
    frame.adjustments.leakFix = nil
    let image = try longest.map { try source(for: frame, maxDimension: $0) } ?? source(for: frame, full: true)
    let pipeline = ImagePipeline.shared
    let (ci, scale) = try pipeline.neutral(image, settings: frame.adjustments, profile: origin.profile)
    guard let cg = pipeline.context.createCGImage(ci, from: ci.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
    else { throw DeskError.message("无法生成正片。") }
    return (cg, scale)
  }
  /// 去漏光's repair taken into ③ 调色: measured (`LeakLab.measureRepair`), kept in the roll's
  /// Repairs folder, and set on the frame as one edit; then ③, where it is graded.
  func applyLeakRepair() {
    guard let j = leak.job, let origin = j.origin, origin.project == projectPath,
      let i = frames.firstIndex(where: { $0.id == origin.frame }), let root = sessionURL
    else { leak.notice = leak.whyNotIntoGrading ?? "请先打开这张照片所在的卷。"; return }
    let f = frames[i]
    let s = f.adjustments
    let aspect = exportPixels(f).map { size -> Double in
      // The picture as the conversion reads it: before it is straightened and turned.
      let turned = ((s.rotation % 4) + 4) % 2 == 1
      return turned ? Double(size.height / size.width) : Double(size.width / size.height)
    } ?? 1.5
    let place = { (p: CGPoint) in ImageGeometry.display(p, settings: s, aspect: aspect) }
    leak.measureRepair(gridAspect: aspect, place: place) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        self.leak.errorText = error.localizedDescription
      case .success(let measured):
        let name = "\(Self.exportFrameName(f.name))-\(String(Int(Date().timeIntervalSince1970), radix: 36)).leakfix"
        let url = root.appendingPathComponent("Repairs", isDirectory: true).appendingPathComponent(name)
        do { try measured.field.write(to: url) } catch {
          self.leak.errorText = "去漏光的校正存不下来：\(error.localizedDescription)"
          return
        }
        guard let k = self.frames.firstIndex(where: { $0.id == f.id }) else { return }
        self.recordEdit("把去漏光用到调色")
        let old = self.frames[k].adjustments.leakFix
        self.frames[k].adjustments.leakFix = LeakFix(
          file: url.path, job: j.id, made: Date(), meanError: measured.mean, worstError: measured.worst)
        if let old { LeakFixStore.shared.forget(old.file) }
        self.refresh()
        self.updateThumbnails()
        self.saveProject()
        if self.selectedID != f.id { self.select(f.id) }
        self.convertStep = .grade
        self.page = .convert
        self.status = String(format: "第 %@ 张的去漏光已用到 ③ 调色：之后的调色都在修好的照片上；和去漏光页的结果平均差 %.1f / 255", f.name, measured.mean)
      }
    }
  }
  /// Whether two settings of a frame make the same picture for 去漏光 (`ImagePipeline.neutral`):
  /// the same base, slopes, white balance, ends and geometry, whatever ③ grades after them.
  static func sameDemasking(_ a: Adjustments, _ b: Adjustments) -> Bool {
    func part(_ s: Adjustments) -> Adjustments {
      var p = s
      // ③'s settings all as new, and the repair itself, which comes of this picture.
      p.takeGrading(from: Adjustments())
      p.leakFix = nil
      return p
    }
    return part(a) == part(b)
  }
  /// The frame's repair taken out again, as one edit; its file stays, for ⌘Z.
  func removeLeakRepair(_ id: UUID) {
    guard let i = frames.firstIndex(where: { $0.id == id }), frames[i].adjustments.leakFix != nil else { return }
    recordEdit("去掉去漏光")
    frames[i].adjustments.leakFix = nil
    refresh()
    updateThumbnails()
    saveProject()
    status = "第 \(frames[i].name) 张不再用去漏光的修复"
  }
  /// A frame of the open roll at full resolution, converted as `origin` says and as an export
  /// would convert it.
  func leakPositive(_ origin: LeakJob.Origin) throws -> CGImage {
    // What the open roll says, read on the main thread: the lab asks from its own queue.
    let read = { (self.projectPath, self.frames.first { $0.id == origin.frame }.map(self.sharpened), self.preferences.sharpening) }
    let (path, found, sharpening) = Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    guard path == origin.project, var frame = found else {
      let roll = URL(fileURLWithPath: origin.project).deletingLastPathComponent().lastPathComponent
      throw DeskError.message("请先打开第 \(origin.frameName) 张所在的工程「\(roll)」。")
    }
    // A job made of the frame as ② leaves it: that picture again, at full resolution.
    if origin.neutral == true { return try leakNeutral(origin, longest: nil).image }
    // The job's conversion, the frame's sharpening as the roll works it out when the job set none.
    let strength = frame.adjustments.sharpening
    frame.adjustments = origin.adjustments
    if frame.adjustments.sharpening == nil { frame.adjustments.sharpening = strength }
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
    lab.renderNeutral = { [weak self] origin, longest in
      guard let self else { throw DeskError.message("App 正在关闭。") }
      return try self.leakNeutral(origin, longest: longest)
    }
    lab.credentials.restore()
    return lab
  }
}
