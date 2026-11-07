import SwiftUI

/// ② 去色罩's dust: looked for on this frame or the whole roll, marked by hand, kept or filled.
struct DustSection: View {
  @ObservedObject var m: AppModel
  @AppStorage("dustSensitivity") private var sensitivity = DustSensitivity.medium.rawValue
  static let info = """
    「找灰尘」在负片上找比周围的胶片密得多的小点：灰尘、毛发和纤维挡住的光，三个颜色一样多，所以三个通道都比颗粒高出很多才算。画面里本来就小而亮的东西（树叶间的亮点、车灯）按胶片三层的反差走，绿比红多，不算；但水面和金属的反光也可能被当成灰尘，看一下标出的圆圈，点一下就留下。

    找到的灰尘用旁边的胶片补上：平滑的部分按周围接过去，颗粒从附近一块干净的胶片借来，补的地方只会变亮（负片上只减不增密度），不会留下暗印。补在负片的原始数据上、去色罩之前，以后改调色不用重做。

    「点选」：在单张上点一处没找到的灰尘去掉它；点标出的圆圈，去掉的改成留下，留下的改成去掉，手动标的撤掉。实线圆圈是去掉的，虚线是留下的。灵敏度「高」找得多，也更容易认错。

    只用于 16 位的负片（本程序的扫描和翻拍）。找灰尘按全分辨率，一张翻拍约几秒。
    """
  private var level: DustSensitivity { DustSensitivity(rawValue: sensitivity) ?? .medium }
  var body: some View {
    let frame = m.selected
    let dust = frame?.dust
    let usable = frame.map(m.dustApplies) ?? false
    PanelSection("除尘", key: "dust", open: false, info: Self.info) {
      Text(readout(dust)).readout()
    } content: {
      VStack(alignment: .leading, spacing: 9) {
        if let frame, usable {
          HStack(spacing: 6) {
            Button("找灰尘") { m.findDust([frame.id], sensitivity: level) }
              .help("在这一张上按全分辨率找灰尘")
            Button("整卷找") { m.findDust(m.frames.map(\.id), sensitivity: level) }
              .help("在本卷每一张上找灰尘；手动标的和点了留下的保留")
            Spacer(minLength: 4)
            Picker("灵敏度", selection: $sensitivity) {
              ForEach(DustSensitivity.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 96)
              .help("灵敏度：高 找得多，也更容易把画面里的小亮点当成灰尘")
          }.font(.system(size: 11)).disabled(m.dustSearch != nil)
          if let busy = m.dustSearch {
            Text(busy).font(.system(size: 11)).foregroundStyle(.secondary)
          }
          HStack(spacing: 6) {
            Button {
              m.useTool(m.tool == .dust ? .select : .dust)
            } label: {
              Label("点选", systemImage: CanvasTool.dust.symbol)
            }.buttonStyle(KeyStyle(latched: m.tool == .dust))
              .help("在单张上点灰尘去掉它，点圆圈改成留下或去掉")
            Spacer()
            Toggle("标出", isOn: $m.showDust).toggleStyle(.switch).controlSize(.mini)
              .help("在单张上用圆圈标出灰尘：实线去掉，虚线留下")
          }.font(.system(size: 11))
          if let dust, !dust.spots.isEmpty {
            HStack {
              Toggle("去掉灰尘", isOn: Binding(get: { dust.on }, set: { m.setDustFilled($0) }))
                .toggleStyle(.switch).tint(Hardware.accent).font(.system(size: 12))
              Spacer()
              Button("清除") { m.clearDust() }.font(.system(size: 11))
                .help("清除这一张找到的和手动标的灰尘")
            }
            Text(summary(dust)).font(.system(size: 11)).foregroundStyle(.secondary)
          }
        } else {
          Text("只用于 16 位的负片：本程序的扫描和翻拍。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
    }
  }
  private func readout(_ dust: DustState?) -> String {
    guard let dust else { return "" }
    return dust.on ? "\(dust.filledCount) 处" : "关"
  }
  private func summary(_ dust: DustState) -> String {
    let kept = dust.spots.count - dust.filledCount
    let byHand = dust.spots.filter { $0.marked == true }.count
    var parts = ["去掉 \(dust.filledCount) 处"]
    if kept > 0 { parts.append("留下 \(kept) 处") }
    if byHand > 0 { parts.append("其中手动标 \(byHand) 处") }
    return parts.joined(separator: " · ")
  }
}
