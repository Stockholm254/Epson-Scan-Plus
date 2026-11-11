import AppKit
import SwiftUI

/// 新建工程's questions, asked before the roll begins: which film it is, negative or slide, and its
/// format, as a shelf of film to take one from. The catalog's common stocks stand on it as their
/// cassettes or 120 rolls, rendered in 3D (`FilmRender`, as the format chosen holds them), found by any word of their name,
/// maker, speed or kind; the presets calibrated on this Mac stand first, and a name typed that the
/// catalog lacks can be used as it is. The formats lie under it as pieces of film to their scale.
/// All of it starts as last chosen and can be changed later in ② 去色罩's film section.
struct NewProjectSheet: View {
  @ObservedObject var m: AppModel
  /// What the roll is taken as: a stock of the catalog, a preset of this Mac, or a name typed.
  enum Choice: Hashable {
    case stock(String)
    case preset(String)
    case named(String)
  }
  @State private var choice: Choice = .stock(FilmCatalog.stocks[0].id)
  @State private var query = ""
  @State private var reversal = false
  @State private var format = FilmFormat.auto
  @State private var edges = PictureEdges.auto
  @FocusState private var searching: Bool
  @State private var hovering: Choice?
  /// The last choice came from ↑ or ↓, so the shelf scrolls to it.
  @State private var stepped = false
  /// What the shelf is for: a new roll's film, or the open roll's changed (from ②'s film section).
  enum Purpose { case newProject, changeFilm }
  let purpose: Purpose
  /// A search and a film to start on, for showing the sheet so (as the window shots do).
  private let preselect: Choice?
  init(m: AppModel, purpose: Purpose = .newProject, query: String = "", preselect: Choice? = nil) {
    self.m = m
    self.purpose = purpose
    self.preselect = preselect
    _query = State(initialValue: query)
  }
  private var changing: Bool { purpose == .changeFilm }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
      shelf
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        chosen
        formats
        edgesRow
        kindRow
      }.padding(.horizontal, 22).padding(.vertical, 16)
      Divider()
      footer.padding(.horizontal, 22).padding(.vertical, 14)
    }
    .frame(width: 720, height: 800)
    .onAppear(perform: start)
  }

  // MARK: Parts

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(changing ? "更换胶片" : "新建工程").font(.system(size: 17, weight: .semibold))
        Text(changing ? "这一卷换成什么胶片" : "这一卷是什么胶片").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Text(changing ? "胶片、片种和画幅一起换，⌘Z 撤销" : "之后在 ② 去色罩的「胶片」里也能改").font(.system(size: 11)).foregroundStyle(.tertiary)
      }
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索：品牌、名字、感光度或片种，如 portra 400、富士 正片、黑白 120", text: $query)
          .textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
          // Return begins with the film taken; one not among those found, it takes the first of them
          // first. ↑ and ↓ go through the films on the shelf, as the search shows them.
          .onSubmit {
            let first = shown.first ?? (typed.isEmpty ? nil : .named(typed))
            if let first, !query.isEmpty, !shown.contains(choice), first != choice {
              withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { pick(first) }
            } else {
              begin()
            }
          }
          .onKeyPress(.downArrow) { step(1); return .handled }
          .onKeyPress(.upArrow) { step(-1); return .handled }
        if !query.isEmpty {
          Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).foregroundStyle(.tertiary).help("清除搜索")
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(searching ? 0.25 : 0.1)))
    }
  }

  /// The film on its shelf: the Mac's own presets, then the catalog by maker; or what was searched.
  private var shelf: some View {
    ScrollViewReader { reader in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6, pinnedViews: []) {
          if query.isEmpty {
            if !recent.isEmpty {
              recentRow
            }
            if !calibrated.isEmpty {
              shelfRow("本机标定", calibrated.map { .preset($0.id) })
            }
            ForEach(makers, id: \.self) { maker in
              shelfRow(maker + (FilmCatalog.makerAliases[maker]?.first.map { " · \($0)" } ?? ""),
                FilmCatalog.stocks.filter { $0.maker == maker }.map { .stock($0.id) })
            }
          } else if shown.isEmpty {
            Text("目录里没有「\(query)」。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 14)
            shelfRow("用这个名字作胶片名", [.named(typed)])
          } else {
            shelfRow("找到 \(shown.count) 种", shown) {
              if !typedIsListed {
                Button { withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { pick(.named(typed)) } } label: {
                  HStack(spacing: 5) {
                    Image(systemName: "character.cursor.ibeam")
                    Text("没有要找的？就用") + Text("「\(typed)」").foregroundColor(Hardware.amberText) + Text("作胶片名")
                  }
                  .font(.system(size: 11)).foregroundStyle(.secondary).contentShape(Rectangle())
                }.buttonStyle(.plain).help("这一卷的胶片名记作「\(typed)」，按通用彩色负片转换")
              }
            }
          }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
      }
      .background(LinearGradient(colors: [Self.shelfLight, Self.shelfGround], startPoint: .top, endPoint: .bottom))
      // The film last chosen in sight, when it lies below the first rows.
      .onAppear {
        if let i = onShelf.firstIndex(of: choice), i >= 14 { reader.scrollTo(choice, anchor: .center) }
      }
      // Taken with the keys, the film comes into sight.
      .onChange(of: choice) { _, now in
        if stepped { withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(now) } }
        stepped = false
      }
    }
  }
  /// `anchors`: its films are where the shelf scrolls to them; the row of those last used stands
  /// at the top with films that also stand further down, and leaves scrolling to those.
  private func shelfRow(_ title: String, _ items: [Choice], anchors: Bool = true,
    @ViewBuilder accessory: () -> some View = { EmptyView() }) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        Spacer(minLength: 12)
        accessory()
      }.padding(.leading, 2)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 86, maximum: 96), spacing: 10, alignment: .top)], alignment: .leading, spacing: 8) {
        ForEach(items, id: \.self) { item in
          if anchors { cell(item).id(item) } else { cell(item) }
        }
      }
      // The shelf's front edge under the row.
      Rectangle().fill(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.02)], startPoint: .top, endPoint: .bottom))
        .frame(height: 5).clipShape(RoundedRectangle(cornerRadius: 1.5)).padding(.top, -6)
    }.padding(.bottom, 8)
  }
  /// The films of the rolls last begun, each in the format its roll was: taken, the format comes too.
  private var recentRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("最近用过").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 86, maximum: 96), spacing: 10, alignment: .top)], alignment: .leading, spacing: 8) {
        ForEach(recent, id: \.self) { used in cell(used.choice, used: used.format) }
      }
      Rectangle().fill(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.02)], startPoint: .top, endPoint: .bottom))
        .frame(height: 5).clipShape(RoundedRectangle(cornerRadius: 1.5)).padding(.top, -6)
    }.padding(.bottom, 8)
  }
  /// `used`: the format of the roll the film was last used in, drawn so and taken with it.
  private func cell(_ item: Choice, used: FilmFormat? = nil) -> some View {
    let on = item == choice && (used == nil || used == format)
    let look = self.look(item)
    let gauge = used.map { Self.gauge(item, format: $0) } ?? self.gauge(for: item)
    return Button {
      withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { pick(item, format: used) }
    } label: {
      VStack(spacing: 3) {
        FilmObject(look: look, gauge: gauge, turns: true)
          .frame(width: 70, height: 92)
          // A calibration of the film, on a tab where it was calibrated.
          .overlay(alignment: .topTrailing) {
            if let c = look.calibration {
              Text(Self.calibrationTab(c)).font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 1.5)
                .background(Capsule().fill(Hardware.accent))
            }
          }
          // The format its roll was, on a tab, where it is 120.
          .overlay(alignment: .bottomTrailing) {
            if let used, used != .mm135 {
              Text(used.rawValue.replacingOccurrences(of: "120 · ", with: "")).font(.system(size: 9, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 4).padding(.vertical, 1.5)
                .background(Capsule().fill(.regularMaterial)).overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            }
          }
          .offset(y: on ? -5 : hovering == item ? -2 : 0)
          .shadow(color: .black.opacity(on ? 0.18 : 0), radius: on ? 8 : 0, y: on ? 6 : 0)
        Text(look.title).font(.system(size: 10.5, weight: on ? .semibold : .regular)).lineLimit(2)
          .multilineTextAlignment(.center).frame(height: 28, alignment: .top)
          .foregroundStyle(on ? AnyShapeStyle(Hardware.amberText) : AnyShapeStyle(.primary))
      }
      .frame(maxWidth: .infinity).padding(.top, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { inside in
      withAnimation(.easeOut(duration: 0.12)) { hovering = inside ? item : (hovering == item ? nil : hovering) }
    }
    .simultaneousGesture(TapGesture(count: 2).onEnded { pick(item, format: used); begin() })
    .help(look.help)
    .accessibilityLabel(look.title + "，" + look.kindText)
    .accessibilityAddTraits(on ? .isSelected : [])
    // Over its neighbours, as its leader swings out when it turns.
    .zIndex(hovering == item ? 1 : 0)
  }

  /// The film taken, large, and what converts it.
  private var chosen: some View {
    let look = self.look(choice)
    return HStack(alignment: .center, spacing: 16) {
      FilmObject(look: look, gauge: gauge(for: choice), turns: true).frame(width: 84, height: 112).zIndex(1)
      VStack(alignment: .leading, spacing: 5) {
        if let maker = look.maker { Text(maker).font(.system(size: 11)).foregroundStyle(.secondary) }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(look.name).font(.system(size: 19, weight: .semibold, design: .serif)).lineLimit(1)
          if let c = look.calibration, !look.calibrated {
            Text(c.hasPrefix("翻拍") ? "翻拍标定" + c.dropFirst(2) : c + " 标定")
              .font(.system(size: 13, weight: .medium)).foregroundStyle(Hardware.amberText).lineLimit(1)
          }
        }
        HStack(spacing: 5) { ForEach(look.tags, id: \.self) { tag($0) } }
        if !look.note.isEmpty { Text(look.note).font(.system(size: 12)).lineLimit(1) }
        Text(conversion(look)).font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let sheet = Self.sheet(choice, m: m) { published(sheet) }
      }
      Spacer(minLength: 0)
    }
  }
  /// What the maker publishes about the film: what it is for, the data sheet's facts, and links to
  /// the sheet and the maker's page, opened in the browser.
  private func published(_ sheet: FilmSheet) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(sheet.about).font(.system(size: 11.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
      if !sheet.specs.isEmpty {
        Text(sheet.specs.prefix(4).joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(.secondary)
          .lineLimit(2).fixedSize(horizontal: false, vertical: true)
          .help(sheet.specs.joined(separator: "\n"))
      }
      HStack(spacing: 14) {
        if let url = sheet.sheet {
          Button { NSWorkspace.shared.open(url) } label: {
            Label("数据表" + (sheet.title.map { " · \($0)" } ?? ""), systemImage: "doc.text")
          }.help("在浏览器里打开厂家的数据表：\(url.absoluteString)")
        } else {
          Text("厂家没有发布数据表").foregroundStyle(.tertiary)
        }
        if let url = sheet.page {
          Button { NSWorkspace.shared.open(url) } label: { Label("厂家页面", systemImage: "safari") }
            .help("在浏览器里打开厂家的产品页：\(url.absoluteString)")
        }
      }
      .buttonStyle(.link).font(.system(size: 11))
    }
  }
  /// The maker's data sheet and page for a choice: a catalog film's, or the film a preset of this
  /// Mac was calibrated from; none for a film outside the catalog.
  static func sheet(_ item: Choice, m: AppModel) -> FilmSheet? {
    switch item {
    case .stock(let id): return FilmSheets.of(id)
    case .preset(let id):
      let p = m.profiles.first { $0.id == id }
      return p.flatMap { AppModel.film(of: $0) }.flatMap { FilmCatalog.stock(named: $0) }.flatMap { FilmSheets.of($0.name) }
    case .named: return nil
    }
  }
  private func tag(_ text: String) -> some View {
    Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(Capsule().fill(Color.primary.opacity(0.07)))
  }

  /// The formats as pieces of film, each to its scale, the base as the kind of film has it.
  private var formats: some View {
    HStack(alignment: .bottom, spacing: 0) {
      Text("画幅").font(.system(size: 12, weight: .medium)).frame(width: 44, alignment: .leading).padding(.bottom, 18)
      HStack(alignment: .bottom, spacing: 12) {
        ForEach(FilmFormat.offered(keeping: format), id: \.self) { f in
          let on = f == format, offered = offers(f)
          Button {
            withAnimation(.easeOut(duration: 0.15)) { format = f }
          } label: {
            VStack(spacing: 5) {
              FormatPiece(format: f, kind: reversal ? .slide : look(choice).kind ?? .colour, selected: on, edges: on ? edges : .auto)
                .frame(width: FormatPiece.width(f), height: 44, alignment: .bottom)
              Text(f == .medium ? "120 其他" : f.rawValue.replacingOccurrences(of: "120 · ", with: ""))
                .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? AnyShapeStyle(Hardware.amberText) : AnyShapeStyle(.primary))
            }
            .opacity(offered ? 1 : 0.42).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(formatHelp(f, offered: offered))
          .accessibilityLabel("画幅 " + f.rawValue)
          .accessibilityAddTraits(on ? .isSelected : [])
        }
      }
    }
  }
  /// Whether the copies take in the film's edge, and what that means in millimetres for the
  /// format chosen: the film's width, the picture's size, the rebate either side.
  private var edgesRow: some View {
    HStack(spacing: 0) {
      Text("片边").font(.system(size: 12, weight: .medium)).frame(width: 44, alignment: .leading)
      Picker("片边", selection: $edges) {
        ForEach(PictureEdges.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
        .help("翻拍或导入的照片里，画面四周有没有拍进片边（片基、边字，135 还有齿孔）。它决定照片的尺寸怎么算（看片镜视场、导出的 dpi），以及去色罩从哪里读。")
      Text(Self.edgesNote(edges, format: format))
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 12).lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
  /// What a choice of film edge means for `format`, in its real sizes.
  static func edgesNote(_ e: PictureEdges, format f: FilmFormat) -> String {
    func mm(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x) }
    let picture: String? = f.pictureAcrossMM.map { across in
      f == .medium ? "\(mm(across)) mm 宽" : "\(mm(across))×\(mm(f.alongMM ?? across)) mm"
    }
    switch e {
    case .auto:
      return "每张照片的裁切里自动找片边，找到了去色罩只读片边以内；尺寸按裁切的短边是画面的短边算。"
    case .picture:
      guard let picture, let short = f.shortMM else { return "照片只拍到画面：不找片边，裁切就是画面。" }
      return "照片只拍到画面（\(picture)）：不找片边，裁切的短边按 \(mm(short)) mm 算尺寸。"
    case .rebate:
      guard let picture, let film = f.filmWidthMM, let across = f.pictureAcrossMM else {
        return "照片带着片边：选了画幅，才能按胶片的宽度（135 为 35 mm，120 为 61.5 mm）算尺寸。"
      }
      let side = mm((film - across) / 2)
      return f == .mm135
        ? "胶片宽 35 mm，画面 \(picture)，上下各约 \(side) mm 片边（齿孔、边字）：裁切的短边按 35 mm 算，去色罩只读片边以内。"
        : "胶片宽 61.5 mm，画面 \(picture)，两边各约 \(side) mm 片边（边字）：裁切横过胶片的一边按 61.5 mm 算，去色罩只读片边以内。"
    }
  }
  private var kindRow: some View {
    HStack(spacing: 0) {
      Text("片种").font(.system(size: 12, weight: .medium)).frame(width: 44, alignment: .leading)
      Picker("片种", selection: $reversal) {
        Text("负片").tag(false)
        Text("反转片").tag(true)
      }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
      Text(reversal ? "幻灯片、正片：不去色罩，读数就是画面" : look(choice).kind == .blackWhite ? "黑白负片按负片去色罩，颜色可以把饱和度调到 0" : "彩色负片：除以片基，去掉橙色色罩")
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 12)
    }
  }
  private var footer: some View {
    HStack {
      Text(summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
      Spacer()
      Text("↑↓ 选胶片 · ⏎ \(changing ? "换上" : "开始") · 双击也行").font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.trailing, 6)
      Button("取消") { if changing { m.changingFilm = false } else { m.askingNewProject = false } }.keyboardShortcut(.cancelAction)
      Button(changing ? "换上" : "开始") { begin() }.keyboardShortcut(.defaultAction)
    }
  }

  // MARK: What is chosen

  /// What a choice looks like and says.
  struct Look {
    var maker: String?
    var name: String
    var title: String
    var iso: Int?
    var kind: FilmStock.Kind?
    var calibrated = false
    /// A calibration of the film, on a tab over its cassette or roll: "翻拍 · 2026-10-30 19:41", "V850".
    var calibration: String?
    var named = false
    var mono = false
    var tags: [String] = []
    var note = ""
    var help = ""
    var kindText: String { kind?.rawValue ?? "彩色负片" }
    /// What its picture is drawn from, as a key to keep it by.
    var renderKey: String { [maker ?? "", name, iso.map(String.init) ?? "", kind?.rawValue ?? "", "\(calibrated)\(named)\(mono)"].joined(separator: "|") }
  }
  private func look(_ item: Choice) -> Look { Self.look(item, m: m) }
  static func look(_ item: Choice, m: AppModel) -> Look {
    switch item {
    case .stock(let id):
      guard let s = FilmCatalog.stocks.first(where: { $0.id == id }) else { return Look(name: id, title: id) }
      var tags = ["ISO \(s.iso)", s.kind.rawValue, s.process, s.gauges.map(\.rawValue).joined(separator: " · ")]
      if s.discontinued { tags.append("停产") }
      return Look(maker: s.maker, name: s.stock, title: s.stock, iso: s.iso, kind: s.kind, mono: s.mono, tags: tags, note: s.note,
        help: "\(s.name) · ISO \(s.iso) · \(s.kind.rawValue)" + (s.preset != nil ? " · 有数据表" : "") + "（双击直接开始）")
    case .preset(let id):
      // A calibration is of a film: drawn as the film's own cassette or roll, the same picture as
      // the film itself, its calibration on a tab. One of no known film keeps the plain can.
      let p = m.profiles.first { $0.id == id } ?? m.profile
      let film = AppModel.film(of: p), stock = film.flatMap { FilmCatalog.stock(named: $0) }
      let calibration = Self.calibration(p)
      let tags = [p.offsets == nil ? "导入" : "标定", p.publication.isEmpty ? "本机" : String(p.publication.prefix(28))]
      let help = p.name + (p.offsets == nil ? "：导入的预设" : "：在这台 Mac 上标定的预设") + "（双击直接开始）"
      if let s = stock {
        return Look(maker: s.maker, name: s.stock, title: Self.shortTitle(p), iso: s.iso, kind: s.kind, calibration: calibration, mono: s.mono,
          tags: tags, help: help)
      }
      if let film {
        return Look(maker: "目录外", name: film, title: Self.shortTitle(p), iso: p.iso > 0 ? Optional(p.iso) : nil, kind: .colour,
          calibration: calibration, named: true, tags: tags, help: help)
      }
      return Look(maker: "本机标定", name: p.name, title: Self.shortTitle(p), iso: p.iso > 0 ? Optional(p.iso) : nil,
        kind: .colour, calibrated: true, calibration: calibration, tags: tags, help: help)
    case .named(let name):
      return Look(maker: "目录外", name: name.isEmpty ? "未命名胶片" : name, title: name.isEmpty ? "未命名" : name, kind: .colour, named: true,
        tags: ["按通用彩色负片转换"], help: "用「\(name)」作这一卷的胶片名，按通用彩色负片转换（双击直接开始）")
    }
  }
  private func conversion(_ look: Look) -> String {
    if reversal { return "反转片不去色罩、不用通道斜率；扫描或翻拍的读数就是画面。" }
    if look.calibrated || look.calibration != nil { return "用这台 Mac 上标定的通道斜率和中性。" }
    // The film calibrated here already: the data sheet as picked, the calibration a pick away.
    let here: String = {
      guard changing, case .stock(let id) = choice, let s = FilmCatalog.stocks.first(where: { $0.id == id }),
        let c = m.calibration(for: s.name) else { return "" }
      return "这一卷的\(m.copyStandRoll ? "这次翻拍" : "扫描仪")为它标定过「\(c.name)」：要用标定的，在「本机标定」里选它。"
    }()
    if case .stock(let id) = choice, let s = FilmCatalog.stocks.first(where: { $0.id == id }), let preset = s.preset,
      let p = FilmProfile.builtins.first(where: { $0.id == preset }) {
      return "用 \(p.publication) 的通道斜率（数据表读出的近似值）。" + (here.isEmpty ? "拍过灰阶或色卡后，可以在本机标定得更准。" : here)
    }
    if !here.isEmpty { return "按通用彩色负片转换。" + here }
    if look.kind == .blackWhite { return "App 里没有它的数据：按通用负片转换，三个通道一样的斜率，自动白平衡按画面拉齐。" }
    if look.kind == .cine { return "电影负片（去掉 remjet 后）按通用彩色负片转换；自动白平衡按画面拉齐各通道。" }
    return "App 里没有它的数据表：按通用彩色负片转换，胶片名照它记；拍过灰阶或色卡后，可以在本机标定。"
  }
  private var summary: String {
    let look = look(choice)
    let calibration = look.calibrated ? "" : look.calibration.map { "（\($0.hasPrefix("翻拍") ? "翻拍标定" + $0.dropFirst(2) : $0 + " 标定")）" } ?? ""
    return (changing ? "将改为：" : "将新建：") + "\(look.maker.map { $0 == "本机标定" || $0 == "目录外" ? "" : $0 + " " } ?? "")\(look.name)\(calibration) · \(reversal ? "反转片" : "负片") · \(format.rawValue)" + (edges == .auto ? "" : " · \(edges.summary)")
  }

  // MARK: Choosing

  /// The films on the shelf, in its order: the Mac's presets and the catalog's, or what was found.
  private var onShelf: [Choice] {
    query.isEmpty ? calibrated.map { Choice.preset($0.id) } + FilmCatalog.stocks.map { Choice.stock($0.id) } : shown
  }
  /// The next or the last film on the shelf, from the one taken.
  private func step(_ by: Int) {
    let list = onShelf
    guard !list.isEmpty else { return }
    let i = list.firstIndex(of: choice).map { min(max($0 + by, 0), list.count - 1) } ?? (by > 0 ? 0 : list.count - 1)
    guard list[i] != choice else { return }
    stepped = true
    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { pick(list[i]) }
  }
  /// A film as a roll was begun with it, and the format the roll was (nil, 自动 or not kept).
  struct Used: Hashable {
    let choice: Choice
    let format: FilmFormat?
  }
  /// The films of the rolls last begun in the library, newest first, each once in each gauge: read
  /// as the sheet opens (the library stays as it is under it), not on every redraw.
  @State private var recent: [Used] = []
  /// The films of the rolls in `entries`, newest first and at most `limit`: a preset of this Mac as
  /// itself, else the roll's film in the catalog, else its own name when it has one; each with the
  /// newest of its rolls' formats, once in 135 (or 自动) and once in 120.
  static func recent(_ entries: [RollEntry], profiles: [FilmProfile], limit: Int = 6) -> [Used] {
    var found = [Used]()
    for e in entries.sorted(by: { $0.date > $1.date }) where found.count < limit {
      let item: Choice
      if !FilmProfile.builtins.contains(where: { $0.id == e.profile.id }), profiles.contains(where: { $0.id == e.profile.id }) {
        item = .preset(e.profile.id)
      } else if let s = FilmCatalog.stock(named: e.film) {
        item = .stock(s.id)
      } else if !e.film.isEmpty, !(FilmProfile.builtins + profiles).contains(where: { $0.name == e.film }) {
        item = .named(e.film)
      } else {
        continue
      }
      let format = e.format.flatMap(FilmFormat.init(rawValue:)).flatMap { $0 == .auto ? nil : $0 }
      let medium = { (f: FilmFormat?) in f.map { $0 != .mm135 } ?? false }
      if !found.contains(where: { $0.choice == item && medium($0.format) == medium(format) }) { found.append(Used(choice: item, format: format)) }
    }
    return found
  }
  private var calibrated: [FilmProfile] {
    m.profiles.filter { p in !FilmProfile.builtins.contains { $0.id == p.id } }
  }
  private var makers: [String] {
    FilmCatalog.stocks.map(\.maker).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
  }
  /// What the search finds: the Mac's presets whose name has every word, the catalog's stocks,
  /// and the words themselves as a name.
  private var shown: [Choice] {
    let words = query.split(separator: " ").map { FilmCatalog.fold(String($0)) }.filter { !$0.isEmpty }
    guard !words.isEmpty else { return [] }
    let presets = calibrated.filter { p in words.allSatisfy { FilmCatalog.fold(p.name).contains($0) } }.map { Choice.preset($0.id) }
    let stocks = FilmCatalog.search(query).map { Choice.stock($0.id) }
    return presets + stocks
  }
  /// The search as a film's name of its own.
  private var typed: String { query.trimmingCharacters(in: .whitespaces) }
  private var typedIsListed: Bool {
    FilmCatalog.stocks.contains { FilmCatalog.fold($0.name) == FilmCatalog.fold(typed) || FilmCatalog.fold($0.stock) == FilmCatalog.fold(typed) }
  }
  /// `format`: the format to take with it, from a roll it was used in.
  private func pick(_ item: Choice, format used: FilmFormat? = nil) {
    choice = item
    if let used { format = used }
    // The kind of film the stock is: a slide is not inverted; the rest are negatives.
    if let kind = look(item).kind { reversal = kind == .slide }
    // A stock made only in one gauge: a format of the other is left for another to pick.
    if case .stock(let id) = item, let s = FilmCatalog.stocks.first(where: { $0.id == id }) {
      if format != .auto && !offers(format, s) { format = s.gauges.contains(.mm135) ? .mm135 : .six6 }
    }
  }
  private func begin() {
    let (p, name) = Self.film(choice, m: m)
    if changing {
      m.applyFilm(profile: p, filmName: name, reversal: reversal, format: format, edges: edges)
    } else {
      m.beginNewProject(profile: p, filmName: name, reversal: reversal, format: format, edges: edges)
    }
  }
  /// The kind the sheet opens on: changing the film keeps the roll's; a new roll is a negative,
  /// unless the film it opens on is a slide film, whatever the last roll was.
  static func startsAsSlides(_ item: Choice, changing: Bool, m: AppModel) -> Bool {
    changing ? m.reversalRoll : look(item, m: m).kind == .slide
  }
  /// The preset a choice converts with and the film's name the roll keeps.
  static func film(_ item: Choice, m: AppModel) -> (FilmProfile, String) {
    let generic = FilmProfile.builtins.first { $0.id == "generic" } ?? m.profile
    switch item {
    case .stock(let id):
      let s = FilmCatalog.stocks.first { $0.id == id }
      return (s?.preset.flatMap { id in FilmProfile.builtins.first { $0.id == id } } ?? generic, s?.name ?? id)
    case .preset(let id):
      // The film the preset is for, not the preset's name; one for no known film keeps the roll's.
      let p = m.profiles.first { $0.id == id } ?? m.profile
      return (p, AppModel.film(of: p) ?? (m.rollFilm.isEmpty ? p.name : m.rollFilm))
    case .named(let name):
      return (generic, name.isEmpty ? generic.name : name)
    }
  }
  /// The open roll's film as the shelf has it: its preset when it is one of this Mac's, else its
  /// film in the catalog, else its name.
  static func current(_ m: AppModel) -> Choice {
    if !FilmProfile.builtins.contains(where: { $0.id == m.profile.id }), m.profiles.contains(where: { $0.id == m.profile.id }) {
      return .preset(m.profile.id)
    }
    if let s = FilmCatalog.stock(named: m.filmName) { return .stock(s.id) }
    return .named(m.filmName)
  }
  /// As last chosen: the roll's preset when it is one of this Mac's, else its film in the catalog,
  /// else its name.
  private func start() {
    recent = Self.recent(m.shelf.entries, profiles: m.profiles)
    format = m.format
    edges = m.filmEdges
    let now = Self.current(m)
    if case .named(let name) = now, name.isEmpty {} else { choice = now }
    reversal = Self.startsAsSlides(choice, changing: changing, m: m)
    if let preselect { pick(preselect) }
    DispatchQueue.main.async { searching = true }
  }
  /// The gauge a choice is drawn as: the one the format takes when the stock comes in it.
  private func gauge(for item: Choice) -> FilmStock.Gauge { Self.gauge(item, format: format) }
  static func gauge(_ item: Choice, format: FilmFormat) -> FilmStock.Gauge {
    let wanted: FilmStock.Gauge? = format == .auto ? nil : format == .mm135 ? .mm135 : .mm120
    if case .stock(let id) = item, let s = FilmCatalog.stocks.first(where: { $0.id == id }) {
      if let wanted, s.gauges.contains(wanted) { return wanted }
      return s.gauges.first ?? .mm135
    }
    return wanted ?? .mm135
  }
  private func offers(_ f: FilmFormat) -> Bool {
    if case .stock(let id) = choice, let s = FilmCatalog.stocks.first(where: { $0.id == id }) { return offers(f, s) }
    return true
  }
  private func offers(_ f: FilmFormat, _ s: FilmStock) -> Bool {
    switch f {
    case .auto: return true
    case .mm135: return s.gauges.contains(.mm135)
    default: return s.gauges.contains(.mm120)
    }
  }
  private func formatHelp(_ f: FilmFormat, offered: Bool) -> String {
    let what: String
    switch f {
    case .auto: what = "扫描时按画面自动识别；翻拍的照片长边按 135 画面的 36 mm 算"
    case .mm135: what = "135：画面 36 × 24 mm"
    case .medium: what = "120，画面长度不定：按短边 56 mm 算"
    default: what = "\(f.rawValue)：画面 \(f.alongMM.map { String(format: "%g", $0) } ?? "?") × 56 mm（沿胶片 × 横过胶片）"
    }
    return what + (offered ? "" : "（这种胶片通常没有这个画幅）")
  }

  /// A calibrated preset on the shelf: its film, then where and when, as 「Kodak Portra 160」 over
  /// 「翻拍 11-07」.
  /// What calibration a preset is past its film: "翻拍 · 2026-10-30 19:41", "V850"; nil for one
  /// that is not calibrated.
  static func calibration(_ p: FilmProfile) -> String? {
    guard p.offsets != nil else { return nil }
    let past = p.name.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
    if !past.isEmpty { return past }
    return p.id.contains("-copy-") || p.publication.hasPrefix("翻拍标定") ? "翻拍" : "V850"
  }
  /// The tab over a calibration's cassette: where it was calibrated.
  static func calibrationTab(_ calibration: String) -> String { calibration.hasPrefix("翻拍") ? "翻拍" : "V850" }
  static func shortTitle(_ p: FilmProfile) -> String {
    let parts = p.name.components(separatedBy: " · ")
    guard parts.count > 1 else { return p.name }
    let rest = parts.dropFirst().joined(separator: " ")
      .replacingOccurrences(of: #"\d{4}-(\d{2}-\d{2})( \d{2}:\d{2})?"#, with: "$1", options: .regularExpression)
    return parts[0] + "\n" + rest
  }
  /// The shelf: lit from above, darker towards its floor.
  static let shelfGround = Hardware.adaptive(NSColor(white: 0.1, alpha: 1), NSColor(white: 0.9, alpha: 1))
  static let shelfLight = Hardware.adaptive(NSColor(white: 0.145, alpha: 1), NSColor(white: 0.955, alpha: 1))
}

/// A piece of film the size a format's frame takes on it, to scale with the others: 135 with its
/// perforations, 120 its full width; the base as the film has it (orange for colour negatives,
/// black round a slide's bright frame, grey for black and white).
struct FormatPiece: View {
  let format: FilmFormat
  let kind: FilmStock.Kind
  let selected: Bool
  /// What a copy takes in, outlined: the picture alone, or the film's whole width.
  var edges: PictureEdges = .auto
  /// Points a millimetre of film takes.
  static let scale: CGFloat = 0.52
  static func size(_ f: FilmFormat) -> CGSize {
    switch f {
    case .auto: return CGSize(width: 34, height: 34)
    case .mm135: return CGSize(width: 44 * scale, height: 35 * scale)
    case .medium: return CGSize(width: 64 * scale, height: 61.5 * scale)
    default: return CGSize(width: (f.alongMM ?? 56) + 8, height: 61.5).applying(CGAffineTransform(scaleX: scale, y: scale))
    }
  }
  static func width(_ f: FilmFormat) -> CGFloat { size(f).width + 4 }
  var body: some View {
    Canvas { ctx, canvas in
      let size = Self.size(format)
      let piece = CGRect(x: (canvas.width - size.width) / 2, y: canvas.height - size.height - 2, width: size.width, height: size.height)
      let amber = Hardware.amber
      if format == .auto {
        let r = piece.insetBy(dx: 2, dy: 2)
        ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(selected ? amber : Color.secondary), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
        ctx.draw(Text("A").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundColor(selected ? amber : Color.secondary), at: CGPoint(x: r.midX, y: r.midY))
        return
      }
      let (base, frame, light) = colours
      ctx.fill(Path(roundedRect: piece, cornerRadius: 1.5), with: .linearGradient(
        Gradient(colors: [Color(nsColor: base).opacity(0.95), Color(nsColor: base.blended(withFraction: 0.25, of: .black) ?? base)]),
        startPoint: CGPoint(x: piece.minX, y: piece.minY), endPoint: CGPoint(x: piece.maxX, y: piece.maxY)))
      // A slide's black rebate keeps its edge on a dark ground.
      if kind == .slide { ctx.stroke(Path(roundedRect: piece, cornerRadius: 1.5), with: .color(.white.opacity(0.16)), lineWidth: 0.6) }
      let k = Self.scale
      let window: CGRect
      if format == .mm135 {
        window = CGRect(x: piece.midX - 18 * k, y: piece.midY - 12 * k, width: 36 * k, height: 24 * k)
        // The perforations, 4.75 mm apart, along both edges.
        var x = piece.minX + 1.6 * k
        while x + 2.8 * k < piece.maxX {
          for y in [piece.minY + 2 * k, piece.maxY - 4 * k] {
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: 1.98 * k * 1.4, height: 1.98 * k), cornerRadius: 0.4), with: .color(Color(nsColor: light).opacity(0.9)))
          }
          x += 4.75 * k
        }
      } else {
        // The frame as it lies on the film: its length along it, 56 mm across.
        let long = format.alongMM ?? 56
        window = CGRect(x: piece.midX - long / 2 * k, y: piece.midY - 28 * k, width: long * k, height: 56 * k)
      }
      ctx.fill(Path(roundedRect: window, cornerRadius: 0.8), with: .linearGradient(
        Gradient(colors: [Color(nsColor: frame.blended(withFraction: 0.18, of: .white) ?? frame), Color(nsColor: frame)]),
        startPoint: CGPoint(x: window.minX, y: window.minY), endPoint: CGPoint(x: window.maxX, y: window.maxY)))
      if format == .medium {
        // Its length not known: the frame's far end fades.
        ctx.draw(Text("?").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(Color(nsColor: light)), at: CGPoint(x: window.midX, y: window.midY))
      }
      if selected {
        ctx.stroke(Path(roundedRect: piece.insetBy(dx: -2, dy: -2), cornerRadius: 3), with: .color(amber), lineWidth: 1.6)
        // What a copy takes in: the picture alone, or the film across its whole width.
        let taken: CGRect? = edges == .picture ? window : edges == .rebate ? CGRect(x: window.minX - 1.2, y: piece.minY + 0.6, width: window.width + 2.4, height: piece.height - 1.2) : nil
        if let taken {
          ctx.stroke(Path(roundedRect: taken, cornerRadius: 1), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
        }
      }
    }
  }
  /// The base, the frame and the perforations' light.
  private var colours: (NSColor, NSColor, NSColor) {
    switch kind {
    case .slide: return (NSColor(white: 0.1, alpha: 1), NSColor(red: 0.55, green: 0.72, blue: 0.92, alpha: 1), NSColor(white: 0.92, alpha: 1))
    case .blackWhite: return (NSColor(white: 0.68, alpha: 1), NSColor(white: 0.28, alpha: 1), NSColor(white: 0.97, alpha: 1))
    case .colour, .cine: return (NSColor(red: 0.86, green: 0.52, blue: 0.27, alpha: 1), NSColor(red: 0.42, green: 0.23, blue: 0.13, alpha: 1), NSColor(white: 0.98, alpha: 1))
    }
  }
}
