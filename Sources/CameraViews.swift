import AppKit
import SwiftUI

/// Module ①'s workspace with the camera: the live view filling the copy stand's dark base, and
/// floating over it on glass the camera's focus magnifier and the sharpness above and the focus
/// controls and the shutter below. On the picture the focus box (click to move it). The last
/// picture's focus check is in the right panel.
/// Module ① with the camera: the live view, or the pictures taken as a contact sheet or one at a
/// time, as the scanner's are shown. The sheet and the frame show each picture in daylight white
/// balance (日光) or as read (原样), with its exposure.
struct CaptureViewPicker: View {
  @ObservedObject var m: AppModel
  enum Way: Hashable { case live, sheet, single }
  var body: some View {
    Picker("视图", selection: Binding(
      get: { !m.reviewingShots ? Way.live : m.singleView ? .single : .sheet },
      set: { way in
        switch way {
        case .live: m.reviewingShots = false
        case .sheet: m.reviewingShots = true; m.showSingle(false)
        case .single: m.reviewingShots = true; m.showSingle(true)
        }
      })) {
      Text("取景").tag(Way.live)
      Text("接触表").tag(Way.sheet)
      Text("单张").tag(Way.single)
    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
      .disabled(m.frames.isEmpty && !m.reviewingShots)
      .help(m.frames.isEmpty ? "拍了照片以后，可以在接触表或单张里看拍好的照片" : "实时取景，或看拍好的照片：接触表 / 单张（⌘1 在两者间切换）")
  }
}

struct CameraStage: View {
  @ObservedObject var m: AppModel
  @ObservedObject var camera: CameraController
  @State private var ring: CGFloat = 0
  @State private var histogram = true
  /// Where the pieces of glass over the stage are named, so one flows out of another.
  @Namespace private var glass
  /// How tall the bars over the stage are, so the live picture lies between them.
  @State private var topBar: CGFloat = 0
  @State private var bottomBar: CGFloat = 0
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 0) {
      ZStack {
        // The window's ground shows: the live view itself frosted past recognition and mostly
        // grey, so a negative's orange mask does not colour the window.
        Color.clear
        // The live picture between the bars, which cover none of it: the film's edges show whole,
        // as the frame is set on the copy stand.
        GeometryReader { geo in
          liveView(in: CGSize(width: geo.size.width, height: max(80, geo.size.height - topBar - bottomBar)))
            .offset(y: topBar)
        }
        VStack(spacing: 0) {
          Group {
            if Liquid.available {
              LiquidGroup(spacing: 12) { fittedTopRow }.padding(.horizontal, 12).padding(.top, 10)
            } else {
              // Concentric with the stage's corners, 12 points in from them.
              fittedTopRow.padding(.horizontal, 10).padding(.vertical, 6).glassPane(radius: CameraStage.corner - 12)
                .padding(.horizontal, 12).padding(.top, 10)
            }
          }.onHeightChange { topBar = $0 }
          Spacer()
          if !Liquid.available, let toast = m.captureToast {
            GlassToast(text: toast).transition(.move(edge: .bottom).combined(with: .opacity)).padding(.bottom, 8)
          }
          Group {
            if Liquid.available {
              LiquidGroup(spacing: 14) { controls }.padding(.horizontal, 12).padding(.bottom, 12)
            } else {
              controls.padding(.horizontal, 12).padding(.vertical, 10).glassPane(radius: CameraStage.corner - 12)
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
          }.onHeightChange { bottomBar = $0 }
        }.animation(.spring(response: 0.35, dampingFraction: 0.8), value: m.captureToast)
      }
    }
  }
  /// The stage's corner radius where it floats between the panels; what lies in its corners is
  /// concentric with it.
  static let corner: CGFloat = 24
  /// A group of controls as a drop of glass of its own, over the picture; named `id`, it flows out
  /// of the glass beside it as it comes, and back into it as it goes.
  func drop(_ group: some View, id: String? = nil, tint: Color? = nil) -> some View {
    group.padding(.horizontal, 10).padding(.vertical, 5)
      .liquid(Capsule(), LiquidStyle(tint: tint ?? (scheme == .light ? .white.opacity(0.25) : .black.opacity(0.22))), id: id, in: id == nil ? nil : glass) { $0 }
  }
  /// The top row as wide as the stage allows: with the live histogram's strip, or without it on a
  /// narrow stage, where it would push the window's columns past its edges.
  var fittedTopRow: some View {
    WidthFit {
      topRow(strip: true)
    } compact: {
      topRow(strip: false)
    }
  }
  /// The camera's focus magnifier, the histogram, and the sharpness.
  @ViewBuilder func topRow(strip: Bool) -> some View {
    HStack(spacing: 10) {
      // To the pictures taken, on the light table or one at a time, and back.
      if Liquid.available { drop(CaptureViewPicker(m: m)) } else { CaptureViewPicker(m: m) }
      // The camera's own magnifier: the live view is then that part of the sensor, pixel for pixel.
      if !camera.magnifications.isEmpty {
        let viewing = Picker("对焦放大", selection: Binding(get: { camera.magnification }, set: { camera.magnify($0) })) {
          Text("1×").tag(Int64(0))
          ForEach(camera.magnifications, id: \.self) { m in Text(String(format: "%.1f×", Double(m) / 10)).tag(m) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
          .help("相机的对焦放大：实时取景传回对焦点附近的真实像素，用来看清楚对没对上焦；点画面移对焦点前先回 1×")
        // The picker and the readout on drops of glass; the keys are glass themselves.
        if Liquid.available { drop(viewing) } else { viewing }
      }
      Button {
        withAnimation(Liquid.flow) { histogram.toggle() }
      } label: {
        Image(systemName: "chart.bar.xaxis").frame(width: 16)
      }.glassAction(on: histogram).controlSize(.small).liquidName("histogram-key", in: glass)
        .accessibilityLabel("直方图").accessibilityValue(histogram ? "开" : "关")
        .help(histogram ? "收起实时取景的直方图" : "在上面这条显示实时取景的直方图")
      // The live histogram in the bar, over none of the picture, beside its key: shown, it flows
      // out of the key as a drop, and back into it put away.
      if strip, histogram, let h = camera.liveHistogram {
        if Liquid.available { drop(LiveHistogramStrip(histogram: h), id: "histogram") } else { LiveHistogramStrip(histogram: h) }
      }
      Spacer(minLength: 8)
      if let s = camera.sharpness {
        let sharp = Text(String(format: "清晰度 R %.1f  G %.1f  B %.1f", s.r * 1e4, s.g * 1e4, s.b * 1e4)).readout(10)
          .help("对焦框里的清晰度（拉普拉斯能量 × 10⁴）：越大越清楚，只在同一画面里前后比较")
        if Liquid.available { drop(sharp) } else { sharp }
      }
    }
  }
  /// The live frame fitted to the stage, under the bars as a picture lies under glass, with the
  /// focus box over it.
  @ViewBuilder func liveView(in size: CGSize) -> some View {
    if let live = camera.live {
      let fit = fitted(CGSize(width: live.width, height: live.height), in: size)
      let at = CGPoint(x: camera.focusPoint.x * fit.width, y: camera.focusPoint.y * fit.height)
      Image(decorative: live, scale: 1).resizable().interpolation(.high)
        .frame(width: fit.width, height: fit.height)
        .overlay {
          if camera.magnification == 0 {
            let b = camera.focusBox
            Rectangle().stroke(Hardware.amber, lineWidth: 1.5)
              .frame(width: b.width * fit.width, height: b.height * fit.width).position(at)
          }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap in
          guard camera.magnification == 0 else { return }
          camera.setFocusPoint(CGPoint(x: tap.location.x / fit.width, y: tap.location.y / fit.height))
        })
        .frame(width: size.width, height: size.height)
    } else {
      VStack(spacing: 8) {
        Image(systemName: "camera.viewfinder").font(.system(size: 34)).foregroundStyle(.secondary)
        Text(camera.connected ? "等待实时取景…" : camera.phase == .missing ? "这份 App 没有带 Sony SDK" : "相机还没有连接")
          .font(.system(size: 13)).foregroundStyle(.secondary)
        // The way in where the eye is, as the left panel's key: one click from the empty view.
        if !camera.connected && camera.phase != .missing {
          Button {
            m.connectCamera()
          } label: {
            Label(camera.phase == .connecting ? "正在连接…" : "连接相机", systemImage: "cable.connector")
          }.buttonStyle(KeyStyle(prominent: true)).controlSize(.large).disabled(camera.phase == .connecting)
            .help("用左边「连接方式」里选的方式连接 A7R IV（相机的 USB 连接方式选「PC 遥控」）")
            .padding(.top, 6)
        }
      }.frame(width: size.width, height: size.height)
    }
  }
  func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
    let k = min((box.width - 24) / max(1, size.width), (box.height - 24) / max(1, size.height))
    return CGSize(width: size.width * k, height: size.height * k)
  }
  /// Focusing on one row, pixel shift on the next, and the shutter release beside both. With
  /// SwiftUI's glass each group is a drop of its own, AF a drop that gives under the finger, the
  /// pixel-shift files counted in beads of glass, and each note of a picture filed rising out of
  /// the shutter as a drop pinches off.
  var controls: some View {
    let liquid = Liquid.available
    return HStack(spacing: 16) {
      VStack(spacing: 8) {
        HStack(spacing: 10) {
          Button {
            camera.autofocus()
          } label: {
            Label("AF", systemImage: "scope").lineLimit(1).fixedSize()
          }.glassAction().liquidName("af", in: glass)
            .help("在对焦框处自动对焦一次并锁住焦点：相机能切手动对焦就切过去；不能（镜头开关在 AF）就在 DMF 里半按按住。锁住时可以步进微调，快门不会再对焦；拍完一张会松开")
          // The lock as a drop of amber glass parting from AF, and running back into it let go.
          if camera.focusLocked {
            let lock = Label("已锁焦", systemImage: "lock.fill").font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
              .accessibilityLabel("焦点已锁住")
            if liquid {
              drop(lock, id: "focus-lock", tint: Hardware.accent.opacity(0.5))
            } else {
              lock.padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Hardware.accent.opacity(0.35)))
            }
          }
          let stepping = HStack(spacing: 3) {
            ForEach([-6, -3, -1], id: \.self) { s in
              Button { camera.step(s) } label: { Text(s == -6 ? "«" : s == -3 ? "‹‹" : "‹").frame(width: 16) }.glassAction()
                .help("对焦往近处走（Near \(-s) 档）：相机在手动对焦，或按 AF 锁住焦点之后")
            }
            FocusRing(offset: $ring) { camera.step($0) }.frame(minWidth: 56, idealWidth: 120, maxWidth: 120).frame(height: 24)
            ForEach([1, 3, 6], id: \.self) { s in
              Button { camera.step(s) } label: { Text(s == 6 ? "»" : s == 3 ? "››" : "›").frame(width: 16) }.glassAction()
                .help("对焦往远处走（Far \(s) 档）：相机在手动对焦，或按 AF 锁住焦点之后")
            }
          }
          stepping
          Spacer(minLength: 0)
        }
        HStack(spacing: 10) {
          let shifting = HStack(spacing: 10) {
            Picker("像素位移", selection: Binding(get: { m.pixelShiftCount }, set: { m.choosePixelShift($0) })) {
              Text("单张").tag(1)
              Text("位移 4").tag(4)
              Text("位移 16").tag(16)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
              .disabled(camera.shiftSwitching != nil || camera.awaitingPicture || !m.pendingShift.isEmpty)
              .help((camera.shiftDirect ? "选了就由 App 把相机设好：打开或关上像素位移，张数 4 或 16，连着时直接改，取景不停；" : "选了就由 App 把相机设好：打开或关上像素位移，张数 4 或 16。Sony 的 SDK 改不了这一项，App 先断开它，用相机自己的 PTP 设好再连上，取景停十来秒；") + "没连着时，连接时设。连接时这里先跟着相机现在的设置。间隔在相机菜单里选最短。一次快门收到的一组合成一张：4 张时每个点的红、绿、蓝都是实测的，没有去马赛克的假色；16 张再加上半像素的位移，合成长宽各两倍的画面（A7R IV 约 2.45 亿像素，每组约 2 GB 原片加 1.5 GB 合成图）")
            if m.pixelShiftCount == 16 {
              Toggle("超采样", isOn: $m.shiftSupersample).toggleStyle(.checkbox).font(.system(size: 11))
                .help("超采样到传感器原生尺寸：颜色更干净、噪声略低、文件小四分之三；解析力和 4 张相同。不勾时合成长宽各两倍的画面（A7R IV 约 2.45 亿像素、1.5 GB）")
            }
            if camera.shiftSwitching != nil {
              ProgressView().controlSize(.small).help("正在把相机设为" + CameraController.shiftName(camera.shiftSwitching ?? 1))
            } else if m.pixelShiftCount > 1 {
              ShiftBeads(count: m.pixelShiftCount, got: m.pendingShift.count)
            }
          }
          if liquid { drop(shifting) } else { shifting }
          Spacer()
        }
      }
      ShutterKey(enabled: camera.connected && !camera.awaitingPicture, busy: camera.awaitingPicture, shots: camera.shots) { camera.shoot() }
        .help(camera.awaitingPicture ? "上一张还在写入和传输，到了再拍" : "拍摄（空格）：只拍不对焦，对焦请按 AF")
        .overlay(alignment: .topTrailing) {
          if liquid, let toast = m.captureToast {
            DropToast(text: toast).id(toast).transition(.scale(scale: 0.3, anchor: .bottomTrailing).combined(with: .opacity))
          }
        }
    }.buttonStyle(.bordered).controlSize(.small).disabled(!camera.connected && camera.phase != .missing)
      .animation(Liquid.flow, value: camera.focusLocked)
  }
}

