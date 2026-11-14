import AppKit
import SwiftUI

/// The film strip's size, as its top edge is dragged: its frames' height in points, their width
/// 7 : 5 of it, the film and the room around them as before.
enum StripSize {
  /// As the strip was before it could be dragged: frames 84 × 60, the strip 114 points tall.
  static let standard = 60.0
  static let range = 40.0...200.0
  static func clamped(_ h: Double) -> Double { min(range.upperBound, max(range.lowerBound, h)) }
  /// A frame's width for its height.
  static func width(_ h: CGFloat) -> CGFloat { (h * 1.4).rounded() }
  /// The strip's height for its frames': the film's edges, the edge print and the room around.
  static func stripHeight(_ h: CGFloat) -> CGFloat { h + 54 }
  /// The frames' height with the strip's top edge dragged `dy` points (down positive) from where
  /// it was with frames `from` tall: whole points, in the range, and no taller than `tallest`.
  static func dragged(from: Double, by dy: Double, tallest: Double = range.upperBound) -> Double {
    min(max(range.lowerBound, tallest), clamped((from - dy).rounded()))
  }
  /// The tallest frames a window `height` points tall takes: the strip at most four tenths of it,
  /// so the picture keeps the rest.
  static func tallest(window height: Double) -> Double { max(range.lowerBound, height * 0.4 - 54) }
  /// The edge print's size: a little larger with larger frames.
  static func edgePrint(_ h: CGFloat) -> CGFloat { 9 + min(2, max(0, (h - standard) / 70)) }
}

/// The film strip with its top edge to drag, as Lightroom's and Capture One's filmstrips have:
/// up for larger frames, down for smaller, a double click back to the size it had. `content` is
/// given the frames' height; while the edge is dragged only the strip is drawn again, not the
/// window, and the height is kept when it is let go.
struct StripResizer<Content: View>: View {
  @ObservedObject var preferences: Preferences
  let content: (CGFloat) -> Content
  @State private var drag: (from: Double, now: Double)?
  @State private var hovering = false
  var height: Double { drag?.now ?? preferences.stripFrameHeight }
  var body: some View {
    content(CGFloat(height)).overlay(alignment: .top) { edge }
  }
  /// The strip's top, between the picture and the film: the resize pointer on it, and a grabber
  /// while the pointer is there or it is dragged.
  var edge: some View {
    ZStack(alignment: .top) {
      Color.clear
      Capsule().fill(Color.secondary.opacity(0.55)).frame(width: 36, height: 3).padding(.top, 1)
        .opacity(hovering || drag != nil ? 1 : 0)
    }
    .frame(height: 7).contentShape(Rectangle())
    .pointerStyle(.rowResize)
    .onHover { hovering = $0 }
    // In the window's coordinates: the edge moves with the strip as it is dragged.
    .gesture(
      DragGesture(minimumDistance: 1, coordinateSpace: .global)
        .onChanged { d in
          let from = drag?.from ?? preferences.stripFrameHeight
          let window = NSApp.keyWindow?.contentLayoutRect.height ?? 900
          drag = (from, StripSize.dragged(from: from, by: Double(d.translation.height), tallest: StripSize.tallest(window: window)))
        }
        .onEnded { _ in
          if let now = drag?.now, now != preferences.stripFrameHeight { preferences.stripFrameHeight = now }
          drag = nil
        }
    )
    .onTapGesture(count: 2) { preferences.stripFrameHeight = StripSize.standard }
    .help("上下拖动调节胶片条的高度；双击恢复原来的大小")
    .accessibilityElement()
    .accessibilityLabel("胶片条高度")
    .accessibilityValue("画面高 \(Int(height)) 点")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: preferences.stripFrameHeight = StripSize.clamped(preferences.stripFrameHeight + 10)
      case .decrement: preferences.stripFrameHeight = StripSize.clamped(preferences.stripFrameHeight - 10)
      @unknown default: break
      }
    }
  }
}
