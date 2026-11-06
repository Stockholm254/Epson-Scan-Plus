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
  @Environment(\.colorScheme) private var scheme
  /// The first frames of each roll, hashed, to lay the same film scanned again in one stack.
  @State private var prints = [String: [UInt64]]()
  @AppStorage("libraryStacks") private var stacks = true
  /// The stack spread out, its rolls shown alone.
  @State private var spread: [String]?
  @State private var renaming: RollEntry?
  @State private var newName = ""
  var groups: [[String]] { RollLibrary.sameFilmGroups(entries, prints: prints) }
  var shown: [RollEntry] {
    let found = entries.filter { e in
      (source == nil || e.source == source)
        && (query.isEmpty
          || [e.title, e.film, e.notes, e.folder.lastPathComponent].contains { $0.localizedCaseInsensitiveContains(query) })
    }
    if let spread { return found.filter { spread.contains($0.id) } }
    guard stacks else { return found }
    // Each stack shows as its newest roll; the older ones lie under it.
    let under = Set(groups.flatMap { $0.dropFirst() })
    return found.filter { !under.contains($0.id) }
  }
  /// The rolls under `entry` in its stack, or none.
  func stack(of entry: RollEntry) -> [String] {
    guard stacks, spread == nil, let g = groups.first(where: { $0.first == entry.id }) else { return [] }
    return g
  }
  var body: some View {
    VStack(spacing: 0) {
      if Hardware.glass {
        ZStack(alignment: .top) {
          drawer.safeAreaInset(edge: .top) { Color.clear.frame(height: 62) }
          header.padding(.horizontal, 16).padding(.vertical, 9).glassPane(radius: 22).padding(.horizontal, 14).padding(.top, 10)
        }
      } else {
        header.padding(.horizontal, 18).padding(.vertical, 12).background(.bar)
        Divider()
        drawer
      }
      HStack {
        Text(m.libraryURL.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
        Spacer()
        Text("双击一页打开这一卷，进入 ② 去色罩；鼠标停在一格上可以放大看；右键可以重命名").font(.system(size: 11)).foregroundStyle(.secondary)
      }.padding(.horizontal, 18).padding(.vertical, 8)
    }
    .frame(minWidth: 900, idealWidth: 1080, minHeight: 620, idealHeight: 760)
    .onAppear { reload() }
    .alert("重命名这一卷", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("卷名", text: $newName)
      Button("好") { if let e = renaming { rename(e, to: newName) } }
      Button("取消", role: .cancel) { renaming = nil }
    } message: {
      Text("留空就按开始的时间显示。")
    }
  }
  var header: some View {
      HStack(spacing: 12) {
        Image(systemName: "archivebox").foregroundStyle(Hardware.amber)
        Text("库").font(.system(size: 16, weight: .semibold))
        Text(loaded ? "\(entries.count) 卷" : "读取中").readout(11)
        if let spread {
          Button {
            withAnimation(Liquid.flow) { self.spread = nil }
          } label: {
            Label("同一批底片的 \(spread.count) 卷", systemImage: "chevron.left")
          }.help("回到整个库")
        }
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
          Divider()
          Toggle("同一批底片叠成一摞", isOn: $stacks)
            .help("同一卷胶片扫了几次（张数一样、前三张一样）的几卷叠在一起，只露最新的一卷")
        } label: {
          Image(systemName: "ellipsis.circle")
        }.menuStyle(.borderlessButton).fixedSize().help("库的选项").accessibilityLabel("库的选项")
        Button("完成") { m.showLibrary = false }.keyboardShortcut(.cancelAction)
      }.buttonStyle(.bordered).controlSize(.regular)
  }
  /// The drawer of sleeves.
  var drawer: some View {
      ScrollView {
        if loaded && shown.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(entries.isEmpty ? "还没有卷" : "没有符合的卷").font(.system(size: 14, weight: .medium))
            Text("预览扫描、翻拍或导入之后，每卷都会自动放进这里。").font(.system(size: 11)).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity).padding(.top, 90)
        }
        // Top-aligned: a stack, taller with its edges, does not push the pages beside it down.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 330), spacing: 26, alignment: .top)], spacing: 32) {
          ForEach(shown) { e in
            let under = stack(of: e)
            RollSleeve(
              entry: e, current: m.projectURL?.standardizedFileURL == e.project.standardizedFileURL, stacked: under.count,
              spread: { withAnimation(Liquid.flow) { spread = under } },
              rename: {
                newName = e.named ? e.title : ""
                renaming = e
              }
            ) { m.openRoll(e) }
          }
        }.padding(.horizontal, 28).padding(.vertical, 30)
      }.background {
        // The drawer: steel, dark or light as the window is, shaded under its front edge.
        ZStack(alignment: .top) {
          LinearGradient(colors: [LibraryDrawer.steelTop, LibraryDrawer.steelBottom], startPoint: .top, endPoint: .bottom)
          LinearGradient(colors: [.black.opacity(scheme == .dark ? 0.6 : 0.12), .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
        }
      }
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
      // The first frames of each, hashed, a little later: stacks form as they come.
      var hashed = [String: [UInt64]]()
      for e in found { if let p = RollLibrary.fingerprint(e) { hashed[e.id] = p } }
      DispatchQueue.main.async { withAnimation(Liquid.flow) { prints = hashed } }
    }
  }
  /// Names a roll: the open one as its panel does, any other in its project file.
  func rename(_ e: RollEntry, to name: String) {
    renaming = nil
    if m.projectURL?.standardizedFileURL == e.project.standardizedFileURL {
      m.rollName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      m.saveProject()
    } else {
      do { try RollLibrary.rename(e.project, to: name) } catch { m.errorText = "不能重命名：\(error.localizedDescription)" }
    }
    reload()
  }
}