/// The files of a pixel-shift shot as beads, one lit as each comes in; when the group is complete
/// they run together into one drop for a moment.
struct ShiftBeads: View {
  let count: Int
  let got: Int
  @State private var gathered = false
  var body: some View {
    let size: CGFloat = count > 8 ? 7 : 10
    HStack(spacing: gathered ? -size * 0.8 : count > 8 ? 2 : 3) {
      ForEach(0..<count, id: \.self) { i in
        let lit = gathered || i < got
        Color.clear.frame(width: size, height: size)
          .liquid(Circle(), LiquidStyle(tint: lit ? Hardware.amber.opacity(0.85) : nil)) {
            $0.overlay(Circle().fill(lit ? Hardware.amber : Hardware.adaptive(NSColor(white: 1, alpha: 0.16), NSColor(white: 0, alpha: 0.16))))
          }
      }
    }
    .animation(Liquid.flow, value: got)
    .onChange(of: got) { old, new in
      // Back to none from some: the group came in whole.
      guard new == 0, old > 0 else { return }
      withAnimation(Liquid.flow) { gathered = true }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(Liquid.flow) { gathered = false } }
    }
    .help("像素位移：已收到 \(got) / \(count) 张")
    .accessibilityElement().accessibilityLabel("像素位移").accessibilityValue("\(got) / \(count)")
  }
}

