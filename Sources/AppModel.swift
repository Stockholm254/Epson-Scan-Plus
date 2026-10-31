import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
  let scanner: ScannerController
  @Published var frames = [FilmFrame]()
  @Published var selectedID: UUID? {
    // The light table turns to the page the frame selected lies on.
    didSet {
      if let id = selectedID, id != oldValue, let page = contactPageIndex(of: id), page != contactPage { contactPage = page }
    }
  }
  /// The light table's page shown: the holder's preview, or one laid out from frames of their own.
  @Published var contactPage = 0
  /// The canvas, to open a frame from the light table: the view closing in on it.
  var frameOpener: ((UUID) -> Void)?
  /// A change of what the canvas shows, which it animates.
  enum ViewChange: Equatable {
    /// From the single frame back to the light table.
    case close
    /// Into a frame's crop, its surroundings round it, or out of it.
    case edit(entering: Bool)
    /// The frame, or the table, turned a quarter (clockwise positive) or mirrored.
    case orient(turns: Int, mirror: Bool)
  }
  /// The canvas, told before the model changes what it shows, so it can take its picture first.
  var viewWillChange: ((ViewChange) -> Void)?
  @Published var overview: CGImage?
  /// The light table's last picture, a page of it: shown at once on coming back to the table,
  /// while a new one is made.
  var tablePrint: (page: Int, positive: Bool, image: CGImage)?
  @Published var displayed: CGImage?
  /// The frames' positives, as the filmstrip shows them; the library keeps a small copy of each.
  @Published var thumbnails = [UUID: CGImage]() {
    didSet {
      // On the light table the curves' histograms are the selected positive's, as it comes.
      if !singleView, let picture = selected.flatMap({ thumbnails[$0.id] }), picture !== selected.flatMap({ oldValue[$0.id] }) {
        (histogram, channelHistograms) = Self.histograms(picture)
      }
      if onSheetPage && contactPositive { refresh() }
      guard !thumbnails.isEmpty, !readOnly, let folder = sessionURL else { return }
      let images = thumbnails
      DispatchQueue.global(qos: .utility).async { RollLibrary.storePositives(images, folder: folder) }
    }
  }
  /// Only the single frame zooms: back on the light table the whole roll shows again.
  @Published var singleView = false {
    didSet {
      // A preview being read shows on the light table as it comes; the single view waits for it.
      if singleView, previewShowing {
        singleView = false
        return
      }
      if !singleView, zoom != 1 { fitView() }
    }
  }
  /// The scanner's preview shows on the light table as it is read.
  var previewShowing: Bool { scanner.previewSoFar != nil }
  @Published var showNegative = false
  @Published var tool = CanvasTool.select
  @Published var format = FilmFormat.auto
  @Published var dpi = 2400
  @Published var filmName = "Kodak Portra 160"
  /// The open roll's name and notes in the library.
  @Published var rollName = ""
  @Published var rollNotes = ""
  /// The roll's pictures that are a file each are measured together as one roll: asked for, as
  /// files from elsewhere need not have been scanned alike.
  @Published var poolPictures = false
  /// Where the open roll's pictures came from, when the app knows: the camera's rolls say so.
  @Published var rollSource: RollSource?
  /// The camera on the copy stand.
  lazy var camera: CameraController = {
    let c = CameraController()
    c.onCapture = { [weak self] url in self?.receiveCapture(url) }
    return c
  }()
  /// Pictures a pixel-shift shot takes (set on the camera, 4 or 16), or 1: the app groups them.
  @Published var pixelShiftCount = 1
  /// The channel the picture and the camera's live view are looked at through: all, or one alone.
  @Published var channelView = ChannelView.all {
    didSet { canvasFocusRevision += 0 }
  }
  /// The files of a pixel-shift shot still to come, and the folder they go in.
  @Published var pendingShift = [URL]()
  /// The camera's last picture as it arrived, RAW or JPEG, for checking focus.
  @Published var lastCapture: URL?
  /// A note floating up over the live view for a moment: a picture filed, a group complete.
  @Published var captureToast: String?
  @Published var profile = FilmProfile.builtins[0]
  @Published var profiles = FilmProfile.builtins
  @Published var status = "点击「预览」读取胶片"
  @Published var errorText: String?
  @Published var rendering = false
  @Published var detectingFrames = false
  @Published var exporting = false
  /// The passes still to scan: one frame each, or the frames of a row scanned together.
  @Published var scanQueue = [[UUID]]()
  @Published private(set) var scanBatch = ScanBatchProgress()
  @Published var histogram = [Double](repeating: 0, count: 64)
  /// Red, green and blue of the positive, on one scale, for the curves.
  @Published var channelHistograms = [[Double]](repeating: [Double](repeating: 0, count: 64), count: 3)
  @Published var exportType = "tiff"
  /// Rotate and mirror act on the current frame, or on every frame while syncing.
  @Published var syncOrientation = false
  /// The contact sheet view shows a positive print of the overview, or the raw scan.
  @Published var contactPositive = true
  /// Neutral patches picked with the calibration tool, across frames and rolls of one film.
  @Published var calibrationPoints = [NeutralPoint]()
  /// The current preset's neutral points marked on their frames; on once a preset is made.
  @Published var showCalibrationPoints = false
  /// The neutral points to mark on `frame`, numbered as listed, in its source: those being picked,
  /// else, asked for, those the current preset was calibrated from.
  func neutralMarks(on frame: FilmFrame) -> [(number: Int, at: CGPoint)] {
    if !calibrationPoints.isEmpty {
      return calibrationPoints.enumerated().compactMap { i, p in p.frame == frame.id ? p.at.map { (i + 1, $0) } : nil }
    }
    guard showCalibrationPoints, let spots = profile.spots else { return [] }
    return spots.enumerated().compactMap { i, s in s.frame == frame.id ? (i + 1, CGPoint(x: s.x, y: s.y)) : nil }
  }
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
  var overviewURL: URL?
  private let overviewCache = OverviewCache()
  var overviewBackendID: String?
  var overviewInputGamma: Double?
  /// The pass under way, and the box it covers in the overview.
  private var currentScan: [UUID]?
  private var currentScanRect: NormalRect?
  /// Why a pass that came back could not be kept, for the message the batch stops with.
  private var receiveError: String?
  private var currentScanReceivedFile = false
  private var scanBatchID = UUID()
  private var activeScanDPI = 2400
  private var scanStarted: Date?
  private var cancelRequested = false
  private var revision = 0
  /// The render last asked for, as the render queue may read it.
  private let wantedLock = NSLock()
  private var wantedRevision = 0
  private func isCurrent(_ token: Int) -> Bool {
    wantedLock.lock()
    defer { wantedLock.unlock() }
    return wantedRevision == token
  }
  private let renderQueue = DispatchQueue(label: "epscan.render", qos: .userInitiated)
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
  /// The scan tab belongs to capturing, the film and output tabs to taking the mask off.
  @Published var panelTab = PanelTab.scan {
    didSet { if panelTab == .scan, page == .convert { page = .capture } }
  }
  /// The main window's three modules, in the order a roll goes through them: capturing it (the
  /// scanner, the camera or files), taking the orange mask off, and repairing light leaks.
  enum Page: String, CaseIterable {
    case capture = "采集", convert = "去色罩", leak = "去漏光"
    var number: String { ["①", "②", "③"][Self.allCases.firstIndex(of: self) ?? 0] }
    var help: String {
      switch self {
      case .capture: return "采集：用 V850 预览和扫描，用 A7R IV 翻拍，或导入文件；每卷自动放进库里"
      case .convert: return "去色罩：片基、白平衡、预设、曲线、接触表和看片镜，以及导出"
      case .leak: return "去漏光：用参考图修复正片上的漏光"
      }
    }
  }
  @Published var page = Page.capture {
    didSet {
      if page == .capture { panelTab = .scan } else if page == .convert, panelTab == .scan { panelTab = .film }
      // The pickers belong to taking the mask off.
      if page == .capture, [CanvasTool.base, .neutral, .highlight].contains(tool) { tool = .select }
    }
  }
  /// Where module ① takes pictures from.
  enum CaptureSource: String, CaseIterable {
    case scanner = "V850 扫描", camera = "A7R IV 翻拍", files = "导入文件"
    var symbol: String {
      switch self {
      case .scanner: return "scanner"
      case .camera: return "camera"
      case .files: return "square.and.arrow.down"
      }
    }
    /// The name on its tab where the whole one does not fit.
    var short: String {
      switch self {
      case .scanner: return "V850"
      case .camera: return "A7R IV"
      case .files: return "导入"
      }
    }
  }
  @Published var captureSource = CaptureSource.scanner
  /// The library, the window's cabinet of rolls, is open.
  @Published var showLibrary = false
  /// The 去漏光 page, made when it is first shown.
  lazy var leak: LeakLab = makeLeakLab()
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
  /// Quarter turns clockwise the light table shows the overview with. Lying across only when the
  /// holder stands upright; turned the way most frames are turned to stand up, and clockwise when
  /// none are: as film lies in the V850's holder, a frame shot across then stands upright (every
  /// frame turned in this computer's projects so far was turned clockwise).
  /// A page laid out from frames of their own lies upright, as it is printed.
  var contactTurn: Int {
    guard !onSheetPage else { return 0 }
    let picture = scanner.previewSoFar ?? displayed
    guard !singleView, preferences.contactLandscape, let d = picture, d.height > d.width else { return 0 }
    // A preview being read is the next roll's, whose frames are not known yet: clockwise, as a new
    // roll's turn out.
    guard scanner.previewSoFar == nil else { return 1 }
    let turns = contactFrames.map { (($0.adjustments.rotation % 4) + 4) % 4 }
    return turns.filter { $0 == 3 }.count > turns.filter { $0 == 1 }.count ? 3 : 1
  }
  /// The light table shows the film mirrored when most frames are, as the strips would lie flipped.
  var contactMirrored: Bool {
    guard !onSheetPage, scanner.previewSoFar == nil else { return false }
    let frames = contactFrames
    return !singleView && frames.filter { $0.adjustments.flipHorizontal == true }.count * 2 > frames.count
  }
  /// The frame the scanner is reading now, and how far it has got.
  var scanningFrames: [FilmFrame] { (currentScan ?? []).compactMap { id in frames.first { $0.id == id } } }
  /// The box the scanner is reading now, over one frame or a row of them.
  var scanningRect: NormalRect? { currentScan == nil ? nil : currentScanRect }
  /// Rows are scanned together only over the 48-bit interface, whose timing was measured.
  var scansRows: Bool { preferences.rowScanning && scanner.backendID == "epson2-linear-v1" }
  private var bytesPerPixel: Double { Double(max(8, scanner.bits) * 3) / 8 }
  /// How the batch's frames would be scanned at `dpi`.
  func scanPasses(_ targets: [FilmFrame], dpi: Int) -> [[FilmFrame]] {
    ScanPasses.group(targets, physicalMM: physicalMM, dpi: dpi, bytesPerPixel: bytesPerPixel, rows: scansRows)
  }
  /// Where a point of the overview is shown in single view, normalised to the picture there.
  func singleViewPoint(_ p: CGPoint) -> CGPoint? {
    guard singleView, let frame = selected else { return nil }
    let region = canvasRegion ?? frame.rect
    let raw = CGPoint(x: (p.x - region.x) / region.width, y: (p.y - region.y) / region.height)
    return ImageGeometry.display(raw, settings: frame.adjustments, aspect: shownAspect(frame))
  }
  /// The frame's width over its height as it lies, which its straightening turns about, when the
  /// single view shows it straightened: not while its crop or base is edited, when the picture is
  /// its surroundings as they lie, with the kept part outlined.
  func shownAspect(_ frame: FilmFrame) -> Double? {
    guard abs(frame.adjustments.angle ?? 0) > 0.0001, !editingSingle else { return nil }
    return frameAspect(frame)
  }
  /// While the straightening is being changed, and a moment after: the canvas lays a grid over
  /// the picture to line a horizon or an edge up with.
  @Published private(set) var straightening = false
  private var straighteningToken = 0
  /// The selected frame's straightening as the screen shows it: clockwise positive, mirrored or not.
  var screenAngle: Double { (settings.angle ?? 0) * (settings.flipHorizontal == true ? -1 : 1) }
  /// Turns the selected frame about its middle to `degrees` clockwise on the screen, cut to the
  /// largest rectangle of its shape inside.
  func straighten(_ degrees: Double) {
    let a = (clamp(degrees, -45, 45) * 100).rounded() / 100 * (settings.flipHorizontal == true ? -1 : 1)
    change("拉直") { $0.angle = abs(a) < 0.005 ? nil : a }
    showStraighteningGrid()
  }
  /// The next drag over the crop draws a line along something that should be level or upright,
  /// a horizon or a wall, and the frame is straightened by it.
  @Published var levelling = false
  /// Straightens by a line drawn over the frame as it lies, `dx` and `dy` on the screen: level
  /// when it runs nearer across, upright when nearer up and down.
  func straighten(along dx: Double, _ dy: Double) {
    levelling = false
    guard hypot(dx, dy) > 0 else { return }
    let a = atan2(dy, dx) * 180 / .pi
    // Turned back by its tilt: a line falling to the right is turned anticlockwise.
    straighten(-(a - 90 * (a / 90).rounded()))
  }
  func showStraighteningGrid() {
    straighteningToken += 1
    let token = straighteningToken
    straightening = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      guard let self, self.straighteningToken == token else { return }
      self.straightening = false
    }
  }
  func frameAspect(_ frame: FilmFrame) -> Double? {
    guard let mm = frameMM(frame), mm.width > 0, mm.height > 0 else { return nil }
    return Double(mm.width / mm.height)
  }
  /// One line on the canvas while a tool is active: where to click, and how to leave it.
  var toolHint: String? {
    switch tool {
    case .select: return nil
    case .crop:
      if singleView && levelling { return "沿地平线、墙边或建筑竖线拖一条线，松手即按它拉直 · Esc 退出" }
      return singleView ? "拖动四角裁切 · 方向键微调 · [ ] 拉直 0.1°（⇧ 1°） · ⌥ 拖一条线拉直 · 回车完成 · Esc 退出" : "在灯箱上拖出新的画框 · Esc 退出"
    case .base: return "点未曝光的橙色片基（片间或片边），不要点景物或片夹；琥珀色是自动找到的片基 · Esc 退出"
    case .neutral: return "点画面中应为中性灰的地方：灰卡、白墙、水泥 · Esc 退出"
    case .highlight: return "点负片上最密、正片里应为纯白的高光：阳光下的白墙、高光反射；更亮处会剪成白 · Esc 退出"
    case .calibrate:
      return "点选中性灰：灰卡、白墙、水泥等均匀处 · 已取 \(calibrationPoints.count) 个"
        + (calibrationPoints.isEmpty ? "" : " · ⌫ 撤回上一点") + " · Esc 结束"
    case .it8:
      let n = it8Marks.count, undo = n > 0 ? " · ⌫ 撤回上一点" : ""
      guard n < IT8Layout.marks.count else { return "6 个点已就位 · 检查色块位置后点「生成标定」" + undo + " · Esc 退出" }
      return "点 \(IT8Layout.marks[n]) 的中心（第 \(n + 1) / \(IT8Layout.marks.count) 个）" + undo + " · Esc 退出"
    }
  }
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
  /// The frame before or after the selected one, in the roll's order: in single view, and on the
  /// light table, where the page turns with it.
  func canNavigate(_ offset: Int) -> Bool {
    guard let i = selectedIndex else { return false }
    return frames.indices.contains(i + offset)
  }
  func navigate(_ offset: Int) {
    guard canNavigate(offset), let i = selectedIndex else { return }
    select(frames[i + offset].id)
    focusCanvas()
  }
  func useTool(_ value: CanvasTool) {
    let editing = editingSingle, willEdit = singleView && (value == .crop || value == .base)
    if editing != willEdit { viewWillChange?(.edit(entering: willEdit)) }
    if value != tool { editRegionLock = nil }
    if value != .crop { levelling = false }
    tool = value
    if value == .neutral || value == .highlight || value == .calibrate || value == .it8 { singleView = selected != nil }
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
    change("重算白平衡") {
      $0.autoWhiteBalance = true
      $0.manualBalance = nil
      $0.neutralSample = nil
      $0.highlightSample = nil
    }
    status = "已重算白平衡 · 独立校正通道亮暗范围"
  }
  func adjustBase(_ channel: Int, value: Double) {
    change("片基微调") {
      var fine = $0.baseFine ?? .zero
      switch channel {
      case 0: fine.r = value
      case 1: fine.g = value
      default: fine.b = value
      }
      $0.baseFine = fine
    }
  }
  /// The frames on the light table's page shown: laid out from their own files, or on the holder.
  var contactFrames: [FilmFrame] {
    if onSheetPage { return sheetPageFrames }
    let own = Set(sheetFrames.map(\.id))
    return frames.filter { !own.contains($0.id) }
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
    // The preview coming in goes on the light table, out of the single view.
    scanner.$previewSoFar.sink { [weak self] picture in
      guard let self, picture != nil, self.singleView else { return }
      self.singleView = false
      DispatchQueue.main.async { self.refresh() }
    }.store(in: &cancellables)
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
  func start() {
    scanner.start()
    updateMCP()
  }

  // MARK: Assistant (MCP)

  /// Takes an assistant's tool calls while `preferences.mcpEnabled`.
  let mcp = MCPServer()
  @Published private(set) var mcpStatus = "关闭"
  func updateMCP() {
    guard preferences.mcpEnabled else {
      mcp.stop()
      mcpStatus = "关闭"
      return
    }
    mcp.model = self
    mcp.onCall = { [weak self] name in
      let time = Date().formatted(date: .omitted, time: .shortened)
      DispatchQueue.main.async { self?.mcpStatus = "已连接 · 最近一次：\(name)（\(time)）" }
    }
    do {
      try mcp.start()
      if !mcpStatus.hasPrefix("已连接") { mcpStatus = "已开启 · 等待 AI 助手连接" }
    } catch {
      mcpStatus = "无法开启：\(error.localizedDescription)"
    }
  }
  /// How an assistant starts this app's MCP server.
  var mcpCommand: String { Bundle.main.executablePath ?? "/Applications/Epson Scan plus.app/Contents/MacOS/EpsonScanPlus" }
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
  /// New projects save as `Session.epscan`; one opened from a file saves back to that file, so an
  /// older `Session.filmdesk` is kept up to date rather than joined by a second copy.
  static let projectFile = "Session.epscan"
  private(set) var projectFileName = AppModel.projectFile
  func makeSession() throws -> URL {
    if let sessionURL { return sessionURL }
    projectFileName = Self.projectFile
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
    // The preview shows on the light table as it is read.
    if singleView { singleView = false }
    scanner.previewDPI = preferences.previewDPI
    scanner.preview()
  }
  func receiveOverview(_ cg: CGImage, size: CGSize, dpi: Double) {
    do {
      sessionURL = nil
      frames = []
      thumbnails = [:]
      tablePrint = nil
      selectedID = nil
      rollName = ""
      rollNotes = ""
      poolPictures = false
      rollSource = nil
      clearEdits()
      let root = try makeSession()
      // Uncompressed: a 600 dpi preview writes in a tenth of a second, as PNG it takes two.
      let url = root.appendingPathComponent("overview.tif")
      try ImagePipeline.shared.saveTIFF(cg, to: url, dpi: Int(dpi))
      overviewCache.keep(cg, for: url)
      // Frame detection, statistics and the contact view work on at most 2200 px, as when a
      // project is opened; crops of single frames come from the full resolution.
      overview = overviewWorkingCopy(ImagePipeline.shared.scaled(cg, maxDimension: 2200), backend: scanner.backendID)
      overviewURL = url
      physicalMM = size
      overviewDPI = dpi
      overviewBackendID = scanner.backendID
      overviewInputGamma = scanner.captureInputGamma
      singleView = false
      showNegative = false
      sourceSummary = "透扫预览 · \(Int(dpi)) dpi"
      // The frames found come in on the light table, which stays.
      detectFrames()
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
        self.clearEdits()
        self.frames = found
        self.selectedID = found.first?.id
        self.detectingFrames = false
        self.tool = .select
        self.editRegionLock = nil
        if enterSingle, let first = found.first { self.open(first.id) }
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
    // A frame of a file of its own lies on a page of the contact sheet, read from its file: the
    // holder's picture stays the holder's.
    selectedID = id
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
        self.recordEdit("收紧片边")
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
    recordEdit("画面范围", key: "画面范围-\(id)")
    if frames[i].scanPath != nil && frames[i].scanRect == nil { frames[i].scanRect = old }
    if frames[i].initialRect == nil { frames[i].initialRect = old }
    frames[i].rect = rect
    status = frames[i].needsRescan ? "范围超出原始扫描 · 需重新扫描，原文件仍保留" : "裁切已更新 · 原始文件未改动"
    updateRollBase()
    refresh()
    saveProject()
    updateThumbnails()
  }
  /// Crops copy shots to their pictures, inside the frame's edges and straightened by them: the
  /// selected one, or with `roll` every one of the roll. Each is checked against the roll's others
  /// (copied at one magnification, its pictures are about one size), so for one frame the four
  /// either side of it are looked at too. One edit, undone together; the files are left as they
  /// are. `done` is told what it did.
  func autoCrop(roll: Bool, done: ((String) -> Void)? = nil) {
    let copies = frames.filter(isSinglePicture)
    let finish = { (said: String) in
      self.status = said
      done?(said)
    }
    guard !isWorking else { return finish("正在处理别的，稍后再自动裁切") }
    let targets: [FilmFrame], looked: [FilmFrame]
    if roll {
      targets = copies
      looked = copies
    } else {
      guard let selected, let i = copies.firstIndex(where: { $0.id == selected.id }) else {
        return finish("自动裁切用于翻拍或单独导入的照片（一个文件一张）")
      }
      targets = [selected]
      looked = Array(copies[max(0, i - 4)...min(copies.count - 1, i + 4)])
    }
    guard !targets.isEmpty else { return finish("这一卷没有翻拍的照片可以自动裁切") }
    status = targets.count > 1 ? "正在找 \(targets.count) 张的画面边…" : "正在找画面的边…"
    let project = sessionURL
    renderQueue.async {
      let pipe = ImagePipeline.shared
      let edges = FrameEdges.agreeing(looked.map { f in (try? self.edgeSource(for: f, maxDimension: 1600)).flatMap { $0 }.flatMap(pipe.frameEdges) })
      var crops = [UUID: PictureCrop]()
      for (f, e) in zip(looked, edges) { crops[f.id] = e.flatMap { pipe.crop($0) } }
      DispatchQueue.main.async {
        guard self.sessionURL == project else { return }
        // Each one a step of its own, however soon after the last.
        self.recordEdit("自动裁切", key: UUID().uuidString)
        var cropped = [FilmFrame](), missed = [String]()
        for f in targets {
          guard let i = self.frames.firstIndex(where: { $0.id == f.id }) else { continue }
          guard let crop = crops[f.id] else {
            missed.append(self.frames[i].name)
            continue
          }
          if self.frames[i].initialRect == nil { self.frames[i].initialRect = self.frames[i].rect }
          self.frames[i].rect = crop.rect
          self.frames[i].adjustments.angle = crop.angle
          cropped.append(self.frames[i])
        }
        if !cropped.isEmpty {
          self.updateRollBase()
          self.refresh()
          self.saveProject()
          self.updateThumbnails()
        }
        let not = missed.isEmpty ? "" : "第 " + missed.joined(separator: "、") + " 张没找到片框的边"
        if cropped.isEmpty {
          finish(not + " · 可用「微调」手动裁切")
        } else if targets.count == 1, let f = cropped.first {
          let turn = f.adjustments.angle.map { String(format: "拉直 %+.2f°", $0) } ?? "画面是正的"
          finish("已自动裁切 · \(turn) · ⌘Z 撤销 · 原文件未改动")
        } else {
          finish("已自动裁切 \(cropped.count) 张" + (not.isEmpty ? "" : " · " + not) + " · ⌘Z 撤销 · 原文件未改动")
        }
      }
    }
  }
  func addFrame(_ rect: NormalRect) {
    guard rect.width > 0.008, rect.height > 0.008 else { return }
    recordEdit("添加画面")
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
  /// The delete key: while points are being picked it takes back the last one, and never removes
  /// the frame they are picked on.
  func deletePressed() {
    switch tool {
    case .it8: undoIT8Mark()
    case .calibrate:
      guard !calibrationPoints.isEmpty else { return }
      calibrationPoints.removeLast()
      status = "已撤回一个中性点 · 还有 \(calibrationPoints.count) 个"
    default: removeSelected()
    }
  }
  func removeSelected() {
    guard let id = selectedID else { return }
    remove(id)
  }
  /// Takes a frame out of the roll, an edit ⌘Z undoes; its files stay in the roll's folder. Taken
  /// while selected, the one after it is selected in its place, or for the last the one before.
  func remove(_ id: UUID) {
    guard let i = frames.firstIndex(where: { $0.id == id }), !isWorking else { return }
    recordEdit("删除画面")
    thumbnails[id] = nil
    frames.remove(at: i)
    if selectedID == id { selectedID = frames.isEmpty ? nil : frames[min(i, frames.count - 1)].id }
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
    recordEdit(enabled ? "勾选" : "取消勾选", key: "勾选-\(id)")
    frames[i].enabled = enabled
    saveProject()
    focusCanvas()
  }
  func setAllEnabled(_ enabled: Bool) {
    guard !isWorking, !frames.isEmpty else { return }
    recordEdit(enabled ? "全选" : "全不选")
    for i in frames.indices { frames[i].enabled = enabled }
    saveProject()
    focusCanvas()
    status = enabled ? "已勾选全部 \(frames.count) 张 · 用于扫描 / 导出" : "已取消全部勾选 · 当前照片仍保留"
  }
  /// `name` is the edit as the Edit menu shows it; steps of one control are undone together.
  func change(_ name: String = "调整", _ mutation: (inout Adjustments) -> Void) {
    guard let i = selectedIndex else { return }
    recordEdit(name, key: "\(name)-\(frames[i].id)")
    // The roll's measured base belongs to the film, so even a reset keeps it.
    let rollBase = frames[i].adjustments.rollBase, rollSlopes = frames[i].adjustments.rollSlopes
    let picked = frames[i].adjustments.rollBasePicked
    mutation(&frames[i].adjustments)
    frames[i].adjustments.rollBase = rollBase
    frames[i].adjustments.rollSlopes = rollSlopes
    frames[i].adjustments.rollBasePicked = picked
    refresh()
    saveProject()
  }
  /// The tone and colour settings back to their defaults. How the file is encoded, which way the
  /// frame faces and the roll's own estimates are not settings, so they stay.
  func resetAdjustments() {
    change("重置调整") {
      let kept = $0
      $0 = Adjustments()
      $0.inputGamma = kept.inputGamma
      $0.inputIsNegative = kept.inputIsNegative
      $0.rotation = kept.rotation
      $0.flipHorizontal = kept.flipHorizontal
      $0.angle = kept.angle
      // How the picture was read, not a setting: a copy shot keeps its colour noise reduction.
      $0.colourNoise = kept.colourNoise
    }
  }

  // MARK: Undo

  /// The window's: edits to the frames and the film preset are undone from the Edit menu.
  weak var undoManager: UndoManager?
  private struct EditState {
    var frames: [FilmFrame], selectedID: UUID?, profile: FilmProfile, filmName: String
  }
  private var lastEdit: (key: String, at: Date)?
  private var editState: EditState { EditState(frames: frames, selectedID: selectedID, profile: profile, filmName: filmName) }
  /// Called before an edit. Repeats of one control within a second, a fader being dragged, are one step.
  private func recordEdit(_ name: String, key: String? = nil, filmName shown: String? = nil) {
    guard let undoManager, !undoManager.isUndoing, !undoManager.isRedoing else { return }
    let key = key ?? name, now = Date()
    defer { lastEdit = (key, now) }
    if let lastEdit, lastEdit.key == key, now.timeIntervalSince(lastEdit.at) < 1, undoManager.canUndo { return }
    // Without event grouping (tests, the command line) each edit is a group of its own.
    let grouping = !undoManager.groupsByEvent
    if grouping { undoManager.beginUndoGrouping() }
    var state = editState
    if let shown { state.filmName = shown }
    undoManager.registerUndo(withTarget: self) { $0.restore(state, name: name) }
    undoManager.setActionName(name)
    if grouping { undoManager.endUndoGrouping() }
  }
  private func restore(_ state: EditState, name: String) {
    let undoing = undoManager?.isUndoing == true
    let current = editState
    undoManager?.registerUndo(withTarget: self) { $0.restore(current, name: name) }
    undoManager?.setActionName(name)
    lastEdit = nil
    // What the user edits comes back. Scans, and the film base and slopes the app measures, stay
    // as they are now; a removed frame comes back, an added one goes.
    frames = state.frames.map { old in
      guard var f = frames.first(where: { $0.id == old.id }) else { return old }
      // A base picked for the roll is the user's own, so it goes back with the edits.
      let picked = f.adjustments.rollBasePicked == true || old.adjustments.rollBasePicked == true
      // How its pixels are read goes back too; the base the app measured is read again with it.
      let measured = f.adjustments.rollBase.map { Crosstalk.moved($0, from: f.crosstalk, to: old.crosstalk) }
      let rollBase = picked ? old.adjustments.rollBase : measured ?? old.adjustments.rollBase
      let rollSlopes = f.adjustments.rollSlopes ?? old.adjustments.rollSlopes
      (f.name, f.rect, f.initialRect, f.enabled, f.format) = (old.name, old.rect, old.initialRect, old.enabled, old.format)
      if let read = f.edgeBase?.base { f.edgeBase?.base = Crosstalk.moved(read, from: f.crosstalk, to: old.crosstalk) }
      // Read through another flat field, the edges are looked at again.
      if f.flatField != old.flatField { f.edgeBase = nil }
      f.crosstalk = old.crosstalk
      f.flatField = old.flatField
      f.adjustments = old.adjustments
      (f.adjustments.rollBase, f.adjustments.rollSlopes) = (rollBase, rollSlopes)
      return f
    }
    selectedID = state.selectedID.flatMap { id in frames.contains { $0.id == id } ? id : nil } ?? frames.first?.id
    (profile, filmName) = (state.profile, state.filmName)
    editRegionLock = nil
    status = (undoing ? "已撤销：" : "已重做：") + name
    updateRollBase()
    updateRollSlopes()
    refresh()
    updateThumbnails()
    saveProject()
    measureEdgeBases()
  }
  /// A new preview, frame list or scan: earlier edits no longer apply to what is there.
  func clearEdits() {
    undoManager?.removeAllActions(withTarget: self)
    lastEdit = nil
  }
  /// Measures the film base between the frames on the current overview and shares it with
  /// them. Only for overviews whose values match the frames' scans: this app's 48-bit
  /// previews, or an imported strip the frames are cut from. Other frames keep theirs.
  /// A base picked once and shared with the roll stays as it is, and reaches the frames of its
  /// roll that came after it.
  func updateRollBase() {
    if let overview {
      // A picture with the copy light's crosstalk taken out no longer reads as the overview does.
      let onOverview = frames.indices.filter {
        frames[$0].adjustments.rollBasePicked != true && frames[$0].crosstalk == nil
          && (frames[$0].sourcePath == nil ? overviewBackendID == "epson2-linear-v1" : frames[$0].sourcePath == overviewURL?.path)
      }
      if !onOverview.isEmpty {
        let base = ImagePipeline.shared.rollBase(overview, frames: onOverview.map { frames[$0] })
        for i in onOverview { frames[i].adjustments.rollBase = base }
      }
    }
    // Pictures a file each, as a camera takes them: the unexposed film at their own edges, or where
    // a picture's edges show none, that of the nearest one in the roll whose do (shot under the
    // light as it was set then). A base picked for the roll, below, comes first.
    for i in frames.indices where frames[i].adjustments.rollBasePicked != true {
      if let from = edgeBaseSource(i), let base = frames[from].edgeBase?.base { frames[i].adjustments.rollBase = base }
    }
    for group in Self.rollGroups(frames, poolPictures: true) {
      guard let shared = group.first(where: { $0.adjustments.rollBasePicked == true })?.adjustments.rollBase else { continue }
      let ids = Set(group.map(\.id))
      for i in frames.indices where ids.contains(frames[i].id) && frames[i].adjustments.rollBasePicked != true {
        frames[i].adjustments.rollBase = shared
        frames[i].adjustments.rollBasePicked = true
      }
    }
  }
  /// Whether the frame is a picture a file each, as a camera or an import of single pictures gives.
  func isSinglePicture(_ f: FilmFrame) -> Bool {
    guard let path = f.sourcePath else { return false }
    return frames.lazy.filter { $0.sourcePath == path }.count == 1
  }
  /// The frame whose edges give frame `i` its base: its own, or the nearest picture of its roll (read
  /// alike) whose edges show the base. Where three or more show one, a reading no other picture
  /// shares the colour of (within 4% in red and blue against green) is passed over: more likely the
  /// holder or the picture than the film, while a light balanced again shows in the pictures after.
  /// Nil when none does, or the frame is not a picture a file each.
  func edgeBaseSource(_ i: Int) -> Int? {
    guard frames.indices.contains(i), isSinglePicture(frames[i]) else { return nil }
    let mine = frames[i]
    let alike = frames.indices.filter {
      frames[$0].edgeBase?.base != nil && isSinglePicture(frames[$0])
        && frames[$0].adjustments.inputGamma == mine.adjustments.inputGamma && frames[$0].sourceBits == mine.sourceBits
    }
    func colour(_ j: Int) -> (Double, Double) {
      let b = frames[j].edgeBase?.base ?? .one
      return (log(b.r / b.g), log(b.b / b.g))
    }
    let trusted = alike.count < 3 ? alike : alike.filter { j in
      alike.contains { k in k != j && abs(colour(k).0 - colour(j).0) < 0.04 && abs(colour(k).1 - colour(j).1) < 0.04 }
    }
    if trusted.contains(i) { return i }
    return trusted.min { abs($0 - i) < abs($1 - i) }
  }
  /// Where the frame's film base comes from, as the panel says it.
  func baseSource(_ f: FilmFrame) -> String {
    if f.adjustments.base != nil { return "片基来自手动取样" }
    if f.adjustments.rollBasePicked == true { return "片基来自整卷共用的手动取样" }
    if let i = frames.firstIndex(where: { $0.id == f.id }), let from = edgeBaseSource(i) {
      return from == i ? "片基来自这一张片边的未曝光片基" : "这一张片边没找到片基，用第 \(frames[from].name) 张片边的"
    }
    if f.adjustments.rollBase != nil { return "片基来自整卷片间未曝光区" }
    return isSinglePicture(f) && f.edgeBase != nil ? "片边没找到未曝光片基，按本张最薄的片区估计" : "片基按本张最薄的片区估计"
  }
  /// Shows on the single frame where its film base was read at its edges.
  @Published var showBaseAreas = false
  /// The picture's file, whole and small, as it reads for the edge base: crosstalk taken out as
  /// the frame has it.
  private func edgeSource(for frame: FilmFrame, maxDimension: Int = 800) throws -> CGImage? {
    guard let path = frame.sourcePath else { return nil }
    let image = try ImagePipeline.shared.load(URL(fileURLWithPath: path), maxDimension: maxDimension)
    return ImagePipeline.shared.corrected(image, crosstalk: frame.crosstalk, flat: frame.flatField)
  }
  /// Looks for the unexposed film at the edges of the roll's pictures not yet looked at, apart from
  /// the main thread, then converts with what it found. `wait` looks before returning.
  func measureEdgeBases(wait: Bool = false) {
    let pending = frames.filter { $0.edgeBase == nil && isSinglePicture($0) }
    guard !pending.isEmpty else { return }
    let project = sessionURL
    let measure = { pending.compactMap { f in (try? self.edgeSource(for: f)).flatMap { $0 }.map { (f.id, ImagePipeline.shared.edgeBase($0)) } } }
    let apply = { (results: [(UUID, EdgeBase)]) in
      guard self.sessionURL == project else { return }
      for (id, found) in results {
        if let i = self.frames.firstIndex(where: { $0.id == id }), self.frames[i].edgeBase == nil { self.frames[i].edgeBase = found }
      }
      self.updateRollBase()
      self.updateRollSlopes()
      self.refresh()
      self.updateThumbnails()
      self.saveProject()
    }
    if wait { apply(measure()) } else { renderQueue.async { let r = measure(); DispatchQueue.main.async { apply(r) } } }
  }
  /// The frames measured together as one roll, for the channel slopes and a shared film base:
  /// the scanned frames; each file holding several frames, an imported strip, on its own; and the
  /// pictures that are a file each, as a camera takes them, each apart, or with `poolPictures`
  /// those read alike (input gamma, bit depth) together.
  static func rollGroups(_ frames: [FilmFrame], poolPictures: Bool) -> [[FilmFrame]] {
    var perFile = [String: Int]()
    for path in frames.compactMap(\.sourcePath) { perFile[path, default: 0] += 1 }
    func key(_ f: FilmFrame) -> String {
      guard let path = f.sourcePath else { return "scanned" }
      if perFile[path, default: 0] > 1 || !poolPictures { return "file " + path }
      return "pictures γ\(f.adjustments.inputGamma) \(f.sourceBits ?? 0)-bit"
    }
    var order = [String](), groups = [String: [FilmFrame]]()
    for f in frames {
      let k = key(f)
      if groups[k] == nil { order.append(k) }
      groups[k, default: []].append(f)
    }
    return order.map { groups[$0]! }
  }
  /// The roll has pictures that are a file each, more than one: they can be measured together.
  var hasSinglePictures: Bool {
    var perFile = [String: Int]()
    for path in frames.compactMap(\.sourcePath) { perFile[path, default: 0] += 1 }
    return perFile.values.filter { $0 == 1 }.count >= 2
  }
  /// The roll has pictures read from a camera's sensor, which can have the copy light's crosstalk
  /// taken out; and whether they have.
  var hasSensorPictures: Bool { frames.contains { $0.sensorRead == true } }
  var crosstalkRemoved: Bool { frames.contains { $0.sensorRead == true && $0.crosstalk != nil } }
  /// Takes the copy light's crosstalk out of the roll's pictures read from the sensor, or puts it
  /// back, as one edit; the roll's next pictures, and the next roll's, follow. What was read off
  /// the pictures (a base picked, the grey and the white picked, the roll's base) is read again
  /// as the pictures now are: the same light mixed it, so it comes out of a reading as out of a
  /// pixel.
  ///
  /// The light as last calibrated on the stand gives the crosstalk and the flat field; before it has
  /// been, the crosstalk measured from the IT8 target, with no flat field. A reading is put back as
  /// it was lit (the old flat field), mixed again, and taken through the new: a base picked where it
  /// was picked, the others (a grey, a white, the roll's base) taken at the frame's middle. The bases
  /// at the edges are looked for again.
  func removeCrosstalk(_ on: Bool) {
    let light = preferences.lightCalibration
    let to: Crosstalk? = on ? light?.crosstalk ?? .measured : nil, flatTo: FlatField? = on ? light?.flat : nil
    let affected = frames.indices.filter { frames[$0].sensorRead == true && (frames[$0].crosstalk != to || frames[$0].flatField != flatTo) }
    preferences.removeCrosstalk = on
    guard !affected.isEmpty, !isWorking else { return }
    recordEdit(on ? "去串色" : "保留串色")
    for i in affected {
      let from = frames[i].crosstalk, flatFrom = frames[i].flatField, crop = frames[i].rect
      func inFile(_ p: CGPoint) -> CGPoint { CGPoint(x: crop.x + p.x * crop.width, y: crop.y + p.y * crop.height) }
      func moved(_ v: RGB?, at p: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> RGB? {
        v.map { reading in
          let lit = FlatField.moved(reading, at: inFile(p), from: flatFrom, to: nil)
          return FlatField.moved(Crosstalk.moved(lit, from: from, to: to), at: inFile(p), from: nil, to: flatTo)
        }
      }
      let picked = frames[i].adjustments.basePicked.map { CGPoint(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) } ?? CGPoint(x: 0.5, y: 0.5)
      frames[i].adjustments.base = moved(frames[i].adjustments.base, at: picked)
      frames[i].adjustments.rollBase = moved(frames[i].adjustments.rollBase)
      frames[i].adjustments.neutralSample = moved(frames[i].adjustments.neutralSample)
      frames[i].adjustments.highlightSample = moved(frames[i].adjustments.highlightSample)
      frames[i].crosstalk = to
      frames[i].flatField = flatTo
      frames[i].edgeBase = nil
    }
    status = on ? (flatTo == nil ? "已去掉翻拍光源的串色 · \(affected.count) 张" : "已去掉翻拍光源的串色和明暗不匀 · \(affected.count) 张")
      : "已保留串色 · \(affected.count) 张"
    updateRollBase()
    updateRollSlopes()
    refresh()
    updateThumbnails()
    saveProject()
    measureEdgeBases()
  }
  /// The copy light measured from the roll's last three pictures read from the sensor: blank frames,
  /// the red, green and blue light each alone. Kept for the copies to come, and this roll's pictures
  /// converted with it if the crosstalk is taken out of them.
  func calibrateLight() {
    let blanks = frames.filter { $0.sensorRead == true }.suffix(3)
    guard blanks.count == 3, !isWorking else { return }
    let paths = blanks.compactMap(\.sourcePath)
    status = "正在标定光源…"
    renderQueue.async {
      let images = paths.compactMap { try? ImagePipeline.shared.load(URL(fileURLWithPath: $0), maxDimension: 600) }
      let found = images.count == 3 ? ImagePipeline.shared.lightCalibration(images) : nil
      DispatchQueue.main.async {
        guard let (light, exposure) = found else {
          self.errorText = "标定不了：最近三张要是不放底片、只开红灯、只开绿灯、只开蓝灯各一张，每张曝光够（最亮处到满量程的一半以上）、不过曝。"
          return
        }
        self.preferences.lightCalibration = light
        let leak = light.crosstalk.largestLeak, names = ["红", "绿", "蓝"]
        let weak = (0..<3).filter { exposure.values[$0] < 0.15 }.map { names[$0] }
        self.status = String(format: "已标定光源：%@灯漏进%@通道 %.0f%%，四角最暗处是最亮处的 %.0f%% · %.0f%% · %.0f%%",
          names[leak.light], names[leak.channel], leak.share * 100,
          light.flat.falloff.r * 100, light.flat.falloff.g * 100, light.flat.falloff.b * 100)
          + (weak.isEmpty ? "" : "；\(weak.joined(separator: "、"))灯曝光偏暗，最好重拍到最亮处约 70%")
        if self.crosstalkRemoved || self.preferences.removeCrosstalk { self.removeCrosstalk(true) }
      }
    }
  }
  /// What the copy light's correction is now, for the panels.
  var lightDescription: String {
    guard let light = preferences.lightCalibration else { return "现在用的是 2026-10-29 用 IT8 色卡测的串色矩阵，没有平场。" }
    let leak = light.crosstalk.largestLeak, names = ["红", "绿", "蓝"]
    return String(format: "现在用的是 %@ 标定的光源：%@灯漏进%@通道 %.0f%%；平场：四角最暗处是最亮处的 %.0f%% · %.0f%% · %.0f%%（红 · 绿 · 蓝）。",
      light.date.formatted(date: .abbreviated, time: .shortened), names[leak.light], names[leak.channel], leak.share * 100,
      light.flat.falloff.r * 100, light.flat.falloff.g * 100, light.flat.falloff.b * 100)
  }
  /// Measures the roll's pictures that are a file each together, or each apart again.
  func setPoolPictures(_ pool: Bool) {
    guard pool != poolPictures else { return }
    poolPictures = pool
    status = pool ? "导入的单张一起做整卷估计" : "导入的单张各自估计"
    saveProject()
    updateRollSlopes()
  }
  /// Shares the film base picked on this frame (the leader, or a frame's edge) with its roll, for
  /// rolls without gaps between the frames to measure it in, as a camera's or pictures imported
  /// a file each. Frames with a base picked of their own keep it.
  func shareFilmBase() {
    guard !isWorking, let f = selected, let base = f.adjustments.base else { return }
    recordEdit("整卷共用片基")
    let group = Self.rollGroups(frames, poolPictures: true).first { $0.contains { $0.id == f.id } } ?? [f]
    let ids = Set(group.map(\.id))
    for i in frames.indices where ids.contains(frames[i].id) {
      frames[i].adjustments.rollBase = base
      frames[i].adjustments.rollBasePicked = true
    }
    status = "第 \(f.name) 张取的片基已用于整卷 \(group.count) 张"
    refresh()
    saveProject()
    // The film's toe bends from a measured base, so the estimate is taken again.
    updateRollSlopes()
  }
  /// Back to the film base measured between the frames, where there is one.
  func unshareFilmBase() {
    guard !isWorking, frames.contains(where: { $0.adjustments.rollBasePicked == true }) else { return }
    recordEdit("取消整卷片基")
    for i in frames.indices where frames[i].adjustments.rollBasePicked == true {
      frames[i].adjustments.rollBase = nil
      frames[i].adjustments.rollBasePicked = nil
    }
    updateRollBase()
    status = "已取消整卷片基"
    refresh()
    saveProject()
    updateRollSlopes()
  }
  /// Each frame turns from its own orientation, so portrait frames stay portrait.
  func turn(clockwise: Bool) {
    guard selectedIndex != nil else { return }
    viewWillChange?(.orient(turns: clockwise ? 1 : -1, mirror: false))
    orient(clockwise ? "顺时针旋转 90°" : "逆时针旋转 90°") { $0.turn(clockwise: clockwise) }
  }
  /// The mirror corrects how the whole strip lay in the holder, so syncing sets one value.
  func toggleMirror() {
    guard selectedIndex != nil else { return }
    let mirrored = settings.flipHorizontal != true
    viewWillChange?(.orient(turns: 0, mirror: true))
    orient(mirrored ? "水平镜像" : "取消水平镜像") { $0.flipHorizontal = mirrored }
  }
  /// The contact view's keys: always the whole roll, whether or not single view syncs.
  func turnRoll(clockwise: Bool) {
    guard !frames.isEmpty else { return }
    viewWillChange?(.orient(turns: clockwise ? 1 : -1, mirror: false))
    orient(clockwise ? "顺时针旋转 90°" : "逆时针旋转 90°", roll: true) { $0.turn(clockwise: clockwise) }
  }
  func mirrorRoll() {
    guard !frames.isEmpty else { return }
    let mirrored = !contactMirrored
    viewWillChange?(.orient(turns: 0, mirror: true))
    orient(mirrored ? "水平镜像" : "取消水平镜像", roll: true) { $0.flipHorizontal = mirrored }
  }
  private func orient(_ action: String, roll: Bool = false, _ mutation: (inout Adjustments) -> Void) {
    recordEdit(action)
    if syncOrientation || roll {
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
    recordEdit("同步到本卷")
    for i in frames.indices {
      let own = frames[i].adjustments
      frames[i].adjustments = s.adjustments
      frames[i].adjustments.rotation = own.rotation
      frames[i].adjustments.angle = own.angle
      frames[i].adjustments.rollBase = own.rollBase
      frames[i].adjustments.rollSlopes = own.rollSlopes
      frames[i].adjustments.rollBasePicked = own.rollBasePicked
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
    // The name typed over is the preset shown before it.
    recordEdit("胶片预设", filmName: profile.name)
    // A film calibrated on this scanner is used without having to pick it.
    profile = calibrated(for: found) ?? found
    updateRollSlopes()
    refresh()
    updateThumbnails()
    saveProject()
  }
  /// The newest preset calibrated from `film` for what the roll was read with: this scanner, or the
  /// camera on the copy stand.
  func calibrated(for film: FilmProfile) -> FilmProfile? {
    let made = film.name + (copyStandRoll ? " · 翻拍" : " · V850")
    return film.offsets != nil ? nil : profiles.last { $0.offsets != nil && $0.name == made }
  }
  /// The roll was copied on the camera stand, not scanned: its neutral points make a copy-stand preset.
  var copyStandRoll: Bool { rollSource == .camera || frames.contains { $0.sensorRead == true } }
  func chooseProfile(_ p: FilmProfile) {
    recordEdit("胶片预设")
    filmName = p.name
    profile = p
    updateRollSlopes()
    refresh()
    updateThumbnails()
    saveProject()
  }
  /// Estimates channel slopes across each roll (`rollGroups`) and shares them with its frames.
  /// They are the fallback when the preset is not calibrated.
  func updateRollSlopes(completion: (() -> Void)? = nil) {
    let snapshot = frames, green = profile.slopes.g, toe = profile.toe, pool = poolPictures
    rollSlopesRevision += 1
    let token = rollSlopesRevision
    renderQueue.async {
      var result = [UUID: RGB?]()
      for members in Self.rollGroups(snapshot, poolPictures: pool) {
        let inputs = members.compactMap { f in
          (try? self.source(for: f, maxDimension: 600)).map { (image: $0, settings: f.adjustments) }
        }
        // The toe only bends from a measured film base, as in the conversion.
        let measured = inputs.allSatisfy { ($0.settings.base ?? $0.settings.rollBase) != nil }
        let slopes = ImagePipeline.shared.rollSlopes(inputs, greenSlope: green, toe: measured ? toe : nil)
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
      let measured = calibrationPoints.allSatisfy { point in
        frames.first { $0.id == point.frame }.map { ($0.adjustments.base ?? $0.adjustments.rollBase) != nil } ?? false
      }
      let fit = try FilmCalibration.fit(calibrationPoints, greenSlope: profile.slopes.g, curve: measured ? profile.dataSheetToe : nil)
      let copy = copyStandRoll
      // How the points' frames were read: the slopes hold for that reading.
      let readings = Set(calibrationPoints.compactMap { p in frames.first { $0.id == p.frame }.map { $0.crosstalk != nil } })
      // Where they were picked, kept with the preset and marked on their frames.
      let spots = calibrationPoints.compactMap { p in
        p.at.flatMap { at in frames.first { $0.id == p.frame }.map { CalibrationSpot(frame: p.frame, name: $0.name, x: at.x, y: at.y) } }
      }
      let made = FilmCalibration.profile(
        from: fit, basedOn: profile, points: calibrationPoints.count,
        scanner: copy ? (camera.model.isEmpty ? "A7R IV" : camera.model) : scanner.name, copyStand: copy,
        unmixed: readings.count == 1 ? readings.first : nil, spots: spots.isEmpty ? nil : spots)
      try made.validate()
      keepProfile(made)
      calibrationPoints = []
      showCalibrationPoints = true
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

  // MARK: Scanner calibration (IT8)

  /// The target's reference data, while a scan of it is marked and measured.
  @Published var it8Reference: IT8Reference?
  /// Points clicked on the selected frame, in 0–1 of its raw image, in `IT8Layout.marks` order.
  @Published var it8Marks = [CGPoint]()
  /// The overview as statistics and the contact view use it: a 48-bit preview loses its stray light.
  private func overviewWorkingCopy(_ image: CGImage, backend: String?) -> CGImage {
    guard backend == "epson2-linear-v1", preferences.removeFlare, let offset = preferences.scannerCalibration?.offset else { return image }
    return ImagePipeline.shared.removingFlare(offset, from: image)
  }
  func importIT8Reference() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.plainText, .text]
    panel.message = "选择与色卡批号一致的 IT8.7/1 参考文件（如 MONT45.2022.07.txt）"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let text = try String(contentsOf: url, encoding: .isoLatin1)
      it8Reference = try IT8Reference.parse(text, name: url.deletingPathExtension().lastPathComponent)
      status = "已读入参考文件「\(it8Reference!.name)」· \(it8Reference!.batch)"
    } catch { errorText = error.localizedDescription }
  }
  func startIT8Marking() {
    guard it8Reference != nil, selected != nil else { return }
    it8Marks = []
    useTool(.it8)
    status = "在色卡上依次点：\(IT8Layout.marks.joined(separator: "、"))"
  }
  func undoIT8Mark() {
    guard !it8Marks.isEmpty else { return }
    it8Marks.removeLast()
  }
  /// Measures the scanner on the selected frame, a scan of the target, from the six points.
  func measureIT8() {
    guard let reference = it8Reference, let frame = selected, it8Marks.count == IT8Layout.marks.count else { return }
    do {
      let readings = try IT8Layout.sample(try source(for: frame, full: true, raw: true), marks: it8Marks)
      let result = try ScannerCalibration.measure(readings, reference: reference)
      preferences.scannerCalibration = result
      it8Marks = []
      useTool(.select)
      reapplyScannerCalibration()
      status = String(
        format: "已标定扫描仪 · 杂散光 R %.2f%% · G %.2f%% · B %.2f%% · 灰阶误差 %.3f → %.3f D · 色块 ΔE 平均 %.1f",
        result.flare.r * 100, result.flare.g * 100, result.flare.b * 100, result.grayErrorBefore, result.grayError,
        result.meanDeltaE)
    } catch { errorText = error.localizedDescription }
  }
  func removeScannerCalibration() {
    preferences.scannerCalibration = nil
    reapplyScannerCalibration()
  }
  /// The open project read again, so every frame, the film base and the thumbnails take the
  /// calibration in or out.
  func reapplyScannerCalibration() {
    guard let project = sessionURL?.appendingPathComponent(projectFileName), FileManager.default.fileExists(atPath: project.path)
    else { return }
    saveProject()
    let keep = selectedID
    loadProject(project)
    if let keep, frames.contains(where: { $0.id == keep }) { select(keep) }
  }
  /// `maxDimension` overrides the preview size, for statistics that need less. `raw` leaves the
  /// scanner's stray light in, for measuring it.
  func source(for frame: FilmFrame, full: Bool = false, maxDimension: Int? = nil, raw: Bool = false) throws -> CGImage {
    let image = try uncorrectedSource(for: frame, full: full, maxDimension: maxDimension)
    return raw ? image : corrected(image, frame, scan: Self.readsScan(frame))
  }
  /// Whether a frame's pixels come from its own scan, rather than the preview or an imported file.
  static func readsScan(_ frame: FilmFrame) -> Bool { frame.sourcePath == nil && frame.scanPath != nil && frame.hasFullResolution }
  /// A scan put on its preview's scale, then its stray light taken out, in one step.
  private func corrected(_ image: CGImage, _ frame: FilmFrame, scan: Bool) -> CGImage {
    let levels = scan ? frame.levels.flatMap { $0.usable ? $0 : nil } : nil
    let flare = flareOffset(frame)
    guard levels != nil || flare != nil else { return image }
    let scale = levels?.scale ?? RGB(r: 1, g: 1, b: 1), bias = levels?.bias ?? RGB(r: 0, g: 0, b: 0)
    let f = flare ?? RGB(r: 0, g: 0, b: 0)
    return ImagePipeline.shared.leveled(image, scale: scale, bias: RGB((0..<3).map { bias.values[$0] - f.values[$0] }))
  }
  /// Whether a frame's scan can be put on its preview's scale: this app's linear scans, against
  /// a 48-bit preview of the same holder.
  func canRegister(_ frame: FilmFrame) -> Bool {
    Self.readsScan(frame) && overviewBackendID == "epson2-linear-v1" && frame.adjustments.inputGamma == 1 && overviewURL != nil
  }
  /// Measures a scan against the preview; `unmeasured` when its levels cannot be told apart.
  func measureLevels(_ frame: FilmFrame) -> LevelRegistration? {
    guard canRegister(frame), let path = frame.scanPath, let url = overviewURL,
      let scan = try? ImagePipeline.shared.loadDecoded(URL(fileURLWithPath: path)), let preview = try? overviewCache.image(url)
    else { return nil }
    return LevelRegistration.measure(scan: scan, footprint: frame.captureRect, preview: preview, region: frame.rect) ?? .unmeasured
  }
  /// Scans in a project from before 0.4.9 have no measured levels; they are measured against the
  /// preview once, then the frames are converted again. `wait` measures before returning.
  func registerMissingLevels(wait: Bool = false) {
    let pending = frames.filter { $0.levels == nil && canRegister($0) }
    guard !pending.isEmpty else { return }
    let project = sessionURL
    let measure = { pending.compactMap { f in self.measureLevels(f).map { (f.id, $0) } } }
    let apply = { (results: [(UUID, LevelRegistration)]) in
      guard self.sessionURL == project else { return }
      for (id, levels) in results { if let i = self.frames.firstIndex(where: { $0.id == id }) { self.frames[i].levels = levels } }
      let aligned = results.filter { $0.1.usable }.count
      self.status = "已把 \(aligned) 张正式扫描对齐到预览" + (aligned < results.count ? " · \(results.count - aligned) 张无法对齐，保持原样" : "")
      self.saveProject()
      self.updateRollSlopes()
      self.refresh()
      self.updateThumbnails()
    }
    if wait { apply(measure()) } else { renderQueue.async { let r = measure(); DispatchQueue.main.async { apply(r) } } }
  }
  /// The stray light to take out of a frame's readings: this app's linear scans and previews, while
  /// a scanner calibration is in use. Imported files and older 24-bit scans keep what they read.
  func flareOffset(_ frame: FilmFrame) -> RGB? {
    guard preferences.removeFlare, let calibration = preferences.scannerCalibration, frame.sourcePath == nil,
      frame.adjustments.inputGamma == 1
    else { return nil }
    return calibration.offset
  }
  /// Files read to render from, at a size, kept so that a slider dragged over a frame does not
  /// read its 300 MB TIFF again each step (a quarter of a second, more the first time): the last
  /// few, never a full-resolution one, which the zoom keeps on its own.
  ///
  /// At full resolution the file is decoded once into memory: left to be read as it is drawn,
  /// Core Image reads it again for each tile it renders, and a 60-megapixel frame took 11 s to
  /// analyse and 11 more to render, against well under a second each decoded.
  private let readLock = NSLock()
  private var read = [(key: String, image: CGImage)]()
  ///
  /// With `crosstalk` and `flat`, the copy light's crosstalk and then its fall-off are taken out as
  /// the file is read, so whatever is measured on the picture measures it without.
  private func load(_ url: URL, maxDimension: Int?, crosstalk: Crosstalk? = nil, flat: FlatField? = nil) throws -> CGImage {
    let pipe = ImagePipeline.shared
    func unmixed(_ image: CGImage) -> CGImage { pipe.corrected(image, crosstalk: crosstalk, flat: flat) }
    guard let maxDimension else { return unmixed(try pipe.loadDecoded(url)) }
    let key = "\(url.path)@\(maxDimension)" + (crosstalk.map { "-\($0.m)" } ?? "")
      + (flat.map { "-flat\($0.width)x\($0.height)-\($0.values.reduce(0, +))" } ?? "")
    readLock.lock()
    let kept = read.first { $0.key == key }?.image
    readLock.unlock()
    if let kept { return kept }
    let image = unmixed(try pipe.load(url, maxDimension: maxDimension))
    readLock.lock()
    read.removeAll { $0.key == key }
    read.insert((key, image), at: 0)
    // The frame shown and the two either side of it, read ahead, and one more.
    if read.count > 4 { read.removeLast() }
    readLock.unlock()
    return image
  }
  private func uncorrectedSource(for frame: FilmFrame, full: Bool, maxDimension: Int?) throws -> CGImage {
    if let path = frame.scanPath, frame.hasFullResolution {
      let raw = try load(URL(fileURLWithPath: path), maxDimension: full ? nil : maxDimension ?? 2200)
      return try ImagePipeline.shared.crop(raw, rect: frame.rect.relative(to: frame.captureRect))
    }
    if let path = frame.sourcePath {
      let image = try load(URL(fileURLWithPath: path), maxDimension: full ? nil : maxDimension ?? 3000, crosstalk: frame.crosstalk, flat: frame.flatField)
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
      return (try load(URL(fileURLWithPath: path), maxDimension: 3000, crosstalk: frame.crosstalk, flat: frame.flatField), .full)
    }
    if let path = frame.scanPath, frame.hasFullResolution {
      let scan = try load(URL(fileURLWithPath: path), maxDimension: 3000)
      return (corrected(scan, frame, scan: true), frame.captureRect)
    }
    guard let url = overviewURL else { throw DeskError.message("尚无图像。") }
    let region = editRegionLock ?? frame.rect.expanded(by: 0.14)
    let context = pipe.scaled(try pipe.crop(overviewCache.image(url), rect: region), maxDimension: 3000)
    return (flareOffset(frame).map { pipe.removingFlare($0, from: context) } ?? context, region)
  }
  /// The loupe's key, as the tools' are: shows it on the picture, or puts it away.
  static let loupeShortcut = "z"
  /// Shows the loupe on the selected frame, or puts it away; `shown` sets it either way.
  func toggleLoupe(_ shown: Bool? = nil) {
    loupeCenter = nil
    preferences.showLoupe = shown ?? !preferences.showLoupe
  }
  /// The frame under the loupe from the frame's own pixels: on the light table as the contact view
  /// shows it, positive or raw (its scan, or the full-resolution preview); over the single frame
  /// as that view shows it, turned and mirrored, at full resolution.
  func loupeDetail(for frame: FilmFrame, single: Bool = false, pixels: Int = 2400, completion: @escaping (CGImage?) -> Void) {
    let positive = single ? !showNegative : contactPositive, p = profile
    renderQueue.async {
      var image = try? self.source(for: frame, full: single, maxDimension: single ? nil : pixels)
      if single, let crop = image {
        image = ImagePipeline.shared.render(crop, settings: frame.adjustments, profile: p, analysis: nil, negative: !positive)
      } else if positive, let crop = image {
        // Upright and as it lies, as in the contact print, so it lies under its frame box.
        var s = frame.adjustments
        s.rotation = 0
        s.flipHorizontal = nil
        s.angle = nil
        image = try? ImagePipeline.shared.preview(crop, settings: s, profile: p)
      }
      DispatchQueue.main.async { completion(image) }
    }
  }
  /// A frame's size on the film, in millimetres, as it lies (before it is turned): its share of
  /// the bed for a scan, or a file's pixels at its dpi (a camera's long side is taken as 36 mm).
  func frameMM(_ frame: FilmFrame) -> CGSize? {
    guard let path = frame.sourcePath else {
      guard physicalMM.width > 0 else { return nil }
      return CGSize(width: frame.rect.width * physicalMM.width, height: frame.rect.height * physicalMM.height)
    }
    guard let dpi = frame.scanDPI, dpi > 0 else { return nil }
    let pixels = filePixels(path)
    guard pixels.width > 0 else { return nil }
    let mm = 25.4 / Double(dpi)
    return CGSize(width: frame.rect.width * pixels.width * mm, height: frame.rect.height * pixels.height * mm)
  }
  /// A file's size in pixels, read once.
  private var filePixelsRead = [String: CGSize]()
  private func filePixels(_ path: String) -> CGSize {
    if let known = filePixelsRead[path] { return known }
    let info = ImagePipeline.shared.info(URL(fileURLWithPath: path))
    let size = CGSize(width: info.width, height: info.height)
    filePixelsRead[path] = size
    return size
  }
  /// A part of the single frame at its own resolution, for the canvas zoomed in past the picture
  /// it shows: `region` in that picture's normalised coordinates, rendered as the frame is now
  /// (`key`, the loupe's), turned and mirrored as it is shown.
  struct Detail {
    var key: String
    var region: NormalRect
    var image: CGImage
  }
  /// The selected frame at its own resolution, read once for all the parts zoomed into; only on
  /// the render queue.
  private var detailSource: (key: String, image: CGImage)?
  func releaseDetailSource() { renderQueue.async { self.detailSource = nil } }
  /// `region` of the single frame at its own resolution, rendered with the whole frame's analysis
  /// (its base, white balance and levels) so it matches the picture around it. Nil until the
  /// frame has been analysed.
  func renderDetail(_ frame: FilmFrame, region: NormalRect, completion: @escaping (Detail?) -> Void) {
    // Never answered at once: an asker that asks again on an answer would never stop.
    guard let analysis = toneAnalysis else { return DispatchQueue.main.async { completion(nil) } }
    let negative = showNegative || tool == .base, p = profile, key = loupeDetailKey(frame, single: true)
    renderQueue.async {
      let source = [frame.id.uuidString, "\(frame.rect)", frame.scanPath ?? "", frame.sourcePath ?? ""].joined(separator: "|")
      if self.detailSource?.key != source {
        self.detailSource = nil
        self.detailSource = (try? self.source(for: frame, full: true)).map { (source, $0) }
      }
      var detail: Detail?
      // The whole frame as shown, straightened, turned and mirrored, of which only the part asked
      // for is worked out.
      if let full = self.detailSource?.image,
        let part = ImagePipeline.shared.render(full, region: region, settings: frame.adjustments, profile: p, analysis: analysis, negative: negative)
      {
        detail = Detail(key: key, region: part.region, image: part.image)
      }
      DispatchQueue.main.async { completion(detail) }
    }
  }
  /// Changes whenever the loupe's picture of `frame` would.
  func loupeDetailKey(_ frame: FilmFrame, single: Bool = false) -> String {
    // Keys sorted: without, the encoder's order is not promised, and the same frame could ask for
    // its picture again on every draw.
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let settings = (try? encoder.encode(frame.adjustments)).map { $0.base64EncodedString() } ?? ""
    let shown = single ? "single \(!showNegative)" : "table \(contactPositive)"
    return [frame.id.uuidString, "\(frame.rect)", frame.scanPath ?? "", shown, profile.id, settings]
      .joined(separator: "|")
  }
  /// How far the picture's render has got, while it runs: the share done and the step under way.
  @Published private(set) var renderStep: (done: Double, label: String)?
  /// From the render queue, for the render still wanted.
  private func step(_ done: Double, _ label: String, _ token: Int) {
    DispatchQueue.main.async {
      guard self.revision == token, self.rendering else { return }
      self.renderStep = (done, label)
    }
  }
  /// A picture of the roll's own file, as the light table shows it, kept for the next time; only
  /// on the render queue.
  /// The luminance and channel histograms of a positive, 64 bins each, each scaled to its peak.
  static func histograms(_ image: CGImage) -> ([Double], [[Double]]) {
    let r = ImagePipeline.shared.raster(image, maxDimension: 250)
    var hist = [Double](repeating: 0, count: 64)
    var channels = [[Double]](repeating: [Double](repeating: 0, count: 64), count: 3)
    for y in 0..<r.height {
      for x in 0..<r.width {
        let c = r.pixel(x, y)
        let l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        hist[min(63, max(0, Int(l * 63)))] += 1
        for (i, v) in c.values.enumerated() { channels[i][min(63, max(0, Int(v * 63)))] += 1 }
      }
    }
    let maxBin = hist.max() ?? 1, maxChannel = channels.joined().max() ?? 1
    return (hist.map { $0 / max(1, maxBin) }, channels.map { $0.map { $0 / max(1, maxChannel) } })
  }
  func refresh() {
    revision += 1
    let token = revision
    wantedLock.lock()
    wantedRevision = token
    wantedLock.unlock()
    renderWork?.cancel()
    renderStep = nil
    guard singleView, let frame = selected else {
      canvasRegion = nil
      samplingInput = nil
      toneAnalysis = nil
      // The curves' histograms, from the selected frame's positive as the filmstrip has it.
      if let picture = selected.flatMap({ thumbnails[$0.id] }) { (histogram, channelHistograms) = Self.histograms(picture) }
      // Frames of their own files (a camera's, imports) on a page laid out as a contact sheet:
      // positives from the film strip's, negatives read small from their files.
      if onSheetPage {
        let page = sheetPageFrames, positive = contactPositive, positives = thumbnails, pages = contactPages.count
        let index = contactPage
        // Back from the single frame, the page as it was until the new one is laid out.
        if let kept = tablePrint, kept.page == index, kept.positive == positive,
          displayed?.width != kept.image.width || displayed?.height != kept.image.height
        {
          displayed = kept.image
        }
        rendering = true
        let work = DispatchWorkItem { [weak self] in
          guard let self else { return }
          self.step(0.2, "排接触表", token)
          let tiles = page.map { f -> (name: String, image: CGImage?) in
            (f.name, positive ? positives[f.id] : try? self.source(for: f, maxDimension: 480))
          }
          let sheet = Self.composeSheet(tiles, pages: pages)
          DispatchQueue.main.async {
            guard self.revision == token else { return }
            if let sheet {
              self.displayed = sheet
              self.tablePrint = (index, positive, sheet)
            }
            self.rendering = false
          }
        }
        renderWork = work
        renderQueue.asyncAfter(deadline: .now() + 0.05, execute: work)
        return
      }
      // Frames that lie on the displayed overview; imports from other files are not on it.
      let onOverview = frames.filter { $0.sourcePath == nil || $0.sourcePath == overviewURL?.path }
      guard contactPositive, let overview, !onOverview.isEmpty else {
        displayed = overview
        rendering = false
        return
      }
      // Keep a previous print while re-rendering, so dragging a frame box does not flicker; back
      // from the single frame, the last print made.
      if displayed?.width != overview.width || displayed?.height != overview.height {
        let index = contactPage
        displayed = tablePrint.flatMap { $0.page == index && $0.positive && $0.image.width == overview.width && $0.image.height == overview.height ? $0.image : nil } ?? overview
      }
      let p = profile
      rendering = true
      let work = DispatchWorkItem { [weak self] in
        self?.step(0.3, "冲印接触表", token)
        let print = ImagePipeline.shared.contactPrint(overview, frames: onOverview, profile: p)
        DispatchQueue.main.async {
          guard let self, self.revision == token else { return }
          self.displayed = print ?? overview
          if let print { self.tablePrint = (self.contactPage, true, print) }
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
    let sharpening = preferences.sharpening
    let previewDPI = Int(overviewDPI)
    rendering = true
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      do {
        self.step(0.05, frame.sourcePath != nil || Self.readsScan(frame) ? "读取原图" : "读取预览", token)
        let cropped = try self.source(for: frame)
        self.step(0.4, "分析片基、白平衡和色阶", token)
        let analysis = ImagePipeline.shared.analyze(
          cropped, settings: frame.adjustments, profile: p)
        self.step(0.6, negative ? "显示负片" : "冲印正片", token)
        let context = edit ? try self.contextSource(for: frame) : nil
        let input = context?.image ?? cropped
        // Its surroundings as they lie while the crop or base is edited, with the kept part outlined.
        var shownSettings = frame.adjustments
        if edit { shownSettings.angle = nil }
        // The kernel follows the size the source was loaded at, as in source(for:) and contextSource(for:).
        let loaded = edit ? 3000 : (frame.sourcePath != nil ? 3000 : 2200)
        let sharpener = negative ? nil : Sharpening.sharpener(sharpening, frame: frame, maxDimension: loaded)
        guard
          let output = ImagePipeline.shared.render(
            input, settings: shownSettings, profile: p, analysis: analysis, negative: negative,
            sharpener: sharpener)
        else { throw DeskError.message("无法生成预览") }
        self.step(0.9, "直方图", token)
        let (hist, channels) = Self.histograms(output)
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
          "\(Int(pixels.width)) × \(Int(pixels.height)) · \(frame.hasFullResolution ? (frame.scanDPI.map{String($0)+" dpi"} ?? "源图") : previewDPI >= 600 ? "\(previewDPI) dpi 预览" : "低清预览")"
          + (Self.readsScan(frame) && frame.levels?.usable == true ? " · 已对齐预览" : "")
        DispatchQueue.main.async {
          guard self.revision == token else { return }
          self.displayed = output
          self.canvasRegion = context?.region
          self.samplingInput = input
          self.toneAnalysis = analysis
          if edit { self.editRegionLock = context?.region }
          if !edit && !negative { self.thumbnails[frame.id] = output }
          self.histogram = hist
          self.channelHistograms = channels
          self.rendering = false
          self.sourceSummary = summary
          self.readAhead(around: frame, token: token)
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
  /// The frames either side of the one shown, read from their files while it is looked at, so that
  /// → and ← show them as soon as they are drawn: after the frame's own render, on the same queue,
  /// the one after first. Another render wanted first, the rest is left.
  private func readAhead(around frame: FilmFrame, token: Int) {
    guard singleView, let i = frames.firstIndex(where: { $0.id == frame.id }) else { return }
    let around = [i + 1, i - 1].filter(frames.indices.contains).map { frames[$0] }
    renderQueue.async { [weak self] in
      for f in around {
        guard let self, self.isCurrent(token) else { return }
        _ = try? self.source(for: f)
      }
    }
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
    if tool == .it8 {
      guard singleView, it8Marks.count < IT8Layout.marks.count else { return }
      it8Marks.append(ImageGeometry.raw(point, settings: frames[i].adjustments, aspect: shownAspect(frames[i])))
      status = it8Marks.count < IT8Layout.marks.count
        ? "下一个：\(IT8Layout.marks[it8Marks.count]) 的中心" : "6 个点已就位 · 检查色块位置后点「生成标定」"
      return
    }
    let input: CGImage
    if singleView {
      guard let samplingInput else { return }
      input = samplingInput
    } else {
      guard let overview else { return }
      input = overview
    }
    let r = ImagePipeline.shared.samples(input, maxDimension: 2000)
    let pt = singleView ? ImageGeometry.raw(point, settings: frames[i].adjustments, aspect: shownAspect(frames[i])) : point
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
      let crop = frames[i].rect
      let point = NeutralPoint(
        frame: frames[i].id, value: color,
        base: RGB((0..<3).map { analysis.base.values[$0] * pow(2, fine.values[$0]) }),
        gamma: frames[i].adjustments.inputGamma,
        at: CGPoint(x: crop.x + pt.x * crop.width, y: crop.y + pt.y * crop.height))
      calibrationPoints.append(point)
      let span = calibrationPoints.map { $0.density[1] }
      status = String(
        format: "已取 %d 个中性点 · 本点绿色密度 %.2f · 跨度 %.2f D", calibrationPoints.count, point.density[1],
        (span.max() ?? 0) - (span.min() ?? 0))
      return
    }
    if tool == .base {
      let at = singleView
        ? NormalRect(x: pt.x - Double(radius) / Double(r.width), y: pt.y - Double(radius) / Double(r.height),
          width: Double(2 * radius + 1) / Double(r.width), height: Double(2 * radius + 1) / Double(r.height))
        : nil
      setFilmBase(color, at: at)
    } else if tool == .neutral {
      setNeutral(color)
    } else if tool == .highlight {
      setHighlight(color)
    }
    tool = .select
    refresh()
  }
  /// The film base from a reading of unexposed film; the white balance is left as picked, not
  /// recalculated. One edit to undo, whether picked on the canvas or by an assistant.
  func setFilmBase(_ color: RGB, at place: NormalRect? = nil) {
    change("取片基") {
      $0.base = color
      $0.basePicked = place
      $0.baseFine = nil
      $0.manualBalance = nil
      $0.neutralSample = nil
      $0.autoWhiteBalance = false
    }
    status = "已取片基 · 自动白平衡已关闭以保留取样，可按需重算"
    updateThumbnails()
  }
  /// Auto white balance on a reading of something that should be grey: the grey sets the
  /// balance, and auto stays on to fit each channel's contrast where the preset leaves that to it.
  func setNeutral(_ color: RGB) {
    change("中性点") {
      $0.manualBalance = nil
      $0.neutralSample = color
      $0.autoWhiteBalance = true
    }
    status = "已按中性点自动白平衡"
    updateThumbnails()
  }
  /// The densest highlight (Dmax) from a reading of something that should be white: each
  /// channel's white is put on it.
  func setHighlight(_ color: RGB) {
    change("高光点") { $0.highlightSample = color }
    status = "已取高光（Dmax）：这一点在正片里是白色，各通道以它为白点对齐"
    updateThumbnails()
  }
  func scanEnabled() {
    guard !isWorking else { return }
    startScanBatch(frames.filter { $0.enabled && $0.sourcePath == nil }.map(\.id))
  }
  /// The toolbar's and menu's scans. A batch first shows what it will take; a single frame only
  /// when the disk is too full for it.
  func requestScanEnabled() {
    guard !isWorking else { return }
    let targets = frames.filter { $0.enabled && $0.sourcePath == nil }
    guard !targets.isEmpty else { return }
    let plan = scanPlan(targets)
    guard (targets.count == 1 && plan.fits) || confirmScan(plan, "扫描 \(plan.frames) 张 · \(plan.dpi) dpi？", "开始扫描") else { return }
    scanEnabled()
  }
  func requestScanSelected() {
    guard let selected, !isWorking else { return }
    if selected.sourcePath == nil {
      let plan = scanPlan([selected])
      guard plan.fits || confirmScan(plan, "扫描第 \(selected.name) 张 · \(plan.dpi) dpi？", "开始扫描") else { return }
    }
    scanSelected()
  }
  /// Asks before a scan, with the plan's summary; true starts it. Tests answer for the user.
  var confirmScan: (ScanPlan, String, String) -> Bool = { plan, title, button in
    let answer = AppModel.scanAlert(plan, title: title, button: button).runModal()
    return answer == (plan.fits ? .alertFirstButtonReturn : .alertSecondButtonReturn)
  }
  static func scanAlert(_ plan: ScanPlan, title: String, button: String) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = plan.fits ? title : "磁盘空间不足"
    alert.informativeText = plan.summary
    if plan.fits {
      alert.addButton(withTitle: button)
      alert.addButton(withTitle: "取消")
    } else {
      // Not enough room: cancelling is the default.
      alert.alertStyle = .critical
      alert.addButton(withTitle: "取消")
      alert.addButton(withTitle: "仍然扫描")
    }
    return alert
  }
  /// What scanning these frames would take at `dpi` (the chosen resolution by default).
  func scanPlan(_ targets: [FilmFrame], dpi planDPI: Int? = nil, forSheet: Bool = false) -> ScanPlan {
    let dpi = planDPI ?? self.dpi
    return ScanPlan.make(
      scanPasses(targets, dpi: dpi), physicalMM: physicalMM, dpi: dpi, bitsPerChannel: max(8, scanner.bits),
      export: preferences.autoExport && !forSheet ? preferences.exportFormat : nil,
      speed: preferences.scanSpeed[ScanPlan.speedKey(backend: scanner.backendID, dpi: dpi)],
      available: Self.availableBytes(at: libraryURL))
  }
  /// Free space on the volume the library is on, from its nearest folder that exists.
  static func availableBytes(at url: URL) -> Double? {
    var folder = url
    while !FileManager.default.fileExists(atPath: folder.path) && folder.pathComponents.count > 1 {
      folder.deleteLastPathComponent()
    }
    return (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage.map(Double.init)
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
    let targets = ids.compactMap { id in frames.first { $0.id == id } }
    scanQueue = scanPasses(targets, dpi: batchDPI ?? dpi).map { $0.map(\.id) }
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
    let ids = scanQueue.removeFirst()
    let pass = ids.compactMap { id in frames.first { $0.id == id } }
    guard !pass.isEmpty, pass.count == ids.count else {
      stopScanBatch(message: "待扫描的画面已不存在。")
      return
    }
    let rect = ScanPasses.union(pass)
    do {
      let root = try makeSession()
      let raw = root.appendingPathComponent("Originals")
      try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
      currentScan = ids
      currentScanRect = rect
      currentScanReceivedFile = false
      receiveError = nil
      scanBatch.beginFrame(count: ids.count)
      activeScanDPI = batchDPI ?? dpi
      scanStarted = Date()
      let captureRect: NormalRect
      if scanner.backendID == "epson2-linear-v1" {
        captureRect = NormalRect(x: rect.x * physicalMM.width / scanner.physicalMM.width,
          y: rect.y * physicalMM.height / scanner.physicalMM.height,
          width: rect.width * physicalMM.width / scanner.physicalMM.width,
          height: rect.height * physicalMM.height / scanner.physicalMM.height)
      } else { captureRect = rect }
      let name = pass.count == 1 ? pass[0].name : "row-" + pass.map(\.name).joined(separator: "-")
      try scanner.scan(
        rect: captureRect, dpi: activeScanDPI, directory: raw,
        name: "\(name)_\(activeScanDPI)dpi_\(UUID().uuidString.prefix(6))")
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
      stopScanBatch(message: receiveError ?? "驱动结束扫描，但没有返回可读取的图像文件。")
      return
    }
    let scanned = currentScan ?? []
    currentScan = nil
    currentScanRect = nil
    currentScanReceivedFile = false
    scanBatch.completeFrame()
    if cancelRequested { scanBatch.stop(cancelled: true) }
    status = scanBatch.summary
    saveProject()
    // The scan itself stays a raw negative. Its positive is exported when the batch ends, once the
    // roll estimate has taken the new scans in, so the file matches what the app shows. Scans
    // made for a contact sheet only feed the sheet.
    if preferences.autoExport, pendingSheet == nil { autoExportIDs += scanned }
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
    currentScanRect = nil
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
    // New scans are bound to the frames as they are now.
    if scanBatch.completed > 0 { clearEdits() }
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
    guard let ids = currentScan, let rect = currentScanRect else { return }
    let pass = ids.compactMap { id in frames.firstIndex { $0.id == id } }
    guard pass.count == ids.count else { return }
    let info = ImagePipeline.shared.info(url)
    guard info.width > 0, info.height > 0, info.bits > 0 else { return }
    // Where the scanner actually read, in the overview's coordinates.
    let footprint = scanner.actualScanAreaMM.map {
      NormalRect(x: $0.minX / physicalMM.width, y: $0.minY / physicalMM.height,
        width: $0.width / physicalMM.width, height: $0.height / physicalMM.height)
    } ?? rect
    var originals = [UUID: (path: String, rect: NormalRect)]()
    if pass.count == 1 {
      originals[ids[0]] = (url.path, footprint)
    } else {
      do {
        originals = try Self.split(url, footprint: footprint, frames: pass.map { frames[$0] }, dpi: activeScanDPI)
        try? FileManager.default.removeItem(at: url)
      } catch {
        // The pass stays on disk; nothing is lost, the batch stops.
        receiveError = "无法把整行扫描分成每张的原始文件：\(error.localizedDescription)。整行扫描保留在 Originals。"
        return
      }
    }
    currentScanReceivedFile = true
    for i in pass {
      guard let original = originals[frames[i].id] else { continue }
      frames[i].scanPath = original.path
      frames[i].scanRect = original.rect
      frames[i].sourcePath = nil
      frames[i].scanDPI = activeScanDPI
      frames[i].sourceBits = info.bits
      // Each scan on the preview's scale, whatever levels the scanner chose for its window.
      frames[i].levels = measureLevels(frames[i])
    }
    if let started = scanStarted {
      let predicted = ScanTiming.seconds(
        widthMM: rect.width * physicalMM.width, heightMM: rect.height * physicalMM.height, dpi: activeScanDPI,
        bytesPerPixel: Double(info.bits * 3) / 8)
      preferences.recordScan(backend: scanner.backendID, dpi: activeScanDPI, seconds: Date().timeIntervalSince(started), predicted: predicted)
      scanStarted = nil
    }
    let names = pass.map { frames[$0].name }
    status = (names.count == 1 ? "第 \(names[0]) 张" : "第 \(names.joined(separator: "、")) 张（一次扫完）") + "扫描完成 · \(info.bits*3)-bit 原始负片已存入 Originals"
      + (preferences.autoExport && pendingSheet == nil ? " · 整批扫完后正片导出到 Exports" : " · 正片请在「输出」导出")
    saveProject()
    if let selectedID, ids.contains(selectedID) { refresh() }
    updateThumbnails()
  }
  /// Cuts a pass over several frames into each frame's own original, as if it had been scanned
  /// alone: the frame's box rounded out to whole pixels of the pass, the pixels as read, in an
  /// uncompressed TIFF next to the pass. Returns each frame's file and where it lies.
  static func split(_ url: URL, footprint: NormalRect, frames: [FilmFrame], dpi: Int) throws -> [UUID: (path: String, rect: NormalRect)] {
    let pass = try ImagePipeline.shared.loadDecoded(url)
    let w = Double(pass.width), h = Double(pass.height)
    var result = [UUID: (path: String, rect: NormalRect)]()
    for frame in frames {
      let r = frame.rect
      let x0 = max(0, floor((r.x - footprint.x) / footprint.width * w)), x1 = min(w, ceil((r.x + r.width - footprint.x) / footprint.width * w))
      let y0 = max(0, floor((r.y - footprint.y) / footprint.height * h)), y1 = min(h, ceil((r.y + r.height - footprint.y) / footprint.height * h))
      guard x1 - x0 >= 2, y1 - y0 >= 2, let crop = pass.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else {
        throw DeskError.message("第 \(frame.name) 张不在这次扫描范围内")
      }
      let out = url.deletingLastPathComponent().appendingPathComponent("\(frame.name)_\(dpi)dpi_\(UUID().uuidString.prefix(6)).tiff")
      try ImagePipeline.shared.saveTIFF(crop, to: out, dpi: dpi)
      result[frame.id] = (out.path, NormalRect(
        x: footprint.x + x0 / w * footprint.width, y: footprint.y + y0 / h * footprint.height,
        width: (x1 - x0) / w * footprint.width, height: (y1 - y0) / h * footprint.height))
    }
    return result
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
      rollName = ""
      rollNotes = ""
      poolPictures = false
      rollSource = nil
      let root = try makeSession()
      let src = root.appendingPathComponent("Originals")
      try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
      clearEdits()
      frames = []
      thumbnails = [:]
      tablePrint = nil
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
      measureEdgeBases()
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
    let space = preferences.exportColorSpace, template = preferences.exportNameTemplate
    let roll = sessionURL?.lastPathComponent ?? "", overviewPath = overviewURL?.path ?? ""
    let previewDPI = Int(overviewDPI)
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    renderQueue.async {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Each frame's pictures let go before the next: a 60-megapixel frame holds half a gigabyte.
        for f in items { try autoreleasepool {
          let image = try self.source(for: f, full: true)
          let sharpener = Sharpening.sharpener(sharpening, frame: f, maxDimension: nil)
          let safeName = String(
            f.name.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" }.prefix(
              40))
          let source = f.hasFullResolution ? (f.scanPath ?? f.sourcePath ?? "") : overviewPath
          let scanned = (try? FileManager.default.attributesOfItem(atPath: source))?[.creationDate] as? Date
          let dpi = f.hasFullResolution ? (f.scanDPI ?? previewDPI) : previewDPI
          let stem = ExportNaming.name(template, film: p.id, name: p.name, frame: safeName, roll: roll, date: scanned)
          // Never over an earlier export: a second one gets a number.
          var url = directory.appendingPathComponent(stem).appendingPathExtension(format.fileExtension)
          var n = 1
          while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = directory.appendingPathComponent("\(stem)-\(n)").appendingPathExtension(format.fileExtension)
          }
          let metadata = ExportMetadata(
            title: "\(p.name) · \(f.name)",
            description: "\(p.name) · 第 \(f.name) 张 · \(dpi) dpi" + (f.hasFullResolution ? "" : " · 预览")
              + (f.sourcePath == nil ? " · EPSON Perfection V800/V850" : ""),
            keywords: [p.name, f.format, "胶片扫描"],
            scanner: f.sourcePath == nil ? ("EPSON", "Perfection V800/V850") : nil, scanned: scanned,
            software: "Epson Scan plus" + (version.map { " " + $0 } ?? ""))
          try ImagePipeline.shared.export(
            image, settings: f.adjustments, profile: p, url: url, format: format, dpi: dpi,
            quality: quality, sharpener: sharpener, colorSpace: space, metadata: metadata)
          let sidecar = ExportRecord(
            profile: p, frame: f, source: source, isPreview: !f.hasFullResolution, colorSpace: space.title)
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          try encoder.encode(sidecar).write(
            to: url.appendingPathExtension("json"), options: .atomic)
        } }
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
  /// The ticked frames a contact sheet would scan first: none from the preview, else those not
  /// yet scanned at 1200 dpi or more.
  func contactSheetScans(_ items: [FilmFrame]) -> [FilmFrame] {
    guard preferences.sheet.scansFirst else { return [] }
    return items.filter { $0.sourcePath == nil && !($0.hasFullResolution && ($0.scanDPI ?? 0) >= ContactSheet.scanDPI) }
  }
  func exportContactSheet() {
    guard !isWorking else { return }
    let items = frames.filter(\.enabled)
    guard !items.isEmpty else {
      errorText = "请先勾选要放进接触表的画面。"
      return
    }
    let needScan = contactSheetScans(items)
    var usePreviews = !preferences.sheet.scansFirst
    if !needScan.isEmpty {
      let ready = scanner.ready && !(scanner.backendID == "epson2-linear-v1" && overviewBackendID != scanner.backendID)
      let alert = NSAlert()
      if ready {
        let plan = scanPlan(needScan, dpi: ContactSheet.scanDPI, forSheet: true)
        alert.messageText = "先以 1200 dpi 扫描 \(needScan.count) 张，再生成接触表？"
        alert.informativeText = "接触表共 \(items.count) 张。尚未扫描或低于 1200 dpi 的画面会先扫描，结果保存为这些画面的原始文件；已有 1200 dpi 及以上扫描的画面直接使用。\n\n" + plan.summary
        if !plan.fits { alert.alertStyle = .critical }
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
    panel.message = usePreviews ? "按预览的分辨率（\(Int(overviewDPI)) dpi）直接导出，不扫描" : "1200 dpi 接触表"
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
      composeContactSheet(ids: items.map(\.id), to: url, format: chooser.format, fromPreview: usePreviews)
    } else {
      pendingSheet = (items.map(\.id), url, chooser.format)
      startScanBatch(needScan.map(\.id), dpi: ContactSheet.scanDPI)
      if !scanBatch.isActive { pendingSheet = nil }  // The batch refused to start.
    }
  }
  /// The sheet at 1200 dpi from the frames' own pixels, or `fromPreview` at the preview's
  /// resolution: scanned frames read at that size, the rest from the preview, nothing scanned.
  func composeContactSheet(
    ids: [UUID], to url: URL, format: ExportFormat, fromPreview: Bool = false, completion: ((Error?) -> Void)? = nil
  ) {
    let items = ids.compactMap { id in frames.first { $0.id == id } }
    let p = profile, layout = preferences.sheet, quality = preferences.jpegQuality
    let previewDPI = overviewDPI
    let title = "\(filmName) · \(Date().formatted(.iso8601.year().month().day())) · \(items.count) 张"
    let filmCode = filmName.uppercased()
    let sharpening = preferences.sharpening
    let tiles = items.map { f -> ContactSheet.Tile in
      if fromPreview, Self.readsScan(f), let path = f.scanPath, let scanned = f.scanDPI {
        // The whole scan file read at the preview's resolution, then cropped to the frame.
        let info = ImagePipeline.shared.info(URL(fileURLWithPath: path))
        let size = max(64, Int(Double(max(info.width, info.height)) * previewDPI / Double(scanned)))
        return ContactSheet.Tile(
          name: f.name, settings: f.adjustments, dpi: previewDPI, source: { try self.source(for: f, maxDimension: size) },
          sharpener: Sharpening.sharpener(sharpening, frame: f, maxDimension: size))
      }
      return ContactSheet.Tile(
        name: f.name, settings: f.adjustments,
        dpi: f.hasFullResolution ? Double(f.scanDPI ?? Int(previewDPI)) : previewDPI,
        source: { try self.source(for: f, full: true) },
        sharpener: Sharpening.sharpener(sharpening, frame: f, maxDimension: nil))
    }
    let sheetDPI = fromPreview ? Int(previewDPI) : ContactSheet.scanDPI
    beginExport()
    status = "正在生成接触表 · \(items.count) 张…"
    renderQueue.async {
      do {
        let size = try ContactSheet.export(
          tiles, profile: p, layout: layout, title: title, filmCode: filmCode, to: url,
          format: format, quality: quality, dpi: sheetDPI)
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
    var colorSpace: String? = nil
  }
  /// A project opened only to read from, as the command-line export does: estimates made on the
  /// way stay in memory, and the project file is left as it was.
  var readOnly = false
  func saveProject() {
    guard !readOnly, let root = sessionURL, let overviewURL else { return }
    var saved = frames
    for i in saved.indices {
      saved[i].scanFile = saved[i].scanPath.flatMap { ProjectFiles.relative($0, to: root) }
      saved[i].sourceFile = saved[i].sourcePath.flatMap { ProjectFiles.relative($0, to: root) }
    }
    var project = DeskProject(
      overviewPath: overviewURL.path, overviewDPI: overviewDPI, physicalWidthMM: physicalMM.width,
      physicalHeightMM: physicalMM.height, filmName: filmName, profile: profile, scanDPI: dpi,
      frames: saved, scanBackendID: overviewBackendID, overviewInputGamma: overviewInputGamma)
    project.overviewFile = ProjectFiles.relative(overviewURL.path, to: root)
    let name = rollName.trimmingCharacters(in: .whitespacesAndNewlines)
    project.rollName = name.isEmpty ? nil : name
    project.notes = rollNotes.isEmpty ? nil : rollNotes
    project.poolPictures = poolPictures ? true : nil
    project.source = rollSource?.rawValue
    do {
      let e = JSONEncoder()
      e.outputFormatting = [.prettyPrinted, .sortedKeys]
      try e.encode(project).write(
        to: root.appendingPathComponent(projectFileName), options: .atomic)
    } catch { status = "工程保存失败：\(error.localizedDescription)" }
  }
  func openProject() {
    guard !isWorking else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.data]
    // Until this library has a project, the older one is where they are.
    let fm = FileManager.default
    panel.directoryURL = !fm.fileExists(atPath: libraryURL.path) && libraryURL == Preferences.defaultLibraryURL
      && fm.fileExists(atPath: Preferences.legacyLibraryURL.path) ? Preferences.legacyLibraryURL : libraryURL
    guard panel.runModal() == .OK, let url = panel.url else { return }
    loadProject(url)
    if sessionURL == url.deletingLastPathComponent(), page == .capture { page = .convert }
  }
  /// The folders the library shows: the library, and while it is the default one, the folder
  /// versions before 0.4.9 kept their projects in.
  var libraryRoots: [(url: URL, legacy: Bool)] {
    var roots = [(url: libraryURL, legacy: false)]
    let legacy = Preferences.legacyLibraryURL
    if libraryURL.standardizedFileURL == Preferences.defaultLibraryURL.standardizedFileURL,
      FileManager.default.fileExists(atPath: legacy.path)
    {
      roots.append((legacy, true))
    }
    return roots
  }
  /// The open roll's project file.
  var projectURL: URL? { sessionURL?.appendingPathComponent(projectFileName) }
  /// Opens a roll from the library and goes on to take the mask off it; the open roll is saved
  /// first. The roll already open just goes on.
  func openRoll(_ entry: RollEntry) {
    guard !isWorking else { return }
    if projectURL?.standardizedFileURL != entry.project.standardizedFileURL {
      saveProject()
      loadProject(entry.project)
    }
    guard projectURL?.standardizedFileURL == entry.project.standardizedFileURL else { return }
    showLibrary = false
    if page != .convert { page = .convert }
  }
  func loadProject(_ url: URL) {
    do {
      let p = try JSONDecoder().decode(DeskProject.self, from: Data(contentsOf: url))
      guard p.version == 1 else { throw DeskError.message("不支持的工程版本。") }
      try p.profile.validate()
      // Files are found where the project folder is now, wherever it was saved.
      let folder = url.deletingLastPathComponent()
      let overviewPath = ProjectFiles.resolve(p.overviewPath, relative: p.overviewFile, in: folder)
      let cg = overviewWorkingCopy(
        try ImagePipeline.shared.load(URL(fileURLWithPath: overviewPath), maxDimension: 2200), backend: p.scanBackendID)
      sessionURL = folder
      projectFileName = url.lastPathComponent
      overviewURL = URL(fileURLWithPath: overviewPath)
      overview = cg
      frames = p.frames.map { saved in
        var f = saved
        f.scanPath = f.scanPath.map { ProjectFiles.resolve($0, relative: f.scanFile, in: folder) }
        f.sourcePath = f.sourcePath.map { ProjectFiles.resolve($0, relative: f.sourceFile, in: folder) }
        (f.scanFile, f.sourceFile) = (nil, nil)
        if f.sensorRead == nil, let path = f.sourcePath, f.adjustments.inputGamma == 1 { f.sensorRead = Self.readFromSensor(path) }
        // Copy shots read from the sensor have their colour noise smoothed, as new ones come in.
        if f.sensorRead == true && f.adjustments.colourNoise == nil { f.adjustments.colourNoise = 1 }
        return f
      }
      clearEdits()
      profile = p.profile
      filmName = p.filmName
      rollName = p.rollName ?? ""
      rollNotes = p.notes ?? ""
      poolPictures = p.poolPictures ?? false
      rollSource = p.source.flatMap(RollSource.init(rawValue:))
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
      status = overviewPath == p.overviewPath ? "已打开工程" : "已打开工程 · 工程文件夹已移动，按新位置读取文件"
      if !readOnly {
        registerMissingLevels()
        measureEdgeBases()
      }
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
