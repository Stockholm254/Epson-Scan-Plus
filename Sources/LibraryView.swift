import AppKit
import SwiftUI

/// What the library tab keeps while another module is shown: the rolls as last read, their first
/// frames hashed and the stacks they make, and the search, the source and the stack spread out as
/// they were left. Each visit reads the folders again, the rolls already read shown meanwhile.
final class LibraryShelf: ObservableObject {
  @Published private(set) var entries = [RollEntry]()
  @Published private(set) var loaded = false
  @Published var query = ""
  @Published var source: RollSource?
  /// The stack spread out, its rolls shown alone.
  @Published var spread: [String]?
  /// The first frames of each roll, hashed, to lay the same film scanned again in one stack.
  @Published private(set) var prints = [String: [UInt64]]()
  /// The stacks, worked out when the rolls or their hashes change, not on every redraw: the tab
  /// stays up while scans and renders publish many times a second.
  private(set) var groups = [[String]]()
  /// Each sleeve's pictures as last loaded, for the roll as it was then: a visit back shows them at
  /// once, and a roll that changed loads again. Only on the main thread.
  var pictures = [String: (entry: RollEntry, frames: [UUID: (image: CGImage, positive: Bool)], preview: CGImage?)]()
  private var reading = 0
  /// Reads the rolls in `roots` again, apart from the main thread; then hashes, a roll each, those
  /// not hashed as they are now. A hash is kept only while its roll reads the same, and what a
  /// pass hashed is kept even when a newer pass has begun.
  func reload(_ roots: [(url: URL, legacy: Bool)]) {
    reading += 1
    let token = reading, known = prints
    let before = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    DispatchQueue.global(qos: .userInitiated).async {
      let found = RollLibrary.scan(roots)
      DispatchQueue.main.async {
        guard token == self.reading else { return }
        self.entries = found
        self.groups = RollLibrary.sameFilmGroups(found, prints: self.prints)
        self.loaded = true
        // A stack spread out that no longer holds its rolls lets the whole library show again.
        if let spread = self.spread, !spread.allSatisfy({ id in found.contains { $0.id == id } }) { self.spread = nil }
      }
      var hashed = [String: [UInt64]]()
      for e in found {
        if let p = known[e.id], before[e.id] == e { hashed[e.id] = p } else if let p = RollLibrary.fingerprint(e) { hashed[e.id] = p }
      }
      DispatchQueue.main.async {
        let ids = Set(self.entries.map(\.id))
        let merged = self.prints.filter { ids.contains($0.key) }.merging(hashed.filter { ids.contains($0.key) }) { _, new in new }
        guard merged != self.prints else { return }
        self.groups = RollLibrary.sameFilmGroups(self.entries, prints: merged)
        withAnimation(Liquid.flow) { self.prints = merged }
      }
    }
  }
}