/// A note of a picture filed, out of the shutter: a drop that grows from the key, still joined
/// to it, and rises away until it pinches off.
struct DropToast: View {
  let text: String
  @State private var risen = false
  @Environment(\.accessibilityReduceMotion) private var still
  var body: some View {
    Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Hardware.ink).fixedSize()
      .padding(.horizontal, 14).padding(.vertical, 7)
      .liquid(Capsule(), LiquidStyle(tint: Hardware.adaptive(NSColor(white: 0, alpha: 0.3), NSColor(white: 1, alpha: 0.3)))) { $0.glassPane(radius: 16, darken: 0.35) }
      .offset(y: risen ? -58 : -18)
      .allowsHitTesting(false)
      .onAppear {
        if still { risen = true } else { withAnimation(.spring(response: 0.7, dampingFraction: 0.6).delay(0.08)) { risen = true } }
      }
  }
}

/// A knurled focus ring lying on its side: drag it to turn the lens, a Near/Far step of 1 for every
/// 14 points, the knurling moving with it.
struct FocusRing: View {
  @Binding var offset: CGFloat
  let step: (Int) -> Void
  @State private var last: CGFloat = 0
  var body: some View {
    GeometryReader { geo in
      ZStack {
        RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.12), Color(white: 0.22)], startPoint: .top, endPoint: .bottom))
        HStack(spacing: 4) {
          ForEach(0..<Int(geo.size.width / 5) + 4, id: \.self) { _ in
            Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1.2)
          }
        }.offset(x: offset.truncatingRemainder(dividingBy: 5)).clipped()
        RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12), lineWidth: 0.6)
      }
      .frame(width: geo.size.width, height: geo.size.height)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 1).onChanged { g in
        let moved = g.translation.width - last
        offset += moved
        if abs(moved) >= 14 {
          step(moved > 0 ? 1 : -1)
          last = g.translation.width
        }
      }.onEnded { _ in last = 0 })
    }
    .help("拖动对焦环：每 14 点走 1 档（要手动对焦模式）")
    .accessibilityElement().accessibilityLabel("对焦环").accessibilityAdjustableAction { d in step(d == .increment ? 1 : -1) }
  }
}

