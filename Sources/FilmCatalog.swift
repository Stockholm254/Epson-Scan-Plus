import Foundation

/// A film stock as sold (and a few ended ones still met in archives), for the new-project sheet:
/// what it is, which gauges it comes in, and what converts it. Only a few have their data sheet's
/// slopes in the app (`preset`); the rest convert as the generic colour negative with their name
/// kept on the roll, until a calibration on this Mac takes over. Slides are not inverted.
struct FilmStock: Identifiable, Hashable {
  enum Kind: String, CaseIterable {
    case colour = "彩色负片"
    case slide = "反转片"
    case blackWhite = "黑白负片"
    case cine = "电影负片"
    /// Words a search may use for it.
    var words: [String] {
      switch self {
      case .colour: return ["彩色", "彩负", "负片", "c41", "colour", "color", "negative"]
      case .slide: return ["反转", "反转片", "正片", "幻灯", "幻灯片", "slide", "reversal", "chrome"]
      case .blackWhite: return ["黑白", "黑白负片", "bw", "b&w", "mono", "monochrome"]
      case .cine: return ["电影", "电影卷", "电影负片", "ecn2", "cine", "motion"]
      }
    }
  }
  enum Gauge: String, CaseIterable { case mm135 = "135", mm120 = "120" }
  /// The maker or brand as printed on the box, and the stock after it.
  let maker: String
  let stock: String
  let iso: Int
  let kind: Kind
  let gauges: [Gauge]
  /// What it is like, in a line.
  var note = ""
  /// The built-in preset with this film's data sheet, by id; nil, the generic colour negative.
  var preset: String? = nil
  /// Other names it goes by, in Chinese too.
  var aliases: [String] = []
  /// No longer made, but common in archives.
  var discontinued = false
  /// A black-and-white slide film (reversal, not inverted).
  var mono = false
  var id: String { name }
  var name: String { "\(maker) \(stock)" }
  /// How it is developed.
  var process: String {
    switch kind {
    case .colour: return "C-41"
    case .slide: return mono ? "黑白反转" : "E-6"
    case .blackWhite: return aliases.contains("c41 黑白") ? "C-41 黑白" : "黑白"
    case .cine: return "ECN-2"
    }
  }
}

