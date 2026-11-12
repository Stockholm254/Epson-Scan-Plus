import SwiftUI

/// The keys the app answers to, in one sheet (⌘/, and in the Help menu), as Lightroom lays its
/// shortcuts out: what the menus hold, and the single keys over the picture no menu shows.
enum Shortcuts {
  struct Key: Identifiable {
    let keys: String
    let does: String
    var id: String { keys + does }
  }
  struct Group: Identifiable {
    let title: String
    let keys: [Key]
    var id: String { title }
  }
  /// A canvas tool's own key, as its letter on a key cap.
  static func cap(_ tool: CanvasTool) -> String { tool.shortcut?.uppercased() ?? "" }
  static let groups: [Group] = [
    Group(title: "库和模块", keys: [
      Key(keys: "⇧⌘L", does: "库"),
      Key(keys: "⌥⌘1 – 3", does: "① 采集、② 去色罩、③ 调色"),
      Key(keys: "⌘N", does: "新建工程"),
      Key(keys: "⌘O", does: "导入图像（去漏光页里导入正片）"),
      Key(keys: "⇧⌘O", does: "打开工程"),
      Key(keys: "⌘,", does: "扫描仪和相机的设置"),
    ]),
    Group(title: "扫描和翻拍", keys: [
      Key(keys: "⇧⌘P", does: "整幅预览"),
      Key(keys: "⇧⌘S", does: "扫描当前画面"),
      Key(keys: "⌘.", does: "取消扫描"),
      Key(keys: "空格", does: "拍摄（① 翻拍的取景）"),
    ]),
    Group(title: "看画面", keys: [
      Key(keys: "⌘1", does: "单张 / 接触表"),
      Key(keys: "← →", does: "上一张 / 下一张"),
      Key(keys: "\(AppModel.loupeShortcut.uppercased()) · ⌘L", does: "看片镜"),
      Key(keys: "⇧⌘D", does: "除尘标出"),
      Key(keys: "⌘I", does: "照片信息（EXIF）"),
      Key(keys: "⌘R · ⇧⌘R", does: "顺时针 / 逆时针旋转"),
      Key(keys: "⌘ 滚动 · 捏合", does: "缩放单张"),
      Key(keys: "Esc", does: "回到选择，缩放回适合"),
      Key(keys: "J", does: "显示溢出：纯白画成红、纯黑画成蓝"),
      Key(keys: "\\", does: "调色前 / 后（③ 调色的单张）"),
    ]),
    Group(title: "画面上的工具", keys: [
      Key(keys: cap(.select), does: "选择"),
      Key(keys: cap(.crop), does: "画面裁切（琥珀色）"),
      Key(keys: cap(.region), does: "去色罩区域（青色）"),
      Key(keys: cap(.base), does: "取片基"),
      Key(keys: cap(.neutral), does: "取中性灰"),
      Key(keys: cap(.curvePick), does: "曲线取点（取曲线点 / 取中性点）"),
      Key(keys: "⌫", does: "删除画框；去色罩区域工具时跟随画面"),
    ]),
    Group(title: "裁切时", keys: [
      Key(keys: "方向键 · ⇧", does: "移动裁切 1 像素 · 10 像素"),
      Key(keys: "[ ] · ⇧", does: "拉直 0.1° · 1°"),
      Key(keys: "回车", does: "完成裁切或去色罩区域"),
    ]),
    Group(title: "调整和导出", keys: [
      Key(keys: "⇧⌘A", does: "自动调整这张"),
      Key(keys: "⇧⌘C / ⇧⌘V", does: "拷贝调整 / 粘贴这一步的（③ 调色或 ② 去色罩）"),
      Key(keys: "⌥⇧⌘V", does: "选择性粘贴：一项项选要粘贴的"),
      Key(keys: "⌥⌘V", does: "粘贴上一张的（先前显示的那张，不用先拷贝）"),
      Key(keys: "⌘Z · ⇧⌘Z", does: "撤销 · 重做"),
      Key(keys: "双击滑块", does: "这一项恢复默认"),
      Key(keys: "⌘ 点选 · ⇧ 连选", does: "选几张一起导出"),
      Key(keys: "⌘E", does: "导出当前（或选中的几张）"),
      Key(keys: "⇧⌘E · ⌥⌘E", does: "导出勾选的 · 导出接触表"),
      Key(keys: "⌥⇧⌘E", does: "直接导出到「输出」里的位置，不弹窗口"),
      Key(keys: "⌥⌘L", does: "在去漏光里打开"),
    ]),
    // Lightroom's marks and its 选择 by them, on the picture, the strip and the light table.
    Group(title: "整理和选择", keys: [
      Key(keys: "0 – 5", does: "星级（0 去掉）"),
      Key(keys: "P · X", does: "留用 · 不要（再按一次取消）"),
      Key(keys: "6 – 9", does: "红、黄、绿、蓝色标签"),
      Key(keys: "⌘A", does: "选中全部画面"),
      Key(keys: "⌘D", does: "只选当前这张"),
      Key(keys: "⌥⌘A", does: "选中留用的；按星级、标签在「画面 › 选择画面」里"),
    ]),
  ]
}

struct ShortcutsSheet: View {
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("键盘快捷键").font(.system(size: 15, weight: .semibold))
        Spacer()
        Text("画面上的单个字母键在点过画面以后才收得到").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      // Three columns of two or three groups, each group's keys right-aligned against what they do.
      HStack(alignment: .top, spacing: 26) {
        column([Shortcuts.groups[0], Shortcuts.groups[1], Shortcuts.groups[6]])
        column([Shortcuts.groups[2], Shortcuts.groups[4]])
        column([Shortcuts.groups[3], Shortcuts.groups[5]])
      }
      HStack {
        Spacer()
        Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }.padding(20).frame(width: 940)
  }
  func column(_ groups: [Shortcuts.Group]) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(groups) { g in
        VStack(alignment: .leading, spacing: 5) {
          Text(g.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Hardware.amberText)
          Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(g.keys) { k in
              GridRow {
                Text(k.keys).font(.system(size: 11.5, weight: .medium, design: .rounded)).monospacedDigit()
                  .padding(.horizontal, 6).padding(.vertical, 2)
                  .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                  .gridColumnAlignment(.trailing)
                Text(k.does).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
