import AppKit

/// The glass bubble that rides with a crop corner while it is dragged: the picture under the
/// corner four times larger, with the crop's edges and its dimmed outside drawn in, behind glass
/// whose rim bends the picture outward, splits it very slightly into colour and catches the light
/// from the top left. The corner sits in the middle of the bubble.
enum CropLens {
  static let magnification: CGFloat = 4
  /// Across, in points.
  static let diameter: CGFloat = 148
  /// How far beyond the plain magnification the rim reaches out into the picture.
  static let rimReach = 0.32
  /// Where the rim begins, as a fraction of the radius.
  static let rimStart = 0.72
  /// The red and blue images' scale against the green at the very rim, about 1%.
  static let dispersion = 0.012

  /// The bubble, `pixels` across: `picture` about `center` (its pixels, from the top left), at
  /// `scale` bubble pixels per picture pixel, with `crop` (picture pixels) outlined and outside it
  /// darkened by `dimOutside`. Where the bubble reaches past the picture it shows the canvas.
  static func render(
    _ picture: CGImage, center: CGPoint, scale: CGFloat, crop: CGRect?, dimOutside: Double = 0.5, pixels: Int
  ) -> CGImage? {
    guard pixels > 4, scale > 0 else { return nil }
    // The patch of the picture the bubble can reach, drawn once into memory.
    let reach = Double(pixels) / 2 / Double(scale) * (1 + rimReach) * (1 + dispersion) + 2
    let patch = CGRect(x: center.x - reach, y: center.y - reach, width: 2 * reach, height: 2 * reach).integral
    let w = Int(patch.width), h = Int(patch.height)
    guard w > 0, h > 0 else { return nil }
    let space = ImagePipeline.shared.outputSpace
    var source = [UInt8](repeating: 0, count: w * h * 4)
    let surround: (Double, Double, Double) = (0.105, 0.11, 0.115)
    for i in 0..<(w * h) {
      source[i * 4] = UInt8(surround.0 * 255)
      source[i * 4 + 1] = UInt8(surround.1 * 255)
      source[i * 4 + 2] = UInt8(surround.2 * 255)
      source[i * 4 + 3] = 255
    }
    let bounds = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
    let visible = patch.intersection(bounds)
    if !visible.isNull, visible.width >= 1, visible.height >= 1, let part = picture.cropping(to: visible) {
      source.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
          data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        // Core Graphics counts rows from the bottom; the patch's rows run from the top.
        ctx.interpolationQuality = .none
        ctx.draw(part, in: CGRect(
          x: visible.minX - patch.minX, y: patch.maxY - visible.maxY, width: visible.width, height: visible.height))
      }
    }
    func sample(_ x: Double, _ y: Double, _ c: Int) -> Double {
      let fx = min(max(x - 0.5, 0), Double(w - 1)), fy = min(max(y - 0.5, 0), Double(h - 1))
      let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
      let tx = fx - Double(x0), ty = fy - Double(y0)
      func at(_ x: Int, _ y: Int) -> Double { Double(source[(y * w + x) * 4 + c]) / 255 }
      return (at(x0, y0) * (1 - tx) + at(x1, y0) * tx) * (1 - ty) + (at(x0, y1) * (1 - tx) + at(x1, y1) * tx) * ty
    }
    let amber = (0.95, 0.71, 0.38)
    let radius = Double(pixels) / 2
    let lineHalf = 1.1 * Double(pixels) / Double(diameter)  // about 2.2 points wide
    // The light comes from the top left.
    let light = (-0.55, -0.835)
    var out = [UInt8](repeating: 0, count: pixels * pixels * 4)
    for py in 0..<pixels {
      for px in 0..<pixels {
        let dx = Double(px) + 0.5 - radius, dy = Double(py) + 0.5 - radius
        let rho = (dx * dx + dy * dy).squareRoot() / radius
        let alpha = min(max((1 - rho) * radius + 0.5, 0), 1)
        if alpha <= 0 { continue }
        let rim = smoothstep(rimStart, 1, rho)
        let bend = 1 + rimReach * rim * rim
        let along = bend / Double(scale)
        // Where the green looks, and the red and blue a hair either side of it at the rim.
        let gx = Double(center.x) + dx * along, gy = Double(center.y) + dy * along
        var colour = [0.0, 0.0, 0.0]
        for c in 0..<3 {
          let spread = c == 1 ? 1 : 1 + (c == 0 ? dispersion : -dispersion) * rim
          let x = Double(center.x) + dx * along * spread - patch.minX
          let y = Double(center.y) + dy * along * spread - patch.minY
          colour[c] = sample(x, y, c)
        }
        if let crop {
          let inside = crop.contains(CGPoint(x: gx, y: gy))
          if !inside { colour = colour.map { $0 * (1 - dimOutside) } }
          // The crop's edges, a constant width in the bubble.
          let half = lineHalf / (Double(scale) / bend)
          let nearX = gy >= crop.minY - half && gy <= crop.maxY + half
          let nearY = gx >= crop.minX - half && gx <= crop.maxX + half
          var d = Double.infinity
          if nearX { d = min(d, abs(gx - crop.minX), abs(gx - crop.maxX)) }
          if nearY { d = min(d, abs(gy - crop.minY), abs(gy - crop.maxY)) }
          let cover = min(max((half - d) * Double(scale) / bend + 0.5, 0), 1)
          colour = [colour[0] + (amber.0 - colour[0]) * cover, colour[1] + (amber.1 - colour[1]) * cover, colour[2] + (amber.2 - colour[2]) * cover]
        }
        // The glass: light along the rim facing the light, shade on the far side, a bright edge
        // and a soft gloss inside the top left.
        let len = max(1e-6, (dx * dx + dy * dy).squareRoot())
        let facing = (dx / len) * light.0 + (dy / len) * light.1
        let shine = pow(rim, 3) * pow(max(0, facing), 2) * 0.55
        let shade = rim * rim * max(0, -facing) * 0.22
        let edge = smoothstep(0.955, 0.98, rho) * (1 - smoothstep(0.985, 1, rho)) * 0.35
        let gloss = exp(-(pow(dx / radius + 0.38, 2) + pow(dy / radius + 0.42, 2)) / 0.05) * 0.1
        let lift = shine + edge + gloss
        let i = (py * pixels + px) * 4
        for c in 0..<3 {
          let v = colour[c] * (1 - shade) + (1 - colour[c] * (1 - shade)) * lift
          out[i + c] = UInt8(min(max(v, 0), 1) * alpha * 255 + 0.5)
        }
        out[i + 3] = UInt8(alpha * 255 + 0.5)
      }
    }
    return out.withUnsafeMutableBytes { raw in
      CGContext(
        data: raw.baseAddress, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
  }

  /// Where the bubble goes for a corner at `point`: above and to the left of it, out from under
  /// the pointer and the corner, or across to the other side where that would leave `bounds`.
  static func frame(for point: CGPoint, in bounds: CGRect, diameter: CGFloat = diameter, flipped: Bool = true) -> CGRect {
    let gap: CGFloat = 26
    let offset = diameter / 2 + gap
    // Up is towards smaller y in a flipped view.
    let up: CGFloat = flipped ? -1 : 1
    var c = CGPoint(x: point.x - offset, y: point.y + up * offset)
    if c.x - diameter / 2 < bounds.minX { c.x = point.x + offset }
    let top = flipped ? c.y - diameter / 2 < bounds.minY : c.y + diameter / 2 > bounds.maxY
    if top { c.y = point.y - up * offset }
    c.x = min(max(c.x, bounds.minX + diameter / 2), bounds.maxX - diameter / 2)
    c.y = min(max(c.y, bounds.minY + diameter / 2), bounds.maxY - diameter / 2)
    return CGRect(x: c.x - diameter / 2, y: c.y - diameter / 2, width: diameter, height: diameter)
  }

  /// How large the bubble is drawn `t` seconds after it appears (it swells a little past full
  /// size and settles), or after it is let go (it shrinks and fades), as scale and opacity.
  static func appearance(shownFor t: Double, released: Double?) -> (scale: CGFloat, opacity: CGFloat) {
    if let released {
      let k = min(max(released / 0.16, 0), 1)
      return (1 - 0.12 * k, 1 - k)
    }
    let k = min(max(t / 0.2, 0), 1)
    // Ease out with a little overshoot.
    let s = 1 + 2.2 * pow(k - 1, 3) + 1.2 * pow(k - 1, 2)
    return (0.6 + 0.4 * s, min(1, k * 2.5))
  }
  private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
  }
}