/// The common films of the makers that make them, and of the long-standing brands that put their
/// name on others' (CineStill, Lomography, Rollei, AgfaPhoto), as sold in 2026: Kodak's own new
/// names (Ektacolor Pro, Ektapan, Kodacolor) beside Kodak Alaris's (Portra, T-Max), which both
/// sell. Hand-rolled and boutique re-spoolings are left out.
enum FilmCatalog {
  /// Makers' names in Chinese and other spellings, for searching.
  static let makerAliases: [String: [String]] = [
    "Kodak": ["柯达"], "Fujifilm": ["富士", "fuji"], "Ilford": ["依尔福", "伊尔福"], "Kentmere": ["肯特美"],
    "Harman": ["哈曼"], "Foma": ["弗马", "fomapan"], "ADOX": ["阿道克斯"], "Ferrania": ["费拉尼亚"],
    "Lucky": ["乐凯"], "ORWO": ["奥沃", "wolfen"], "CineStill": ["cinestill"], "Lomography": ["乐魔", "lomo"],
    "Rollei": ["禄来"], "AgfaPhoto": ["爱克发", "agfa"],
  ]
  private static let both: [FilmStock.Gauge] = [.mm135, .mm120]
  private static let only135: [FilmStock.Gauge] = [.mm135]
  private static let only120: [FilmStock.Gauge] = [.mm120]
  static let stocks: [FilmStock] = [
    // Kodak · colour negative. Eastman Kodak sells Portra as Ektacolor Pro since March 2026; Kodak
    // Alaris still sells it as Portra: the same emulsions, both listed.
    FilmStock(maker: "Kodak", stock: "Portra 160", iso: 160, kind: .colour, gauges: both, note: "细颗粒，中性，饱和度克制，高光过渡柔和", preset: "portra160", aliases: ["portra", "波特拉", "ektacolor pro 160"]),
    FilmStock(maker: "Kodak", stock: "Portra 400", iso: 400, kind: .colour, gauges: both, note: "中性略暖，肤色好，宽容度大", preset: "portra400", aliases: ["portra", "波特拉", "ektacolor pro 400"]),
    FilmStock(maker: "Kodak", stock: "Portra 800", iso: 800, kind: .colour, gauges: both, note: "高速里颗粒细，中性，肤色好", aliases: ["portra", "波特拉", "ektacolor pro 800"]),
    FilmStock(maker: "Kodak", stock: "Ektacolor Pro 160", iso: 160, kind: .colour, gauges: both, note: "Eastman Kodak 2026 年起的名字，即 Portra 160", preset: "portra160", aliases: ["ektacolor", "portra 160", "波特拉"]),
    FilmStock(maker: "Kodak", stock: "Ektacolor Pro 400", iso: 400, kind: .colour, gauges: both, note: "Eastman Kodak 2026 年起的名字，即 Portra 400", preset: "portra400", aliases: ["ektacolor", "portra 400", "波特拉"]),
    FilmStock(maker: "Kodak", stock: "Ektacolor Pro 800", iso: 800, kind: .colour, gauges: both, note: "Eastman Kodak 2026 年起的名字，即 Portra 800", aliases: ["ektacolor", "portra 800", "波特拉"]),
    FilmStock(maker: "Kodak", stock: "Ektar 100", iso: 100, kind: .colour, gauges: both, note: "极细颗粒，饱和度高，偏冷，宽容度窄", preset: "ektar100", aliases: ["ektar", "爱克塔"]),
    FilmStock(maker: "Kodak", stock: "Gold 200", iso: 200, kind: .colour, gauges: both, note: "民用，偏暖，高光琥珀色", aliases: ["gold", "金200", "金"]),
    FilmStock(maker: "Kodak", stock: "UltraMax 400", iso: 400, kind: .colour, gauges: only135, note: "民用，暖，饱和，反差比 Gold 高", aliases: ["ultramax", "um400", "超级400"]),
    FilmStock(maker: "Kodak", stock: "ColorPlus 200", iso: 200, kind: .colour, gauges: only135, note: "入门民用卷，偏暖，颗粒较粗", aliases: ["colorplus", "colourplus", "color plus"]),
    FilmStock(maker: "Kodak", stock: "Pro Image 100", iso: 100, kind: .colour, gauges: only135, note: "细颗粒，中性略暖，暗部干净", aliases: ["proimage", "pro image"]),
    FilmStock(maker: "Kodak", stock: "Kodacolor 100", iso: 100, kind: .colour, gauges: only135, note: "Eastman Kodak 2025 年起直销的民用卷", aliases: ["kodacolor"]),
    FilmStock(maker: "Kodak", stock: "Kodacolor 200", iso: 200, kind: .colour, gauges: only135, note: "Eastman Kodak 2025 年起直销的民用卷，偏暖", aliases: ["kodacolor"]),
    // Kodak · slide, cine, black and white
    FilmStock(maker: "Kodak", stock: "Ektachrome E100", iso: 100, kind: .slide, gauges: both, note: "中性准确，白干净，饱和度适中", aliases: ["e100", "ektachrome"]),
    FilmStock(maker: "Kodak", stock: "Vision3 50D 5203", iso: 50, kind: .cine, gauges: only135, note: "日光电影负片，带 remjet", aliases: ["vision3", "5203", "50d"]),
    FilmStock(maker: "Kodak", stock: "Vision3 250D 5207", iso: 250, kind: .cine, gauges: only135, note: "日光电影负片，带 remjet", aliases: ["vision3", "5207", "250d"]),
    FilmStock(maker: "Kodak", stock: "Vision3 200T 5213", iso: 200, kind: .cine, gauges: only135, note: "灯光电影负片，带 remjet", aliases: ["vision3", "5213", "200t", "灯光"]),
    FilmStock(maker: "Kodak", stock: "Vision3 500T 5219", iso: 500, kind: .cine, gauges: only135, note: "灯光电影负片，带 remjet", aliases: ["vision3", "5219", "500t", "灯光"]),
    FilmStock(maker: "Kodak", stock: "Tri-X 400", iso: 400, kind: .blackWhite, gauges: both, note: "经典颗粒，中间调层次好，增感有颗粒感", aliases: ["trix", "tx400", "tx"]),
    FilmStock(maker: "Kodak", stock: "T-Max 100", iso: 100, kind: .blackWhite, gauges: both, note: "T 颗粒，极细，线性", aliases: ["tmax", "tmx", "ektapan 100"]),
    FilmStock(maker: "Kodak", stock: "T-Max 400", iso: 400, kind: .blackWhite, gauges: both, note: "T 颗粒，比 Tri-X 细而线性", aliases: ["tmax", "tmy", "ektapan 400"]),
    FilmStock(maker: "Kodak", stock: "T-Max P3200", iso: 3200, kind: .blackWhite, gauges: only135, note: "增感用高速片", aliases: ["tmax", "tmz", "ektapan p3200"]),
    FilmStock(maker: "Kodak", stock: "Ektapan 100", iso: 100, kind: .blackWhite, gauges: both, note: "Eastman Kodak 2026 年起的名字，即 T-Max 100", aliases: ["ektapan", "tmax 100"]),
    FilmStock(maker: "Kodak", stock: "Ektapan 400", iso: 400, kind: .blackWhite, gauges: both, note: "Eastman Kodak 2026 年起的名字，即 T-Max 400", aliases: ["ektapan", "tmax 400"]),
    FilmStock(maker: "Kodak", stock: "Ektapan P3200", iso: 3200, kind: .blackWhite, gauges: only135, note: "Eastman Kodak 2026 年起的名字，即 T-Max P3200", aliases: ["ektapan", "tmax p3200"]),
    FilmStock(maker: "Kodak", stock: "Double-X 5222", iso: 250, kind: .blackWhite, gauges: only135, note: "黑白电影负片，反差高", aliases: ["doublex", "5222", "电影"]),
    // Fujifilm: what it still sells, and the films it ended that archives are full of.
    FilmStock(maker: "Fujifilm", stock: "200", iso: 200, kind: .colour, gauges: only135, note: "民用卷（Kodak 代工），偏暖", aliases: ["fujifilm 200", "fujicolor 200", "富士200"]),
    FilmStock(maker: "Fujifilm", stock: "400", iso: 400, kind: .colour, gauges: only135, note: "民用卷（Kodak 代工），暖而饱和", aliases: ["fujifilm 400", "fujicolor 400", "富士400"]),
    FilmStock(maker: "Fujifilm", stock: "Fujicolor 100", iso: 100, kind: .colour, gauges: only135, note: "日本销售，细颗粒，色彩稳定", aliases: ["fujicolor"]),
    FilmStock(maker: "Fujifilm", stock: "Superia Premium 400", iso: 400, kind: .colour, gauges: only135, note: "日本销售，明亮，反差低，绿色清新", aliases: ["superia", "premium"]),
    FilmStock(maker: "Fujifilm", stock: "Superia X-TRA 400", iso: 400, kind: .colour, gauges: only135, note: "富士自产民用卷，偏冷，蓝绿鲜明", aliases: ["superia", "xtra"], discontinued: true),
    FilmStock(maker: "Fujifilm", stock: "Fujicolor C200", iso: 200, kind: .colour, gauges: only135, note: "富士民用卷", aliases: ["c200", "fujicolor"], discontinued: true),
    FilmStock(maker: "Fujifilm", stock: "Pro 400H", iso: 400, kind: .colour, gauges: both, note: "第四层感色，粉嫩通透", aliases: ["400h"], discontinued: true),
    FilmStock(maker: "Fujifilm", stock: "Pro 160NS", iso: 160, kind: .colour, gauges: only120, note: "人像专业卷，柔和", aliases: ["160ns"], discontinued: true),
    FilmStock(maker: "Fujifilm", stock: "Velvia 50", iso: 50, kind: .slide, gauges: both, note: "极高饱和、高反差，风光用", aliases: ["velvia", "rvp50", "维尔维亚"]),
    FilmStock(maker: "Fujifilm", stock: "Velvia 100", iso: 100, kind: .slide, gauges: both, note: "比 Velvia 50 还饱和", aliases: ["velvia", "rvp100", "维尔维亚"]),
    FilmStock(maker: "Fujifilm", stock: "Provia 100F", iso: 100, kind: .slide, gauges: both, note: "真实而略鲜艳，肤色好", aliases: ["provia", "rdp", "普罗维亚"]),
    FilmStock(maker: "Fujifilm", stock: "Neopan Acros II 100", iso: 100, kind: .blackWhite, gauges: both, note: "极细颗粒，倒易律失效很小", aliases: ["acros", "neopan", "阿克洛斯"]),
    // Ilford and Kentmere (Harman Technology)
    FilmStock(maker: "Ilford", stock: "HP5 Plus 400", iso: 400, kind: .blackWhite, gauges: both, note: "经典颗粒，宽容度大，适合增感", aliases: ["hp5"]),
    FilmStock(maker: "Ilford", stock: "FP4 Plus 125", iso: 125, kind: .blackWhite, gauges: both, note: "中速细颗粒，层次平顺", aliases: ["fp4"]),
    FilmStock(maker: "Ilford", stock: "Pan F Plus 50", iso: 50, kind: .blackWhite, gauges: both, note: "Ilford 最细的传统颗粒，宽容度窄", aliases: ["panf", "pan f"]),
    FilmStock(maker: "Ilford", stock: "Delta 100", iso: 100, kind: .blackWhite, gauges: both, note: "核壳扁平颗粒，细而锐", aliases: ["delta"]),
    FilmStock(maker: "Ilford", stock: "Delta 400", iso: 400, kind: .blackWhite, gauges: both, note: "核壳扁平颗粒，细而锐", aliases: ["delta"]),
    FilmStock(maker: "Ilford", stock: "Delta 3200", iso: 3200, kind: .blackWhite, gauges: both, note: "实际约 1000，为增感设计", aliases: ["delta"]),
    FilmStock(maker: "Ilford", stock: "XP2 Super 400", iso: 400, kind: .blackWhite, gauges: both, note: "用 C-41 冲洗的黑白片，宽容度很大", aliases: ["xp2", "c41 黑白"]),
    FilmStock(maker: "Ilford", stock: "SFX 200", iso: 200, kind: .blackWhite, gauges: both, note: "红敏到约 740 nm，配红滤镜有近红外效果", aliases: ["sfx", "红外"]),
    FilmStock(maker: "Ilford", stock: "Ortho Plus 80", iso: 80, kind: .blackWhite, gauges: both, note: "正色片，红色发暗、天空发亮", aliases: ["ortho", "正色"]),
    FilmStock(maker: "Kentmere", stock: "Pan 100", iso: 100, kind: .blackWhite, gauges: both, note: "实惠的传统颗粒", aliases: ["kentmere 100"]),
    FilmStock(maker: "Kentmere", stock: "Pan 200", iso: 200, kind: .blackWhite, gauges: only135, note: "2025 年新出，反差较高", aliases: ["kentmere 200"]),
    FilmStock(maker: "Kentmere", stock: "Pan 400", iso: 400, kind: .blackWhite, gauges: both, note: "实惠的传统颗粒", aliases: ["kentmere 400"]),
    FilmStock(maker: "Harman", stock: "Phoenix 200", iso: 200, kind: .colour, gauges: both, note: "没有橙色色罩，颗粒明显，饱和高", aliases: ["phoenix", "凤凰", "蓝凤凰"], discontinued: true),
    FilmStock(maker: "Harman", stock: "Phoenix II 200", iso: 200, kind: .colour, gauges: only135, note: "2025 年重新配方，没有橙色色罩，暖而饱和", aliases: ["phoenix", "凤凰", "蓝凤凰", "phoenix 2"]),
    FilmStock(maker: "Harman", stock: "Red 125", iso: 125, kind: .colour, gauges: only135, note: "反向曝光的红调片，整体偏红", aliases: ["redscale", "红调"]),
    FilmStock(maker: "Harman", stock: "Switch Azure 125", iso: 125, kind: .colour, gauges: only135, note: "2026 年新出，红蓝两个通道互换", aliases: ["switch", "azure"]),
    // Foma, ADOX, Ferrania, ORWO, Lucky
    FilmStock(maker: "Foma", stock: "Fomapan 100 Classic", iso: 100, kind: .blackWhite, gauges: both, note: "实惠的传统颗粒", aliases: ["fomapan 100"]),
    FilmStock(maker: "Foma", stock: "Fomapan 200 Creative", iso: 200, kind: .blackWhite, gauges: both, note: "T 形颗粒，反差适中", aliases: ["fomapan 200"]),
    FilmStock(maker: "Foma", stock: "Fomapan 400 Action", iso: 400, kind: .blackWhite, gauges: both, note: "颗粒比 HP5 明显", aliases: ["fomapan 400"]),
    FilmStock(maker: "Foma", stock: "Retropan 320 Soft", iso: 320, kind: .blackWhite, gauges: both, note: "低反差画意片", aliases: ["retropan"]),
    FilmStock(maker: "Foma", stock: "Ortho 400", iso: 400, kind: .blackWhite, gauges: both, note: "高速正色片", aliases: ["ortho", "正色"]),
    FilmStock(maker: "Foma", stock: "Fomapan R100", iso: 100, kind: .slide, gauges: only135, note: "黑白反转片", aliases: ["r100", "黑白反转", "黑白"], mono: true),
    FilmStock(maker: "ADOX", stock: "CHS 100 II", iso: 100, kind: .blackWhite, gauges: both, note: "正全色，柔和，五十年代质感", aliases: ["chs"]),
    FilmStock(maker: "ADOX", stock: "HR-50", iso: 50, kind: .blackWhite, gauges: both, note: "航拍乳剂改良，极细颗粒", aliases: ["hr50"]),
    FilmStock(maker: "ADOX", stock: "CMS 20 II", iso: 20, kind: .blackWhite, gauges: both, note: "微缩胶片乳剂，几乎没有颗粒", aliases: ["cms20", "cms 20"]),
    FilmStock(maker: "ADOX", stock: "Silvermax 100", iso: 100, kind: .blackWhite, gauges: only135, note: "双倍银盐，影调宽", aliases: ["silvermax"]),
    FilmStock(maker: "ADOX", stock: "Scala 50", iso: 50, kind: .slide, gauges: only135, note: "黑白反转片，极细颗粒", aliases: ["scala", "黑白反转", "黑白"], mono: true),
    FilmStock(maker: "ADOX", stock: "Color Mission 200", iso: 200, kind: .colour, gauges: only135, note: "单批次彩色负片，绿色偏薄荷", aliases: ["color mission", "colour mission"]),
    FilmStock(maker: "Ferrania", stock: "P30 80", iso: 80, kind: .blackWhite, gauges: only135, note: "电影黑白乳剂，细颗粒，反差高", aliases: ["p30"]),
    FilmStock(maker: "Ferrania", stock: "P33 160", iso: 160, kind: .blackWhite, gauges: only135, note: "全色电影黑白乳剂，宽容度比 P30 大", aliases: ["p33"]),
    FilmStock(maker: "Ferrania", stock: "Orto 50", iso: 50, kind: .blackWhite, gauges: only135, note: "正色电影黑白乳剂", aliases: ["orto", "正色"]),
    FilmStock(maker: "ORWO", stock: "Wolfen NC500", iso: 400, kind: .colour, gauges: only135, note: "电影血统，颗粒感强，偏黄绿", aliases: ["nc500"]),
    FilmStock(maker: "ORWO", stock: "Wolfen NC400", iso: 400, kind: .colour, gauges: only135, note: "NC500 的下一代，灰色片基", aliases: ["nc400"]),
    FilmStock(maker: "ORWO", stock: "Wolfen UN54+", iso: 100, kind: .blackWhite, gauges: only135, note: "电影黑白乳剂", aliases: ["un54"]),
    FilmStock(maker: "ORWO", stock: "Wolfen N74+", iso: 400, kind: .blackWhite, gauges: only135, note: "电影黑白乳剂", aliases: ["n74"]),
    FilmStock(maker: "Lucky", stock: "Color 200", iso: 200, kind: .colour, gauges: only135, note: "乐凯民用彩色负片，偏红", aliases: ["c200", "乐凯200"]),
    FilmStock(maker: "Lucky", stock: "Color 400", iso: 400, kind: .colour, gauges: both, note: "乐凯新一代彩色负片（C400）", aliases: ["c400", "乐凯400"]),
    FilmStock(maker: "Lucky", stock: "SHD 100", iso: 100, kind: .blackWhite, gauges: both, note: "淡蓝色涤纶片基，宽容度大", aliases: ["shd", "乐凯黑白"]),
    FilmStock(maker: "Lucky", stock: "SHD 400", iso: 400, kind: .blackWhite, gauges: both, note: "淡蓝色涤纶片基，反差偏高", aliases: ["shd", "乐凯黑白"]),
    // CineStill, Lomography, Rollei, AgfaPhoto: others' emulsions under their names.
    FilmStock(maker: "CineStill", stock: "800T", iso: 800, kind: .colour, gauges: both, note: "Kodak Vision3 500T 去掉 remjet，灯光平衡，高光有红晕", aliases: ["800t", "灯光", "电影卷"]),
    FilmStock(maker: "CineStill", stock: "400D", iso: 400, kind: .colour, gauges: both, note: "日光电影乳剂去掉 remjet，饱和柔和", aliases: ["400d", "电影卷"]),
    FilmStock(maker: "CineStill", stock: "50D", iso: 50, kind: .colour, gauges: both, note: "Vision3 50D 去掉 remjet，极细颗粒，淡雅", aliases: ["50d", "电影卷"]),
    FilmStock(maker: "CineStill", stock: "BwXX", iso: 250, kind: .blackWhite, gauges: only135, note: "Kodak Double-X 5222 黑白电影片", aliases: ["bwxx", "double x"]),
    FilmStock(maker: "Lomography", stock: "Color Negative 100", iso: 100, kind: .colour, gauges: both, note: "暖而柔和", aliases: ["cn100", "lomo 100"]),
    FilmStock(maker: "Lomography", stock: "Color Negative 400", iso: 400, kind: .colour, gauges: both, note: "复古棕调", aliases: ["cn400", "lomo 400"]),
    FilmStock(maker: "Lomography", stock: "Color Negative 800", iso: 800, kind: .colour, gauges: both, note: "高速里颗粒细，偏暖", aliases: ["cn800", "lomo 800"]),
    FilmStock(maker: "Lomography", stock: "LomoChrome Classicolor 200", iso: 200, kind: .colour, gauges: only135, note: "2025 年新出，暖而低饱和的老民用卷味道", aliases: ["classicolor", "lomochrome"]),
    FilmStock(maker: "Lomography", stock: "LomoChrome Purple", iso: 400, kind: .colour, gauges: both, note: "创意片，绿色变紫", aliases: ["purple", "lomochrome", "紫"]),
    FilmStock(maker: "Lomography", stock: "LomoChrome Turquoise", iso: 400, kind: .colour, gauges: both, note: "创意片，暖色变青绿", aliases: ["turquoise", "lomochrome"]),
    FilmStock(maker: "Lomography", stock: "LomoChrome Metropolis", iso: 400, kind: .colour, gauges: both, note: "创意片，低饱和，粗粝", aliases: ["metropolis", "lomochrome"]),
    FilmStock(maker: "Lomography", stock: "Earl Grey 100", iso: 100, kind: .blackWhite, gauges: both, note: "Fomapan 100 乳剂", aliases: ["earl grey"]),
    FilmStock(maker: "Lomography", stock: "Lady Grey 400", iso: 400, kind: .blackWhite, gauges: both, note: "Fomapan 400 乳剂", aliases: ["lady grey"]),
    FilmStock(maker: "Lomography", stock: "Berlin Kino 400", iso: 400, kind: .blackWhite, gauges: both, note: "ORWO N74 电影黑白乳剂", aliases: ["berlin kino"]),
    FilmStock(maker: "Rollei", stock: "RPX 25", iso: 25, kind: .blackWhite, gauges: both, note: "航拍乳剂，极细颗粒", aliases: ["rpx"]),
    FilmStock(maker: "Rollei", stock: "RPX 100", iso: 100, kind: .blackWhite, gauges: both, note: "Kentmere 100 乳剂", aliases: ["rpx"]),
    FilmStock(maker: "Rollei", stock: "RPX 400", iso: 400, kind: .blackWhite, gauges: both, note: "Kentmere 400 乳剂", aliases: ["rpx"]),
    FilmStock(maker: "Rollei", stock: "Retro 80S", iso: 80, kind: .blackWhite, gauges: both, note: "透明片基，超全色到近红外", aliases: ["retro"]),
    FilmStock(maker: "Rollei", stock: "Retro 400S", iso: 400, kind: .blackWhite, gauges: both, note: "细颗粒，红敏扩展", aliases: ["retro"]),
    FilmStock(maker: "Rollei", stock: "Infrared 400", iso: 400, kind: .blackWhite, gauges: both, note: "近红外到约 750 nm", aliases: ["infrared", "红外"]),
    FilmStock(maker: "Rollei", stock: "Superpan 200", iso: 200, kind: .blackWhite, gauges: both, note: "超全色，细颗粒", aliases: ["superpan"]),
    FilmStock(maker: "AgfaPhoto", stock: "APX 100", iso: 100, kind: .blackWhite, gauges: only135, note: "传统颗粒", aliases: ["apx"]),
    FilmStock(maker: "AgfaPhoto", stock: "APX 400", iso: 400, kind: .blackWhite, gauges: only135, note: "传统颗粒", aliases: ["apx"]),
  ]

