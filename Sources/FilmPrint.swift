import AppKit

/// The print on a 135 cassette, stock by stock, laid out as photographs of the real cassettes show
/// it: each maker's families (Kodak Professional's dark shell with the yellow notes strip, the
/// consumer yellow, the black-and-white films' B&W band, Fujifilm's green, Fujichrome's printing
/// across, Ilford's white with the stock's colour, CineStill's sprocket rows, and so on), their
/// colours, where each line stands, how large and which way it reads. The words are set in the
/// Mac's own type in the weight the cassette's look like; no maker's logo or artwork is copied.
/// A stock none of the families has comes in its maker's colours (`generic`).
enum FilmPrint {
  /// The print laid flat as it wraps round: arc millimetres round from the front the camera looks
  /// at (+, towards the lip on the right), millimetres down from the shell's top end.
  struct Flat {
    let ctx: CGContext
    let size: CGSize
    let front: CGFloat
    var m: CGFloat { FilmRender.Label.mm }
    func x(_ s: CGFloat) -> CGFloat { front + s * m }
    func all(_ c: NSColor) {
      ctx.setFillColor(c.cgColor)
      ctx.fill(CGRect(origin: .zero, size: size))
    }
    /// A band round from `s0` to `s1`, from `y0` down to `y1`.
    func fill(_ c: NSColor, _ s0: CGFloat, _ s1: CGFloat, y0: CGFloat = 0, y1: CGFloat = 38) {
      ctx.setFillColor(c.cgColor)
      ctx.fill(CGRect(x: x(s0), y: y0 * m, width: (s1 - s0) * m, height: (y1 - y0) * m))
    }
    /// The same, its colour going from the first to the last round (or down, `down`).
    func shade(_ colours: [NSColor], _ s0: CGFloat, _ s1: CGFloat, y0: CGFloat = 0, y1: CGFloat = 38, down: Bool = false) {
      guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours.map(\.cgColor) as CFArray, locations: nil) else { return }
      let r = CGRect(x: x(s0), y: y0 * m, width: (s1 - s0) * m, height: (y1 - y0) * m)
      ctx.saveGState()
      ctx.clip(to: r)
      ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: down ? CGPoint(x: r.minX, y: r.maxY) : CGPoint(x: r.maxX, y: r.minY), options: [])
      ctx.restoreGState()
    }
    /// Words as they are set: runs in their own fonts and colours, made smaller to be no longer
    /// than `fit` millimetres; or, `stretch`, their letters widened (or narrowed) to be just as long,
    /// as the makers set their names.
    func runs(_ parts: [(String, NSFont, NSColor)], kern: CGFloat = 0, fit: CGFloat?, stretch: Bool = false, wide: CGFloat = 1, slant: CGFloat = 0) -> NSAttributedString {
      func make(_ k: CGFloat, wide: CGFloat = 1) -> NSAttributedString {
        let a = NSMutableAttributedString()
        for (s, f, c) in parts {
          let font = NSFont(descriptor: f.fontDescriptor, size: f.pointSize * k) ?? f
          a.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c, .kern: kern * m * k, .expansion: log(wide), .obliqueness: slant]))
        }
        return a
      }
      let a = make(1, wide: wide)
      if let fit, stretch { return make(1, wide: wide * fit * m / a.size().width) }
      if let fit, a.size().width > fit * m { return make(fit * m / a.size().width, wide: wide) }
      return a
    }
    /// A line set along the length, reading from the top end down (its letters' tops towards the
    /// lip), its middle `s` round, starting `top` mm down; reading up from `top` (`up`), the letters'
    /// tops away from the lip.
    func along(_ parts: [(String, NSFont, NSColor)], s: CGFloat, top: CGFloat, fit: CGFloat, kern: CGFloat = 0, up: Bool = false, stretch: Bool = false, wide: CGFloat = 1, slant: CGFloat = 0, outline: NSColor? = nil) {
      let a = runs(parts, kern: kern, fit: fit, stretch: stretch, wide: wide, slant: slant)
      let line = a.size()
      ctx.saveGState()
      ctx.translateBy(x: x(s), y: top * m)
      ctx.rotate(by: up ? -.pi / 2 : .pi / 2)
      let at = CGPoint(x: 0, y: -line.height / 2)
      if let outline { stroke(a, outline, at: at) }
      a.draw(at: at)
      ctx.restoreGState()
    }
    /// A line set across, its left end (or its middle, `centred`) `s` round, its top `y` mm down.
    func across(_ parts: [(String, NSFont, NSColor)], s: CGFloat, y: CGFloat, fit: CGFloat? = nil, centred: Bool = false, kern: CGFloat = 0, wide: CGFloat = 1) {
      let a = runs(parts, kern: kern, fit: fit, wide: wide)
      a.draw(at: CGPoint(x: x(s) - (centred ? a.size().width / 2 : 0), y: y * m))
    }
    /// The width a line takes, in millimetres.
    func width(_ parts: [(String, NSFont, NSColor)], kern: CGFloat = 0, fit: CGFloat? = nil) -> CGFloat { runs(parts, kern: kern, fit: fit).size().width / m }
    /// A dark edge round a line's letters, drawn under them.
    private func stroke(_ a: NSAttributedString, _ c: NSColor, at p: CGPoint) {
      let outlined = NSMutableAttributedString(attributedString: a)
      outlined.addAttributes([.strokeColor: c, .strokeWidth: 9, .foregroundColor: c], range: NSRange(location: 0, length: a.length))
      outlined.draw(at: p)
    }
    /// A box drawn round, `s` round from its left, `y` down from its top.
    func frame(_ c: NSColor, _ s0: CGFloat, _ s1: CGFloat, y0: CGFloat, y1: CGFloat, line: CGFloat = 0.25) {
      ctx.setStrokeColor(c.cgColor)
      ctx.setLineWidth(line * m)
      ctx.stroke(CGRect(x: x(s0), y: y0 * m, width: (s1 - s0) * m, height: (y1 - y0) * m))
    }
    /// The DX squares a camera reads, bare steel or painted in rows of six, and the bar code a
    /// lab's machine reads, round the back.
    func dx(_ look: NewProjectSheet.Look, ink: NSColor = NSColor(white: 0.07, alpha: 1)) {
      for row in 0..<2 {
        for col in 0..<6 {
          let bare = (row * 5 + col + (look.iso ?? 100) / 50) % 3 != 0
          fill(bare ? NSColor(white: 0.8, alpha: 1) : ink, -46 + CGFloat(row) * 2.6, -43.7 + CGFloat(row) * 2.6, y0: 19 + CGFloat(col) * 2.6, y1: 21.3 + CGFloat(col) * 2.6)
        }
      }
      fill(.white, -34, -26.5, y0: 4.5, y1: 28)
      var y: CGFloat = 5.3
      var seed = look.renderKey.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value } | 1
      while y < 27 {
        seed = seed &* 1103515245 &+ 12345
        let t = CGFloat((seed >> 16) % 3 + 1) * 0.28
        fill(.black, -33.2, -27.3, y0: y, y1: y + t)
        y += t + CGFloat((seed >> 20) % 2 + 1) * 0.3
      }
    }
  }

  // MARK: Type and colour

  static func font(_ name: String, _ mm: CGFloat) -> NSFont {
    let size = mm * FilmRender.Label.mm
    return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: .bold)
  }
  static func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
  static let kodakYellow = rgb(0xF2B21C)
  static let paper = rgb(0xF5F5F2)
  static let ink = rgb(0x141210)
  static let white = rgb(0xF6F6F4)
  static let fujiGreen = rgb(0x0E9A4E)
  /// Kodak's name with Professional after it, as its cassettes set them.
  static func kodakProfessional(_ mm: CGFloat, _ c: NSColor, maker: NSColor? = nil) -> [(String, NSFont, NSColor)] {
    [("Kodak", font("AvenirNext-Bold", mm), maker ?? c), (" Professional", font("AvenirNext-Regular", mm), c)]
  }
  /// FUJIFILM as Fujifilm sets it: a wide, even, half-bold capital.
  static func fujifilm(_ mm: CGFloat, _ c: NSColor) -> [(String, NSFont, NSColor)] { [("FUJIFILM", font("AvenirNext-DemiBold", mm), c)] }

  /// The process a lab reads, as the cassette prints it.
  static func process(_ look: NewProjectSheet.Look) -> String {
    switch look.kind ?? .colour {
    case .colour: return "C-41"
    case .slide: return look.mono ? "B&W" : "E-6"
    case .blackWhite: return "B&W"
    case .cine: return "ECN-2"
    }
  }

  // MARK: Which print

  /// A stock's print, drawn on a `Flat`.
  struct Design {
    var draw: (Flat, NewProjectSheet.Look) -> Void
  }
  /// A film none of the families is: its maker's colours, a band by the lip with the maker, the
  /// stock and what it is, its speed large, the kind's stripe with the process on the left.
  static func generic(_ look: NewProjectSheet.Look) -> Design {
    Design { f, look in
      let l = FilmRender.livery(look.maker)
      let (kindColour, process) = FilmRender.kindBand(look)
      f.all(l.ground)
      f.fill(l.band, 2.0, 6.8)
      func light(_ c: NSColor) -> Bool {
        let c = c.usingColorSpace(.sRGB) ?? c
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent > 0.5
      }
      let bandInk = light(l.band) ? (light(l.ground) ? ink : l.ground) : (light(l.ground) ? l.ground : white)
      f.along([(look.maker ?? "", font("AvenirNextCondensed-Heavy", 3.9), bandInk)], s: 4.4, top: 3, fit: 32, kern: 0.2)
      f.along([(look.name.uppercased(), font("AvenirNextCondensed-Bold", 5.4), l.ink)], s: -1.7, top: 3, fit: 32, kern: 0.15)
      f.along([(FilmRender.Label.description(look), font("AvenirNextCondensed-Medium", 2.3), l.ink)], s: -6.1, top: 4, fit: 30)
      if let iso = look.iso {
        f.along([("\(iso)", font("AvenirNextCondensed-Heavy", 8.4), l.ink)], s: -11.0, top: 15, fit: 19)
        f.along([("36 EXP", font("AvenirNextCondensed-DemiBold", 2.3), l.ink)], s: -8.6, top: 4, fit: 12)
      }
      f.fill(kindColour, -18.3, -15.8)
      f.along([(process, font("AvenirNextCondensed-Bold", 2.0), white)], s: -17.0, top: 4, fit: 14)
      f.dx(look)
    }
  }
  static func design(_ look: NewProjectSheet.Look) -> Design? {
    guard !look.calibrated, !look.named, let maker = look.maker else { return nil }
    let name = look.name, iso = look.iso ?? 100
    func has(_ s: String) -> Bool { name.localizedCaseInsensitiveContains(s) }
    switch maker {
    case "Kodak":
      if has("Portra") { return kodakPro("PORTRA \(iso)", ground: rgb(0x2B3033), light: true) }
      if has("Ektar") { return kodakPro("Ektar 100", ground: rgb(0x111111), light: true) }
      if has("Ektacolor") { return kodakPro("EKTACOLOR PRO \(iso)", ground: rgb(0x2A2C38), light: true) }
      if has("Pro Image") { return kodakPro("PRO IMAGE 100", ground: rgb(0x3A2A22), light: true) }
      if has("Vision3") { return kodakPro(name.replacingOccurrences(of: "Vision3", with: "VISION3"), ground: rgb(0x111111), light: false) }
      if has("Double-X") { return kodakPro("DOUBLE-X 5222", ground: rgb(0x111111), light: false) }
      if has("Gold") || has("UltraMax") || has("ColorPlus") || has("Kodacolor") { return kodakConsumer(iso) }
      if has("Ektachrome") { return kodakChrome }
      if has("Tri-X") { return kodakMono(name: "\(iso)TX", line: "TRI-X \(iso) FILM", field: kodakYellow, colour: rgb(0x23864A), triX: true) }
      if has("T-Max") { return kodakMono(name: iso == 3200 ? "P3200TMAX" : "\(iso)TMAX", line: iso == 3200 ? "T-MAX P3200 FILM" : "T-MAX \(iso) FILM", field: rgb(0xD5D7D8), colour: ink, triX: false) }
      if has("Ektapan") { return kodakMono(name: iso == 3200 ? "P3200 EKTAPAN" : "\(iso) EKTAPAN", line: "EKTAPAN \(iso) FILM", field: rgb(0xD5D7D8), colour: ink, triX: false) }
    case "Fujifilm":
      if name == "200" || name == "400" || has("Fujicolor 100") { return fujiPrint(iso) }
      if has("X-TRA") { return fujiSuperia("X-TRA \(iso)", band: "SUPERIA") }
      if has("C200") { return fujiSuperia("C200", band: "FUJICOLOR") }
      if has("400H") { return fujiSuperia("PRO 400H", band: "FUJICOLOR") }
      if has("Premium") { return fujiPremium(iso) }
      if has("Velvia") { return velvia(iso) }
      if has("Provia") { return provia }
      if has("Acros") { return acros }
    case "Ilford":
      if has("HP5") { return ilford("HP5", rgb(0x37A23C), "PLUS", iso) }
      if has("FP4") { return ilford("FP4", rgb(0x2D6DB5), "PLUS", iso) }
      if has("Pan F") { return ilford("PAN F", rgb(0xE2541E), "PLUS", iso) }
      if has("Delta") { return delta(iso, iso == 100 ? rgb(0x3FA2D8) : iso == 400 ? rgb(0x2E9A4C) : rgb(0x64399A)) }
      if has("XP2") { return ilford("XP2", rgb(0xD62B2B), "SUPER", iso, sub: "C41 PROCESS") }
      if has("SFX") { return ilford("SFX", rgb(0x8A1F33), "\(iso)", nil) }
      if has("Ortho") { return ilford("ORTHO", rgb(0x9C2A2A), "PLUS", iso) }
    case "Kentmere":
      return ilford("PAN", iso == 400 ? rgb(0x5A3B9B) : iso == 200 ? rgb(0x1F8F8A) : rgb(0x2E4BA6), "\(iso)", nil, maker: "KENTMERE")
    case "CineStill":
      if has("800T") { return cineStill("800T", rgb(0xDC2A2A), "color film for low light") }
      if has("400D") { return cineStill("400D", rgb(0x7650C5), "color film for daylight") }
      if has("50D") { return cineStill("50D", rgb(0x2A6ED6), "color film for daylight") }
      if has("XX") { return cineStill("XX", rgb(0x3A3B3E), "black & white film") }
    case "Lomography":
      if has("Color Negative") { return lomography("\(iso)", "COLOR PRINT FILM", ground: rgb(0x121212)) }
      if has("Purple") { return lomography("PURPLE", "LOMOCHROME", ground: rgb(0x5E2A86)) }
      if has("Turquoise") { return lomography("TURQUOISE", "LOMOCHROME", ground: rgb(0x178E92)) }
      if has("Metropolis") { return lomography("METROPOLIS", "LOMOCHROME", ground: rgb(0x55585C)) }
      if has("Classicolor") { return lomography("CLASSICOLOR", "LOMOCHROME", ground: rgb(0x8C3A2B)) }
      if has("Earl Grey") { return lomography("EARL GREY", "B&W \(iso)", ground: rgb(0x6B6E72)) }
      if has("Lady Grey") { return lomography("LADY GREY", "B&W \(iso)", ground: rgb(0x8A8C90)) }
      if has("Berlin") { return lomography("BERLIN KINO", "B&W \(iso)", ground: rgb(0x1A1A1A)) }
    case "Harman":
      if has("Phoenix II") { return phoenix("PHOENIX II", "ISO \(iso) C41 COLOUR FILM", rgb(0x2E63C9), rgb(0x173A8C)) }
      if has("Phoenix") { return phoenix("PHOENIX", "ISO \(iso) C41 COLOUR FILM", rgb(0xF0573A), rgb(0xB8241E)) }
      if has("Red") { return phoenix("RED", "ISO \(iso) C41 COLOUR FILM", rgb(0xD8262C), rgb(0x7E1016)) }
      if has("Azure") { return phoenix("SWITCH AZURE", "ISO \(iso) C41 COLOUR FILM", rgb(0x2AA7D8), rgb(0x156C9A)) }
    case "Foma":
      if has("Fomapan 100") { return fomapan("100", "CLASSIC", rgb(0xF5D624)) }
      if has("Fomapan 200") { return fomapan("200", "CREATIVE", rgb(0xF06A2A)) }
      if has("Fomapan 400") { return fomapan("400", "ACTION", rgb(0x8CCB3A)) }
      if has("R100") { return fomapan("R 100", "REVERSAL", rgb(0x7FB2E0)) }
      if has("Retropan") { return fomapan("320", "RETROPAN SOFT", rgb(0xC9A46A)) }
      if has("Ortho") { return fomapan("400", "ORTHO", rgb(0xE04A8A)) }
    case "Rollei":
      if has("Retro") { return rollei(name.uppercased(), ground: [rgb(0xB9BDC0), rgb(0xEEF0F1), rgb(0xC2C6C9)], ink: ink, colour: rgb(0xD9262B)) }
      if has("RPX") { return rollei(name.uppercased(), ground: [rgb(0x161616), rgb(0x2A2B2C), rgb(0x161616)], ink: white, colour: rgb(0xA9CF38)) }
      if has("Infrared") { return rollei("INFRARED \(iso)", ground: [rgb(0x161616), rgb(0x2A2B2C), rgb(0x161616)], ink: white, colour: rgb(0xD9262B)) }
      if has("Superpan") { return rollei("SUPERPAN \(iso)", ground: [rgb(0xB9BDC0), rgb(0xEEF0F1), rgb(0xC2C6C9)], ink: ink, colour: rgb(0x2D5DB5)) }
    case "ADOX":
      if has("Color Mission") { return adox("COLOR MISSION", "Farbnegativfilm • Color Negative Film", ground: rgb(0x1B8A8F)) }
      if has("Scala") { return adox("SCALA \(iso)", "Schwarzweiss-Umkehrfilm • B&W Reversal Film", ground: rgb(0x3B3D40)) }
      return adox(name.uppercased(), "Schwarzweissfilm • Black & White Film", ground: rgb(0xEC6A2C))
    case "AgfaPhoto":
      return agfaAPX(iso)
    case "ORWO":
      if let m = name.range(of: #"(NC|UN|N)\s?(\d+\+?)"#, options: .regularExpression) {
        let code = String(name[m]), letters = code.prefix { $0.isLetter }, digits = code.dropFirst(letters.count).trimmingCharacters(in: .whitespaces)
        return orwo(String(letters), digits, colour: look.kind != .blackWhite)
      }
    case "Lucky":
      return lucky(name.uppercased(), colour: look.kind != .blackWhite)
    case "Ferrania":
      let code = name.components(separatedBy: " ").first ?? name
      return ferrania(code.uppercased(), "\(code == "Orto" ? "ORTHO" : "PANCHRO") FILM \(iso) ASA")
    default: break
    }
    return nil
  }

  // MARK: Kodak

  /// Kodak Professional's colour films (Portra, Ektar): a dark shell; the yellow notes strip on
  /// the left under the process; the maker and Professional nearest the lip, the stock large in a
  /// light face, what it is under it, all in white reading down.
  static func kodakPro(_ title: String, ground: NSColor, light: Bool) -> Design {
    Design { f, look in
      f.all(ground)
      f.fill(kodakYellow, -16, -6.6, y0: 6.2)
      f.across([(process(look), font("AvenirNext-DemiBold", 3.3), white)], s: -11.3, y: 1.3, fit: 8, centred: true)
      f.along([("NOTES", font("AvenirNext-DemiBoldItalic", 1.9), rgb(0x5A3206))], s: -7.7, top: 7.4, fit: 8, kern: 0.15)
      f.along(kodakProfessional(3.6, white), s: 6.4, top: 6.6, fit: 27)
      let name = [(title, font(light ? "Avenir-Light" : "Avenir-Book", 7.6), white)]
      f.along(name, s: 1.3, top: 6.0, fit: 31)
      // Under the name, what it is: from the name's start in Portra's way; Ektar's, bold, to its end.
      let ektar = title.hasPrefix("Ektar")
      let what = [(FilmRender.Label.description(look), font(ektar ? "AvenirNext-DemiBold" : "AvenirNext-Regular", 3.0), white)]
      f.along(what, s: -3.5, top: ektar ? 6.0 + f.width(name, fit: 31) - f.width(what, fit: 21) : 7.0, fit: 21)
      f.dx(look)
    }
  }
  /// Kodak's consumer films (Gold, UltraMax, ColorPlus): Kodak yellow; the maker very large
  /// nearest the lip, the speed large beside it, two small lines; on the left a black strip with
  /// the speed and length in yellow.
  static func kodakConsumer(_ iso: Int) -> Design {
    let brown = rgb(0x1E150A)
    return Design { f, look in
      f.all(kodakYellow)
      f.along([("Kodak", font("AvenirNext-Heavy", 10.4), brown)], s: 4.8, top: 2.4, fit: 33.5, kern: -0.2)
      f.along([("\(iso)", font("AvenirNext-Bold", 11.6), brown)], s: -3.6, top: 8.5, fit: 19)
      f.along([("35mm color print film", font("AvenirNext-DemiBold", 2.5), brown)], s: -9.0, top: 8.6, fit: 26, kern: 0.22)
      f.along([("DX", font("AvenirNext-HeavyItalic", 2.6), brown)], s: -11.6, top: 8.6, fit: 5)
      f.along([("Kodak \(iso) • 36", font("AvenirNext-MediumItalic", 1.8), brown)], s: -11.0, top: 15, fit: 14)
      f.along([("PROCESS C-41", font("AvenirNext-MediumItalic", 1.8), brown)], s: -12.8, top: 15, fit: 14)
      f.fill(rgb(0x101010), -21.5, -14.6)
      f.along([("\(iso)", font("AvenirNext-HeavyItalic", 4.4), kodakYellow), ("  36", font("AvenirNext-HeavyItalic", 4.4), kodakYellow), ("exp.", font("AvenirNext-HeavyItalic", 2.6), kodakYellow)], s: -17.6, top: 9, fit: 26)
      f.dx(look)
    }
  }
  /// Ektachrome: royal blue; the yellow notes strip on the left under the process, a yellow strip
  /// by the lip with the maker; the stock very large in white, its name and what it is beside.
  static let kodakChrome = Design { f, look in
    let blue = rgb(0x1F5BB8)
    f.all(blue)
    f.fill(kodakYellow, -18, -10.4, y0: 6.2)
    f.fill(rgb(0x173F86), -18, -10.4, y1: 6.2)
    f.across([("E-6", font("AvenirNext-DemiBold", 3.3), white)], s: -14.0, y: 1.3, centred: true)
    f.along([("NOTES", font("AvenirNext-DemiBoldItalic", 1.9), rgb(0x173F86))], s: -11.4, top: 7.4, fit: 8, kern: 0.15)
    f.fill(kodakYellow, 3.4, 30)
    f.along(kodakProfessional(3.6, rgb(0x173F86), maker: rgb(0xD7261E)), s: 5.6, top: 6.4, fit: 28)
    f.along([("E100", font("AvenirNext-Bold", 10.6), white)], s: -1.8, top: 5.6, fit: 27, wide: 1.25)
    f.along([("EKTACHROME", font("AvenirNext-Bold", 2.7), white)], s: -6.9, top: 6.0, fit: 24, kern: 0.1)
    f.along([("Color Reversal Film", font("AvenirNext-Regular", 2.5), white)], s: -9.0, top: 6.0, fit: 24)
    f.dx(look)
  }
  /// Kodak's black-and-white films: a white band at the top with B&W; the stock large; its film's
  /// line and the maker by the lip; Tri-X on Kodak yellow in green, T-Max on silver in black.
  static func kodakMono(name: String, line: String, field: NSColor, colour: NSColor, triX: Bool) -> Design {
    Design { f, look in
      if triX {
        f.all(field)
      } else {
        f.all(field)
        f.shade([rgb(0xB8BBBD), rgb(0xE6E8E9), rgb(0xC9CCCE)], -10.6, 7.8)
        f.fill(kodakYellow, -18.5, -10.6)
      }
      f.fill(paper, 7.8, 22)
      f.fill(paper, -60, 30, y1: 4.6)
      f.across([("B&W", font("Georgia-Bold", 3.1), ink)], s: -1.5, y: 1.0, centred: true)
      // The stock in Kodak's wide capitals with their small serifs; T-Max's TMAX in heavy italics,
      // its T tall.
      let serif = "Copperplate-Bold", digits = String(name.prefix { $0.isNumber || $0 == "P" })
      let title: [(String, NSFont, NSColor)] = triX ? [(name, font(serif, 8.6), colour)]
        : [(digits, font(serif, 8.6), colour), (String(name.dropFirst(digits.count).prefix(1)), font("AvenirNext-HeavyItalic", 10.4), colour),
           (String(name.dropFirst(digits.count + 1)), font("AvenirNext-HeavyItalic", 7.2), colour)]
      f.along(title, s: -1.4, top: 5.4, fit: 28.5)
      f.along([(line, font(triX ? "HelveticaNeue-Bold" : "HelveticaNeue-Medium", 2.0), ink)], s: 3.2, top: 5.6, fit: 20, kern: triX ? 0.05 : 0.25)
      f.along(kodakProfessional(2.9, ink, maker: triX ? rgb(0xD7261E) : nil), s: 6.0, top: 6.0, fit: 22)
      f.along([("BLACK & WHITE NEGATIVE FILM", font(triX ? "HelveticaNeue-Bold" : "HelveticaNeue-Medium", 2.3), ink)], s: -6.4, top: 5.8, fit: 27)
      f.along([("NOTES", font(triX ? "HelveticaNeue-Bold" : "HelveticaNeue", 1.8), ink)], s: triX ? -9.4 : -11.8, top: 6.0, fit: 8, kern: 0.15)
      if triX {
        let big = font(serif, 5.4)
        f.along([("\(look.iso ?? 400)", big, colour)], s: -10.0, top: 26.6, fit: 10)
        f.along([("\(look.iso ?? 400)", big, colour)], s: -14.2, top: 26.6, fit: 10)
        f.along([("\(name)•36", font("HelveticaNeue-Bold", 1.5), ink)], s: -16.4, top: 26.6, fit: 8)
        f.fill(paper, -23, -17.4)
        f.along([(name, font(serif, 4.6), colour)], s: -19.6, top: 4.6, fit: 20)
      }
      f.dx(look)
    }
  }

  // MARK: Fujifilm

  /// Fujifilm 200 and 400 (and the Fujicolor sold in Japan): white; a green band by the lip with
  /// the maker in white; the speed large in black; a black strip on the left.
  static func fujiPrint(_ iso: Int) -> Design {
    Design { f, look in
      f.all(paper)
      // A bright green from the middle on, paler where it meets the white.
      let green = rgb(0x3BB54A)
      f.fill(green, 0.6, 30)
      f.shade([rgb(0xA8DA8E), green], -1.0, 0.6)
      f.along(fujifilm(5.0, white), s: 4.6, top: 4.0, fit: 30, kern: 0.3, wide: 1.18)
      f.along([("\(iso)", font("AvenirNext-DemiBoldItalic", 5.8), ink)], s: -4.0, top: 11.0, fit: 12)
      f.fill(rgb(0x141414), -9.6, -7.0, y0: 3.2, y1: 34.8)
      f.along([("FILM FOR COLOR PRINTS", font("AvenirNext-DemiBold", 1.9), white)], s: -8.3, top: 6.2, fit: 26, kern: 0.12)
      f.along([("CH-36   \(iso)   PROCESS C-41", font("AvenirNext-Medium", 1.7), ink)], s: -11.6, top: 8.0, fit: 24)
      f.across([("DX", font("AvenirNext-HeavyItalic", 2.4), ink)], s: -15.0, y: 3.0, centred: true)
      f.dx(look)
    }
  }
  /// Superia X-TRA, C200 and Pro 400H: white on the left with the length large; a green field
  /// with the stock in heavy italics and the range's name in white by the lip.
  static func fujiSuperia(_ title: String, band: String) -> Design {
    Design { f, look in
      f.all(paper)
      f.shade([rgb(0x9ADB86), rgb(0x3EBB3C), rgb(0x179A3A)], -6.6, 3.4)
      f.fill(rgb(0x139A3C), 3.4, 22)
      f.along([(band, font("AvenirNext-DemiBold", 4.4), white)], s: 5.4, top: 4.0, fit: 30, kern: 0.3, wide: 1.12)
      f.along([(title, font("HelveticaNeue-BoldItalic", 7.6), ink)], s: -0.6, top: 6.0, fit: 29)
      f.along([("FILM FOR COLOR PRINTS", font("HelveticaNeue-Bold", 2.0), ink)], s: -5.4, top: 6.4, fit: 24)
      f.across([("36", font("HelveticaNeue-Bold", 6.4), ink)], s: -13.2, y: 2.4, centred: true)
      f.across([("CH135", font("HelveticaNeue-Bold", 1.9), ink)], s: -13.2, y: 9.2, centred: true)
      f.along(fujifilm(2.8, fujiGreen), s: -9.2, top: 14, fit: 18, kern: 0.2, wide: 1.15)
      f.along([("PROCESS CN-16 · C-41", font("HelveticaNeue-Medium", 1.6), ink)], s: -11.4, top: 14, fit: 18)
      f.dx(look)
    }
  }
  /// Superia Premium: purple above with the range's name, the speed in purple on white, green
  /// below with the maker; printed across.
  static func fujiPremium(_ iso: Int) -> Design {
    let purple = rgb(0x6C2A7E)
    return Design { f, look in
      f.all(paper)
      f.fill(purple, -60, 30, y1: 15.5)
      f.fill(fujiGreen, -60, 30, y0: 28.5)
      f.across([("SUPERIA", font("HelveticaNeue-Italic", 2.8), white)], s: -7, y: 4.2, fit: 12)
      f.across([("PREMIUM", font("HelveticaNeue-Bold", 4.8), white)], s: -9.4, y: 7.6, fit: 14.6)
      f.across([("\(iso)", font("Didot-Bold", 9.4), purple)], s: -2.4, y: 16.4, fit: 13, centred: true)
      f.across(fujifilm(3.2, white), s: -9.4, y: 29.6, fit: 14, kern: 0.2, wide: 1.15)
      f.across([("FUJICOLOR  ·  FILM FOR COLOR PRINTS", font("HelveticaNeue-Bold", 1.7), white)], s: -9.4, y: 34, fit: 14.6)
      f.fill(paper, -21, -11)
      f.across([("36", font("HelveticaNeue-Bold", 5.6), ink)], s: -15.4, y: 2.0, centred: true)
      f.dx(look)
    }
  }
  /// Fujichrome as it is printed, across: the green shell, the maker, FUJICHROME and the speed's
  /// box; Velvia's name large on a white band below.
  static func velvia(_ iso: Int) -> Design {
    let green = rgb(0x17955A)
    return Design { f, look in
      f.all(green)
      f.fill(paper, -60, 30, y0: 28.6)
      f.fill(paper, -21, -11.2)
      f.fill(rgb(0x4A5FC0), -14.6, -11.2, y0: 12, y1: 22)
      f.along([("36", font("HelveticaNeue-Bold", 5.2), ink)], s: -17.2, top: 2.0, fit: 8)
      let l: CGFloat = -9.8
      f.across(fujifilm(2.7, white), s: l, y: 3.0, fit: 14, kern: 0.15, wide: 1.15)
      f.across([("COLOR REVERSAL FILM", font("HelveticaNeue-Medium", 1.4), white)], s: l + 3, y: 7.0, fit: 12)
      f.across([("FUJICHROME", font("HelveticaNeue-CondensedBlack", 4.6), white)], s: l, y: 9.2, fit: 15.4)
      f.across([("FOR PROFESSIONALS", font("HelveticaNeue-Medium", 1.5), white)], s: l, y: 14.6, fit: 14)
      let speed = [("ISO \(iso)/\(iso == 100 ? 21 : 18)°", font("HelveticaNeue-Bold", 2.3), white)]
      f.across(speed, s: l + 0.9, y: 17.5)
      f.frame(white, l, l + 1.8 + f.width(speed), y0: 17.3, y1: 20.6)
      f.across([("DAYLIGHT", font("HelveticaNeue-Medium", 1.6), white)], s: l, y: 21.6)
      f.across([("PROCESS ", font("HelveticaNeue-Medium", 1.6), white), ("CR-56 · E-6", font("HelveticaNeue-Bold", 1.6), white)], s: l, y: 24.1, fit: 14)
      f.across([("Velvia", font("HelveticaNeue-CondensedBold", 8.6), ink), (" \(iso)", font("HelveticaNeue-CondensedBold", 4.8), ink)], s: l - 0.4, y: 28.6, fit: 16)
      f.dx(look)
    }
  }
  /// Provia: a green band above with FUJICHROME, blue with the stock large in white, green below
  /// with the maker; the length large on white on the left.
  static let provia = Design { f, look in
    let blue = rgb(0x26388F), green = rgb(0x1A9150)
    f.all(blue)
    f.shade([rgb(0x2D47A8), blue, rgb(0x182565)], -11.2, 22, y0: 6.6, y1: 30.5, down: true)
    f.fill(green, -60, 30, y1: 6.6)
    f.fill(green, -60, 30, y0: 30.5)
    f.fill(paper, -21, -11.2)
    f.across([("36", font("HelveticaNeue-Bold", 6.2), ink)], s: -16.1, y: 1.8, centred: true)
    f.along([("RDP III  135", font("HelveticaNeue-Bold", 1.8), ink)], s: -13.0, top: 10, fit: 14)
    let l: CGFloat = -9.6
    f.across([("FUJICHROME", font("HelveticaNeue-Bold", 3.2), white)], s: l, y: 1.7, fit: 15)
    f.across([("PROVIA", font("HelveticaNeue-Medium", 6.0), white)], s: l, y: 7.4, fit: 15.4)
    f.across([("100", font("HelveticaNeue-Medium", 6.0), white), ("F", font("HelveticaNeue-MediumItalic", 6.0), white)], s: l, y: 13.6, fit: 15)
    f.across([("DAYLIGHT", font("HelveticaNeue-Medium", 1.8), white)], s: l, y: 21.0)
    f.across([("COLOR REVERSAL FILM", font("HelveticaNeue-Medium", 1.5), white)], s: l, y: 23.4, fit: 14)
    f.across([("PROCESS ", font("HelveticaNeue-Medium", 1.5), white), ("CR-56 / E-6", font("HelveticaNeue-Bold", 1.5), white)], s: l, y: 25.4, fit: 14)
    f.across([("Professional", font("HelveticaNeue-Italic", 2.2), white)], s: l, y: 27.6, fit: 14)
    f.across(fujifilm(3.4, white), s: l + 0.6, y: 32.4, fit: 14, kern: 0.15, wide: 1.15)
    f.dx(look)
  }
  /// Acros II: green above with the maker, NEOPAN and the speed large; silver below with ACROS II.
  static let acros = Design { f, look in
    let green = rgb(0x2E9A4C)
    f.all(green)
    f.shade([rgb(0xC9CBCC), rgb(0xEDEEEE), rgb(0xBFC1C3)], -60, 30, y0: 22.4)
    f.fill(paper, -21, -11.2)
    f.across([("36", font("HelveticaNeue-Bold", 6.2), ink)], s: -16.1, y: 1.8, centred: true)
    let l: CGFloat = -9.6
    f.across(fujifilm(2.9, white), s: l, y: 2.6, fit: 14, kern: 0.15, wide: 1.15)
    f.across([("NEOPAN", font("HelveticaNeue-Medium", 3.4), white)], s: l, y: 6.6, fit: 14)
    f.across([("100", font("HelveticaNeue-Medium", 8.0), white), (" B/W", font("HelveticaNeue-Bold", 2.0), white)], s: l, y: 10.6, fit: 15.4)
    f.across([("ACROS", font("HelveticaNeue-CondensedBlack", 6.0), ink), (" II", font("HelveticaNeue-CondensedBlack", 6.0), ink)], s: l, y: 24.0, fit: 15)
    f.across([("BLACK & WHITE NEGATIVE FILM", font("HelveticaNeue-Medium", 1.5), ink)], s: l, y: 32.6, fit: 14.5)
    f.dx(look)
  }

  // MARK: Ilford, Kentmere

  /// Ilford's films (Kentmere's the same way): white; reading up, the maker in heavy black, the
  /// stock very large in its own colour, then its PLUS (or speed) by a black bar, the speed and
  /// what it is.
  static func ilford(_ word: String, _ colour: NSColor, _ third: String, _ iso: Int?, sub: String? = nil, maker: String = "ILFORD") -> Design {
    Design { f, look in
      f.all(paper)
      let heavy = "HelveticaNeue-CondensedBlack"
      // The heavy words lean, as Ilford sets them.
      f.along([(maker, font(heavy, 4.6), maker == "ILFORD" ? ink : colour)], s: -12.0, top: 32.6, fit: 25.5, up: true, stretch: true, slant: 0.16)
      f.along([(word, font(heavy, 12.4), colour)], s: -5.0, top: 32.6, fit: 25.5, up: true, stretch: true, slant: 0.16)
      let t = [(third, font(heavy, 6.0), ink)]
      f.along(t, s: 2.4, top: 32.6, fit: 13, up: true, slant: 0.16)
      let used = min(13, f.width(t))
      f.fill(ink, 0.3, 4.5, y0: 6.8, y1: 31.6 - used)
      if let iso { f.along([("\(iso)", font("HelveticaNeue-CondensedBold", 3.6), ink)], s: 6.0, top: 32.6, fit: 8, up: true) }
      f.along([(sub ?? "BLACK & WHITE FILM", font("HelveticaNeue-Medium", 1.9), ink)], s: 8.8, top: 32.6, fit: 25, up: true)
      if sub != nil { f.along([("BLACK & WHITE FILM", font("HelveticaNeue-Medium", 1.9), ink)], s: 10.8, top: 32.6, fit: 25, up: true) }
      f.fill(ink, -60, 30, y0: 36.6)
      f.dx(look)
    }
  }

  /// Delta Professional, as its cassettes are printed (100 sky blue, 400 green, 3200 violet): white,
  /// a band of the stock's colour round the back to well before the front, with the speeds to rate
  /// it at in a white table and the length and rated speed in white on it;
  /// reading up and upright, not leaning as HP5's, the length and the speed in small type, ILFORD
  /// very large in black, DELTA as large in the stock's colour cut by fine white lines across, the
  /// speed in black as large again, and PROFESSIONAL in the colour by the lip.
  static func delta(_ iso: Int, _ colour: NSColor) -> Design {
    // Measured off a photograph of the Delta 3200 cassette, in millimetres round from the front and
    // down from the top end.
    Design { f, look in
      f.all(paper)
      let heavy = "HelveticaNeue-CondensedBlack", round = "AvenirNext-Heavy"
      let pale = colour.blended(withFraction: 0.3, of: .white) ?? colour
      // The band round the back, the whole height, to 8 mm before the front.
      f.fill(colour, -60, -8.0)
      // On it, by the back, the speeds to rate it at in a white table: a line down it and three
      // across, 1600, 3200 and 6400 reading up (half, as and twice the speed).
      f.fill(paper, -17.5, -12.3, y0: 4.0, y1: 31.2)
      let grey = NSColor(white: 0.6, alpha: 1), table = NSColor(white: 0.3, alpha: 1)
      f.fill(grey, -13.8, -13.65, y0: 4.0, y1: 31.2)
      for y in [9.8, 16.0, 24.6] as [CGFloat] { f.fill(grey, -17.5, -12.3, y0: y, y1: y + 0.15) }
      for (speed, foot) in [(iso * 2, 15.6), (iso, 24.2), (iso / 2, 30.8)] as [(Int, CGFloat)] {
        f.along([("\(speed)", font("HelveticaNeue", 1.7), table)], s: -13.05, top: foot, fit: 5.6, up: true)
      }
      // Beside it in white on the band: the length, bold, and the speed it is rated at along the
      // length (3200 is rated, not its box speed: EI, as its cassette says; the others ISO).
      let din = 1 + Int((10 * log10(Double(max(iso, 1)))).rounded())
      f.along([("36", font("HelveticaNeue-Bold", 2.4), white)], s: -10.8, top: 16.2, fit: 2.4, up: true)
      f.along([("\(iso >= 3200 ? "EI" : "ISO") \(iso)/\(din)° ", font("HelveticaNeue", 2.1), white), ("DELTA", font("HelveticaNeue-Bold", 2.1), white),
        (" 36 EXP", font("HelveticaNeue", 2.1), white)], s: -9.1, top: 31.0, fit: 25.4, up: true)
      // DELTA, in fine stripes along its length (the way it reads), as the stock's name is printed:
      // thick stripes, narrow gaps, so it stands out from the Δ's thin lines.
      let pitch: CGFloat = 0.48
      f.along([("DELTA", font(round, 9.2), colour)], s: 4.6, top: 34.2, fit: 26.9, up: true, stretch: true)
      var cut: CGFloat = 0
      while cut < 8.4 {
        f.fill(paper, cut + 0.37, cut + pitch, y0: 6.5, y1: 34.8)
        cut += pitch
      }
      // The Δ it stands in: its point a little past ILFORD on the far side, a little above the
      // middle of the length, its base by PROFESSIONAL from 6.8 to 32.7 mm down; drawn in thin lines
      // on the name's stripes (inside a letter a line lies within its stripe, so the letters stay as
      // they are and the lines show between and past them, and between ILFORD's letters).
      let apex = CGPoint(x: -7.5, y: 18.6), base: CGFloat = 13.3, baseTop: CGFloat = 6.8, baseFoot: CGFloat = 32.7
      var k = (apex.x / pitch).rounded(.down)
      while k * pitch < base {
        let s0 = k * pitch + 0.1
        if s0 > apex.x {
          let t = (s0 - apex.x) / (base - apex.x)
          f.fill(colour, s0, s0 + 0.17, y0: apex.y + (baseTop - apex.y) * t, y1: apex.y + (baseFoot - apex.y) * t)
        }
        k += 1
      }
      // ILFORD very large over the Δ's point; the speed in a round heavy face, as long as it is on the
      // cassette, centred on the middle and close past DELTA; PROFESSIONAL by the lip in a paler colour.
      f.along([("ILFORD", font(heavy, 9.3), ink)], s: -2.6, top: 33.9, fit: 26.6, up: true, stretch: true)
      let long: CGFloat = iso >= 1000 ? 20.7 : 15.6
      f.along([("\(iso)", font(round, 7.8), ink)], s: 10.6, top: 20.55 + long / 2, fit: long, up: true, stretch: true)
      f.along([("PROFESSIONAL", font("AvenirNext-Bold", 2.6), pale)], s: 15.0, top: 32.7, fit: 25.9, kern: 0.2, up: true, stretch: true)
      f.fill(ink, -60, 30, y0: 36.6)
      f.dx(look)
    }
  }

  // MARK: Rollei, ADOX, AgfaPhoto, ORWO

  /// Rollei: reading up, the brand large in rounded bold, the stock in its colour, what it is; RPX
  /// on black, Retro on silver.
  static func rollei(_ title: String, ground: [NSColor], ink: NSColor, colour: NSColor) -> Design {
    Design { f, look in
      f.shade(ground, -60, 30)
      f.fill(paper, -21, -15.4)
      f.along([("Rollei", font("ArialRoundedMTBold", 7.4), ink)], s: -7.6, top: 32.0, fit: 22, up: true)
      f.along([(title, font("AvenirNext-Bold", 6.0), colour)], s: -0.6, top: 32.0, fit: 25, up: true)
      f.along([("BLACK & WHITE FILM", font("AvenirNext-DemiBold", 1.9), ink)], s: 3.8, top: 32.0, fit: 22, kern: 0.2, up: true)
      f.along([("135 · 36 EXP.", font("AvenirNext-Medium", 1.7), ink)], s: 6.2, top: 32.0, fit: 14, up: true)
      f.dx(look)
    }
  }
  /// ADOX: orange with fine blue and white lines down it; the brand in white in its oval, reading
  /// up; the stock in heavy black on a white band; the length at the top, the speed at the foot.
  static func adox(_ title: String, _ line: String, ground: NSColor) -> Design {
    Design { f, look in
      f.all(ground)
      f.fill(rgb(0x2B4FA8), -13.4, -12.9)
      f.fill(paper, -12.4, -12.0)
      f.fill(rgb(0x2B4FA8), 6.4, 6.9)
      f.fill(rgb(0xF3A51F), 7.4, 30)
      f.across([("36", font("AvenirNext-Bold", 3.4), ink)], s: -10.6, y: 2.0)
      f.across([("135", font("AvenirNext-DemiBold", 1.8), ink)], s: -10.6, y: 5.8)
      f.along([("ISO \(look.iso ?? 100)/\(look.iso.map { 10 + Int((10 * log10(Double($0))).rounded()) } ?? 21)°", font("AvenirNext-DemiBold", 2.0), ink)], s: -10.0, top: 35.0, fit: 12, up: true)
      // The brand in its oval.
      let brand = [("ADOX", font("AvenirNext-Heavy", 4.6), white)]
      let long = f.width(brand, kern: 0.3)
      f.along(brand, s: -6.0, top: 26.6, fit: 16, kern: 0.3, up: true)
      f.ctx.setStrokeColor(white.cgColor)
      f.ctx.setLineWidth(0.35 * f.m)
      f.ctx.strokeEllipse(in: CGRect(x: f.x(-8.9), y: (26.6 - long - 1.6) * f.m, width: 5.8 * f.m, height: (long + 3.2) * f.m))
      f.fill(paper, -2.6, 4.2)
      f.along([(title, font("HelveticaNeue-CondensedBlack", 5.6), ink)], s: 0.8, top: 34.0, fit: 27, up: true)
      f.along([(line, font("AvenirNext-DemiBold", 1.6), ink)], s: 5.3, top: 34.0, fit: 27, up: true)
      f.dx(look)
    }
  }
  /// AgfaPhoto's APX: silver, the name very large in pale embossed capitals reading up, PROFESSIONAL
  /// beside, the brand with its red dot at the foot; the speed in white on a dark band by the lip.
  static func agfaAPX(_ iso: Int) -> Design {
    Design { f, look in
      f.shade([rgb(0xAEB3B6), rgb(0xE9ECED), rgb(0xBFC3C6)], -60, 30)
      f.along([("APX", font("HelveticaNeue-Bold", 12.0), rgb(0xDADDDE))], s: -1.6, top: 33.0, fit: 24, up: true, stretch: true, outline: rgb(0x55595C))
      f.along([("APX", font("HelveticaNeue-Bold", 12.0), rgb(0xE8EAEB))], s: -1.6, top: 33.0, fit: 24, up: true, stretch: true)
      f.along([("PROFESSIONAL", font("AvenirNext-DemiBold", 2.0), rgb(0x333638))], s: 4.6, top: 33.0, fit: 22, kern: 0.45, up: true)
      f.along([("For black and white prints", font("AvenirNext-Regular", 1.6), rgb(0x333638))], s: -9.4, top: 33.0, fit: 20, up: true)
      f.ctx.setFillColor(rgb(0xD8262B).cgColor)
      f.ctx.fillEllipse(in: CGRect(x: f.x(-6.6), y: 34.0 * f.m, width: 1.8 * f.m, height: 1.8 * f.m))
      f.along([("AGFA", font("AvenirNext-Bold", 2.2), rgb(0x333638)), ("PHOTO", font("AvenirNext-Regular", 2.2), rgb(0x333638))], s: -5.7, top: 33.4, fit: 14, up: true)
      f.fill(rgb(0x2A2C2E), 6.2, 30)
      f.along([("\(iso)", font("AvenirNext-Bold", 4.2), white)], s: 8.2, top: 11.0, fit: 9, up: true)
      f.along([("135·36", font("AvenirNext-DemiBold", 2.0), white)], s: 8.2, top: 33.0, fit: 9, up: true)
      f.across([("DX", font("AvenirNext-HeavyItalic", 2.4), white)], s: 8.2, y: 1.6, centred: true)
      f.dx(look)
    }
  }
  /// ORWO's Wolfen films, printed across as their boxes are: white; the code and the speed large in
  /// black; WOLFEN over COLOR in coloured letters (or B&W); a pale blue band at the foot.
  static func orwo(_ letters: String, _ speed: String, colour: Bool) -> Design {
    Design { f, look in
      f.all(paper)
      f.fill(colour ? rgb(0x7FC2E8) : rgb(0xB9BEC2), -60, 30, y0: 29.0)
      let l: CGFloat = -10.0
      f.across([(letters, font("HelveticaNeue-CondensedBlack", 7.4), ink)], s: l, y: 3.0, fit: 7)
      f.across([(speed, font("HelveticaNeue-CondensedBlack", 6.6), ink)], s: l, y: 11.6, fit: 7)
      f.across([("ORIGINAL", font("AvenirNext-DemiBold", 1.3), ink)], s: l + 7.4, y: 4.0)
      f.across([("WOLFEN", font("AvenirNext-Heavy", 2.4), ink)], s: l + 7.4, y: 5.6, fit: 9)
      let word: [(String, NSFont, NSColor)] = colour
        ? zip("COLOR", [rgb(0xF2C300), rgb(0xD8262C), rgb(0x2F9E44), rgb(0x2B5DB8), ink]).map { (String($0), font("HelveticaNeue-CondensedBlack", 7.0), $1) }
        : [("B&W", font("HelveticaNeue-CondensedBlack", 7.0), ink)]
      f.across(word, s: l + 7.4, y: 8.2, fit: 9.6)
      f.across([("135-36", font("AvenirNext-Bold", 2.8), white), ("  " + (colour ? "Color Negative Film" : "B&W Negative Film"), font("AvenirNext-DemiBold", 1.6), white)], s: l, y: 30.2, fit: 16)
      f.across([(letters + speed, font("HelveticaNeue-CondensedBlack", 2.8), rgb(0x173F86))], s: l, y: 34.0, fit: 10)
      f.dx(look)
    }
  }

  /// Lucky (乐凯): white, printed across; a red band down the left with the length in white, thin
  /// yellow and green lines beside it; the brand in red, what it is in Chinese, the process.
  static func lucky(_ title: String, colour: Bool) -> Design {
    let red = rgb(0xD8232A)
    return Design { f, look in
      f.all(paper)
      f.fill(red, -21, -6.4)
      f.fill(rgb(0xF2C21B), -6.4, -5.9)
      f.fill(rgb(0x2F9E44), -5.9, -5.4)
      f.across([("DX", font("AvenirNext-HeavyItalic", 2.2), white)], s: -12.8, y: 18.0)
      f.across([("135-", font("AvenirNext-DemiBold", 2.0), white)], s: -12.8, y: 21.6)
      f.across([("36", font("AvenirNext-Bold", 4.4), white)], s: -12.8, y: 24.2, fit: 6)
      let l: CGFloat = -3.8
      f.across([("乐凯", font("PingFangSC-Semibold", 5.0), red)], s: l, y: 3.2, fit: 12)
      f.across([("LUCKY", font("AvenirNext-Heavy", 2.4), red)], s: l, y: 10.4, kern: 0.3)
      f.across([(colour ? "彩色胶卷" : "黑白胶卷", font("PingFangSC-Medium", 3.0), ink)], s: l, y: 14.6, fit: 12)
      f.across([("Process " + (colour ? "C-41" : "B&W"), font("AvenirNext-Medium", 1.7), ink)], s: l, y: 19.4, fit: 12)
      f.across([(title, font("AvenirNext-Bold", 3.6), ink)], s: l, y: 23.0, fit: 12)
      f.across([("ISO \(look.iso ?? 200)", font("AvenirNext-DemiBold", 2.0), ink)], s: l, y: 28.0, fit: 12)
      f.dx(look)
    }
  }
  /// Ferrania's films: black with two fine white lines down it; Ferrania in heavy white reading
  /// down, made in Italy, the stock and what it is.
  static func ferrania(_ code: String, _ line: String) -> Design {
    Design { f, look in
      f.all(rgb(0x121212))
      f.fill(white, -9.6, -9.3)
      f.fill(white, 6.2, 6.5)
      f.along([("Ferrania", font("AvenirNext-Heavy", 6.4), white)], s: 1.8, top: 5.0, fit: 28)
      f.along([("MADE IN ITALY", font("AvenirNext-DemiBold", 1.7), white)], s: -2.4, top: 17.0, fit: 16, kern: 0.35)
      f.along([(code, font("AvenirNext-Heavy", 5.4), white)], s: -6.0, top: 5.0, fit: 12)
      f.along([(line, font("AvenirNext-DemiBold", 1.7), white)], s: -6.6, top: 17.6, fit: 16)
      f.along([("www.filmferrania.it", font("AvenirNext-Regular", 1.5), white)], s: 4.6, top: 5.0, fit: 16)
      f.dx(look)
    }
  }

  // MARK: Others

  /// CineStill: its colour all round, rows of black squares along both ends like a film's
  /// perforations, the name and the stock large across in white, a black strip on the left with
  /// the push marks.
  static func cineStill(_ stock: String, _ ground: NSColor, _ line: String) -> Design {
    Design { f, look in
      f.all(ground)
      var s: CGFloat = -60
      while s < 30 {
        f.fill(ink, s, s + 1.6, y0: 0.9, y1: 2.9)
        f.fill(ink, s, s + 1.6, y0: 35.1, y1: 37.1)
        s += 3.0
      }
      f.fill(ink, -21, -12.6, y0: 4.6, y1: 33.4)
      f.along([("PUSH  □ +1  □ +2  □ +3", font("HelveticaNeue-Bold", 1.9), white)], s: -15.0, top: 7, fit: 24)
      f.along([("\(stock) · C-41 · \(line)", font("HelveticaNeue-Medium", 1.6), white)], s: -17.6, top: 7, fit: 24)
      let l: CGFloat = -10.8
      f.across([("Cine", font("ArialRoundedMTBold", 8.0), white)], s: l, y: 6.0)
      f.across([("Still", font("ArialRoundedMTBold", 8.0), white), (" film", font("ArialRoundedMTBold", 2.4), white)], s: l + 1.0, y: 13.6, fit: 15.6)
      f.across([(stock, font("ArialRoundedMTBold", 6.0), white)], s: l, y: 22.6, fit: 14)
      f.across([(line, font("AvenirNext-Italic", 2.0), white)], s: l, y: 30.0, fit: 15)
      f.dx(look)
    }
  }
  /// Lomography: black (or the film's colour); the speed or the name very large in white reading
  /// down, what it is beside, a white strip by the lip with the brand in red.
  static func lomography(_ title: String, _ line: String, ground: NSColor) -> Design {
    Design { f, look in
      f.all(ground)
      f.fill(paper, 3.4, 22)
      f.along([("lomography", font("AvenirNext-HeavyItalic", 3.4), rgb(0xE0262B))], s: 5.6, top: 6, fit: 26)
      f.along([(title, font("HelveticaNeue-CondensedBlack", 11.0), white)], s: -2.6, top: 4.6, fit: 29)
      f.along([(line, font("HelveticaNeue-CondensedBold", 2.9), white)], s: -8.6, top: 5.6, fit: 27)
      f.along([("35MM · 36 EXP", font("HelveticaNeue-Medium", 1.8), white)], s: -11.0, top: 5.6, fit: 20)
      f.dx(look)
    }
  }
  /// Harman's colour films: the colour shading darker towards the foot, its feathers in a darker
  /// tone, the name large across in white, the speed and process under it, the maker in a dark
  /// band at the foot.
  static func phoenix(_ title: String, _ line: String, _ light: NSColor, _ dark: NSColor) -> Design {
    Design { f, look in
      f.shade([light, dark], -60, 30, y0: 0, y1: 33, down: true)
      f.fill(dark.blended(withFraction: 0.45, of: .black) ?? dark, -60, 30, y0: 33)
      // The feathers: long leaves fanning from the foot.
      f.ctx.saveGState()
      f.ctx.setFillColor((dark.blended(withFraction: 0.2, of: .black) ?? dark).withAlphaComponent(0.55).cgColor)
      for k in 0..<9 {
        let root = CGPoint(x: f.x(-10 + CGFloat(k) * 3.6), y: 33 * f.m)
        let tip = CGPoint(x: f.x(-18 + CGFloat(k) * 4.4), y: (4 + CGFloat(k % 3) * 3) * f.m)
        let p = CGMutablePath()
        p.move(to: root)
        p.addQuadCurve(to: tip, control: CGPoint(x: root.x - 4 * f.m, y: (root.y + tip.y) / 2))
        p.addQuadCurve(to: root, control: CGPoint(x: tip.x + 5 * f.m, y: (root.y + tip.y) / 2))
        f.ctx.addPath(p)
      }
      f.ctx.fillPath()
      f.ctx.restoreGState()
      f.across([(title, font("HelveticaNeue-CondensedBlack", 6.6), white)], s: -2.4, y: 12.0, fit: 15, centred: true, kern: 0.15)
      f.across([(line, font("HelveticaNeue-Bold", 1.7), white)], s: -2.4, y: 19.6, fit: 14, centred: true)
      f.across([("HARMAN", font("HelveticaNeue-CondensedBlack", 2.6), white), (" photo", font("HelveticaNeue-Light", 2.6), white)], s: -2.4, y: 34.2, fit: 13, centred: true)
      f.dx(look)
    }
  }
  /// Fomapan: navy; the name large in white reading down; the speed and length on a patch in the
  /// film's own colour.
  static func fomapan(_ speed: String, _ word: String, _ patch: NSColor) -> Design {
    let navy = rgb(0x1E3272)
    return Design { f, look in
      f.all(navy)
      f.fill(patch, -9.2, -2.6, y0: 4, y1: 17)
      f.along([("\(speed)/36", font("HelveticaNeue-CondensedBlack", 3.6), ink)], s: -4.4, top: 4.8, fit: 11.5)
      f.along([(word, font("HelveticaNeue-CondensedBold", 2.4), ink)], s: -7.4, top: 4.8, fit: 11.5)
      f.along([("FOMAPAN", font("HelveticaNeue-CondensedBlack", 7.6), white)], s: 2.8, top: 4.8, fit: 28, kern: 0.2)
      f.along([("profi line", font("HelveticaNeue-Light", 2.8), white)], s: 7.6, top: 24, fit: 11)
      f.along([("BLACK & WHITE NEGATIVE FILM", font("HelveticaNeue-Medium", 1.7), white)], s: -11.4, top: 4.8, fit: 26)
      f.dx(look)
    }
  }
}