/// The last picture about the focus point at full resolution, one pixel of the file to one pixel of
/// the screen or larger, unsmoothed, with its sharpness channel by channel.
struct FocusCheck: View {
  @ObservedObject var m: AppModel
  @ObservedObject var camera: CameraController
  @State private var crop: CGImage?
  @State private var histogram: Histogram?
  @State private var scale = 2
  @State private var loading = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionTitle(text: "对焦检查", symbol: "plus.magnifyingglass")
      Picker("倍率", selection: $scale) {
        Text("100%").tag(1)
        Text("200%").tag(2)
        Text("400%").tag(4)
      }.pickerStyle(.segmented).labelsHidden()
      // A square as wide as the panel, the file's pixels shown about its middle.
      Color.black.opacity(0.4).aspectRatio(1, contentMode: .fit).overlay {
        if let crop {
          let shown = crop
          let pixels = 248 / CGFloat(scale)
          Image(decorative: shown, scale: NSScreen.main?.backingScaleFactor ?? 2).resizable().interpolation(.none)
            .frame(width: CGFloat(shown.width) * CGFloat(scale) / (NSScreen.main?.backingScaleFactor ?? 2),
              height: CGFloat(shown.height) * CGFloat(scale) / (NSScreen.main?.backingScaleFactor ?? 2))
            .help(String(format: "每个文件像素放大到 %d 个屏幕像素；窗口里约 %.0f × %.0f 个文件像素", scale, pixels, pixels))
        } else {
          Text(loading ? "读取中…" : "拍一张后在这里看对焦").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }.clipped()
        .help("取的是相机文件本身的全分辨率像素（RAW 按系统默认显示），以对焦框的位置为中心。")
      if let crop {
        let s = Sharpness.measure(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        Text(String(format: "清晰度×10⁴ R %.1f G %.1f B %.1f", s.r * 1e4, s.g * 1e4, s.b * 1e4)).fixedSize().readout(10)
          .help("这块原图的清晰度：三个通道差得多时，说明有色差，红和蓝的焦点不在同一处")
      }
      if let histogram { LastHistogram(histogram: histogram) }
      // The base's balance in the last picture, for setting the narrowband light by.
      if let shot = m.lastShotBalance {
        VStack(alignment: .leading, spacing: 4) {
          Text("第 \(shot.frame) 张 · 片基偏色").font(.system(size: 11, weight: .medium))
          HStack(spacing: 6) {
            BaseSwatch(level: shot.balance.balanced)
            Text(shot.balance.short).fixedSize().readout(10)
            InfoButton(text: shot.balance.text, about: "片基偏色")
          }
        }.help(shot.balance.isEven ? "片基在日光白平衡下是灰的：灯的配比消掉了片基的颜色，和取景里看到的一样" : "片基在日光白平衡下还偏色：点 ⓘ 看哪盏灯调多少，调完再拍一张")
      }
      if let url = m.lastCapture {
        Text(url.lastPathComponent).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        Button("按对焦点重新取") { load(url) }.font(.system(size: 11))
      }
    }.onChange(of: m.lastCapture) { _, url in if let url { load(url) } }
      .onAppear { if crop == nil, let url = m.lastCapture { load(url) } }
  }
  func load(_ url: URL) {
    loading = true
    let point = camera.focusPoint
    AppModel.captureQueue.async {
      let image = AppModel.focusCrop(url, at: point, side: 248)
      let counted = Histogram.sensor(url) ?? (try? ImagePipeline.shared.load(url, maxDimension: 512)).map(Histogram.picture)
      DispatchQueue.main.async {
        crop = image
        histogram = counted
        loading = false
      }
    }
  }
}

