import AppKit
import Foundation

/// A scanned roll of several holder loads: a preview made over the roll open is asked about, kept
/// as the roll's next preview with its frames numbered on and shown on a page of its own; a frame's
/// pixels come from its own preview whichever is shown; the roll saved and opened again keeps them,
/// as the library does; scanning a frame of another holder asks for it; a preview let go leaves the
/// roll as it was, and one that began a new roll can be let go too.
enum MultiPreviewTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    func settle(_ seconds: Double = 0.1) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    /// A holder's preview of one colour, as its film is.
    func film(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
      let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
      return ctx.makeImage()!
    }
    func mean(_ image: CGImage) -> [Double] {
      let r = ImagePipeline.shared.raster(image, maxDimension: 64)
      var sum = [0.0, 0.0, 0.0]
      for y in 0..<r.height { for x in 0..<r.width { let p = r.pixel(x, y).values; for c in 0..<3 { sum[c] += p[c] } } }
      return sum.map { $0 / Double(r.width * r.height) }
    }
    let library = folder.appendingPathComponent("multi-preview", isDirectory: true)
    try? FileManager.default.removeItem(at: library)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    let model = AppModel(libraryURL: library)
    var trashed = [URL]()
    model.discardRollFolder = { url in
      trashed.append(url)
      try? FileManager.default.removeItem(at: url)
    }
    func waitDetecting() { for _ in 0..<100 where model.detectingFrames || model.rendering { settle() } }
    let mm = CGSize(width: 150, height: 100)

    // The first holder: a new roll, asked whether to keep it; three frames drawn on it.
    model.receiveOverview(film(0.8, 0.45, 0.3), size: mm, dpi: 100)
    waitDetecting()
    try check(model.previewDecision == .keepNew && model.sessionURL != nil && model.previewCount == 1,
      "a preview with no roll open begins a new roll, and asks whether to keep it")
    model.keepNewRoll()
    let roll = model.sessionURL!
    model.frames.removeAll()
    for i in 0..<3 { model.addFrame(NormalRect(x: 0.05 + Double(i) * 0.3, y: 0.2, width: 0.25, height: 0.5)) }
    let firstNames = model.frames.map(\.name)

    // The second holder, over the roll open: shown, nothing on it, asked about.
    model.receiveOverview(film(0.3, 0.45, 0.8), size: mm, dpi: 100)
    try check(model.previewDecision == .addOrNew && model.pendingPreview != nil && model.contactFrames.isEmpty
      && model.displayed === model.pendingPreview?.working && model.frames.count == 3 && model.sessionURL == roll,
      "a preview over a roll with frames is shown with nothing on it and asked about, the roll as it was")
    model.addPendingPreview()
    waitDetecting()
    model.frames.removeAll { model.previewIndex(of: $0) == 1 }
    for i in 0..<2 { model.addFrame(NormalRect(x: 0.1 + Double(i) * 0.4, y: 0.25, width: 0.3, height: 0.45)) }
    let second = model.frames.filter { model.previewIndex(of: $0) == 1 }
    let numbers = model.frames.compactMap { Int($0.name) }
    try check(model.previewCount == 2 && model.activePreview == 1 && model.loadedPreview == 1 && second.count == 2
      && second.allSatisfy { $0.preview == 1 } && Set(numbers).count == numbers.count
      && second.compactMap { Int($0.name) }.min()! > firstNames.compactMap { Int($0) }.max()!
      && model.contactPages == [.holder(0), .holder(1)] && model.contactFrames.map(\.id) == second.map(\.id)
      && model.overviewURL?.lastPathComponent == "overview-2.tif" && model.previewDecision == nil,
      "加到这一卷 keeps the preview as the roll's second, a page of its own, its frames numbered on from the first's")

    // Each frame's pixels from its own preview, whichever is shown.
    let red = try model.source(for: model.frames[0], raw: true), blue = try model.source(for: second[0], raw: true)
    let (r, b) = (mean(red), mean(blue))
    try check(r[0] > r[2] + 0.2 && b[2] > b[0] + 0.2, "a frame's picture comes from its own preview, the other one shown (\(r.map { Int($0 * 255) }), \(b.map { Int($0 * 255) }))")
    model.showContactPage(0)
    try check(model.activePreview == 0 && model.overviewURL?.lastPathComponent == "overview.tif"
      && model.contactFrames.count == 3 && model.analysisKey(second[0]).contains("overview-2.tif"),
      "turning to the first page shows the first preview, and the other's frames keep theirs")

    // Saved and opened again, as the library reads it too.
    model.saveProject()
    let reopened = AppModel(libraryURL: library)
    reopened.loadProject(roll.appendingPathComponent(AppModel.projectFile))
    let entry = RollLibrary.entry(roll.appendingPathComponent(AppModel.projectFile))
    try check(reopened.previewCount == 2 && reopened.overviewURL?.lastPathComponent == "overview.tif"
      && reopened.frames.filter { reopened.previewIndex(of: $0) == 1 }.map(\.name) == second.map(\.name)
      && entry?.frames.filter { $0.preview?.lastPathComponent == "overview-2.tif" }.count == 2,
      "the roll opened again keeps both previews and which frame lies on which; the library knows too")
    reopened.singleView = false
    reopened.showContactPage(1)
    try check(reopened.activePreview == 1 && reopened.overviewURL?.lastPathComponent == "overview-2.tif"
      && reopened.physicalMM == mm, "and shows the second on its page")

    // Scanning a frame of the first holder while the second is on the scanner asks for it.
    var asked: (Int, [Int], Int, Int)?
    model.askPutBack = { off, others, loaded, on in
      asked = (off, others, loaded, on)
      return .cancel
    }
    model.select(model.frames[0].id)
    model.scanSelected()
    try check(asked.map { $0.0 == 1 && $0.1 == [0] && $0.2 == 1 && $0.3 == 0 } == true && !model.isWorking,
      "scanning a frame of the first holder with the second on the scanner asks for it to be put back, and scans nothing when not")

    // A preview let go leaves the roll as it was; one kept as a new roll leaves it in the library.
    let before = model.frames
    model.receiveOverview(film(0.5, 0.5, 0.5), size: mm, dpi: 100)
    model.discardPendingPreview()
    try check(model.frames.map(\.id) == before.map(\.id) && model.frames.map(\.rect) == before.map(\.rect) && model.pendingPreview == nil && model.previewDecision == nil && model.previewCount == 2,
      "不保留 lets the preview go, the roll as it was")
    model.receiveOverview(film(0.5, 0.5, 0.5), size: mm, dpi: 100)
    model.pendingAsNewRoll()
    waitDetecting()
    let newRoll = model.sessionURL
    try check(newRoll != nil && newRoll != roll && model.previewCount == 1 && model.previewDecision == nil
      && FileManager.default.fileExists(atPath: roll.appendingPathComponent(AppModel.projectFile).path),
      "存成新的一卷 makes a roll of it, the one open before staying in the library")
    // A preview that began a new roll, let go: that roll put away, an empty project again.
    model.newProject()
    model.receiveOverview(film(0.6, 0.4, 0.3), size: mm, dpi: 100)
    waitDetecting()
    let begun = model.sessionURL
    model.discardNewRoll()
    try check(begun != nil && trashed == [begun!] && model.sessionURL == nil && model.frames.isEmpty && model.previewDecision == nil,
      "a new roll a preview began, not kept, is put away and the window is an empty new project again")

    // 合并同类卷: a scanned roll merged into another: its folder moved into the other's Merged
    // folder, its frames on a page of their own preview, numbered on, read where their files now
    // are; the library lists one roll; a roll of another kind is not offered.
    let target = AppModel(libraryURL: library)
    target.discardRollFolder = model.discardRollFolder
    func scannedRoll(_ m: AppModel, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, frames n: Int) -> URL {
      m.newProject()
      m.receiveOverview(film(r, g, b), size: mm, dpi: 100)
      for _ in 0..<100 where m.detectingFrames || m.rendering { settle() }
      m.keepNewRoll()
      m.frames.removeAll()
      for i in 0..<n { m.addFrame(NormalRect(x: 0.05 + Double(i) * 0.3, y: 0.2, width: 0.25, height: 0.5)) }
      m.saveProject()
      return m.sessionURL!
    }
    let rollA = scannedRoll(target, 0.8, 0.45, 0.3, frames: 3), rollB = scannedRoll(target, 0.3, 0.45, 0.8, frames: 2)
    let entries = RollLibrary.scan([library])
    let entryA = entries.first { $0.folder.standardizedFileURL.path == rollA.standardizedFileURL.path }
    let offered = entryA.map { AppModel.mergeCandidates(for: $0, among: entries).map(\.folder.lastPathComponent) } ?? []
    let added = try target.mergeRolls(into: rollA.appendingPathComponent(AppModel.projectFile), from: [rollB.appendingPathComponent(AppModel.projectFile)])
    let fromB = target.frames.filter { target.previewIndex(of: $0) == target.previewCount - 1 }
    let blueB = try fromB.first.map { mean(try target.source(for: $0, raw: true)) } ?? [0, 0, 0]
    let after = RollLibrary.scan([library]).map(\.folder.lastPathComponent)
    let names = target.frames.compactMap { Int($0.name) }
    let mergedInto = target.sessionURL?.standardizedFileURL.path == rollA.standardizedFileURL.path
    try check(offered.contains(rollB.lastPathComponent) && added == 2 && mergedInto && target.frames.count == 5
      && fromB.count == 2 && blueB[2] > blueB[0] + 0.2 && Set(names).count == 5
      && FileManager.default.fileExists(atPath: rollA.appendingPathComponent("Merged").appendingPathComponent(rollB.lastPathComponent).path)
      && !FileManager.default.fileExists(atPath: rollB.path) && after.contains(rollA.lastPathComponent) && !after.contains(rollB.lastPathComponent),
      "合并同类卷 moves the other roll's folder into this one's, its frames on a page of their own preview, numbered on and read where they now are, one roll in the library"
        + " (offered \(offered.contains(rollB.lastPathComponent)), added \(added), into \(mergedInto), frames \(target.frames.count), its \(fromB.count), blue \(blueB.map { Int($0 * 255) }), library \(after.contains(rollA.lastPathComponent)) \(!after.contains(rollB.lastPathComponent)))")
    let reopened2 = AppModel(libraryURL: library)
    reopened2.loadProject(rollA.appendingPathComponent(AppModel.projectFile))
    try check(reopened2.frames.count == 5 && reopened2.previewCount == target.previewCount
      && reopened2.frames.allSatisfy { reopened2.previewURL(of: $0).map { FileManager.default.fileExists(atPath: $0.path) } ?? false },
      "and opened again it keeps every frame and preview, each file found")
    try? FileManager.default.removeItem(at: library)
  }
}
