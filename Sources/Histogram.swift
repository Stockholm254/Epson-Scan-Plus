import CoreGraphics
import Foundation
import SwiftUI

/// How a picture's values fall, channel by channel, from black to full: the counts in equal steps,
/// the share of each channel at full (clipped: light past it is lost), and where its brightest half
/// percent begins, as a fraction of full.
struct Histogram: Equatable {
  /// Red, green and blue, each so many counts from black to full.
  var counts: [[Int]]
  var clipped: RGB
  var top: RGB
  /// Values in proportion to the light, a RAW's photosites; otherwise an encoded picture's.
  var linear: Bool

  /// From counts in fine equal steps per channel, the last of them full, shown in `bins` steps.
  init(fine: [[Int]], bins: Int, linear: Bool) {
    let n = fine[0].count
    counts = fine.map { f in (0..<bins).map { b in f[(b * n / bins)..<((b + 1) * n / bins)].reduce(0, +) } }
    clipped = RGB(fine.map { Double($0[n - 1]) / Double(max(1, $0.reduce(0, +))) })
    top = RGB(fine.map { f in
      let want = Double(f.reduce(0, +)) * 0.995
      var run = 0
      for (i, c) in f.enumerated() {
        run += c
        if Double(run) >= want { return Double(i + 1) / Double(n) }
      }
      return 1
    })
    self.linear = linear
  }

