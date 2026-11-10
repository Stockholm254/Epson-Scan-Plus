import CoreGraphics
import Foundation

struct RGB: Codable, Equatable {
  var r: Double
  var g: Double
  var b: Double
  static let one = RGB(r: 1, g: 1, b: 1)
  static let zero = RGB(r: 0, g: 0, b: 0)
  var values: [Double] { [r, g, b] }
  init(r: Double, g: Double, b: Double) {
    self.r = r
    self.g = g
    self.b = b
  }
  init(_ v: [Double]) { self.init(r: v[0], g: v[1], b: v[2]) }
}

/// How a copy stand's light falls off across the frame, light by light: each of its red, green and
/// blue lights alone on a blank frame, the crosstalk taken out, as a coarse grid over the picture
/// normalised to its brightest cell. Dividing a picture read with the same crosstalk out by it
/// lights every part of the frame as its brightest was.
struct FlatField: Codable, Equatable {
  var width: Int
  var height: Int
  /// Row by row from the top left, the red, green and blue light's share in each cell.
  var values: [Float]
  /// The share at `p` (normalised to the picture, from the top left), between the cells' centres.
  func value(at p: CGPoint) -> RGB {
    let x = min(max(p.x * Double(width) - 0.5, 0), Double(width - 1)), y = min(max(p.y * Double(height) - 0.5, 0), Double(height - 1))
    let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
    let fx = x - Double(x0), fy = y - Double(y0)
    func at(_ cx: Int, _ cy: Int, _ c: Int) -> Double { Double(values[(cy * width + cx) * 3 + c]) }
    return RGB((0..<3).map { c in
      (at(x0, y0, c) * (1 - fx) + at(x1, y0, c) * fx) * (1 - fy) + (at(x0, y1, c) * (1 - fx) + at(x1, y1, c) * fx) * fy
    })
  }
  /// Each light's weakest cell against its brightest: how far it falls off across the frame.
  var falloff: RGB {
    RGB((0..<3).map { c in Double(stride(from: c, to: values.count, by: 3).map { values[$0] }.min() ?? 1) })
  }
  /// A reading at `p` lit as `from` lit it (nil: as read), put as `to` lights it instead.
  static func moved(_ v: RGB, at p: CGPoint, from: FlatField?, to: FlatField?) -> RGB {
    guard from != to else { return v }
    let back = from.map { f in RGB((0..<3).map { v.values[$0] * f.value(at: p).values[$0] }) } ?? v
    return to.map { f in RGB((0..<3).map { back.values[$0] / max(0.05, f.value(at: p).values[$0]) }) } ?? back
  }
}

/// A flat field made from a blank frame: no film, shot with the copies' macro lens, aperture,
/// magnification and light, so how it falls off across the picture is the lens's vignetting and the
/// light's unevenness together, each channel's own. It keeps the blank's own readings, cell by cell,
/// and gives the field for a picture read either way (`variant`), with the crosstalk out or as the
/// sensor read it, so the grid never changes under its id. Several make a library; a roll keeps a
/// copy of each its frames use.
struct FlatProfile: Codable, Identifiable, Equatable {
  var id: String
  var name: String
  /// When the blank was taken (its file's capture time), else when it was measured.
  var date: Date
  /// Where it was measured: the roll, the frame and the original file, as words.
  var source: String
  /// The blank frame, in the roll it was made on.
  var sourceFrame: UUID
  /// The blank's picture, as decoded.
  var width: Int
  var height: Int
  /// The aperture the blank was taken at, when its file says (an f-number).
  var aperture: Double?
  var notes: String = ""
  /// Each cell's median reading per channel, linear and as the sensor read it, row by row from the
  /// top left: `gridWidth` × `gridHeight` cells of red, green and blue.
  var gridWidth: Int
  var gridHeight: Int
  var cells: [Float]

  /// The field a picture read through `crosstalk` (nil: as the sensor read it) is divided by: each
  /// cell's reading unmixed alike, every channel against its brightest cell; cells under a quarter
  /// of it (a holder's mask) are left alone.
  func variant(_ crosstalk: Crosstalk?) -> FlatField {
    let n = gridWidth * gridHeight
    var read = [RGB]()
    read.reserveCapacity(n)
    for i in 0..<n {
      let v = RGB(r: Double(cells[i * 3]), g: Double(cells[i * 3 + 1]), b: Double(cells[i * 3 + 2]))
      read.append(crosstalk.map { $0.unmixed(v) } ?? v)
    }
    var values = [Float](repeating: 1, count: n * 3)
    for c in 0..<3 {
      let top = read.map { $0.values[c] }.max() ?? 0
      guard top > 0 else { continue }
      for i in 0..<n {
        let share = read[i].values[c] / top
        values[i * 3 + c] = Float(share >= 0.25 ? share : 1)
      }
    }
    return FlatField(width: gridWidth, height: gridHeight, values: values)
  }
  /// Whether a picture of `width` × `height` was taken as the blank was: the same size, or twice it
  /// each way (a 16-shot pixel-shift composite), within a hundredth. A crop mode, a picture turned
  /// or another camera does not fit.
  func fits(width w: Int, height h: Int) -> Bool {
    guard width > 0, height > 0 else { return false }
    func near(_ a: Int, _ b: Int, _ k: Double) -> Bool { abs(Double(a) / (Double(b) * k) - 1) < 0.01 }
    let same = near(w, width, 1) && near(h, height, 1)
    return same || near(w, width, 2) && near(h, height, 2)
  }
  /// Each channel's darkest share, as the sensor read it: how far it falls off.
  var falloff: RGB { variant(nil).falloff }

