import AppKit
import SwiftUI

/// Module ①'s workspace with the camera: the live view filling the copy stand's dark base, and
/// floating over it on glass the zoom and sharpness above and the focus controls and the
/// shutter below. On the picture the focus box (click to move it) and a glass bubble magnifying
/// what is under it. Beside it, on a glass pane, the last picture at full resolution about the
/// focus point, pixel for pixel, to check focus.
struct CameraStage: View {
  @ObservedObject var m: AppModel
  @ObservedObject var camera: CameraController
  @State private var zoom = 1
  @State private var ring: CGFloat = 0
  @State private var magnifier = true
  var body: some View {
    HStack(spacing: 0) {
      ZStack {
        // Not continued under the panels as a positive is: a negative's orange mask would colour
        // the whole window.
        Color(red: 0.06, green: 0.06, blue: 0.065)
        GeometryReader { geo in liveView(in: geo.size) }
        VStack(spacing: 0) {
          if Liquid.available {
            LiquidGroup(spacing: 12) { topRow }.padding(.horizontal, 12).padding(.top, 10)
          } else {
            topRow.padding(.horizontal, 10).padding(.vertical, 6).glassPane(radius: 20)
              .padding(.horizontal, 12).padding(.top, 10)
          }
          Spacer()
          if !Liquid.available, let toast = m.captureToast {
            GlassToast(text: toast).transition(.move(edge: .bottom).combined(with: .opacity)).padding(.bottom, 8)
          }
          if Liquid.available {
            LiquidGroup(spacing: 14) { controls }.padding(.horizontal, 12).padding(.bottom, 12)
          } else {
            controls.padding(.horizontal, 12).padding(.vertical, 10).glassPane(radius: 18)
              .padding(.horizontal, 12).padding(.bottom, 12)
          }
        }.animation(.spring(response: 0.35, dampingFraction: 0.8), value: m.captureToast)
      }
      FocusCheck(m: m, camera: camera).frame(width: 276).consolePanel().padding(8)
    }.background(Color(red: 0.105, green: 0.11, blue: 0.115))
  }
  /// A group of controls as a drop of glass of its own, over the picture.
  func drop(_ group: some View) -> some View {
    group.padding(.horizontal, 10).padding(.vertical, 5)
      .liquid(Capsule(), LiquidStyle(tint: .black.opacity(0.22))) { $0 }
  }
  /// The zoom and the magnifier, and the sharpness.
  @ViewBuilder var topRow: some View {
    HStack(spacing: 10) {
      let viewing = HStack(spacing: 10) {
        if camera.magnifications.isEmpty {
          Picker("放大", selection: $zoom) {
            Text("1×").tag(1)
            Text("2×").tag(2)
            Text("4×").tag(4)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 120).help("取景放大：按对焦框放大实时取景（相机没有报对焦放大，只能放大取景小图）")
        } else {
          // The camera's own magnifier: the live view is then that part of the sensor, pixel for pixel.
          Picker("对焦放大", selection: Binding(get: { camera.magnification }, set: { camera.magnify($0) })) {
            Text("1×").tag(Int64(0))
            ForEach(camera.magnifications, id: \.self) { m in Text(String(format: "%.1f×", Double(m) / 10)).tag(m) }
          }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            .help("相机的对焦放大：实时取景传回对焦点附近的真实像素，用来看清楚对没对上焦；点画面移对焦点前先回 1×")
        }
        Button {
          magnifier.toggle()
        } label: {
          Image(systemName: "magnifyingglass.circle").frame(width: 16)
        }.buttonStyle(HardwareKeyStyle(latched: magnifier)).controlSize(.small)
          .help(magnifier ? "收起对焦框上的玻璃放大镜" : "在对焦框上放一个放大 4 倍的玻璃放大镜")
      }
      if Liquid.available { drop(viewing) } else { viewing }
      Spacer(minLength: 8)
      if let s = camera.sharpness {
        Text(String(format: "清晰度 R %.1f  G %.1f  B %.1f", s.r * 1e4, s.g * 1e4, s.b * 1e4)).lcd(10)
          .help("对焦框里的清晰度（拉普拉斯能量 × 10⁴）：越大越清楚，只在同一画面里前后比较")
      }
    }
  }
  /// The live frame fitted to the stage, under the bars as a picture lies under glass, with the
  /// focus box and the glass bubble over it.
  @ViewBuilder func liveView(in size: CGSize) -> some View {
    if let live = camera.live {
      let shown = view(live)
      let fit = fitted(CGSize(width: shown.width, height: shown.height), in: size)
      let at = CGPoint(x: camera.focusPoint.x * fit.width, y: camera.focusPoint.y * fit.height)
      Image(decorative: shown, scale: 1).resizable().interpolation(zoom > 1 ? .none : .high)
        .frame(width: fit.width, height: fit.height)
        .overlay {
          if zoom == 1 && camera.magnification == 0 {
            let b = camera.focusBox
            Rectangle().stroke(Hardware.amber, lineWidth: 1.5)
              .frame(width: b.width * fit.width, height: b.height * fit.width).position(at)
          }
        }
        .overlay(alignment: .topLeading) {
          // The light table's loupe, the one chosen, standing on the live view at the focus point.
          if zoom == 1, camera.magnification == 0, magnifier,
            let loupe = LiveLoupe.render(shown, size: fit, at: at, style: m.preferences.loupeStyle, backing: NSScreen.main?.backingScaleFactor ?? 2)
          {
            Image(decorative: loupe.image, scale: NSScreen.main?.backingScaleFactor ?? 2)
              .frame(width: loupe.frame.width, height: loupe.frame.height)
              .offset(x: loupe.frame.minX, y: loupe.frame.minY)
              .allowsHitTesting(false)
          }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap in
          guard zoom == 1, camera.magnification == 0 else { return }
          camera.setFocusPoint(CGPoint(x: tap.location.x / fit.width, y: tap.location.y / fit.height))
        })
        .frame(width: size.width, height: size.height)
    } else {
      VStack(spacing: 8) {
        Image(systemName: "camera.viewfinder").font(.system(size: 34)).foregroundStyle(.secondary)
        Text(camera.connected ? "等待实时取景…" : camera.phase == .missing ? "这份 App 没有带 Sony SDK" : "在左边连接相机")
          .font(.system(size: 13)).foregroundStyle(.secondary)
      }.frame(width: size.width, height: size.height)
    }
  }
  /// The live frame as shown: zoomed about the focus point, through the chosen gel.
  func view(_ live: CGImage) -> CGImage {
    var image = live
    if zoom > 1 {
      let w = CGFloat(live.width) / CGFloat(zoom), h = CGFloat(live.height) / CGFloat(zoom)
      let x = min(max(camera.focusPoint.x * CGFloat(live.width) - w / 2, 0), CGFloat(live.width) - w)
      let y = min(max(camera.focusPoint.y * CGFloat(live.height) - h / 2, 0), CGFloat(live.height) - h)
      image = live.cropping(to: CGRect(x: x, y: y, width: w, height: h).integral) ?? live
    }
    return m.channelView.apply(image)
  }
  func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
    let k = min((box.width - 24) / max(1, size.width), (box.height - 24) / max(1, size.height))
    return CGSize(width: size.width * k, height: size.height * k)
  }
  /// Focusing on one row, the shot on the next. With SwiftUI's glass each group is a drop of its
  /// own, AF and 精确对焦 drops that give under the finger, the pixel-shift files counted in beads
  /// of glass, and each note of a picture filed rising out of the shutter as a drop pinches off.
  var controls: some View {
    let liquid = Liquid.available
    return VStack(spacing: 8) {
      HStack(spacing: 10) {
        Button {
          camera.autofocus()
        } label: {
          Label("AF", systemImage: "scope").lineLimit(1).fixedSize()
        }.help("半按快门，在对焦框处自动对焦（相机要在 AF 模式）").environment(\.glassKeys, liquid)
        let stepping = HStack(spacing: 3) {
          ForEach([-7, -3, -1], id: \.self) { s in
            Button { camera.step(s) } label: { Text(s == -7 ? "«" : s == -3 ? "‹‹" : "‹").frame(width: 16) }
              .help("对焦往近处走（Near \(-s) 档，要手动对焦模式）")
          }
          FocusRing(offset: $ring) { camera.step($0) }.frame(width: 120, height: 24)
          ForEach([1, 3, 7], id: \.self) { s in
            Button { camera.step(s) } label: { Text(s == 7 ? "»" : s == 3 ? "››" : "›").frame(width: 16) }
              .help("对焦往远处走（Far \(s) 档，要手动对焦模式）")
          }
        }
        if liquid { drop(stepping) } else { stepping }
        Button {
          camera.refining ? camera.cancelRefine() : camera.refineFocus()
        } label: {
          Label(camera.refining ? "停止" : "精确对焦", systemImage: "camera.metering.center.weighted")
        }.help("切到手动对焦，按对焦框里的颗粒清晰度一步步找最清楚的位置（7、3、1 档逐级）").environment(\.glassKeys, liquid)
        Spacer(minLength: 0)
      }
      HStack(spacing: 10) {
        let shifting = HStack(spacing: 10) {
          Picker("像素位移", selection: $m.pixelShiftCount) {
            Text("单张").tag(1)
            Text("位移 4").tag(4)
            Text("位移 16").tag(16)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
            .help("像素位移要先在相机上设好；这里只决定几张文件归成一组")
          if m.pixelShiftCount > 1 { ShiftBeads(count: m.pixelShiftCount, got: m.pendingShift.count) }
        }
        if liquid { drop(shifting) } else { shifting }
        Spacer()
        ShutterKey(enabled: camera.connected && !camera.awaitingPicture, shots: camera.shots) { camera.shoot() }
          .help(camera.awaitingPicture ? "上一张还在写入和传输，到了再拍" : "拍摄（空格）")
          .overlay(alignment: .topTrailing) {
            if liquid, let toast = m.captureToast {
              DropToast(text: toast).id(toast).transition(.scale(scale: 0.3, anchor: .bottomTrailing).combined(with: .opacity))
            }
          }
      }
    }.buttonStyle(HardwareKeyStyle()).controlSize(.small).disabled(!camera.connected && camera.phase != .missing)
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
            $0.overlay(Circle().fill(lit ? Hardware.amber : Color.white.opacity(0.16)))
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
  var body: some View {
    Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(white: 0.96)).fixedSize()
      .padding(.horizontal, 14).padding(.vertical, 7)
      .liquid(Capsule(), LiquidStyle(tint: .black.opacity(0.3))) { $0.glassPane(radius: 16, darken: 0.35) }
      .offset(y: risen ? -58 : -18)
      .allowsHitTesting(false)
      .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.6).delay(0.08)) { risen = true } }
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
/// the screen or larger, unsmoothed, through the chosen gel, with its sharpness channel by channel.
struct FocusCheck: View {
  @ObservedObject var m: AppModel
  @ObservedObject var camera: CameraController
  @State private var crop: CGImage?
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
      ZStack {
        Rectangle().fill(Color.black.opacity(0.4))
        if let crop {
          let shown = m.channelView.apply(crop)
          let pixels = 248 / CGFloat(scale)
          Image(decorative: shown, scale: NSScreen.main?.backingScaleFactor ?? 2).resizable().interpolation(.none)
            .frame(width: CGFloat(shown.width) * CGFloat(scale) / (NSScreen.main?.backingScaleFactor ?? 2),
              height: CGFloat(shown.height) * CGFloat(scale) / (NSScreen.main?.backingScaleFactor ?? 2))
            .frame(width: 248, height: 248).clipped()
            .help(String(format: "每个文件像素放大到 %d 个屏幕像素；窗口里约 %.0f × %.0f 个文件像素", scale, pixels, pixels))
        } else {
          Text(loading ? "读取中…" : "拍一张后在这里看对焦").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }.frame(width: 248, height: 248)
      if let crop {
        let s = FocusSearch.sharpness(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        Text(String(format: "清晰度 × 10⁴\nR %.1f\nG %.1f\nB %.1f", s.r * 1e4, s.g * 1e4, s.b * 1e4)).lcd(10)
          .help("这块原图的清晰度：三个通道差得多时，说明有色差，红和蓝的焦点不在同一处")
      }
      if let url = m.lastCapture {
        Text(url.lastPathComponent).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        Button("按对焦点重新取") { load(url) }.font(.system(size: 11))
      }
      Text("取的是相机文件本身的全分辨率像素（RAW 按系统默认显示），以对焦框的位置为中心。")
        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Spacer()
    }.padding(16).buttonStyle(HardwareKeyStyle()).controlSize(.small)
      .onChange(of: m.lastCapture) { _, url in if let url { load(url) } }
      .onAppear { if crop == nil, let url = m.lastCapture { load(url) } }
  }
  func load(_ url: URL) {
    loading = true
    let point = camera.focusPoint
    AppModel.captureQueue.async {
      let image = AppModel.focusCrop(url, at: point, side: 248)
      DispatchQueue.main.async {
        crop = image
        loading = false
      }
    }
  }
}

