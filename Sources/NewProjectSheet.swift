import SwiftUI

/// 新建工程's questions, asked before the roll begins: which film it is (a preset, with its slopes
/// and any calibration), negative or slide, and its format. They start as last chosen; all three
/// can be changed later in ② 去色罩's film section, the format in ①'s 画面 too.
struct NewProjectSheet: View {
  @ObservedObject var m: AppModel
  @State private var profileID = ""
  @State private var reversal = false
  @State private var format = FilmFormat.auto
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("新建工程").font(.system(size: 15, weight: .semibold))
      Text("先选这一卷是什么胶片：① 采集、② 去色罩和 ③ 去漏光都按它来。之后在 ② 去色罩的「胶片」里也能改。")
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("胶片").gridColumnAlignment(.trailing)
          Picker("胶片", selection: $profileID) {
            ForEach(m.profiles) { p in Text(Self.title(p, among: m.profiles)).tag(p.id) }
          }.labelsHidden().frame(width: 290, alignment: .leading)
        }
        GridRow {
          Text("片种")
          Picker("片种", selection: $reversal) {
            Text("负片").tag(false)
            Text("反转片").tag(true)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
        }
        GridRow {
          Text("画幅")
          Picker("画幅", selection: $format) {
            ForEach(FilmFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }.labelsHidden().frame(width: 180, alignment: .leading)
        }
      }.font(.system(size: 12))
      Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("取消") { m.askingNewProject = false }.keyboardShortcut(.cancelAction)
        Button("开始") {
          let p = m.profiles.first { $0.id == profileID } ?? m.profile
          m.beginNewProject(profile: p, reversal: reversal, format: format)
        }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20).frame(width: 440)
    .onAppear {
      profileID = m.profile.id
      reversal = m.reversalRoll
      format = m.format
    }
  }
  private var note: String {
    format.shortMM == nil
      ? "画幅选「自动」时，扫描按画面自动识别，翻拍的照片长边按 135 画面的 36 mm 算。"
      : "翻拍时按「\(format.rawValue)」算画面在胶片上的大小，看片镜的视场和导出的 dpi 跟着它；扫描时按它识别画面。"
  }
  /// A preset as the film menu names it: with the day it was calibrated where another has its name.
  static func title(_ p: FilmProfile, among profiles: [FilmProfile]) -> String {
    guard profiles.filter({ $0.name == p.name }).count > 1,
      let day = p.publication.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression)
    else { return p.name }
    return "\(p.name)（\(p.publication[day])）"
  }
}
