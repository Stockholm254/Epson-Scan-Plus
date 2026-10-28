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
    case .jpeg: return "JPEG"
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

/// Colour spaces for exports. Raw values are stored in settings and taken by `--color-space`.
enum ExportColorSpace: String, CaseIterable, Identifiable {
  case sRGB = "srgb", displayP3 = "p3", adobeRGB = "adobe", proPhoto = "prophoto"
  var id: String { rawValue }
  var title: String {
    switch self {
    case .sRGB: return "sRGB"
    case .displayP3: return "Display P3"
    case .adobeRGB: return "Adobe RGB (1998)"
    case .proPhoto: return "ProPhoto RGB"
    }
  }
  var space: CGColorSpace {
    switch self {
    case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
    case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
    case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
    case .proPhoto: return CGColorSpace(name: CGColorSpace.rommrgb)!
    }
  }
}

/// Export file names from a template: {film} the preset's short name, {name} the film's name,
/// {frame} the frame number, {roll} the project folder, {date} the scan date (yyyyMMdd).
enum ExportNaming {
  static let standard = "{film}_{frame}"
  static func name(_ template: String, film: String, name: String, frame: String, roll: String, date: Date?) -> String {
    let day = date.map {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyyMMdd"
      return f.string(from: $0)
    } ?? ""
    var result = template.trimmingCharacters(in: .whitespaces).isEmpty ? standard : template
    for (token, value) in [("{film}", film), ("{name}", name), ("{frame}", frame), ("{roll}", roll), ("{date}", day)] {
      result = result.replacingOccurrences(of: token, with: value)
    }
    // No folders, hidden files or characters Finder shows as a slash.
    let safe = result.map { "/:\\".contains($0) || $0.isNewline ? "_" : $0 }
    let trimmed = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    return trimmed.isEmpty ? "frame" : String(trimmed.prefix(120))
  }
}

