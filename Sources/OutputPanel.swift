import AppKit
import SwiftUI

/// The strip's mark on a frame for exporting: waiting, being written, written as it is now, or
/// changed since. Small, in the frame's corner, and only in ② where frames are exported.
struct ExportMarkView: View {
  let mark: ExportMark
  /// The file and when, for the tooltip.
  var note: String? = nil
  var body: some View {
    ZStack {
      switch mark {
      case .notExported:
        EmptyView()
      case .waiting:
        Image(systemName: "circle.dotted").foregroundStyle(.white.opacity(0.75))
          .transition(.opacity)
      case .writing:
        // Still: a mark that pulsed had SwiftUI draw the whole strip again every frame of an export.
        Image(systemName: "arrow.up.circle.fill").foregroundStyle(.white, Hardware.accent)
          .transition(.scale(scale: 0.5).combined(with: .opacity))
      case .exported:
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, ExportMarkView.green)
          .transition(.scale(scale: 0.4).combined(with: .opacity))
      case .changed:
        Image(systemName: "pencil.circle.fill").foregroundStyle(.black, Hardware.amber)
          .transition(.scale(scale: 0.6).combined(with: .opacity))
      }
    }
    .font(.system(size: 13)).symbolRenderingMode(.palette)
    // A dark ring rather than a shadow: a shadow is drawn off screen, for every mark, every time
    // the strip is drawn.
    .background { if mark != .notExported { Circle().fill(.black.opacity(0.45)).padding(-1.5) } }
    .animation(.spring(response: 0.32, dampingFraction: 0.62), value: mark)
    .help(note.map { help + "\n" + $0 } ?? help)
    .accessibilityLabel(help)
  }
  static let green = Color(red: 0.3, green: 0.72, blue: 0.4)
  var help: String {
    switch mark {
    case .notExported: return ""
    case .waiting: return "等着导出"
    case .writing: return "正在导出"
    case .exported: return "已导出，导出后没有再改"
    case .changed: return "导出后又改过调整：再导出一次才是现在的样子"
    }
  }
}

/// The contact sheet as it will come out, from the strip's pictures: the paper, the strips or the
/// grid, the frames each in its place, the title and numbers as bars. Drawn with the sheet's own
/// geometry, so what it shows is what is written, and the frames glide to their new places as
/// the layout changes.
struct SheetPreview: View {
  let frames: [FilmFrame]
  let thumbnails: [UUID: CGImage]
  let layout: ContactSheet.Layout
  /// The roll's film in the heading, when the sheet shows it.
  var film: (look: NewProjectSheet.Look, gauge: FilmStock.Gauge)? = nil

