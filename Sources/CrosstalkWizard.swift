import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 去串色校准: the copy light's crosstalk measured step by step. With nothing on the stand, the red,
/// green and blue lights are each shot alone; every frame is read as it comes (is it the light asked
/// for, exposed well, lit by it alone), and from the three the matrix, shown beside the one in use
/// before it replaces it. The frames go to the wizard's folder, not into a roll.
struct LightWizard: Equatable {
  /// 0 what to set up, 1–3 the red, green and blue light, 4 the matrix.
  var step = 0
  var shots: [LightShot?] = [nil, nil, nil]
  /// A frame being read.
  var reading = false
  /// Where the camera's frames are kept: made with the first, kept with the calibration, removed
  /// when the wizard is cancelled.
  var folder: URL
  /// Counts the frames sent to be read, so one read after another came in is dropped.
  var token = 0
  /// The light the step is for.
  var light: Int? { (1...3).contains(step) ? step - 1 : nil }
  /// The crosstalk the three frames give, when each can be used.
  var crosstalk: Crosstalk? {
    let readings = shots.compactMap { $0?.usable == true ? $0?.reading : nil }
    return readings.count == 3 ? ImagePipeline.crosstalk(readings) : nil
  }
}

/// One light's frame in `LightWizard`.
struct LightShot: Equatable {
  var file: URL
  /// The camera's frame, kept in the wizard's folder (removed with it); else a file chosen where it is.
  var owned: Bool
  var reading: ImagePipeline.LightReading?
  /// Why it cannot be used, or what could be better.
  var problem: String?
  var warning: String?
  var usable: Bool { reading != nil && problem == nil }
}

extension AppModel {
  static let lightNames = ["红", "绿", "蓝"]
  /// Where the wizard's frames are kept, a folder for each calibration.
  static var lightShotRoot = Updater.supportRoot.appendingPathComponent("光源标定", isDirectory: true)

