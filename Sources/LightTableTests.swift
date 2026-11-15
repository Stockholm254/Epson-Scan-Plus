import AppKit
import CoreGraphics
import Foundation

enum LightTableTests {
  static func run(folder: URL) throws {
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw DeskError.message("FAIL: " + label) }; print("PASS: " + label)
    }
    let table = LightTable()
    guard let image = table.image(size: CGSize(width: 400, height: 300), scale: 2) else {
      throw DeskError.message("FAIL: the light table is shaded by Metal compiled at run time")
    }
    try check(image.width == 800 && image.height == 600, "the light table is shaded by Metal at the display's resolution")
    try check(table.image(size: CGSize(width: 400, height: 300), scale: 2) === image
      && table.image(size: CGSize(width: 401, height: 300), scale: 2) !== image,
      "the shaded table is cached until the view changes size")
    let bytes = [UInt8](image.dataProvider!.data! as Data)
    func pixel(_ x: Int, _ y: Int) -> [Int] { (0..<4).map { Int(bytes[(y * image.width + x) * 4 + $0]) } }
    let centre = pixel(400, 300), nearEdge = pixel(Int(LightTable.glassInset * 2) + 20, 300)
    try check(centre[0] == centre[1] && centre[1] == centre[2] && centre[0] > 235,
      "the glass is a bright neutral white: \(centre.prefix(3))")
    try check(nearEdge[1] + 5 < centre[1], "the glass falls off towards the frame: \(nearEdge[1]) at the edge, \(centre[1]) at the centre")
    let bar = pixel(18, 300)
    try check(bar[3] == 255 && bar[1] < 90, "the aluminium frame is dark like the panels: \(bar.prefix(3))")
    try check(pixel(0, 0)[3] == 0, "the frame's rounded corners leave the workspace showing")
    // The glass is recessed: the chamfer above it faces away from the light, the one below faces it.
    let top = pixel(400, Int(LightTable.glassInset * 2) - 6), bottom = pixel(400, 600 - Int(LightTable.glassInset * 2) + 6)
    try check(top[1] < bottom[1], "light falls from above on the flipped canvas: chamfer \(top[1]) above, \(bottom[1]) below the glass")
    // Stretched over a canvas growing as the status line folds away (`drawStretched`), the table
    // made for the size before shows as the one made for the new size would, its frame's corners
    // as they are.
    let taller = CGSize(width: 400, height: 330)
    guard let exact = table.image(size: taller, scale: 2) else { throw DeskError.message("FAIL: no table for the new size") }
    let w = 800, h = 660
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 2, y: -2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    LightTable.drawStretched(image, made: CGSize(width: 400, height: 300), in: CGRect(origin: .zero, size: taller))
    NSGraphicsContext.restoreGraphicsState()
    let made = [UInt8](exact.dataProvider!.data! as Data), stretched = [UInt8](ctx.makeImage()!.dataProvider!.data! as Data)
    var sum = 0.0, most = 0, corner = 0
    for i in 0..<min(made.count, stretched.count) {
      let d = abs(Int(made[i]) - Int(stretched[i]))
      sum += Double(d)
      most = max(most, d)
      let p = i / 4
      if p % w < 40 && p / w < 40 { corner = max(corner, d) }
    }
    let mean = sum / Double(made.count)
    try check(made.count == stretched.count && mean < 1 && most <= 12 && corner <= 2,
      String(format: "the table stretched while the canvas changes size is as it would be made for it (%.2f apart on average, %d at most, %d in a corner /255)", mean, most, corner))
  }
}
