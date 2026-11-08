import AppKit
import ImageIO
import SwiftUI

/// What a frame's own file says of how it was taken (its EXIF): camera, lens, exposure, when, and
/// for a scan the scanner and its resolution. Read from the camera's file, not the TIFF the app
/// decoded it to, which carries none of it.
enum PhotoInfo {
  struct Row: Identifiable, Equatable {
    var label: String
    var value: String
    var id: String { label }
  }
  /// The file that holds the frame's EXIF: for a camera RAW decoded into the roll's Decoded folder,
  /// the RAW of the same name beside it in Captures; otherwise the picture's own file or its scan.
  static func file(for frame: FilmFrame) -> URL? {
    if let path = frame.sourcePath {
      let url = URL(fileURLWithPath: path)
      let folder = url.deletingLastPathComponent()
      if folder.lastPathComponent == "Decoded" {
        let captures = folder.deletingLastPathComponent().appendingPathComponent("Captures", isDirectory: true)
        let name = url.deletingPathExtension().lastPathComponent
        let raw = (try? FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil))?
          .filter { $0.deletingPathExtension().lastPathComponent == name && AppModel.rawExtensions.contains($0.pathExtension.lowercased()) }
          .sorted { $0.lastPathComponent < $1.lastPathComponent }.first
        if let raw { return raw }
      }
      return url
    }
    return frame.scanPath.map { URL(fileURLWithPath: $0) }
  }
  /// The rows to show for `url`, in the order a photographer reads them; only what the file has.
  static func rows(_ url: URL) -> [Row] {
    var rows = [Row]()
    func add(_ label: String, _ value: String?) {
      if let value, !value.isEmpty { rows.append(Row(label: label, value: value)) }
    }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    add("文件", url.lastPathComponent + (size.map { String(format: " · %.1f MB", Double($0) / 1_000_000) } ?? ""))
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return rows }
    let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let aux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
    func number(_ d: [CFString: Any], _ key: CFString) -> Double? {
      (d[key] as? NSNumber)?.doubleValue ?? (d[key] as? [NSNumber])?.first?.doubleValue
    }
    let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    add("相机", model.localizedCaseInsensitiveContains(make) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " "))
    add("镜头", (exif[kCGImagePropertyExifLensModel] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel] as? String))
    if let f = number(exif, kCGImagePropertyExifFocalLength) {
      let equivalent = number(exif, kCGImagePropertyExifFocalLenIn35mmFilm)
      add("焦距", String(format: "%g mm", f) + (equivalent.map { abs($0 - f) > 0.5 ? String(format: "（等效 %g mm）", $0) : "" } ?? ""))
    }
    add("光圈", number(exif, kCGImagePropertyExifFNumber).map { String(format: "f/%g", $0) })
    add("快门", number(exif, kCGImagePropertyExifExposureTime).map(shutter))
    add("ISO", number(exif, kCGImagePropertyExifISOSpeedRatings).map { String(format: "%g", $0) })
    if let bias = number(exif, kCGImagePropertyExifExposureBiasValue), abs(bias) > 0.01 {
      add("曝光补偿", String(format: "%+.1f EV", bias))
    }
    add("拍摄时间", ((exif[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)).map(date))
    if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
      add("尺寸", "\(w) × \(h)" + ((p[kCGImagePropertyDepth] as? Int).map { " · \($0) 位" } ?? ""))
    }
    // A scan's: the scanner's resolution and what wrote the file.
    if model.isEmpty, let dpi = p[kCGImagePropertyDPIWidth] as? Double, dpi > 72 { add("分辨率", String(format: "%g dpi", dpi)) }
    add("软件", tiff[kCGImagePropertyTIFFSoftware] as? String)
    return rows
  }
  /// 1/320 s, 0.5 s, 2 s.
  static func shutter(_ t: Double) -> String {
    guard t > 0 else { return "" }
    if t >= 0.3 { return String(format: "%g s", (t * 10).rounded() / 10) }
    return "1/\(Int((1 / t).rounded())) s"
  }
  /// EXIF's 2026:11:07 13:21:52 as 2026-11-07 13:21:52.
  static func date(_ exif: String) -> String {
    let parts = exif.split(separator: " ", maxSplits: 1)
    guard let day = parts.first else { return exif }
    return ([day.replacingOccurrences(of: ":", with: "-")] + parts.dropFirst().map(String.init)).joined(separator: " ")
  }
}

/// The key beside the frame's name under the single view: the frame's EXIF in a popover.
struct PhotoInfoButton: View {
  let frame: FilmFrame
  @State private var shown = false
  var body: some View {
    Button {
      shown.toggle()
    } label: {
      Image(systemName: "info.circle")
    }.buttonStyle(.borderless).keyboardShortcut("i").help("照片信息：相机、镜头、曝光和拍摄时间 · ⌘I")
      .accessibilityLabel("照片信息")
      .popover(isPresented: $shown, arrowEdge: .top) { PhotoInfoView(file: PhotoInfo.file(for: frame)) }
  }
}

struct PhotoInfoView: View {
  let file: URL?
  var body: some View {
    let rows = file.map(PhotoInfo.rows) ?? []
    VStack(alignment: .leading, spacing: 10) {
      Text("照片信息").font(.system(size: 13, weight: .semibold))
      if rows.count <= 1 {
        Text(file == nil ? "这一张没有自己的文件" : "这个文件里没有拍摄信息").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
        ForEach(rows) { row in
          GridRow {
            Text(row.label).foregroundStyle(.secondary)
            Text(row.value).textSelection(.enabled)
          }
        }
      }.font(.system(size: 12))
      if let file {
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file]) }.font(.system(size: 12))
      }
    }.padding(14).frame(minWidth: 260, alignment: .leading)
  }
}