  private enum CodingKeys: String, CodingKey {
    case id, name, date, source, sourceFrame, width, height, aperture, notes, gridWidth, gridHeight, cells
  }
  init(
    id: String = UUID().uuidString, name: String, date: Date, source: String, sourceFrame: UUID, width: Int, height: Int,
    aperture: Double? = nil, notes: String = "", gridWidth: Int, gridHeight: Int, cells: [Float]
  ) {
    (self.id, self.name, self.date, self.source, self.sourceFrame) = (id, name, date, source, sourceFrame)
    (self.width, self.height, self.aperture, self.notes) = (width, height, aperture, notes)
    (self.gridWidth, self.gridHeight, self.cells) = (gridWidth, gridHeight, cells)
  }
  // The cells as little-endian Float32 in base64: a fifth of the JSON numbers, and read back bit for bit.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    date = try c.decode(Date.self, forKey: .date)
    source = try c.decode(String.self, forKey: .source)
    sourceFrame = try c.decode(UUID.self, forKey: .sourceFrame)
    width = try c.decode(Int.self, forKey: .width)
    height = try c.decode(Int.self, forKey: .height)
    aperture = try c.decodeIfPresent(Double.self, forKey: .aperture)
    notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    gridWidth = try c.decode(Int.self, forKey: .gridWidth)
    gridHeight = try c.decode(Int.self, forKey: .gridHeight)
    let data = Data(base64Encoded: try c.decode(String.self, forKey: .cells)) ?? Data()
    cells = data.withUnsafeBytes { raw in (0..<(data.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) } }
    guard cells.count == gridWidth * gridHeight * 3 else {
      throw DecodingError.dataCorruptedError(forKey: .cells, in: c, debugDescription: "flat field cells do not fill the grid")
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(date, forKey: .date)
    try c.encode(source, forKey: .source)
    try c.encode(sourceFrame, forKey: .sourceFrame)
    try c.encode(width, forKey: .width)
    try c.encode(height, forKey: .height)
    try c.encodeIfPresent(aperture, forKey: .aperture)
    if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
    try c.encode(gridWidth, forKey: .gridWidth)
    try c.encode(gridHeight, forKey: .gridHeight)
    var data = Data(capacity: cells.count * 4)
    for v in cells { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    try c.encode(data.base64EncodedString(), forKey: .cells)
  }
}

/// A copy stand's light, measured from its red, green and blue lights each alone on a blank frame:
/// how the camera's channels mix them, and how each falls off across the frame.
struct LightCalibration: Codable, Equatable {
  var date: Date
  var crosstalk: Crosstalk
  var flat: FlatField
}

/// How a camera's channels mix the red, green and blue lights of a copy stand: `m` row by row, a
/// row each camera channel and a column each light, each light read as 1 in its own channel.
/// Light adds up, so the mix is undone exactly in the linear readings, before the film base
/// divides them out; a density mix only comes near it. Under white light, whose spectrum is
/// continuous, no such matrix holds.
struct Crosstalk: Codable, Equatable {
  var m: [Double]
  /// The A7R IV under the author's copy light, from an IT8.7/1 target lit by each light alone
  /// (2026-10-29): the blue light reads 34% in green, the green 12% and 11% in red and blue.
  static let measured = Crosstalk(m: [
    1, 0.11926, 0.04549,
    0.14866, 1, 0.33603,
    0.02556, 0.10633, 1,
  ])
  /// The rows of the matrix that takes the mix out.
  var inverse: [Double] {
    let a = m
    let c0 = a[4] * a[8] - a[5] * a[7], c1 = a[5] * a[6] - a[3] * a[8], c2 = a[3] * a[7] - a[4] * a[6]
    let det = a[0] * c0 + a[1] * c1 + a[2] * c2
    return [
      c0, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
      c1, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
      c2, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3],
    ].map { $0 / det }
  }
  /// A reading with the mix taken out: what each light alone gave. Never quite nothing, so that a
  /// density can still be taken of it.
  func unmixed(_ v: RGB) -> RGB { Self.times(inverse, v) }
  /// A reading with the mix put back, as the camera read it.
  func mixed(_ v: RGB) -> RGB { Self.times(m, v) }
  private static func times(_ a: [Double], _ v: RGB) -> RGB {
    RGB((0..<3).map { (c: Int) -> Double in max(1e-6, a[3 * c] * v.r + a[3 * c + 1] * v.g + a[3 * c + 2] * v.b) })
  }
  /// The leak of each light into the other channels, as percentages, the largest first: for saying
  /// what a calibration found.
  var largestLeak: (light: Int, channel: Int, share: Double) {
    var best = (light: 0, channel: 0, share: 0.0)
    for c in 0..<3 { for j in 0..<3 where c != j && m[3 * c + j] > best.share { best = (j, c, m[3 * c + j]) } }
    return best
  }
  /// A reading taken with `from` out of it (nil: as read) put as it reads with `to` out instead.
  static func moved(_ v: RGB, from: Crosstalk?, to: Crosstalk?) -> RGB {
    guard from != to else { return v }
    let read = from?.mixed(v) ?? v
    return to?.unmixed(read) ?? read
  }
}