/// Module ①'s left panel with the camera: connection, exposure, focus mode, file type, where the
/// pictures go, pixel shift, and the log for when something does not work.
struct CameraPanel: View {
  @ObservedObject var m: AppModel
  @ObservedObject var camera: CameraController
  @State private var keepOnCard = false
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        StatusLED(lamp: camera.connected ? .ready : camera.phase == .connecting ? .busy : .fault, size: 7)
        Text(camera.connected ? camera.model : camera.phase == .missing ? "没有 SDK" : camera.phase == .connecting ? "连接中" : "未连接").lcd(10)
        Spacer()
        if let battery = camera.properties["BatteryRemain"] { Text("电量 \(battery.text)").font(.system(size: 10)).foregroundStyle(.secondary) }
      }
      if !camera.message.isEmpty {
        Text(camera.message).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if camera.connected {
          Button("断开") { camera.disconnect() }
          Button(camera.liveOn ? "关实时取景" : "开实时取景") { camera.setLive(!camera.liveOn) }
        } else {
          Button {
            camera.connect(keepOnCard: keepOnCard)
          } label: {
            Label("连接相机", systemImage: "cable.connector")
          }.buttonStyle(HardwareKeyStyle(prominent: true)).disabled(camera.phase == .missing || camera.phase == .connecting)
        }
      }
      Toggle("存储卡上也留一份", isOn: $keepOnCard).toggleStyle(LEDToggleStyle()).font(.system(size: 11))
        .disabled(camera.connected).help("连接时设定：只存到电脑，或电脑和存储卡各一份（要插卡）")
      if camera.connected {
        Divider()
        Text("曝光").font(.system(size: 12, weight: .medium))
        setting("快门", "ShutterSpeed")
        setting("光圈", "FNumber")
        setting("ISO", "IsoSensitivity")
        setting("模式", "ExposureProgramMode")
        setting("曝光补偿", "ExposureBiasCompensation")
        Text("模式由相机上的转盘决定：M 档时快门、光圈都能改，A 档只改光圈，S 档只改快门。光圈要电子镜头才能远程改（比如 Sigma 70mm F2.8 DG Macro Art）；翻拍底片一般从 f/5.6–8 开始试。")
          .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Divider()
        Text("白平衡").font(.system(size: 12, weight: .medium))
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
        Text("RAW 的数据不受白平衡影响，App 解码时整卷固定 5500K；这里只改实时取景和 JPEG 的颜色。固定一个色温，取景每张颜色一致。")
          .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Divider()
        Text("对焦").font(.system(size: 12, weight: .medium))
        HStack {
          Button("AF-S") { camera.set("FocusMode", 2) }
          Button("MF") { camera.set("FocusMode", 1) }
          Spacer()
          Text(camera.properties["FocusMode"]?.text ?? "--").lcd(10)
        }
        setting("区域", "FocusArea")
        if let f = camera.properties["FocusIndication"] { labeled("状态", f.text) }
        Text("点取景画面移动对焦点：对焦区域要是「自由点」。精确对焦会切到 MF。")
          .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Divider()
        Text("文件").font(.system(size: 12, weight: .medium))
        setting("格式", "FileType")
        setting("保存到", "StillImageStoreDestination")
        Text("RAW 请在相机菜单里设为「无压缩」，SDK 改不了这一项。")
          .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      Text("像素位移").font(.system(size: 12, weight: .medium))
      Text("像素位移只能在相机上设：拍摄菜单里选「像素位移多重拍摄」，张数选 4 或 16，间隔选最短。下方取景区右侧选同样的张数，App 会按快门、把这一组文件放进同一个文件夹。合成还没做，先用每组第一张转换。")
        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
      Text(value).lcd(10)
    }
  }
  /// A setting with the values the camera offers for it.
  func setting(_ title: String, _ name: String) -> some View {
    let p = camera.properties[name]
    return HStack {
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
      Spacer()
      if let p, p.settable, !p.values.isEmpty {
        Menu(p.text) {
          ForEach(p.values, id: \.self) { v in
            Button(CameraProperty.describe(name, v)) { camera.set(name, v) }
          }
        }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
      } else {
        Text(p?.text ?? "--").lcd(10)
      }
    }
  }
}