  func openLightWizard() {
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.dateFormat = "yyyy-MM-dd HHmmss"
    lightWizard = LightWizard(folder: Self.unused(Self.lightShotRoot.appendingPathComponent(stamp.string(from: Date()), isDirectory: true)))
  }
  /// Closed without a calibration: the camera's frames it kept go with it.
  func cancelLightWizard() {
    guard let w = lightWizard else { return }
    lightWizard = nil
    for shot in w.shots.compactMap({ $0 }) where shot.owned { try? FileManager.default.removeItem(at: shot.file) }
    if (try? FileManager.default.contentsOfDirectory(atPath: w.folder.path))?.isEmpty == true {
      try? FileManager.default.removeItem(at: w.folder)
    }
  }
  func lightWizardStep(_ step: Int) {
    guard var w = lightWizard, (0...4).contains(step) else { return }
    // On only past a light that has a frame to use, and to the matrix once all three have.
    if step > w.step, let light = w.light, w.shots[light]?.usable != true { return }
    if step == 4, w.crosstalk == nil { return }
    w.step = step
    lightWizard = w
  }
  /// The camera's shutter, for the step's light: over a focus lock, kept held after the picture,
  /// as the next light's blank frame gives the camera nothing to focus on.
  func shootLightFrame() {
    guard lightWizard?.light != nil, camera.connected else { return }
    camera.shoot(keepFocus: true)
  }
  /// A picture the camera sent while the wizard is open: the step's light, kept in its folder; on
  /// another step it is kept there unused and said so.
  func receiveLightShot(_ url: URL) {
    guard let w = lightWizard else { return }
    let files = FileManager.default
    let name = w.light.map { Self.lightNames[$0] + "灯-" } ?? "未用-"
    do {
      try files.createDirectory(at: w.folder, withIntermediateDirectories: true)
      let dest = Self.unused(w.folder.appendingPathComponent(name + url.lastPathComponent))
      do { try files.moveItem(at: url, to: dest) } catch { try files.copyItem(at: url, to: dest) }
      guard w.light != nil else {
        status = "去串色校准开着：这张没有进卷，也没有用来标定（\(dest.lastPathComponent)）"
        return
      }
      readLightShot(dest, owned: true)
    } catch { errorText = "收不下相机拍的照片：\(error.localizedDescription)" }
  }
  /// A frame already shot, for the step's light, read where it is.
  func useLightShot(_ url: URL) {
    guard lightWizard?.light != nil else { return }
    readLightShot(url, owned: false)
  }
  private func readLightShot(_ file: URL, owned: Bool) {
    guard var w = lightWizard, let light = w.light else { return }
    w.token += 1
    w.reading = true
    lightWizard = w
    let token = w.token
    // Locked, the camera takes no setting: what to change is the light, not the shutter.
    let locked = camera.focusLocked
    Self.captureQueue.async {
      var shot = LightShot(file: file, owned: owned)
      do {
        let image: CGImage, sensor: Bool
        if Self.rawExtensions.contains(file.pathExtension.lowercased()) {
          (image, sensor) = try Self.linearImage(fromRAW: file)
        } else {
          (image, sensor) = (try ImagePipeline.shared.load(file, maxDimension: 1200), true)
        }
        shot.reading = ImagePipeline.shared.lightReading(image)
        if !sensor {
          shot.problem = "这张 RAW 不是直接从传感器读出来的（压缩 RAW 或别的格式，系统的 RAW 引擎已经混过颜色）：请把相机的 RAW 设为无压缩再拍。"
        } else if let reading = shot.reading {
          (shot.problem, shot.warning) = Self.lightVerdict(reading, light: light, locked: locked)
        } else {
          shot.problem = "读不出这张的像素。"
        }
      } catch {
        shot.problem = "读不了这张：\(error.localizedDescription)"
      }
      DispatchQueue.main.async {
        guard var w = self.lightWizard, w.token == token else {
          if owned, self.lightWizard == nil { try? FileManager.default.removeItem(at: file) }
          return
        }
        if let old = w.shots[light], old.owned, old.file != file { try? FileManager.default.removeItem(at: old.file) }
        w.shots[light] = shot
        w.reading = false
        self.lightWizard = w
        self.status = shot.usable ? "\(Self.lightNames[light])灯这张可以用" : "\(Self.lightNames[light])灯这张要重拍"
      }
    }
  }
  /// What keeps a frame of `light` alone from measuring its crosstalk, and what could be better;
  /// with the focus `locked`, the camera takes no setting, so the light is to be turned up or down.
  static func lightVerdict(_ r: ImagePipeline.LightReading, light: Int, locked: Bool = false) -> (problem: String?, warning: String?) {
    let names = lightNames, want = names[light]
    let percent = Int((r.peak * 100).rounded())
    let stops = log2(0.7 / max(r.peak, 0.001))
    let slower = locked ? "把\(want)灯调亮约 %.1f 档" : "快门慢约 %.1f 档"
    if r.clipped > 0.005 {
      return (String(format: "过曝：%.1f%% 的地方到了满量程。" + (locked ? "把\(want)灯调暗一档以上" : "快门快一档以上") + "再拍，最亮处约 70%% 最好。", r.clipped * 100), nil)
    }
    if r.peak < 0.15 {
      return (String(format: "太暗：最亮处只到满量程的 %d%%。" + slower + "再拍（到最亮处约 70%%）。", percent, stops), nil)
    }
    if r.own != light {
      return ("这张最亮的是\(names[r.own])通道，像是开着\(names[r.own])灯。只开\(want)灯，其他两种关掉，再拍一张。", nil)
    }
    let leak = r.leak
    if leak.share >= 0.6 {
      return (String(format: "\(names[leak.channel])通道也读到了\(want)通道的 %.0f%%，像是不止开了一种灯。只开\(want)灯再拍。", leak.share * 100), nil)
    }
    if r.count <= 100 {
      return ("画面上曝光合适的地方太少：拿走底片和挡光的东西，让灯照满画面再拍。", nil)
    }
    var notes = [String]()
    if r.peak < 0.4 { notes.append(String(format: "偏暗：最亮处 %d%%。能用，但小的串色会读得不准；" + slower + "更好。", percent, stops)) }
    if r.peak > 0.92 { notes.append("接近过曝：最亮处 \(percent)%，" + (locked ? "灯暗一点" : "快一点") + "更稳。") }
    if r.spread > 0.25 {
      notes.append(String(format: "画面各处读进\(names[leak.channel])通道的比例不一样（相差 %.0f%%）：可能有房间的灯或别的灯漏进来。", r.spread * 100))
    }
    return (nil, notes.isEmpty ? nil : notes.joined(separator: "\n"))
  }
  /// The three frames' crosstalk kept for the copies to come, and the open roll read through it when
  /// its crosstalk is taken out.
  func applyLightWizard() {
    guard let w = lightWizard, let crosstalk = w.crosstalk else { return }
    let sources = w.shots.compactMap { $0?.file.path }
    lightWizard = nil
    preferences.lightCalibration = LightCalibration(date: Date(), crosstalk: crosstalk, sources: sources)
    let leak = crosstalk.largestLeak, names = Self.lightNames
    status = String(format: "已标定光源：%@灯漏进%@通道 %.0f%%", names[leak.light], names[leak.channel], leak.share * 100)
    if crosstalkRemoved || preferences.removeCrosstalk { removeCrosstalk(true) }
  }
  /// The copy presets calibrated with the crosstalk taken out: their slopes were read through the
  /// matrix in use then.
  var presetsReadUnmixed: [FilmProfile] { preferences.customProfiles.filter { $0.offsets != nil && $0.readsUnmixed == true } }
}

