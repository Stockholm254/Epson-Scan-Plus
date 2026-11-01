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
  /// Where the brightest 0.1% lie, in their brightest channel.
  var brightest: Double
}

/// A frame's histogram over more than a screen shows (`ToneRange`): the part an ordinary (SDR)
/// screen shows with gradation lit, what it shows as black or white dimmed, the levels' black and
/// white marked, and whole stops past the white. On a square-root scale, so a few highlights still
/// show beside the midtones' thousands.
struct ToneRangeView: View {
  let range: ToneRange
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Canvas { ctx, size in
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
      .accessibilityElement().accessibilityLabel("直方图 · SDR 范围").accessibilityValue(lines.joined(separator: "；"))
      VStack(alignment: .leading, spacing: 1) {
        ForEach(lines, id: \.self) { Text($0) }
      }.font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
  private func percent(_ v: Double) -> String {
    v < 0.0001 ? "0" : v < 0.01 ? String(format: "%.2f%%", v * 100) : String(format: "%.1f%%", v * 100)
  }
  /// How far past white the frame goes, and what shows white or black.
  var lines: [String] {
    var past = "白点以上 \(percent(range.pastWhite))"
    if let stop = range.stop, range.brightest > 1 {
      past += String(format: "，最亮的 0.1%% 在白点以上 %.1f 档", (range.brightest - 1) / stop)
    }
    return [past, "屏幕上纯白 \(percent(range.atWhite))，纯黑 \(percent(range.atBlack))"]
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

/// The live view's histogram on glass, over the picture's top right, with the letters of the
/// channels the camera's picture clips lit.
struct LiveHistogram: View {
  let histogram: Histogram
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HistogramView(histogram: histogram).frame(width: 180, height: 60)
      HStack(spacing: 6) {
        Text("实时取景").font(.system(size: 9)).foregroundStyle(.secondary)
        Spacer()
        ForEach(0..<3, id: \.self) { c in
          let clipped = histogram.clipped.values[c] > 0.001
          Text(["R", "G", "B"][c]).font(.system(size: 9, weight: clipped ? .bold : .regular, design: .monospaced))
            .foregroundStyle(clipped ? HistogramView.colours[c] : Color.secondary.opacity(0.6))
        }
        if histogram.clipped.values.contains(where: { $0 > 0.001 }) {
          Text("过曝").font(.system(size: 9, weight: .medium)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.35))
        }
      }.frame(width: 180)
    }
    .padding(8)
    .liquid(RoundedRectangle(cornerRadius: 12), LiquidStyle(tint: Hardware.adaptive(NSColor(white: 0, alpha: 0.3), NSColor(white: 1, alpha: 0.3)))) { $0.glassPane(radius: 12, darken: 0.35) }
    .help("相机实时取景的直方图。它来自相机按自己的白平衡和曲线做出的 JPEG，只作参考；RAW 有没有过曝、离满量程还差多少，看右边「上一张 RAW」。通道字母亮起表示这个通道有像素到了顶。")
  }
}
