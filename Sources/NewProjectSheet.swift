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
  @FocusState private var searching: Bool
  @State private var hovering: Choice?
  /// A search and a film to start on, for showing the sheet so (as the window shots do).
  private let preselect: Choice?
  init(m: AppModel, query: String = "", preselect: Choice? = nil) {
    self.m = m
    self.preselect = preselect
    _query = State(initialValue: query)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
      shelf
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        chosen
        formats
        kindRow
      }.padding(.horizontal, 22).padding(.vertical, 16)
      Divider()
      footer.padding(.horizontal, 22).padding(.vertical, 14)
    }
    .frame(width: 720, height: 690)
    .onAppear(perform: start)
  }

  // MARK: Parts

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("新建工程").font(.system(size: 17, weight: .semibold))
        Text("这一卷是什么胶片").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Text("之后在 ② 去色罩的「胶片」里也能改").font(.system(size: 11)).foregroundStyle(.tertiary)
      }
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索：品牌、名字、感光度或片种，如 portra 400、富士 正片、黑白 120", text: $query)
          .textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
          // Return takes the first film found; again, with it taken (or nothing typed), begins.
          .onSubmit {
            let first = shown.first ?? (typed.isEmpty ? nil : .named(typed))
            if let first, first != choice { withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { pick(first) } } else { begin() }
          }
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
        let order = calibrated.map { Choice.preset($0.id) } + FilmCatalog.stocks.map { Choice.stock($0.id) }
        if let i = order.firstIndex(of: choice), i >= 14 { reader.scrollTo(choice, anchor: .center) }
      }
    }
  }
  private func shelfRow(_ title: String, _ items: [Choice], @ViewBuilder accessory: () -> some View = { EmptyView() }) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        Spacer(minLength: 12)
        accessory()
      }.padding(.leading, 2)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 86, maximum: 96), spacing: 10, alignment: .top)], alignment: .leading, spacing: 8) {
        ForEach(items, id: \.self) { item in cell(item).id(item) }
      }
      // The shelf's front edge under the row.
      Rectangle().fill(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.02)], startPoint: .top, endPoint: .bottom))
        .frame(height: 5).clipShape(RoundedRectangle(cornerRadius: 1.5)).padding(.top, -6)
    }.padding(.bottom, 8)
  }
  private func cell(_ item: Choice) -> some View {
    let on = item == choice
    let look = self.look(item)
    return Button {
      withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { pick(item) }
    } label: {
      VStack(spacing: 3) {
        FilmObject(look: look, gauge: gauge(for: item))
          .frame(width: 70, height: 92)
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
    .simultaneousGesture(TapGesture(count: 2).onEnded { pick(item); begin() })
    .help(look.help)
    .accessibilityLabel(look.title + "，" + look.kindText)
    .accessibilityAddTraits(on ? .isSelected : [])
  }

  /// The film taken, large, and what converts it.
  private var chosen: some View {
    let look = self.look(choice)
    return HStack(alignment: .center, spacing: 16) {
      FilmObject(look: look, gauge: gauge(for: choice)).frame(width: 84, height: 112)
      VStack(alignment: .leading, spacing: 5) {
        if let maker = look.maker { Text(maker).font(.system(size: 11)).foregroundStyle(.secondary) }
        Text(look.name).font(.system(size: 19, weight: .semibold, design: .serif)).lineLimit(1)
        HStack(spacing: 5) { ForEach(look.tags, id: \.self) { tag($0) } }
        if !look.note.isEmpty { Text(look.note).font(.system(size: 12)).lineLimit(1) }
        Text(conversion(look)).font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
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
        ForEach(FilmFormat.allCases, id: \.self) { f in
          let on = f == format, offered = offers(f)
          Button {
            withAnimation(.easeOut(duration: 0.15)) { format = f }
          } label: {
            VStack(spacing: 5) {
              FormatPiece(format: f, kind: reversal ? .slide : look(choice).kind ?? .colour, selected: on)
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
      Button("取消") { m.askingNewProject = false }.keyboardShortcut(.cancelAction)
      Button("开始") { begin() }.keyboardShortcut(.defaultAction)
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
    var named = false
    var mono = false
    var tags: [String] = []
    var note = ""
    var help = ""
    var kindText: String { kind?.rawValue ?? "彩色负片" }
    /// What its picture is drawn from, as a key to keep it by.
    var renderKey: String { [maker ?? "", name, iso.map(String.init) ?? "", kind?.rawValue ?? "", "\(calibrated)\(named)\(mono)"].joined(separator: "|") }
  }
  private func look(_ item: Choice) -> Look {
    switch item {
    case .stock(let id):
      guard let s = FilmCatalog.stocks.first(where: { $0.id == id }) else { return Look(name: id, title: id) }
      var tags = ["ISO \(s.iso)", s.kind.rawValue, s.process, s.gauges.map(\.rawValue).joined(separator: " · ")]
      if s.discontinued { tags.append("停产") }
      return Look(maker: s.maker, name: s.stock, title: s.stock, iso: s.iso, kind: s.kind, mono: s.mono, tags: tags, note: s.note,
        help: "\(s.name) · ISO \(s.iso) · \(s.kind.rawValue)" + (s.preset != nil ? " · 有数据表" : "") + "（双击直接开始）")
    case .preset(let id):
      let p = m.profiles.first { $0.id == id } ?? m.profile
      let base = FilmCatalog.stock(named: p.name)
      return Look(maker: "本机标定", name: p.name, title: Self.shortTitle(p), iso: p.iso > 0 ? Optional(p.iso) : base?.iso,
        kind: base?.kind ?? .colour, calibrated: true, tags: ["标定", p.publication.isEmpty ? "本机" : String(p.publication.prefix(28))],
        help: p.name + "：在这台 Mac 上标定的预设（双击直接开始）")
    case .named(let name):
      return Look(maker: "目录外", name: name.isEmpty ? "未命名胶片" : name, title: name.isEmpty ? "未命名" : name, kind: .colour, named: true,
        tags: ["按通用彩色负片转换"], help: "用「\(name)」作这一卷的胶片名，按通用彩色负片转换（双击直接开始）")
    }
  }
  private func conversion(_ look: Look) -> String {
    if reversal { return "反转片不去色罩、不用通道斜率；扫描或翻拍的读数就是画面。" }
    if look.calibrated { return "用这台 Mac 上标定的通道斜率和中性。" }
    if case .stock(let id) = choice, let s = FilmCatalog.stocks.first(where: { $0.id == id }), let preset = s.preset,
      let p = FilmProfile.builtins.first(where: { $0.id == preset }) {
      return "用 \(p.publication) 的通道斜率（数据表读出的近似值）；拍过灰阶或色卡后，可以在本机标定得更准。"
    }
    if look.kind == .blackWhite { return "App 里没有它的数据：按通用负片转换，三个通道一样的斜率，自动白平衡按画面拉齐。" }
    if look.kind == .cine { return "电影负片（去掉 remjet 后）按通用彩色负片转换；自动白平衡按画面拉齐各通道。" }
    return "App 里没有它的数据表：按通用彩色负片转换，胶片名照它记；拍过灰阶或色卡后，可以在本机标定。"
  }
  private var summary: String {
    "将新建：\(look(choice).maker.map { $0 == "本机标定" || $0 == "目录外" ? "" : $0 + " " } ?? "")\(look(choice).name) · \(reversal ? "反转片" : "负片") · \(format.rawValue)"
  }

  // MARK: Choosing

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
  private func pick(_ item: Choice) {
    choice = item
    // The kind of film the stock is: a slide is not inverted; the rest are negatives.
    if let kind = look(item).kind { reversal = kind == .slide }
    // A stock made only in one gauge: a format of the other is left for another to pick.
    if case .stock(let id) = item, let s = FilmCatalog.stocks.first(where: { $0.id == id }) {
      if format != .auto && !offers(format, s) { format = s.gauges.contains(.mm135) ? .mm135 : .six6 }
    }
  }
  private func begin() {
    let generic = FilmProfile.builtins.first { $0.id == "generic" } ?? m.profile
    switch choice {
    case .stock(let id):
      let s = FilmCatalog.stocks.first { $0.id == id }
      let p = s?.preset.flatMap { id in FilmProfile.builtins.first { $0.id == id } } ?? generic
      m.beginNewProject(profile: p, filmName: s?.name ?? id, reversal: reversal, format: format)
    case .preset(let id):
      let p = m.profiles.first { $0.id == id } ?? m.profile
      m.beginNewProject(profile: p, filmName: p.name, reversal: reversal, format: format)
    case .named(let name):
      m.beginNewProject(profile: generic, filmName: name.isEmpty ? generic.name : name, reversal: reversal, format: format)
    }
  }
  /// As last chosen: the roll's preset when it is one of this Mac's, else its film in the catalog,
  /// else its name.
  private func start() {
    format = m.format
    if !FilmProfile.builtins.contains(where: { $0.id == m.profile.id }), m.profiles.contains(where: { $0.id == m.profile.id }) {
      choice = .preset(m.profile.id)
    } else if let s = FilmCatalog.stock(named: m.filmName) {
      choice = .stock(s.id)
    } else if !m.filmName.isEmpty {
      choice = .named(m.filmName)
    }
    reversal = m.reversalRoll
    if let preselect { pick(preselect) }
    DispatchQueue.main.async { searching = true }
  }
  /// The gauge a choice is drawn as: the one the format takes when the stock comes in it.
  private func gauge(for item: Choice) -> FilmStock.Gauge {
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
    default: what = "\(f.rawValue)：画面 \(f.longMM.map { String(format: "%g", $0) } ?? "?") × 56 mm"
    }
    return what + (offered ? "" : "（这种胶片通常没有这个画幅）")
  }

  /// A calibrated preset on the shelf: its film, then where and when, as 「Kodak Portra 160」 over
  /// 「翻拍 11-07」.
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
  /// Points a millimetre of film takes.
  static let scale: CGFloat = 0.52
  static func size(_ f: FilmFormat) -> CGSize {
    switch f {
    case .auto: return CGSize(width: 34, height: 34)
    case .mm135: return CGSize(width: 44 * scale, height: 35 * scale)
    case .medium: return CGSize(width: 64 * scale, height: 61.5 * scale)
    default: return CGSize(width: (f.longMM ?? 56) + 8, height: 61.5).applying(CGAffineTransform(scaleX: scale, y: scale))
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
        let long = format.longMM ?? 56
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
