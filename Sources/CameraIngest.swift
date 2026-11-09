import AppKit
import CoreImage
import Foundation

/// The camera's pictures arriving in the library: each goes into the roll being shot (a new roll
/// when the open one is not the camera's), into its `Captures` folder, and a RAW is decoded into a
/// linear 16-bit TIFF in `Decoded`, which the conversion reads as it reads a linear scan.
extension AppModel {
  static let captureQueue = DispatchQueue(label: "epscan.capture", qos: .userInitiated)
  static let rawExtensions: Set<String> = ["arw", "arq", "dng", "srf", "sr2"]

  /// A picture the camera has just sent.
  func receiveCapture(_ url: URL) {
    do {
      if sessionURL == nil || rollSource != .camera { try startCameraRoll() }
      guard let root = sessionURL else { return }
      let files = FileManager.default
      var folder = root.appendingPathComponent("Captures")
      // The files of one pixel-shift shot go in a folder of their own.
      if pixelShiftCount > 1 {
        let groups = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("PixelShift-") }.count
        let index = pendingShift.isEmpty ? groups + 1 : groups
        folder.appendPathComponent(String(format: "PixelShift-%03d", max(1, index)))
      }
      try files.createDirectory(at: folder, withIntermediateDirectories: true)
      let dest = Self.unused(folder.appendingPathComponent(url.lastPathComponent))
      do { try files.moveItem(at: url, to: dest) } catch { try files.copyItem(at: url, to: dest) }
      lastCapture = dest
      if pixelShiftCount > 1 {
        pendingShift.append(dest)
        guard pendingShift.count >= pixelShiftCount else {
          status = "像素位移：已收到 \(pendingShift.count) / \(pixelShiftCount) 张"
          toast("像素位移 \(pendingShift.count) / \(pixelShiftCount)")
          return
        }
        // In the order they came, which is the order the camera took them.
        let group = pendingShift
        pendingShift = []
        decodeShift(group, root: root)
      } else {
        decodeCapture(dest, root: root)
      }
    } catch { errorText = "收不下相机拍的照片：\(error.localizedDescription)" }
  }
  /// A pixel-shift group that will not be completed (the press brought fewer pictures), so the next
  /// press starts a group of its own. Four or more of 16 are the camera set to 4 (the app cannot set
  /// it: the camera's SDK has no such setting), or the rest lost: the first four, one square, are
  /// composed as a 4-shot group. Fewer: the first picture as one shot.
  func releaseShift() {
    guard let first = pendingShift.first, let root = sessionURL else { return }
    let group = pendingShift, square = SensorRaw.shiftOrder.count
    pendingShift = []
    if group.count >= square {
      let said = group.count == square
        ? "相机这一下只拍了 4 张：相机里像素位移的张数是 4。已按 4 张合成；要 16 张，在取景区重新选一次 16，或在相机菜单的像素位移多重拍摄里把张数改成 16"
        : "这一下只收到 \(group.count) / \(pixelShiftCount) 张，后面的没有来。已用前 4 张按 4 张合成"
      camera.explain(said)
      decodeShift(Array(group.prefix(square)), root: root, note: group.count == square ? "相机设的是 4 张，按 4 张合成" : "只收到 \(group.count) / \(pixelShiftCount) 张，用前 4 张按 4 张合成")
    } else {
      decodeCapture(first, root: root)
    }
  }
  /// A new roll for the camera, measured as one roll and sharing a picked base.
  func startCameraRoll() throws {
    saveProject()
    sessionURL = nil
    rollName = ""
    rollNotes = ""
    frames = []
    thumbnails = [:]
    tablePrint = nil
    selectedID = nil
    clearEdits()
    overview = nil
    overviewURL = nil
    overviewBackendID = nil
    overviewInputGamma = 1
    pendingShift = []
    _ = try makeSession()
    rollSource = .camera
    poolPictures = true
    useCalibration = true
    rollFlats = []
  }
  func decodeCapture(_ file: URL, root: URL) {
    let raw = Self.rawExtensions.contains(file.pathExtension.lowercased())
    status = raw ? "正在解码 \(file.lastPathComponent)…" : "已收到 \(file.lastPathComponent)"
    Self.captureQueue.async {
      var result: Result<URL, Error>
      var sensor = false
      if raw {
        let decoded = root.appendingPathComponent("Decoded", isDirectory: true)
        let out = Self.unused(decoded.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".tif"))
        result = Result {
          try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
          sensor = try Self.linearTIFF(fromRAW: file, to: out)
          return out
        }
      } else {
        result = .success(file)
      }
      DispatchQueue.main.async {
        switch result {
        case .success(let picture): self.addCapturedFrame(picture, original: file, linear: raw, sensor: sensor)
        case .failure(let error): self.errorText = "解码 \(file.lastPathComponent) 失败：\(error.localizedDescription)"
        }
      }
    }
  }
  /// How far the two greens of a pixel-shift composite may differ, against their level, before the
  /// group is taken to have moved: about 1.4 % when the four lie as they should (Vlad's test target
  /// on the copy stand), 7.9 % with two of them swapped, a photosite out.
  static let shiftGreensLimit = 0.04
  /// How far, in photosites, a 16-shot group's squares may lie from the half photosite the camera
  /// means before the group is taken to have moved: 0.14 and 0.21 on the two sets of Vlad's test
  /// target; a third of a half step is where the doubled grid stops gaining much.
  static let shiftSquaresLimit = 0.25
  /// What a pixel-shift group composed into, for the status: the picture written, the two greens'
  /// disagreement, and for 16 shots the squares as found.
  private struct Composed {
    var greens: Double
    var shift16: SensorRaw.Shift16?
    /// 16 shots composed as their first four, for want of room.
    var squareOnly = false
  }
  /// A whole pixel-shift group composed into one frame, each point's red, green and blue as
  /// measured, instead of one shot's colours filled in from its neighbours: 4 shots at the sensor's
  /// resolution, 16 at twice it each way. When they are not uncompressed ARWs of one kind (JPEGs, a
  /// compressed RAW), the first is used as one shot.
  private func decodeShift(_ group: [URL], root: URL, note: String? = nil) {
    let square = SensorRaw.shiftOrder.count, all = square * SensorRaw.shiftGroups.count
    guard group.count == square || group.count == all, let first = group.first else {
      status = "像素位移 \(group.count) 张已收齐；只有 4 张或 16 张一组能合成，先用这组的第一张"
      if let first = group.first { decodeCapture(first, root: root) }
      return
    }
    let name = first.deletingLastPathComponent().lastPathComponent
    let supersample = shiftSupersample
    status = "正在合成像素位移 \(name)（\(group.count) 张）…"
    Self.captureQueue.async {
      let decoded = root.appendingPathComponent("Decoded", isDirectory: true)
      let out = Self.unused(decoded.appendingPathComponent(name + ".tif"))
      let result = Result { () -> Composed? in
        try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
        if group.count == all {
          // Twice the sensor each way, 16-bit RGB: about 1.5 GB for the A7R IV, written beside the
          // 2 GB of shots (supersampled, a quarter of it). Without room for it twice over, the first
          // square alone.
          let raw = (try? NSData(contentsOf: first, options: .alwaysMapped)).flatMap { SensorRaw($0 as Data) }
          let needed = Int64((raw?.width ?? 0) * (raw?.height ?? 0) * (supersample ? 6 : 24) * 2)
          let free = (try? decoded.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
          if free >= needed, let composed = try SensorRaw.pixelShift16(group, supersample: supersample) {
            try ImagePipeline.shared.saveTIFF(composed.image, to: out, dpi: 300)
            return Composed(greens: composed.greens, shift16: composed)
          }
          guard free < needed, let composed = try SensorRaw.pixelShiftRGB(Array(group.prefix(square))) else { return nil }
          try ImagePipeline.shared.saveTIFF(composed.image, to: out, dpi: 300)
          return Composed(greens: composed.greens, squareOnly: true)
        }
        guard let composed = try SensorRaw.pixelShiftRGB(group) else { return nil }
        try ImagePipeline.shared.saveTIFF(composed.image, to: out, dpi: 300)
        return Composed(greens: composed.greens)
      }
      DispatchQueue.main.async {
        switch result {
        case .success(nil):
          self.status = "像素位移 \(group.count) 张不是同一种无压缩 ARW，合成不了，先用这组的第一张"
          self.decodeCapture(first, root: root)
        case .success(let composed?):
          self.addCapturedFrame(out, original: first, linear: true, sensor: true)
          let said = String(format: "%.1f%%", composed.greens * 100)
          // What went wrong, which asks for the group again, and what is only so.
          var problems = [String](), facts = [String]()
          if let note { facts.append(note) }
          if composed.greens > Self.shiftGreensLimit {
            problems.append("两次绿色相差 \(said)（正常约 1.5%）：4 张之间有东西动了（胶片、相机或灯），细节会有重影")
          }
          var head = "像素位移 \(name) 已合成"
          if let s = composed.shift16 {
            head = "像素位移 \(name)（16 张，\(s.supersampled ? "超采样到 " : "")\(s.image.width)×\(s.image.height)）已合成"
            if !s.measured {
              facts.append("画面细节太少，量不出 4 组之间的位移，按相机标称的半像素合成")
            } else if s.astray > Self.shiftSquaresLimit {
              problems.append(String(format: "4 组之间的半像素位移偏了 %.2f 像素（应为 0.5）：比 4 张合成多不出多少细节", s.astray))
            } else {
              facts.append(String(format: "4 组对齐，半像素位移最多偏 %.2f 像素", s.astray))
            }
          }
          if composed.squareOnly { facts.append("磁盘空间不够放 16 张的合成图（\(supersample ? "约 0.4 GB" : "约 1.5 GB")），先用第一组 4 张合成") }
          if problems.isEmpty {
            self.status = head + "：" + (facts + [(composed.shift16 == nil ? "4 张对齐，" : "") + "两次绿色相差 \(said)"]).joined(separator: "；")
          } else {
            self.status = head + "，但" + (problems + facts).joined(separator: "；") + "。这一组最好重拍"
            self.toast("没对齐：重拍这一组")
          }
        case .failure(let error):
          self.errorText = "合成像素位移 \(name) 失败：\(error.localizedDescription)"
        }
      }
    }
  }
  /// `picture` as the roll's next frame; a RAW's is linear (input gamma 1), a JPEG's is not. Read
  /// from the `sensor`, it has the copy light's crosstalk taken out, or not, as the roll's other
  /// such frames have, or as last chosen for a roll's first.
  func addCapturedFrame(_ picture: URL, original: URL, linear: Bool, sensor: Bool = false) {
    let info = ImagePipeline.shared.info(picture)
    // The long side taken as the 36 mm of a 135 frame filling it; only the export's dpi follows it.
    let dpi = info.width > 0 ? Double(max(info.width, info.height)) / 36 * 25.4 : 300
    var f = FilmFrame(name: nextFrameName, rect: .full, format: "翻拍")
    f.sourcePath = picture.path
    f.sourceBits = info.bits
    f.scanDPI = Int(dpi.rounded())
    f.adjustments.inputGamma = linear ? 1 : 2.2
    // It joins the roll's film: a copy of a slide in a roll of slides is a slide.
    if frames.contains(where: { $0.adjustments.isSlide }) { f.adjustments.setReversal(true) }
    f.sensorRead = sensor
    if sensor {
      f.adjustments.colourNoise = 1
      // As the roll's other pictures from the sensor are read, or, the roll's first, as the light
      // was last calibrated.
      let light = preferences.lightCalibration
      if let other = frames.first(where: { $0.sensorRead == true }) {
        f.crosstalk = other.crosstalk
      } else if preferences.removeCrosstalk {
        f.crosstalk = light?.crosstalk ?? .measured
      }
    }
    // The flat field of the roll's last picture of this size (after a new blank frame, that
    // blank's); else the copy light's with the crosstalk out, or none.
    if linear, let flat = flatForNext(width: info.width, height: info.height) { f.flatID = flat.id }
    f.flatField = resolvedFlat(f.flatID, crosstalk: f.crosstalk)
    if overview == nil || overviewURL == nil {
      overviewURL = picture
      overview = try? ImagePipeline.shared.load(picture, maxDimension: 2200)
      overviewDPI = dpi
      if info.width > 0 {
        physicalMM = CGSize(width: Double(info.width) / dpi * 25.4, height: Double(info.height) / dpi * 25.4)
      }
    }
    frames.append(f)
    selectedID = f.id
    let flatNote = flatProfile(of: f).map { " · 平场「\($0.name)」" } ?? ""
    status = "第 \(f.name) 张已入库：\(original.lastPathComponent)" + flatNote
    toast("第 \(f.name) 张已入库" + flatNote)
    updateRollBase()
    refresh()
    updateThumbnails()
    updateRollSlopes()
    saveProject()
    measureEdgeBases()
    // The base's balance for the camera page, while the light is set.
    if linear { updateLastShotBalance(f.id) }
  }
  /// Shows `text` over the live view for three seconds, unless another note takes its place.
  func toast(_ text: String) {
    captureToast = text
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      if self?.captureToast == text { self?.captureToast = nil }
    }
  }
  /// `url`, or the same name with a number added where a file already has it.
  static func unused(_ url: URL) -> URL {
    let files = FileManager.default
    guard files.fileExists(atPath: url.path) else { return url }
    let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
    for n in 2... {
      let next = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(n)" + (ext.isEmpty ? "" : "." + ext))
      if !files.fileExists(atPath: next.path) { return next }
    }
    return url
  }
  /// A camera RAW as a linear 16-bit TIFF, as this app's scans are. An uncompressed ARW is read
  /// straight from the sensor, each channel what its colour of light made, with no colour matrix
  /// to mix them (what a negative lit by red, green and blue lights needs). Any other RAW goes
  /// through the system's RAW engine with nothing of its own added: no tone curve or boost, no
  /// baseline exposure, no lens correction, sharpening or noise reduction, and the same fixed
  /// white balance for every frame, so the channels keep one scale across the roll; it still
  /// applies the camera's colour matrix. True when it was read from the sensor.
  @discardableResult static func linearTIFF(fromRAW url: URL, to out: URL) throws -> Bool {
    if let native = try SensorRaw.nativeRGB(url) {
      try ImagePipeline.shared.saveTIFF(native, to: out, dpi: 300)
      return true
    }
    guard let raw = CIRAWFilter(imageURL: url) else { throw DeskError.message("系统无法读取这个 RAW：\(url.lastPathComponent)") }
    raw.boostAmount = 0
    raw.baselineExposure = 0
    raw.exposure = 0
    raw.isGamutMappingEnabled = false
    raw.neutralTemperature = 5500
    raw.neutralTint = 0
    if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = false }
    raw.extendedDynamicRangeAmount = 0
    if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
    if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
    if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
    if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
    if raw.isContrastSupported { raw.contrastAmount = 0 }
    if raw.isDetailSupported { raw.detailAmount = 0 }
    if raw.isMoireReductionSupported { raw.moireReductionAmount = 0 }
    guard let image = raw.outputImage else { throw DeskError.message("RAW 解码没有输出：\(url.lastPathComponent)") }
    let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
    let context = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: linear])
    guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA16, colorSpace: linear) else {
      throw DeskError.message("RAW 解码失败：\(url.lastPathComponent)")
    }
    try ImagePipeline.shared.saveTIFF(cg, to: out, dpi: 300)
    return false
  }
  /// Whether the TIFF at `path` is one `linearTIFF` read from a camera's sensor: decoded into a
  /// roll's Decoded folder, red, green and blue with no alpha, which the system's RAW engine adds.
  /// For projects from before frames recorded it.
  static func readFromSensor(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard url.deletingLastPathComponent().lastPathComponent == "Decoded",
      let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    else { return false }
    return !(p[kCGImagePropertyHasAlpha] as? Bool ?? false) && p[kCGImagePropertyDepth] as? Int == 16
  }
  /// A piece of `url` (the camera's own file) about `point`, normalised, `side` pixels across at
  /// full resolution, as the camera renders it: for checking focus pixel by pixel.
  static func focusCrop(_ url: URL, at point: CGPoint, side: Int = 256) -> CGImage? {
    let image: CIImage?
    if rawExtensions.contains(url.pathExtension.lowercased()) {
      image = CIRAWFilter(imageURL: url)?.outputImage
    } else {
      image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }
    guard let image else { return nil }
    let e = image.extent
    // Core Image counts up from the bottom.
    let cx = e.minX + point.x * e.width, cy = e.maxY - point.y * e.height, half = CGFloat(side) / 2
    let r = CGRect(x: cx - half, y: cy - half, width: CGFloat(side), height: CGFloat(side)).integral.intersection(e)
    guard !r.isNull, r.width > 1, r.height > 1 else { return nil }
    let space = ImagePipeline.shared.outputSpace
    return CIContext(options: [.outputColorSpace: space]).createCGImage(image, from: r, format: .RGBA8, colorSpace: space)
  }
}