struct NormalRect: Codable, Equatable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  static let full = NormalRect(x: 0, y: 0, width: 1, height: 1)
  var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
  /// Holds `other` whole, to within a ten-thousandth.
  func covers(_ other: NormalRect) -> Bool {
    let e = 1e-4
    return other.x >= x - e && other.y >= y - e && other.x + other.width <= x + width + e && other.y + other.height <= y + height + e
  }
  init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  init(_ rect: CGRect) {
    let r = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    self.init(
      x: r.isNull ? 0 : r.minX, y: r.isNull ? 0 : r.minY, width: r.isNull ? 0 : r.width,
      height: r.isNull ? 0 : r.height)
  }
  func pixels(_ size: CGSize) -> CGRect {
    let requested = CGRect(
      x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height
    ).intersection(CGRect(origin: .zero, size: size))
    guard !requested.isNull else { return .zero }
    // Outward integral rounding could put a bright seam pixel back into a crop.
    // Tolerance preserves exact integer edges after normalized-coordinate math.
    let left = ceil(requested.minX - 1e-7)
    let top = ceil(requested.minY - 1e-7)
    return CGRect(
      x: left, y: top, width: max(0, floor(requested.maxX + 1e-7) - left),
      height: max(0, floor(requested.maxY + 1e-7) - top))
  }
  func relative(to parent: NormalRect) -> NormalRect {
    NormalRect(
      x: (x - parent.x) / parent.width, y: (y - parent.y) / parent.height,
      width: width / parent.width, height: height / parent.height)
  }
  func mapped(into parent: NormalRect) -> NormalRect {
    NormalRect(
      x: parent.x + x * parent.width, y: parent.y + y * parent.height, width: width * parent.width,
      height: height * parent.height)
  }
  func contains(_ other: NormalRect, tolerance: Double = 0.000001) -> Bool {
    other.x >= x - tolerance && other.y >= y - tolerance
      && other.x + other.width <= x + width + tolerance
      && other.y + other.height <= y + height + tolerance
  }
  func expanded(by fraction: Double) -> NormalRect {
    NormalRect(cg.insetBy(dx: -width * fraction, dy: -height * fraction))
  }
}

