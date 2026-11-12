import AppKit
import Foundation
import ImageIO

/// Flat fields from blank frames (no film; the copies' macro lens, aperture, magnification and
/// light): made from a frame of the roll, kept in a library, and given to groups of the roll's
/// frames, each frame divided by its own (`FilmFrame.flatID`, set only through `relight`).
extension AppModel {
  /// A frame's flat id with 应用平场 switched off: divided by no flat.
  static let noFlat = "none"
  /// The roll's blank frames: those its flats were made from.
  var blankFrameIDs: Set<UUID> { Set(rollFlats.map(\.sourceFrame)) }
  /// A picture a blank frame's flat could divide: a linear file, as a camera's are decoded.
  func isLinearPicture(_ f: FilmFrame) -> Bool { f.sourcePath != nil && f.adjustments.inputGamma == 1 }
  /// The roll has such pictures.
  var hasLinearPictures: Bool { frames.contains(where: isLinearPicture) }
  /// A picture's size as decoded, read once.
  func pictureSize(_ f: FilmFrame) -> (width: Int, height: Int)? {
    guard let path = f.sourcePath else { return nil }
    if let kept = pictureSizes[path] { return kept }
    let info = ImagePipeline.shared.info(URL(fileURLWithPath: path))
    guard info.width > 0, info.height > 0 else { return nil }
    pictureSizes[path] = (info.width, info.height)
    return (info.width, info.height)
  }
  /// Whether `flat` can divide frame `f`: a linear picture of the blank's size (or twice it).
  func flat(_ flat: FlatProfile, fits f: FilmFrame) -> Bool {
    guard isLinearPicture(f), let size = pictureSize(f) else { return false }
    return flat.fits(width: size.width, height: size.height)
  }
  /// The blank frame's flat frame `f` is divided by, if any.
  func flatProfile(of f: FilmFrame) -> FlatProfile? { f.flatID.flatMap { id in rollFlats.first { $0.id == id } } }
  /// What frame `f` is divided by, in a few words: a blank frame's flat, or none.
  func flatName(_ f: FilmFrame) -> String {
    if f.flatID == Self.noFlat { return "不补" }
    return flatProfile(of: f)?.name ?? "没有"
  }
  /// The roll as the flats' sources name it.
  var rollTitle: String {
    let name = rollName.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? (sessionURL?.lastPathComponent ?? "") : name
  }

