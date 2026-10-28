import AppKit
import SwiftUI

/// The module selector: a knurled rotary switch under a glass cap, whose pointer clicks round to
/// ① 采集, ② 去色罩 or ③ 去漏光, each engraved beside its stop with a lamp over the one it is on.
/// Click a name to go there, or the knob to turn it on to the next.
struct ModuleDial: View {
  @Binding var page: AppModel.Page
  /// The pointer's angle at each stop, in degrees from straight up.
  static let angles: [Double] = [-50, 0, 50]
  var body: some View {
    let pages = AppModel.Page.allCases
    let index = pages.firstIndex(of: page) ?? 0
    HStack(spacing: 8) {
      knob(angle: Self.angles[index])
        .onTapGesture { set(pages[(index + 1) % pages.count]) }
        .help("转到下一个模块（⌥⌘1–3 直接转到）")
      HStack(spacing: 2) {
        ForEach(pages, id: \.self) { p in
          Button {
            set(p)
          } label: {
            VStack(spacing: 3) {
              Circle().fill(p == page ? Hardware.amber : Color(white: 0.24)).frame(width: 5, height: 5)
                .shadow(color: p == page ? Hardware.amber.opacity(0.85) : .clear, radius: 3)
              // Engraved: dark above the letters, a faint light edge below.
              Text("\(p.number) \(p.rawValue)").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(p == page ? Hardware.amber : Color(white: 0.6))
                .shadow(color: .black.opacity(0.75), radius: 0, x: 0, y: -0.6)
                .shadow(color: .white.opacity(0.07), radius: 0, x: 0, y: 0.6)
            }.padding(.horizontal, 6).padding(.vertical, 2).contentShape(Rectangle())
          }.buttonStyle(.plain).help(p.help)
        }
      }
    }
    .padding(.horizontal, Hardware.glass ? 10 : 0).padding(.vertical, Hardware.glass ? 3 : 0)
    .background {
      // In the glass look the dial sits in a pane of glass, its lamps shining through.
      if Hardware.glass { SystemGlassBackground(capsule: true, radius: 20, tint: NSColor(white: 0, alpha: 0.22)) }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("模块")
    .accessibilityValue("\(page.number) \(page.rawValue)")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: set(pages[min(index + 1, pages.count - 1)])
      case .decrement: set(pages[max(index - 1, 0)])
      @unknown default: break
      }
    }
  }
  /// The knob: a knurled skirt and a domed cap lit from the top left, which stay lit from there,
  /// and the knurling and the pointer, which turn.
  func knob(angle: Double) -> some View {
    ZStack {
      Circle().fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing))
      ZStack {
        ForEach(0..<36, id: \.self) { i in
          Rectangle().fill(Color.black.opacity(0.5)).frame(width: 0.8, height: 3.4).offset(y: -13.1)
            .rotationEffect(.degrees(Double(i) * 10))
        }
      }.rotationEffect(.degrees(angle))
      Circle()
        .fill(RadialGradient(
          colors: [Color(white: 0.44), Color(white: 0.19)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: 14))
        .frame(width: 21, height: 21)
        .overlay(Circle().stroke(Color.white.opacity(0.13), lineWidth: 0.5))
      // A glass cap over it, catching the light from the top left.
      Circle()
        .fill(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.04), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        .frame(width: 21, height: 21)
      Ellipse().fill(Color.white.opacity(0.55)).frame(width: 7, height: 3.5).rotationEffect(.degrees(-30)).offset(x: -4.5, y: -5.5)
      Capsule().fill(Hardware.amber).frame(width: 2.2, height: 8).offset(y: -5.6)
        .shadow(color: Hardware.amber.opacity(0.6), radius: 2)
        .rotationEffect(.degrees(angle))
    }
    .frame(width: 30, height: 30)
    .shadow(color: .black.opacity(0.6), radius: 2, y: 1.5)
    .animation(.spring(response: 0.28, dampingFraction: 0.55), value: angle)
    .contentShape(Circle())
  }
  /// Turns to `p`, with a detent felt on a Force Touch trackpad.
  func set(_ p: AppModel.Page) {
    guard p != page else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    page = p
  }
}
