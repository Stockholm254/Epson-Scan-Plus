import Foundation

/// A copy roll's edges checked against each other, and the copy light balanced from the base.
enum BaseChecksTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let model = AppModel(libraryURL: folder.appendingPathComponent("base-checks"))
    model.readOnly = true
    func copy(_ name: String, base: RGB) -> FilmFrame {
      var f = FilmFrame(name: name, rect: .full, format: "135")
      f.sourcePath = "/tmp/base-check-\(name).arw"
      f.sensorRead = true
      f.adjustments.inputGamma = 1
      f.edgeBase = EdgeBase(base: base, areas: [])
      return f
    }
    // Four copies at one light, a fifth with its edge half a stop darker in blue.
    let even = RGB(r: 0.72, g: 0.41, b: 0.18)
    model.frames = [copy("01", base: even), copy("02", base: even), copy("03", base: even), copy("04", base: even),
      copy("05", base: RGB(r: 0.72, g: 0.41, b: 0.18 / pow(2, 0.5)))]
    let apart = model.baseDrift(model.frames[4]), alike = model.baseDrift(model.frames[1])
    try check(apart.map { abs($0.b - 0.5 * log10(2)) < 1e-6 && abs($0.r) < 1e-9 } == true && alike.map { $0.values.allSatisfy { abs($0) < 1e-9 } } == true
      && model.baseNotes(model.frames[4]).contains("中途调过灯") && !model.baseNotes(model.frames[1]).contains("中途调过灯"),
      String(format: "a copy whose edge reads apart from the roll's is told (blue %+.3f D), the others not", apart?.b ?? -1))
    // The light: red reads 72%, green 41%, blue 18% of full; green ×1.76 and blue ×4 bring them level.
    let ratio = model.lightRatio(model.frames[0])
    try check(ratio.map { abs($0.factors.r - 1) < 1e-9 && abs($0.factors.g - 0.72 / 0.41) < 1e-9 && abs($0.factors.b - 4) < 1e-9 } == true
      && model.baseNotes(model.frames[0]).contains("蓝灯 ×4.00"),
      "on the copy stand the base's reading says how to set each light so all three channels fill alike")
    var scanned = model.frames[0]
    scanned.sensorRead = nil
    try check(model.lightRatio(scanned) == nil, "a picture not read from the camera's sensor gets no light advice")
  }
}