  /// The camera's own file a decoded picture came from, in the roll's Captures folder (a picture
  /// imported as it is, that file).
  func originalCapture(_ f: FilmFrame) -> URL? {
    guard let path = f.sourcePath else { return nil }
    let url = URL(fileURLWithPath: path)
    guard url.deletingLastPathComponent().lastPathComponent == "Decoded" else { return url }
    let stem = url.deletingPathExtension().lastPathComponent
    let captures = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Captures")
    let found = FileManager.default.enumerator(at: captures, includingPropertiesForKeys: nil)
    while let u = found?.nextObject() as? URL {
      if u.deletingPathExtension().lastPathComponent == stem && Self.rawExtensions.contains(u.pathExtension.lowercased()) { return u }
    }
    return nil
  }
  /// The aperture and capture time a camera file records, where it does.
  static func captureFacts(_ url: URL?) -> (aperture: Double?, date: Date?) {
    guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return (nil, nil) }
    let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let aperture = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
    let read = DateFormatter()
    read.locale = Locale(identifier: "en_US_POSIX")
    read.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return (aperture, (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(read.date(from:)))
  }
  /// A new flat's name: when its blank was taken, and at what aperture.
  static func flatName(date: Date, aperture: Double?) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: date) + (aperture.map { String(format: " · f/%g", $0) } ?? " · 平场")
  }

  /// Why the flats cannot change now, or nil: neutral points being picked are read through the flat
  /// they were picked under, and mixing two in one fit would bend the slopes.
  var flatsBlocked: String? {
    if !calibrationPoints.isEmpty { return "左栏的预设标定里正在取 \(calibrationPoints.count) 个点：先生成预设或清除，再改平场。" }
    if measuringFlat { return "正在量平场…" }
    if isWorking { return "等扫描或导出完成再改平场。" }
    return nil
  }

  /// Measures frame `frame` as a blank frame apart from the main thread: a new flat in the library;
  /// on the roll it was made on, if that is still open and has the frame, kept with the roll, the
  /// blank unticked, and given to the frames it belongs to (`blankScope`).
  func makeFlat(from frame: FilmFrame) {
    guard flatsBlocked == nil else {
      errorText = flatsBlocked
      return
    }
    guard isLinearPicture(frame), let path = frame.sourcePath else {
      errorText = "平场要用相机拍的空白帧（线性读出的 RAW）：扫描和 JPEG 不行。"
      return
    }
    // Film at its edges: a picture of a negative, not a blank.
    if frame.edgeBase?.base != nil {
      errorText = "第 \(frame.name) 张的片边找到了未曝光的片基：这是一张底片的照片，不是空白帧。拿走底片，用同样的镜头、光圈、放大倍率和灯拍一张，再用那张。"
      return
    }
    let session = sessionURL, id = frame.id, name = frame.name, roll = rollTitle, original = originalCapture(frame)
    measuringFlat = true
    status = "正在从第 \(name) 张量平场…"
    renderQueue.async {
      let result = Result { () -> FlatProfile in
        let pipe = ImagePipeline.shared
        let url = URL(fileURLWithPath: path)
        let cells = try pipe.blankCells(try pipe.load(url, maxDimension: 1200))
        let size = pipe.info(url)
        let facts = Self.captureFacts(original)
        let date = facts.date ?? Date()
        return FlatProfile(
          name: Self.flatName(date: date, aperture: facts.aperture), date: date,
          source: "\(roll) · 第 \(name) 张" + (original.map { " · \($0.lastPathComponent)" } ?? ""),
          sourceFrame: id, width: size.width, height: size.height, aperture: facts.aperture,
          gridWidth: ImagePipeline.flatGrid.width, gridHeight: ImagePipeline.flatGrid.height, cells: cells)
      }
      DispatchQueue.main.async {
        self.measuringFlat = false
        switch result {
        case .failure(let error):
          self.errorText = "第 \(name) 张量不了平场：\(error.localizedDescription)"
        case .success(let flat):
          self.preferences.flatProfiles.append(flat)
          guard self.sessionURL == session, self.frames.contains(where: { $0.id == id }), self.flatsBlocked == nil else {
            self.status = "平场「\(flat.name)」已存进列表：量完时已换了卷、删了那一张或正在忙，没有用到照片上"
            return
          }
          self.adoptFlat(flat, blank: id)
        }
      }
    }
  }
  /// `flat`, just made from frame `blank` of this roll: kept with the roll, the blank unticked (no
  /// film on it to export), and given to the frames it belongs to, as one edit.
  private func adoptFlat(_ flat: FlatProfile, blank: UUID) {
    // A step of its own, however soon after the last: not a fader being dragged.
    recordEdit("平场", key: UUID().uuidString)
    rollFlats.append(flat)
    let scope = blankScope(blank)
    // The blank itself is not divided, nor exported, nor de-masked: shown as it was read, the light
    // and how it falls off towards the edges.
    if let i = frames.firstIndex(where: { $0.id == blank }) {
      frames[i].enabled = false
      frames[i].adjustments.inputIsNegative = false
      if frames[i].flatID != nil { relight(i, crosstalk: frames[i].crosstalk, flatID: nil) }
    }
    let done = assignFlat(flat.id, to: scope)
    status = "平场「\(flat.name)」：" + scopeWords(scope) + "，用到 \(done.applied) 张"
      + (done.skipped > 0 ? "；\(done.skipped) 张尺寸和空白帧不同，跳过" : "") + "；空白帧已取消勾选"
    finishFlatChange()
  }
  /// The frames a blank frame's flat goes to: the whole roll while it has no other blank; else from
  /// the blank to the frame before the next blank. A blank shot after a change of setup comes before
  /// its frames, so with none after it yet it goes to none now, and the frames shot next take it.
  /// Blank frames themselves are left out.
  func blankScope(_ blank: UUID) -> [UUID] {
    guard let at = frames.firstIndex(where: { $0.id == blank }) else { return [] }
    let blanks = blankFrameIDs.union([blank])
    let others = frames.indices.filter { $0 != at && blanks.contains(frames[$0].id) }
    guard !others.isEmpty else { return frames.map(\.id).filter { !blanks.contains($0) } }
    let range = (at + 1)..<(others.first { $0 > at } ?? frames.count)
    return range.map { frames[$0].id }.filter { !blanks.contains($0) }
  }
  /// `scope` as the status says it: the whole roll, or from one frame to another.
  func scopeWords(_ scope: [UUID]) -> String {
    let names = frames.filter { scope.contains($0.id) }.map(\.name)
    guard let first = names.first, let last = names.last else { return "之后拍进来的照片" }
    if scope.count == frames.count - blankFrameIDs.intersection(Set(frames.map(\.id))).count { return "整卷" }
    return first == last ? "第 \(first) 张" : "第 \(first)–\(last) 张"
  }
  /// The frames `ids` divided by the roll's flat `id` (nil: none), each read again through it; frames it does not fit are left alone. No edit
  /// of its own: the caller records one.
  @discardableResult func assignFlat(_ id: String?, to ids: [UUID]) -> (applied: Int, skipped: Int) {
    let profile = id.flatMap { i in rollFlats.first { $0.id == i } }
    var applied = 0, skipped = 0
    for fid in ids {
      guard let i = frames.firstIndex(where: { $0.id == fid }) else { continue }
      if let profile, !flat(profile, fits: frames[i]) {
        skipped += 1
        continue
      }
      applied += 1
      if frames[i].flatID == id && frames[i].flatField == resolvedFlat(id, crosstalk: frames[i].crosstalk) { continue }
      relight(i, crosstalk: frames[i].crosstalk, flatID: id)
    }
    reshareRollBases()
    return (applied, skipped)
  }
  /// `flat` (nil: none) given to frames `ids` as one edit; blank frames and frames it does not fit
  /// stay as they are. Returns what it did, in words. `off`: 应用平场 switched off.
  @discardableResult func applyFlat(_ flat: FlatProfile?, to ids: [UUID], off: Bool = false) -> String {
    if let blocked = flatsBlocked { return blocked }
    let flat = off ? nil : flat
    if let flat, !rollFlats.contains(where: { $0.id == flat.id }) { rollFlats.append(flat) }
    let blanks = blankFrameIDs
    let targets = ids.filter { !blanks.contains($0) }
    recordEdit(flat == nil ? "不补平场" : "平场", key: UUID().uuidString)
    let done = assignFlat(off ? Self.noFlat : flat?.id, to: targets)
    let said = (flat.map { "「\($0.name)」用到 \(done.applied) 张" } ?? "\(done.applied) 张不补平场")
      + (done.skipped > 0 ? "；\(done.skipped) 张尺寸和空白帧不同，跳过" : "") + (targets.count < ids.count ? "；空白帧不补" : "")
    status = "平场：" + said
    finishFlatChange()
    return said
  }
  /// The flats frame `f` can be divided by: the roll's and then the library's that fit it.
  func flatChoices(for f: FilmFrame) -> [FlatProfile] {
    var seen = Set<String>()
    return (rollFlats + preferences.flatProfiles).filter { p in seen.insert(p.id).inserted && flat(p, fits: f) }
  }
  /// Frame `f` is divided by a blank frame's flat field.
  func flatApplied(_ f: FilmFrame) -> Bool { f.flatField != nil }
  /// The flat 应用平场 switched on gives frame `f`: that of the blank whose frames it is among,
  /// else the newest that fits; nil where none fits.
  func defaultFlat(for f: FilmFrame) -> FlatProfile? {
    rollFlats.last { blankScope($0.sourceFrame).contains(f.id) && flat($0, fits: f) } ?? flatChoices(for: f).last
  }
  /// 应用平场 for the selected frame: off, divided by no flat; on, by the flat it would take
  /// (`defaultFlat`). One edit, undone with ⌘Z.
  func setFlatApplied(_ on: Bool) {
    guard let f = selected, !blankFrameIDs.contains(f.id) else { return }
    if on { applyFlat(defaultFlat(for: f), to: [f.id]) } else { applyFlat(nil, to: [f.id], off: true) }
  }
  /// The selected frame's flat chosen: one of `flatChoices` by id.
  func chooseFlat(_ id: String) {
    guard let f = selected else { return }
    guard let p = flatChoices(for: f).first(where: { $0.id == id }) else { return }
    applyFlat(p, to: [f.id])
  }
  /// 应用到本卷: the selected frame's flat or none, given to the roll's frames;
  /// blank frames and frames it does not fit stay as they are.
  func applySelectedFlatToRoll() {
    guard let f = selected else { return }
    let all = frames.map(\.id)
    if f.flatID == Self.noFlat { applyFlat(nil, to: all, off: true) } else { applyFlat(flatProfile(of: f), to: all) }
  }
  /// The flat a new picture of `width` × `height` takes: that of the roll's last picture its size,
  /// or, where that is a blank, the blank's own (a blank comes before the frames shot after it).
  func flatForNext(width: Int, height: Int) -> FlatProfile? {
    let blanks = blankFrameIDs
    guard let last = frames.last(where: { isLinearPicture($0) && pictureSize($0).map { $0 == (width, height) } ?? false }) else { return nil }
    let flat = blanks.contains(last.id) ? rollFlats.last { $0.sourceFrame == last.id } : flatProfile(of: last)
    return flat.flatMap { $0.fits(width: width, height: height) ? $0 : nil }
  }
  /// Each base picked for the roll taken again from the frame it was picked on, as that frame reads
  /// it now, for the frames on the same flat field and crosstalk: `relight` reads a shared base at a
  /// frame's middle, where the base picked at its edge was not.
  func reshareRollBases() {
    for i in frames.indices {
      guard frames[i].adjustments.rollBasePicked == true, let from = frames[i].adjustments.rollBaseFrom,
        let source = frames.first(where: { $0.id == from }), let base = source.adjustments.base,
        source.flatID == frames[i].flatID, source.crosstalk == frames[i].crosstalk
      else { continue }
      frames[i].adjustments.rollBase = base
    }
  }
  /// After the roll's frames are read through other flat fields: what the app measured on them,
  /// measured again, and the roll shown and kept as it now is.
  func finishFlatChange() {
    updateRollBase()
    updateRollSlopes()
    updateRollPrint()
    refresh()
    updateThumbnails()
    saveProject()
    measureEdgeBases()
  }

  /// A flat renamed, in the library and in this roll.
  func renameFlat(_ id: String, to name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    for i in preferences.flatProfiles.indices where preferences.flatProfiles[i].id == id { preferences.flatProfiles[i].name = name }
    for i in rollFlats.indices where rollFlats[i].id == id { rollFlats[i].name = name }
    saveProject()
  }
  /// Flats deleted from the library; the rolls using them keep their own copies.
  func deleteFlats(_ ids: Set<String>) {
    preferences.flatProfiles.removeAll { ids.contains($0.id) }
  }
  /// A roll's own copy of a flat put back in the library, for other rolls to use.
  func keepFlat(_ flat: FlatProfile) {
    guard !preferences.flatProfiles.contains(where: { $0.id == flat.id }) else { return }
    preferences.flatProfiles.append(flat)
  }
}
