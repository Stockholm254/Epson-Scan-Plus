import AppKit
import SwiftUI

/// The library: a drawer of the cabinet, each roll a negative sleeve page punched for the binder,
/// its frames in the pockets (the positives the app has rendered, else the negatives as they are),
/// a paper label along the top and an index tab saying where it came from. Double-click a page to
/// open the roll.
struct LibrarySheet: View {
  @ObservedObject var m: AppModel
  @State private var entries = [RollEntry]()
  @State private var loaded = false
  @State private var query = ""
  @State private var source: RollSource?
  var shown: [RollEntry] {
    entries.filter { e in
      (source == nil || e.source == source)
        && (query.isEmpty
          || [e.title, e.film, e.notes, e.folder.lastPathComponent].contains { $0.localizedCaseInsensitiveContains(query) })
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "archivebox").foregroundStyle(Hardware.amber)
        Text("库").font(.system(size: 16, weight: .semibold))
        Text(loaded ? "\(entries.count) 卷" : "读取中").lcd(11)
        Spacer()
        TextField("搜索卷名、胶片或备注", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
        Picker("来源", selection: $source) {
          Text("全部").tag(RollSource?.none)
          ForEach(RollSource.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
        Menu {
          Button("从文件打开工程…") {
            m.showLibrary = false
            DispatchQueue.main.async { m.openProject() }
          }
          Button("在 Finder 中显示图库") { NSWorkspace.shared.activateFileViewerSelecting([m.libraryURL]) }
          Button("更改新卷的存放位置…") {
            m.chooseLibrary()
            reload()
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }.menuStyle(.borderlessButton).fixedSize()
        Button("完成") { m.showLibrary = false }.keyboardShortcut(.cancelAction)
      }.buttonStyle(HardwareKeyStyle()).controlSize(.regular).padding(.horizontal, 18).padding(.vertical, 12)
        .background(Hardware.metal)
      Divider()
      ScrollView {
        if loaded && shown.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(entries.isEmpty ? "还没有卷" : "没有符合的卷").font(.system(size: 14, weight: .medium))
            Text("预览扫描、翻拍或导入之后，每卷都会自动放进这里。").font(.system(size: 11)).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity).padding(.top, 90)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 330), spacing: 26)], spacing: 32) {
          ForEach(shown) { e in
            RollSleeve(entry: e, current: m.projectURL?.standardizedFileURL == e.project.standardizedFileURL) { m.openRoll(e) }
          }
        }.padding(.horizontal, 28).padding(.vertical, 30)
      }.background {
        // The drawer: dark steel, shaded under its front edge.
        ZStack(alignment: .top) {
          LinearGradient(colors: [Color(white: 0.085), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
          LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
        }
      }
      HStack {
        Text(m.libraryURL.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
        Spacer()
        Text("双击一页打开这一卷，进入 ② 去色罩").font(.system(size: 10)).foregroundStyle(.secondary)
      }.padding(.horizontal, 18).padding(.vertical, 8)
    }
    .frame(minWidth: 900, idealWidth: 1080, minHeight: 620, idealHeight: 760)
    .background(Color(red: 0.135, green: 0.14, blue: 0.145)).preferredColorScheme(.dark).tint(Hardware.amber)
    .onAppear { reload() }
  }
  func reload() {
    let roots = m.libraryRoots
    loaded = false
    DispatchQueue.global(qos: .userInitiated).async {
      let found = RollLibrary.scan(roots)
      DispatchQueue.main.async {
        entries = found
        loaded = true
      }
    }
  }
}

