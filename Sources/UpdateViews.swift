import SwiftUI

/// The version in use, what the feed offers and what it changes, and the keys to look again,
/// fetch it or update now. Opened from 「检查更新…」 in the app menu and from the status line.
struct UpdateSheet: View {
  @ObservedObject var m: AppModel
  @ObservedObject var updater: Updater
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("更新").font(.system(size: 15, weight: .semibold))
        Text("在用 \(updater.version)（\(updater.build)）").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        InfoButton(text: "放在「应用程序」文件夹里的 Epson Scan plus 会自己更新：打开后几秒和之后每六小时看一次更新列表，有新版本就下载，核对发布签名、校验值和代码签名，退出时换上新版本，下次打开就是新的。也可以点「现在更新并重新打开」。\n\n更新列表默认是这台 Mac 上的发布目录（\(Updater.localFeed.deletingLastPathComponent().path)），不联网。换下来的旧版本放在 \(updater.parkRoot.path)，留最近 \(Updater.keptVersions) 个，更早的移到废纸篓。\n\n别处的副本（试用版、磁盘映像里的）不会自己更新。")
      }
      Text(updater.status).font(.system(size: 12)).foregroundStyle(updater.release == nil ? Color.secondary : Hardware.amber)
        .fixedSize(horizontal: false, vertical: true)
      if let r = updater.release {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(Array(r.notes.prefix(8).enumerated()), id: \.offset) { _, line in
            Text("· " + line).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
          }
          if r.notes.count > 8 { Text("等 \(r.notes.count) 项").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
      }
      Toggle("自动下载新版本，退出时安装", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
        .toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 12)).disabled(!updater.updatesItself)
      HStack {
        Button("检查更新") { updater.check() }.disabled(!updater.updatesItself || !updater.canCheck)
        if case .available(let r) = updater.phase {
          Button("下载 \(r.version)") { updater.prepare(r) }
        }
        if case .ready = updater.phase {
          Button("现在更新并重新打开") { updater.install(relaunch: true) }
            .disabled(m.isWorking).help(m.isWorking ? "扫描或导出完了再更新" : "退出、换上新版本、再打开")
        }
        Spacer()
        Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}

/// In the workspace's status line while a newer version is on offer or ready: what it is, and the
/// key to see it.
struct UpdateNotice: View {
  @ObservedObject var m: AppModel
  @ObservedObject var updater: Updater
  var body: some View {
    if let r = updater.release {
      Button {
        m.showUpdates = true
      } label: {
        HStack(spacing: 5) {
          StatusLED(lamp: .busy, size: 6)
          Text(updater.phase == .ready(r) ? "\(r.version) 退出时更新" : "新版本 \(r.version)").font(.system(size: 11))
        }
      }
      .buttonStyle(.plain).foregroundStyle(Hardware.amber).help(updater.status)
    }
  }
}