/// All crop, pick and orientation coordinates use a top-left origin, independent of CI's axes.
/// A frame is shown straightened first (turned by its angle and cut to the largest rectangle of
/// its own shape inside), then turned by quarters and mirrored. The straightening needs the
/// frame's shape (its width over its height); without one it is left out, as for the crop tool,
/// which shows the frame's surroundings as they lie.
enum ImageGeometry {
  /// How much of a frame `aspect` wide to one high is kept across, turned by `degrees`.
  static func keep(_ degrees: Double, aspect: Double) -> Double {
    let t = abs(degrees) * .pi / 180, w = aspect
    return min(w / (w * cos(t) + sin(t)), 1 / (w * sin(t) + cos(t)))
  }
  /// A point of the frame to where it shows straightened, or back: turned clockwise on screen by
  /// `degrees` about the middle and spread by what is cut away.
  static func straightened(_ p: CGPoint, degrees: Double, aspect: Double, inverse: Bool = false) -> CGPoint {
    guard abs(degrees) > 0.0001, aspect > 0 else { return p }
    let k = keep(degrees, aspect: aspect), t = degrees * .pi / 180, c = cos(t), s = sin(t)
    if inverse {
      let u = (Double(p.x) - 0.5) * k * aspect, v = (Double(p.y) - 0.5) * k
      return CGPoint(x: (u * c + v * s) / aspect + 0.5, y: -u * s + v * c + 0.5)
    }
    let u = (Double(p.x) - 0.5) * aspect, v = Double(p.y) - 0.5
    return CGPoint(x: (u * c - v * s) / (k * aspect) + 0.5, y: (u * s + v * c) / k + 0.5)
  }
  static func display(_ p: CGPoint, settings: Adjustments, aspect: Double? = nil) -> CGPoint {
    let p = aspect.map { straightened(p, degrees: settings.angle ?? 0, aspect: $0) } ?? p
    var q: CGPoint
    switch ((settings.rotation % 4) + 4) % 4 {
    case 1: q = CGPoint(x: 1 - p.y, y: p.x)
    case 2: q = CGPoint(x: 1 - p.x, y: 1 - p.y)
    case 3: q = CGPoint(x: p.y, y: 1 - p.x)
    default: q = p
    }
    if settings.flipHorizontal == true { q.x = 1 - q.x }
    return q
  }
  static func raw(_ p: CGPoint, settings: Adjustments, aspect: Double? = nil) -> CGPoint {
    var q = p
    if settings.flipHorizontal == true { q.x = 1 - q.x }
    let r: CGPoint
    switch ((settings.rotation % 4) + 4) % 4 {
    case 1: r = CGPoint(x: q.y, y: 1 - q.x)
    case 2: r = CGPoint(x: 1 - q.x, y: 1 - q.y)
    case 3: r = CGPoint(x: 1 - q.y, y: q.x)
    default: r = q
    }
    return aspect.map { straightened(r, degrees: settings.angle ?? 0, aspect: $0, inverse: true) } ?? r
  }
  static func transform(_ rect: NormalRect, settings: Adjustments, inverse: Bool = false)
    -> NormalRect
  {
    let corners = [
      CGPoint(x: rect.x, y: rect.y), CGPoint(x: rect.x + rect.width, y: rect.y),
      CGPoint(x: rect.x, y: rect.y + rect.height),
      CGPoint(x: rect.x + rect.width, y: rect.y + rect.height),
    ].map { inverse ? raw($0, settings: settings) : display($0, settings: settings) }
    let xs = corners.map(\.x)
    let ys = corners.map(\.y)
    return NormalRect(
      x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }
}

/// A roll's print: the balance (and per-channel gain) and the black and white ends, in the
/// conversion's log exposure, as `ToneAnalysis` holds them for one frame; and how far its brightest
/// frame's highlights run past the white (nil in prints made before it was kept).
struct RollPrint: Codable, Equatable {
  var balance: RGB
  var gain: RGB
  var low: Double
  var high: Double
  var reach: Double? = nil
}

struct Adjustments: Codable, Equatable {
  var autoWhiteBalance = true
  var autoLevels = true
  var exposure = 0.0
  var warmth = 0.0
  var tint = 0.0
  /// The dark tones made warmer (positive) or cooler, the light ones as they are: shade lit by a
  /// blue sky warmed without warming the sunlit greys. −1 to 1, nil as it is.
  var shadowWarmth: Double? = nil
  var shadowWarmthAmount: Double {
    get { shadowWarmth ?? 0 }
    set { shadowWarmth = newValue == 0 ? nil : newValue }
  }
  /// The same dark tones made greener (negative) or more magenta, as shadow warmth moves them
  /// between red and blue: the two together take a shade to neutral whichever way it leans, such
  /// as haze in shadow that only the blue layer took, coming out violet. It only takes out the
  /// opposite cast: green where the shadow is violet, never on grass already green. −1 to 1, nil as it is.
  var shadowTint: Double? = nil
  var shadowTintAmount: Double {
    get { shadowTint ?? 0 }
    set { shadowTint = newValue == 0 ? nil : newValue }
  }
  var black = 0.0
  var white = 1.0
  var midtone = 1.0
  var contrast = 1.0
  var saturation = 1.0
  /// Black and white run out softly, as on paper: a toe under the darkest tones and a shoulder over
  /// the brightest, and the shadows' colour kept. Nil is on; false is the straight cut.
  var softEnds: Bool? = nil
  var softEndsOn: Bool {
    get { softEnds != false }
    set { softEnds = newValue ? nil : false }
  }
  /// The dark tones and the light tones made lighter (positive) or darker, black and white held
  /// and every tone kept in order: −1 to 1, nil as it is.
  var shadows: Double? = nil
  var shadowsAmount: Double {
    get { shadows ?? 0 }
    set { shadows = newValue == 0 ? nil : newValue }
  }
  /// The light tones pressed down, white with them, the darker half and the colours as they are:
  /// 0 to 1, nil none.
  var pressHighlights: Double? = nil
  var pressHighlightsAmount: Double {
    get { pressHighlights ?? 0 }
    set { pressHighlights = newValue == 0 ? nil : newValue }
  }
  var highlights: Double? = nil
  var highlightsAmount: Double {
    get { highlights ?? 0 }
    set { highlights = newValue == 0 ? nil : newValue }
  }
  /// Colour noise smoothed away, the grain's lightness left as it is: 0 (or nil) off, 1 as a copy
  /// shot comes in with.
  var colourNoise: Double? = nil
  var colourNoiseAmount: Double {
    get { colourNoise ?? 0 }
    set { colourNoise = newValue }
  }
  var inputGamma = 2.2
  var inputIsNegative = true
  /// The film is reversal film, a slide: its reading is the picture already, not a negative, read
  /// raw (linear off the scanner), so it is shown through its own white balance and ends and
  /// encoded for the screen. Nil for a negative, or a file already made positive, shown as it is.
  var reversal: Bool? = nil
  /// A slide's reading, converted as `reversal` says; never a negative's.
  var isSlide: Bool { reversal == true && !inputIsNegative }
  /// Read as a slide, or as a negative again. A slide's own colour is its picture, so it starts
  /// with auto white balance off; a negative with it on, as it always does.
  mutating func setReversal(_ on: Bool) {
    (inputIsNegative, reversal, autoWhiteBalance) = on ? (false, true, false) : (true, nil, true)
  }
  var base: RGB? = nil
  /// Where `base` was picked on the frame, normalised in the frame as cropped; nil when it came
  /// from elsewhere (the light table, an assistant).
  var basePicked: NormalRect? = nil
  /// The roll's film base, measured by the app between the frames; used when `base` is nil.
  var rollBase: RGB? = nil
  /// The roll base was picked by hand once, on the leader or a frame's edge, and shared with the
  /// roll, rather than measured between the frames: the gaps do not replace it.
  var rollBasePicked: Bool? = nil
  /// The frame a base picked for the roll was picked on, so it is read again where it was picked.
  var rollBaseFrom: UUID? = nil
  /// The roll's channel slopes, estimated by the app across all its frames; used unless the
  /// preset is calibrated for this scanner.
  var rollSlopes: RGB? = nil
  /// The roll printed as a lab prints one, worked out from all its frames together (`rollPrint`):
  /// with `sharedBalance` its frames share one white balance, so each comes out in the same colour;
  /// with `sharedLevels` one pair of black and white ends, so a dark scene stays dark, each frame
  /// its own exposure. Nil each frame its own.
  var sharedBalance: Bool? = nil
  var sharedLevels: Bool? = nil
  var printsWithRoll: Bool { sharedBalance == true || sharedLevels == true }
  /// The roll's print, measured by the app across its frames; used while either is on.
  var rollPrint: RollPrint? = nil
  var manualBalance: RGB? = nil
  var rotation = 0
  var flipHorizontal: Bool? = nil
  // EV per channel; applied AFTER automatic estimation, never cancelled by it.
  var baseFine: RGB? = nil
  /// The de-masking region: the part of the picture the base estimate, white balance, levels and
  /// highlight reach are read from (`ImagePipeline.analysisPart`), in the picture's own crop
  /// normalised from its top left, unturned. Nil follows the picture, less its outer 5%. Where the
  /// picture is shown and exported is the crop's alone; a base picked or found at the film's edges
  /// still comes from where it was read.
  var analysisRegion: NormalRect? = nil
  var neutralSample: RGB? = nil  // Encoded negative values, recalculated if the film/base changes.
  /// Where `neutralSample` was picked, normalised in the frame's picture (not its crop); nil when
  /// not known.
  var neutralPicked: NormalRect? = nil
  // The white picked as the densest highlight (`highlightSample`, Dmax) is gone (2026-11-07): it
  // fitted each channel's contrast to a point on the film's shoulder in place of the roll's or the
  // calibration's slopes. A project saved with one opens without it, the key not read.
  /// Deconvolution strength 0...1 from the scanner profile; nil uses the frame's default.
  var sharpening: Double? = nil
  /// RGB and per-channel tone curves, applied after conversion; nil leaves tones as they are.
  var curves: ToneCurves? = nil
  /// Straightening, in degrees clockwise on screen, before the quarter turns: the frame turned
  /// about its middle and cut to the largest rectangle of its own shape inside. Nil is level.
  var angle: Double? = nil
  /// Turns the displayed picture 90°. Rotation is applied before the mirror, so a
  /// mirrored frame needs the opposite raw step to turn the same way on screen.
  mutating func turn(clockwise: Bool) {
    let step = clockwise == (flipHorizontal != true) ? 1 : 3
    rotation = ((rotation + step) % 4 + 4) % 4
  }
}

/// Where a calibrated preset's neutral point was picked: the frame (and its name then), and the
/// spot in its source, as `NeutralPoint.at`; and what was read there, so the calibration can be
/// taken up again and points added to it (presets from 0.11.1 and before kept only the spot).
struct CalibrationSpot: Codable, Equatable {
  var frame: UUID
  var name: String
  var x: Double
  var y: Double
  var value: RGB? = nil
  var base: RGB? = nil
  var gamma: Double? = nil
}

struct FilmProfile: Codable, Identifiable, Equatable {
  var id: String
  var name: String
  var aliases: [String]
  var iso: Int
  var process: String
  var sourceURL: String
  var publication: String
  var slopes: RGB
  var notes: String
  /// Calibrated presets only: each channel's neutral offset from green in log exposure, so a
  /// neutral reads the same in all channels. Used when auto white balance is off.
  var offsets: RGB? = nil
  /// Each channel's toe width in log exposure, where the density curve bends towards the base:
  /// D = D-min + slope · w · ln(1 + e^(x / w)), undone in the conversion. Only presets calibrated
  /// on this scanner from neutrals reaching into the shadows have one; nil keeps the straight line.
  var toe: RGB? = nil
  /// Calibrated presets only: where their neutral points were picked, so the frames can show them.
  var spots: [CalibrationSpot]? = nil
  /// The toes of the Kodak data sheets' Status M curves, traced from their vector drawings (RMS
  /// under 0.03 D). Not applied as they are: on a V850 roll of Portra 160 the edges' channel ratios
  /// near the base did not follow them, and converting with them tinted the roll pink. Calibration
  /// takes green's from here and fits red's and blue's to the user's own neutrals.
  static let dataSheetToes: [String: RGB] = [
    "portra160": RGB(r: 0.160, g: 0.110, b: 0.150), "portra400": RGB(r: 0.165, g: 0.115, b: 0.145),
    "ektar100": RGB(r: 0.130, g: 0.100, b: 0.075),
  ]
  /// This film's data-sheet toe, also for a preset calibrated from it ("portra160-v850-…", or
  /// "portra160-copy-…" on the copy stand).
  var dataSheetToe: RGB? {
    Self.dataSheetToes[id] ?? Self.dataSheetToes.first { id.hasPrefix($0.key + "-v850-") || id.hasPrefix($0.key + "-copy-") }?.value
  }
  static let approximation = "使用官方特性曲线中段的人工读图近似；不是扫描仪 ICC 标定。片基与色阶由当前扫描估计。"
  static let builtins: [FilmProfile] = [
    FilmProfile(
      id: "portra160", name: "Kodak Portra 160", aliases: ["portra160", "portra 160", "柯达160"],
      iso: 160, process: "C-41 · 日光",
      sourceURL:
        "https://business.kodakmoments.com/sites/default/files/files/products/e4051_portra_160.pdf",
      publication: "Kodak E-4051 · 2016 · p.4", slopes: RGB(r: 0.52, g: 0.55, b: 0.62),
      notes: approximation),
    FilmProfile(
      id: "portra400", name: "Kodak Portra 400", aliases: ["portra400", "portra 400", "柯达400"],
      iso: 400, process: "C-41 · 日光",
      sourceURL:
        "https://imaging.kodakalaris.com/sites/default/files/files/resources/e4050_portra_400.pdf",
      publication: "Kodak E-4050 · 2016 · p.4", slopes: RGB(r: 0.55, g: 0.56, b: 0.64),
      notes: approximation),
    FilmProfile(
      id: "ektar100", name: "Kodak Ektar 100", aliases: ["ektar100", "ektar 100"], iso: 100,
      process: "C-41 · 日光",
      sourceURL:
        "https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4046_ektar_100.pdf",
      publication: "Kodak E-4046 · 2016 · p.4", slopes: RGB(r: 0.56, g: 0.57, b: 0.65),
      notes: approximation),
    FilmProfile(
      id: "generic", name: "通用彩色负片", aliases: ["generic", "通用"], iso: 0, process: "彩色负片",
      sourceURL: "", publication: "通用起点 · 未匹配文档", slopes: RGB(r: 0.55, g: 0.55, b: 0.55),
      notes: "未匹配到技术文档，使用相同通道斜率。可导入带来源链接的 JSON 胶片配置。"),
  ]
  /// A film's own slopes set each channel's contrast; only the generic preset, which has no film
  /// data, lets auto white balance stretch the channels to the scene instead.
  var setsChannelContrast: Bool { id != "generic" }
  func validate() throws {
    guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil, !name.isEmpty,
      slopes.values.allSatisfy({ $0.isFinite && $0 >= 0.1 && $0 <= 2.0 }),
      toe?.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 0.6 }) ?? true
    else { throw DeskError.message("胶片配置无效：ID 须为字母、数字、短横线或下划线，通道斜率须在 0.1–2.0，趾部宽度须在 0–0.6。") }
    if !sourceURL.isEmpty {
      guard let u = URL(string: sourceURL), ["https", "http"].contains(u.scheme ?? "") else {
        throw DeskError.message("技术文档链接必须为 http/https。")
      }
    }
  }
}

