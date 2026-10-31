import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What an AI assistant connected over MCP can do: read how the selected frame is converted —
/// film base and where it came from, the film's channel slopes, white balance, levels, densities
/// and the result — see it, sample it, and adjust it. Every change goes through the app's own edits,
/// so ⌘Z takes it back; nothing here scans, deletes, exports or touches files. The 去漏光 page's
/// tools are in MCPLeakTools.
enum MCPTools {
  struct Tool {
    let name: String
    let description: String
    let properties: [String: Any]
    var required: [String] = []
    var schema: [String: Any] {
      var s: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
      if !required.isEmpty { s["required"] = required }
      return s
    }
  }
  private static func number(_ text: String, _ range: ClosedRange<Double>) -> [String: Any] {
    ["type": "number", "minimum": range.lowerBound, "maximum": range.upperBound, "description": text]
  }
  private static let point: [String: Any] = [
    "x": number("横向位置，0 为画面左边，1 为右边（单张视图中看到的方向）", 0...1),
    "y": number("纵向位置，0 为画面上边，1 为下边", 0...1),
  ]
  static let tools: [Tool] = conversionTools + leakTools
  private static let conversionTools: [Tool] = [
    Tool(name: "get_state", description: "读取当前工程和选中画面的转换状态：胶片预设与各通道斜率、片基 RGB 及来源、整卷估计、白平衡、色阶、影调、扫描与对齐信息，以及负片密度和正片各通道的百分位与溢出比例。调整前先调用。", properties: [:]),
    Tool(name: "list_frames", description: "列出本卷所有画面：编号、是否勾选、是否已正式扫描及 dpi、方向。", properties: [:]),
    Tool(name: "list_presets", description: "列出可用的胶片预设：名称、通道斜率、来源，是否为本机标定。", properties: [:]),
    Tool(name: "select_frame", description: "选中某张画面（按编号，如 \"09\"）。", properties: ["name": ["type": "string", "description": "画面编号"]], required: ["name"]),
    Tool(name: "preview", description: "取得选中画面的 JPEG：positive 为当前设置转换出的正片，negative 为未反相的负片（线性数据，看起来很暗）。", properties: [
      "kind": ["type": "string", "enum": ["positive", "negative"], "description": "默认 positive"],
      "max_size": ["type": "integer", "minimum": 256, "maximum": 1600, "description": "长边像素，默认 768"],
    ]),
    Tool(name: "sample", description: "在选中画面上取点：每点返回负片的线性 RGB、各通道高于片基的密度（D），和转换后正片的 sRGB 值。用来判断哪里是中性灰、片基是否准确。", properties: [
      "points": ["type": "array", "maxItems": 20, "description": "[[x, y], …]，坐标同 pick_neutral",
        "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2]],
    ], required: ["points"]),
    Tool(name: "adjust", description: "调整选中画面的转换参数，只改给出的项；可用 ⌘Z 撤销。", properties: [
      "warmth": number("冷暖，-1 到 1", -1...1), "tint": number("绿 / 洋红，-1 到 1", -1...1),
      "exposure": number("曝光 EV", -2...2), "contrast": number("对比度", 0.5...1.6), "saturation": number("饱和度", 0...1.8),
      "black": number("黑点（关闭自动色阶时生效）", 0...0.4), "white": number("白点（关闭自动色阶时生效）", 0.6...1),
      "midtone": number("中间调", 0.4...2),
      "highlights": number("高光：亮部压暗（负）或提亮（正），黑白两端不动，-1 到 1", -1...1),
      "shadows": number("阴影：暗部提亮（正）或压暗（负），黑白两端不动，-1 到 1", -1...1),
      "angle": number("拉直角度（度）：画面绕中心转动，正数顺时针，裁去转出的空角，-45 到 45", -45...45),
      "auto_white_balance": ["type": "boolean", "description": "自动白平衡"], "auto_levels": ["type": "boolean", "description": "自动色阶"],
      "shared_balance": ["type": "boolean", "description": "整卷同一白平衡：整卷共用一个按所有画面统计的白平衡，每张颜色一致；作用于选中画面所在的整卷"],
      "shared_levels": ["type": "boolean", "description": "整卷同一色阶：整卷共用一组黑白两端，暗的场景就是暗的，每张只按曝光微调；作用于选中画面所在的整卷"],
      "base_fine_ev": ["type": "array", "items": ["type": "number", "minimum": -0.5, "maximum": 0.5], "minItems": 3, "maxItems": 3,
        "description": "片基逐通道微调 [R, G, B]，单位 EV，-0.5 到 0.5"],
    ]),
    Tool(name: "pick_film_base", description: "在指定位置取片基（只应点在未曝光的橙色片基上，例如画面边缘的片间）；会关闭自动白平衡以保留取样。", properties: point, required: ["x", "y"]),
    Tool(name: "auto_crop", description: "翻拍的照片自动裁切：按片框的四条边裁到画面以内，并按边拉直。默认只裁选中的这张；whole_roll 为 true 时整卷一起裁。和本卷其他张的画面大小对照，改正找错的边。可用 undo 撤销，原文件不改。", properties: [
      "whole_roll": ["type": "boolean", "description": "整卷一起裁，默认 false"],
    ]),
    Tool(name: "auto_film_base", description: "放弃手动片基，改用自动片基：扫描的卷用整卷片间测得的，翻拍和单张照片用片边的未曝光片基，都没有时按本张最薄处估计。", properties: [:]),
    Tool(name: "pick_neutral", description: "把指定位置作为中性灰，按它自动白平衡（灰卡、白墙、水泥等）。", properties: point, required: ["x", "y"]),
    Tool(name: "pick_highlight", description: "把指定位置作为高光（Dmax）：负片上最密、正片里应为纯白的地方（阳光下的白墙、高光反射）。各通道以它为白点对齐，它在正片里是白色；更亮的地方会剪成白。", properties: point, required: ["x", "y"]),
    Tool(name: "choose_preset", description: "选用胶片预设（按名称，部分匹配，如 \"Portra 160\"）。", properties: ["name": ["type": "string"]], required: ["name"]),
    Tool(name: "apply_to_roll", description: "把选中画面的调整同步到本卷所有画面（保留各张的方向和裁切）。", properties: [:]),
    Tool(name: "reset_adjustments", description: "把选中画面的调整恢复默认（保留输入 Gamma、方向和整卷估计）。", properties: [:]),
    Tool(name: "undo", description: "撤销 App 里的上一步编辑，和 ⌘Z 一样。", properties: [:]),
    Tool(name: "calibration_add_points", description: "预设标定：在选中画面上把这些位置加为中性点（本来就是中性灰或白的东西）。返回每个点高于片基的密度、目前所有点的拟合（各通道斜率、残差）和每个点偏离拟合多少。", properties: [
      "points": ["type": "array", "minItems": 1, "maxItems": 12, "description": "[[x, y], …]，坐标同 pick_neutral；每个点放在平坦一块的中间",
        "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2]],
    ], required: ["points"]),
    Tool(name: "calibration_state", description: "预设标定：列出已取的中性点（画面、密度、偏离拟合多少），明暗跨度够不够，和现在的拟合。", properties: [:]),
    Tool(name: "calibration_remove_point", description: "预设标定：去掉第几个中性点（从 1 数起），比如偏离拟合太多、可能不是中性的那个。", properties: [
      "index": ["type": "integer", "minimum": 1, "description": "点的序号，见 calibration_state"],
    ], required: ["index"]),
    Tool(name: "calibration_clear", description: "预设标定：清除所有已取的中性点。", properties: [:]),
    Tool(name: "calibration_make_preset", description: "预设标定：用已取的中性点生成预设并用到这一卷（翻拍的卷是「胶片 · 翻拍 · 开拍时间」，只属于这一次翻拍，新开的卷不会自动用它；扫描的卷是「胶片 · V850」）。可用 ⌘Z 撤销选用。", properties: [:]),
  ]
  static var definitions: [[String: Any]] {
    tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }
  }
  static let instructions = """
    Epson Scan plus 是彩色负片扫描与转换程序。转换的顺序：负片的线性读数除以片基（橙色色罩），换算成各通道高于片基的密度；按胶片预设或整卷估计的各通道斜率把三层的反差拉齐；再做白平衡、色阶和影调。
    - 先用 get_state 和 preview 看当前结果，用 sample 在可能是中性灰的地方取点：中性灰在正片里 R、G、B 应接近，在负片里三个通道高于片基的密度之比应接近通道斜率之比。
    - 偏色先查片基（get_state 里的 film_base 和来源）；片基可疑时用 pick_film_base 点未曝光的片间，或 base_fine_ev 微调。再用 pick_neutral 或 warmth / tint。
    - 坐标是单张视图里画面的相对位置，0–1，左上为原点。
    - 翻拍的照片四周带着片基、漏光或片夹时，先用 auto_crop 裁到画面（whole_roll 整卷一起），再看和取样：自动白平衡和色阶只看裁切以内。
    - 每次调整都能在 App 里用 ⌘Z 撤销，也可以调用 undo。转换的工具不会扫描、删除或导出文件。
    预设标定（calibration_*）定的是这种胶片在这台设备上各通道的反差（斜率），让灰从暗到亮都是灰；它还记下中性落在哪里，用这个预设时白平衡按它配平（开着自动也一样），所以取点时那种光下的灰是灰。它不套色卡，胶片的风格保留。
    原理：中性的东西三个通道反射得一样多。除掉片基以后，它每个通道高于片基的密度 = 这个通道的斜率 ×（同一个曝光量 + 这个通道的偏移），偏移里是光的颜色。所以同一种光下的中性点，从亮到暗落在一条直线上（红对绿、蓝对绿），斜率就是要标定的。挑点和去点都只按这一条，不和别的软件或别的渲染比颜色。
    用户说「帮这卷做翻拍标定」时：
    1. 先确认胶片预设对（get_state，必要时 choose_preset），并用 calibration_clear 清掉旧点。
    2. 用 list_frames、select_frame、preview 看几张，按物体找光谱平坦、本来就中性的东西：拍在胶片上的色卡或灰卡的灰块（最好）、白色或灰色的牌子、白墙、灰水泥、柏油路、白云、雪。避开天空、植物、皮肤、木头、石头和碎石（常带锈色）、刷了颜色的墙、金属（映着天空）、已经溢出的白和最暗的黑。预览可能整体偏蓝或偏色，按「这是什么东西」判断，不要按颜色判断。
    3. 光要一样：所有点都在直射阳光下，或都在同一片阴影里，不要混。阴影里是天光，比阳光蓝，同一面白墙的阴影和阳光两部分不在一条线上。夕阳、灯光下的东西不要。
    4. 明暗要拉开，在同一种光下：亮的（白墙、白牌子）和暗的（柏油路、深灰的东西）各至少两样不同的东西，中间再一两个，共 4–8 个，可以跨画面。每个点放在平坦一块的中间，不要压在边缘或纹理上。加点前可以先 sample，确认点在那个东西上。
    5. 用 calibration_add_points 加点，看报告：
       - 某个点偏离 0.03 D 以上时，报告会给出彼此落在一条线上的最大一组，按它用 calibration_remove_point 去掉组外的点（从序号大的去起）。
       - 报告说有两组各自一致、斜率不同时，不要猜哪组对：在同样的光下再加几个暗的或亮的中性点，直到只剩一组。
       - 同一段画面（比如中途调过灯以后拍的几张）的点都往一个方向偏时，这一段和别的不能混，只用其中一段的点。
       - 跨度不到 0.3 D 时再加更亮或更暗的点。
    6. 用 calibration_make_preset 生成，然后告诉用户选了哪些地方（哪张、什么东西）、得到的斜率和残差；App 会在画面上标出这些点。
    看预览时图像会发给你所在的 AI 服务；只在用户请求时这样做。
    """ + "\n" + leakInstructions

  /// Runs `name` with `arguments` against the app. Called off the main thread by the server; state
  /// is read and changed on the main thread.
  static func call(_ name: String, _ arguments: [String: Any], model: AppModel) -> (content: [[String: Any]], isError: Bool) {
    do {
      return (try run(name, arguments, model), false)
    } catch {
      return ([["type": "text", "text": "错误：" + error.localizedDescription]], true)
    }
  }
  static func onMain<T>(_ work: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try work() }
    return try DispatchQueue.main.sync(execute: work)
  }
  static func text(_ value: Any) -> [[String: Any]] {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return [["type": "text", "text": String(data: data, encoding: .utf8) ?? "{}"]]
  }
  private static func rgb(_ v: RGB) -> [String: Double] {
    ["r": (v.r * 10000).rounded() / 10000, "g": (v.g * 10000).rounded() / 10000, "b": (v.b * 10000).rounded() / 10000]
  }
  private static func round(_ v: Double, _ digits: Double = 1000) -> Double { (v * digits).rounded() / digits }
  /// The selected frame and what converting it needs, read on the main thread.
  private static func selected(_ model: AppModel) throws -> (FilmFrame, FilmProfile) {
    try onMain {
      guard let frame = model.selected else { throw DeskError.message("没有选中的画面。先在 App 里预览或打开工程，或用 select_frame。") }
      return (frame, model.profile)
    }
  }
  private static func coordinate(_ arguments: [String: Any]) throws -> CGPoint {
    guard let x = (arguments["x"] as? NSNumber)?.doubleValue, let y = (arguments["y"] as? NSNumber)?.doubleValue,
      (0...1).contains(x), (0...1).contains(y)
    else { throw DeskError.message("需要 0 到 1 之间的 x 和 y。") }
    return CGPoint(x: x, y: y)
  }
  /// The neutral points so far, how far apart, the fit they give, and how far each lies off it; when
  /// some lie off it, the largest group on one line, or that two groups disagree; when they do not
  /// fit together at all, which one left out lets the rest. Read on the main thread, worked out here.
  private static func calibrationReport(_ model: AppModel) -> String {
    let (points, profile, names, measured, copy, batch) = onMain {
      (model.calibrationPoints, model.profile, model.calibrationPoints.map { p in model.frames.first { $0.id == p.frame }?.name ?? "?" },
        model.calibrationPoints.allSatisfy { p in model.frames.first { $0.id == p.frame }.map { ($0.adjustments.base ?? $0.adjustments.rollBase) != nil } ?? false },
        model.copyStandRoll, model.copyBatch)
    }
    guard !points.isEmpty else { return "还没有中性点。" }
    let curve = measured ? profile.dataSheetToe : nil
    func fit(_ p: [NeutralPoint]) -> FilmCalibration.Fit? { try? FilmCalibration.fit(p, greenSlope: profile.slopes.g, curve: curve) }
    let found = fit(points)
    var lines = [String]()
    for (i, p) in points.enumerated() {
      let d = p.density
      var line = String(format: "%d. 第 %@ 张 · 高于片基的密度 R %.3f G %.3f B %.3f", i + 1, names[i], d[0], d[1], d[2])
      if let f = found {
        let off = misfit(p, f)
        line += String(format: " · 偏离 R %+.3f B %+.3f D", off[0], off[1])
      }
      lines.append(line)
    }
    let greens = points.map { $0.density[1] }, span = greens.max()! - greens.min()!
    lines.append(String(format: "绿色密度跨度 %.2f D（至少 %.1f）", span, FilmCalibration.minimumSpan))
    if let f = found, points.count >= 4, points.contains(where: { p in misfit(p, f).contains { abs($0) > agreement } }) {
      lines.append(agreeingGroups(points, fit))
    }
    if let f = found {
      lines.append(String(format: "拟合：R %.3f · G %.3f · B %.3f，残差 %.3f D", f.slopes.r, f.slopes.g, f.slopes.b, f.residual)
        + (f.toe.map { String(format: "，趾部 R %.2f · B %.2f", $0.r, $0.b) } ?? ""))
      lines.append("可以 calibration_make_preset，会生成「\(FilmCalibration.name(basedOn: profile, copyStand: copy, batch: batch))」。")
    } else if points.count >= 3, let i = points.indices.first(where: { j in fit(points.enumerated().filter { $0.offset != j }.map(\.element)) != nil }) {
      lines.append("这些点拟合不到一起；去掉第 \(i + 1) 个以后就可以，它可能不是中性的。")
    } else if points.count >= 2 {
      lines.append("还拟合不出来：" + fitError(points, profile.slopes.g, curve))
    }
    return lines.joined(separator: "\n")
  }
  /// How far apart two neutral points may lie off one line, red's or blue's, and still count as
  /// the same grey.
  static let agreement = 0.03
  /// How far `p` lies off fit `f`, red and blue, in density.
  private static func misfit(_ p: NeutralPoint, _ f: FilmCalibration.Fit) -> [Double] {
    let d = p.density, toe = f.toe ?? .zero
    let xg = FilmToe.exposure(d[1] / f.slopes.g, width: toe.g)
    return [0, 2].map { c in (FilmToe.exposure(d[c] / f.slopes.values[c], width: toe.values[c]) - xg - f.offsets.values[c]) * f.slopes.values[c] }
  }
  /// Of `points`, the largest groups lying on one line within `agreement` (every group of three or
  /// more, up to twelve points): which those are and which are not, or, where two such groups give
  /// slopes 0.03 apart, that the points they differ on cannot both be neutral.
  private static func agreeingGroups(_ points: [NeutralPoint], _ fit: ([NeutralPoint]) -> FilmCalibration.Fit?) -> String {
    guard points.count <= 12 else { return "点超过 12 个，不再找一致的一组；去掉偏离最大的再看。" }
    var best = [(members: [Int], fit: FilmCalibration.Fit)](), size = 0
    for mask in 1..<(1 << points.count) where mask.nonzeroBitCount >= max(3, size) {
      let members = points.indices.filter { mask & (1 << $0) != 0 }
      guard let f = fit(members.map { points[$0] }),
        members.allSatisfy({ i in misfit(points[i], f).allSatisfy { abs($0) <= agreement } })
      else { continue }
      if members.count > size { (best, size) = ([], members.count) }
      best.append((members, f))
    }
    func list(_ m: [Int]) -> String { m.map { String($0 + 1) }.joined(separator: "、") }
    guard let first = best.first else { return "找不到三个以上彼此落在一条线上的点：这些点多半混了不同的光，或有几个不是中性的。" }
    let apart = best.filter { g in max(abs(g.fit.slopes.r - first.fit.slopes.r), abs(g.fit.slopes.b - first.fit.slopes.b)) > agreement }
    if let other = apart.first {
      let differ = Set(first.members).symmetricDifference(other.members).sorted()
      return String(format: "有两组各自落在一条线上，斜率不同：第 %@ 个（R %.3f · B %.3f）和第 %@ 个（R %.3f · B %.3f）。分歧在第 %@ 个点，不会都是中性的；在同样的光下再加几个中性点，让多数决定。",
        list(first.members), first.fit.slopes.r, first.fit.slopes.b, list(other.members), other.fit.slopes.r, other.fit.slopes.b, list(differ))
    }
    let out = points.indices.filter { !first.members.contains($0) }
    return String(format: "彼此落在一条线上的最大一组：第 %@ 个（R %.3f · B %.3f）。不在里面的第 %@ 个可能不是中性的，或者光不一样，可以去掉。",
      list(first.members), first.fit.slopes.r, first.fit.slopes.b, list(out))
  }
  private static func fitError(_ points: [NeutralPoint], _ green: Double, _ curve: RGB?) -> String {
    do { _ = try FilmCalibration.fit(points, greenSlope: green, curve: curve); return "" } catch { return error.localizedDescription }
  }
  /// The negative's linear reading around a point of the frame as shown, 5 × 5 pixels.
  private static func reading(_ raster: Raster, at p: CGPoint, settings: Adjustments) -> RGB {
    let raw = ImageGeometry.raw(p, settings: settings, aspect: Double(raster.width) / Double(max(1, raster.height)))
    let x = Int(raw.x * Double(raster.width - 1)), y = Int(raw.y * Double(raster.height - 1))
    var sum = [0.0, 0.0, 0.0], n = 0.0
    for dy in -2...2 { for dx in -2...2 {
      let v = raster.pixel(x + dx, y + dy).values
      for c in 0..<3 { sum[c] += v[c] }
      n += 1
    } }
    return RGB(sum.map { $0 / n })
  }
  private static func percentiles(_ values: [Double]) -> [String: Double] {
    let s = values.sorted()
    guard !s.isEmpty else { return [:] }
    func at(_ q: Double) -> Double { round(s[min(s.count - 1, Int(q * Double(s.count - 1)))]) }
    return ["p1": at(0.01), "p50": at(0.5), "p99": at(0.99)]
  }