  /// A picture as it shows, 8 bits a channel, read at no more than 256 pixels across without
  /// smoothing, so a clipped highlight still reads as clipped.
  static func picture(_ image: CGImage) -> Histogram {
    let k = min(1, 256 / Double(max(image.width, image.height)))
    let w = max(1, Int(Double(image.width) * k)), h = max(1, Int(Double(image.height) * k))
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { raw in
      guard let ctx = CGContext(
        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: ImagePipeline.shared.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      ctx.interpolationQuality = .none
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var fine = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
    for i in stride(from: 0, to: px.count, by: 4) {
      for c in 0..<3 { fine[c][Int(px[i + c])] += 1 }
    }
    return Histogram(fine: fine, bins: 64, linear: false)
  }

  /// An uncompressed ARW's photosites as the sensor measured them, less black, over the range up to
  /// white: before any interpolation, white balance or curve, so full is where the sensor stopped
  /// counting. Every other cell of the mosaic each way. Nil for any other file.
  static func sensor(_ url: URL) -> Histogram? {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let raw = SensorRaw(data) else { return nil }
    let n = 1024
    var fine = [[Int]](repeating: [Int](repeating: 0, count: n), count: 3)
    data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      let samples = bytes.baseAddress!.advanced(by: raw.offset)
      for y in stride(from: 0, to: raw.height - 1, by: 4) {
        for x in stride(from: 0, to: raw.width - 1, by: 4) {
          for k in 0..<4 {
            let at = (y + k / 2) * raw.width + x + k % 2
            let s = Int(samples.loadUnaligned(fromByteOffset: 2 * at, as: UInt16.self).littleEndian)
            let v = Double(s - raw.black[k]) / Double(max(1, raw.white - raw.black[k]))
            fine[raw.pattern[k]][min(n - 1, max(0, Int(v * Double(n))))] += 1
          }
        }
      }
    }
    return Histogram(fine: fine, bins: 128, linear: true)
  }
}

/// Where a frame's tones lie against what a screen shows of them (`ImagePipeline.toneRange`): each
/// channel as the conversion takes it into its ends, on the print's straight line (the levels'
/// black at 0, their white at 1, log exposure in between, and past them as far as the negative
/// goes), as shares of the frame in equal steps over `domain`, the first and last holding what lies
/// beyond; and the part of that a screen shows with gradation, from `black` (at or below it a
/// channel shows black) to `white` (from it on a channel shows white), through the ends, the
/// midtone and the curves; nil where the screen never gets there.
struct ToneRange: Equatable {
  var counts: [[Double]]
  var domain: ClosedRange<Double>
  var black: Double?, white: Double?
  /// A stop of print exposure on that scale; nil for a positive, whose scale is not log exposure.
  var stop: Double?
  /// Shares of the frame: a channel past the white, a channel white on screen, one black on screen;
  /// the last two as the scale puts them, or counted on the picture as shown
  /// (`ImagePipeline.screenShares`), which takes in what comes after the ends.
  var pastWhite: Double, atWhite: Double, atBlack: Double
  /// Where the brightest 0.1% lie, in their brightest channel; the darkest 0.1%, in their darkest.
  var brightest: Double
  var darkest: Double = 0
  /// The counts as finely as they were made (`fine` steps over `fineDomain`, the first and last
  /// holding what lies beyond), for a view of a narrower stretch than `domain`: the levels' black
  /// to white, which `counts` covers in only a third or so of its steps.
  var fine: [[Double]] = []
  var fineDomain: ClosedRange<Double> = 0...1
  /// The picture as shown, each channel in 256 steps from black to white, shares of the frame
  /// (`ImagePipeline.screenCounts`): everything the grading does, the curves too. Empty until counted.
  var screen: [[Double]] = []
}

/// A frame's histogram as the screen shows it (`ToneRange.screen`): each channel from black at the
/// left to white at the right, everything the grading does counted in, so every slider moves it;
/// the end steps, pure black and pure white, marked when anything lands there. On a square-root
/// scale, so a few highlights still show beside the midtones' thousands. Before it is counted, the
/// tones on the print's straight line as they go into the ends (`ToneRange.counts`).
struct ToneRangeView: View {
  let range: ToneRange
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Canvas { ctx, size in
        if range.screen.count == 3 { shown(ctx, size); return }
        let d = range.domain
        func x(_ q: Double) -> CGFloat { size.width * CGFloat((q - d.lowerBound) / (d.upperBound - d.lowerBound)) }
        let from = x(range.black ?? d.lowerBound), to = x(range.white ?? d.upperBound)
        ctx.fill(Path(CGRect(x: from, y: 0, width: max(0, to - from), height: size.height)), with: .color(.white.opacity(0.08)))
        let bins = range.counts[0].count
        let peak = max(1e-9, range.counts.flatMap { $0.dropFirst().dropLast() }.max() ?? 1)
        var lit = ctx
        lit.blendMode = .plusLighter
        for c in 0..<3 {
          var p = Path()
          p.move(to: CGPoint(x: 0, y: size.height))
          for b in 0..<bins {
            let y = size.height * (1 - 0.92 * CGFloat(min(1, (range.counts[c][b] / peak).squareRoot())))
            p.addLine(to: CGPoint(x: size.width * CGFloat(b) / CGFloat(bins), y: y))
            p.addLine(to: CGPoint(x: size.width * CGFloat(b + 1) / CGFloat(bins), y: y))
          }
          p.addLine(to: CGPoint(x: size.width, y: size.height))
          p.closeSubpath()
          lit.fill(p, with: .color(HistogramView.colours[c].opacity(0.45)))
        }
        // What shows black or white on screen, dimmed.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: from, height: size.height)), with: .color(.black.opacity(0.5)))
        ctx.fill(Path(CGRect(x: to, y: 0, width: max(0, size.width - to), height: size.height)), with: .color(.black.opacity(0.5)))
        func mark(_ q: Double, _ label: String, dashed: Bool) {
          guard d.contains(q) else { return }
          let at = x(q)
          ctx.stroke(Path { $0.move(to: CGPoint(x: at, y: 9)); $0.addLine(to: CGPoint(x: at, y: size.height)) },
            with: .color(.white.opacity(dashed ? 0.3 : 0.45)), style: StrokeStyle(lineWidth: 0.6, dash: dashed ? [2, 2] : []))
          ctx.draw(Text(label).font(.system(size: 8)).foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: at, y: 4))
        }
        mark(0, "黑", dashed: false)
        mark(1, "白", dashed: false)
        if let stop = range.stop, x(1 + stop) - x(1) >= 14 {
          for n in 1...4 { mark(1 + Double(n) * stop, "+\(n)", dashed: true) }
        }
      }
      .frame(height: 64)
      .padding(4).background(PlotScreen())
      .accessibilityElement().accessibilityLabel("直方图").accessibilityValue(lines.joined(separator: "；"))
      // As many lines as the frame has, each one line: the sliders under them stay where they are
      // while one of them is dragged and the figures change.
      VStack(alignment: .leading, spacing: 1) {
        ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element).lineLimit(1).minimumScaleFactor(0.7) }
      }.font(.system(size: 11)).foregroundStyle(.secondary)
    }
  }
  /// The picture as shown, 0 to 255.
  private func shown(_ ctx: GraphicsContext, _ size: CGSize) {
    let bins = range.screen[0].count
    guard bins > 2 else { return }
    let peak = max(1e-9, range.screen.flatMap { $0.dropFirst().dropLast() }.max() ?? 1)
    var lit = ctx
    lit.blendMode = .plusLighter
    for c in 0..<3 {
      var p = Path()
      p.move(to: CGPoint(x: 0, y: size.height))
      for b in 0..<bins {
        let y = size.height * (1 - 0.92 * CGFloat(min(1, (range.screen[c][b] / peak).squareRoot())))
        p.addLine(to: CGPoint(x: size.width * CGFloat(b) / CGFloat(bins), y: y))
        p.addLine(to: CGPoint(x: size.width * CGFloat(b + 1) / CGFloat(bins), y: y))
      }
      p.addLine(to: CGPoint(x: size.width, y: size.height))
      p.closeSubpath()
      lit.fill(p, with: .color(HistogramView.colours[c].opacity(0.45)))
    }
    // Pure black and pure white, where anything lands on them: a bar at that end.
    for (end, at) in [(0, CGFloat(0)), (bins - 1, size.width - 3)] where range.screen.contains(where: { $0[end] > 0.0005 }) {
      ctx.fill(Path(CGRect(x: at, y: 0, width: 3, height: size.height)), with: .color(.white.opacity(0.55)))
    }
    for (q, label) in [(0.0, "0"), (0.5, "128"), (1.0, "255")] {
      let x = min(max(size.width * CGFloat(q), 8), size.width - 10)
      ctx.draw(Text(label).font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)), at: CGPoint(x: x, y: 5))
    }
  }
  private func percent(_ v: Double) -> String {
    v < 0.0001 ? "0" : v < 0.01 ? String(format: "%.2f%%", v * 100) : String(format: "%.1f%%", v * 100)
  }
  /// How far past white the frame goes, where its brightest lie (a negative's, on the scale of
  /// print exposure), and what shows white or black: the same lines whatever the figures.
  var lines: [String] {
    var lines = ["白点以上 \(percent(range.pastWhite))"]
    if let stop = range.stop {
      lines.append(range.brightest > 1
        ? String(format: "最亮的 0.1%% 在白点以上 %.1f 档", (range.brightest - 1) / stop) : "最亮的 0.1% 不到白点")
    }
    return lines + ["屏幕上纯白 \(percent(range.atWhite))，纯黑 \(percent(range.atBlack))"]
  }
}