struct FilmFrame: Identifiable, Codable {
  var id = UUID()
  var name: String
  var rect: NormalRect {
    // The de-masking region stays where it lay on the film as the crop changes, cut to the new
    // crop; it follows the picture again once less than 2% of it is left inside.
    didSet {
      guard rect != oldValue, let region = adjustments.analysisRegion, rect.width > 0, rect.height > 0 else { return }
      let onFilm = region.mapped(into: oldValue).cg.intersection(rect.cg)
      guard !onFilm.isNull, onFilm.width > rect.width * 0.02, onFilm.height > rect.height * 0.02 else {
        adjustments.analysisRegion = nil
        return
      }
      adjustments.analysisRegion = NormalRect(onFilm).relative(to: rect)
    }
  }
  var format: String
  var enabled = true
  var adjustments = Adjustments()
  var scanPath: String? = nil
  var scanRect: NormalRect? = nil  // Physical footprint of the immutable original scan.
  var initialRect: NormalRect? = nil
  // Imported full source; rect is applied non-destructively. scanPath is already cropped.
  var sourcePath: String? = nil
  var scanDPI: Int? = nil
  var sourceBits: Int? = nil
  /// `scanPath` and `sourcePath` relative to the project folder, written only in saved projects.
  var scanFile: String? = nil
  var sourceFile: String? = nil
  /// The scan's levels against the preview, measured when it arrives (or when a project from
  /// before 0.4.9 is opened); conversion puts the scan on the preview's scale with it.
  var levels: LevelRegistration? = nil
  /// A camera RAW read straight from its sensor, in the camera's own channels (not through the
  /// system's RAW engine, which applies the camera's colour matrix). Nil in projects from before
  /// it was recorded, until the file is looked at.
  var sensorRead: Bool? = nil
  /// The copy light's crosstalk taken out of the picture as read, before anything is measured on
  /// it; nil keeps it as the sensor read it.
  var crosstalk: Crosstalk? = nil
  /// The unexposed film at the picture's edges, for a picture a file each; nil until looked for.
  var edgeBase: EdgeBase? = nil
  /// The copy light's flat field divided out of the picture after its crosstalk, so every part of
  /// the frame reads as if lit as its brightest; nil leaves it as lit.
  var flatField: FlatField? = nil
  /// The flat field from a blank frame the picture is divided by (`FlatProfile.id`, kept with the
  /// roll); nil for the copy light's, or none.
  var flatID: String? = nil
  /// Dust found on the film or marked by hand, filled as the frame is read; nil until looked for.
  var dust: DustState? = nil
  var captureRect: NormalRect { scanRect ?? rect }
  var hasFullResolution: Bool {
    sourcePath != nil || (scanPath != nil && captureRect.contains(rect))
  }
  var needsRescan: Bool { scanPath != nil && sourcePath == nil && !captureRect.contains(rect) }
}