/// The library, the window's first tab: a drawer of the cabinet, each roll a negative sleeve page
/// punched for the binder, its frames in the pockets (the positives the app has rendered, else the
/// negatives as they are), a paper label along the top and an index tab saying where it came from.
/// Double-click a page to open the roll; a new project and an import start one.
struct LibraryPage: View {
  @ObservedObject var m: AppModel
  @ObservedObject var shelf: LibraryShelf
  @Environment(\.colorScheme) private var scheme
  @AppStorage("libraryStacks") private var stacks = true
  @State private var renaming: RollEntry?
  /// The roll asked to go to the Trash, until the user says yes.
  @State private var trashing: RollEntry?
  @State private var newName = ""
  var shown: [RollEntry] {
    let query = shelf.query, source = shelf.source
    let found = shelf.entries.filter { e in
      (source == nil || e.source == source) && (query.isEmpty || RollLibrary.matches(e, query))
    }
    if let spread = shelf.spread { return found.filter { spread.contains($0.id) } }
    guard stacks else { return found }
    // Each stack shows as its newest roll; the older ones lie under it.
    let under = Set(shelf.groups.flatMap { $0.dropFirst() })
    return found.filter { !under.contains($0.id) }
  }
  /// The rolls under `entry` in its stack, or none.
  func stack(of entry: RollEntry) -> [String] {
    guard stacks, shelf.spread == nil, let g = shelf.groups.first(where: { $0.first == entry.id }) else { return [] }
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
        Text("双击一页打开这一卷，进入 ② 去色罩；鼠标停在一格上可以放大看；右键可以重命名；标签右下角的废纸篓把这一卷移到废纸篓").font(.system(size: 11)).foregroundStyle(.secondary)
      }.padding(.horizontal, 18).padding(.vertical, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { shelf.reload(m.libraryRoots) }
    .onChange(of: m.libraryURL) { shelf.reload(m.libraryRoots) }
    // Shown while a preview, a camera picture or an import makes or grows the open roll.
    .onChange(of: m.sessionURL) { shelf.reload(m.libraryRoots) }
    .onChange(of: m.frames.count) { shelf.reload(m.libraryRoots) }
    .alert("重命名这一卷", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("卷名", text: $newName)
      Button("好") { if let e = renaming { rename(e, to: newName) } }
      Button("取消", role: .cancel) { renaming = nil }
    } message: {
      Text("留空就按开始的时间显示。")
    }
    .confirmationDialog(trashing.map { "把「\($0.title)」移到废纸篓？" } ?? "", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })) {
      Button("移到废纸篓", role: .destructive) {
        if let e = trashing {
          do { try m.trashRoll(e.folder) } catch { m.errorText = "不能删除这一卷：\(error.localizedDescription)" }
        }
        trashing = nil
        shelf.reload(m.libraryRoots)
      }
      Button("取消", role: .cancel) { trashing = nil }
    } message: {
      Text(trashing.map { e in
        "整个文件夹一起移到废纸篓：\(e.frames.count) 张画面、原片和导出过的 \(e.exported) 个文件。清空废纸篓之前，都可以在废纸篓里右键「放回原处」拿回来。"
          + (m.projectURL?.standardizedFileURL == e.project.standardizedFileURL ? "这一卷正打开着，会先关掉。" : "")
      } ?? "")
    }
  }
  var header: some View {
      HStack(spacing: 12) {
        Image(systemName: "archivebox").foregroundStyle(Hardware.amber)
        Text("库").font(.system(size: 16, weight: .semibold))
        Text(shelf.loaded ? "\(shelf.entries.count) 卷" : "读取中").readout(11)
        // Where a roll starts: empty, for the scanner or the camera, or from files.
        Button {
          m.askNewProject()
        } label: {
          Label("新建工程", systemImage: "plus.rectangle.on.folder")
        }.disabled(m.isWorking)
          .help("新建工程（⌘N）：先选这一卷的胶片、片种和画幅；打开着的这一卷存好留在库里，窗口清空，转到 ① 采集；下一次预览、拍摄或导入存进新的一卷")
        Button {
          m.importImages()
        } label: {
          Label("导入…", systemImage: "square.and.arrow.down")
        }.disabled(m.isWorking)
          .help("导入（⌘O）：TIFF、PNG、JPEG 导成新的一卷导入的照片，相机 RAW（ARW 等）导成新的一卷翻拍；都复制进库，原文件不动，导入后转到 ② 去色罩")
        if shelf.spread != nil {
          Button {
            withAnimation(Liquid.flow) { shelf.spread = nil }
          } label: {
            Label("同一批底片的 \(shown.count) 卷", systemImage: "chevron.left")
          }.help("回到整个库")
        }
        Spacer()
        TextField("搜索卷名、胶片或备注", text: $shelf.query).textFieldStyle(.roundedBorder).frame(width: 200)
          .help("也能按胶片是什么来找：厂家（富士、柯达）、片种（正片、黑白）、感光度或画幅（6×7）")
        Picker("来源", selection: $shelf.source) {
          Text("全部").tag(RollSource?.none)
          ForEach(RollSource.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
        Menu {
          Button("从文件打开工程…") { m.openProject() }
          Button("在 Finder 中显示图库") { NSWorkspace.shared.activateFileViewerSelecting([m.libraryURL]) }
          Button("更改新卷的存放位置…") { m.chooseLibrary() }
          Divider()
          Toggle("同一批底片叠成一摞", isOn: $stacks)
            .help("同一卷胶片扫了几次（张数一样、前三张一样）的几卷叠在一起，只露最新的一卷")
        } label: {
          Image(systemName: "ellipsis.circle")
        }.menuStyle(.borderlessButton).fixedSize().help("库的选项").accessibilityLabel("库的选项")
      }.buttonStyle(.bordered).controlSize(.regular)
  }
  /// The drawer of sleeves.
  var drawer: some View {
      ScrollView {
        // The way in: the modules wait for a project.
        if !m.hasProject {
          Label("先在这里新建工程、双击打开一卷，或导入照片；之后 ① 采集、② 去色罩、③ 去漏光 才能用。", systemImage: "info.circle")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 18)
        }
        if shelf.loaded && shown.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(shelf.entries.isEmpty ? "还没有卷" : "没有符合的卷").font(.system(size: 14, weight: .medium))
            Text("点「新建工程」去预览扫描或翻拍，或「导入…」照片；每卷都会自动放进这里。").font(.system(size: 11)).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity).padding(.top, 90)
        }
        // Top-aligned: a stack, taller with its edges, does not push the pages beside it down.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 330), spacing: 26, alignment: .top)], spacing: 32) {
          ForEach(shown) { e in
            let under = stack(of: e)
            RollSleeve(
              entry: e, current: m.projectURL?.standardizedFileURL == e.project.standardizedFileURL, shelf: shelf, stacked: under.count,
              spread: { withAnimation(Liquid.flow) { shelf.spread = under } },
              rename: {
                newName = e.named ? e.title : ""
                renaming = e
              },
              trash: { trashing = e }
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
  /// Names a roll: the open one as its panel does, any other in its project file.
  func rename(_ e: RollEntry, to name: String) {
    renaming = nil
    if m.projectURL?.standardizedFileURL == e.project.standardizedFileURL {
      m.rollName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      m.saveProject()
    } else {
      do { try RollLibrary.rename(e.project, to: name) } catch { m.errorText = "不能重命名：\(error.localizedDescription)" }
    }
    shelf.reload(m.libraryRoots)
  }
}

/// A roll as a negative sleeve page: strips of six pockets under clear plastic, a paper label
/// along the top, the binder's punched holes down the side, an index tab for where the roll came
/// from, and a page that lifts a little under the pointer.
struct RollSleeve: View {
  let entry: RollEntry
  let current: Bool
  /// Where its pictures are kept between visits to the library.
  var shelf: LibraryShelf? = nil
  /// How many rolls of the same film lie in its stack, itself included; 0 when it lies alone.
  var stacked = 0
  var spread: () -> Void = {}
  var rename: () -> Void = {}
  var trash: () -> Void = {}
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
      Divider()
      Button("移到废纸篓…", role: .destructive) { trash() }
    }
    .help(entry.folder.path)
    .onAppear(perform: load)
    .onChange(of: entry) { load() }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { open() }
  }
  var details: String {
    var parts = [entry.film] + (entry.format.map { [$0] } ?? []) + ["\(entry.frames.count) 张"]
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
    .padding(.horizontal, 10).padding(.vertical, 7).padding(.trailing, 22).frame(maxWidth: .infinity, alignment: .leading)
    .background(LinearGradient(colors: [Self.paper, Self.paper.opacity(0.88)], startPoint: .top, endPoint: .bottom))
    // Moving the roll to the Trash, at hand as well as in its menu: quiet until the page is under
    // the pointer. It asks before anything moves.
    .overlay(alignment: .bottomTrailing) {
      Button(action: trash) {
        Image(systemName: "trash").font(.system(size: 11, weight: .medium)).foregroundStyle(Self.ink.opacity(hover ? 0.75 : 0.3))
          .frame(width: 22, height: 22).contentShape(Rectangle())
      }.buttonStyle(.plain).padding(.trailing, 2).padding(.bottom, 1)
        .help("把这一卷移到废纸篓（会先问一下）")
        .accessibilityLabel("移到废纸篓")
    }
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
  /// What shows round a frame that does not fill its 3:2 pocket (a 6×6, a crop with its sprocket
  /// strips): the orange film base behind a negative, as on the film, and a print's neutral black
  /// behind a positive, where the orange read as red in the dark round the picture.
  static func backing(positive: Bool) -> Color {
    positive ? Color(white: 0.07) : Hardware.filmBase.opacity(0.85)
  }
  /// A pocket of the strip; under the pointer, a glass loupe rises over it, enlarging the frame.
  func pocket(_ frame: RollEntry.Frame?) -> some View {
    let under = frame != nil && hovered == frame?.id
    return ZStack {
      Rectangle().fill(frame.map { Self.backing(positive: pictures[$0.id]?.positive == true) } ?? Color.primary.opacity(0.04))
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
    // As loaded on the last visit, while the roll reads the same: shown at once.
    if let kept = shelf?.pictures[e.id], kept.entry == e {
      pictures = kept.frames
      preview = kept.preview
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let found = RollLibrary.thumbnails(for: e)
      let small = e.frames.isEmpty ? e.overview.flatMap { RollLibrary.thumbnail($0, maxPixels: 240) } : nil
      DispatchQueue.main.async {
        pictures = found
        preview = small
        shelf?.pictures[e.id] = (e, found, small)
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
