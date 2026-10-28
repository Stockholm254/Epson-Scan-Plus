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
        let first = pendingShift.sorted { $0.lastPathComponent < $1.lastPathComponent }[0]
        pendingShift = []
        status = "像素位移 \(pixelShiftCount) 张已收齐；合成还没做，先用这组的第一张"
        decodeCapture(first, root: root)
      } else {
        decodeCapture(dest, root: root)
      }
    } catch { errorText = "收不下相机拍的照片：\(error.localizedDescription)" }
  }
  /// A new roll for the camera, measured as one roll and sharing a picked base.
  func startCameraRoll() throws {
    saveProject()
    sessionURL = nil
    rollName = ""
    rollNotes = ""
    frames = []
    thumbnails = [:]
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
  }
  private func decodeCapture(_ file: URL, root: URL) {
    let raw = Self.rawExtensions.contains(file.pathExtension.lowercased())
    status = raw ? "正在解码 \(file.lastPathComponent)…" : "已收到 \(file.lastPathComponent)"
    Self.captureQueue.async {
      var result: Result<URL, Error>
      if raw {
        let decoded = root.appendingPathComponent("Decoded", isDirectory: true)
        let out = Self.unused(decoded.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".tif"))
        result = Result {
          try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
          try Self.linearTIFF(fromRAW: file, to: out)
          return out
        }
      } else {
        result = .success(file)
      }
      DispatchQueue.main.async {
        switch result {
        case .success(let picture): self.addCapturedFrame(picture, original: file, linear: raw)
        case .failure(let error): self.errorText = "解码 \(file.lastPathComponent) 失败：\(error.localizedDescription)"
        }
      }
    }
  }
  /// `picture` as the roll's next frame; a RAW's is linear (input gamma 1), a JPEG's is not.
  func addCapturedFrame(_ picture: URL, original: URL, linear: Bool) {
    let info = ImagePipeline.shared.info(picture)
    // The long side taken as the 36 mm of a 135 frame filling it; only the export's dpi follows it.
    let dpi = info.width > 0 ? Double(max(info.width, info.height)) / 36 * 25.4 : 300
    var f = FilmFrame(name: String(format: "%02d", frames.count + 1), rect: .full, format: "翻拍")
    f.sourcePath = picture.path
    f.sourceBits = info.bits
    f.scanDPI = Int(dpi.rounded())
    f.adjustments.inputGamma = linear ? 1 : 2.2
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
    status = "第 \(f.name) 张已入库：\(original.lastPathComponent)"
    toast("第 \(f.name) 张已入库")
    updateRollBase()
    refresh()
    updateThumbnails()
    updateRollSlopes()
    saveProject()
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
  /// A camera RAW decoded by the system's RAW engine with nothing of its own added: no tone curve
  /// or boost, no baseline exposure, no lens correction, sharpening or noise reduction, and the
  /// same fixed white balance for every frame, so the channels keep one scale across the roll.
  /// Written linear, 16 bits a channel, as this app's scans are. (The system still applies the
  /// camera's colour matrix; reading the sensor's own channels is left for later.)
  static func linearTIFF(fromRAW url: URL, to out: URL) throws {
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