struct DeskProject: Codable {
  var version = 1
  var overviewPath: String
  var overviewDPI: Double
  var physicalWidthMM: Double
  var physicalHeightMM: Double
  var filmName: String
  var profile: FilmProfile
  var scanDPI: Int
  var frames: [FilmFrame]
  var scanBackendID: String? = nil
  var overviewInputGamma: Double? = nil
  /// `overviewPath` relative to the project folder.
  var overviewFile: String? = nil
  /// The roll's name and notes in the library; nil until given.
  var rollName: String? = nil
  var notes: String? = nil
  /// Where its pictures came from (`RollSource`); nil for rolls the app tells by their frames.
  var source: String? = nil
  /// Its pictures that are a file each are estimated together, as one roll; nil, apart.
  var poolPictures: Bool? = nil
  /// False: its calibrated preset converts as the film it was calibrated from; nil, with it.
  var useCalibration: Bool? = nil
  /// The flat fields its frames are divided by (`FilmFrame.flatID`), and those made on it.
  var flats: [FlatProfile]? = nil
  /// The roll's film format as chosen (`FilmFormat`'s raw value); nil, 自动.
  var format: String? = nil
}

/// A project names its files by absolute path, which older versions read, and relative to its
/// folder, so the folder can be moved or renamed.
enum ProjectFiles {
  /// `path` relative to `folder`, when it lies inside it.
  static func relative(_ path: String, to folder: URL) -> String? {
    let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    guard file.hasPrefix(base + "/") else { return nil }
    return String(file.dropFirst(base.count + 1))
  }
  /// The file inside the folder under its relative name, else the saved absolute path, else, for
  /// an older project that was moved, the same trailing path components inside the folder.
  static func resolve(_ path: String, relative: String?, in folder: URL) -> String {
    let files = FileManager.default
    if let relative {
      let inside = folder.appendingPathComponent(relative).path
      if files.fileExists(atPath: inside) { return inside }
    }
    if files.fileExists(atPath: path) { return path }
    let parts = URL(fileURLWithPath: path).pathComponents
    for n in stride(from: min(3, parts.count - 1), through: 1, by: -1) {
      let inside = folder.appendingPathComponent(parts.suffix(n).joined(separator: "/")).path
      if files.fileExists(atPath: inside) { return inside }
    }
    return path
  }
}

