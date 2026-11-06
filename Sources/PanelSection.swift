import SwiftUI

/// A section of a panel that folds: its title with a chevron, what stays at hand while it is folded
/// (a switch, a readout) and its ⓘ on the right, its controls under it. Whether it is open is kept
/// per section, so the panel opens as it was left; `forced` holds it open while it is in use.
struct PanelSection<Accessory: View, Content: View>: View {
  let title: String
  var info: String?
  var symbol: String?
  var forced = false
  var level = Level.section
  let accessory: Accessory
  let content: Content
  @AppStorage private var open: Bool
  enum Level { case section, sub }

  init(
    _ title: String, key: String, open: Bool = true, info: String? = nil, symbol: String? = nil, forced: Bool = false,
    level: Level = .section, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.info = info
    self.symbol = symbol
    self.forced = forced
    self.level = level
    self.accessory = accessory()
    self.content = content()
    _open = AppStorage(wrappedValue: open, "panelSection." + key)
  }
  var shown: Bool { open || forced }
  var body: some View {
    VStack(alignment: .leading, spacing: level == .section ? 10 : 7) {
      HStack(spacing: 6) {
        Button {
          withAnimation(.snappy(duration: 0.22)) { open.toggle() }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right")
              .font(.system(size: level == .section ? 10 : 9, weight: .semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(shown ? 90 : 0))
              .frame(width: 10)
            if let symbol { Image(systemName: symbol).foregroundStyle(Hardware.amberText) }
            Text(title).font(.system(size: level == .section ? 13 : 11, weight: level == .section ? .semibold : .medium))
              .lineLimit(1)
          }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(forced)
        .help(shown ? "收起" : "展开")
        .accessibilityLabel(title).accessibilityValue(shown ? "已展开" : "已收起")
        Spacer(minLength: 6)
        accessory
        if let info { InfoButton(text: info) }
      }
      if shown { content.transition(.opacity) }
    }
  }
}

extension PanelSection where Accessory == EmptyView {
  init(
    _ title: String, key: String, open: Bool = true, info: String? = nil, symbol: String? = nil, forced: Bool = false,
    level: Level = .section, @ViewBuilder content: () -> Content
  ) {
    self.init(title, key: key, open: open, info: info, symbol: symbol, forced: forced, level: level, accessory: { EmptyView() }, content: content)
  }
}