/// The levels' histogram: the frame's tones on the scale the black and white points are set on
/// (the automatic ends' black at 0 and white at 1, what lies past them in the end steps), the black
/// point, the midtone's mid-grey and the white point marked, and what they send to pure black or
/// white dimmed. The marks drag, nearest first. Worked out from `ToneRange`, whose counts are past
/// the black and white points (`q = (q0 - black) / (white - black)`), so it costs no render.
struct LevelsHistogram: View {
  enum Mark { case black, midtone, white }
  let range: ToneRange
  let black: Double, white: Double, midtone: Double
  var set: (Mark, Double) -> Void
  @State private var dragging: Mark?
  /// The marks as dragged, drawn at once: the values given come with the window's update, at
  /// most ten a second during a drag (`WindowGate`). Let go when those arrive.
  @State private var draft: [Mark: Double] = [:]
  /// The channels drawn: all three as light added together (0), or red, green or blue alone, as
  /// the curves' keys name them.
  @AppStorage("levelsHistogramChannel") private var channel = 0
  static let bins = 128
  /// The counts on the scale before the black and white points, `bins` steps from 0 to 1, the
  /// first and last holding what lies beyond. From the finest counts there are: the coarse ones
  /// cover black to white in fewer steps than these, which left every other step empty.
  static func counts(_ range: ToneRange, black: Double, white: Double) -> [[Double]] {
    let (source, d) = range.fine.count >= 3 ? (range.fine, range.fineDomain) : (range.counts, range.domain)
    let n = source.first?.count ?? 0
    let step = (d.upperBound - d.lowerBound) / Double(max(n, 1))
    var out = [[Double]](repeating: [Double](repeating: 0, count: bins), count: 3)
    for c in 0..<min(3, source.count) {
      for i in 0..<n where source[c][i] > 0 {
        let q = d.lowerBound + (Double(i) + 0.5) * step
        let before = black + q * (white - black)
        out[c][min(bins - 1, max(0, Int(before * Double(bins))))] += source[c][i]
      }
    }
    return out
  }
  /// Where the midtone puts mid-grey on that scale: `q^(1/midtone)` is a half at `q = 0.5^midtone`.
  static func midPoint(black: Double, white: Double, midtone: Double) -> Double {
    black + pow(0.5, midtone) * (white - black)
  }
  /// The midtone that puts mid-grey at `x`, within the slider's range.
  static func midtone(at x: Double, black: Double, white: Double) -> Double {
    let q = min(0.98, max(0.02, (x - black) / max(white - black, 0.01)))
    return min(2, max(0.4, log(q) / log(0.5)))
  }
  var body: some View {
    let black = draft[.black] ?? self.black, white = draft[.white] ?? self.white, midtone = draft[.midtone] ?? self.midtone
    let counts = Self.counts(range, black: black, white: white)
    let mid = Self.midPoint(black: black, white: white, midtone: midtone)
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 5) {
        ForEach(0..<4, id: \.self) { i in
          let key = Button(CurveEditor.names[i]) { channel = i }
            .buttonStyle(KeyStyle(latched: channel == i))
            .help(i == 0 ? "三个通道叠在一起看" : "只看\(["", "红", "绿", "蓝"][i])通道")
          // A colour on the key takes the place of its latched fill: the one shown keeps none.
          if channel == i || i == 0 { key } else { key.foregroundStyle(CurveEditor.colors[i]) }
        }
        Spacer(minLength: 0)
      }.controlSize(.small).font(.system(size: 11))
      plot(counts: counts, black: black, white: white, mid: mid)
    }
  }
  private func plot(counts: [[Double]], black: Double, white: Double, mid: Double) -> some View {
    let shown = channel == 0 ? [0, 1, 2] : [channel - 1]
    return GeometryReader { geo in
      Canvas { ctx, size in
        func x(_ v: Double) -> CGFloat { size.width * CGFloat(min(1, max(0, v))) }
        // Scaled to the channels shown, so one alone fills the height.
        let peak = max(1e-9, shown.flatMap { counts[$0].dropFirst().dropLast() }.max() ?? 1)
        var lit = ctx
        lit.blendMode = .plusLighter
        for c in shown {
          var p = Path()
          p.move(to: CGPoint(x: 0, y: size.height))
          for b in 0..<Self.bins {
            let y = size.height * (1 - 0.92 * CGFloat(min(1, (counts[c][b] / peak).squareRoot())))
            p.addLine(to: CGPoint(x: size.width * CGFloat(b) / CGFloat(Self.bins), y: y))
            p.addLine(to: CGPoint(x: size.width * CGFloat(b + 1) / CGFloat(Self.bins), y: y))
          }
          p.addLine(to: CGPoint(x: size.width, y: size.height))
          p.closeSubpath()
          lit.fill(p, with: .color(HistogramView.colours[c].opacity(shown.count == 1 ? 0.8 : 0.45)))
        }
        // What the black and white points send to pure black and pure white, dimmed.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: x(black), height: size.height)), with: .color(.black.opacity(0.5)))
        ctx.fill(Path(CGRect(x: x(white), y: 0, width: max(0, size.width - x(white)), height: size.height)), with: .color(.black.opacity(0.5)))
        func mark(_ v: Double, _ label: String, _ on: Bool) {
          let at = x(v)
          ctx.stroke(Path { $0.move(to: CGPoint(x: at, y: 10)); $0.addLine(to: CGPoint(x: at, y: size.height)) },
            with: .color(on ? Hardware.accent : .white.opacity(0.55)), lineWidth: on ? 1.2 : 0.8)
          ctx.draw(Text(label).font(.system(size: 8, weight: .medium)).foregroundStyle(on ? Hardware.accent : .white.opacity(0.7)),
            at: CGPoint(x: min(max(at, 5), size.width - 5), y: 5))
        }
        mark(black, "黑", dragging == .black)
        mark(mid, "中", dragging == .midtone)
        mark(white, "白", dragging == .white)
      }
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { g in
          let w = max(1, geo.size.width), v = Double(g.location.x / w)
          if dragging == nil {
            // The mark nearest where the drag began, the midtone where black and white stand together.
            let start = Double(g.startLocation.x / w)
            dragging = [(Mark.black, black), (.midtone, mid), (.white, white)].min { abs($0.1 - start) < abs($1.1 - start) }?.0
          }
          let value: Double
          switch dragging {
          case .black: value = min(0.4, max(0, min(v, white - 0.05)))
          case .white: value = max(0.6, min(1, max(v, black + 0.05)))
          case .midtone: value = Self.midtone(at: v, black: black, white: white)
          case nil: return
          }
          if let mark = dragging {
            draft[mark] = value
            set(mark, value)
          }
        }
        .onEnded { _ in
          dragging = nil
          // The window's last update comes within a tenth of a second; should none change the
          // values (the step refused), the marks go back to them all the same.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if dragging == nil { draft = [:] } }
        })
    }
    .onChange(of: [self.black, self.white, self.midtone]) { if dragging == nil { draft = [:] } }
    .frame(height: 56)
    .padding(4).background(PlotScreen())
    .accessibilityElement().accessibilityLabel("色阶直方图 · " + CurveEditor.names[channel])
    .accessibilityValue(String(format: "黑点 %.2f，中间调 %.2f，白点 %.2f", black, midtone, white))
    .help("色阶之前的直方图：拖「黑」「中」「白」三条线设黑点、中间调和白点；两边暗下去的部分是变成纯黑、纯白的")
  }
}