  private static func run(_ name: String, _ arguments: [String: Any], _ model: AppModel) throws -> [[String: Any]] {
    let pipe = ImagePipeline.shared
    switch name {
    case "get_state":
      let (frame, profile) = try selected(model)
      let summary: [String: Any] = onMain {
        var project: [String: Any] = ["film": model.filmName, "frames": model.frames.count, "preview_dpi": model.overviewDPI]
        if let folder = model.sessionURL { project["folder"] = folder.lastPathComponent }
        return ["project": project, "view": model.singleView ? "single" : "contact"]
      }
      let s = frame.adjustments
      let source = try model.source(for: frame, maxDimension: 600)
      let analysis = pipe.analyze(source, settings: s, profile: profile)
      let negative = pipe.raster(source, maxDimension: 300)
      let positive = pipe.raster(try pipe.preview(source, settings: s, profile: profile), maxDimension: 300)
      var densities = [[Double]](repeating: [], count: 3), outputs = [[Double]](repeating: [], count: 3)
      var dark = 0.0, bright = 0.0, count = 0.0
      for y in stride(from: negative.height / 20, to: negative.height * 19 / 20, by: 2) {
        for x in stride(from: negative.width / 20, to: negative.width * 19 / 20, by: 2) {
          let v = negative.pixel(x, y).values
          for c in 0..<3 { densities[c].append(log10(max(1e-6, analysis.base.values[c]) / max(1e-6, v[c])) * s.inputGamma) }
        }
      }
      for y in stride(from: 0, to: positive.height, by: 2) {
        for x in stride(from: 0, to: positive.width, by: 2) {
          let v = positive.pixel(x, y).values
          for c in 0..<3 { outputs[c].append(v[c]) }
          if v.max()! < 1.0 / 255 { dark += 1 }
          if v.min()! > 254.0 / 255 { bright += 1 }
          count += 1
        }
      }
      var framePart: [String: Any] = ["name": frame.name, "scanned": AppModel.readsScan(frame), "rotation_quarter_turns": s.rotation,
        "mirrored": s.flipHorizontal == true]
      if let dpi = frame.scanDPI, AppModel.readsScan(frame) { framePart["scan_dpi"] = dpi }
      if let l = frame.levels { framePart["aligned_to_preview"] = ["used": l.usable, "fit": round(l.fit, 10000), "gain": rgb(l.gain)] }
      var preset: [String: Any] = ["name": profile.name, "id": profile.id, "source": profile.publication, "channel_slopes": rgb(profile.slopes)]
      if let toe = profile.toe { preset["toe"] = rgb(toe) }
      if let offsets = profile.offsets { preset["calibrated_neutral_offsets"] = rgb(offsets) }
      let fromEdges: String? = onMain {
        guard let i = model.frames.firstIndex(where: { $0.id == frame.id }), let from = model.edgeBaseSource(i) else { return nil }
        return from == i ? "the unexposed film at this frame's edges" : "the unexposed film at the edges of frame \(model.frames[from].name)"
      }
      var base: [String: Any] = ["rgb": rgb(analysis.base),
        "source": s.base != nil ? "manual pick" : s.rollBasePicked == true ? "picked once and shared with the roll"
          : fromEdges ?? (s.rollBase != nil ? "measured between frames of the roll" : "estimated from the thinnest part of this frame")]
      if let fine = s.baseFine { base["fine_ev"] = rgb(fine) }
      var state = summary
      state["frame"] = framePart
      state["preset"] = preset
      state["film_base"] = base
      if let slopes = s.rollSlopes { state["roll_estimate_slopes"] = rgb(slopes) }
      var balance: [String: Any] = ["auto": s.autoWhiteBalance, "warmth": s.warmth, "tint": s.tint]
      if let neutral = s.neutralSample { balance["neutral_sample"] = rgb(neutral) }
      if let highlight = s.highlightSample { balance["highlight_sample_dmax"] = rgb(highlight) }
      state["white_balance"] = balance
      state["levels"] = ["auto": s.autoLevels, "black": s.black, "white": s.white, "midtone": s.midtone]
      state["tone"] = ["exposure": s.exposure, "contrast": s.contrast, "saturation": s.saturation, "curves": s.curves != nil]
      state["input"] = ["negative": s.inputIsNegative, "gamma": s.inputGamma]
      state["negative_density_above_base"] = ["r": percentiles(densities[0]), "g": percentiles(densities[1]), "b": percentiles(densities[2])]
      state["positive_srgb"] = ["r": percentiles(outputs[0]), "g": percentiles(outputs[1]), "b": percentiles(outputs[2]),
        "clipped_black_percent": round(dark / max(1, count) * 100, 10), "clipped_white_percent": round(bright / max(1, count) * 100, 10)]
      return text(state)
    case "list_frames":
      return text(onMain {
        model.frames.map { f -> [String: Any] in
          var item: [String: Any] = ["name": f.name, "ticked": f.enabled, "selected": f.id == model.selectedID,
            "scanned": AppModel.readsScan(f), "rotation_quarter_turns": f.adjustments.rotation]
          if let dpi = f.scanDPI, AppModel.readsScan(f) { item["scan_dpi"] = dpi }
          return item
        }
      })
    case "list_presets":
      return text(onMain {
        model.profiles.map { p -> [String: Any] in
          ["name": p.name, "id": p.id, "source": p.publication, "channel_slopes": rgb(p.slopes), "calibrated_here": p.offsets != nil,
           "in_use": p.id == model.profile.id]
        }
      })
    case "select_frame":
      guard let wanted = arguments["name"] as? String else { throw DeskError.message("需要画面编号 name。") }
      try onMain {
        guard let f = model.frames.first(where: { $0.name == wanted }) else {
          throw DeskError.message("没有编号为 \(wanted) 的画面。可用 list_frames 查看。")
        }
        model.select(f.id)
      }
      return [["type": "text", "text": "已选中第 \(wanted) 张。"]]
    case "preview":
      let (frame, profile) = try selected(model)
      let size = min(1600, max(256, (arguments["max_size"] as? NSNumber)?.intValue ?? 768))
      let negative = (arguments["kind"] as? String) == "negative"
      let source = try model.source(for: frame, maxDimension: size)
      let image = negative ? source : try pipe.preview(source, settings: frame.adjustments, profile: profile)
      let jpeg = NSMutableData()
      guard let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw DeskError.message("无法生成预览。")
      }
      CGImageDestinationAddImage(dest, pipe.opaque(image), [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
      guard CGImageDestinationFinalize(dest) else { throw DeskError.message("无法生成预览。") }
      return [
        ["type": "image", "data": (jpeg as Data).base64EncodedString(), "mimeType": "image/jpeg"],
        ["type": "text", "text": "第 \(frame.name) 张 · \(negative ? "负片（线性，未反相）" : "正片") · \(image.width) × \(image.height)"],
      ]
    case "sample":
      let (frame, profile) = try selected(model)
      guard let list = arguments["points"] as? [[Any]], !list.isEmpty, list.count <= 20 else {
        throw DeskError.message("需要 1 到 20 个点：[[x, y], …]。")
      }
      let points = try list.map { p -> CGPoint in
        guard p.count == 2, let x = (p[0] as? NSNumber)?.doubleValue, let y = (p[1] as? NSNumber)?.doubleValue,
          (0...1).contains(x), (0...1).contains(y)
        else { throw DeskError.message("每个点是 [x, y]，都在 0 到 1 之间。") }
        return CGPoint(x: x, y: y)
      }
      let s = frame.adjustments
      let source = try model.source(for: frame, maxDimension: 1500)
      let analysis = pipe.analyze(source, settings: s, profile: profile)
      let negative = pipe.raster(source, maxDimension: 1500)
      let positive = pipe.raster(try pipe.preview(source, settings: s, profile: profile), maxDimension: 1500)
      return text(points.map { p -> [String: Any] in
        let v = reading(negative, at: p, settings: s)
        let out = positive.pixel(Int(p.x * Double(positive.width - 1)), Int(p.y * Double(positive.height - 1)))
        let d = RGB((0..<3).map { log10(max(1e-6, analysis.base.values[$0]) / max(1e-6, v.values[$0])) * s.inputGamma })
        return ["x": p.x, "y": p.y, "negative_linear": rgb(v), "density_above_base": rgb(d), "positive_srgb": rgb(out)]
      })
    case "adjust":
      let known: Set = ["warmth", "tint", "exposure", "contrast", "saturation", "black", "white", "midtone", "highlights", "shadows", "auto_white_balance", "auto_levels", "base_fine_ev", "angle", "shared_balance", "shared_levels"]
      let unknown = Set(arguments.keys).subtracting(known)
      guard unknown.isEmpty else { throw DeskError.message("不认识的参数：\(unknown.sorted().joined(separator: ", "))") }
      guard !arguments.isEmpty else { throw DeskError.message("没有要改的参数。") }
      func value(_ key: String, _ range: ClosedRange<Double>) throws -> Double? {
        guard let raw = arguments[key] else { return nil }
        guard let v = (raw as? NSNumber)?.doubleValue, v.isFinite else { throw DeskError.message("\(key) 应为数字。") }
        return min(range.upperBound, max(range.lowerBound, v))
      }
      let numbers: [(WritableKeyPath<Adjustments, Double>, String, ClosedRange<Double>)] = [
        (\.warmth, "warmth", -1...1), (\.tint, "tint", -1...1), (\.exposure, "exposure", -2...2), (\.contrast, "contrast", 0.5...1.6),
        (\.saturation, "saturation", 0...1.8), (\.black, "black", 0...0.4), (\.white, "white", 0.6...1), (\.midtone, "midtone", 0.4...2),
        (\.highlightsAmount, "highlights", -1...1), (\.shadowsAmount, "shadows", -1...1),
      ]
      let values = try numbers.compactMap { n in try value(n.1, n.2).map { (n.0, $0) } }
      let angle = try value("angle", -45...45)
      var fine: RGB?
      if let raw = arguments["base_fine_ev"] {
        guard let list = raw as? [NSNumber], list.count == 3 else { throw DeskError.message("base_fine_ev 是 [R, G, B] 三个数。") }
        fine = RGB(list.map { min(0.5, max(-0.5, $0.doubleValue)) })
      }
      _ = try selected(model)
      onMain {
        model.change("AI 调整") { a in
          for (key, v) in values { a[keyPath: key] = v }
          if let b = arguments["auto_white_balance"] as? Bool {
            // Turned on from off it starts over from the picture; already on, a neutral pick stays.
            if b && !a.autoWhiteBalance {
              a.neutralSample = nil
              a.manualBalance = nil
            }
            a.autoWhiteBalance = b
          }
          if let b = arguments["auto_levels"] as? Bool { a.autoLevels = b }
          if let fine { a.baseFine = fine }
          if let angle { a.angle = abs(angle) < 0.005 ? nil : angle }
        }
        if let b = arguments["shared_balance"] as? Bool { model.setSharedBalance(b) }
        if let b = arguments["shared_levels"] as? Bool { model.setSharedLevels(b) }
      }
      return [["type": "text", "text": "已调整：\(arguments.keys.sorted().joined(separator: ", "))。可用 ⌘Z 或 undo 撤销。"]]
    case "pick_film_base", "pick_neutral", "pick_highlight":
      let p = try coordinate(arguments)
      let (frame, _) = try selected(model)
      let v = reading(pipe.raster(try model.source(for: frame, maxDimension: 2000), maxDimension: 2000), at: p, settings: frame.adjustments)
      onMain {
        switch name {
        case "pick_film_base": model.setFilmBase(v)
        case "pick_highlight": model.setHighlight(v)
        default: model.setNeutral(v)
        }
      }
      let reading = "负片线性 RGB \(String(format: "%.4f %.4f %.4f", v.r, v.g, v.b))"
      let said = ["pick_film_base": "已取片基：\(reading)；自动白平衡已关闭。", "pick_highlight": "已取高光（Dmax）：\(reading)；这一点在正片里是白色。"]
      return [["type": "text", "text": said[name] ?? "已按中性点自动白平衡：\(reading)。"]]
    case "calibration_add_points":
      guard let list = arguments["points"] as? [[Any]], !list.isEmpty else { throw DeskError.message("需要 points：[[x, y], …]。") }
      let (frame, profile) = try selected(model)
      let pts = try list.map { pair -> CGPoint in
        guard pair.count == 2, let x = (pair[0] as? NSNumber)?.doubleValue, let y = (pair[1] as? NSNumber)?.doubleValue,
          (0...1).contains(x), (0...1).contains(y)
        else { throw DeskError.message("每个点要是 0 到 1 之间的 [x, y]。") }
        return CGPoint(x: x, y: y)
      }
      // Float readings: an 8-bit one is too coarse where a linear negative is dense.
      let source = try model.source(for: frame, maxDimension: 2000)
      let s = pipe.samples(source, maxDimension: 2000)
      let fine = frame.adjustments.baseFine ?? .zero
      let analysed = pipe.analyze(try model.source(for: frame, maxDimension: 600), settings: frame.adjustments, profile: profile).base
      let base = RGB((0..<3).map { analysed.values[$0] * pow(2, fine.values[$0]) })
      let added = pts.map { p -> NeutralPoint in
        let raw = ImageGeometry.raw(p, settings: frame.adjustments, aspect: Double(s.width) / Double(max(1, s.height)))
        let x = Int(raw.x * Double(s.width - 1)), y = Int(raw.y * Double(s.height - 1))
        var sum = [0.0, 0.0, 0.0]
        for dy in -3...3 { for dx in -3...3 { let v = s.pixel(x + dx, y + dy).values; for c in 0..<3 { sum[c] += v[c] } } }
        let crop = frame.rect
        return NeutralPoint(frame: frame.id, value: RGB(sum.map { $0 / 49 }), base: base, gamma: frame.adjustments.inputGamma,
          at: CGPoint(x: crop.x + raw.x * crop.width, y: crop.y + raw.y * crop.height))
      }
      onMain { model.calibrationPoints += added }
      return [["type": "text", "text": "已在第 \(frame.name) 张加了 \(added.count) 个中性点。\n" + calibrationReport(model)]]
    case "calibration_state":
      return [["type": "text", "text": calibrationReport(model)]]
    case "calibration_remove_point":
      guard let index = (arguments["index"] as? NSNumber)?.intValue else { throw DeskError.message("需要 index。") }
      try onMain {
        guard (1...max(1, model.calibrationPoints.count)).contains(index), index <= model.calibrationPoints.count else {
          throw DeskError.message("没有第 \(index) 个点；现在有 \(model.calibrationPoints.count) 个。")
        }
        model.calibrationPoints.remove(at: index - 1)
      }
      return [["type": "text", "text": "已去掉第 \(index) 个点。\n" + calibrationReport(model)]]
    case "calibration_clear":
      onMain { model.clearCalibration() }
      return [["type": "text", "text": "已清除所有中性点。"]]
    case "calibration_make_preset":
      let result: (error: String?, name: String, status: String) = onMain {
        model.errorText = nil
        model.makeScannerPreset()
        let error = model.errorText
        model.errorText = nil
        return (error, model.profile.name, model.status)
      }
      if let error = result.error { throw DeskError.message(error) }
      return [["type": "text", "text": result.status + "。这一卷现在用「\(result.name)」。App 的单张画面上标出了这些点，「翻拍预设标定」（扫描的卷是「本机预设标定」）里列出了它们在哪几张。"]]
    case "auto_crop":
      _ = try selected(model)
      let roll = arguments["whole_roll"] as? Bool ?? false
      // It looks at the pictures apart from the main thread and finishes on it: waited for here,
      // or, called on the main thread, by letting it run.
      let finished = DispatchSemaphore(value: 0)
      var said: String?
      onMain {
        model.autoCrop(roll: roll) { text in
          said = text
          finished.signal()
        }
      }
      let end = Date().addingTimeInterval(120)
      if Thread.isMainThread {
        while said == nil && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
      } else {
        _ = finished.wait(timeout: .now() + 120)
      }
      guard let said else { throw DeskError.message("自动裁切超时。") }
      return [["type": "text", "text": said]]
    case "auto_film_base":
      _ = try selected(model)
      onMain { model.change("自动片基") { $0.base = nil; $0.basePicked = nil; $0.baseFine = nil } }
      return [["type": "text", "text": "已改用自动片基。"]]
    case "choose_preset":
      guard let wanted = (arguments["name"] as? String)?.lowercased(), !wanted.isEmpty else { throw DeskError.message("需要预设名称 name。") }
      let chosen: String = try onMain {
        guard let p = model.profiles.first(where: { $0.name.lowercased() == wanted }) ?? model.profiles.first(where: { $0.name.lowercased().contains(wanted) })
        else { throw DeskError.message("没有名为 \(wanted) 的预设。可用 list_presets 查看。") }
        model.chooseProfile(p)
        return p.name
      }
      return [["type": "text", "text": "已选用预设「\(chosen)」。"]]
    case "apply_to_roll":
      _ = try selected(model)
      onMain { model.applyToRoll() }
      return [["type": "text", "text": "已把这张的调整同步到本卷。"]]
    case "reset_adjustments":
      _ = try selected(model)
      onMain { model.resetAdjustments() }
      return [["type": "text", "text": "已重置这张的调整。"]]
    case "undo":
      if onMain({ model.page == .leak && model.leak.busy == "重建正片预览" }) { throw DeskError.message("去漏光页正在重建正片预览，稍后再撤销。") }
      let undone: String? = onMain {
        guard let undo = model.undoManager, undo.canUndo else { return nil }
        let name = undo.undoActionName
        undo.undo()
        return name
      }
      guard let undone else { throw DeskError.message("没有可以撤销的编辑。") }
      return [["type": "text", "text": "已撤销「\(undone)」。"]]
    default:
      if name.hasPrefix("leak_") { return try runLeak(name, arguments, model) }
      throw DeskError.message("没有名为 \(name) 的工具。")
    }
  }
}