enum DeskError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let s) = self { return s }
    return nil
  }
}

enum CanvasTool: String, CaseIterable {
  case select = "选择"
  case crop = "画框"
  case region = "去色罩区域"
  case base = "片基"
  case neutral = "中性灰"
  case shadowNeutral = "阴影中性"
  case calibrate = "标定中性点"
  case it8 = "IT8 色卡"
  case dust = "灰尘"
  /// Lightroom's targeted adjustment of the curves: a place on the picture held and dragged up or
  /// down moves the curve taken where that place lies on it. Its key is in the curves section.
  case curve = "曲线目标调整"

  /// The tools a click reads a point of the picture with.
  var picksPoint: Bool { self == .base || self == .neutral || self == .shadowNeutral || self == .calibrate || self == .it8 || self == .dust }

  /// Each tool's SF Symbol. The two samplers differ in glyph and carry a label as well: the
  /// film base is the orange mask, the neutral a grey in the picture.
  var symbol: String {
    switch self {
    case .select: return "cursorarrow"
    case .crop: return "crop"
    case .region: return "camera.metering.matrix"
    case .base: return "eyedropper.full"
    case .neutral: return "eyedropper"
    case .shadowNeutral: return "eyedropper.halffull"
    case .calibrate: return "target"
    case .it8: return "squareshape.split.3x3"
    case .dust: return "aqi.medium"
    case .curve: return "scope"
    }
  }
  /// Shown next to the symbol in the toolbar.
  var label: String? {
    switch self {
    case .crop: return "画面"
    case .region: return "去色罩"
    case .base: return "片基"
    case .neutral: return "中性灰"
    default: return nil
    }
  }
  /// The colour each of the two crops is drawn in on the picture, and its key tinted with: the
  /// picture's crop amber, the de-masking region cyan.
  var colour: (red: Double, green: Double, blue: Double)? {
    switch self {
    case .crop: return (0.95, 0.71, 0.38)
    case .region: return (0.36, 0.84, 0.96)
    default: return nil
    }
  }
  /// The key that picks the tool while the canvas has focus, as in other image editors.
  var shortcut: String? {
    switch self {
    case .select: return "v"
    case .crop: return "c"
    case .region: return "m"
    case .base: return "b"
    case .neutral: return "n"
    case .shadowNeutral, .calibrate, .it8, .dust, .curve: return nil
    }
  }
  var help: String {
    let what: String
    switch self {
    case .select: what = "选择：点接触表上的画面进入单张；单张放大时拖动平移"
    case .crop: what = "画面裁切（琥珀色）：在接触表上拖出新画框；单张中裁切显示和导出的范围"
    case .region: what = "去色罩区域（青色）：在画面里框出算片基、白平衡和色阶用的地方，显示和导出不变"
    case .base: what = "取片基：点未曝光的橙色片基，作为去色罩的基准"
    case .neutral: what = "取中性灰：点画面中应为灰色的地方，校正白平衡"
    case .shadowNeutral: what = "阴影中性：点阴影里应为灰色的地方，设定阴影冷暖和阴影色调，亮处不变"
    case .calibrate: what = "标定中性点：点选灰卡等中性灰，生成这台扫描仪或这次翻拍的预设"
    case .it8: what = "IT8 色卡：按提示点色卡上的 6 个点"
    case .dust: what = "点选灰尘：在单张上点一处灰尘去掉它，点标出的圆圈改成留下或去掉"
    case .curve: what = "曲线目标调整：在单张上按住要调的地方上下拖，调它在曲线上的那一段"
    }
    return what + (shortcut.map { " · \($0.uppercased())" } ?? "")
  }
}
/// A roll's film format: how a scan's frames are found, and a copy's size on the film (the loupe's
/// field and the export's dpi), which the camera's pixels do not say.
enum FilmFormat: String, CaseIterable {
  case auto = "自动"
  case mm135 = "135"
  case medium = "120"
  case six45 = "120 · 6×4.5"
  case six6 = "120 · 6×6"
  case six7 = "120 · 6×7"
  case six9 = "120 · 6×9"
  /// The picture's short side on the film, in millimetres: 24 for 135, 56 for 120 whatever its
  /// length. Nil for 自动.
  var shortMM: Double? {
    switch self {
    case .auto: return nil
    case .mm135: return 24
    case .six45: return 41.5
    case .medium, .six6, .six7, .six9: return 56
    }
  }
  /// The picture's long side, where the format says it.
  var longMM: Double? {
    switch self {
    case .auto, .medium: return nil
    case .mm135: return 36
    case .six45, .six6: return 56
    case .six7: return 69.5
    case .six9: return 84
    }
  }
}

func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, x)) }

extension CGRect {
  var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
