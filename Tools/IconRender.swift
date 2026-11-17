import AppKit
import SceneKit

/// Draws the app icon's two pictures into Icon/AppIcon.icon/Assets (Tools/render-icon.sh builds it
/// with the app's Sources and runs it; Icon/build-icon.sh then compiles the icon):
/// - cassette.png: the shelf's own 3D 135 cassette (`FilmRender.stage`), 1024 px on a clear ground,
///   its print a black shell with the yellow notes band, "100", C-41 and the DX squares, in the
///   manner of a professional colour negative but with no maker's or stock's name;
/// - glow.png: a light table's glow, white in the middle easing to a pale grey towards the corners.
@main enum IconRender {
  static func main() {
    let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon/AppIcon.icon/Assets")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
    let renderer = SCNRenderer(device: device, options: nil)
    let look = NewProjectSheet.Look(name: "100", title: "100", iso: 100, kind: .colour)
    let print = FilmRender.Label.draw(width: FilmRender.Shell.round, height: 38) { ctx, size in
      let f = FilmPrint.Flat(ctx: ctx, size: size, front: FilmRender.Shell.frontAt * FilmRender.Label.mm)
      let white = FilmPrint.white
      f.all(FilmPrint.rgb(0x111111))
      f.fill(FilmPrint.kodakYellow, -16, -6.6, y0: 6.2)
      f.across([("C-41", FilmPrint.font("AvenirNext-DemiBold", 3.3), white)], s: -11.3, y: 1.3, fit: 8, centred: true)
      f.along([("NOTES", FilmPrint.font("AvenirNext-DemiBoldItalic", 1.9), FilmPrint.rgb(0x5A3206))], s: -7.7, top: 7.4, fit: 8, kern: 0.15)
      f.along([("100", FilmPrint.font("Avenir-Light", 7.6), white)], s: 1.3, top: 6.0, fit: 31)
      f.along([("Color Negative Film", FilmPrint.font("AvenirNext-DemiBold", 3.0), white)], s: -3.5, top: 6.0, fit: 21)
      f.dx(look)
    }
    let set = FilmRender.stage(look, gauge: .mm135, aspect: 1)
    // The shell is the cassette's first part; its print, its first material.
    set.film.childNodes.first?.geometry?.materials.first?.diffuse.contents = print
    renderer.scene = set.scene
    renderer.pointOfView = set.camera
    let shot = renderer.snapshot(atTime: 0, with: CGSize(width: 1024, height: 1024), antialiasingMode: .multisampling4X)
    guard let cassette = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("no render") }
    write(cassette, root.appendingPathComponent("cassette.png"))

    let w = 1024
    var bytes = [UInt8](repeating: 255, count: w * w * 4)
    for y in 0..<w {
      for x in 0..<w {
        let d = hypot(Double(x) / Double(w) - 0.5, Double(y) / Double(w) - 0.42)
        let t = min(1, d / 0.75), v = 1 - 0.28 * t * t
        let i = (y * w + x) * 4
        bytes[i] = UInt8(250 * v); bytes[i + 1] = UInt8(250 * v); bytes[i + 2] = UInt8(247 * v)
      }
    }
    let ctx = CGContext(data: &bytes, width: w, height: w, bitsPerComponent: 8, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    write(ctx.makeImage()!, root.appendingPathComponent("glow.png"))
  }
  static func write(_ image: CGImage, _ url: URL) {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("no PNG") }
    do { try data.write(to: url) } catch { fatalError("\(url.path): \(error)") }
    Swift.print("wrote", url.path)
  }
}
