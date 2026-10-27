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
  }
}
