import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
  let scanner: ScannerController
  @Published var frames = [FilmFrame]()
  @Published var selectedID: UUID?
  @Published var overview: CGImage?
  @Published var displayed: CGImage?
  @Published var thumbnails = [UUID: CGImage]()
  @Published var singleView = false
  @Published var showNegative = false
  @Published var tool = CanvasTool.select
  @Published var format = FilmFormat.auto
  @Published var dpi = 2400
  @Published var filmName = "Kodak Portra 160"
  @Published var profile = FilmProfile.builtins[0]
  @Published var profiles = FilmProfile.builtins
  @Published var status = "点击「预览」读取胶片"
  @Published var errorText: String?
  @Published var rendering = false
  @Published var detectingFrames = false
  @Published var exporting = false
  @Published var scanQueue = [UUID]()
  @Published private(set) var scanBatch = ScanBatchProgress()
  @Published var histogram = [Double](repeating: 0, count: 64)
  @Published var exportType = "tiff"
  /// Rotate and mirror act on the current frame, or on every frame while syncing.
  @Published var syncOrientation = false
  /// The contact sheet view shows a positive print of the overview, or the raw scan.
  @Published var contactPositive = true
  /// Neutral patches picked with the calibration tool, across frames and rolls of one film.
  @Published var calibrationPoints = [NeutralPoint]()
  @Published var measuringTarget = false
  /// Progress or failure of the last target measurement, shown in the scan tab.
  @Published var sharpeningMessage: String?
  @Published var zoom = 1.0
  /// Where the loupe lies on the light table, as a fraction of the canvas; nil by the edge.
  var loupeCenter: CGPoint?
  @Published var overviewDPI = 150.0
  @Published var physicalMM = CGSize(width: 149.86, height: 246.38)
  @Published var sessionURL: URL?
  @Published var sourceSummary = ""
  @Published var canvasRegion: NormalRect?
  @Published var toneAnalysis: ToneAnalysis?
  @Published var viewportRevision = 0
  @Published var canvasFocusRevision = 0
  private var samplingInput: CGImage?
  private var editRegionLock: NormalRect?
  private var overviewURL: URL?
  private let overviewCache = OverviewCache()
  private var overviewBackendID: String?
  private var overviewInputGamma: Double?
  private var currentScan: UUID?
  private var currentScanReceivedFile = false
  private var scanBatchID = UUID()
  private var activeScanDPI = 2400
  private var cancelRequested = false
  private var revision = 0
  private let renderQueue = DispatchQueue(label: "FilmDesk.render", qos: .userInitiated)
  private var renderWork: DispatchWorkItem?
  private var cancellables = Set<AnyCancellable>()
  private var quitAfterScan = false
  /// A contact sheet waiting for its 1200 dpi scans; the batch's own resolution while it runs.
  private var pendingSheet: (ids: [UUID], url: URL, format: ExportFormat)?
  private var batchDPI: Int?
  /// Scans of this batch to export as positives when it ends.
  private var autoExportIDs = [UUID]()
  private var rollSlopesRevision = 0
  private var exportsRunning = 0
  /// The left panel's tab: scanning and storage, film and presets, or output.
  enum PanelTab: String, CaseIterable { case scan = "扫描", film = "胶片", output = "输出" }
  @Published var panelTab = PanelTab.scan
  /// New previews and imports create their project folders here.
  @Published private(set) var libraryURL: URL
  let preferences: Preferences
  var selectedIndex: Int? { frames.firstIndex { $0.id == selectedID } }
  var selected: FilmFrame? { selectedIndex.map { frames[$0] } }
  var settings: Adjustments { selected?.adjustments ?? Adjustments() }
  var isWorking: Bool {
    scanner.busy || scanBatch.isActive || currentScan != nil || exporting || detectingFrames
  }
  var scanProgressLabel: String { scanBatch.label(frameProgress: scanner.progress) }
  var scanProgressFraction: Double { scanBatch.fraction(frameProgress: scanner.progress) }
  var activityStatus: String {
    scanBatch.isActive ? scanProgressLabel : (scanner.busy ? scanner.status : status)
  }
  var enabledCount: Int { frames.filter(\.enabled).count }
  var hasScanTargets: Bool { frames.contains { $0.enabled && $0.sourcePath == nil } }
  var editingSingle: Bool { singleView && (tool == .crop || tool == .base) }
  var canvasCrop: NormalRect? {
    guard let region = canvasRegion, let selected else { return nil }
    return ImageGeometry.transform(
      selected.rect.relative(to: region), settings: selected.adjustments)
  }
  func fitView() {
    zoom = 1
    viewportRevision += 1
  }
  func focusCanvas() { canvasFocusRevision += 1 }
  func canNavigate(_ offset: Int) -> Bool {
    guard singleView, let i = selectedIndex else { return false }
    return frames.indices.contains(i + offset)
  }
  func navigate(_ offset: Int) {
    guard canNavigate(offset), let i = selectedIndex else { return }
    select(frames[i + offset].id)
    focusCanvas()
  }
  func useTool(_ value: CanvasTool) {
    if value != tool { editRegionLock = nil }
    tool = value
    if value == .loupe || value == .neutral || value == .calibrate { singleView = selected != nil }
    if value == .base || value == .crop { fitView() }
    focusCanvas()
    refresh()
  }
  func commitSingleCrop(_ rect: NormalRect) {
    guard let region = canvasRegion, let selected, !isWorking else { return }
    let raw = ImageGeometry.transform(rect, settings: selected.adjustments, inverse: true)
    setRect(selected.id, rect: NormalRect(raw.mapped(into: region).cg))
  }
  func resetCrop() {
    guard let selected else { return }
    setRect(selected.id, rect: selected.initialRect ?? selected.scanRect ?? selected.rect)
  }
  func adjustCropEdge(_ edge: Int, delta: Double) {
    guard var r = canvasCrop else { return }
    switch edge {
    case 0:
      let end = r.x + r.width
      r.x = clamp(r.x + delta, 0, end - 0.03)
      r.width = end - r.x
    case 1:
      let end = r.y + r.height
      r.y = clamp(r.y + delta, 0, end - 0.03)
      r.height = end - r.y
    case 2: r.width = clamp(r.width + delta, 0.03, 1 - r.x)
    default: r.height = clamp(r.height + delta, 0.03, 1 - r.y)
    }
    commitSingleCrop(r)
  }
  func recalculateWhiteBalance() {
    change {
      $0.autoWhiteBalance = true
      $0.manualBalance = nil
      $0.neutralSample = nil
    }
    status = "已重算白平衡 · 独立校正通道亮暗范围"
  }
  func adjustBase(_ channel: Int, value: Double) {
    change {
      var fine = $0.baseFine ?? .zero
      switch channel {
      case 0: fine.r = value
      case 1: fine.g = value
      default: fine.b = value
      }
      $0.baseFine = fine
    }
  }
  var contactFrames: [FilmFrame] {
    if let path = selected?.sourcePath { return frames.filter { $0.sourcePath == path } }
    return frames.filter { $0.sourcePath == nil }
  }
  init(libraryURL: URL, scanner: ScannerController = ScannerController(), preferences: Preferences = Preferences()) {
    self.libraryURL = libraryURL
    self.scanner = scanner
    self.preferences = preferences
    exportType = preferences.exportFormat.rawValue
    profiles = FilmProfile.builtins + preferences.customProfiles
    preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(
      in: &cancellables)
    scanner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(
      in: &cancellables)
    scanner.onFailure = { [weak self] message in
      guard let self else { return }
      if self.scanBatch.isActive {
        self.stopScanBatch(message: message)
      } else if !self.cancelRequested {
        self.errorText = message
      }
    }
    scanner.onOverview = { [weak self] cg, size, dpi in
      self?.receiveOverview(cg, size: size, dpi: dpi)
    }
    scanner.onScan = { [weak self] url in self?.receiveScan(url) }
    scanner.onFinished = { [weak self] error in self?.finishScan(error) }
  }
  func start() { scanner.start() }
  /// Changes where new projects go. The open project and existing ones stay where they are.
  func setLibrary(_ url: URL) {
    libraryURL = url
    preferences.libraryPath = url.standardizedFileURL == Preferences.defaultLibraryURL.standardizedFileURL ? nil : url.path
    status = "新工程将保存到 \(url.path)"
  }
  func chooseLibrary() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "存储到此文件夹"
    panel.directoryURL = libraryURL
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard FileManager.default.isWritableFile(atPath: url.path) else {
      errorText = "无法写入「\(url.lastPathComponent)」，请选择其他文件夹。"
      return
    }
    setLibrary(url)
  }
  /// Measures a scanned resolution target and keeps the result as the scanner's sharpening profile.
  func importSharpeningTarget() {
    guard !measuringTarget else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.tiff, .png]
    panel.message = "选择分辨率标靶的扫描文件，建议用你最常用的最高 dpi 扫描"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    measuringTarget = true
    sharpeningMessage = "正在测量 \(url.lastPathComponent)…"
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let profile = try TargetMeasurement.measure(url)
        DispatchQueue.main.async {
          self.measuringTarget = false
          self.sharpeningMessage = nil
          self.preferences.sharpening = profile
          self.refresh()
        }
      } catch {
        DispatchQueue.main.async {
          self.measuringTarget = false
          self.sharpeningMessage = error.localizedDescription
        }
      }
    }
  }
  func removeSharpeningProfile() {
    preferences.sharpening = nil
    sharpeningMessage = nil
    refresh()
  }
  func makeSession() throws -> URL {
    if let sessionURL { return sessionURL }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    let root = libraryURL.appendingPathComponent(
      formatter.string(from: Date()) + "_" + UUID().uuidString.prefix(4))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    sessionURL = root
    return root
  }
  func requestPreview() {
    guard !isWorking else { return }
    cancelRequested = false
    scanner.previewDPI = preferences.previewDPI
    scanner.preview()
  }
  func receiveOverview(_ cg: CGImage, size: CGSize, dpi: Double) {
    do {
      sessionURL = nil
      frames = []
      thumbnails = [:]
      selectedID = nil
      let root = try makeSession()
      // Uncompressed: a 600 dpi preview writes in a tenth of a second, as PNG it takes two.
      let url = root.appendingPathComponent("overview.tif")
      try ImagePipeline.shared.saveTIFF(cg, to: url, dpi: Int(dpi))
      overviewCache.keep(cg, for: url)
      // Frame detection, statistics and the contact view work on at most 2200 px, as when a
      // project is opened; crops of single frames come from the full resolution.
      overview = ImagePipeline.shared.scaled(cg, maxDimension: 2200)
      overviewURL = url
      physicalMM = size
      overviewDPI = dpi
      overviewBackendID = scanner.backendID
      overviewInputGamma = scanner.captureInputGamma
      singleView = false
      showNegative = false
      sourceSummary = "透扫预览 · \(Int(dpi)) dpi"
      detectFrames(enterSingle: true)
    } catch { errorText = error.localizedDescription }
  }
  func detectFrames(enterSingle: Bool = false) {
    guard let overview, !isWorking else { return }
    if frames.contains(where: { $0.hasFullResolution }) {
      let a = NSAlert()
      a.messageText = "重新识别画面？"
      a.informativeText = "当前裁切和逐张调整将被替换，原始文件仍保留在工程文件夹中。"
      a.addButton(withTitle: "重新识别")
      a.addButton(withTitle: "取消")
      guard a.runModal() == .alertFirstButtonReturn else { return }
    }
    rendering = true
    detectingFrames = true
    status = "正在识别画面…"
    let size = physicalMM
    let format = format
    let importedPath = frames.first?.sourcePath
    let inputGamma = overviewInputGamma
    renderQueue.async {
      var found = FrameDetector.detect(overview, physicalMM: size, format: format)
      if importedPath == nil, let inputGamma {
        for i in found.indices { found[i].adjustments.inputGamma = inputGamma }
      }
      if let path = importedPath {
        let info = ImagePipeline.shared.info(URL(fileURLWithPath: path))
        for i in found.indices {
          found[i].sourcePath = path
          found[i].scanDPI = Int(info.dpi > 0 ? info.dpi : 2400)
          found[i].sourceBits = info.bits
        }
      }
      DispatchQueue.main.async {
        self.frames = found
        self.selectedID = found.first?.id
        self.detectingFrames = false
        self.tool = .select
        self.editRegionLock = nil
        if enterSingle { self.singleView = !found.isEmpty }
        self.fitView()
        self.focusCanvas()
        self.rendering = false
        self.status = found.isEmpty ? "没有识别到画面，可用「画框」手动选择" : "识别到 \(found.count) 张 · 拖动边角可微调"
        self.updateRollBase()
        self.updateRollSlopes()
        self.refresh()
        self.updateThumbnails()
        self.saveProject()
      }
    }
  }
  func select(_ id: UUID) {
    if selectedID != id {
      fitView()
      editRegionLock = nil
    }
    selectedID = id
    if let path = selected?.sourcePath, path != overviewURL?.path {
      let url = URL(fileURLWithPath: path)
      if let image = try? ImagePipeline.shared.load(url, maxDimension: 2200) {
        overview = image
        overviewURL = url
        let info = ImagePipeline.shared.info(url)
        overviewDPI = info.dpi > 0 ? info.dpi : Double(dpi)
        physicalMM = CGSize(
          width: Double(info.width) / overviewDPI * 25.4,
          height: Double(info.height) / overviewDPI * 25.4)
      }
    }
    refresh()
  }
  func tightenExistingBorders() {
    guard let overview, !isWorking, !rendering, selected?.sourcePath == nil, !frames.isEmpty else {
      return
    }
    rendering = true
    detectingFrames = true
    let size = physicalMM
    let format = format
    let snapshot = frames
    status = "正在收紧片边…"
    renderQueue.async {
      let detected = FrameDetector.detect(overview, physicalMM: size, format: format)
      DispatchQueue.main.async {
        var changed = 0
        for old in snapshot where old.sourcePath == nil {
          guard let index = self.frames.firstIndex(where: { $0.id == old.id }),
            self.frames[index].rect == old.rect
          else { continue }
          let match = detected.max { a, b in
            a.rect.cg.intersection(old.rect.cg).area < b.rect.cg.intersection(old.rect.cg).area
          }
          guard let match else { continue }
          let intersection = old.rect.cg.intersection(match.rect.cg)
          // Only contract a well-matched existing frame. Keep manual crops and all settings.
          guard !intersection.isNull, intersection.area > old.rect.cg.area * 0.70,
            old.rect.cg.area - intersection.area > 0.000001
          else { continue }
          if old.scanPath != nil && old.scanRect == nil { self.frames[index].scanRect = old.rect }
          if old.initialRect == nil { self.frames[index].initialRect = old.rect }
          self.frames[index].rect = NormalRect(intersection)
          changed += 1
        }
        self.rendering = false
        self.detectingFrames = false
        self.editRegionLock = nil
        self.fitView()
        self.focusCanvas()
        self.updateRollBase()
        self.updateRollSlopes()
        self.refresh()
        self.updateThumbnails()
        self.saveProject()
        self.status = "已收紧 \(changed) 张的片边 · 调色和原始扫描保留"
      }
    }
  }
  func setRect(_ id: UUID, rect: NormalRect) {
    guard let i = frames.firstIndex(where: { $0.id == id }), rect.width > 0.005, rect.height > 0.005
    else { return }
    let old = frames[i].rect
    guard
      abs(old.x - rect.x) + abs(old.y - rect.y) + abs(old.width - rect.width)
        + abs(old.height - rect.height) > 0.000001
    else { return }
    if frames[i].scanPath != nil && frames[i].scanRect == nil { frames[i].scanRect = old }
    if frames[i].initialRect == nil { frames[i].initialRect = old }
    frames[i].rect = rect
    status = frames[i].needsRescan ? "范围超出原始扫描 · 需重新扫描，原文件仍保留" : "裁切已更新 · 原始文件未改动"
    updateRollBase()
    refresh()
    saveProject()
    updateThumbnails()
  }
  func addFrame(_ rect: NormalRect) {
    guard rect.width > 0.008, rect.height > 0.008 else { return }
    var f = FilmFrame(
      name: String(format: "%02d", frames.count + 1), rect: rect, format: format.rawValue)
    if let selected, let path = selected.sourcePath {
      f.sourcePath = path
      f.scanDPI = selected.scanDPI
      f.sourceBits = selected.sourceBits
    }
    frames.append(f)
    selectedID = f.id
    tool = .select
    updateRollBase()
    updateRollSlopes()
    refresh()
    updateThumbnails()
    saveProject()
  }
  func removeSelected() {
    guard let i = selectedIndex, !isWorking else { return }
    thumbnails[frames[i].id] = nil
    frames.remove(at: i)
    selectedID = frames.first?.id
    updateRollBase()
    updateRollSlopes()
    refresh()
    saveProject()
  }
  func toggleEnabled(_ id: UUID) {
    guard let i = frames.firstIndex(where: { $0.id == id }) else { return }
    setEnabled(id, enabled: !frames[i].enabled)
  }
  func setEnabled(_ id: UUID, enabled: Bool) {
    guard !isWorking, let i = frames.firstIndex(where: { $0.id == id }),
      frames[i].enabled != enabled
    else { return }
    frames[i].enabled = enabled
    saveProject()
    focusCanvas()
  }
  func setAllEnabled(_ enabled: Bool) {
    guard !isWorking, !frames.isEmpty else { return }
    for i in frames.indices { frames[i].enabled = enabled }
    saveProject()
    focusCanvas()
    status = enabled ? "已勾选全部 \(frames.count) 张 · 用于扫描 / 导出" : "已取消全部勾选 · 当前照片仍保留"
  }
  func change(_ mutation: (inout Adjustments) -> Void) {
    guard let i = selectedIndex else { return }
    // The roll's measured base belongs to the film, so even a reset keeps it.
    let rollBase = frames[i].adjustments.rollBase, rollSlopes = frames[i].adjustments.rollSlopes
    mutation(&frames[i].adjustments)
    frames[i].adjustments.rollBase = rollBase
    frames[i].adjustments.rollSlopes = rollSlopes
    refresh()
    saveProject()
  }
  /// Measures the film base between the frames on the current overview and shares it with
  /// them. Only for overviews whose values match the frames' scans: this app's 48-bit
  /// previews, or an imported strip the frames are cut from. Other frames keep theirs.
  private func updateRollBase() {
    guard let overview else { return }
    let onOverview = frames.indices.filter {
      frames[$0].sourcePath == nil ? overviewBackendID == "epson2-linear-v1" : frames[$0].sourcePath == overviewURL?.path
    }
    guard !onOverview.isEmpty else { return }
    let base = ImagePipeline.shared.rollBase(overview, frames: onOverview.map { frames[$0] })
    for i in onOverview { frames[i].adjustments.rollBase = base }
  }
  /// Each frame turns from its own orientation, so portrait frames stay portrait.
  func turn(clockwise: Bool) {
    orient(clockwise ? "顺时针旋转 90°" : "逆时针旋转 90°") { $0.turn(clockwise: clockwise) }
  }
  /// The mirror corrects how the whole strip lay in the holder, so syncing sets one value.
  func toggleMirror() {
    let mirrored = settings.flipHorizontal != true
    orient(mirrored ? "水平镜像" : "取消水平镜像") { $0.flipHorizontal = mirrored }
  }
  private func orient(_ action: String, _ mutation: (inout Adjustments) -> Void) {
    if syncOrientation {
      guard !frames.isEmpty else { return }
      for i in frames.indices { mutation(&frames[i].adjustments) }
      status = "已对全部 \(frames.count) 张\(action)"
    } else {
      guard let i = selectedIndex else { return }
      mutation(&frames[i].adjustments)
    }
    refresh()
    updateThumbnails()
    saveProject()
  }
  func applyToRoll() {
    guard let s = selected else { return }
    for i in frames.indices {
      let own = frames[i].adjustments
      frames[i].adjustments = s.adjustments
      frames[i].adjustments.rotation = own.rotation
      frames[i].adjustments.rollBase = own.rollBase
      frames[i].adjustments.rollSlopes = own.rollSlopes
    }
    refresh()
    updateThumbnails()
    saveProject()
    status = "已同步调色参数到本卷"
  }
  func matchFilm() {
    let q = filmName.lowercased().replacingOccurrences(of: " ", with: "")
    let found =
      profiles.first { p in
        ([p.name] + p.aliases).contains {
          $0.lowercased().replacingOccurrences(of: " ", with: "") == q
        }
      } ?? FilmProfile.builtins.last!
    // A film calibrated on this scanner is used without having to pick it.
    profile = calibrated(for: found) ?? found
    updateRollSlopes()
    refresh()
    updateThumbnails()
    saveProject()
  }
  /// The newest preset calibrated on this scanner from `film`, if any.
  func calibrated(for film: FilmProfile) -> FilmProfile? {
    film.offsets != nil ? nil : profiles.last { $0.offsets != nil && $0.name == film.name + " · V850" }
  }
  func chooseProfile(_ p: FilmProfile) {
    filmName = p.name
    profile = p
    updateRollSlopes()
    refresh()
    updateThumbnails()
    saveProject()
  }
  /// Estimates channel slopes across each roll — the scanned frames, or each imported file — and
  /// shares them with its frames. They are the fallback when the preset is not calibrated.
  func updateRollSlopes(completion: (() -> Void)? = nil) {
    let snapshot = frames, green = profile.slopes.g
    rollSlopesRevision += 1
    let token = rollSlopesRevision
    renderQueue.async {
      var result = [UUID: RGB?]()
      for (_, members) in Dictionary(grouping: snapshot, by: { $0.sourcePath ?? "" }) {
        let inputs = members.compactMap { f in
          (try? self.source(for: f, maxDimension: 600)).map { (image: $0, settings: f.adjustments) }
        }
        let slopes = ImagePipeline.shared.rollSlopes(inputs, greenSlope: green)
        for f in members { result[f.id] = .some(slopes) }
      }
      DispatchQueue.main.async {
        // A newer estimate is on its way; still let the caller go on.
        guard token == self.rollSlopesRevision else {
          completion?()
          return
        }
        for i in self.frames.indices {
          if let slopes = result[self.frames[i].id] { self.frames[i].adjustments.rollSlopes = slopes }
        }
        self.refresh()
        self.updateThumbnails()
        self.saveProject()
        completion?()
      }
    }
  }
  func importProfile() {
    let p = NSOpenPanel()
    p.allowedContentTypes = [.json]
    p.allowsMultipleSelection = false
    guard p.runModal() == .OK, let url = p.url else { return }
    do {
      let profile = try JSONDecoder().decode(FilmProfile.self, from: Data(contentsOf: url))
      try profile.validate()
      keepProfile(profile)
      chooseProfile(profile)
    } catch { errorText = error.localizedDescription }
  }
  /// Adds a preset to the list and to settings, replacing one with the same ID.
  func keepProfile(_ profile: FilmProfile) {
    preferences.customProfiles.removeAll { $0.id == profile.id }
    preferences.customProfiles.append(profile)
    profiles = FilmProfile.builtins + preferences.customProfiles
  }
  func deleteCustomProfile(_ id: String) {
    preferences.customProfiles.removeAll { $0.id == id }
    profiles = FilmProfile.builtins + preferences.customProfiles
  }
  func exportProfile(_ profile: FilmProfile) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = profile.id + ".json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let e = JSONEncoder()
      e.outputFormatting = [.prettyPrinted, .sortedKeys]
      try e.encode(profile).write(to: url, options: .atomic)
    } catch { errorText = error.localizedDescription }
  }
  /// Solves this scanner's preset for the current film from the picked neutral points, keeps it
  /// and applies it to the project. The current preset supplies the film and the green slope.
  func makeScannerPreset() {
    do {
      let fit = try FilmCalibration.fit(calibrationPoints, greenSlope: profile.slopes.g)
      let made = FilmCalibration.profile(from: fit, basedOn: profile, points: calibrationPoints.count, scanner: scanner.name)
      try made.validate()
      keepProfile(made)
      calibrationPoints = []
      if tool == .calibrate { tool = .select }
      chooseProfile(made)
      status = String(
        format: "已生成预设「%@」· R %.3f · G %.3f · B %.3f · 残差 %.3f D", made.name, fit.slopes.r, fit.slopes.g,
        fit.slopes.b, fit.residual)
    } catch { errorText = error.localizedDescription }
  }
  func clearCalibration() {
    calibrationPoints = []
    if tool == .calibrate { useTool(.select) }
  }
  /// `maxDimension` overrides the preview size, for statistics that need less.
  func source(for frame: FilmFrame, full: Bool = false, maxDimension: Int? = nil) throws -> CGImage {
    if let path = frame.scanPath, frame.hasFullResolution {
      let raw = try ImagePipeline.shared.load(
        URL(fileURLWithPath: path), maxDimension: full ? nil : maxDimension ?? 2200)
      return try ImagePipeline.shared.crop(raw, rect: frame.rect.relative(to: frame.captureRect))
    }
    if let path = frame.sourcePath {
      let image = try ImagePipeline.shared.load(
        URL(fileURLWithPath: path), maxDimension: full ? nil : maxDimension ?? 3000)
      return try ImagePipeline.shared.crop(image, rect: frame.rect)
    }
    guard let url = overviewURL else { throw DeskError.message("尚无图像。") }
    // Cropped from the full resolution first, so each frame keeps all of a 600 dpi preview.
    let crop = try ImagePipeline.shared.crop(overviewCache.image(url), rect: frame.rect)
    let limit = full ? nil : maxDimension ?? 2200
    return limit.map { ImagePipeline.shared.scaled(crop, maxDimension: $0) } ?? crop
  }
  func contextSource(for frame: FilmFrame) throws -> (image: CGImage, region: NormalRect) {
    let pipe = ImagePipeline.shared
    if let path = frame.sourcePath {
      return (try pipe.load(URL(fileURLWithPath: path), maxDimension: 3000), .full)
    }
    if let path = frame.scanPath, frame.hasFullResolution {
      return (try pipe.load(URL(fileURLWithPath: path), maxDimension: 3000), frame.captureRect)
    }
    guard let url = overviewURL else { throw DeskError.message("尚无图像。") }
    let region = editRegionLock ?? frame.rect.expanded(by: 0.14)
    return (pipe.scaled(try pipe.crop(overviewCache.image(url), rect: region), maxDimension: 3000), region)
  }
  /// The frame under the light table's loupe as the contact view shows it, positive or raw, but
  /// from the frame's own pixels: its scan, or the full-resolution preview.
  func loupeDetail(for frame: FilmFrame, completion: @escaping (CGImage?) -> Void) {
    let positive = contactPositive, p = profile
    renderQueue.async {
      var image = try? self.source(for: frame, maxDimension: 2400)
      if positive, let crop = image {
        // Upright, as in the contact print, so it lies under its frame box.
        var s = frame.adjustments
        s.rotation = 0
        s.flipHorizontal = nil
        image = try? ImagePipeline.shared.preview(crop, settings: s, profile: p)
      }
      DispatchQueue.main.async { completion(image) }
    }
  }
  /// Changes whenever the loupe's picture of `frame` would.
  func loupeDetailKey(_ frame: FilmFrame) -> String {
    let settings = (try? JSONEncoder().encode(frame.adjustments)).map { $0.base64EncodedString() } ?? ""
    return [frame.id.uuidString, "\(frame.rect)", frame.scanPath ?? "", "\(contactPositive)", profile.id, settings]
      .joined(separator: "|")
  }
  func refresh() {
    revision += 1
    let token = revision
    renderWork?.cancel()
    guard singleView, let frame = selected else {
      canvasRegion = nil
      samplingInput = nil
      toneAnalysis = nil
      // Frames that lie on the displayed overview; imports from other files are not on it.
      let onOverview = frames.filter { $0.sourcePath == nil || $0.sourcePath == overviewURL?.path }
      guard contactPositive, let overview, !onOverview.isEmpty else {
        displayed = overview
        rendering = false
        return
      }
      // Keep a previous print while re-rendering, so dragging a frame box does not flicker.
      if displayed?.width != overview.width || displayed?.height != overview.height { displayed = overview }
      let p = profile
      rendering = true
      let work = DispatchWorkItem { [weak self] in
        let print = ImagePipeline.shared.contactPrint(overview, frames: onOverview, profile: p)
        DispatchQueue.main.async {
          guard let self, self.revision == token else { return }
          self.displayed = print ?? overview
          self.rendering = false
        }
      }
      renderWork = work
      renderQueue.asyncAfter(deadline: .now() + 0.07, execute: work)
      return
    }
    let p = profile
    let edit = editingSingle
    if !edit { editRegionLock = nil }
    let negative = showNegative || tool == .base
    let full = tool == .loupe
    let sharpening = preferences.sharpening
    rendering = true
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      do {
        let cropped = try self.source(for: frame, full: full)
        let analysis = ImagePipeline.shared.analyze(
          cropped, settings: frame.adjustments, profile: p)
        let context = edit ? try self.contextSource(for: frame) : nil
        let input = context?.image ?? cropped
        // The kernel follows the size the source was loaded at, as in source(for:) and contextSource(for:).
        let loaded = edit ? 3000 : full ? nil : (frame.sourcePath != nil ? 3000 : 2200)
        let sharpener = negative ? nil : Sharpening.sharpener(sharpening, frame: frame, maxDimension: loaded)
        guard
          let output = ImagePipeline.shared.render(
            input, settings: frame.adjustments, profile: p, analysis: analysis, negative: negative,
            sharpener: sharpener)
        else { throw DeskError.message("无法生成预览") }
        let r = ImagePipeline.shared.raster(output, maxDimension: 250)
        var hist = [Double](repeating: 0, count: 64)
        for y in 0..<r.height {
          for x in 0..<r.width {
            let c = r.pixel(x, y)
            let l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            hist[min(63, Int(l * 63))] += 1
          }
        }
        let maxBin = hist.max() ?? 1
        hist = hist.map { $0 / max(1, maxBin) }
        var pixels = CGSize(width: input.width, height: input.height)
        if frame.hasFullResolution, let path = frame.scanPath ?? frame.sourcePath {
          let info = ImagePipeline.shared.info(URL(fileURLWithPath: path))
          pixels =
            frame.scanPath != nil
            ? frame.rect.relative(to: frame.captureRect).pixels(
              CGSize(width: info.width, height: info.height)
            ).size
            : frame.rect.pixels(CGSize(width: info.width, height: info.height)).size
        }
        let summary =
          "\(Int(pixels.width)) × \(Int(pixels.height)) · \(frame.hasFullResolution ? (frame.scanDPI.map{String($0)+" dpi"} ?? "源图") : "低清预览")"
        DispatchQueue.main.async {
          guard self.revision == token else { return }
          self.displayed = output
          self.canvasRegion = context?.region
          self.samplingInput = input
          self.toneAnalysis = analysis
          if edit { self.editRegionLock = context?.region }
          if !edit && !negative && !full { self.thumbnails[frame.id] = output }
          self.histogram = hist
          self.rendering = false
          self.sourceSummary = summary
        }
      } catch {
        DispatchQueue.main.async {
          guard self.revision == token else { return }
          self.errorText = error.localizedDescription
          self.rendering = false
        }
      }
    }
    renderWork = work
    renderQueue.asyncAfter(deadline: .now() + 0.07, execute: work)
  }
  func updateThumbnails() {
    guard overview != nil else { return }
    let snapshot = frames
    let p = profile
    renderQueue.async {
      var result = [UUID: CGImage]()
      for f in snapshot {
        if let input = try? self.source(for: f),
          let positive = try? ImagePipeline.shared.preview(
            input, settings: f.adjustments, profile: p)
        {
          result[f.id] = positive
        }
      }
      DispatchQueue.main.async { self.thumbnails = result }
    }
  }
  func sample(_ point: CGPoint) {
    guard let i = selectedIndex, !rendering else { return }
    let input: CGImage
    if singleView {
      guard let samplingInput else { return }
      input = samplingInput
    } else {
      guard let overview else { return }
      input = overview
    }
    let r = ImagePipeline.shared.samples(input, maxDimension: 2000)
    let pt = singleView ? ImageGeometry.raw(point, settings: frames[i].adjustments) : point
    let x = Int(pt.x * Double(r.width))
    let y = Int(pt.y * Double(r.height))
    var sum = [Double](repeating: 0, count: 3)
    var n = 0.0
    // A large fixed 7×7 window can mix a thin film-base strip with image content.
    let radius = max(1, min(3, Int(Double(min(r.width, r.height)) * 0.006)))
    for dy in -radius...radius {
      for dx in -radius...radius {
        let p = r.pixel(x + dx, y + dy).values
        for c in 0..<3 { sum[c] += p[c] }
        n += 1
      }
    }
    let color = RGB(sum.map { $0 / n })
    if tool == .calibrate {
      // Keep the tool for the next point. The base is the one this frame converts with.
      guard singleView, let analysis = toneAnalysis else { return }
      let fine = frames[i].adjustments.baseFine ?? .zero
      let point = NeutralPoint(
        frame: frames[i].id, value: color,
        base: RGB((0..<3).map { analysis.base.values[$0] * pow(2, fine.values[$0]) }),
        gamma: frames[i].adjustments.inputGamma)
      calibrationPoints.append(point)
      let span = calibrationPoints.map { $0.density[1] }
      status = String(
        format: "已取 %d 个中性点 · 本点绿色密度 %.2f · 跨度 %.2f D", calibrationPoints.count, point.density[1],
        (span.max() ?? 0) - (span.min() ?? 0))
      return
    }
    if tool == .base {
      frames[i].adjustments.base = color
      frames[i].adjustments.baseFine = nil
      frames[i].adjustments.manualBalance = nil
      frames[i].adjustments.neutralSample = nil
      frames[i].adjustments.autoWhiteBalance = false
      status = "已取片基 · 自动白平衡已关闭以保留取样，可按需重算"
    } else if tool == .neutral {
      frames[i].adjustments.manualBalance = nil
      frames[i].adjustments.neutralSample = color
      frames[i].adjustments.autoWhiteBalance = false
      status = "已设置中性点"
    }
    tool = .select
    refresh()
    saveProject()
    updateThumbnails()
  }
  func scanEnabled() {
    guard !isWorking else { return }
    startScanBatch(frames.filter { $0.enabled && $0.sourcePath == nil }.map(\.id))
  }
  func scanSelected() {
    guard let id = selectedID, !isWorking else { return }
    guard selected?.sourcePath == nil else {
      errorText = "导入的图像已是原始文件，无需重新扫描。"
      return
    }
    startScanBatch([id])
  }
  /// `dpi` overrides the selected resolution for this batch only.
  private func startScanBatch(_ ids: [UUID], dpi batchDPI: Int? = nil) {
    guard !ids.isEmpty else { return }
    if scanner.backendID == "epson2-linear-v1" && overviewBackendID != scanner.backendID {
      errorText = "使用 48-bit 接口前请重新预览，建立匹配的扫描坐标与线性片基。重新预览会创建新工程，旧工程和原图仍保留。"
      return
    }
    self.batchDPI = batchDPI
    scanQueue = ids
    scanBatchID = UUID()
    scanBatch = ScanBatchProgress(total: ids.count)
    cancelRequested = false
    errorText = nil
    nextScan()
  }
  private func nextScan() {
    guard scanBatch.phase == .running, !scanQueue.isEmpty, !scanner.busy,
      currentScan == nil
    else { return }
    let id = scanQueue.removeFirst()
    guard let frame = frames.first(where: { $0.id == id }) else {
      stopScanBatch(message: "待扫描的画面已不存在。")
      return
    }
    do {
      let root = try makeSession()
      let raw = root.appendingPathComponent("Originals")
      try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
      currentScan = id
      currentScanReceivedFile = false
      scanBatch.beginFrame()
      activeScanDPI = batchDPI ?? dpi
      let captureRect: NormalRect
      if scanner.backendID == "epson2-linear-v1" {
        captureRect = NormalRect(x: frame.rect.x * physicalMM.width / scanner.physicalMM.width,
          y: frame.rect.y * physicalMM.height / scanner.physicalMM.height,
          width: frame.rect.width * physicalMM.width / scanner.physicalMM.width,
          height: frame.rect.height * physicalMM.height / scanner.physicalMM.height)
      } else { captureRect = frame.rect }
      try scanner.scan(
        rect: captureRect, dpi: activeScanDPI, directory: raw,
        name: "\(frame.name)_\(activeScanDPI)dpi_\(UUID().uuidString.prefix(6))")
    } catch {
      stopScanBatch(message: error.localizedDescription)
    }
  }
  private func finishScan(_ error: Error?) {
    guard scanBatch.isActive else { return }  // A driver can report the same failure twice.
    if let error {
      stopScanBatch(message: error.localizedDescription)
      return
    }
    guard currentScan != nil else { return }
    guard currentScanReceivedFile else {
      stopScanBatch(message: "驱动结束扫描，但没有返回可读取的图像文件。")
      return
    }
    let scanned = currentScan
    currentScan = nil
    currentScanReceivedFile = false
    scanBatch.completeFrame()
    if cancelRequested { scanBatch.stop(cancelled: true) }
    status = scanBatch.summary
    saveProject()
    // The scan itself stays a raw negative. Its positive is exported when the batch ends, once the
    // roll estimate has taken the new scans in, so the file matches what the app shows. Scans
    // made for a contact sheet only feed the sheet.
    if preferences.autoExport, pendingSheet == nil, let scanned { autoExportIDs.append(scanned) }
    guard scanBatch.isActive else {
      endBatch()
      return
    }
    let batchID = scanBatchID
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      guard let self, self.scanBatchID == batchID else { return }
      self.nextScan()
    }
  }
  private func stopScanBatch(message: String? = nil) {
    scanQueue = []
    currentScan = nil
    currentScanReceivedFile = false
    scanBatch.stop(cancelled: cancelRequested)
    status = scanBatch.summary
    if let message, !cancelRequested {
      errorText = message
      status += " · " + message
    }
    saveProject()
    endBatch()
  }
  /// A finished batch hands its scans to a waiting contact sheet; a stopped one drops it.
  /// Either way the new scans refine the roll's slope estimate, and then go to Exports.
  private func endBatch() {
    batchDPI = nil
    let exports = autoExportIDs
    autoExportIDs = []
    if scanBatch.completed > 0 { updateRollSlopes { [weak self] in self?.exportScans(exports) } }
    if !exports.isEmpty { status += " · 正在导出正片到 Exports…" }
    guard let sheet = pendingSheet else { return }
    pendingSheet = nil
    if scanBatch.phase == .completed {
      composeContactSheet(ids: sheet.ids, to: sheet.url, format: sheet.format)
    } else {
      status += " · 接触表未生成"
    }
  }
  /// Exports finished scans as positives into the project's Exports folder.
  private func exportScans(_ ids: [UUID]) {
    let items = frames.filter { ids.contains($0.id) }
    guard !items.isEmpty, let root = sessionURL else { return }
    export(items: items, to: root.appendingPathComponent("Exports"))
  }
  private func receiveScan(_ url: URL) {
    guard let id = currentScan, let i = frames.firstIndex(where: { $0.id == id }) else { return }
    let info = ImagePipeline.shared.info(url)
    guard info.width > 0, info.height > 0, info.bits > 0 else { return }
    currentScanReceivedFile = true
    frames[i].scanPath = url.path
    frames[i].scanRect = frames[i].rect
    if let area = scanner.actualScanAreaMM {
      frames[i].scanRect = NormalRect(x: area.minX / physicalMM.width, y: area.minY / physicalMM.height,
        width: area.width / physicalMM.width, height: area.height / physicalMM.height)
    }
    frames[i].sourcePath = nil
    frames[i].scanDPI = activeScanDPI
    frames[i].sourceBits = info.bits
    status = "第 \(frames[i].name) 张扫描完成 · \(info.bits*3)-bit 原始负片已存入 Originals"
      + (preferences.autoExport && pendingSheet == nil ? " · 整批扫完后正片导出到 Exports" : " · 正片请在「输出」导出")
    saveProject()
    if id == selectedID { refresh() }
    updateThumbnails()
  }
  func cancel() {
    scanQueue = []
    cancelRequested = true
    scanBatch.requestCancellation()
    if scanBatch.isActive && !scanner.busy { stopScanBatch() }
    if scanner.busy { scanner.cancel() }
  }
  /// Quitting mid-scan cancels, then waits until the helper has drained the transfer and
  /// released USB, so nothing else opens the scanner while it is still moving.
  /// Returns false when the app can quit at once.
  func finishScanBeforeQuit(then quit: @escaping () -> Void) -> Bool {
    guard scanner.busy, scanner.finishesScanBeforeQuit else { return false }
    guard !quitAfterScan else { return true }
    quitAfterScan = true
    cancel()
    scanner.status = "等待当前扫描完成归位后退出，请勿关闭扫描仪或打开其他扫描程序…"
    scanner.$busy.first { !$0 }.receive(on: DispatchQueue.main).sink { _ in quit() }
      .store(in: &cancellables)
    return true
  }
  func importImages() {
    guard !isWorking else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.tiff, .png, .jpeg]
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    importURLs(panel.urls)
  }
  func importURLs(_ urls: [URL]) {
    guard let first = urls.first else { return }
    do {
      sessionURL = nil
      let root = try makeSession()
      let src = root.appendingPathComponent("Originals")
      try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
      frames = []
      thumbnails = [:]
      for (idx, url) in urls.enumerated() {
        let dest = src.appendingPathComponent("\(idx+1)_" + url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        let info = ImagePipeline.shared.info(dest)
        var f = FilmFrame(name: String(format: "%02d", idx + 1), rect: .full, format: "导入")
        f.sourcePath = dest.path
        f.scanDPI = Int(info.dpi > 0 ? info.dpi : Double(dpi))
        f.sourceBits = info.bits
        frames.append(f)
        if idx == 0 {
          overviewURL = dest
          overview = try ImagePipeline.shared.load(dest, maxDimension: 2200)
          overviewDPI = info.dpi > 0 ? info.dpi : Double(dpi)
          physicalMM = CGSize(
            width: Double(info.width) / overviewDPI * 25.4,
            height: Double(info.height) / overviewDPI * 25.4)
        }
      }
      selectedID = frames.first?.id
      singleView = true
      showNegative = false
      status = "导入 \(urls.count) 张 · \(first.lastPathComponent)"
      refresh()
      updateThumbnails()
      updateRollSlopes()
      saveProject()
    } catch { errorText = error.localizedDescription }
  }
  func exportImages(all: Bool) {
    let items = all ? frames.filter(\.enabled) : (selected.map { [$0] } ?? [])
    guard !items.isEmpty, !isWorking else { return }
    let previews = items.filter { !$0.hasFullResolution }.count
    if previews > 0 {
      let alert = NSAlert()
      alert.messageText = "包含 \(previews) 张低清预览"
      alert.informativeText = "这些画面尚未正式扫描。导出不会增加实际细节；如需成片，请先扫描。"
      alert.addButton(withTitle: "仅导出预览 / 继续")
      alert.addButton(withTitle: "取消")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "导出到此文件夹"
    panel.directoryURL = sessionURL
    // The format is chosen with the destination and becomes the default in the output tab.
    let chooser = FormatChooser(selected: ExportFormat(rawValue: exportType) ?? .tiff)
    chooser.attach(to: panel)
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    exportType = chooser.format.rawValue
    preferences.exportFormat = chooser.format
    export(items: items, to: folder)
  }
  /// Exports can overlap (an auto-export while the next scan runs), so `exporting` counts them.
  private func beginExport() {
    exportsRunning += 1
    exporting = true
  }
  private func endExport() {
    exportsRunning = max(0, exportsRunning - 1)
    exporting = exportsRunning > 0
  }
  func export(items: [FilmFrame], to directory: URL, completion: (() -> Void)? = nil) {
    beginExport()
    let p = profile
    let format = ExportFormat(rawValue: exportType) ?? .tiff
    let quality = preferences.jpegQuality
    let sharpening = preferences.sharpening
    renderQueue.async {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for f in items {
          let image = try self.source(for: f, full: true)
          let sharpener = Sharpening.sharpener(sharpening, frame: f, maxDimension: nil)
          let safeName = String(
            f.name.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" }.prefix(
              40))
          let file = "\(p.id)_\(safeName)_\(UUID().uuidString.prefix(6)).\(format.fileExtension)"
          let url = directory.appendingPathComponent(file)
          try ImagePipeline.shared.export(
            image, settings: f.adjustments, profile: p, url: url, format: format,
            dpi: f.hasFullResolution ? (f.scanDPI ?? Int(self.overviewDPI)) : Int(self.overviewDPI),
            quality: quality, sharpener: sharpener)
          let sidecar = ExportRecord(
            profile: p, frame: f,
            source: f.hasFullResolution
              ? (f.scanPath ?? f.sourcePath ?? "") : (self.overviewURL?.path ?? ""),
            isPreview: !f.hasFullResolution)
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          try encoder.encode(sidecar).write(
            to: url.appendingPathExtension("json"), options: .atomic)
        }
        DispatchQueue.main.async {
          self.endExport()
          self.status = "已导出 \(items.count) 张到 \(directory.lastPathComponent)"
          completion?()
        }
      } catch {
        DispatchQueue.main.async {
          self.endExport()
          self.errorText = error.localizedDescription
          completion?()
        }
      }
    }
  }
  /// Exports the ticked frames as one contact sheet. Frames without a scan of at least 1200 dpi
  /// are first scanned at 1200 dpi, and those scans become their originals.
  func exportContactSheet() {
    guard !isWorking else { return }
    let items = frames.filter(\.enabled)
    guard !items.isEmpty else {
      errorText = "请先勾选要放进接触表的画面。"
      return
    }
    let needScan = items.filter {
      $0.sourcePath == nil && !($0.hasFullResolution && ($0.scanDPI ?? 0) >= ContactSheet.scanDPI)
    }
    var usePreviews = false
    if !needScan.isEmpty {
      let ready = scanner.ready && !(scanner.backendID == "epson2-linear-v1" && overviewBackendID != scanner.backendID)
      let alert = NSAlert()
      if ready {
        alert.messageText = "先以 1200 dpi 扫描 \(needScan.count) 张，再生成接触表？"
        alert.informativeText = "接触表共 \(items.count) 张。尚未扫描或低于 1200 dpi 的画面会先扫描，结果保存为这些画面的原始文件；已有 1200 dpi 及以上扫描的画面直接使用。"
        alert.addButton(withTitle: "扫描并生成")
      } else {
        alert.messageText = "扫描仪未就绪"
        alert.informativeText = "有 \(needScan.count) 张需要以 1200 dpi 扫描。可以先用现有的低清预览生成接触表，细节会比较模糊。"
        alert.addButton(withTitle: "用低清预览生成")
      }
      alert.addButton(withTitle: "取消")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      usePreviews = !ready
    }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.directoryURL = sessionURL ?? libraryURL
    let date = Date().formatted(.iso8601.year().month().day())
    let safeFilm = String(filmName.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(40))
    panel.nameFieldStringValue = "接触表_\(safeFilm)_\(date)"
    let chooser = FormatChooser(selected: preferences.exportFormat)
    chooser.attach(to: panel)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    preferences.exportFormat = chooser.format
    exportType = chooser.format.rawValue
    if needScan.isEmpty || usePreviews {
      composeContactSheet(ids: items.map(\.id), to: url, format: chooser.format)
    } else {
      pendingSheet = (items.map(\.id), url, chooser.format)
      startScanBatch(needScan.map(\.id), dpi: ContactSheet.scanDPI)
      if !scanBatch.isActive { pendingSheet = nil }  // The batch refused to start.
    }
  }
  func composeContactSheet(
    ids: [UUID], to url: URL, format: ExportFormat, completion: ((Error?) -> Void)? = nil
  ) {
    let items = ids.compactMap { id in frames.first { $0.id == id } }
    let p = profile, layout = preferences.sheet, quality = preferences.jpegQuality
    let previewDPI = overviewDPI
    let title = "\(filmName) · \(Date().formatted(.iso8601.year().month().day())) · \(items.count) 张"
    let filmCode = filmName.uppercased()
    let sharpening = preferences.sharpening
    let tiles = items.map { f in
      ContactSheet.Tile(
        name: f.name, settings: f.adjustments,
        dpi: f.hasFullResolution ? Double(f.scanDPI ?? Int(previewDPI)) : previewDPI,
        source: { try self.source(for: f, full: true) },
        sharpener: Sharpening.sharpener(sharpening, frame: f, maxDimension: nil))
    }
    beginExport()
    status = "正在生成接触表 · \(items.count) 张…"
    renderQueue.async {
      do {
        let size = try ContactSheet.export(
          tiles, profile: p, layout: layout, title: title, filmCode: filmCode, to: url,
          format: format, quality: quality)
        DispatchQueue.main.async {
          self.endExport()
          self.status = "接触表已导出：\(url.lastPathComponent) · \(Int(size.width)) × \(Int(size.height))"
          completion?(nil)
        }
      } catch {
        DispatchQueue.main.async {
          self.endExport()
          self.errorText = error.localizedDescription
          completion?(error)
        }
      }
    }
  }
  struct ExportRecord: Codable {
    var profile: FilmProfile
    var frame: FilmFrame
    var source: String
    var isPreview: Bool
  }
  func saveProject() {
    guard let root = sessionURL, let overviewURL else { return }
    let project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: overviewDPI, physicalWidthMM: physicalMM.width,
      physicalHeightMM: physicalMM.height, filmName: filmName, profile: profile, scanDPI: dpi,
      frames: frames, scanBackendID: overviewBackendID, overviewInputGamma: overviewInputGamma)
    do {
      let e = JSONEncoder()
      e.outputFormatting = [.prettyPrinted, .sortedKeys]
      try e.encode(project).write(
        to: root.appendingPathComponent("Session.filmdesk"), options: .atomic)
    } catch { status = "工程保存失败：\(error.localizedDescription)" }
  }
  func openProject() {
    guard !isWorking else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.data]
    panel.directoryURL = libraryURL
    guard panel.runModal() == .OK, let url = panel.url else { return }
    loadProject(url)
  }
  func loadProject(_ url: URL) {
    do {
      let p = try JSONDecoder().decode(DeskProject.self, from: Data(contentsOf: url))
      guard p.version == 1 else { throw DeskError.message("不支持的工程版本。") }
      try p.profile.validate()
      let cg = try ImagePipeline.shared.load(
        URL(fileURLWithPath: p.overviewPath), maxDimension: 2200)
      sessionURL = url.deletingLastPathComponent()
      overviewURL = URL(fileURLWithPath: p.overviewPath)
      overview = cg
      frames = p.frames
      profile = p.profile
      filmName = p.filmName
      dpi = p.scanDPI
      overviewDPI = p.overviewDPI
      overviewBackendID = p.scanBackendID
      overviewInputGamma = p.overviewInputGamma
      physicalMM = CGSize(width: p.physicalWidthMM, height: p.physicalHeightMM)
      selectedID = frames.first?.id
      singleView = false
      updateRollBase()
      updateRollSlopes()
      refresh()
      updateThumbnails()
      status = "已打开工程"
    } catch { errorText = error.localizedDescription }
  }
  func openEpson() {
    scanner.close()
    let url = URL(fileURLWithPath: "/Applications/Epson Software/Epson Scan 2.app")
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) {
      _, error in
      if let error { DispatchQueue.main.async { self.errorText = error.localizedDescription } }
    }
  }
}
