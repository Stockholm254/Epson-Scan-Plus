import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Export file types. Raw values are stable: they are stored in settings and taken by `--format`.
enum ExportFormat: String, CaseIterable, Identifiable {
  case tiff, tiff8, jpeg, png
  var id: String { rawValue }
  var title: String {
    switch self {
    case .tiff: return "TIFF · 16-bit"
    case .tiff8: return "TIFF · 8-bit"
    case .jpeg: return "JPEG · sRGB"
    case .png: return "PNG · 16-bit"
    }
  }
  var fileExtension: String {
    switch self {
    case .tiff, .tiff8: return "tif"
    case .jpeg: return "jpg"
    case .png: return "png"
    }
  }
  var type: UTType {
    switch self {
    case .tiff, .tiff8: return .tiff
    case .jpeg: return .jpeg
    case .png: return .png
    }
  }
  var sixteenBit: Bool { self == .tiff || self == .png }
}

/// App-wide settings. The app keeps them in UserDefaults; without `defaults` (tests, the
/// command-line exporter) they live only in memory and never touch the user's settings.
final class Preferences: ObservableObject {
  static let defaultLibraryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Film Desk")
  private let defaults: UserDefaults?
  /// Where new previews and imports create their project folders; nil is the default library.
  @Published var libraryPath: String? { didSet { defaults?.set(libraryPath, forKey: "libraryPath") } }
  @Published var exportFormat: ExportFormat { didSet { defaults?.set(exportFormat.rawValue, forKey: "exportFormat") } }
  @Published var jpegQuality: Double { didSet { defaults?.set(jpegQuality, forKey: "jpegQuality") } }
  @Published var sheet: ContactSheet.Layout {
    didSet { defaults?.set(try? JSONEncoder().encode(sheet), forKey: "contactSheet") }
  }
  /// Also export finished scans as positives into the project's Exports folder. On unless turned
  /// off; an in-memory set (tests, the command-line exporter) never exports on its own.
  @Published var autoExport: Bool { didSet { defaults?.set(autoExport, forKey: "autoExport") } }
  /// The whole-holder preview. 600 dpi takes about 80 s on the V850, 150 dpi about 50 s;
  /// 300 dpi is barely quicker than 600, so it is not offered.
  @Published var previewDPI: Int { didSet { defaults?.set(previewDPI, forKey: "previewDPI") } }
  static let previewResolutions = [600, 150]
  /// The loupe lying on the light table, and which one.
  @Published var showLoupe: Bool { didSet { defaults?.set(showLoupe, forKey: "showLoupe") } }
  @Published var loupeStyle: LoupeStyle { didSet { defaults?.set(loupeStyle.rawValue, forKey: "loupeStyle") } }
  /// Side panel widths, as the user dragged them.
  @Published var leftWidth: Double { didSet { defaults?.set(leftWidth, forKey: "leftWidth") } }
  @Published var rightWidth: Double { didSet { defaults?.set(rightWidth, forKey: "rightWidth") } }
  static let leftWidths = 210.0...380.0, rightWidths = 240.0...420.0
  /// Imported and calibrated film presets, offered next to the built-in ones.
  @Published var customProfiles: [FilmProfile] {
    didSet { defaults?.set(try? JSONEncoder().encode(customProfiles), forKey: "customProfiles") }
  }
  /// The scanner's measured MTF; sharpening stays off until a target has been measured.
  @Published var sharpening: SharpeningProfile? {
    didSet { defaults?.set(sharpening.flatMap { try? JSONEncoder().encode($0) }, forKey: "sharpening") }
  }
  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults
    libraryPath = defaults?.string(forKey: "libraryPath")
    exportFormat = defaults?.string(forKey: "exportFormat").flatMap(ExportFormat.init(rawValue:)) ?? .tiff
    let quality = defaults?.double(forKey: "jpegQuality") ?? 0
    jpegQuality = quality > 0 ? min(1, max(0.5, quality)) : 0.97
    sheet = defaults?.data(forKey: "contactSheet").flatMap { try? JSONDecoder().decode(ContactSheet.Layout.self, from: $0) }
      ?? ContactSheet.Layout()
    sharpening = defaults?.data(forKey: "sharpening").flatMap { try? JSONDecoder().decode(SharpeningProfile.self, from: $0) }
    customProfiles = defaults?.data(forKey: "customProfiles").flatMap { try? JSONDecoder().decode([FilmProfile].self, from: $0) } ?? []
    autoExport = defaults.map { $0.object(forKey: "autoExport") as? Bool ?? true } ?? false
    let dpi = defaults?.integer(forKey: "previewDPI") ?? 0
    previewDPI = Self.previewResolutions.contains(dpi) ? dpi : 600
    showLoupe = defaults?.object(forKey: "showLoupe") as? Bool ?? true
    loupeStyle = defaults?.string(forKey: "loupeStyle").flatMap(LoupeStyle.init(rawValue:)) ?? .pentax
    let left = defaults?.double(forKey: "leftWidth") ?? 0, right = defaults?.double(forKey: "rightWidth") ?? 0
    leftWidth = left > 0 ? min(Self.leftWidths.upperBound, max(Self.leftWidths.lowerBound, left)) : 230
    rightWidth = right > 0 ? min(Self.rightWidths.upperBound, max(Self.rightWidths.lowerBound, right)) : 258
  }
  var libraryURL: URL { libraryPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultLibraryURL }
}

/// A format popup for export panels. In a save panel it also keeps the file extension in step.
final class FormatChooser: NSObject {
  let popup = NSPopUpButton(frame: .zero, pullsDown: false)
  private weak var savePanel: NSSavePanel?
  init(selected: ExportFormat) {
    super.init()
    popup.addItems(withTitles: ExportFormat.allCases.map(\.title))
    popup.selectItem(at: ExportFormat.allCases.firstIndex(of: selected) ?? 0)
    popup.target = self
    popup.action = #selector(changed)
  }
  var format: ExportFormat { ExportFormat.allCases[max(0, popup.indexOfSelectedItem)] }
  func attach(to panel: NSSavePanel) {
    let accessory = NSStackView(views: [NSTextField(labelWithString: "导出格式："), popup])
    accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    accessory.setFrameSize(accessory.fittingSize)
    panel.accessoryView = accessory
    if let open = panel as? NSOpenPanel {
      open.isAccessoryViewDisclosed = true
    } else {
      savePanel = panel
      changed()
    }
  }
  @objc private func changed() {
    guard let panel = savePanel else { return }
    panel.allowedContentTypes = [format.type]
    let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
    panel.nameFieldStringValue = name + "." + format.fileExtension
  }
}
