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
  /// Sets the section back on its own; its key shows in the title row while there is one.
  var reset: (() -> Void)?
  let accessory: Accessory
  let content: Content
  @AppStorage private var open: Bool
  enum Level { case section, sub }

  init(
    _ title: String, key: String, open: Bool = true, info: String? = nil, symbol: String? = nil, forced: Bool = false,
    level: Level = .section, reset: (() -> Void)? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.reset = reset
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
        if let reset {
          Button(action: reset) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .medium))
          }.buttonStyle(.plain).foregroundStyle(.secondary)
            .help("把「\(title)」恢复默认，别的不动 · ⌘Z 撤销").accessibilityLabel("恢复\(title)")
            .transition(.opacity)
        }
        accessory
        if let info { InfoButton(text: info, about: title) }
      }
      if shown { content.transition(.opacity) }
    }
  }
}

/// A switch in a panel: its name on the left, the switch at the right edge before its ⓘ, as the
/// left panel's and System Settings' are, so the switches of both panels line up down one edge.
struct SwitchRow: View {
  let title: String
  @Binding var isOn: Bool
  var info: String?
  /// The switch alone greyed out; its ⓘ still opens.
  var off = false
  @Environment(\.isEnabled) private var enabled
  init(_ title: String, isOn: Binding<Bool>, info: String? = nil, off: Bool = false) {
    self.title = title
    _isOn = isOn
    self.info = info
    self.off = off
  }
  var body: some View {
    HStack(spacing: 6) {
      Text(title).font(.system(size: 12)).lineLimit(1).foregroundStyle(enabled && !off ? .primary : .secondary)
      Spacer(minLength: 4)
      Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Hardware.accent).disabled(off)
      // Without an ⓘ, its room kept, so this switch stands in line with those that have one.
      if let info { InfoButton(text: info, about: title) } else { Image(systemName: "info.circle").font(.system(size: 12)).hidden() }
    }
  }
}

extension PanelSection where Accessory == EmptyView {
  init(
    _ title: String, key: String, open: Bool = true, info: String? = nil, symbol: String? = nil, forced: Bool = false,
    level: Level = .section, reset: (() -> Void)? = nil, @ViewBuilder content: () -> Content
  ) {
    self.init(title, key: key, open: open, info: info, symbol: symbol, forced: forced, level: level, reset: reset, accessory: { EmptyView() }, content: content)
  }
}
