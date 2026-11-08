import CoreGraphics
import Foundation

/// The copy light measured from three blank frames, each light alone: its crosstalk and its fall-off
/// across the frame found again from synthetic frames made with known ones, in any order; a negative
/// lit unevenly read evenly once both are taken out; and the next copies coming in with them.
enum CopyLightTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let pipe = ImagePipeline.shared
    let w = 360, h = 240
    let mix = Crosstalk.measured
    // Each light falls off by its own amount, red least, blue most, from a point off the middle both
    // ways, so a field turned over or mirrored would not fit.
    let falls = [0.25, 0.35, 0.5]
    func lit(_ light: Int, _ x: Int, _ y: Int) -> Double {
      let dx = (Double(x) / Double(w) - 0.45) * 2, dy = (Double(y) / Double(h) - 0.4) * 2
      return 1 - falls[light] * (dx * dx + dy * dy) / 2
    }
    func picture(_ value: (Int, Int) -> [Double]) -> CGImage {
      var px = [UInt16](repeating: 0, count: w * h * 3)
      for y in 0..<h { for x in 0..<w { for (c, v) in value(x, y).enumerated() { px[(y * w + x) * 3 + c] = UInt16(min(65535, max(0, v * 65535))) } } }
      return CGImage(
        width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6,
        space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
    // A blank frame with one light on: that light, as each camera channel reads it.
    func blank(_ light: Int, _ level: Double) -> CGImage {
      picture { x, y in (0..<3).map { c in mix.m[3 * c + light] * level * lit(light, x, y) } }
    }
    let frames = [blank(2, 0.6), blank(0, 0.7), blank(1, 0.5)]
    guard let (light, exposure) = pipe.lightCalibration(frames) else { throw DeskError.message("FAIL: light calibrated") }
    let matrixFound = zip(light.crosstalk.m, mix.m).allSatisfy { abs($0 - $1) < 0.01 }
    let corner = light.flat.value(at: CGPoint(x: 0.02, y: 0.03)), middle = light.flat.value(at: CGPoint(x: 0.45, y: 0.4))
    let expected = (0..<3).map { lit($0, w * 2 / 100, h * 3 / 100) }
    try check(matrixFound && (0..<3).allSatisfy { abs(corner.values[$0] - expected[$0]) < 0.04 && abs(middle.values[$0] - 1) < 0.03 }
      && abs(exposure.r - 0.7) < 0.1 && abs(exposure.b - 0.6) < 0.1,
      String(format: "three blank frames, one light each in any order, give the light's crosstalk and how each light falls off: corner %.2f · %.2f · %.2f, made %.2f · %.2f · %.2f",
        corner.r, corner.g, corner.b, expected[0], expected[1], expected[2]))
    try check(pipe.lightCalibration([blank(0, 0.7), blank(0, 0.6), blank(1, 0.5)]) == nil,
      "two frames of the same light do not make a calibration")

    // A blank film base under all three lights, lit unevenly, reads evenly once corrected.
    let film = [0.6, 0.35, 0.25]
    let negative = picture { (x: Int, y: Int) -> [Double] in
      (0..<3).map { (c: Int) -> Double in (0..<3).map { (j: Int) -> Double in mix.m[3 * c + j] * 0.8 * lit(j, x, y) * film[j] }.reduce(0, +) }
    }
    let even = pipe.samples(pipe.corrected(negative, crosstalk: light.crosstalk, flat: light.flat), maxDimension: w)
    let plain = pipe.samples(pipe.corrected(negative, crosstalk: light.crosstalk, flat: nil), maxDimension: w)
    func spread(_ s: Samples) -> Double {
      (0..<3).map { c in
        let v = [(12, 10), (w / 2, h / 2), (w - 12, h - 10), (w - 12, 10), (12, h - 10)].map { s.pixel($0.0, $0.1).values[c] }
        return (v.max()! - v.min()!) / v.max()!
      }.max()!
    }
    // Shown as a negative, the film base is a neutral grey, not the copy light's colour.
    var settings = Adjustments()
    settings.rollBase = RGB((0..<3).map { c in plain.pixel(w / 2, h / 2).values[c] })
    let shownBase = pipe.samples(pipe.neutralNegative(pipe.corrected(negative, crosstalk: light.crosstalk, flat: nil), settings: settings), maxDimension: w).pixel(w / 2, h / 2)
    try check(max(shownBase.r, shownBase.g, shownBase.b) - min(shownBase.r, shownBase.g, shownBase.b) < 0.02,
      String(format: "a negative is shown with its film base a neutral grey, not the copy light's colour: %.2f · %.2f · %.2f", shownBase.r, shownBase.g, shownBase.b))
    try check(spread(even) < 0.04 && spread(plain) > 0.2,
      String(format: "a film base lit unevenly reads the same in the corners as in the middle once the light is taken out: %.0f%% apart, %.0f%% before",
        spread(even) * 100, spread(plain) * 100))

    // The next copies come in read through it; turned off for the roll, as the sensor read them.
    let root = folder.appendingPathComponent("copy-light", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let decoded = root.appendingPathComponent("Decoded", isDirectory: true)
    try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
    let suite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: root.appendingPathComponent("library"), preferences: Preferences(defaults: defaults))
    let edits = UndoManager()
    edits.groupsByEvent = false
    model.undoManager = edits
    for (n, frame) in frames.enumerated() {
      let url = decoded.appendingPathComponent("EPS0000\(n + 1).tif")
      try pipe.saveTIFF(frame, to: url, dpi: 300)
      model.addCapturedFrame(url, original: url, linear: true, sensor: true)
    }
    model.calibrateLight()
    for _ in 0..<100 where model.preferences.lightCalibration == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    let kept = Preferences(defaults: defaults).lightCalibration
    try check(kept.map { zip($0.crosstalk.m, mix.m).allSatisfy { abs($0 - $1) < 0.01 } } == true
      && model.frames.allSatisfy { $0.crosstalk == kept?.crosstalk && $0.flatField == kept?.flat }
      && model.lightDescription.contains("漏进"),
      "the roll's last three frames calibrate the light, kept for the copies to come, and the roll is read through it")
    let url = decoded.appendingPathComponent("EPS00004.tif")
    try pipe.saveTIFF(negative, to: url, dpi: 300)
    model.addCapturedFrame(url, original: url, linear: true, sensor: true)
    let next = model.frames[3]
    model.removeCrosstalk(false)
    try check(next.crosstalk == kept?.crosstalk && next.flatField == kept?.flat
      && model.frames.allSatisfy { $0.crosstalk == nil && $0.flatField == nil },
      "a copy that comes in next is read through the calibrated light; turned off for the roll, every frame is read as the sensor read it")
    edits.undo()
    try check(model.frames.allSatisfy { $0.flatField == kept?.flat }, "and undo reads them through it again")

    // One blank frame under all the lights (no film; the lens's vignetting and the light's
    // unevenness together) gives each light's fall-off once its cells are unmixed; a frame clipped, or
    // with a picture on it, is told.
    func white(_ level: Double) -> CGImage {
      picture { x, y in (0..<3).map { c in (0..<3).map { j in mix.m[3 * c + j] * level * lit(j, x, y) }.reduce(0, +) / 1.5 } }
    }
    let blankFrame = white(0.6)
    let cells = try pipe.blankCells(blankFrame)
    let made = FlatProfile(name: "试", date: Date(timeIntervalSince1970: 0), source: "试", sourceFrame: UUID(), width: w, height: h,
      gridWidth: ImagePipeline.flatGrid.width, gridHeight: ImagePipeline.flatGrid.height, cells: cells)
    let byLight = made.variant(mix)
    let near = byLight.value(at: CGPoint(x: 0.02, y: 0.03)), mid = byLight.value(at: CGPoint(x: 0.45, y: 0.4))
    var tooBright = false, notBlank = false
    do { _ = try pipe.blankCells(white(1.4)) } catch { tooBright = "\(error)".contains("过曝") }
    let textured = picture { x, y in (0..<3).map { c in 0.3 + 0.25 * sin(Double(x) / 7 + Double(c)) * cos(Double(y) / 5) } }
    do { _ = try pipe.blankCells(textured) } catch { notBlank = "\(error)".contains("不像空白帧") }
    let lightsFound = (0..<3).allSatisfy { abs(near.values[$0] - expected[$0]) < 0.04 && abs(mid.values[$0] - 1) < 0.03 }
    try check(lightsFound && tooBright && notBlank,
      String(format: "one blank frame under all the lights gives each light's fall-off once its cells are unmixed (corner %.2f · %.2f · %.2f, made %.2f · %.2f · %.2f); clipped or with a picture on it, it says so",
        near.r, near.g, near.b, expected[0], expected[1], expected[2]))
    let edge = Double(w) * 0.105
    let masked = picture { x, y in
      let open = min(1, max(0, (Double(x) - edge) / 3))
      return (0..<3).map { c in (0.01 + (1 - 0.01) * open) * (0..<3).map { j in mix.m[3 * c + j] * 0.6 * lit(j, x, y) }.reduce(0, +) / 1.5 }
    }
    let maskedFlat = FlatProfile(name: "试", date: Date(timeIntervalSince1970: 0), source: "试", sourceFrame: UUID(), width: w, height: h,
      gridWidth: ImagePipeline.flatGrid.width, gridHeight: ImagePipeline.flatGrid.height, cells: try pipe.blankCells(masked)).variant(mix)
    let inside = (0..<3).map { c in maskedFlat.value(at: CGPoint(x: 0.13, y: 0.5)).values[c] / lit(c, Int(0.13 * Double(w)), h / 2) }
    try check(inside.allSatisfy { abs($0 - 1) < 0.06 },
      String(format: "a holder's mask in the blank leaves the film just inside its soft edge divided by the fall-off there, not by the half-lit edge (%.2f · %.2f · %.2f of it)", inside[0], inside[1], inside[2]))
    let coded = try JSONDecoder().decode(FlatProfile.self, from: JSONEncoder().encode(made))
    try check(coded == made && coded.variant(mix) == byLight && made.fits(width: w, height: h) && made.fits(width: 2 * w, height: 2 * h)
      && !made.fits(width: w + 40, height: h) && !made.fits(width: h, height: w),
      "a flat keeps its blank's readings bit for bit, and fits pictures of the blank's size or twice it, not another shape")

    // Flats given to a roll: blank A's to the whole roll, then blank B's only from B on; a picture
    // of another size is left alone; each read the way its crosstalk reads; undone a step at a time.
    let flatRoot = folder.appendingPathComponent("blank-flat", isDirectory: true)
    try? FileManager.default.removeItem(at: flatRoot)
    let flatSuite = "EpsonScanPlus.tests.\(UUID().uuidString)"
    let flatDefaults = UserDefaults(suiteName: flatSuite)!
    defer { flatDefaults.removePersistentDomain(forName: flatSuite) }
    let flatModel = AppModel(libraryURL: flatRoot.appendingPathComponent("library"), preferences: Preferences(defaults: flatDefaults))
    let flatEdits = UndoManager()
    flatEdits.groupsByEvent = false
    flatModel.undoManager = flatEdits
    flatModel.preferences.removeCrosstalk = false
    try flatModel.startCameraRoll()
    let flatDecoded = flatModel.sessionURL!.appendingPathComponent("Decoded", isDirectory: true)
    try FileManager.default.createDirectory(at: flatDecoded, withIntermediateDirectories: true)
    let odd: CGImage = {
      let ww = w + 40
      let px = [UInt16](repeating: 30000, count: ww * h * 3)
      return CGImage(width: ww, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: ww * 6, space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
        provider: CGDataProvider(data: px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }()
    func capture(_ image: CGImage, _ n: Int) throws {
      let url = flatDecoded.appendingPathComponent(String(format: "DSC%05d.tif", n))
      try pipe.saveTIFF(image, to: url, dpi: 300)
      flatModel.addCapturedFrame(url, original: url, linear: true, sensor: true)
    }
    // 01 blank A · 02 03 film · 04 blank B · 05 06 film · 07 another size
    for (n, image) in [blankFrame, negative, negative, white(0.5), negative, negative, odd].enumerated() { try capture(image, n + 1) }
    let ids = flatModel.frames.map(\.id)
    func settleFlat() { for _ in 0..<200 where flatModel.measuringFlat { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) } }
    flatModel.makeFlat(from: flatModel.frames[0])
    settleFlat()
    let flatA = flatModel.rollFlats.first
    let afterA = flatModel.frames.map(\.flatID)
    let skippedOdd = flatModel.status.contains("跳过")
    flatModel.makeFlat(from: flatModel.frames[3])
    settleFlat()
    let flatB = flatModel.rollFlats.count == 2 ? flatModel.rollFlats[1] : nil
    let afterB = flatModel.frames.map(\.flatID)
    try check(flatA != nil && flatB != nil && flatModel.errorText == nil
      && afterA == [nil, flatA?.id, flatA?.id, flatA?.id, flatA?.id, flatA?.id, nil]
      && afterB == [nil, flatA?.id, flatA?.id, nil, flatB?.id, flatB?.id, nil] && skippedOdd
      && !flatModel.frames[0].enabled && !flatModel.frames[3].enabled
      && flatModel.frames.allSatisfy { f in f.flatField == flatModel.resolvedFlat(f.flatID, crosstalk: f.crosstalk) }
      && flatModel.preferences.flatProfiles.map(\.id) == [flatA?.id, flatB?.id].compactMap { $0 },
      "blank A's flat goes to the whole roll, blank B's only from B on; blanks are unticked, another size is skipped, both kept in the library: \(afterB.map { $0.map { String($0.prefix(4)) } ?? "-" })")
    let evenPlain = spread(pipe.samples(try flatModel.source(for: flatModel.frames[4], maxDimension: w), maxDimension: w))
    flatModel.removeCrosstalk(true)
    let unmixedRight = flatModel.frames[4].flatField == flatB?.variant(flatModel.frames[4].crosstalk) && flatModel.frames[4].crosstalk != nil
    let evenUnmixed = spread(pipe.samples(try flatModel.source(for: flatModel.frames[4], maxDimension: w), maxDimension: w))
    try check(evenPlain < 0.06 && evenUnmixed < 0.04 && unmixedRight,
      String(format: "a film base lit unevenly reads evenly through its blank's flat, as the sensor read it (%.0f%% apart) or with the crosstalk out (%.0f%%), the flat read the same way", evenPlain * 100, evenUnmixed * 100))
    flatEdits.undo()
    let crosstalkUndone = flatModel.frames.allSatisfy { $0.crosstalk == nil } && flatModel.frames.map(\.flatID) == afterB
    flatEdits.undo()
    try check(crosstalkUndone && flatModel.frames.map(\.flatID) == afterA && flatModel.frames[3].enabled
      && flatModel.frames.allSatisfy { f in f.flatField == flatModel.resolvedFlat(f.flatID, crosstalk: f.crosstalk) },
      "undo takes the crosstalk back with the flats kept, then blank B's flat back: each frame names the flat it is divided by again")
    flatEdits.redo()
    // A group given another flat, and none; a new picture takes the last one's.
    _ = flatModel.applyFlat(flatB, to: [ids[1]])
    let toB = flatModel.frames[1].flatID == flatB?.id
    let none = flatModel.applyFlat(nil, to: [ids[1], ids[0]])
    let noneOK = flatModel.frames[1].flatID == nil && flatModel.frames[1].flatField == nil && none.contains("空白帧不补")
    try capture(negative, 8)
    try check(toB && noneOK && flatModel.frames.last?.flatID == flatB?.id && flatModel.frames.last?.flatField == flatB?.variant(nil),
      "a frame given another flat and then none is read so; a new picture takes the flat of the roll's last one")
    // A base picked at a frame's edge and shared moves where it was picked when the flats change.
    flatModel.select(ids[4])
    flatModel.setFilmBase(RGB(r: 0.3, g: 0.2, b: 0.15), at: NormalRect(x: 0.01, y: 0.01, width: 0.02, height: 0.02))
    flatModel.shareFilmBase()
    _ = flatModel.applyFlat(nil, to: [ids[4], ids[5]])
    let moved = flatModel.frames[4].adjustments.base
    try check(moved != nil && moved != RGB(r: 0.3, g: 0.2, b: 0.15) && flatModel.frames[5].adjustments.rollBase == moved
      && flatModel.frames[5].adjustments.rollBaseFrom == ids[4],
      "a base picked at a frame's edge and shared with its flat's frames is read again where it was picked, and shared again")
    flatEdits.undo()
    flatEdits.undo()
    flatEdits.undo()
    // Kept once with the roll: frames keep only the flat's id where it reads back exactly; a frame
    // whose flat is missing opens unflattened and says so.
    flatModel.saveProject()
    let saved = flatModel.sessionURL!.appendingPathComponent(flatModel.projectFileName)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as? [String: Any] ?? [:]
    let savedFrames = json["frames"] as? [[String: Any]] ?? []
    let reopened = AppModel(libraryURL: flatRoot.appendingPathComponent("library"), preferences: Preferences(defaults: flatDefaults))
    reopened.readOnly = true
    reopened.loadProject(saved)
    let sameFlats = reopened.frames.map(\.flatID) == flatModel.frames.map(\.flatID)
      && zip(reopened.frames, flatModel.frames).allSatisfy { $0.flatField == $1.flatField }
    var lost = json
    lost["flats"] = nil
    let lostURL = flatModel.sessionURL!.appendingPathComponent("lost.epscan")
    try JSONSerialization.data(withJSONObject: lost).write(to: lostURL)
    reopened.loadProject(lostURL)
    try check(json["version"] as? Int == 2 && (json["flats"] as? [Any])?.count == 2
      && savedFrames.filter { $0["flatID"] != nil }.allSatisfy { $0["flatField"] == nil } && sameFlats
      && reopened.frames.allSatisfy { $0.flatID == nil } && reopened.status.contains("找不到"),
      "a roll keeps each flat once, its frames only the id; it opens read alike, and a frame whose flat is gone opens unflattened, said")
    try capture(white(0.55), 9)
    let before = flatModel.frames.map(\.flatID)
    flatModel.makeFlat(from: flatModel.frames[8])
    settleFlat()
    let flatC = flatModel.rollFlats.last
    let untouched = Array(flatModel.frames.prefix(8).map(\.flatID)) == Array(before.prefix(8)) && flatModel.status.contains("之后拍进来的照片")
    try capture(negative, 10)
    let nextTakesC = flatModel.frames.last?.flatID == flatC?.id && flatC?.sourceFrame == flatModel.frames[8].id
    flatEdits.undo()
    try check(untouched && nextTakesC && !flatModel.blankFrameIDs.contains(flatModel.frames[8].id) && flatModel.rollFlats.count == 2,
      "a blank shot after a change of setup leaves the frames before it alone, and the next picture takes it; undone, the frame is a picture again")
    // A measurement that ends after another roll was opened goes to the library only.
    flatModel.makeFlat(from: flatModel.frames[3])
    try flatModel.startCameraRoll()
    settleFlat()
    try check(flatModel.frames.isEmpty && flatModel.rollFlats.isEmpty && flatModel.preferences.flatProfiles.count == 4 && flatModel.status.contains("已存进列表"),
      "a flat measured while another roll was opened is kept in the library and given to no roll")
  }
}