/// A histogram as a camera back draws one, on a dark screen in either look: the three channels as
/// light added together, so where they overlap they mix towards white, scaled to the tallest count
/// away from the two ends, which a black border or a clipped sky would otherwise dwarf everything
/// beside. Quarters marked.
struct HistogramView: View {
  let histogram: Histogram
  static let colours = [Color(red: 1, green: 0.28, blue: 0.22), Color(red: 0.3, green: 0.95, blue: 0.35), Color(red: 0.35, green: 0.55, blue: 1)]
  var body: some View {
    Canvas { ctx, size in
      for q in 1..<4 {
        let x = size.width * CGFloat(q) / 4
        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
          with: .color(.white.opacity(0.14)), lineWidth: 0.5)
      }
      let bins = histogram.counts[0].count
      let peak = Double(max(1, histogram.counts.flatMap { $0.dropFirst().dropLast() }.max() ?? 1))
      ctx.blendMode = .plusLighter
      for c in 0..<3 {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: size.height))
        for b in 0..<bins {
          let y = size.height * (1 - CGFloat(min(1, Double(histogram.counts[c][b]) / peak)))
          p.addLine(to: CGPoint(x: size.width * CGFloat(b) / CGFloat(bins), y: y))
          p.addLine(to: CGPoint(x: size.width * CGFloat(b + 1) / CGFloat(bins), y: y))
        }
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.closeSubpath()
        ctx.fill(p, with: .color(Self.colours[c].opacity(0.6)))
      }
    }
    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.72)))
    .accessibilityElement().accessibilityLabel("直方图")
    .accessibilityValue(String(format: "亮端 红 %.0f%%，绿 %.0f%%，蓝 %.0f%%", histogram.top.r * 100, histogram.top.g * 100, histogram.top.b * 100))
  }
}

/// The live view's histogram as a strip in the bar over the stage, the letters of the channels the
/// camera's picture clips lit beside it.
struct LiveHistogramStrip: View {
  let histogram: Histogram
  var body: some View {
    HStack(spacing: 6) {
      HistogramView(histogram: histogram).frame(width: 110, height: 22)
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 3) {
          ForEach(0..<3, id: \.self) { c in
            let clipped = histogram.clipped.values[c] > 0.001
            Text(["R", "G", "B"][c]).font(.system(size: 9, weight: clipped ? .bold : .regular, design: .monospaced))
              .foregroundStyle(clipped ? HistogramView.colours[c] : Color.secondary.opacity(0.6))
          }
        }
        Text(histogram.clipped.values.contains(where: { $0 > 0.001 }) ? "过曝" : "取景")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(histogram.clipped.values.contains(where: { $0 > 0.001 }) ? Color(red: 1, green: 0.45, blue: 0.35) : .secondary)
      }
    }
    .help("相机实时取景的直方图。它来自相机按自己的白平衡和曲线做出的 JPEG，只作参考；RAW 有没有过曝、离满量程还差多少，看右边「上一张 RAW」。通道字母变粗变亮表示这个通道有像素到了顶。")
  }
}
