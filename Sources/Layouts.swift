import SwiftUI

/// The first of two layouts of a row that fits the width it is given, as `ViewThatFits` picks one,
/// with only the one shown in the window. Each update of the window lays it out twice: at its size,
/// and at its smallest for the window's minimum size, where the full layout never fits. So
/// `ViewThatFits` took the compact one, then the full one again, at every update, taking their
/// AppKit controls out of the window and putting new ones in: under the single frame a dozen
/// buttons and two segmented controls at each step of a slider dragged, a third of the step's time.
///
/// Here the widest room a row is offered through one turn of the run loop decides: the full
/// layout while its own width fits, else the compact one, until the room is back to the full one's
/// width. Neither asks the window for room: the row gives way to a narrower window, and the compact
/// layout takes over.
struct WidthFit<Full: View, Compact: View>: View {
  private let full: Full
  private let compact: Compact
  init(@ViewBuilder full: () -> Full, @ViewBuilder compact: () -> Compact) {
    self.full = full()
    self.compact = compact()
  }
  @State private var compactShown = false
  /// What the layouts measured: kept out of the view's state, so measuring updates nothing.
  @State private var measured = Measured()
  final class Measured {
    /// The full layout's own width when last shown.
    var fullWidth: CGFloat = 0
    /// The widest room laid out in since the last choice.
    var room: CGFloat = 0
    var asked = false
  }
  var body: some View {
    let row = IdealWidth(measuresIdeal: !compactShown, measured: { ideal, room in laidOut(ideal: ideal, room: room) })
    return row {
      if compactShown { compact } else { full }
    }
  }
  /// Called as the row is laid out: the room offered, and once placed the shown layout's own width.
  private func laidOut(ideal: CGFloat?, room: CGFloat) {
    let m = measured
    if !compactShown, let ideal { m.fullWidth = ideal }
    m.room = max(m.room, room)
    guard !m.asked else { return }
    m.asked = true
    // Once this turn's layouts are done, and not while laying out.
    DispatchQueue.main.async {
      m.asked = false
      let room = m.room
      m.room = 0
      let wanted = compactShown ? (m.fullWidth <= 0 || room < m.fullWidth) : m.fullWidth > room + 0.5
      if wanted != compactShown { compactShown = wanted }
    }
  }
}

/// Lays out its one view as proposed, never wider than proposed. It tells `measured` each width it
/// is offered, and once placed the view's own width (as `ViewThatFits` measures a candidate along
/// the horizontal).
private struct IdealWidth: Layout {
  /// The compact layout's own width is not needed: only the room it has.
  let measuresIdeal: Bool
  let measured: (_ ideal: CGFloat?, _ room: CGFloat) -> Void
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let view = subviews.first else { return .zero }
    let size = view.sizeThatFits(proposal)
    guard let width = proposal.width, width.isFinite else { return size }
    measured(nil, width)
    return CGSize(width: min(size.width, width), height: size.height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let view = subviews.first else { return }
    view.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    if bounds.width.isFinite, bounds.width > 0 {
      measured(measuresIdeal ? view.sizeThatFits(ProposedViewSize(width: nil, height: bounds.height)).width : nil, max(bounds.width, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0))
    }
  }
}

/// The window's content filling what it is given, never smaller than `minimum`, which is what it
/// tells as its minimum without laying the content out. The window asks for its content's minimum
/// size at every update, and a frame of minimum width and height laid the whole window out again at
/// that size for it: a quarter of the main thread's time while a slider was dragged. On every page
/// and with the panels in or out the content's own minimum was this one.
struct WindowMinimum: Layout {
  var minimum: CGSize
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    CGSize(width: max(proposal.width ?? minimum.width, minimum.width), height: max(proposal.height ?? minimum.height, minimum.height))
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for view in subviews { view.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size)) }
  }
}

extension View {
  /// This view as a window's content, at least `minimum` (`WindowMinimum`).
  func windowMinimum(width: CGFloat, height: CGFloat) -> some View {
    WindowMinimum(minimum: CGSize(width: width, height: height)) { self }
  }
}
