import AppKit
import SwiftUI

/// The module selector: a knurled rotary switch under a glass cap, whose pointer clicks round to
/// ① 采集, ② 去色罩 or ③ 去漏光, each engraved beside its stop with a lamp over the one it is on.
/// Click a name to go there, or the knob to turn it on to the next. With SwiftUI's glass a drop of
/// amber glass lies under the module it is on and flows along to the next as the dial turns.
struct ModuleDial: View {
  @Binding var page: AppModel.Page
  @Namespace private var glass
  @Environment(\.colorScheme) private var scheme
  /// The pointer's angle at each stop, in degrees from straight up.
  static let angles: [Double] = [-50, 0, 50]
  var body: some View {
    let pages = AppModel.Page.allCases
    let index = pages.firstIndex(of: page) ?? 0
    let light = scheme == .light
    HStack(spacing: 8) {
      knob(angle: Self.angles[index])
        .onTapGesture { set(pages[(index + 1) % pages.count]) }
        .help("转到下一个模块（⌥⌘1–3 直接转到）")
      LiquidGroup(spacing: 14) {
        HStack(spacing: 2) {
          ForEach(pages, id: \.self) { p in
            Button {
              set(p)
            } label: {
              let name = VStack(spacing: 3) {
                Circle().fill(p == page ? Hardware.amber : Color(white: light ? 0.72 : 0.24)).frame(width: 5, height: 5)
                  .shadow(color: p == page ? Hardware.amber.opacity(0.85) : .clear, radius: 3)
                // Engraved: dark above the letters, a faint light edge below.
                Text("\(p.number) \(p.rawValue)").font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(p == page ? Hardware.amberText : Color(white: light ? 0.32 : 0.6))
                  .shadow(color: .black.opacity(light ? 0.12 : 0.75), radius: 0, x: 0, y: -0.6)
                  .shadow(color: .white.opacity(light ? 0.8 : 0.07), radius: 0, x: 0, y: 0.6)
              }.padding(.horizontal, 8).padding(.vertical, 2)
              // The drop is the name's own glass, so the name lies on it, not under it.
              if p == page && Liquid.available {
                name.liquid(Capsule(), LiquidStyle(tint: Hardware.amber.opacity(0.1)), id: "dial", in: glass) { $0 }
                  .contentShape(Rectangle())
              } else {
                name.contentShape(Rectangle())
              }
            }.buttonStyle(.plain).help(p.help)
          }
        }
      }.animation(Liquid.flow, value: page)
    }
    .padding(.horizontal, Hardware.glass ? 10 : 0).padding(.vertical, Hardware.glass ? 3 : 0)
    .background {
      // In the glass look the dial sits in a pane of glass, its lamps shining through; with
      // SwiftUI's glass the drop is the glass, on the window.
      if Hardware.glass && !Liquid.available { SystemGlassBackground(capsule: true, radius: 20, tint: NSColor(white: light ? 1 : 0, alpha: 0.22)) }
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
    // On light glass of bright satin aluminium.
    let light = scheme == .light
    return ZStack {
      Circle().fill(LinearGradient(colors: light ? [Color(white: 0.97), Color(white: 0.64)] : [Color(white: 0.36), Color(white: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing))
      ZStack {
        ForEach(0..<36, id: \.self) { i in
          Rectangle().fill(Color.black.opacity(light ? 0.28 : 0.5)).frame(width: 0.8, height: 3.4).offset(y: -13.1)
            .rotationEffect(.degrees(Double(i) * 10))
        }
      }.rotationEffect(.degrees(angle))
      Circle()
        .fill(RadialGradient(
          colors: light ? [Color(white: 1), Color(white: 0.78)] : [Color(white: 0.44), Color(white: 0.19)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: 14))
        .frame(width: 21, height: 21)
        .overlay(Circle().stroke(light ? Color.black.opacity(0.14) : Color.white.opacity(0.13), lineWidth: 0.5))
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
    .shadow(color: .black.opacity(light ? 0.3 : 0.6), radius: 2, y: 1.5)
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
