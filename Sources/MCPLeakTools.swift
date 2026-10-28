import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The 去漏光 page over MCP: an assistant can open a frame, read the repair, see it, sample it,
/// change the scene, strength and basic adjustments, and refit against the reference, all through
/// the page's own changes, so ⌘Z takes them back. Making a reference is the one paid step: the tool
/// only opens the app's confirmation, which the user answers. Nothing here exports or deletes.
extension MCPTools {
  private static func number(_ text: String, _ range: ClosedRange<Double>) -> [String: Any] {
    ["type": "number", "minimum": range.lowerBound, "maximum": range.upperBound, "description": text]
  }
  static let leakTools: [Tool] = [
    Tool(name: "leak_get_state", description: "读取去漏光页的状态：当前照片与来源、是否已有参考图（及生成记录）、是否已应用去漏光，场景判断（白天 / 夜晚 / 混合及把握）、去偏色强度、保护设置、基础调整，以及参考匹配的对齐方向、可靠度、样本数和留出样本误差。", properties: [:]),
    Tool(name: "leak_list_jobs", description: "列出保存过的去漏光任务：编号、名称、是否已有参考图、最后修改时间。", properties: [:]),
    Tool(name: "leak_open", description: "切到去漏光页并打开一张照片：frame 为本卷画面编号（如 \"09\"，按它当前的调色），或 job 为 leak_list_jobs 里的任务编号。", properties: [
      "frame": ["type": "string", "description": "本卷画面编号"], "job": ["type": "string", "description": "任务编号"],
    ]),
    Tool(name: "leak_start", description: "开始去漏光：用已有参考图在本地拟合并应用（免费，不调用 API）。还没有参考图时会提示先请用户生成或导入。", properties: [:]),
    Tool(name: "leak_set", description: "调整去漏光参数，只改给出的项；场景改变时用已有参考图在本地重新拟合。可用 ⌘Z 或 undo 撤销。", properties: [
      "scene": ["type": "string", "enum": ["auto", "day", "night"], "description": "场景：自动判断、白天 / 自然光、夜晚 / 点光源"],
      "strength": number("去偏色强度，0 为原片，1 为完全按参考校正", 0...1),
      "protect_highlights": ["type": "boolean", "description": "保留灯光红晕和真实红色物体"],
      "exposure": number("曝光 EV（去漏光之前作用于原片）", -2...2), "temperature": number("冷 ↔ 暖", -100...100),
      "tint": number("绿 ↔ 品红", -100...100), "contrast": number("对比度", -50...80),
    ]),
    Tool(name: "leak_preview", description: "取得去漏光页的 JPEG：result 为当前结果，original 为修复前，reference 为参考图。", properties: [
      "kind": ["type": "string", "enum": ["result", "original", "reference"], "description": "默认 result"],
      "max_size": ["type": "integer", "minimum": 256, "maximum": 1600, "description": "长边像素，默认 768"],
    ]),
    Tool(name: "leak_sample", description: "在去漏光页的画面上取点：每点返回修复前和修复后的 Adobe RGB 值，以及该处的漏光把握（0–1）和夜景白雾把握（0–1）。坐标 0–1，左上为原点。", properties: [
      "points": ["type": "array", "maxItems": 20, "description": "[[x, y], …]",
        "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2]],
    ], required: ["points"]),
    Tool(name: "leak_detect", description: "在照片上自动检测漏光候选区域和灯光保护区：候选区域默认不启用，要用户在 App 里勾选才生效；检测到的保护区替换之前检测的，手绘保护不变。可用 ⌘Z 或 undo 撤销。", properties: [
      "sensitivity": number("灵敏度，默认 0.5", 0.1...1),
    ]),
    Tool(name: "leak_request_reference", description: "请用户生成参考图：只在 App 里打开确认窗口（说明会上传 1536 px 缩图并由用户的 OpenAI API 账户计费），由用户决定是否生成；本工具自己不上传、不计费。未设置 API Key 时打开 API 管理。", properties: [:]),
  ]
  static let leakInstructions = """
    去漏光页（FilmLightLab 修订 9）修复正片上的红色 / 品红漏光：参考图（同一张照片的干净版本，通常由图像模型生成）只指导平滑的色彩和明暗校正，输出像素都来自原片。
    - 先用 leak_open 打开照片、leak_get_state 和 leak_preview 看情况；已有参考图时 leak_start 在本地免费修复。
    - 生成参考图要上传缩图并计费，只能由用户确认：用 leak_request_reference 在 App 里打开确认窗口，不要替用户决定。
    - 结果不理想时先检查场景（夜景的边缘白雾只在夜晚模式校正），再调 strength；灯光红晕被抹掉时确认 protect_highlights 开着。
    - 这些工具不导出、不删除文件；导出由用户在 App 里完成。
    """

  private static func lab(_ model: AppModel) -> LeakLab { onMain { model.leak } }
  /// Until the page has finished what it was doing; the error it showed, if any.
  private static func settle(_ lab: LeakLab, seconds: Double = 300) throws {
    let deadline = Date().addingTimeInterval(seconds)
    usleep(50_000)
    while Date() < deadline {
      if onMain({ lab.busy == nil && !lab.updating }) { break }
      usleep(50_000)
    }
    if let error = onMain({ () -> String? in
      defer { lab.errorText = nil }
      return lab.errorText
    }) { throw DeskError.message(error) }
  }
  private static func requireBase(_ lab: LeakLab) throws {
    guard onMain({ lab.hasBase }) else { throw DeskError.message("去漏光页还没有照片。先用 leak_open 打开一张。") }
  }
  private static func jpeg(_ image: CGImage, maxSize: Int) throws -> String {
    let scaled = ImagePipeline.shared.scaled(image, maxDimension: maxSize)
    guard let srgb = ImagePipeline.shared.converted(scaled, to: CGColorSpace(name: CGColorSpace.sRGB)!, bitsPerComponent: 8) else {
      throw DeskError.message("无法生成预览。")
    }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw DeskError.message("无法生成预览。") }
    CGImageDestinationAddImage(dest, srgb, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw DeskError.message("无法生成预览。") }
    return (data as Data).base64EncodedString()
  }
  private static func short(_ v: Double, _ digits: Double = 1000) -> Double { (v * digits).rounded() / digits }

