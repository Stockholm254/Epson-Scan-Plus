import SwiftUI

/// A film's calibrations on this Mac as rows of a table, however many there are: what each is
/// called, where it was made (本机 or 翻拍), the scanner or camera, the day, and how many neutral
/// points it was fitted to, read from the calibration's own description; newest first.
struct CalibrationRow: Identifiable, Equatable {
  let id: String
  let title: String
  let kind: String
  let device: String
  let date: String
  let points: Int
  /// The day with its time where the title has one, for sorting within a day.
  let when: String

  init(id: String, title: String, publication: String) {
    self.id = id
    self.title = title
    var parts = publication.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    // 「本机标定 · EPSON V800/V850 · GT-X980 · 2026-10-27 · 3 个中性点」, 「翻拍标定 · ILCE-7RM4 · 2026-10-31 · 8 个中性点」
    let kindPart = parts.first { $0.hasSuffix("标定") }
    kind = kindPart.map { $0.replacingOccurrences(of: "标定", with: "") } ?? (title.hasPrefix("翻拍") ? "翻拍" : "本机")
    if let k = kindPart, let i = parts.firstIndex(of: k) { parts.remove(at: i) }
    let pointsPart = parts.last { $0.hasSuffix("个中性点") }
    points = pointsPart.flatMap { Int($0.replacingOccurrences(of: "个中性点", with: "").trimmingCharacters(in: .whitespaces)) } ?? 0
    if let p = pointsPart, let i = parts.lastIndex(of: p) { parts.remove(at: i) }
    let dated = parts.first { $0.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
    date = dated.map { String($0.prefix(10)) } ?? ""
    if let d = dated, let i = parts.firstIndex(of: d) { parts.remove(at: i) }
    device = parts.joined(separator: " · ")
    // The title's own day and time (「翻拍标定 · 2026-11-11 20:13」) is the finer one.
    let titled = title.range(of: #"\d{4}-\d{2}-\d{2}( \d{2}:\d{2})?"#, options: .regularExpression).map { String(title[$0]) }
    when = titled ?? date
  }
  /// Newest first, then by title.
  static func sorted(_ rows: [CalibrationRow]) -> [CalibrationRow] {
    rows.sorted { $0.when != $1.when ? $0.when > $1.when : $0.title < $1.title }
  }
  /// Rows with every word of `query` in their title, kind, device or day.
  static func filtered(_ rows: [CalibrationRow], _ query: String) -> [CalibrationRow] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return rows }
    return rows.filter { r in
      let text = [r.title, r.kind, r.device, r.date].joined(separator: " ").lowercased()
      return words.allSatisfy { text.contains($0) }
    }
  }
}

/// The calibrations of the film chosen, to take one or none: 不用标定 on its own row over a table
/// that scrolls past six rows, sorts by any column and, past eight, can be searched.
struct CalibrationTable: View {
  let rows: [CalibrationRow]
  let without: String
  @Binding var selection: String?
  @State private var order = [KeyPathComparator(\CalibrationRow.when, order: .reverse)]
  @State private var query = ""
  static let shownRows = 6, searchFrom = 8
  var body: some View {
    let found = CalibrationRow.filtered(rows, query).sorted(using: order)
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text("已有的标定").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        Text("\(rows.count) 个").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        Spacer(minLength: 8)
        if rows.count > Self.searchFrom {
          TextField("搜索标定：设备、日期", text: $query).textFieldStyle(.roundedBorder).controlSize(.small).frame(maxWidth: 180)
        }
      }.padding(.top, 4)
      // None of them: the film as its data sheet or the generic film converts it.
      Button {
        withAnimation(.easeOut(duration: 0.12)) { selection = nil }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: selection == nil ? "largecircle.fill.circle" : "circle").foregroundStyle(selection == nil ? Hardware.accent : Color.secondary)
          Text("不用标定").font(.system(size: 11.5, weight: selection == nil ? .semibold : .regular))
            .foregroundStyle(selection == nil ? AnyShapeStyle(Hardware.amberText) : AnyShapeStyle(.primary))
          Text(without).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityAddTraits(selection == nil ? .isSelected : [])
      Table(found, selection: $selection, sortOrder: $order) {
        TableColumn("标定", value: \.title) { r in Text(r.title).fontWeight(r.id == selection ? .semibold : .regular).lineLimit(1) }
          .width(min: 120, ideal: 190)
        TableColumn("类型", value: \.kind) { r in Text(r.kind) }.width(min: 34, ideal: 40)
        TableColumn("设备", value: \.device) { r in Text(r.device).lineLimit(1) }.width(min: 70, ideal: 140)
        TableColumn("日期", value: \.when) { r in Text(r.date).monospacedDigit() }.width(min: 70, ideal: 80)
        TableColumn("中性点", value: \.points) { r in Text("\(r.points)").monospacedDigit() }.width(min: 40, ideal: 48)
      }
      .font(.system(size: 11))
      .frame(height: Self.height(found.count))
      .accessibilityLabel("已有的标定")
      if found.isEmpty && !query.isEmpty {
        Text("没有符合「\(query)」的标定").font(.system(size: 10.5)).foregroundStyle(.secondary)
      }
    }
  }
  /// Tall enough for the rows up to six, then scrolling: its header and a row's height each.
  static func height(_ rows: Int) -> CGFloat { 28 + CGFloat(min(max(rows, 1), shownRows)) * 24 + 4 }
}