/// The last picture's histogram, a RAW's from the sensor's own values: how near full each channel
/// came and how much of it was clipped, in numbers, for setting the exposure by.
struct LastHistogram: View {
  let histogram: Histogram
  /// Stops below full.
  func ev(_ v: Double) -> String { v >= 0.999 ? "  0.0" : String(format: "%+5.1f", log2(max(v, 1e-4))) }
  var body: some View {
    let h = histogram
    return VStack(alignment: .leading, spacing: 6) {
      Text(h.linear ? "上一张 RAW · 传感器原始值" : "上一张 · 相机渲染的画面").font(.system(size: 11, weight: .medium))
      HistogramView(histogram: h).frame(maxWidth: .infinity).frame(height: 64)
      Text(String(format: "亮端  R %3.0f%%  G %3.0f%%  B %3.0f%%", h.top.r * 100, h.top.g * 100, h.top.b * 100)
        + (h.linear ? "\n距满  R \(ev(h.top.r)) G \(ev(h.top.g)) B \(ev(h.top.b)) EV" : "")
        + String(format: "\n过曝  R %.2f%% G %.2f%% B %.2f%%", h.clipped.r * 100, h.clipped.g * 100, h.clipped.b * 100))
        .fixedSize().readout(10)
    }
    .help(h.linear
      ? "横轴是传感器读数，按比例从黑到满量程，左右等距就是光量等比例；竖线是 1/4、1/2、3/4。亮端是每个通道最亮的 0.5% 从哪里开始；距满是它离满量程还差几档。过曝是到顶的感光点的比例，应为 0。"
      : "这张不是无压缩 ARW，只能看相机渲染出来的画面，按它的曲线编码，不等于传感器读数。")
  }
}