  static func runLeak(_ name: String, _ arguments: [String: Any], _ model: AppModel) throws -> [[String: Any]] {
    let lab = lab(model)
    func say(_ text: String) -> [[String: Any]] { [["type": "text", "text": text]] }
    switch name {
    case "leak_get_state":
      return text(onMain { () -> [String: Any] in
        var state: [String: Any] = ["page": model.page == .leak ? "去漏光" : "扫描与转换", "api_key_configured": lab.credentials.configured]
        guard let j = lab.job else {
          state["photo"] = NSNull()
          return state
        }
        var photo: [String: Any] = ["name": j.sourceName, "job": j.id]
        if let meta = j.meta { photo["size"] = [meta.width, meta.height]; photo["preview_size"] = [meta.previewWidth, meta.previewHeight] }
        if let o = j.origin { photo["frame"] = o.frameName; photo["project"] = URL(fileURLWithPath: o.project).deletingLastPathComponent().lastPathComponent }
        state["photo"] = photo
        var reference: [String: Any] = ["present": lab.hasReference]
        if let name = j.guideName { reference["name"] = name }
        if let g = j.generatedAI { reference["generated"] = ["model": g.model, "quality": g.quality, "at": g.generatedAt] }
        state["reference"] = reference
        let p = lab.params
        state["repaired"] = lab.repaired
        var scene: [String: Any] = ["mode": p.sceneMode]
        if let s = p.sceneInfo { scene["judged"] = s.type; scene["label"] = s.label; scene["night_weight"] = short(s.nightWeight); scene["confidence"] = short(s.confidence) }
        state["scene"] = scene
        state["protect_highlights"] = p.protectHighlights
        state["local"] = [
          "leak_regions": p.regions.count, "leak_regions_enabled": p.regions.filter { $0.enabled != false }.count,
          "protections": p.protect.count, "landmark_pairs": j.pairs?.count ?? 0,
        ]
        state["detected_protections"] = p.protect.filter { $0.detected == true }.count
        state["adjustments"] = ["exposure": p.exposure, "temperature": p.temperature, "tint": p.tint, "contrast": p.contrast]
        if let m = p.referenceModel {
          state["model"] = [
            "revision": m.revision, "strength": short(m.strength), "alignment_rotation": m.alignment.rotation,
            "alignment_score": short(m.alignment.score), "alignment_reliable": m.alignment.reliable, "samples": m.samples,
            "residual_amount": m.bilateral.amount, "held_out_log_error_before": short(m.diagnostics.heldOutBefore.logRGB, 100000),
            "held_out_log_error_after": short(m.diagnostics.heldOutAfter.logRGB, 100000),
          ]
        }
        state["notice"] = lab.notice
        return state
      })
    case "leak_list_jobs":
      return text(onMain {
        lab.jobs().map { ["job": $0.id, "name": $0.name, "has_reference": $0.hasReference, "modified": ISO8601DateFormatter().string(from: $0.modified)] }
      })
    case "leak_open":
      guard onMain({ lab.busy == nil }) else { throw DeskError.message("去漏光页正在处理（\(onMain { lab.busy ?? "" })），稍后再打开。") }
      if let id = arguments["job"] as? String {
        guard onMain({ lab.jobs().contains { $0.id == id } }) else { throw DeskError.message("没有编号为 \(id) 的任务。可用 leak_list_jobs 查看。") }
        onMain {
          model.page = .leak
          lab.open(id)
        }
      } else if let wanted = arguments["frame"] as? String {
        try onMain {
          guard let f = model.frames.first(where: { $0.name == wanted }), let origin = model.leakOrigin(f) else {
            throw DeskError.message("本卷没有编号为 \(wanted) 的画面。可用 list_frames 查看。")
          }
          model.page = .leak
          if model.selectedID != f.id { model.select(f.id) }
          lab.open(origin: origin)
        }
      } else {
        throw DeskError.message("需要 frame（画面编号）或 job（任务编号）。")
      }
      try settle(lab)
      // Whether what was asked for is what is open now.
      let wantedJob = arguments["job"] as? String, wantedFrame = arguments["frame"] as? String
      guard onMain({
        guard let j = lab.job, lab.hasBase else { return false }
        if let wantedJob { return j.id == wantedJob }
        return j.origin.map { o in model.frames.first { $0.id == o.frame }?.name == wantedFrame } ?? false
      }) else { throw DeskError.message("没有打开：" + onMain { lab.notice }) }
      return say(onMain { "已打开「\(lab.job?.sourceName ?? "")」。" + (lab.hasReference ? "已有参考图。" : "还没有参考图。") + lab.notice })
    case "leak_start":
      try requireBase(lab)
      guard onMain({ lab.hasReference }) else {
        throw DeskError.message("还没有参考图。生成参考图要计费，请用 leak_request_reference 请用户在 App 里确认，或请用户导入已有参考图。")
      }
      guard onMain({ lab.busy == nil }) else { throw DeskError.message("去漏光页正在处理，稍后再试。") }
      onMain { lab.start() }
      try settle(lab)
      guard onMain({ lab.repaired && lab.after != nil }) else { throw DeskError.message("没有应用去漏光：" + onMain { lab.notice }) }
      return say(onMain { lab.notice })
    case "leak_set":
      try requireBase(lab)
      let known: Set = ["scene", "strength", "protect_highlights", "exposure", "temperature", "tint", "contrast"]
      let unknown = Set(arguments.keys).subtracting(known)
      guard unknown.isEmpty else { throw DeskError.message("不认识的参数：\(unknown.sorted().joined(separator: ", "))") }
      guard !arguments.isEmpty else { throw DeskError.message("没有要改的参数。") }
      func value(_ key: String, _ range: ClosedRange<Double>) throws -> Double? {
        guard let raw = arguments[key] else { return nil }
        guard let v = (raw as? NSNumber)?.doubleValue, v.isFinite else { throw DeskError.message("\(key) 应为数字。") }
        return min(range.upperBound, max(range.lowerBound, v))
      }
      let numbers: [(WritableKeyPath<LeakParams, Double>, String, ClosedRange<Double>)] = [
        (\.exposure, "exposure", -2...2), (\.temperature, "temperature", -100...100), (\.tint, "tint", -100...100), (\.contrast, "contrast", -50...80),
      ]
      let values = try numbers.compactMap { n in try value(n.1, n.2).map { (n.0, $0) } }
      let strength = try value("strength", 0...1)
      if arguments["scene"] != nil, !(arguments["scene"] is String) { throw DeskError.message("scene 应为 auto、day 或 night。") }
      if arguments["protect_highlights"] != nil, !(arguments["protect_highlights"] is Bool) { throw DeskError.message("protect_highlights 应为 true 或 false。") }
      let scene = arguments["scene"] as? String, protect = arguments["protect_highlights"] as? Bool
      if let scene, !["auto", "day", "night"].contains(scene) { throw DeskError.message("scene 只能是 auto、day 或 night。") }
      guard onMain({ lab.busy == nil }) else { throw DeskError.message("去漏光页正在处理，稍后再调整。") }
      // A new scene is fitted again first; the rest then applies to that fit, a strength included.
      if let scene, scene != onMain({ lab.params.sceneMode }) {
        onMain { lab.setScene(scene) }
        try settle(lab)
      }
      if !values.isEmpty || protect != nil || strength != nil {
        if strength != nil, !onMain({ lab.model != nil }) { throw DeskError.message("还没有应用去漏光，没有强度可调。先 leak_start。") }
        onMain {
          lab.change("AI 调整去漏光") { p in
            for (key, v) in values { p[keyPath: key] = v }
            if let protect { p.protectHighlights = protect }
            if let strength { p.referenceModel?.strength = strength }
          }
        }
        try settle(lab)
      }
      return say("已调整：\(arguments.keys.sorted().joined(separator: ", "))。可用 ⌘Z 或 undo 撤销。" + (scene != nil ? onMain { lab.notice } : ""))
    case "leak_preview":
      try requireBase(lab)
      let size = min(1600, max(256, (arguments["max_size"] as? NSNumber)?.intValue ?? 768))
      let kind = arguments["kind"] as? String ?? "result"
      let image: CGImage? = onMain {
        switch kind {
        case "original": return lab.before
        case "reference": return lab.reference
        default: return lab.after ?? lab.before
        }
      }
      guard let image else { throw DeskError.message(kind == "reference" ? "还没有参考图。" : "预览尚未生成。") }
      if kind == "result", onMain({ lab.repaired && lab.after == nil }) { throw DeskError.message("去漏光预览没有生成：" + onMain { lab.notice }) }
      let label = ["original": "修复前", "reference": "参考图"][kind] ?? (onMain { lab.repaired && lab.after != nil } ? "去漏光后" : "尚未去漏光")
      return [
        ["type": "image", "data": try jpeg(image, maxSize: size), "mimeType": "image/jpeg"],
        ["type": "text", "text": "\(onMain { lab.job?.sourceName ?? "" }) · \(label) · \(image.width) × \(image.height)"],
      ]
    case "leak_sample":
      try requireBase(lab)
      guard let list = arguments["points"] as? [[Any]], !list.isEmpty, list.count <= 20 else { throw DeskError.message("需要 1 到 20 个点：[[x, y], …]。") }
      let points = try list.map { p -> (Double, Double) in
        guard p.count == 2, let x = (p[0] as? NSNumber)?.doubleValue, let y = (p[1] as? NSNumber)?.doubleValue, (0...1).contains(x), (0...1).contains(y)
        else { throw DeskError.message("每个点是 [x, y]，都在 0 到 1 之间。") }
        return (x, y)
      }
      let (before, after, model) = onMain { (lab.before, lab.after, lab.model) }
      guard let before else { throw DeskError.message("预览尚未生成。") }
      let original = try LeakImage(before), result = try after.map { try LeakImage($0) }
      func rgb(_ v: SIMD3<Double>) -> [String: Double] { ["r": short(v.x, 10000), "g": short(v.y, 10000), "b": short(v.z, 10000)] }
      return text(points.map { x, y -> [String: Any] in
        var item: [String: Any] = ["x": x, "y": y, "original_adobe_rgb": rgb(LeakEngine.sample(original, x, y, 0.004))]
        if let result { item["result_adobe_rgb"] = rgb(LeakEngine.sample(result, x, y, 0.004)) }
        if let model {
          item["leak_confidence"] = short(model.veilField.sample(x, y))
          item["night_white_fog_confidence"] = short(model.neutralField.sample(x, y))
        }
        return item
      })
    case "leak_detect":
      try requireBase(lab)
      guard onMain({ lab.busy == nil }) else { throw DeskError.message("去漏光页正在处理，稍后再试。") }
      if let raw = arguments["sensitivity"] {
        guard let v = (raw as? NSNumber)?.doubleValue, v.isFinite else { throw DeskError.message("sensitivity 应为数字。") }
        onMain { lab.sensitivity = min(1, max(0.1, v)) }
      }
      onMain { lab.detect() }
      try settle(lab)
      return say(onMain {
        "\(lab.notice)\n现有漏光区域 \(lab.params.regions.count) 个（启用 \(lab.params.regions.filter { $0.enabled != false }.count) 个），保护区 \(lab.params.protect.count) 个。"
      })
    case "leak_request_reference":
      try requireBase(lab)
      let configured = onMain { () -> Bool in
        model.page = .leak
        if lab.credentials.configured { lab.showGenerate = true } else { lab.showAPI = true }
        return lab.credentials.configured
      }
      return say(configured
        ? "已在 App 里打开「生成参考图并去漏光」的确认窗口。是否上传缩图并计费由用户决定；生成完成后可用 leak_get_state 查看。"
        : "还没有设置 OpenAI API Key：已在 App 里打开 API 管理，请用户自己填写（不要在对话里索取 Key）。")
    default:
      throw DeskError.message("没有名为 \(name) 的工具。")
    }
  }
}
