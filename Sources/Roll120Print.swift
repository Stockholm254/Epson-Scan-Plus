import AppKit

/// The print on a 120 roll, maker by maker, as photographs of the real rolls show it: the backing
/// paper round the spool (Kodak Professional's white with dark ends, the stock's name and a bar
/// code; Fujifilm's teal or green ends; Ilford's, Lomography's and the others' plain pale paper) and
/// the seal round its middle that names the film (Kodak's yellow, the others' white carrying the
/// stock's own colours). Positions are millimetres down from the paper's top edge (62 mm tall) and
/// round from the front the camera looks at.
enum Roll120Print {
  typealias Look = NewProjectSheet.Look
  /// The seal: its picture, how tall it is, and how far its middle lies above the paper's middle.
  struct Seal {
    let image: NSImage
    let height: CGFloat
    let rise: CGFloat
  }
  static let round: CGFloat = 2 * .pi * 12.0, paperTall: CGFloat = 62
  static var mm: CGFloat { FilmRender.Label.mm }
  static func rgb(_ hex: UInt32) -> NSColor { FilmPrint.rgb(hex) }
  static func font(_ name: String, _ size: CGFloat) -> NSFont { NSFont(name: name, size: size * mm) ?? NSFont.systemFont(ofSize: size * mm, weight: .bold) }
  /// A line centred `s` mm round from the front, its top `y` mm down, no longer than `fit` mm.
  static func line(_ s: String, _ f: NSFont, _ c: NSColor, s at: CGFloat = 0, y: CGFloat, fit: CGFloat? = nil, kern: CGFloat = 0, width: CGFloat) {
    FilmRender.Label.text(s, f, c, at: CGPoint(x: width * FilmRender.Label.front + at * mm, y: y * mm), kern: kern * mm, fit: fit.map { $0 * mm })
  }
  /// Runs of words in their own fonts, centred on the front.
  static func runs(_ parts: [(String, NSFont, NSColor)], y: CGFloat, width: CGFloat, s at: CGFloat = 0) {
    let a = NSMutableAttributedString()
    for (s, f, c) in parts { a.append(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])) }
    a.draw(at: CGPoint(x: width * FilmRender.Label.front + at * mm - a.size().width / 2, y: y * mm))
  }
  static func band(_ ctx: CGContext, _ c: NSColor, _ y0: CGFloat, _ y1: CGFloat, width: CGFloat) {
    ctx.setFillColor(c.cgColor)
    ctx.fill(CGRect(x: 0, y: y0 * mm, width: width, height: (y1 - y0) * mm))
  }
  enum Family { case kodak, fujichrome, fujicolor, ilford, kentmere, lomography, cinestill, other }
  static func family(_ look: Look) -> Family {
    switch look.maker ?? "" {
    case "Kodak": return .kodak
    case "Fujifilm": return look.kind == .slide ? .fujichrome : .fujicolor
    case "Ilford": return .ilford
    case "Kentmere": return .kentmere
    case "Lomography": return .lomography
    case "CineStill": return .cinestill
    default: return .other
    }
  }
  /// The stock's name without its maker, as the roll prints it (PORTRA 400); Tri-X's paper reads
  /// 400TX, as its cassette does.
  static func stockName(_ look: Look) -> String {
    look.name.contains("Tri-X") ? "\(look.iso ?? 400)TX" : look.name
  }

  // MARK: The backing paper

  static func paper(_ look: Look) -> NSImage {
    FilmRender.Label.draw(width: round, height: paperTall) { ctx, size in
      let w = size.width
      switch family(look) {
      case .kodak:
        // White, dark grey ends (deeper at the top), the stock's name large round the top, the bar
        // code round the foot.
        band(ctx, rgb(0xF3F2EE), 0, 62, width: w)
        band(ctx, rgb(0x2B2D2C), 0, 7.2, width: w)
        band(ctx, rgb(0x2B2D2C), 58.8, 62, width: w)
        let name = stockName(look).uppercased()
        for at in [-round / 2, 0, round / 2] as [CGFloat] {
          line(name, font("HelveticaNeue", 5.6), rgb(0x2C2C2C), s: at, y: 10.2, fit: round / 2 - 3, width: w)
        }
        band(ctx, rgb(0xF6A31E), 18.5, 41.8, width: w)
        var y: CGFloat = 44.2
        var seed = UInt32(truncatingIfNeeded: name.unicodeScalars.reduce(7) { $0 &* 31 &+ Int($1.value) }) | 1
        while y < 54.8 {
          seed = seed &* 1103515245 &+ 12345
          let t = CGFloat((seed >> 16) % 4 + 1) * 0.32
          band(ctx, rgb(0x1E1E1E), y, min(54.8, y + t), width: w)
          y += t + CGFloat((seed >> 20) % 3 + 1) * 0.42
        }
      case .fujichrome, .fujicolor:
        // The maker's colour at both ends with 120 and FUJIFILM in white, white between.
        let c = family(look) == .fujichrome ? rgb(0x1C7FA6) : rgb(0x1D9A57)
        band(ctx, rgb(0xF1F1EE), 0, 62, width: w)
        band(ctx, c, 0, 13.5, width: w)
        band(ctx, c, 48.5, 62, width: w)
        for at in [-round / 3, 0, round / 3] as [CGFloat] {
          line("120", font("HelveticaNeue-Bold", 3.0), .white, s: at, y: 4.2, width: w)
          line("FUJIFILM", font("AvenirNext-DemiBold", 3.2), .white, s: at, y: 53.0, fit: 20, kern: 0.3, width: w)
        }
      case .cinestill:
        // CineStill's: plain white paper, the wound end of it showing as a thin grey line that
        // runs round the roll on a slant, above the seal and below it.
        band(ctx, rgb(0xF4F4F2), 0, 62, width: w)
        for (x0, y0, x1, y1) in [(0.18, 0.0, 0.62, 21.0), (0.42, 42.0, 0.9, 62.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
          let line = CGMutablePath()
          line.move(to: CGPoint(x: w * x0, y: y0 * mm))
          line.addCurve(to: CGPoint(x: w * x1, y: y1 * mm), control1: CGPoint(x: w * (x0 + 0.12), y: (y0 + (y1 - y0) * 0.2) * mm),
            control2: CGPoint(x: w * (x1 - 0.05), y: (y0 + (y1 - y0) * 0.75) * mm))
          ctx.addPath(line)
          ctx.setStrokeColor(rgb(0xB9B9B6).cgColor)
          ctx.setLineWidth(0.22 * mm)
          ctx.strokePath()
          // The paper's edge throws a faint shadow on the turn under it.
          ctx.addPath(line.copy(using: [CGAffineTransform(translationX: 0, y: 0.25 * mm)])!)
          ctx.setStrokeColor(rgb(0xDCDCD9).cgColor)
          ctx.setLineWidth(0.35 * mm)
          ctx.strokePath()
        }
      case .ilford, .kentmere, .lomography, .other:
        // Plain pale paper, the maker's name small round the ends where it has one.
        band(ctx, rgb(0xE9E9E6), 0, 62, width: w)
        let maker = (look.maker ?? "").uppercased()
        let ink = NSColor(white: 0.55, alpha: 1)
        for at in [-round / 3, 0, round / 3] as [CGFloat] {
          line(maker, font("HelveticaNeue-Medium", 1.8), ink, s: at, y: 4.0, kern: 0.3, width: w)
          line("120", font("HelveticaNeue-Medium", 1.8), ink, s: at, y: 56.0, width: w)
        }
      }
    }
  }

  // MARK: The seal

  static func seal(_ look: Look) -> Seal {
    switch family(look) {
    case .kodak: return kodakSeal(look)
    case .fujichrome, .fujicolor: return fujiSeal(look)
    case .ilford: return ilfordSeal(look)
    case .kentmere: return kentmereSeal(look)
    case .lomography: return lomographySeal(look)
    case .cinestill: return cinestillSeal(look)
    case .other: return otherSeal(look)
    }
  }
  /// Kodak Professional's: yellow, Kodak in red with Professional, 120 large, the warning under it.
  static func kodakSeal(_ look: Look) -> Seal {
    let tall: CGFloat = 16
    let image = FilmRender.Label.draw(width: round + 0.9, height: tall) { ctx, size in
      let w = size.width
      band(ctx, rgb(0xF8B23A), 0, tall, width: w)
      let pro = look.tags.contains { $0.contains("Professional") } || ["Portra", "Ektar", "Ektacolor", "Tri-X", "T-Max", "Ektachrome", "Pro Image", "Ektapan", "Vision", "Double-X"].contains { look.name.contains($0) }
      for at in [0, round / 2] as [CGFloat] {
        runs([("Kodak", font("AvenirNext-Bold", 2.3), rgb(0xD8262E)), (pro ? " Professional" : "", font("AvenirNext-Regular", 2.3), rgb(0x1E1E1E))], y: 1.6, width: w, s: at)
        line("120", font("AvenirNext-Bold", 6.0), rgb(0x161616), s: at, y: 4.6, width: w)
        line("Load in subdued light.", font("AvenirNext-DemiBold", 1.5), rgb(0x1E1E1E), s: at, y: 12.2, fit: 22, width: w)
      }
    }
    return Seal(image: image, height: tall, rise: -0.5)
  }
  /// Fujifilm's: white, a band of navy (Fujichrome) or green (Fujicolor) across with the stock in
  /// white, FUJI above it in the colour, the warning under it.
  static func fujiSeal(_ look: Look) -> Seal {
    let tall: CGFloat = 20
    let slide = family(look) == .fujichrome
    let c = slide ? rgb(0x1E3A8C) : rgb(0x1D9A57)
    let image = FilmRender.Label.draw(width: round + 0.9, height: tall) { ctx, size in
      let w = size.width
      band(ctx, rgb(0xF7F7F5), 0, tall, width: w)
      band(ctx, c, 7.4, 13.0, width: w)
      let name = look.name.replacingOccurrences(of: "Neopan ", with: "")
      for at in [0, round / 2] as [CGFloat] {
        line("FUJIFILM", font("AvenirNext-Bold", 3.0), c, s: at, y: 2.4, kern: 0.3, width: w)
        line(name, font("AvenirNext-BoldItalic", 4.0), .white, s: at, y: 7.9, fit: 30, width: w)
        line(slide ? "DAYLIGHT · E-6" : "C-41", font("AvenirNext-DemiBold", 1.5), rgb(0x2A2A2A), s: at, y: 14.2, width: w)
        line("LOAD IN SUBDUED LIGHT", font("AvenirNext-Medium", 1.3), rgb(0x4A4A4A), s: at, y: 16.4, width: w)
      }
    }
    return Seal(image: image, height: tall, rise: 1.0)
  }
  /// Ilford's: white with the cassette's own words across it, upright, ILFORD over the stock's name in its
  /// colour, the black bar with PLUS (or the speed) under it.
  static func ilfordSeal(_ look: Look) -> Seal {
    let tall: CGFloat = 18
    let colour: NSColor, word: String, third: String
    let iso = look.iso ?? 400
    if look.name.contains("Delta") {
      colour = iso == 100 ? rgb(0x3FA2D8) : iso == 400 ? rgb(0x2E9A4C) : rgb(0x64399A); word = "DELTA"; third = "\(iso)"
    } else if look.name.contains("HP5") {
      colour = rgb(0x37A23C); word = "HP5"; third = "PLUS"
    } else if look.name.contains("FP4") {
      colour = rgb(0x2D6DB5); word = "FP4"; third = "PLUS"
    } else if look.name.contains("Pan F") {
      colour = rgb(0xE2541E); word = "PAN F"; third = "PLUS"
    } else if look.name.contains("XP2") {
      colour = rgb(0xD62B2B); word = "XP2"; third = "SUPER"
    } else if look.name.contains("SFX") {
      colour = rgb(0x8A1F33); word = "SFX"; third = "\(iso)"
    } else {
      colour = rgb(0x9C2A2A); word = look.name.uppercased(); third = "PLUS"
    }
    let image = FilmRender.Label.draw(width: round + 0.9, height: tall) { ctx, size in
      let w = size.width
      band(ctx, rgb(0xF7F7F5), 0, tall, width: w)
      let heavy = "HelveticaNeue-CondensedBlack"
      // ILFORD and the stock's name upright as on the box, PLUS on its bar leaning.
      func lean(_ text: String, _ f: NSFont, _ c: NSColor, s at: CGFloat, y: CGFloat, fit: CGFloat, slant: CGFloat = 0) {
        var a = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: c, .obliqueness: slant])
        if a.size().width > fit * mm, let smaller = NSFont(descriptor: f.fontDescriptor, size: f.pointSize * fit * mm / a.size().width) {
          a = NSAttributedString(string: text, attributes: [.font: smaller, .foregroundColor: c, .obliqueness: slant])
        }
        a.draw(at: CGPoint(x: w * FilmRender.Label.front + at * mm - a.size().width / 2, y: y * mm))
      }
      for at in [0, round / 2] as [CGFloat] {
        lean("ILFORD", font(heavy, 3.6), FilmPrint.ink, s: at, y: 1.2, fit: 14)
        lean(word, font(heavy, 6.8), colour, s: at, y: 4.2, fit: 18)
        // The black bar, its left end breaking up into squares, its word in white on it.
        let x0 = w * FilmRender.Label.front + (at - 6.0) * mm, sq = 0.6 * mm
        ctx.setFillColor(FilmPrint.ink.cgColor)
        ctx.fill(CGRect(x: x0 + 2.4 * mm, y: 11.6 * mm, width: 9.6 * mm, height: 3.6 * mm))
        for col in 0..<4 {
          for row in 0..<6 where (row * 3 + col * 5) % 4 < col + 1 {
            ctx.fill(CGRect(x: x0 + CGFloat(col) * sq, y: 11.6 * mm + CGFloat(row) * sq, width: sq, height: sq))
          }
        }
        lean(third, font(heavy, 3.0), .white, s: at + 1.2, y: 11.9, fit: 9, slant: 0.16)
        if third == "PLUS" || third == "SUPER" { line("\(iso)", font("HelveticaNeue-CondensedBlack", 2.0), FilmPrint.ink, s: at + 1.2, y: 15.6, width: w) }
        if word == "DELTA" { line("PROFESSIONAL", font("HelveticaNeue-Bold", 1.7), colour, s: at, y: 15.6, kern: 0.15, width: w) }
      }
    }
    return Seal(image: image, height: tall, rise: -3.5)
  }
  /// Kentmere's: its gradient, the K mark, PAN and the speed, KENTMERE, all in white.
  static func kentmereSeal(_ look: Look) -> Seal {
    let tall: CGFloat = 20
    let iso = look.iso ?? 400
    let colours = iso == 400 ? [rgb(0x3B3FC2), rgb(0x7A3AB8), rgb(0xC24AC9)]
      : iso == 200 ? [rgb(0x2A6FB8), rgb(0x5E9B3C), rgb(0xC9B83A)] : [rgb(0x1E3E9A), rgb(0x1F7AA8), rgb(0x2FB09A)]
    let image = FilmRender.Label.draw(width: round + 0.9, height: tall) { ctx, size in
      let w = size.width
      if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours.map(\.cgColor) as CFArray, locations: nil) {
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: 0), options: [])
      }
      for at in [0, round / 2] as [CGFloat] {
        runs([("PAN ", font("AvenirNext-Bold", 4.8), .white), ("\(iso)", font("AvenirNext-Regular", 4.8), .white)], y: 3.2, width: w, s: at)
        line("KENTMERE", font("AvenirNext-Bold", 3.0), .white, s: at, y: 10.4, kern: 0.15, width: w)
        line("BLACK & WHITE FILM", font("AvenirNext-Medium", 1.5), .white, s: at, y: 14.6, kern: 0.2, width: w)
      }
    }
    return Seal(image: image, height: tall, rise: -2.0)
  }
  /// Lomography's: white, lomography in red, the stock's words stacked in heavy colour.
  static func lomographySeal(_ look: Look) -> Seal {
    let tall: CGFloat = 20
    let name = look.name.uppercased()
    let colour: NSColor = name.contains("PURPLE") ? rgb(0x5E2A86) : name.contains("TURQUOISE") ? rgb(0x178E92)
      : name.contains("METROPOLIS") ? rgb(0x55585C) : name.contains("GREY") || name.contains("KINO") ? rgb(0x2C2C2C) : rgb(0xD8247A)
    let words: [String] = name.contains("COLOR NEGATIVE") ? ["COLOR", "NEGATIVE", "\(look.iso ?? 400)"]
      : name.split(separator: " ").map(String.init).filter { $0 != "LOMOCHROME" && $0 != "LOMOGRAPHY" }
    let image = FilmRender.Label.draw(width: round + 0.9, height: tall) { ctx, size in
      let w = size.width
      band(ctx, rgb(0xF7F7F5), 0, tall, width: w)
      for at in [0, round / 2] as [CGFloat] {
        let logo = CGRect(x: w * FilmRender.Label.front + (at - 7) * mm, y: 1.6 * mm, width: 14 * mm, height: 2.8 * mm)
        ctx.setFillColor(rgb(0xD8262E).cgColor)
        ctx.fill(logo)
        line("lomography", font("AvenirNext-HeavyItalic", 2.2), .white, s: at, y: 1.75, fit: 13, width: w)
        for (k, word) in words.prefix(3).enumerated() {
          line(word, font("AvenirNextCondensed-Heavy", 3.6), colour, s: at, y: 5.4 + CGFloat(k) * 4.0, fit: 18, kern: 0.1, width: w)
        }
      }
    }
    return Seal(image: image, height: tall, rise: -1.0)
  }
  /// CineStill's: a narrow white edge over a band of the stock's colour (800T red, 400D purple,
  /// 50D blue), and on it the CineStill film mark in white: Cine over Still, its C and S large
  /// and round, film upright beside till.
  static func cinestillSeal(_ look: Look) -> Seal {
    let tall: CGFloat = 24, edge: CGFloat = 3.6
    let name = look.name.uppercased()
    let colour = name.contains("400D") ? rgb(0x67308F) : name.contains("50D") ? rgb(0x2C64B4) : rgb(0xD3262E)
    let image = FilmRender.Label.draw(width: round + 0.9, height: tall) { ctx, size in
      let w = size.width
      band(ctx, rgb(0xF6F6F4), 0, tall, width: w)
      band(ctx, colour, edge, tall, width: w)
      let thin = "AvenirNext-Medium", big = "AvenirNext-Regular"
      for at in [0, round / 2] as [CGFloat] {
        let x = w * FilmRender.Label.front + at * mm
        // Cine: a large C, ine beside it; Still under it the same; film upright after till.
        func word(_ first: String, _ rest: String, top: CGFloat) -> CGFloat {
          let a = NSMutableAttributedString(string: first, attributes: [.font: font(big, 9.6), .foregroundColor: NSColor.white, .kern: -0.6 * mm])
          a.append(NSAttributedString(string: rest, attributes: [.font: font(thin, 6.0), .foregroundColor: NSColor.white, .kern: -0.15 * mm]))
          a.draw(at: CGPoint(x: x - 7.2 * mm, y: top * mm))
          return a.size().width
        }
        _ = word("C", "ine", top: edge + 0.6)
        let still = word("S", "till", top: edge + 8.6)
        ctx.saveGState()
        let film = NSAttributedString(string: "film", attributes: [.font: font(thin, 2.6), .foregroundColor: NSColor.white])
        ctx.translateBy(x: x - 7.2 * mm + still + 0.4 * mm, y: (edge + 18.4) * mm)
        ctx.rotate(by: -.pi / 2)
        film.draw(at: .zero)
        ctx.restoreGState()
      }
    }
    return Seal(image: image, height: tall, rise: 2.0)
  }
  /// Any other maker's: white, a band of the maker's colour with its name, the stock and speed.
  static func otherSeal(_ look: Look) -> Seal {
    let tall: CGFloat = 18
    let l = FilmRender.livery(look.maker)
    let (kindColour, process) = FilmRender.kindBand(look)
    let image = FilmRender.Label.draw(width: round + 0.9, height: tall) { ctx, size in
      let w = size.width
      band(ctx, rgb(0xF7F7F5), 0, tall, width: w)
      let strong = l.ground.brightnessComponentSafe < 0.85 ? l.ground : l.band
      band(ctx, strong, 0, 4.6, width: w)
      band(ctx, kindColour, tall - 3.0, tall, width: w)
      for at in [0, round / 2] as [CGFloat] {
        line((look.maker ?? "").uppercased(), font("AvenirNextCondensed-Heavy", 3.0), .white, s: at, y: 0.9, fit: 22, kern: 0.3, width: w)
        line(look.name, font("AvenirNextCondensed-Bold", 4.4), rgb(0x161616), s: at, y: 5.6, fit: 22, width: w)
        if let iso = look.iso { line("\(iso)", font("AvenirNextCondensed-Heavy", 4.0), rgb(0x161616), s: at, y: 10.0, width: w) }
        line(process, font("AvenirNextCondensed-DemiBold", 1.9), .white, s: at, y: tall - 2.6, width: w)
      }
    }
    return Seal(image: image, height: tall, rise: 1.0)
  }
}

private extension NSColor {
  /// Brightness in sRGB, whatever the colour's space.
  var brightnessComponentSafe: CGFloat { usingColorSpace(.sRGB)?.brightnessComponent ?? 0.5 }
}