/// Module ①'s left panel with the camera: connection, exposure, focus mode, file type, where the
/// pictures go, pixel shift, and the log for when something does not work.
struct CameraPanel: View {
  @ObservedObject var m: AppModel
  @ObservedObject var camera: CameraController
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        StatusLED(lamp: camera.connected ? .ready : camera.phase == .connecting ? .busy : .fault, size: 7)
        Text(camera.connected ? camera.model : camera.phase == .missing ? "没有 SDK" : camera.phase == .connecting ? "连接中" : "未连接").readout(10)
        if camera.connected { Text(camera.link.name).font(.system(size: 10)).foregroundStyle(.tertiary) }
        Spacer()
        if let battery = camera.properties["BatteryRemain"] { Text("电量 \(battery.text)").font(.system(size: 11)).foregroundStyle(.secondary) }
      }
      if !camera.message.isEmpty {
        Text(camera.message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if camera.connected {
          Button("断开") { camera.disconnect() }
          Button(camera.liveOn ? "关实时取景" : "开实时取景") { camera.setLive(!camera.liveOn) }
        } else {
          Button {
            m.connectCamera()
          } label: {
            Label("连接相机", systemImage: "cable.connector")
          }.buttonStyle(KeyStyle(prominent: true)).disabled(camera.phase == .missing || camera.phase == .connecting)
        }
      }
      // How the camera is reached, chosen while it is not connected.
      if !camera.connected {
        HStack {
          Text("连接方式").font(.system(size: 12)).foregroundStyle(.secondary)
          Spacer()
          Picker("连接方式", selection: Binding(get: { camera.link }, set: { m.useCameraLink($0) })) {
            ForEach(CameraController.Link.allCases, id: \.self) { Text($0.name).tag($0) }
          }.labelsHidden().fixedSize().font(.system(size: 11)).disabled(camera.phase == .connecting)
        }.help("直连 PTP：App 直接讲相机自己的协议，和 Imaging Edge 一样，像素位移的开关和张数连着就能改，取景不停。Sony SDK：Sony 给第三方的开发包，改像素位移时要先断开它再连上。直连有问题时可以换回 SDK。")
      }
      // Where the pictures go, one choice before and while connected; never the card alone, or none would come here.
      HStack {
        Text("保存到").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Picker("保存到", selection: Binding(get: { m.keepsOnCard }, set: { m.keepOnCard($0) })) {
          Text("只存电脑").tag(false)
          Text("电脑和存储卡").tag(true)
        }.labelsHidden().fixedSize().font(.system(size: 11))
          .disabled(camera.connected && camera.properties["StillImageStoreDestination"]?.settable != true)
      }.help("照片总是传到电脑；选「电脑和存储卡」时，存储卡上再留一份（要插卡）。下次连接照这里设定，连着时改也立刻生效。")
      if camera.connected {
        Divider()
        HStack {
          Text("曝光").font(.system(size: 12, weight: .medium))
          Spacer()
          InfoButton(
            text: "模式由相机上的转盘决定：M 档时快门、光圈都能改，A 档只改光圈，S 档只改快门。光圈要电子镜头才能远程改（比如 Sigma 70mm F2.8 DG Macro Art）；翻拍底片一般从 f/5.6–8 开始试。",
            about: "曝光")
        }
        setting("快门", "ShutterSpeed")
        setting("光圈", "FNumber")
        setting("ISO", "IsoSensitivity")
        setting("模式", "ExposureProgramMode")
        setting("曝光补偿", "ExposureBiasCompensation")
        Divider()
        HStack {
          Text("白平衡").font(.system(size: 12, weight: .medium))
          Spacer()
          InfoButton(
            text: "RAW 的数据不受白平衡影响，App 解码时整卷固定 5500K；这里只改实时取景和 JPEG 的颜色。固定一个色温，取景每张颜色一致。",
            about: "相机白平衡")
        }
        setting("模式", "WhiteBalance")
        if camera.properties["WhiteBalance"]?.value == CameraController.colourTemperatureMode {
          HStack(spacing: 6) {
            Text("色温").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("−") { camera.nudgeColourTemperature(by: -100) }.help("冷一点：减 100K")
            Menu(camera.properties["Colortemp"]?.text ?? "--") {
              ForEach([3200, 4000, 5000, 5500, 6500] as [Int64], id: \.self) { k in
                Button("\(k)K") { camera.setColourTemperature(k) }
              }
            }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
            Button("+") { camera.nudgeColourTemperature(by: 100) }.help("暖一点：加 100K")
          }
        } else {
          Button("设为色温 5500K") { camera.setColourTemperature(5500) }.font(.system(size: 11))
        }
        Divider()
        Text("对焦").font(.system(size: 12, weight: .medium))
        HStack {
          Button("AF-S") { camera.set("FocusMode", 2) }
          Button("MF") { camera.set("FocusMode", 1) }
          Spacer()
          Text(camera.properties["FocusMode"]?.text ?? "--").readout(10)
        }
        setting("区域", "FocusArea")
        if let f = camera.properties["FocusIndication"] { labeled("状态", f.text) }
        Text("点取景画面移动对焦点：对焦区域要是「自由点」。")
          .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Divider()
        Text("文件").font(.system(size: 12, weight: .medium))
        setting("格式", "FileType")
        Text("RAW 请在相机菜单里设为「无压缩」，远程改不了这一项。")
          .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      // What to set on the camera in a line; the whole of it behind ⓘ.
      HStack {
        Text("像素位移").font(.system(size: 12, weight: .medium))
        Spacer()
        InfoButton(text: "在下方取景区右侧选单张、4 张或 16 张，App 就把相机设好：打开或关上像素位移，设好张数。直连 PTP 时在连接里直接改，取景不停；用 Sony SDK 时它改不了这一项，App 先断开它，用相机自己的 PTP 设好，再连上，取景停十来秒。在相机菜单里改了，那里也跟着变。连接时那里先跟着相机现在的设置。间隔请在相机菜单里选最短，RAW 设为无压缩。按一次快门，相机拍一组，App 把这一组放进同一个文件夹，合成一张再转换。\n\n4 张：每张传感器移一个像素，合成的每个点红、绿、蓝都是实测的，没有去马赛克的假色，颗粒和细边缘的颜色更干净；像素数不变。\n\n16 张：4 组这样的 4 张，组与组之间再移半个像素，合成长宽各两倍的画面。半像素位移由 App 从画面上实测（相机给的常差 0.1–0.2 像素），每个点取离它最近的那一组。A7R IV 一组约 19 秒、原片约 2 GB，合成图约 1.5 GB，合成时要约 3 GB 内存。能多出的细节取决于镜头：在 Vlad's 测试标靶上，16 张比 4 张只多分辨了一个元素。\n\n勾选「超采样」时，16 张合成后再缩回传感器原生尺寸（Lanczos-3）：颜色比 4 张更干净（标靶上假色少约 30%）、噪声略低（暗处低 10–15%）、文件小四分之三；解析力和 4 张相同。\n\n一组之间胶片、相机或灯不能动：两次绿色相差超过 4%（正常约 1.5%），或 16 张的半像素位移偏离超过 0.25 像素时，App 会提醒重拍。")
      }
      Text("下方取景区右侧选张数，App 会把相机设好" + (camera.shiftDirect ? "。" : "（取景停十来秒）。") + "间隔在相机菜单里选最短，RAW 设为无压缩。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Divider()
      HStack {
        Text("光源标定").font(.system(size: 12, weight: .medium))
        Spacer()
        InfoButton(text: "拿走底片，灯箱上什么都不放：只开红灯拍一张、只开绿灯拍一张、只开蓝灯拍一张，每张曝光到最亮处约 70%（看上面的直方图）。拍完点下面的按钮。\n\nApp 从这三张算出这组灯的串色矩阵，和每种灯在画面上的明暗分布（平场）。之后翻拍时，读出 RAW 先去串色，再把四周偏暗的地方补平。换了灯的位置或灯箱，就再标一次；灯的亮度配比怎么调都不用重标。标定完，这三张空白帧可以在胶片条上删掉。\n\n只想去掉微距镜头的暗角和灯的不匀，或者用白光翻拍：在 ② 去色罩「胶片」一节的「平场」里用一张空白帧（三种灯一起开）就够，去串色开不开都行。")
      }
      Text("拿走底片，红、绿、蓝灯各单独拍一张空白帧（最亮处约 70%），再点下面的按钮。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button {
        m.calibrateLight()
      } label: {
        Label("用最近三张标定光源", systemImage: "light.panel")
      }.disabled(m.frames.filter { $0.sensorRead == true }.count < 3 || m.isWorking)
      Text(m.lightDescription).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      DisclosureGroup("诊断") {
        ScrollView {
          Text(camera.log.suffix(60).joined(separator: "\n")).font(.system(size: 9, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.frame(height: 160)
        Button("复制诊断信息") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(camera.log.joined(separator: "\n"), forType: .string)
        }.font(.system(size: 11))
      }.font(.system(size: 11))
    }
  }
  func labeled(_ name: String, _ value: String) -> some View {
    HStack {
      Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
      Spacer()
      Text(value).readout(10)
    }
  }
  /// A setting with the values the camera offers for it.
  func setting(_ title: String, _ name: String) -> some View {
    let p = camera.properties[name]
    return HStack {
      Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
      Spacer()
      if let p, p.settable, !p.values.isEmpty {
        Menu(p.text) {
          ForEach(p.values, id: \.self) { v in
            Button(CameraProperty.describe(name, v)) { camera.set(name, v) }
          }
        }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
      } else {
        Text(p?.text ?? "--").readout(10)
      }
    }
  }
}

/// A view's height as laid out, told each time it changes.
private struct LaidOutHeight: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
extension View {
  func onHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
    background(GeometryReader { g in Color.clear.preference(key: LaidOutHeight.self, value: g.size.height) })
      .onPreferenceChange(LaidOutHeight.self, perform: action)
  }
}
