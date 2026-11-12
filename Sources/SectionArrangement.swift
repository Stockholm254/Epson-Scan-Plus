import SwiftUI
import UniformTypeIdentifiers

/// The sections of a side column in the order the user put them: dragged by the grip that shows
/// on a section's title row, or moved up and down from its title's menu, kept for each column
/// (② 的胶片与画面, ② 的右栏, ③ 的右栏) and back to the app's own order from the same menu.
/// Sections the column does not show at the moment (片基 for a slide, 画面范围 on the light
/// table) keep their places for when they come back.
enum SectionColumn: String, CaseIterable {
  case film, demask, grade
  /// The column's sections in the app's own order, by their keys.
  var defaults: [String] {
    switch self {
    case .film: return ["film", "calibration", "base", "frame"]
    case .demask: return ["dust", "input"]
    case .grade: return ["balance", "tone", "levels", "colour", "curves", "sharpening"]
    }
  }
  var storageKey: String { "sectionOrder." + rawValue }
}

/// Orders worked out on keys alone, so tests can check them.
enum SectionOrder {
  /// The saved order, read: keys the column no longer has left out, keys it gained since put
  /// where the app's own order has them, after the one before them.
  static func order(saved: String, defaults: [String]) -> [String] {
    var out = [String]()
    for k in saved.split(separator: ",").map(String.init) where defaults.contains(k) && !out.contains(k) { out.append(k) }
    for (i, k) in defaults.enumerated() where !out.contains(k) {
      let before = defaults[..<i].last { out.contains($0) }
      let at = before.flatMap { out.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
      out.insert(k, at: at)
    }
    return out
  }
  static func saved(_ order: [String]) -> String { order.joined(separator: ",") }
  /// `dragged` put where `target` is: after it when coming from above, before it from below.
  static func place(_ dragged: String, at target: String, in order: [String]) -> [String] {
    guard dragged != target, let from = order.firstIndex(of: dragged), let to = order.firstIndex(of: target) else { return order }
    var out = order
    out.remove(at: from)
    let at = out.firstIndex(of: target)! + (from < to ? 1 : 0)
    out.insert(dragged, at: at)
    return out
  }
  /// `key` moved `by` places among those `shown`, the others keeping their places.
  static func move(_ key: String, by: Int, in order: [String], shown: [String]) -> [String] {
    let visible = order.filter(shown.contains)
    guard let i = visible.firstIndex(of: key) else { return order }
    let j = i + by
    guard visible.indices.contains(j) else { return order }
    return place(key, at: visible[j], in: order)
  }
}

/// What a column hands its sections: how to move one, and to put the column back.
final class SectionArranger {
  let column: SectionColumn
  let shown: [String]
  private let read: () -> String
  private let write: (String) -> Void
  /// The section being dragged, by its key, while it is.
  static var dragging: (column: SectionColumn, key: String)?
  init(column: SectionColumn, shown: [String], read: @escaping () -> String, write: @escaping (String) -> Void) {
    self.column = column
    self.shown = shown
    self.read = read
    self.write = write
  }
  var order: [String] { SectionOrder.order(saved: read(), defaults: column.defaults) }
  var isDefault: Bool { order == column.defaults }
  func canMove(_ key: String, by: Int) -> Bool { SectionOrder.move(key, by: by, in: order, shown: shown) != order }
  func move(_ key: String, by: Int) {
    let next = SectionOrder.move(key, by: by, in: order, shown: shown)
    withAnimation(.snappy(duration: 0.25)) { write(SectionOrder.saved(next)) }
  }
  func place(_ dragged: String, at target: String) {
    let next = SectionOrder.place(dragged, at: target, in: order)
    guard next != order else { return }
    withAnimation(.snappy(duration: 0.22)) { write(SectionOrder.saved(next)) }
  }
  func reset() { withAnimation(.snappy(duration: 0.25)) { write("") } }
}

private struct SectionArrangerKey: EnvironmentKey { static let defaultValue: SectionArranger? = nil }
extension EnvironmentValues {
  /// The column a section is in, when it can be moved there.
  var sectionArranger: SectionArranger? {
    get { self[SectionArrangerKey.self] }
    set { self[SectionArrangerKey.self] = newValue }
  }
}

/// A column of sections in the user's order, a divider between them: `shown` the keys it has now,
/// `section` the view for a key.
struct ArrangedColumn<Section: View>: View {
  let column: SectionColumn
  let shown: [String]
  let section: (String) -> Section
  @AppStorage private var saved: String
  init(_ column: SectionColumn, shown: [String], @ViewBuilder section: @escaping (String) -> Section) {
    self.column = column
    self.shown = shown
    self.section = section
    _saved = AppStorage(wrappedValue: "", column.storageKey)
  }
  var body: some View {
    let arranger = SectionArranger(column: column, shown: shown, read: { saved }, write: { saved = $0 })
    let order = SectionOrder.order(saved: saved, defaults: column.defaults).filter(shown.contains)
    ForEach(Array(order.enumerated()), id: \.element) { i, key in
      VStack(alignment: .leading, spacing: 16) {
        if i > 0 { Divider() }
        section(key)
      }
      .onDrop(of: [.utf8PlainText], delegate: SectionDrop(target: key, arranger: arranger))
    }
    .environment(\.sectionArranger, arranger)
  }
}

/// A section dragged over another takes its place as it passes, so the column shows where it will
/// lie; let go, it stays.
struct SectionDrop: DropDelegate {
  let target: String
  let arranger: SectionArranger
  func validateDrop(info: DropInfo) -> Bool { SectionArranger.dragging?.column == arranger.column }
  func dropEntered(info: DropInfo) {
    guard let d = SectionArranger.dragging, d.column == arranger.column, d.key != target else { return }
    arranger.place(d.key, at: target)
  }
  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
  func performDrop(info: DropInfo) -> Bool {
    SectionArranger.dragging = nil
    return true
  }
}