  /// A frame's shape as it prints: its picture's, which is turned as the frame is; turned back
  /// to the film's way when the sheet keeps it.
  private func quarterTurns(_ f: FilmFrame) -> Int { ((f.adjustments.rotation % 4) + 4) % 4 }
  /// Its shape only, at one size for every frame: the strip's pictures are not all as big, and
  /// the sheet prints every frame at the film's scale.
  private func size(_ f: FilmFrame) -> CGSize {
    let s = thumbnails[f.id].map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 3, height: 2)
    let k = 1000 / max(1, max(s.width, s.height))
    let fitted = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
    return !layout.followRotation && quarterTurns(f) % 2 == 1 ? CGSize(width: fitted.height, height: fitted.width) : fitted
  }
  /// Width over height of the sheet, for the box it is shown in.
  static func aspect(_ frames: [FilmFrame], thumbnails: [UUID: CGImage], layout: ContactSheet.Layout) -> CGFloat {
    let preview = SheetPreview(frames: frames, thumbnails: thumbnails, layout: layout)
    let g = preview.geometry
    return g.size.width / max(1, g.size.height)
  }
  private var shown: [FilmFrame] { Array(frames.prefix(48)) }
  private var geometry: ContactSheet.Geometry {
    let sizes = shown.map(size)
    let cell = ContactSheet.cell(for: sizes.isEmpty ? [CGSize(width: 1000, height: 667)] : sizes)
    return ContactSheet.geometry(count: max(1, shown.count), cell: cell, layout: layout, sizes: sizes.isEmpty ? nil : sizes)
  }
  var body: some View {
    let shown = self.shown
    let g = geometry
    let paper = layout.whitePaper ? Color(red: 0.96, green: 0.955, blue: 0.94) : Color(white: 0.04)
    let ink = layout.whitePaper ? Color(white: 0.18) : Color(white: 0.82)
    return GeometryReader { box in
      let k = min(box.size.width / max(1, g.size.width), box.size.height / max(1, g.size.height))
      let dx = (box.size.width - g.size.width * k) / 2, dy = (box.size.height - g.size.height * k) / 2
      let place = { (r: CGRect) -> CGRect in CGRect(x: dx + r.minX * k, y: dy + r.minY * k, width: r.width * k, height: r.height * k) }
      ZStack(alignment: .topLeading) {
        let sheet = place(CGRect(origin: .zero, size: g.size))
        Rectangle().fill(paper)
          .overlay(Rectangle().strokeBorder(Color.white.opacity(layout.whitePaper ? 0 : 0.16), lineWidth: 0.5))
          .frame(width: sheet.width, height: sheet.height).position(x: sheet.midX, y: sheet.midY)
          .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        if let f = g.film, let film {
          let r = place(f)
          FilmObject(look: film.look, gauge: film.gauge).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
        }
        if let t = g.title {
          let r = place(t)
          Capsule().fill(ink.opacity(0.55))
            .frame(width: r.width * 0.45, height: max(1.5, r.height * 0.5))
            .position(x: r.minX + r.width * 0.225, y: r.midY)
        }
        if layout.showsSprockets {
          ForEach(Array(g.strips.enumerated()), id: \.offset) { _, s in
            let r = place(s)
            Rectangle().fill(Color(white: 0.05)).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
          }
        }
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, f in
          if i < g.cells.count {
            let r = place(g.cells[i])
            picture(f, fitting: r.size)
              .position(x: r.midX, y: r.midY)
            if layout.numbers, i < g.labels.count, layout.style == .grid || !layout.showsSprockets {
              let l = place(g.labels[i])
              Capsule().fill(ink.opacity(0.5)).frame(width: max(2, l.height * 0.9), height: max(1, l.height * 0.28))
                .position(x: l.midX, y: l.midY)
            }
          }
        }
      }
    }
    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: layout)
    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: shown.map(\.id))
    .accessibilityElement()
    .accessibilityLabel("接触表的样子：\(shown.count) 张，" + (layout.style == .strips ? "胶片条" : "网格"))
  }
  @ViewBuilder private func picture(_ f: FilmFrame, fitting box: CGSize) -> some View {
    let s = size(f)
    let fit = min(box.width / max(1, s.width), box.height / max(1, s.height))
    let w = s.width * fit, h = s.height * fit
    if let cg = thumbnails[f.id] {
      // The picture as the strip shows it, turned back when the sheet keeps the film's way.
      let back = layout.followRotation ? 0 : quarterTurns(f)
      Image(decorative: cg, scale: 1).resizable()
        .frame(width: back % 2 == 1 ? h : w, height: back % 2 == 1 ? w : h)
        .rotationEffect(.degrees(Double(-90 * back)))
        .frame(width: w, height: h)
        .opacity(f.enabled ? 1 : 0.35)
    } else {
      Rectangle().fill(Color(white: 0.22)).frame(width: w, height: h)
    }
  }
}

/// The status line's progress while exporting: how many of how many, the frame being written,
/// and the key that stops after it.
struct ExportProgressBar: View {
  @Gated var m: AppModel
  var body: some View {
    let p = m.exportProgress
    HStack(spacing: 8) {
      // Not animated: each frame of a counting or easing animation drew the status line again.
      Text(p.label).font(.system(size: 11)).monospacedDigit().lineLimit(1)
      ProgressView(value: p.fraction).frame(width: 90)
        .accessibilityLabel("导出进度").accessibilityValue(p.label)
      Button("停止") { m.stopExports() }.controlSize(.small)
        .help("写完正在写的这张就停；写好的文件留着")
    }
    .transition(.move(edge: .trailing).combined(with: .opacity))
  }
}
