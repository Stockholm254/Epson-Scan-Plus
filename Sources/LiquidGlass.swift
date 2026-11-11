import AppKit
import SwiftUI

/// SwiftUI's own Liquid Glass, with the macOS 26 SDK: glass that flows from one place to the next,
/// runs together with its neighbours like drops, and gives under a press. Built with an earlier
/// SDK, or with EPSON_SCAN_PLUS_NO_GLASS set, every part here draws what the app drew before,
/// through the run-time glass view or the console look.
enum Liquid {
  /// SwiftUI's glass is there to use.
  static var available: Bool {
    #if compiler(>=6.2)
      return Hardware.glass
    #else
      return false
    #endif
  }
  /// How a piece of glass moves when it flows, runs together or comes apart.
  /// The glass flowing from one place to the next; with Reduce Motion a short fade instead.
  static var flow: Animation {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.72)
  }
  /// From one module to another: the sidebar and inspector sliding, the pages cross-fading, in a
  /// third of a second with no overshoot, so modules changed quickly one after another never sway.
  /// Settings set at once (自动调整, 重置调整, a curve preset): the faders and the curve move to
  /// them, rather than jump, in a little over a quarter of a second.
  static var settle: Animation {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.12) : .snappy(duration: 0.28)
  }
  static var pageChange: Animation {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.32)
  }
}

/// What a piece of Liquid Glass is: clear (the picture seen almost unchanged through it) or
/// regular, tinted or not, giving under a press or not.
struct LiquidStyle {
  var clear = false
  var tint: Color?
  var interactive = false
  #if compiler(>=6.2)
    var glass: Glass {
      var g: Glass = clear ? .clear : .regular
      if let tint { g = g.tint(tint) }
      return interactive ? g.interactive() : g
    }
  #endif
}

extension View {
  /// Liquid Glass of `shape` behind this view. `id` names it within `namespace`, so that in a
  /// `LiquidGroup` it flows to wherever the same id appears next; `union` runs it together with the
  /// pieces of the same union into one. Without SwiftUI's glass, `fallback` instead.
  @ViewBuilder func liquid<S: Shape, F: View>(
    _ shape: S, _ style: LiquidStyle = LiquidStyle(), id: String? = nil, union: String? = nil, in namespace: Namespace.ID? = nil,
    @ViewBuilder fallback: (Self) -> F
  ) -> some View {
    #if compiler(>=6.2)
      if Hardware.glass {
        LiquidPiece(content: self, shape: shape, style: style, id: id, union: union, namespace: namespace)
      } else {
        fallback(self)
      }
    #else
      fallback(self)
    #endif
  }
}

#if compiler(>=6.2)
  private struct LiquidPiece<Content: View, S: Shape>: View {
    let content: Content
    let shape: S
    let style: LiquidStyle
    let id: String?
    let union: String?
    let namespace: Namespace.ID?
    var body: some View {
      if let namespace {
        content.glassEffect(style.glass, in: shape).glassEffectUnion(id: union, namespace: namespace).glassEffectID(id, in: namespace)
      } else {
        content.glassEffect(style.glass, in: shape)
      }
    }
  }
#endif

extension View {
  /// Names this view's glass (a glass key's, say) within `namespace`, so a drop shown beside it
  /// in a `LiquidGroup` grows out of it and runs back into it; without SwiftUI's glass, nothing.
  @ViewBuilder func liquidName(_ id: String, in namespace: Namespace.ID) -> some View {
    #if compiler(>=6.2)
      if Hardware.glass {
        glassEffectID(id, in: namespace)
      } else {
        self
      }
    #else
      self
    #endif
  }
}

/// Pieces of glass that run together when they come within `spacing` of each other and flow
/// between places as one material; without SwiftUI's glass, just the content.
struct LiquidGroup<Content: View>: View {
  var spacing: CGFloat? = nil
  @ViewBuilder var content: Content
  var body: some View {
    #if compiler(>=6.2)
      if Hardware.glass {
        GlassEffectContainer(spacing: spacing) { content }
      } else {
        content
      }
    #else
      content
    #endif
  }
}

/// The picture continued past its edges, blurred, darkened in the dark appearance and lightened in
/// the light one, under the glass around it, as the system extends a picture under a sidebar.
struct PictureExtension: View {
  let image: CGImage?
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    if Hardware.glass, let image {
      GeometryReader { g in
        Image(decorative: image, scale: 1).resizable().interpolation(.low).scaledToFill()
          .frame(width: g.size.width, height: g.size.height).clipped()
          .blur(radius: 48, opaque: true).saturation(1.25).brightness(scheme == .dark ? -0.22 : 0.18)
      }.allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}

extension View {
  /// The one action a bar or panel leads to, as the system draws it: prominent Liquid Glass with
  /// the macOS 26 SDK, a prominent bordered button built with an earlier one, in `tint`.
  @ViewBuilder func leadingAction(_ tint: Color = Hardware.accent) -> some View {
    #if compiler(>=6.2)
      buttonStyle(.glassProminent).tint(tint)
    #else
      buttonStyle(.borderedProminent).tint(tint)
    #endif
  }
  /// A key floating over the picture, as the system draws one: Liquid Glass with the macOS 26 SDK, a
  /// bordered button built with an earlier one; one that is `on` filled with the accent.
  @ViewBuilder func glassAction(on: Bool = false) -> some View {
    if on {
      leadingAction()
    } else {
      #if compiler(>=6.2)
        buttonStyle(.glass)
      #else
        buttonStyle(.bordered)
      #endif
    }
  }
}