/// The light table's loupe over the live view: the same ray-marched loupe, standing at the focus
/// point, seen from in front, magnifying the live picture as much as its pixels allow (the
/// camera's own magnifier shows the sensor's pixels; the live picture is only 1024 across).
enum LiveLoupe {
  static func render(_ live: CGImage, size: CGSize, at point: CGPoint, style: LoupeStyle, backing: CGFloat) -> (image: CGImage, frame: CGRect)? {
    guard size.width > 40, size.height > 40 else { return nil }
    let radius = min(size.width, size.height) * 0.2 * CGFloat(style.baseMM / 48).squareRoot()
    let perPoint = Double(live.width) / Double(size.width)
    let pose = LoupeRenderer.Pose(
      style: style, center: point, radius: radius,
      eye: SIMD3(Float(size.width / 2), Float(size.height), Float(max(size.width, size.height) * 2)),
      magnification: min(style.magnification, max(2, perPoint * 1.5)))
    let frame = CGRect(x: point.x - radius * 2.1, y: point.y - radius * 2.1, width: radius * 4.2, height: radius * 4.2)
      .intersection(CGRect(origin: .zero, size: size)).integral
    guard frame.width > 1, frame.height > 1 else { return nil }
    let scene = LoupeRenderer.Scene(table: live, canvas: size, film: live, filmRect: CGRect(origin: .zero, size: size))
    // One ray a pixel: it is drawn again for every frame the camera sends.
    return LoupeRenderer.shared.render(frame: frame, scale: backing, pose: pose, scene: scene, samples: 1).map { ($0, frame) }
  }
}