/// A roll as a negative sleeve page: strips of six pockets under clear plastic, a paper label
/// along the top, the binder's punched holes down the side, an index tab for where the roll came
/// from, and a page that lifts a little under the pointer.
struct RollSleeve: View {
  let entry: RollEntry
  let current: Bool
  /// How many rolls of the same film lie in its stack, itself included; 0 when it lies alone.
  var stacked = 0
  var spread: () -> Void = {}
  var rename: () -> Void = {}
  let open: () -> Void
  @State private var pictures = [UUID: (image: CGImage, positive: Bool)]()
  /// A roll with no frames cut from its preview: the preview, small, in their place.
  @State private var preview: CGImage?
  @State private var hover = false
  /// The pocket under the pointer, and the glass loupe over it.
  @State private var hovered: UUID?
  @State private var loupe: CGImage?
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
        // The shadow is the page's outline's, not the whole page's: a shadow of all its strips and
        // pockets is drawn again every frame the page lifts, and took seconds a drawer.
        // The pages under it in its stack, their edges showing below and to the right.
        ForEach(Array((0..<min(2, max(0, stacked - 1))).reversed()), id: \.self) { i in
          RoundedRectangle(cornerRadius: 3).fill(LibraryDrawer.page)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.16), lineWidth: 0.6))
            .offset(x: CGFloat(i + 1) * 5, y: CGFloat(i + 1) * 5)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        }
        RoundedRectangle(cornerRadius: 3).fill(LibraryDrawer.page)
          .shadow(color: .black.opacity(hover ? 0.45 : 0.25), radius: hover ? 12 : 5, y: hover ? 8 : 3)
        RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.8).opacity(0.13))
        RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.16), lineWidth: 0.6)
        VStack {
          ForEach(0..<3, id: \.self) { _ in
            Spacer()
            Circle().fill(LibraryDrawer.steelTop).frame(width: 6, height: 6)
              .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
          }
          Spacer()
        }.padding(.leading, 4)
      }
    }
    .overlay(alignment: .topTrailing) { indexTab.offset(x: -14, y: -16) }
    .overlay(RoundedRectangle(cornerRadius: 3).stroke(current ? Hardware.amber : .clear, lineWidth: 1.5))
    .offset(y: hover ? -4 : 0)
    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
    .onHover { hover = $0 }
    .contentShape(Rectangle())
    .onTapGesture(count: 2, perform: open)
    .contextMenu {
      Button("打开") { open() }
      if !entry.legacy { Button("重命名…") { rename() } }
      if stacked > 1 { Button("摊开同一批底片的 \(stacked) 卷") { spread() } }
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
          .font(.system(size: 11)).foregroundStyle(Self.ink.opacity(0.6)).lineLimit(1)
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
    .background(LinearGradient(colors: [Self.paper, Self.paper.opacity(0.88)], startPoint: .top, endPoint: .bottom))
    .padding(.top, 8).padding(.trailing, 8)
  }
  /// The strips under clear plastic, with a sheen across them.
  @ViewBuilder var sleeve: some View {
    if entry.frames.isEmpty {
      HStack(spacing: 10) {
        if let preview {
          Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 90, maxHeight: 64)
        }
        Text(entry.overview == nil ? "没有画面" : "只有预览，没有切出画面")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }.padding(.vertical, 8).padding(.trailing, 8).frame(minHeight: 64)
    } else {
      frameStrips
    }
  }
  var frameStrips: some View {
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
        }.padding(2).background(Color.primary.opacity(0.05))
          .zIndex(rows[r].contains { $0.id == hovered } ? 10 : 0)
      }
      if entry.frames.count > shownFrames.count {
        Text("另有 \(entry.frames.count - shownFrames.count) 张").font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 8).padding(.trailing, 8)
    .overlay {
      LinearGradient(colors: [.white.opacity(0.11), .clear, .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
        .allowsHitTesting(false)
    }
  }
  /// A pocket of the strip; under the pointer, a glass loupe rises over it, enlarging the frame.
  func pocket(_ frame: RollEntry.Frame?) -> some View {
    let under = frame != nil && hovered == frame?.id
    return ZStack {
      Rectangle().fill(frame == nil ? Color.primary.opacity(0.04) : Hardware.filmBase.opacity(0.85))
      if let frame, let picture = pictures[frame.id] {
        Image(decorative: picture.image, scale: 1).resizable().aspectRatio(contentMode: .fit)
      }
    }.aspectRatio(1.5, contentMode: .fit).clipped()
      .overlay(alignment: .top) {
        if under, let loupe {
          Image(decorative: loupe, scale: 2).frame(width: 112, height: 112)
            .shadow(color: .black.opacity(0.55), radius: 12, y: 6)
            .offset(y: -118).allowsHitTesting(false)
            .transition(.scale(scale: 0.7, anchor: .bottom).combined(with: .opacity))
        }
      }
      .zIndex(under ? 10 : 0)
      .onHover { inside in
        guard let frame else { return }
        if inside, let picture = pictures[frame.id] {
          loupe = CropLens.loupe(picture.image)
          withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) { hovered = frame.id }
        } else if hovered == frame.id {
          withAnimation(.easeOut(duration: 0.12)) { hovered = nil }
        }
      }
  }
  var indexTab: some View {
    let color: Color = {
      switch entry.source {
      case .scanner: return Color(red: 0.56, green: 0.76, blue: 0.47)
      case .camera: return Hardware.amber
      case .files: return Color(red: 0.52, green: 0.7, blue: 0.92)
      }
    }()
    return Text(entry.source.rawValue + (entry.legacy ? " · 旧版" : "") + (stacked > 1 ? " · \(stacked) 卷" : ""))
      .font(.system(size: 10, weight: .bold)).foregroundStyle(Color(white: 0.1))
      .padding(.horizontal, 9).padding(.vertical, 3)
      .background(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4).fill(color))
  }
  func load() {
    let e = entry
    DispatchQueue.global(qos: .userInitiated).async {
      let found = RollLibrary.thumbnails(for: e)
      let small = e.frames.isEmpty ? e.overview.flatMap { RollLibrary.thumbnail($0, maxPixels: 240) } : nil
      DispatchQueue.main.async {
        pictures = found
        preview = small
      }
    }
  }
}

/// The library drawer's colours, dark or light as the window is.
enum LibraryDrawer {
  static let steelTop = Hardware.adaptive(NSColor(white: 0.085, alpha: 1), NSColor(white: 0.86, alpha: 1))
  static let steelBottom = Hardware.adaptive(NSColor(white: 0.14, alpha: 1), NSColor(white: 0.92, alpha: 1))
  static let page = Hardware.adaptive(NSColor(white: 0.1, alpha: 1), NSColor(white: 0.97, alpha: 1))
}