/// A roll as a negative sleeve page: strips of six pockets under clear plastic, a paper label
/// along the top, the binder's punched holes down the side, an index tab for where the roll came
/// from, and a page that lifts a little under the pointer.
struct RollSleeve: View {
  let entry: RollEntry
  let current: Bool
  let open: () -> Void
  @State private var pictures = [UUID: (image: CGImage, positive: Bool)]()
  @State private var hover = false
  static let perStrip = 6
  static let strips = 6
  private static let paper = Color(red: 0.93, green: 0.89, blue: 0.8)
  private static let ink = Color(red: 0.22, green: 0.17, blue: 0.12)
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      label
      sleeve
    }
    .padding(.leading, 14)
    .background {
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.8).opacity(0.13))
        RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.16), lineWidth: 0.6)
        VStack {
          ForEach(0..<3, id: \.self) { _ in
            Spacer()
            Circle().fill(Color(white: 0.1)).frame(width: 6, height: 6)
              .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
          }
          Spacer()
        }.padding(.leading, 4)
      }
    }
    .overlay(alignment: .topTrailing) { indexTab.offset(x: -14, y: -16) }
    .overlay(RoundedRectangle(cornerRadius: 3).stroke(current ? Hardware.amber : .clear, lineWidth: 1.5))
    .offset(y: hover ? -4 : 0)
    .shadow(color: .black.opacity(hover ? 0.6 : 0.4), radius: hover ? 12 : 5, y: hover ? 8 : 3)
    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
    .onHover { hover = $0 }
    .contentShape(Rectangle())
    .onTapGesture(count: 2, perform: open)
    .contextMenu {
      Button("打开") { open() }
      Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.folder]) }
    }
    .help(entry.folder.path)
    .onAppear(perform: load)
    .onChange(of: entry) { load() }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { open() }
  }
  var details: String {
    var parts = [entry.film, "\(entry.frames.count) 张"]
    if entry.fullResolution > 0 { parts.append("全分辨率 \(entry.fullResolution)") }
    if entry.exported > 0 { parts.append("已导出 \(entry.exported)") }
    return parts.joined(separator: " · ")
  }
  /// The paper label, written on.
  var label: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(entry.title).font(.system(size: 13, weight: .semibold, design: .serif)).foregroundStyle(Self.ink).lineLimit(1)
      Text(details).font(.system(size: 10, design: .monospaced)).foregroundStyle(Self.ink.opacity(0.75)).lineLimit(1)
      if entry.named || !entry.notes.isEmpty {
        Text(entry.named ? RollLibrary.title(entry.date) + (entry.notes.isEmpty ? "" : " · " + entry.notes) : entry.notes)
          .font(.system(size: 10)).foregroundStyle(Self.ink.opacity(0.6)).lineLimit(1)
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
    .background(LinearGradient(colors: [Self.paper, Self.paper.opacity(0.88)], startPoint: .top, endPoint: .bottom))
    .padding(.top, 8).padding(.trailing, 8)
  }
  /// The strips under clear plastic, with a sheen across them.
  var sleeve: some View {
    let shownFrames = Array(entry.frames.prefix(Self.perStrip * Self.strips))
    let rows = stride(from: 0, to: max(1, shownFrames.count), by: Self.perStrip).map {
      Array(shownFrames[min($0, shownFrames.count)..<min($0 + Self.perStrip, shownFrames.count)])
    }
    return VStack(alignment: .leading, spacing: 3) {
      ForEach(rows.indices, id: \.self) { r in
        HStack(spacing: 2) {
          ForEach(0..<Self.perStrip, id: \.self) { c in
            pocket(c < rows[r].count ? rows[r][c] : nil)
          }
        }.padding(2).background(Color.white.opacity(0.05))
      }
      if entry.frames.count > shownFrames.count {
        Text("另有 \(entry.frames.count - shownFrames.count) 张").font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 8).padding(.trailing, 8)
    .overlay {
      LinearGradient(colors: [.white.opacity(0.11), .clear, .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
        .allowsHitTesting(false)
    }
  }
  func pocket(_ frame: RollEntry.Frame?) -> some View {
    ZStack {
      Rectangle().fill(frame == nil ? Color.white.opacity(0.03) : Hardware.filmBase.opacity(0.85))
      if let frame, let picture = pictures[frame.id] {
        Image(decorative: picture.image, scale: 1).resizable().aspectRatio(contentMode: .fit)
      }
    }.aspectRatio(1.5, contentMode: .fit).clipped()
  }
  var indexTab: some View {
    let color: Color = {
      switch entry.source {
      case .scanner: return Color(red: 0.56, green: 0.76, blue: 0.47)
      case .camera: return Hardware.amber
      case .files: return Color(red: 0.52, green: 0.7, blue: 0.92)
      }
    }()
    return Text(entry.source.rawValue + (entry.legacy ? " · 旧版" : ""))
      .font(.system(size: 10, weight: .bold)).foregroundStyle(Color(white: 0.1))
      .padding(.horizontal, 9).padding(.vertical, 3)
      .background(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4).fill(color))
  }
  func load() {
    let e = entry
    DispatchQueue.global(qos: .userInitiated).async {
      let found = RollLibrary.thumbnails(for: e)
      DispatchQueue.main.async { pictures = found }
    }
  }
}
