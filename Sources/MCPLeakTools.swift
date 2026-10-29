import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The 去漏光 page over MCP, all that FilmLightLab's own API does: an assistant can open a frame or
/// import a file, import a reference, read the repair, see it, sample it, change the scene,
/// strength and basic adjustments, draw, tick and protect local regions, set landmarks, turn and
/// crop, load a preset, and refit against the reference, all through the page's own changes, so
/// ⌘Z takes them back. Files it names are read and copied, never changed. Making a reference is
/// the one paid step, and writing a file (an export, a preset) the user's: those tools only open
/// the app's confirmation or save panel, which the user answers. Nothing here deletes a file or
/// sets the API key.
extension MCPTools {
  private static func number(_ text: String, _ range: ClosedRange<Double>) -> [String: Any] {
    ["type": "number", "minimum": range.lowerBound, "maximum": range.upperBound, "description": text]
  }
  private static func pointPair(_ text: String) -> [String: Any] {
    ["type": "array", "items": ["type": "number", "minimum": 0, "maximum": 1], "minItems": 2, "maxItems": 2, "description": text]
  }
  private static let fileField: [String: Any] = ["type": "string", "description": "文件的完整路径（以 / 或 ~ 开头）"]
  private static let regionFields: [String: Any] = [
    "x": number("椭圆中心的横向位置", 0...1), "y": number("椭圆中心的纵向位置", 0...1),
    "rx": number("横向半径，占画宽", 0.005...0.5), "ry": number("纵向半径，占画高", 0.005...0.5),
    "clean_point": pointPair("[x, y]：同材质、没有漏光的干净位置，区域按它的颜色校正"),
    "mode": ["type": "string", "enum": ["chroma", "fog"], "description": "chroma 去掉色偏、保留明暗（默认）；fog 减去亮雾、恢复暗部"],
    "amount": number("强度，新建默认 0.8", 0...1), "feather": number("羽化，新建默认 0.8", 0...1),
    "name": ["type": "string", "maxLength": 80, "description": "名称"],
  ]
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
    Tool(name: "leak_request_reference", description: "请用户生成参考图：只在 App 里打开确认窗口（说明会上传 1536 px 缩图并由用户的 OpenAI API 账户计费），由用户决定是否生成；本工具自己不上传、不计费。quality 和 note 只预填到窗口里，用户可以改。未设置 API Key 时打开 API 管理。", properties: [
      "quality": ["type": "string", "enum": ["high", "medium"], "description": "预填的质量，默认 high"],
      "note": ["type": "string", "maxLength": 2000, "description": "预填的附加要求（可选）"],
    ]),
    Tool(name: "leak_import", description: "切到去漏光页，导入一张已去色罩、反相的正片文件（TIFF / PNG / JPEG，推荐带 ICC 的 16 位 TIFF），复制进一个新任务；原文件不改动。", properties: [
      "path": fileField,
    ], required: ["path"]),
    Tool(name: "leak_import_reference", description: "为当前照片导入参考图：同一张照片在别处去掉漏光的完整版本（TIFF / PNG / JPEG），复制进任务；免费，不调用 API。会清空之前的对应点；之后用 leak_start 在本地拟合。", properties: [
      "path": fileField,
    ], required: ["path"]),
    Tool(name: "leak_list_regions", description: "列出局部漏光区域和保护区：编号、名称、形状、模式、中心与半径、强度、羽化、干净参考点、是否启用、是否自动检测及把握。坐标 0–1，左上为原点，和 leak_preview 的画面一致。", properties: [:]),
    Tool(name: "leak_add_region", description: "画一个椭圆漏光区域，按 clean_point 的颜色校正区域里的漏光；新建即启用。可用 ⌘Z 或 undo 撤销。", properties: regionFields,
      required: ["x", "y", "rx", "ry", "clean_point"]),
    Tool(name: "leak_update_region", description: "修改一个区域或保护区，只改给出的项：enabled 启用或停用（自动检测的候选启用后才生效）；漏光区域还能改干净参考点、模式、强度、羽化，椭圆的还能改中心和半径；保护区只能改 enabled 和 name。可用 ⌘Z 或 undo 撤销。", properties: regionFields.merging([
      "id": ["type": "string", "description": "leak_list_regions 里的编号"], "enabled": ["type": "boolean", "description": "启用或停用"],
    ]) { a, _ in a }, required: ["id"]),
    Tool(name: "leak_delete_region", description: "删除一个漏光区域或保护区。可用 ⌘Z 或 undo 撤销。", properties: [
      "id": ["type": "string", "description": "leak_list_regions 里的编号"],
    ], required: ["id"]),
    Tool(name: "leak_add_protection", description: "画保护区：沿 points 的一笔圆头画笔，下面的原片不被校正（灯光红晕、真实的红色物体），不管拟合和检测怎么判断。可用 ⌘Z 或 undo 撤销。", properties: [
      "points": ["type": "array", "minItems": 1, "maxItems": 2000, "description": "[[x, y], …]，一个点即一个圆", "items": pointPair("[x, y]")],
      "radius": number("画笔半径，占画宽；默认用 App 里的画笔大小", 0.005...0.08),
    ], required: ["points"]),
    Tool(name: "leak_set_landmarks", description: "设原片和参考图的对应点，自动对齐不确定（leak_get_state 里 alignment_reliable 为 false）时用：4 到 20 对，尽量分散在四角附近；空列表则清空，按相同构图对齐。之后用 leak_start 在本地重新拟合。这一步不进撤销。", properties: [
      "pairs": ["type": "array", "maxItems": 20, "description": "[{original: [x, y], reference: [x, y]}, …]", "items": [
        "type": "object", "required": ["original", "reference"], "additionalProperties": false, "properties": [
          "original": pointPair("原片（leak_preview 的 original）上的点"), "reference": pointPair("参考图上的同一处"),
        ],
      ]],
    ], required: ["pairs"]),
    Tool(name: "leak_rotate", description: "把原片转 90° 或 180°：重建正片预览，清空裁切、区域、保护区和对应点（位置随画面改变）；已有参考图时在本地重新匹配，不调用 API。可用 ⌘Z 或 undo 撤销。", properties: [
      "quarter_turns": ["type": "integer", "enum": [-1, 1, 2], "description": "1 右转 90°，-1 左转 90°，2 转 180°"],
    ], required: ["quarter_turns"]),
    Tool(name: "leak_crop", description: "裁切转好方向的原片（0–1）：重建正片预览，清空区域、保护区和对应点；已有参考图时在本地重新匹配。x 0、y 0、w 1、h 1 为不裁切。可用 ⌘Z 或 undo 撤销。", properties: [
      "x": number("左边", 0...0.9), "y": number("上边", 0...0.9), "w": number("宽", 0.05...1), "h": number("高", 0.05...1),
    ], required: ["x", "y", "w", "h"]),
    Tool(name: "leak_clear_correction", description: "停用参考校正：只剩基础调整和局部区域；参考图留着，leak_start 可免费重新应用。可用 ⌘Z 或 undo 撤销。", properties: [:]),
    Tool(name: "leak_load_preset", description: "载入去漏光预设（Epson Scan plus 或 FilmLightLab 保存的 JSON）：参数、区域和对应点；方向或裁切不同时按预设重建。可用 ⌘Z 或 undo 撤销。", properties: [
      "path": fileField,
    ], required: ["path"]),
    Tool(name: "leak_save_preset", description: "请用户保存去漏光预设：只在 App 里打开保存窗口，由用户选位置；本工具自己不写文件。", properties: [:]),
    Tool(name: "leak_export", description: "请用户导出去漏光结果：只在 App 里打开导出窗口（全分辨率 16 位 Adobe RGB TIFF，附 sRGB JPEG 和参数记录），由用户选位置；本工具自己不写文件。要先应用去漏光。", properties: [:]),
  ]
  static let leakInstructions = """
    去漏光页（FilmLightLab 修订 9）修复正片上的红色 / 品红漏光：参考图（同一张照片的干净版本，通常由图像模型生成）只指导平滑的色彩和明暗校正，输出像素都来自原片。
    - 先用 leak_open 打开本卷照片或任务（或 leak_import 导入文件），leak_get_state 和 leak_preview 看情况；已有参考图时 leak_start 在本地免费修复。
    - 生成参考图要上传缩图并计费，只能由用户确认：用 leak_request_reference 在 App 里打开确认窗口，不要替用户决定。用户已有干净版本时用 leak_import_reference，免费。
    - 结果不理想时先检查场景（夜景的边缘白雾只在夜晚模式校正），再调 strength；灯光红晕被抹掉时确认 protect_highlights 开着，或用 leak_add_protection 画保护区。
    - 局部漏光：leak_detect 找候选（默认不启用），leak_list_regions 查看，leak_update_region 启用或修改；也可以 leak_add_region 画椭圆，clean_point 点在同材质、没有漏光的地方。
    - 自动对齐不可靠时用 leak_set_landmarks 给 4 对以上对应点，再 leak_start。旋转和裁切会清空区域、保护区和对应点，先定方向和裁切。
    - 工具只读取给出路径的文件（leak_import、leak_import_reference、leak_load_preset），复制进任务，原文件不改；写文件（leak_export、leak_save_preset）只在 App 里打开保存窗口，由用户选位置。工具不删除文件，也读不到、改不了 API Key。
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
  private static func idle(_ lab: LeakLab) throws {
    guard onMain({ lab.busy == nil }) else { throw DeskError.message("去漏光页正在处理（\(onMain { lab.busy ?? "" })），稍后再试。") }
  }
  /// Refuses what a tool does not take.
  private static func only(_ arguments: [String: Any], _ known: Set<String>) throws {
    let unknown = Set(arguments.keys).subtracting(known)
    guard unknown.isEmpty else { throw DeskError.message("不认识的参数：\(unknown.sorted().joined(separator: ", "))") }
  }
  /// A number given, held to `range`; nil when it is not given.
  private static func double(_ arguments: [String: Any], _ key: String, _ range: ClosedRange<Double>) throws -> Double? {
    guard let raw = arguments[key] else { return nil }
    guard let v = (raw as? NSNumber)?.doubleValue, v.isFinite else { throw DeskError.message("\(key) 应为数字。") }
    return min(range.upperBound, max(range.lowerBound, v))
  }
  /// A point given as [x, y], both 0–1; nil when it is not given.
  private static func spot(_ raw: Any?, _ key: String) throws -> LeakPoint? {
    guard let raw else { return nil }
    guard let p = raw as? [Any], p.count == 2, let x = (p[0] as? NSNumber)?.doubleValue, let y = (p[1] as? NSNumber)?.doubleValue,
      (0...1).contains(x), (0...1).contains(y)
    else { throw DeskError.message("\(key) 是 [x, y]，都在 0 到 1 之间。") }
    return LeakPoint(x: x, y: y)
  }
  private static func choice(_ arguments: [String: Any], _ key: String, _ choices: [String]) throws -> String? {
    guard let raw = arguments[key] else { return nil }
    guard let s = raw as? String, choices.contains(s) else { throw DeskError.message("\(key) 只能是 \(choices.joined(separator: "、"))。") }
    return s
  }
  private static func label(_ arguments: [String: Any]) throws -> String? {
    guard let raw = arguments["name"] else { return nil }
    guard let s = raw as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { throw DeskError.message("name 应为文字。") }
    return String(s.prefix(80))
  }
  private static let imageKinds = ["tif", "tiff", "png", "jpg", "jpeg", "webp"]
  /// The file named to be read: there, not a folder, and of one of `kinds`.
  private static func file(_ arguments: [String: Any], _ kinds: [String], _ what: String) throws -> URL {
    guard let raw = arguments["path"] as? String, !raw.isEmpty else { throw DeskError.message("需要 path：\(what)的完整路径。") }
    let full = (raw as NSString).expandingTildeInPath
    guard full.hasPrefix("/") else { throw DeskError.message("path 要是完整路径，以 / 或 ~ 开头。") }
    var folder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: full, isDirectory: &folder), !folder.boolValue else { throw DeskError.message("找不到文件：\(full)") }
    let url = URL(fileURLWithPath: full).standardizedFileURL
    guard kinds.contains(url.pathExtension.lowercased()) else { throw DeskError.message("\(what)要是 \(kinds.joined(separator: "、")) 文件。") }
    return url
  }
  /// A leak region or a protection as the assistant reads it.
  private static func describe(_ r: LeakRegion, protection: Bool) -> [String: Any] {
    var item: [String: Any] = ["id": r.id, "shape": r.shape, "enabled": r.enabled != false]
    if let name = r.name { item["name"] = name }
    if let x = r.x, let y = r.y { item["center"] = [short(x), short(y)] }
    if let rx = r.rx, let ry = r.ry { item["radii"] = [short(rx), short(ry)] }
    if let points = r.points { item["points"] = points.count }
    if r.shape == "stroke" { item["radius"] = short(r.radius ?? 0.025) }
    if r.detected == true { item["detected"] = true }
    if let c = r.confidence { item["confidence"] = c }
    guard !protection else { return item }
    item["mode"] = r.mode ?? "chroma"
    item["amount"] = short(r.amount ?? 1)
    item["feather"] = short(r.feather ?? 0.7)
    if let ref = r.ref { item["clean_point"] = [short(ref.x), short(ref.y)] }
    // A region acts only once it has a clean colour to go to: a point, or one measured when detected.
    item["has_clean_colour"] = r.ref != nil || r.target != nil || r.fog != nil
    return item
  }

  static func runLeak(_ name: String, _ arguments: [String: Any], _ model: AppModel) throws -> [[String: Any]] {
    let lab = lab(model)
    func say(_ text: String) -> [[String: Any]] { [["type": "text", "text": text]] }
    switch name {
    case "leak_get_state":
      return text(onMain { () -> [String: Any] in
        var state: [String: Any] = ["page": model.page.rawValue, "api_key_configured": lab.credentials.configured]
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
      // Nothing is applied when part of it cannot be.
      if strength != nil, !onMain({ lab.model != nil || (scene != nil && lab.hasReference) }) {
        throw DeskError.message("还没有应用去漏光，没有强度可调。先 leak_start。")
      }
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
      try only(arguments, ["quality", "note"])
      let quality = try choice(arguments, "quality", ["high", "medium"])
      if arguments["note"] != nil, !(arguments["note"] is String) { throw DeskError.message("note 应为文字。") }
      let note = (arguments["note"] as? String).map { String($0.prefix(2000)) }
      let configured = onMain { () -> Bool in
        model.page = .leak
        if lab.credentials.configured {
          lab.requestedQuality = quality
          lab.requestedNote = note
          lab.showGenerate = true
        } else {
          lab.showAPI = true
        }
        return lab.credentials.configured
      }
      return say(configured
        ? "已在 App 里打开「生成参考图并去漏光」的确认窗口" + (quality != nil || note != nil ? "，并预填了质量和附加要求" : "") + "。是否上传缩图并计费由用户决定；生成完成后可用 leak_get_state 查看。"
        : "还没有设置 OpenAI API Key：已在 App 里打开 API 管理，请用户自己填写（不要在对话里索取 Key）。")
    case "leak_import":
      try only(arguments, ["path"])
      let url = try file(arguments, imageKinds, "正片")
      try idle(lab)
      let before = onMain { lab.job?.id }
      onMain {
        model.page = .leak
        lab.importFile(url)
      }
      try settle(lab)
      guard onMain({ lab.hasBase && lab.job.map { $0.id != before && $0.sourceName == url.lastPathComponent } == true }) else {
        throw DeskError.message("没有导入：" + onMain { lab.notice })
      }
      return say(onMain { "已导入「\(url.lastPathComponent)」为新任务 \(lab.job?.id ?? "")，原文件没有改动。还没有参考图。" })
    case "leak_import_reference":
      try requireBase(lab)
      try only(arguments, ["path"])
      let url = try file(arguments, imageKinds, "参考图")
      try idle(lab)
      onMain { lab.importReference(url) }
      try settle(lab)
      guard onMain({ lab.hasReference && lab.job?.guideName == url.lastPathComponent }) else {
        throw DeskError.message("没有导入参考图：" + onMain { lab.notice })
      }
      return say("参考图「\(url.lastPathComponent)」已导入，没有调用 API。用 leak_preview（kind 为 reference）确认构图一致后，leak_start 在本地拟合。")
    case "leak_list_regions":
      try requireBase(lab)
      return text(onMain { () -> [String: Any] in
        [
          "regions": lab.params.regions.map { describe($0, protection: false) },
          "protections": lab.params.protect.map { describe($0, protection: true) },
          "landmark_pairs": lab.pairs.map { ["original": $0.source.map { short($0) }, "reference": $0.target.map { short($0) }] },
        ]
      })
    case "leak_add_region":
      try requireBase(lab)
      try only(arguments, ["x", "y", "rx", "ry", "clean_point", "mode", "amount", "feather", "name"])
      guard let x = try double(arguments, "x", 0...1), let y = try double(arguments, "y", 0...1),
        let rx = try double(arguments, "rx", 0.005...0.5), let ry = try double(arguments, "ry", 0.005...0.5)
      else { throw DeskError.message("需要椭圆的中心 x、y 和半径 rx、ry。") }
      guard let clean = try spot(arguments["clean_point"], "clean_point") else {
        throw DeskError.message("需要 clean_point：同材质、没有漏光的干净位置 [x, y]，区域按它的颜色校正。")
      }
      let mode = try choice(arguments, "mode", ["chroma", "fog"]) ?? "chroma"
      let amount = try double(arguments, "amount", 0...1) ?? 0.8, feather = try double(arguments, "feather", 0...1) ?? 0.8
      let given = try label(arguments)
      try idle(lab)
      let id = UUID().uuidString.lowercased()
      onMain {
        let r = LeakRegion(
          id: id, name: given ?? "AI 区域 \(lab.params.regions.count + 1)", shape: "ellipse", mode: mode, x: x, y: y, rx: rx, ry: ry,
          amount: amount, feather: feather, ref: clean, enabled: true)
        lab.change("AI 新建漏光区域") { $0.regions.append(r) }
      }
      try settle(lab)
      guard onMain({ lab.params.regions.contains { $0.id == id } }) else { throw DeskError.message("没有新建区域：" + onMain { lab.notice }) }
      onMain { lab.selectedRegion = id }
      return say("已新建漏光区域 \(id)，按 (\(short(clean.x)), \(short(clean.y))) 的颜色校正。可用 ⌘Z 或 undo 撤销。")
    case "leak_update_region":
      try requireBase(lab)
      try only(arguments, ["id", "enabled", "x", "y", "rx", "ry", "clean_point", "mode", "amount", "feather", "name"])
      guard let id = arguments["id"] as? String else { throw DeskError.message("需要 id：leak_list_regions 里的编号。") }
      let found = onMain { () -> (LeakRegion, Bool)? in
        if let r = lab.params.regions.first(where: { $0.id == id }) { return (r, false) }
        return lab.params.protect.first { $0.id == id }.map { ($0, true) }
      }
      guard let (region, protection) = found else { throw DeskError.message("没有编号为 \(id) 的区域或保护区。可用 leak_list_regions 查看。") }
      let changes = Set(arguments.keys).subtracting(["id"])
      guard !changes.isEmpty else { throw DeskError.message("没有要改的参数。") }
      if protection, !changes.isSubset(of: ["enabled", "name"]) { throw DeskError.message("保护区只能改 enabled 和 name；要换地方，删除后重画。") }
      if region.shape != "ellipse", !changes.isDisjoint(with: ["x", "y", "rx", "ry"]) { throw DeskError.message("只有椭圆区域能改中心和半径。") }
      if arguments["enabled"] != nil, !(arguments["enabled"] is Bool) { throw DeskError.message("enabled 应为 true 或 false。") }
      let enabled = arguments["enabled"] as? Bool
      let x = try double(arguments, "x", 0...1), y = try double(arguments, "y", 0...1)
      let rx = try double(arguments, "rx", 0.005...0.5), ry = try double(arguments, "ry", 0.005...0.5)
      let amount = try double(arguments, "amount", 0...1), feather = try double(arguments, "feather", 0...1)
      let clean = try spot(arguments["clean_point"], "clean_point"), mode = try choice(arguments, "mode", ["chroma", "fog"])
      let given = try label(arguments)
      try idle(lab)
      onMain {
        lab.editRegion(id, "AI 调整区域", joins: false) { r in
          // A suggestion turned on counts as approved, so the next fit keeps it.
          if let enabled {
            r.enabled = enabled
            r.approved = enabled
          }
          if let x { r.x = x }
          if let y { r.y = y }
          if let rx { r.rx = rx }
          if let ry { r.ry = ry }
          if let amount { r.amount = amount }
          if let feather { r.feather = feather }
          if let mode { r.mode = mode }
          if let given { r.name = given }
          // A new clean point: what was measured from the old one, or when detected, goes.
          if let clean {
            r.ref = clean
            r.target = nil
            r.fog = nil
            r.ratios = nil
            r.channelRy = nil
            r.gaussian = false
            r.detected = false
          }
        }
      }
      try settle(lab)
      return say("已调整\(protection ? "保护区" : "区域") \(id)：\(changes.sorted().joined(separator: ", "))。可用 ⌘Z 或 undo 撤销。")
    case "leak_delete_region":
      try requireBase(lab)
      try only(arguments, ["id"])
      guard let id = arguments["id"] as? String else { throw DeskError.message("需要 id：leak_list_regions 里的编号。") }
      func present() -> Bool { onMain { (lab.params.regions + lab.params.protect).contains { $0.id == id } } }
      guard present() else { throw DeskError.message("没有编号为 \(id) 的区域或保护区。可用 leak_list_regions 查看。") }
      try idle(lab)
      onMain { lab.deleteRegion(id) }
      try settle(lab)
      guard !present() else { throw DeskError.message("没有删除：" + onMain { lab.notice }) }
      return say("已删除 \(id)。可用 ⌘Z 或 undo 撤销。")
    case "leak_add_protection":
      try requireBase(lab)
      try only(arguments, ["points", "radius"])
      guard let list = arguments["points"] as? [Any], (1...2000).contains(list.count) else { throw DeskError.message("需要 1 到 2000 个点：[[x, y], …]。") }
      let points = try list.map { p -> [Double] in
        guard let s = try spot(p, "points 里的每个点") else { throw DeskError.message("points 里的每个点是 [x, y]。") }
        return [s.x, s.y]
      }
      let radius = try double(arguments, "radius", 0.005...0.08)
      try idle(lab)
      guard let id = onMain({ lab.addProtection(points, radius: radius) }) else { throw DeskError.message("没有画上保护区：" + onMain { lab.notice }) }
      try settle(lab)
      return say("已画保护区 \(id)（\(points.count) 个点），下面的原片不被校正。可用 ⌘Z 或 undo 撤销。")
    case "leak_set_landmarks":
      try requireBase(lab)
      try only(arguments, ["pairs"])
      guard let list = arguments["pairs"] as? [Any], list.count <= 20 else {
        throw DeskError.message("pairs 是最多 20 对的列表：[{original: [x, y], reference: [x, y]}, …]。")
      }
      let pairs = try list.map { item -> LeakPair in
        guard let d = item as? [String: Any], Set(d.keys) == ["original", "reference"],
          let s = try spot(d["original"], "original"), let t = try spot(d["reference"], "reference")
        else { throw DeskError.message("每对是 {original: [x, y], reference: [x, y]}。") }
        return LeakPair(source: [s.x, s.y], target: [t.x, t.y])
      }
      guard pairs.isEmpty || pairs.count >= 4 else { throw DeskError.message("至少要 4 对对应点；给空列表则清空，按相同构图对齐。") }
      guard pairs.isEmpty || onMain({ lab.hasReference }) else { throw DeskError.message("还没有参考图，没有可对应的点。") }
      try idle(lab)
      onMain { lab.setPairs(pairs) }
      guard onMain({ lab.pairs == pairs }) else { throw DeskError.message("没有设上对应点：" + onMain { lab.notice }) }
      return say((pairs.isEmpty ? "已清空对应点，按相同构图对齐。" : "已设 \(pairs.count) 对对应点。")
        + "用 leak_start 在本地重新拟合，不调用 API。这一步不进撤销。")
    case "leak_rotate":
      try requireBase(lab)
      try only(arguments, ["quarter_turns"])
      guard let turns = (arguments["quarter_turns"] as? NSNumber)?.intValue, [-1, 1, 2].contains(turns) else {
        throw DeskError.message("quarter_turns 只能是 1、-1 或 2。")
      }
      try idle(lab)
      let before = onMain { lab.params.rotation }
      onMain { lab.rotate(by: 90 * turns) }
      try settle(lab)
      let now = onMain { lab.params.rotation }
      guard now == ((before + 90 * turns) % 360 + 360) % 360 else { throw DeskError.message("没有旋转：" + onMain { lab.notice }) }
      return say("原片已转到 \(now)°，裁切、区域、保护区和对应点已清空。" + onMain { lab.notice } + " 可用 ⌘Z 或 undo 撤销。")
    case "leak_crop":
      try requireBase(lab)
      try only(arguments, ["x", "y", "w", "h"])
      guard let x = try double(arguments, "x", 0...0.9), let y = try double(arguments, "y", 0...0.9),
        let w = try double(arguments, "w", 0.05...1), let h = try double(arguments, "h", 0.05...1)
      else { throw DeskError.message("需要 x、y、w、h（0–1，按转好方向的原片）。") }
      try idle(lab)
      let before = onMain { lab.params.crop }
      onMain { lab.setCrop(LeakCrop(x: x, y: y, w: w, h: h)) }
      try settle(lab)
      let now = onMain { lab.params.crop }
      guard now != before else { return say("裁切和现在一样，没有改。") }
      return say(String(format: "已裁切为左 %.3f、上 %.3f、宽 %.3f、高 %.3f，区域、保护区和对应点已清空。", now.x, now.y, now.w, now.h)
        + onMain { lab.notice } + " 可用 ⌘Z 或 undo 撤销。")
    case "leak_clear_correction":
      try requireBase(lab)
      try only(arguments, [])
      guard onMain({ lab.model != nil }) else { throw DeskError.message("现在没有参考校正可停用。") }
      try idle(lab)
      onMain { lab.clearReferenceCorrection() }
      try settle(lab)
      return say("参考校正已停用，参考图还在；leak_start 可免费重新应用。可用 ⌘Z 或 undo 撤销。")
    case "leak_load_preset":
      try requireBase(lab)
      try only(arguments, ["path"])
      let url = try file(arguments, ["json"], "预设")
      try idle(lab)
      onMain { lab.loadPreset(from: url) }
      try settle(lab)
      return say(onMain { lab.notice })
    case "leak_save_preset", "leak_export":
      try requireBase(lab)
      try only(arguments, [])
      let export = name == "leak_export"
      if export, !onMain({ lab.repaired && lab.after != nil }) { throw DeskError.message("还没有应用去漏光，没有可导出的结果。先 leak_start。") }
      try idle(lab)
      // The panel waits for the user; the tool does not.
      DispatchQueue.main.async {
        model.page = .leak
        if export { lab.chooseExport() } else { lab.chooseSavePreset() }
      }
      return say(export
        ? "已在 App 里打开导出窗口（全分辨率 16 位 Adobe RGB TIFF，附 sRGB JPEG 和参数记录），由用户选位置；本工具没有写文件。导出完成后 leak_get_state 的 notice 会说明。"
        : "已在 App 里打开保存预设的窗口，由用户选位置和名称；本工具没有写文件。")
    default:
      throw DeskError.message("没有名为 \(name) 的工具。")
    }
  }
}
