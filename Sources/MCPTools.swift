import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What an AI assistant connected over MCP can do: read how the selected frame is converted —
/// film base and where it came from, the film's channel slopes, white balance, levels, densities
/// and the result — see it, sample it, and adjust it. Every change goes through the app's own edits,
/// so ⌘Z takes it back; nothing here scans, deletes, exports or touches files.
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
  static let tools: [Tool] = [
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
      "auto_white_balance": ["type": "boolean", "description": "自动白平衡"], "auto_levels": ["type": "boolean", "description": "自动色阶"],
      "base_fine_ev": ["type": "array", "items": ["type": "number", "minimum": -0.5, "maximum": 0.5], "minItems": 3, "maxItems": 3,
        "description": "片基逐通道微调 [R, G, B]，单位 EV，-0.5 到 0.5"],
    ]),
    Tool(name: "pick_film_base", description: "在指定位置取片基（只应点在未曝光的橙色片基上，例如画面边缘的片间）；会关闭自动白平衡以保留取样。", properties: point, required: ["x", "y"]),
    Tool(name: "auto_film_base", description: "放弃手动片基，改用整卷片间测得的片基或本张最薄处的估计。", properties: [:]),
    Tool(name: "pick_neutral", description: "把指定位置作为中性灰校正白平衡（灰卡、白墙、水泥等）；会关闭自动白平衡。", properties: point, required: ["x", "y"]),
    Tool(name: "choose_preset", description: "选用胶片预设（按名称，部分匹配，如 \"Portra 160\"）。", properties: ["name": ["type": "string"]], required: ["name"]),
    Tool(name: "apply_to_roll", description: "把选中画面的调整同步到本卷所有画面（保留各张的方向和裁切）。", properties: [:]),
    Tool(name: "reset_adjustments", description: "把选中画面的调整恢复默认（保留输入 Gamma、方向和整卷估计）。", properties: [:]),
    Tool(name: "undo", description: "撤销 App 里的上一步编辑，和 ⌘Z 一样。", properties: [:]),
  ]
  static var definitions: [[String: Any]] {
    tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }
  }
  static let instructions = """
    Epson Scan plus 是彩色负片扫描与转换程序。转换的顺序：负片的线性读数除以片基（橙色色罩），换算成各通道高于片基的密度；按胶片预设或整卷估计的各通道斜率把三层的反差拉齐；再做白平衡、色阶和影调。
    - 先用 get_state 和 preview 看当前结果，用 sample 在可能是中性灰的地方取点：中性灰在正片里 R、G、B 应接近，在负片里三个通道高于片基的密度之比应接近通道斜率之比。
    - 偏色先查片基（get_state 里的 film_base 和来源）；片基可疑时用 pick_film_base 点未曝光的片间，或 base_fine_ev 微调。再用 pick_neutral 或 warmth / tint。
    - 坐标是单张视图里画面的相对位置，0–1，左上为原点。
    - 每次调整都能在 App 里用 ⌘Z 撤销，也可以调用 undo。工具不会扫描、删除或导出文件。
    """

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
  private static func text(_ value: Any) -> [[String: Any]] {
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
  /// The negative's linear reading around a point of the frame as shown, 5 × 5 pixels.
  private static func reading(_ raster: Raster, at p: CGPoint, settings: Adjustments) -> RGB {
    let raw = ImageGeometry.raw(p, settings: settings)
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
      var base: [String: Any] = ["rgb": rgb(analysis.base),
        "source": s.base != nil ? "manual pick" : s.rollBase != nil ? "measured between frames of the roll" : "estimated from the thinnest part of this frame"]
      if let fine = s.baseFine { base["fine_ev"] = rgb(fine) }
      var state = summary
      state["frame"] = framePart
      state["preset"] = preset
      state["film_base"] = base
      if let slopes = s.rollSlopes { state["roll_estimate_slopes"] = rgb(slopes) }
      var balance: [String: Any] = ["auto": s.autoWhiteBalance, "warmth": s.warmth, "tint": s.tint]
      if let neutral = s.neutralSample { balance["neutral_sample"] = rgb(neutral) }
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
      let known: Set = ["warmth", "tint", "exposure", "contrast", "saturation", "black", "white", "midtone", "auto_white_balance", "auto_levels", "base_fine_ev"]
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
      ]
      let values = try numbers.compactMap { n in try value(n.1, n.2).map { (n.0, $0) } }
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
            a.autoWhiteBalance = b
            if b { a.neutralSample = nil; a.manualBalance = nil }
          }
          if let b = arguments["auto_levels"] as? Bool { a.autoLevels = b }
          if let fine { a.baseFine = fine }
        }
      }
      return [["type": "text", "text": "已调整：\(arguments.keys.sorted().joined(separator: ", "))。可用 ⌘Z 或 undo 撤销。"]]
    case "pick_film_base", "pick_neutral":
      let p = try coordinate(arguments)
      let (frame, _) = try selected(model)
      let v = reading(pipe.raster(try model.source(for: frame, maxDimension: 2000), maxDimension: 2000), at: p, settings: frame.adjustments)
      onMain { name == "pick_film_base" ? model.setFilmBase(v) : model.setNeutral(v) }
      return [["type": "text", "text": (name == "pick_film_base" ? "已取片基" : "已设中性点") + "：负片线性 RGB \(String(format: "%.4f %.4f %.4f", v.r, v.g, v.b))；自动白平衡已关闭。"]]
    case "auto_film_base":
      _ = try selected(model)
      onMain { model.change("自动片基") { $0.base = nil; $0.baseFine = nil } }
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
      let undone: String? = onMain {
        guard let undo = model.undoManager, undo.canUndo else { return nil }
        let name = undo.undoActionName
        undo.undo()
        return name
      }
      guard let undone else { throw DeskError.message("没有可以撤销的编辑。") }
      return [["type": "text", "text": "已撤销「\(undone)」。"]]
    default:
      throw DeskError.message("没有名为 \(name) 的工具。")
    }
  }
}
