import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The frame's EXIF: read from the camera's own file beside the decoded one, written as a
/// photographer reads it.
enum PhotoInfoTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let root = folder.appendingPathComponent("photo-info", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let captures = root.appendingPathComponent("Captures", isDirectory: true)
    let decoded = root.appendingPathComponent("Decoded", isDirectory: true)
    for d in [captures, decoded] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    // A camera's picture, as a JPEG carrying what a Sony RAW does.
    let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let shot = captures.appendingPathComponent("EPS00007.jpg")
    let dest = CGImageDestinationCreateWithURL(shot as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SONY", kCGImagePropertyTIFFModel: "ILCE-7RM4"],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifExposureTime: 0.003125, kCGImagePropertyExifFNumber: 4.5,
        kCGImagePropertyExifISOSpeedRatings: [100], kCGImagePropertyExifFocalLength: 70,
        kCGImagePropertyExifLensModel: "Sony E 70mm F2.8", kCGImagePropertyExifDateTimeOriginal: "2026:11:07 13:21:52",
        kCGImagePropertyExifExposureBiasValue: -0.3,
      ],
    ] as CFDictionary)
    try check(CGImageDestinationFinalize(dest), "a test picture with EXIF is written")
    let rows = Dictionary(uniqueKeysWithValues: PhotoInfo.rows(shot).map { ($0.label, $0.value) })
    try check(rows["相机"] == "SONY ILCE-7RM4" && rows["镜头"] == "Sony E 70mm F2.8" && rows["焦距"] == "70 mm"
      && rows["光圈"] == "f/4.5" && rows["快门"] == "1/320 s" && rows["ISO"] == "100" && rows["曝光补偿"] == "-0.3 EV"
      && rows["拍摄时间"] == "2026-11-07 13:21:52" && rows["尺寸"] == "64 × 48 · 8 位",
      "a picture's EXIF reads as a photographer reads it: \(PhotoInfo.rows(shot).map { "\($0.label) \($0.value)" }.joined(separator: "，"))")
    try check(PhotoInfo.shutter(0.5) == "0.5 s" && PhotoInfo.shutter(2) == "2 s" && PhotoInfo.shutter(1.0 / 60) == "1/60 s",
      "shutter speeds: a fraction below a third of a second, seconds above")
    // Decoded into the roll's Decoded folder from a RAW in Captures: the RAW holds the EXIF.
    let raw = captures.appendingPathComponent("EPS00008.ARW"), tif = decoded.appendingPathComponent("EPS00008.tif")
    for url in [raw, tif, decoded.appendingPathComponent("EPS00009.tif")] { try Data([0]).write(to: url) }
    var frame = FilmFrame(name: "08", rect: .full, format: "翻拍")
    frame.sourcePath = tif.path
    var alone = FilmFrame(name: "09", rect: .full, format: "翻拍")
    alone.sourcePath = decoded.appendingPathComponent("EPS00009.tif").path
    var scanned = FilmFrame(name: "01", rect: .full, format: "135")
    scanned.scanPath = "/scans/01.tif"
    // Compared as files: under /var/folders the listing gives /private/var's path, the same file.
    try check(PhotoInfo.file(for: frame)?.resolvingSymlinksInPath() == raw.resolvingSymlinksInPath()
      && PhotoInfo.file(for: alone)?.lastPathComponent == "EPS00009.tif"
      && PhotoInfo.file(for: scanned)?.path == "/scans/01.tif" && PhotoInfo.file(for: FilmFrame(name: "02", rect: .full, format: "135")) == nil,
      "the EXIF comes from the camera's RAW beside the decoded picture, else the picture's own file or its scan")
  }
}
