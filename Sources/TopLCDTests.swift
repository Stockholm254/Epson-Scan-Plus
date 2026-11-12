import AppKit
import SwiftUI

/// The camera's settings on its top LCD: written as the panel writes them, each figure in its
/// cells, dark segments on the pale reflector by day and on the blue lamp in the dark, dashes
/// before it is connected.
enum TopLCDTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    try check(TopLCD.shutterFace("1/125") == "125" && TopLCD.shutterFace("0.5\"") == "0\"5" && TopLCD.shutterFace("2\"") == "2\""
      && TopLCD.shutterFace("B") == "buLb" && TopLCD.apertureFace("f/8.0") == "8.0" && TopLCD.apertureFace("f/11.0") == "11"
      && TopLCD.isoFace("ISO 100") == "100" && TopLCD.isoFace("ISO AUTO") == "Auto"
      && TopLCD.biasValue("+0.7 EV") == 0.7 && TopLCD.biasValue("±0.0 EV") == 0 && TopLCD.biasValue(nil) == nil,
      "the LCD writes shutter, aperture and ISO as a camera's top panel does: 125, 0\"5, buLb, 8.0, 11, Auto")
    let half = TopLCD.cells("0\"5"), f = TopLCD.cells("5.6")
    let spelled = ["buLb", "Auto", "----", "0123456789"].allSatisfy { $0.allSatisfy { SevenSegment.segments[$0] != nil } }
    try check(half.count == 2 && half[0].mark == "\"" && f.count == 2 && f[0].mark == "." && f[1].mark == nil && spelled,
      "a decimal point or seconds mark joins the figure before it, and every letter it spells has its segments")
    try check(TopLCD.bars(0.8) == 3 && TopLCD.bars(0.5) == 2 && TopLCD.bars(0.2) == 1 && TopLCD.bars(0.02) == 0 && TopLCD.bars(nil) == 0,
      "the battery shows three bars full, fewer as it runs down")

    // Drawn: how much of the screen is dark segment, and the reflector's colour.
    func render(_ lcd: TopLCD, lit: Bool) -> (ink: Double, light: SIMD3<Double>)? {
      MainActor.assumeIsolated {
        let r = ImageRenderer(content: lcd.frame(width: 252).environment(\.colorScheme, lit ? .dark : .light))
        r.scale = 2
        guard let cg = r.cgImage else { return nil }
        let w = cg.width, h = cg.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: w * h * 4), count: w * h * 4))
        // Inside the screen, clear of its bevel: 12 points in from the sides, 12 from top and bottom.
        var dark = 0, n = 0, sum = SIMD3<Double>(repeating: 0), lights = 0
        for y in stride(from: 24, to: h - 24, by: 1) {
          for x in stride(from: 24, to: w - 24, by: 1) {
            let i = (y * w + x) * 4
            let c = SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255
            let luma = 0.3 * c.x + 0.59 * c.y + 0.11 * c.z
            n += 1
            if luma < 0.3 { dark += 1 } else if luma > 0.5 { sum += c; lights += 1 }
          }
        }
        return (Double(dark) / Double(n), sum / Double(max(lights, 1)))
      }
    }
    let on = TopLCD(shutter: "1/125", aperture: "f/8.0", iso: "ISO 100", bias: "+0.7 EV", mode: "M", shots: 12, battery: 0.8)
    let off = TopLCD(shutter: "--", aperture: "--", iso: "--", connected: false)
    if let day = render(on, lit: false), let night = render(on, lit: true), let none = render(off, lit: false) {
      print("LCD ink \(day.ink) lit \(night.ink) off \(none.ink); reflector \(day.light) lamp \(night.light)")
      try check(day.ink > 0.05 && day.ink < 0.4 && abs(day.light.x - day.light.z) < 0.12 && day.light.y > 0.6,
        "by day the figures are dark on the pale grey-green reflector")
      try check(night.ink > 0.05 && night.light.z > night.light.x + 0.3,
        "in the dark appearance its blue lamp is on behind the same dark figures")
      try check(none.ink < day.ink * 0.6, "before the camera is connected the LCD shows only dashes")
    } else {
      throw DeskError.message("FAIL: the top LCD could not be drawn")
    }
  }
}
