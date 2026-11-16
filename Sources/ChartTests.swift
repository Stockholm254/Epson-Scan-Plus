import CoreGraphics
import Foundation

/// 色卡 (0.24): a chart shot on a film measured its slopes and fitted its colour matrix; each is used
/// only where the roll chooses it, the slopes then before the roll's estimate, the matrix keeping
/// greys as they were and turning colours. Phoenix II's, refitted on 2026-11-16.
enum ChartTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let phoenix = FilmProfile.builtins.first { $0.id == "phoenix2-200" }!
    let m = phoenix.colorMatrix ?? []
    try check(phoenix.chartMeasured == true && phoenix.slopes == RGB(r: 0.60, g: 0.40, b: 0.59) && m.count == 9
      && (0..<3).allSatisfy { r in abs(m[3 * r] + m[3 * r + 1] + m[3 * r + 2] - 1) < 0.001 }
      && FilmProfile.builtins.filter { $0.colorMatrix != nil }.map(\.id) == ["phoenix2-200"],
      "Phoenix II carries its chart's slopes (red 0.60, green 0.40, blue 0.59) and colour matrix, each row adding up to 1; no other film has one")
    // The slopes: the roll's estimate first, unless the roll chose the chart's.
    var estimated = Adjustments()
    estimated.rollSlopes = RGB(r: 0.903, g: 0.55, b: 0.73)
    var chosen = phoenix
    chosen.chartFirst = true
    try check(ImagePipeline.slopes(estimated, phoenix).slopes == estimated.rollSlopes && ImagePipeline.slopes(estimated, chosen).slopes == phoenix.slopes,
      "the roll's estimate comes before the chart's slopes, unless the roll chose them in 色卡")
    // The roll's switches, by the roll's film: a copy preset calibrated for Phoenix II, its calibration off.
    let suite = "local.epscan.chart-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(libraryURL: folder.appendingPathComponent("chart", isDirectory: true), preferences: Preferences(defaults: defaults))
    model.profile = FilmProfile.builtins.first { $0.id == "generic" }!
    model.filmName = "Harman Phoenix II 200"
    let off = model.conversionProfile
    model.setChartSlopes(true)
    let slopesOn = model.conversionProfile
    model.setChartColour(true)
    let both = model.conversionProfile
    model.setChartSlopes(false)
    model.setChartColour(false)
    try check(model.chartFilm?.id == "phoenix2-200" && off.chartFirst == nil && off.colourInUse == nil
      && slopesOn.chartFirst == true && slopesOn.slopes == phoenix.slopes && slopesOn.colourInUse == nil
      && both.colourInUse == m && model.conversionProfile == off,
      "a Phoenix II roll converts as before until 色卡 chooses the chart's slopes, its colour matrix, or both; switched off, as before again")
    model.filmName = "Kodak Portra 160"
    model.profile = FilmProfile.builtins.first { $0.id == "portra160" }!
    try check(model.chartFilm == nil, "a film with no chart shot on it has no 色卡")
    // The matrix in the conversion: greys as they were, a colour turned.
    var with = Adjustments.newFrame
    with.base = RGB(r: 0.30, g: 0.62, b: 0.52)
    let rows = ImagePipeline.filmColourRows(with, both), none = ImagePipeline.filmColourRows(with, off)
    var mono = with
    mono.setMonochrome(true)
    try check(none.map { [$0.x, $0.y, $0.z] } == [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
      && rows.allSatisfy { abs($0.x + $0.y + $0.z - 1) < 1e-12 } && ImagePipeline.filmColourRows(mono, both).map { [$0.x, $0.y, $0.z] } == [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
      "the kernel gets the identity without a chosen matrix, a black and white roll's too; the matrix's rows add up to exactly 1")
    let pipe = ImagePipeline.shared
    let base = with.base!
    func reading(_ e: [Double]) -> [Double] { (0..<3).map { base.values[$0] * pow(10, -phoenix.slopes.values[$0] * e[$0] / 2.2) } }
    let w = 120, h = 40
    var samples = [UInt16](repeating: 65535, count: w * h * 4)
    for y in 0..<h {
      for x in 0..<w {
        var e = Array(repeating: 0.2 + 1.0 * Double(x) / Double(w - 1), count: 3)
        if y >= 30, (40..<80).contains(x) { e = [1.05, 0.80, 0.35] }
        let v = reading(e)
        for c in 0..<3 { samples[(y * w + x) * 4 + c] = UInt16(min(1, v[c]) * 65535) }
      }
    }
    let negative = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
      provider: CGDataProvider(data: Data(bytes: samples, count: samples.count * 2) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    with.neutralSample = RGB(reading([0.7, 0.7, 0.7]))
    var plainProfile = phoenix
    plainProfile.chartFirst = true
    var colouredProfile = plainProfile
    colouredProfile.colourInUse = m
    let a = pipe.analyze(negative, settings: with, profile: plainProfile)
    guard let o1 = pipe.render(negative, settings: with, profile: plainProfile, analysis: a, negative: false),
      let o2 = pipe.render(negative, settings: with, profile: colouredProfile, analysis: a, negative: false)
    else { throw DeskError.message("FAIL: the chart's negative could not be converted") }
    let r1 = pipe.raster(o1, maxDimension: 120), r2 = pipe.raster(o2, maxDimension: 120)
    var greyMoved = 0.0, colourMoved = 0.0
    for x in 0..<r1.width {
      let g1 = r1.pixel(x, 10), g2 = r2.pixel(x, 10)
      greyMoved = max(greyMoved, (0..<3).map { abs(g1.values[$0] - g2.values[$0]) }.max()!)
    }
    for x in 45..<75 {
      let c1 = r1.pixel(x, 35), c2 = r2.pixel(x, 35)
      colourMoved = max(colourMoved, (0..<3).map { abs(c1.values[$0] - c2.values[$0]) }.max()!)
    }
    try check(greyMoved <= 1.5 / 255 && colourMoved > 4 / 255,
      String(format: "with the chart's colour matrix the grey ramp prints as it did (%.1f levels at most), a yellow-orange turns (%.0f levels)", greyMoved * 255, colourMoved * 255))
  }
}