  /// Folded for matching: lower case, without spaces, dashes, dots or the middle dot.
  static func fold(_ s: String) -> String {
    s.lowercased().filter { !" -·._/".contains($0) }
  }
  /// What a stock is found by: its name, maker (also in Chinese), aliases, speed, kind, process
  /// and gauges, folded.
  static func haystack(_ s: FilmStock) -> [String] {
    ([s.name, s.maker, s.stock, "iso\(s.iso)", "\(s.iso)", s.process, s.kind.rawValue] + s.aliases
      + (makerAliases[s.maker] ?? []) + s.kind.words + s.gauges.map(\.rawValue)
      + (s.discontinued ? ["停产"] : []) + (s.mono ? ["黑白"] : [])).map(fold)
  }
  /// The stocks every word of `query` is found in, best first: a name that starts with the query,
  /// then those whose data sheet the app has, then those still made, in the catalog's order (by
  /// maker). A word of digits is a speed or a gauge and matches it whole, so 「400」 is not 「4000」
  /// and 「320」 is not Delta 3200. All the stocks, so ordered, for an empty query.
  static func search(_ query: String, in stocks: [FilmStock] = stocks) -> [FilmStock] {
    let words = query.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" || $0 == "、" })
      .map { fold(String($0)) }.filter { !$0.isEmpty }
    let found = stocks.enumerated().filter { _, s in
      let hay = haystack(s)
      return words.allSatisfy { w in w.allSatisfy(\.isNumber) ? hay.contains(w) : hay.contains { $0.contains(w) } }
    }
    let q = fold(query)
    func score(_ s: FilmStock) -> Int {
      (!q.isEmpty && (fold(s.name).hasPrefix(q) || fold(s.stock).hasPrefix(q)) ? 4 : 0) + (s.preset != nil ? 2 : 0) + (s.discontinued ? 0 : 1)
    }
    return found.sorted { a, b in
      let (sa, sb) = (score(a.element), score(b.element))
      return sa != sb ? sa > sb : a.offset < b.offset
    }.map(\.element)
  }
  /// The stock a preset or a roll's film name is, if the catalog has it: by its name, or the
  /// built-in preset it converts with.
  static func stock(named name: String) -> FilmStock? {
    let n = fold(FilmCalibration.film(name))
    return stocks.first { fold($0.name) == n }
      ?? stocks.first { s in s.preset.flatMap { id in FilmProfile.builtins.first { $0.id == id } }.map { fold($0.name) == n } == true }
  }
}