/// The wizard's sheet: a step at a time, the light to switch on, the shutter, and what each frame read.
struct LightWizardSheet: View {
  @ObservedObject var m: AppModel
  @ObservedObject var camera: CameraController
  static let tints: [Color] = [Color(red: 0.86, green: 0.2, blue: 0.18), Color(red: 0.2, green: 0.62, blue: 0.3), Color(red: 0.2, green: 0.4, blue: 0.9)]
  var body: some View {
    let w = m.lightWizard ?? LightWizard(folder: AppModel.lightShotRoot)
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text("去串色校准").font(.system(size: 15, weight: .semibold))
        Text("算出翻拍灯每种颜色有多少读进了相机别的通道").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
      }
      steps(w)
      Divider()
      Group {
        switch w.step {
        case 0: prepare
        case 1...3: lightStep(w, light: w.step - 1)
        default: result(w)
        }
      }
      Spacer(minLength: 0)
      Divider()
      HStack {
        Button("取消") { m.cancelLightWizard() }.keyboardShortcut(.cancelAction)
        Spacer()
        if w.step > 0 { Button("上一步") { m.lightWizardStep(w.step - 1) } }
        if w.step < 4 {
          let ready = w.light.map { w.shots[$0]?.usable == true } ?? true
          Button(w.step == 3 ? "算出矩阵" : w.step == 0 ? "开始" : "下一步") { m.lightWizardStep(w.step + 1) }
            .buttonStyle(KeyStyle(prominent: true)).keyboardShortcut(.defaultAction)
            .disabled(!ready || w.reading || (w.step == 3 && w.crosstalk == nil))
        } else {
          Button("使用这组矩阵") { m.applyLightWizard() }.buttonStyle(KeyStyle(prominent: true)).keyboardShortcut(.defaultAction)
            .disabled(w.crosstalk == nil)
        }
      }
    }
    .padding(20)
    .frame(width: 580, height: 540)
  }

  /// The five steps, the one shown marked, a light's ticked once its frame can be used.
  func steps(_ w: LightWizard) -> some View {
    let titles = ["准备", "红灯", "绿灯", "蓝灯", "结果"]
    return HStack(spacing: 6) {
      ForEach(0..<5, id: \.self) { i in
        let done = (1...3).contains(i) && w.shots[i - 1]?.usable == true
        HStack(spacing: 4) {
          if (1...3).contains(i) { Circle().fill(Self.tints[i - 1]).frame(width: 7, height: 7) }
          Text(titles[i]).font(.system(size: 12, weight: i == w.step ? .semibold : .regular))
          if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(i == w.step ? Color.primary.opacity(0.1) : Color.clear))
        if i < 4 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
      }
    }
  }

  var prepare: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array([
        "镜头、光圈和放大倍率和翻拍时一样。相机拍单张（不开像素位移），RAW 设为无压缩。",
        "关掉房间的灯、挡住窗户：别的光会被算成串色。",
        "先锁焦：底片还在时按「AF 锁焦」，再拿走底片，片夹里、灯上什么都不放。空白画面上相机合不了焦，所以三张都按住半按拍，焦点一直锁着，拍完也不松开。",
        "每一步只开一种灯，曝光到最亮处约 70%。锁焦时相机不收设置，快门改不了：快门在锁焦前对着取景的直方图定好，三种灯亮暗不一时在灯上调。",
      ].enumerated()), id: \.offset) { i, line in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("\(i + 1)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
          Text(line).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
      }
      Divider()
      Label(camera.connected ? "相机已连接（\(camera.model)）：每一步点「拍摄」。"
        : "相机没有连接：可以先关掉这个窗口连上相机，也可以每一步选一张已经拍好的 RAW。",
        systemImage: camera.connected ? "camera" : "camera.badge.ellipsis")
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if camera.connected { focusLock }
      if m.pixelShiftCount > 1 {
        Label("取景区下方现在是位移 \(m.pixelShiftCount) 张：标定拍单张就够，先改成「单张」更快。", systemImage: "exclamationmark.triangle")
          .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
      Text(m.lightDescription).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  func lightStep(_ w: LightWizard, light: Int) -> some View {
    let name = AppModel.lightNames[light]
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Circle().fill(Self.tints[light]).frame(width: 22, height: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text("只开\(name)灯").font(.system(size: 15, weight: .semibold))
          Text("另外两种灯关掉，灯上什么都不放。").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer()
      }
      HStack(spacing: 10) {
        Button {
          m.shootLightFrame()
        } label: {
          Label("拍摄", systemImage: "camera.aperture")
        }
        .buttonStyle(KeyStyle(prominent: w.shots[light] == nil))
        .disabled(!camera.connected || camera.awaitingPicture || w.reading)
        .help(camera.connected ? "按快门：这张交给校准，不进胶片条" : "相机没有连接")
        Button("选文件…") { choose() }.disabled(w.reading)
          .help("用一张已经拍好的、只开\(name)灯的空白帧（无压缩 RAW）")
        Spacer()
        if camera.connected { shutter }
      }
      if camera.connected { focusLock }
      if w.reading {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("正在读取…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
      } else if let shot = w.shots[light] {
        shotView(shot, light: light)
      } else {
        Text("还没有这一张。拍完 App 会马上读出曝光和串色，不合适会告诉你怎么改。")
          .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// Whether the focus is locked for the blank frames, and the key that locks or lets go of it.
  var focusLock: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      if camera.focusLocked {
        Label("已锁焦：每一张都按住半按拍，焦点不动，拍完也不松开。锁焦时相机不收设置，快门改不了。", systemImage: "lock.fill")
          .foregroundStyle(.secondary)
        Spacer(minLength: 6)
        Button("解除锁焦") { camera.unlockFocus() }
          .help("松开半按。之后快门会先对焦，空白画面上合不了焦；要再锁住，放回底片按 AF 锁焦")
      } else if camera.autofocusMode {
        Label("没有锁焦：空白画面上相机合不了焦，按快门可能拍不出来，焦点也会跑。放回底片（或别的有纹理的东西）按「AF 锁焦」，再拿走。", systemImage: "lock.open")
          .foregroundStyle(.orange)
        Spacer(minLength: 6)
        Button("AF 锁焦") { camera.autofocus() }
          .help("对焦一次并按住半按，焦点锁住：之后的每一张都不再对焦")
      } else {
        Label("镜头在手动对焦：快门不对焦，焦点不动。", systemImage: "lock.fill").foregroundStyle(.secondary)
      }
    }
    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
  }

  /// The camera's shutter speed, a step either way, beside the shutter; locked, the camera takes no
  /// setting, and it is shown only.
  var shutter: some View {
    let name = "ShutterSpeed", p = camera.properties[name]
    return HStack(spacing: 6) {
      Text("快门").font(.system(size: 12)).foregroundStyle(.secondary)
      if let p, p.settable, !p.values.isEmpty, !camera.focusLocked {
        let all = p.choices
        let i = all.firstIndex(of: p.value)
        let back: (() -> Void)? = i.flatMap { k in k > 0 ? { camera.set(name, all[k - 1]) } : nil }
        let on: (() -> Void)? = i.flatMap { k in k + 1 < all.count ? { camera.set(name, all[k + 1]) } : nil }
        CameraStepper(text: p.text, choices: all.map { v in (CameraProperty.describe(name, v), { camera.set(name, v) }) }, back: back, on: on)
      } else {
        Text(p?.text ?? "--").font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
          .help(camera.focusLocked ? "锁焦时相机不收设置：要改快门，先解除锁焦，改完放回底片再按 AF 锁焦" : "")
      }
    }
  }

  func shotView(_ shot: LightShot, light: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(shot.file.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      if let r = shot.reading {
        HStack(alignment: .bottom, spacing: 14) {
          ForEach(0..<3, id: \.self) { c in
            let share = c == r.own ? r.peak : r.column[c] * r.peak
            VStack(spacing: 4) {
              ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 34, height: 90)
                RoundedRectangle(cornerRadius: 3).fill(Self.tints[c].opacity(c == r.own ? 1 : 0.55))
                  .frame(width: 34, height: max(1, 90 * min(1, share)))
              }
              Text("\(AppModel.lightNames[c])通道").font(.system(size: 11)).foregroundStyle(.secondary)
              Text(c == r.own ? "100%" : String(format: "%.1f%%", r.column[c] * 100))
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(c == r.own ? .secondary : .primary)
            }
          }
          VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "最亮处到满量程的 %.0f%%（目标约 70%%）", r.peak * 100)).font(.system(size: 12))
            Text("另外两格是这种灯读进别的通道的光，以\(AppModel.lightNames[r.own])通道为 100%。").font(.system(size: 11)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
        }
      }
      if let problem = shot.problem {
        Label(problem, systemImage: "xmark.octagon").font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      } else {
        Label("可以用", systemImage: "checkmark.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
        if let warning = shot.warning {
          Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  func result(_ w: LightWizard) -> some View {
    let now = m.preferences.lightCalibration?.crosstalk ?? .measured
    let names = AppModel.lightNames
    return VStack(alignment: .leading, spacing: 12) {
      if let x = w.crosstalk {
        Text("每种灯读进相机各通道的多少（按这种灯自己的通道为 100%），括号里是现在用的：")
          .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Grid(alignment: .trailing, horizontalSpacing: 22, verticalSpacing: 8) {
          GridRow {
            Text("")
            ForEach(0..<3, id: \.self) { j in
              HStack(spacing: 4) {
                Circle().fill(Self.tints[j]).frame(width: 7, height: 7)
                Text("\(names[j])灯").font(.system(size: 12, weight: .medium))
              }
            }
          }
          ForEach(0..<3, id: \.self) { c in
            GridRow {
              Text("相机\(names[c])通道").font(.system(size: 12)).foregroundStyle(.secondary)
              ForEach(0..<3, id: \.self) { j in
                let v = x.m[3 * c + j], was = now.m[3 * c + j]
                VStack(alignment: .trailing, spacing: 1) {
                  Text(c == j ? "100%" : String(format: "%.1f%%", v * 100)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(c == j ? .secondary : .primary)
                  if c != j {
                    Text(String(format: "（%.1f%%）", was * 100)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }
        let leak = x.largestLeak
        Text(String(format: "最大的是%@灯读进%@通道 %.1f%%。", names[leak.light], names[leak.channel], leak.share * 100)
          + (m.preferences.lightCalibration == nil ? "现在用的是 2026-10-29 用 IT8 色卡测的。" : ""))
          .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        let roll = m.frames.filter { $0.sensorRead == true }.count
        Text("使用以后，之后拍进来的照片按这组矩阵去串色" + (roll > 0 && (m.crosstalkRemoved || m.preferences.removeCrosstalk) ? "；这一卷的 \(roll) 张也按它重读。" : "。"))
          .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        let presets = m.presetsReadUnmixed
        if !presets.isEmpty {
          Label("有 \(presets.count) 个翻拍预设是在去串色开着时标定的，它们的斜率按原来的矩阵读出；换了矩阵会差一点，最好在新矩阵下重新标定。",
            systemImage: "exclamationmark.triangle")
            .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text("三张里有不能用的，回到前面重拍。").font(.system(size: 12)).foregroundStyle(.red)
      }
    }
  }

  func choose() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.rawImage, .tiff] + AppModel.rawExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    panel.message = "选一张只开这一种灯、不放底片拍的空白帧"
    if panel.runModal() == .OK, let url = panel.url { m.useLightShot(url) }
  }
}
