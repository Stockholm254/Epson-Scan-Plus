import SwiftUI

/// ② 去色罩 → 去漏光 → ③ 调色: the inspector's ways between the steps.
extension ContentView {
  /// ③'s note of the frame's light-leak repair, when it has one: it is graded on the repaired
  /// picture; the repair can be changed in 去漏光 or taken out here.
  @ViewBuilder var leakRepairSection: some View {
    if let f = m.selected, let fix = f.adjustments.leakFix {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          sectionTitle("去漏光", symbol: "wand.and.rays")
          Spacer()
          Text("已修复").font(.system(size: 11)).foregroundStyle(Hardware.amberText)
        }
        note("这张用着去漏光的修复（\(WhenSaid.ago(fix.made))修好）：下面的调色、导出和接触表都在修好的照片上，原片不改。"
          + (fix.meanError.map { String(format: "和去漏光页的结果平均差 %.1f / 255。", $0) } ?? ""))
        HStack(spacing: 8) {
          Button("在去漏光里改") { m.openInLeak(f.id) }.disabled(m.isWorking)
            .help("回到去漏光页接着修这一张；改好再点「用到 ③ 调色」")
          Button("去掉修复") { m.removeLeakRepair(f.id) }.disabled(m.isWorking)
            .help("这张不再用去漏光的修复（⌘Z 可以撤销）；去漏光页里的任务留着")
        }.font(.system(size: 11))
      }
      Divider()
    } else if let f = m.selected, let kept = m.leakJobs[f.id] {
      // Worked on in 去漏光, its repair not taken into ③ yet.
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          sectionTitle("去漏光", symbol: "wand.and.rays")
          Spacer()
          Text("没用到 ③").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        note("这张在去漏光里有任务（\(WhenSaid.ago(kept.modified))），修复还没用到 ③：这里调色、导出的是没修的照片。在去漏光里看好，再点「用到 ③ 调色」。")
        Button("在去漏光里打开") { m.openInLeak(f.id) }.disabled(m.isWorking)
          .font(.system(size: 11))
          .help("在去漏光页打开这一张的任务（⌥⌘L）")
      }
      Divider()
    }
  }
  /// ②'s way on: to ③, or through 去漏光 for a frame that needs it.
  var nextSteps: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionTitle("下一步", symbol: "arrow.right")
      note("负片变成干净的正片以后，到 ③ 调色：在那里调色和导出。有漏光的照片先去漏光（可选，② 的最后一步）：在这一步的结果上修，修好以后到 ③ 接着调色。")
      Button {
        m.station = .grade
      } label: {
        Label("③ 调色", systemImage: "arrow.right").frame(maxWidth: .infinity)
      }.buttonStyle(KeyStyle(prominent: true)).controlSize(.regular)
        .help("到 ③ 调色（⌥⌘3）：白平衡、影调、色阶、色彩、曲线、锐化和导出")
      Button {
        if let id = m.selectedID { m.openInLeak(id) }
      } label: {
        Label(m.selected?.adjustments.leakFix != nil ? "在去漏光里改修复"
          : m.selected.flatMap { m.leakJobs[$0.id] } != nil ? "在去漏光里接着修" : "先去漏光（可选）", systemImage: "wand.and.rays")
          .frame(maxWidth: .infinity)
      }.disabled(m.selected == nil || m.isWorking)
        .help("在去漏光页打开这一张（⌥⌘L）")
    }
  }
}

/// A frame with a light-leak repair, marked on the strip as its export is: in the corner opposite.
/// Hollow for one with a 去漏光 job whose repair ③ does not use.
struct LeakRepairMark: View {
  var applied = true
  var body: some View {
    Image(systemName: "wand.and.rays").font(.system(size: 9, weight: .semibold))
      .foregroundStyle(applied ? Color.white : Hardware.amber)
      .padding(3)
      .background(Circle().fill(applied ? Hardware.amber.opacity(0.85) : Color.black.opacity(0.55)))
      .overlay { if !applied { Circle().strokeBorder(Hardware.amber.opacity(0.85), lineWidth: 1) } }
      .help(applied ? "这张去过漏光：③ 调色在修好的照片上" : "这张在去漏光里有任务，修复还没用到 ③ 调色")
      .accessibilityLabel(applied ? "去过漏光" : "有去漏光任务，没用到调色")
  }
}