/// App-wide settings. The app keeps them in UserDefaults; without `defaults` (tests, the
/// command-line exporter) they live only in memory and never touch the user's settings.
final class Preferences: ObservableObject {
  static let defaultLibraryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("epscan")
  /// Where versions before 0.4.9 kept their projects; left as it is, and still opened from.
  static let legacyLibraryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Film Desk")
  /// The settings of versions before 0.4.9, kept under their old identifier.
  static let legacyDomain = "local.filmdesk.mac"
  /// Brings settings over from `legacy` once: presets, calibrations, the chosen library and the
  /// rest. Anything already set here wins; window and panel state is left behind.
  static func migrate(from legacy: String = legacyDomain, into defaults: UserDefaults) {
    let done = "migratedFrom." + legacy
    guard !defaults.bool(forKey: done) else { return }
    for (key, value) in UserDefaults.standard.persistentDomain(forName: legacy) ?? [:]
    where !key.hasPrefix("NS") && defaults.object(forKey: key) == nil {
      defaults.set(value, forKey: key)
    }
    defaults.set(true, forKey: done)
  }
  private let defaults: UserDefaults?
  /// Where new previews and imports create their project folders; nil is the default library.
  @Published var libraryPath: String? { didSet { defaults?.set(libraryPath, forKey: "libraryPath") } }
  @Published var exportFormat: ExportFormat { didSet { defaults?.set(exportFormat.rawValue, forKey: "exportFormat") } }
  @Published var jpegQuality: Double { didSet { defaults?.set(jpegQuality, forKey: "jpegQuality") } }
  @Published var exportColorSpace: ExportColorSpace {
    didSet { defaults?.set(exportColorSpace.rawValue, forKey: "exportColorSpace") }
  }
  @Published var exportNameTemplate: String { didSet { defaults?.set(exportNameTemplate, forKey: "exportNameTemplate") } }
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
  /// The light table turns an upright holder a quarter turn, so the strips run across a wide window.
  @Published var contactLandscape: Bool { didSet { defaults?.set(contactLandscape, forKey: "contactLandscape") } }
  /// Side panel widths, as the user dragged them.
  @Published var leftWidth: Double { didSet { defaults?.set(leftWidth, forKey: "leftWidth") } }
  @Published var rightWidth: Double { didSet { defaults?.set(rightWidth, forKey: "rightWidth") } }
  static let leftWidths = 210.0...380.0, rightWidths = 240.0...420.0
  /// Imported and calibrated film presets, offered next to the built-in ones.
  @Published var customProfiles: [FilmProfile] {
    didSet { defaults?.set(try? JSONEncoder().encode(customProfiles), forKey: "customProfiles") }
  }
  /// The scanner measured on an IT8 target, and whether conversion takes its stray light out.
  @Published var scannerCalibration: ScannerCalibration? {
    didSet { defaults?.set(scannerCalibration.flatMap { try? JSONEncoder().encode($0) }, forKey: "scannerCalibration") }
  }
  @Published var removeFlare: Bool { didSet { defaults?.set(removeFlare, forKey: "removeFlare") } }
  /// The scanner's measured MTF; sharpening stays off until a target has been measured.
  @Published var sharpening: SharpeningProfile? {
    didSet { defaults?.set(sharpening.flatMap { try? JSONEncoder().encode($0) }, forKey: "sharpening") }
  }
  /// How this computer's scanner keeps time against `ScanTiming`, by backend and resolution
  /// (`ScanPlan.speedKey`): actual over predicted, for the time a batch will take. A new key, so
  /// the seconds per megapixel 0.4.8 kept are not read as one.
  @Published var scanSpeed: [String: Double] { didSet { defaults?.set(scanSpeed, forKey: "scanSpeed") } }
  /// Takes in one finished pass; the latest counts as much as all before it.
  func recordScan(backend: String, dpi: Int, seconds: Double, predicted: Double) {
    guard let speed = ScanPlan.speed(seconds: seconds, predicted: predicted) else { return }
    let key = ScanPlan.speedKey(backend: backend, dpi: dpi)
    scanSpeed[key] = scanSpeed[key].map { ($0 + speed) / 2 } ?? speed
  }
  /// Frames side by side scanned in one pass when that is quicker (48-bit interface only).
  @Published var rowScanning: Bool { didSet { defaults?.set(rowScanning, forKey: "rowScanning") } }
  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults
    libraryPath = defaults?.string(forKey: "libraryPath")
    exportFormat = defaults?.string(forKey: "exportFormat").flatMap(ExportFormat.init(rawValue:)) ?? .tiff
    exportColorSpace = defaults?.string(forKey: "exportColorSpace").flatMap(ExportColorSpace.init(rawValue:)) ?? .sRGB
    exportNameTemplate = defaults?.string(forKey: "exportNameTemplate") ?? ExportNaming.standard
    let quality = defaults?.double(forKey: "jpegQuality") ?? 0
    jpegQuality = quality > 0 ? min(1, max(0.5, quality)) : 0.97
    sheet = defaults?.data(forKey: "contactSheet").flatMap { try? JSONDecoder().decode(ContactSheet.Layout.self, from: $0) }
      ?? ContactSheet.Layout()
    sharpening = defaults?.data(forKey: "sharpening").flatMap { try? JSONDecoder().decode(SharpeningProfile.self, from: $0) }
    scannerCalibration = defaults?.data(forKey: "scannerCalibration").flatMap { try? JSONDecoder().decode(ScannerCalibration.self, from: $0) }
    removeFlare = defaults?.object(forKey: "removeFlare") as? Bool ?? true
    customProfiles = defaults?.data(forKey: "customProfiles").flatMap { try? JSONDecoder().decode([FilmProfile].self, from: $0) } ?? []
    autoExport = defaults.map { $0.object(forKey: "autoExport") as? Bool ?? true } ?? false
    let dpi = defaults?.integer(forKey: "previewDPI") ?? 0
    previewDPI = Self.previewResolutions.contains(dpi) ? dpi : 600
    showLoupe = defaults?.object(forKey: "showLoupe") as? Bool ?? true
    loupeStyle = defaults?.string(forKey: "loupeStyle").flatMap(LoupeStyle.init(rawValue:)) ?? .pentax
    contactLandscape = defaults?.object(forKey: "contactLandscape") as? Bool ?? true
    let left = defaults?.double(forKey: "leftWidth") ?? 0, right = defaults?.double(forKey: "rightWidth") ?? 0
    leftWidth = left > 0 ? min(Self.leftWidths.upperBound, max(Self.leftWidths.lowerBound, left)) : 230
    scanSpeed = (defaults?.dictionary(forKey: "scanSpeed") as? [String: Double]) ?? [:]
    rowScanning = defaults?.object(forKey: "rowScanning") as? Bool ?? true
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
