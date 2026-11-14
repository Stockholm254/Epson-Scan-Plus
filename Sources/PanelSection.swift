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
  /// What it is kept by: whether it is open, and where its column has it.
  let key: String
  @AppStorage private var open: Bool
  /// The column it can be moved in, when it is a section of one that can be arranged.
  @Environment(\.sectionArranger) private var arranger
  @State private var hovering = false
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
    self.key = key
    _open = AppStorage(wrappedValue: open, "panelSection." + key)
  }
  var shown: Bool { open || forced }
  /// The column's arranger, for a section of the column itself (not a part inside one).
  private var movable: SectionArranger? {
    guard level == .section, let arranger, arranger.column.defaults.contains(key) else { return nil }
    return arranger
  }
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
      // Its place in the column: a grip in the margin to drag it by, and a menu on the title row.
      .overlay(alignment: .leading) {
        if let arranger = movable {
          Image(systemName: "line.3.horizontal")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            .frame(width: 14, height: 20).contentShape(Rectangle())
            .offset(x: -16)
            .opacity(hovering ? 1 : 0)
            .onDrag {
              SectionArranger.dragging = (arranger.column, key)
              return NSItemProvider(object: key as NSString)
            }
            .help("拖动，把「\(title)」排到这一栏的别处；右键标题可以上移、下移或恢复默认顺序")
            .accessibilityHidden(true)
        }
      }
      .onHover { hovering = $0 }
      .contextMenu {
        if let arranger = movable {
          Button("上移「\(title)」", systemImage: "arrow.up") { arranger.move(key, by: -1) }.disabled(!arranger.canMove(key, by: -1))
          Button("下移「\(title)」", systemImage: "arrow.down") { arranger.move(key, by: 1) }.disabled(!arranger.canMove(key, by: 1))
          Divider()
          Button("恢复这一栏的默认顺序", systemImage: "arrow.counterclockwise") { arranger.reset() }.disabled(arranger.isDefault)
        }
      }
      .accessibilityActions {
        if let arranger = movable {
          Button("上移") { arranger.move(key, by: -1) }
          Button("下移") { arranger.move(key, by: 1) }
        }
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
      // On a second line where the panel is narrow, rather than cut: 「保留灯光红晕和真实红…」.
      Text(title).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(enabled && !off ? .primary : .secondary)
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
