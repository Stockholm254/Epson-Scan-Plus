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
    Tool(name: "get_state", description: "读取当前工程和选中画面的转换状态：胶片预设与各通道斜率、片基 RGB 及来源、全卷斜率估计（roll_estimate_slopes，开关在 roll.slope_estimate）、白平衡、色阶、影调、扫描与对齐信息，以及负片密度和正片各通道的百分位与溢出比例；sdr_range 给出进入两端之前（自动色阶定出的黑为 0、白为 1）白点以上的比例、最亮 0.1% 的位置和高出白点几档、屏幕上从哪里起是纯白或纯黑，以及屏幕上纯白、纯黑的比例。还有：frame.light_leak 是这张的去漏光（applied：修复在转换里，③ 在修好的照片上调色；job_not_applied：去漏光页有任务、修复还没用到 ③）；画面的裁切、拉直、来源文件、是否从传感器读出和去串色、手动取过哪些点；预设的类型和说明（适用条件写在里面），这一卷关了「用标定」时 preset 是转换实际用的胶片，roll_preset 是这一卷选的标定预设；frame.flat_field 是这张除的平场（来自哪张空白帧、名字、最暗处的比例）；slopes_in_use 是转换实际用的斜率和它来自哪里（标定预设、全卷斜率估计或预设）；analysis 是自动分析实际定出的片基、白平衡、色阶两端（对数曝光）和高光伸到多远；tone 里的高光、阴影、去色噪；curves 是现有的色调曲线（有改动的通道和它们的控制点，空表示没有曲线）；roll 是整卷同一白平衡 / 色阶、去串色和标定点数。调整前先调用。", properties: [:]),
    Tool(name: "list_frames", description: "列出本卷所有画面：编号、是否勾选、是否显示（selected）、是否和它一起选中（chosen）、是否已正式扫描及 dpi、方向、镜像、拉直、裁切、来源文件，和手动取过的片基、中性灰；stars、flag（picked / rejected）、label（red…purple）是 Lightroom 式的标记，没有就不列；light_leak 是去漏光的状态（applied / job_not_applied，没有就不列）。", properties: [:]),
    Tool(name: "list_presets", description: "列出所有胶片预设：名称、类型（内置 / V850 标定 / 翻拍标定 / 导入 / 只在卷里）、通道斜率、来源和说明，这一卷是否在用，图库里有几卷在用及是哪几卷，能否删除。「只在卷里」是已从列表删除、只有卷里还留着的预设。只读，删除和恢复在 App 的「预设…」表格里做。", properties: [:]),
    Tool(name: "list_rolls", description: "列出图库里的卷（只读）：标题、文件夹、开始时间、来源（扫描 / 翻拍 / 导入）、胶片、用的预设、画面数、全分辨率张数、已导出的文件数、备注，以及哪一卷是打开的。", properties: [:]),
    Tool(name: "select_frame", description: "选中某张画面（按编号，如 \"09\"）。", properties: ["name": ["type": "string", "description": "画面编号"]], required: ["name"]),
    Tool(name: "set_marks", description: "给画面打星级、旗标和颜色标签，像 Lightroom（App 里的 0–5、P、X、6–9）：stars 0–5（0 去掉），flag 为 picked（留用）、rejected（不要）或 none，label 为 red、yellow、green、blue、purple 或 none；没给的那一项不动。frames 是画面编号；省略时作用于 App 里选中的几张（只选了一张就是那一张）。存在工程里，可用 undo 撤销。list_frames 读得到每张的标记。", properties: [
      "frames": ["type": "array", "items": ["type": "string"], "description": "画面编号，如 [\"01\", \"04\"]；省略时为所选的"],
      "stars": ["type": "integer", "minimum": 0, "maximum": 5],
      "flag": ["type": "string", "enum": ["picked", "rejected", "none"]],
      "label": ["type": "string", "enum": ["red", "yellow", "green", "blue", "purple", "none"]],
    ]),
    Tool(name: "select_by_marks", description: "按标记一起选中几张，像 Lightroom 的「按旗标 / 星级 / 颜色标签选择」（App 里「画面 › 选择画面」）：by 为 picked（留用的）、unflagged（没有旗标的）、rejected（不要的）、stars（stars 星及以上的）、label（某个颜色标签的）、all（全部）或 only_shown（只留显示的这张）。显示的那张在其中时不换，否则换到第一张；之后 apply_grading_preset、set_marks 等作用于所选的每一张。一张都没有时选中的不变。返回选中了哪几张。", properties: [
      "by": ["type": "string", "enum": ["picked", "unflagged", "rejected", "stars", "label", "all", "only_shown"]],
      "stars": ["type": "integer", "minimum": 1, "maximum": 5, "description": "by 为 stars 时，几星及以上"],
      "label": ["type": "string", "enum": ["red", "yellow", "green", "blue", "purple"], "description": "by 为 label 时"],
    ], required: ["by"]),
    Tool(name: "preview", description: "取得选中画面的 JPEG：positive 为当前设置转换出的正片，negative 为未反相的负片（线性数据，看起来很暗）。", properties: [
      "kind": ["type": "string", "enum": ["positive", "negative"], "description": "默认 positive"],
      "max_size": ["type": "integer", "minimum": 256, "maximum": 1600, "description": "长边像素，默认 768"],
    ]),
    Tool(name: "sample", description: "在选中画面上取点：每点返回负片的线性 RGB、各通道高于片基的密度（D），和转换后正片的 sRGB 值。用来判断哪里是中性灰、片基是否准确。", properties: [
      "points": ["type": "array", "maxItems": 20, "description": "[[x, y], …]，坐标同 pick_neutral",
        "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2]],
    ], required: ["points"]),
    Tool(name: "adjust", description: "调整一张画面的转换参数，只改给出的项；给出 frame 时调那一张（先选中它），不给时调选中的那张；回复里写着调的是哪一张。可用 ⌘Z 撤销。", properties: [
      "frame": ["type": "string", "description": "画面编号，如 \"09\"；省略时为选中的画面"],
      "warmth": number("冷暖，-1 到 1", -1...1), "tint": number("绿 / 洋红，-1 到 1", -1...1),
      "shadow_warmth": number("阴影冷暖：只动暗部，越亮作用越小，阳光下的灰不变；正数暖，-1 到 1", -1...1),
      "shadow_tint": number("阴影色调：和阴影冷暖动同样的暗部，负数绿、正数洋红；阴影蓝里带紫时往负拨，-1 到 1", -1...1),
      "exposure": number("曝光 EV", -2...2), "contrast": number("对比度", 0.5...1.6), "saturation": number("饱和度", 0...1.8),
      "highlights": number("高光（像 Lightroom）：亮的区域按周围的亮度整块压暗（负）或提亮（正），纹理保留，在剪切之前，往负能拉回白点以上的东西；0.45 以下不动，-1 到 1", -1...1),
      "shadows": number("阴影（像 Lightroom）：暗的区域按周围的亮度整块提亮（正）或压暗（负），纹理保留，黑不动，-1 到 1", -1...1),
      "whites": number("白色（像 Lightroom）：最亮的一端整体往下（负，拉回白点以上的）或往上（正，更多推到白），按像素自己最亮的通道，0.5 以下不动，颜色不变，-1 到 1", -1...1),
      "blacks": number("黑色（像 Lightroom）：最暗的一端整体压深（负）或提起（正，拉回黑以下的），按像素自己最暗的通道，0.5 以上不动，颜色不变，-1 到 1", -1...1),
      "angle": number("拉直角度（度）：画面绕中心转动，正数顺时针，裁去转出的空角，-45 到 45", -45...45),
      "auto_white_balance": ["type": "boolean", "description": "自动白平衡"], "auto_levels": ["type": "boolean", "description": "自动色阶"],
      "shared_balance": ["type": "boolean", "description": "整卷同一白平衡：整卷共用一个按所有画面统计的白平衡，每张颜色一致；作用于选中画面所在的整卷"],
      "shared_levels": ["type": "boolean", "description": "整卷同一色阶：整卷共用一组黑白两端，暗的场景就是暗的，每张只按曝光微调；作用于选中画面所在的整卷"],
      "texture": number("纹理（像 Lightroom）：最细的起伏加强（正）或柔化（负），颜色不变，-1 到 1", -1...1),
      "clarity": number("清晰度（像 Lightroom）：中等尺度的局部反差，主要在中间调，黑白不动，-1 到 1", -1...1),
      "dehaze": number("去朦胧（像 Lightroom）：去掉（正）或加上（负）一层白雾，-1 到 1", -1...1),
      "vibrance": number("自然饱和度（像 Lightroom）：只加不太鲜艳的颜色，肤色加得少，-1 到 1", -1...1),
      "auto_whites_blacks": ["type": "boolean", "description": "自动白色、黑色（像 Lightroom 按住 Shift 双击）：设白色、黑色，让这张最亮的 0.1% 正好到白、最暗的 0.1% 正好到黑；在其他参数之后算，要单张视图里算过的影调"],
    ]),
    Tool(name: "pick_film_base", description: "在指定位置取片基（只应点在未曝光的橙色片基上，例如画面边缘的片间）；会关闭自动白平衡以保留取样。", properties: point, required: ["x", "y"]),
    Tool(name: "auto_straighten", description: "自动拉直选中的这张，像 Lightroom 裁切里的「自动」：在画面里找地平线（在本机用 macOS 的视觉框架），按它放平，③ 的裁切留在画面上；找不到清楚的地平线时不改动，说明原因。用 select_by_marks 选了几张时，每张按自己的地平线。地平线本来就该是斜的照片（有意的倾斜构图）不要用。可用 undo 撤销。", properties: [:]),
    Tool(name: "auto_crop", description: "翻拍的照片自动裁切：按片框的四条边裁到画面以内，并按边拉直。默认只裁选中的这张；whole_roll 为 true 时整卷一起裁。和本卷其他张的画面大小对照，改正找错的边。可用 undo 撤销，原文件不改。", properties: [
      "whole_roll": ["type": "boolean", "description": "整卷一起裁，默认 false"],
    ]),
    Tool(name: "auto_film_base", description: "放弃手动片基，改用自动片基：扫描的卷用整卷片间测得的，翻拍和单张照片用片边的未曝光片基，都没有时按本张最薄处估计。", properties: [:]),
    Tool(name: "pick_neutral", description: "把指定位置作为中性灰，按它自动白平衡（灰卡、白墙、水泥等）。", properties: point, required: ["x", "y"]),
    Tool(name: "pick_shadow_neutral", description: "把阴影里的指定位置作为中性灰，设定阴影冷暖和阴影色调让它变灰（背光的水泥、路面、石头）；亮处和整体白平衡不变。这一点太暗或太亮时不改，并说明。", properties: point, required: ["x", "y"]),
    Tool(name: "set_curve", description: "设定一张画面（frame，省略时为选中的那张）的一条色调曲线，和 App 里「曲线」一节的一样：channel 是 rgb、red、green 或 blue（各通道曲线在 RGB 曲线之后生效）；points 是 [[x, y], …]，都在 0 到 1 之间，x 是转换后的输出值，y 是曲线给它的新值。两端 x=0 和 x=1 不给时按 (0, 0)、(1, 1) 补上，相邻两点的 x 至少相隔 0.01，最多 16 个点；中间按单调三次样条连起来，不会过冲。points 省略或为空时把这条曲线恢复成直线；channel 为 all 时清掉全部曲线（连同用户在 App 里调的参数曲线）。曲线在转换之后按通道查表，从黑到白所有影调都受影响：偏色先用白平衡、阴影冷暖和阴影色调，曲线用来做它们做不到的。get_state 的 curves 列出现有曲线。可用 undo 撤销。", properties: [
      "frame": ["type": "string", "description": "画面编号，如 \"09\"；省略时为选中的画面"],
      "channel": ["type": "string", "enum": ["rgb", "red", "green", "blue", "all"], "description": "哪条曲线；all 只用来清掉全部曲线"],
      "points": ["type": "array", "maxItems": 16, "items": ["type": "array", "minItems": 2, "maxItems": 2, "items": ["type": "number", "minimum": 0, "maximum": 1]],
        "description": "[[x, y], …]，0 到 1；省略或为空时恢复成直线"],
    ], required: ["channel"]),
    Tool(name: "pick_curve_point", description: "曲线取点，和 App 里「曲线」下面的取点工具（U）一样：读这一点在曲线之前的正片值（转换以后、曲线查表之前），坐标同 pick_neutral。mode 为 point（取曲线点）：在 channel 那条点曲线上它所在的地方加一个控制点（rgb 曲线上按它的亮度），点落在曲线上，照片不变，之后用 set_curve 移动。mode 为 neutral（取中性点）：点在本来应该是灰的地方，给 red、green、blue 三条曲线各加一个点，让这一点三个通道输出一样，目标是它在曲线之后的亮度（0.2126 R + 0.7152 G + 0.0722 B），明暗不变；两端不动，所以只在这个亮度附近去掉偏色，在别的亮度上再取就再加一组点（离已有的点不到 0.02 时移动那个点）。整张偏色用 pick_neutral，阴影里的灰用 pick_shadow_neutral；它们都对了、只剩某一段亮度偏色时才用 neutral。这一点离曲线的端点太近或那里已有控制点时不改，并说明。可用 undo 撤销。", properties: point.merging([
      "mode": ["type": "string", "enum": ["point", "neutral"], "description": "point 取曲线点，neutral 取中性点"],
      "channel": ["type": "string", "enum": ["rgb", "red", "green", "blue"], "description": "point 时加在哪条曲线上，默认 rgb；neutral 总是 red、green、blue 三条"],
    ]) { a, _ in a }, required: ["x", "y", "mode"]),
    Tool(name: "choose_preset", description: "选用胶片预设（按名称，部分匹配，如 \"Portra 160\"）。", properties: ["name": ["type": "string"]], required: ["name"]),
    Tool(name: "apply_to_roll", description: "把选中画面的调整同步到本卷所有画面（保留各张的方向和裁切）。", properties: [:]),
    Tool(name: "list_grading_presets", description: "列出用户的调色预设（App 里 ③ 调色顶上的「预设」）：名称、记着哪几项调色、什么时候存的。只读。", properties: [:]),
    Tool(name: "apply_grading_preset", description: "把一个调色预设套用到选中的画面（App 里多选了几张时套用到所选的每一张），只改预设里记着的那几项调色，② 去色罩的设置不动；name 按名称，部分匹配。可用 undo 撤销。", properties: [
      "name": ["type": "string", "description": "预设名称"],
    ], required: ["name"]),
    Tool(name: "take_snapshot", description: "把选中画面现在的调色存成快照（App 里 ③ 调色顶上的「快照」），跟着这一卷存；换个调法以后能用 restore_snapshot 回来。name 省略时用「快照」加时间；同名的替换。", properties: [
      "name": ["type": "string", "description": "快照名称，可省略"],
    ]),
    Tool(name: "restore_snapshot", description: "把选中画面的调色恢复成它的一个快照，只改调色，② 去色罩的设置不动；name 按名称，部分匹配。name 省略时只列出这张的快照。可用 undo 撤销。", properties: [
      "name": ["type": "string", "description": "快照名称"],
    ]),
    Tool(name: "reset_adjustments", description: "把选中画面的调整恢复默认（保留输入 Gamma、方向和全卷斜率估计）。", properties: [:]),
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
    Epson Scan plus 是彩色负片扫描与转换程序。转换的顺序：负片的线性读数除以片基（橙色色罩），换算成各通道高于片基的密度；按胶片预设或全卷斜率估计的各通道斜率把三层的反差拉齐；再做白平衡、色阶和影调。
    - 先用 get_state 和 preview 看当前结果，用 sample 在可能是中性灰的地方取点：中性灰在正片里 R、G、B 应接近，在负片里三个通道高于片基的密度之比应接近通道斜率之比。
    - 偏色先查片基（get_state 里的 film_base 和来源）；片基可疑时用 pick_film_base 点未曝光的片间，或 auto_film_base 回到自动。再用 pick_neutral 或 warmth / tint。晴天的阴影由蓝天照亮，本来就比阳光下蓝；阳光下的灰已经是灰、只有暗部偏蓝时，用 shadow_warmth，不要动整体的 warmth；暗部蓝里带紫（常见于远处雾气、只有蓝层曝了光的阴影）时配合 shadow_tint 往负（绿），阴影里有中性的东西时用 pick_shadow_neutral 一次定两个。色调曲线（set_curve）在转换之后按通道查表，从黑到白都受影响，只在上面这些做不到时用；用之前看 get_state 的 curves，有人调过的曲线（比如把一条通道整体抬高）常常就是整张偏色的原因，用 set_curve 不给 points 把它恢复成直线。白平衡和阴影都对了、只剩某一段亮度偏色（比如高光发黄）时，在那段亮度本来是灰的地方用 pick_curve_point（mode neutral），只动那个亮度附近。
    - 坐标是单张视图里画面的相对位置，0–1，左上为原点。
    - 翻拍的照片四周带着片基、漏光或片夹时，先用 auto_crop 裁到画面（whole_roll 整卷一起），再看和取样：自动白平衡和色阶只看裁切以内。
    - 地平线、水面拍斜了时可以用 auto_straighten 放平（找不到清楚的地平线时不改动）；有意倾斜的构图不要用。
    - 每次调整都能在 App 里用 ⌘Z 撤销，也可以调用 undo。转换的工具不会扫描、删除或导出文件。
    - 翻拍预设的斜率属于那台相机和那组灯，灯的配比变了也照样成立；它记下的中性却是标定那次的灯光。套用以后整体偏色、而白色或灰色的东西彼此一致时，在它们上面 pick_neutral 重新配平就好，不必重做标定。
    - 画面的方向和镜像这里改不了，要请用户在 App 里转。
    - 要看图库里别的卷，或某个预设有哪些卷在用、适用条件（说明里写着去串色要开还是关），用 list_rolls 和 list_presets，都只读。
    - 星级、旗标和颜色标签：list_frames 读，set_marks 设；select_by_marks 按标记一起选中几张，之后 apply_grading_preset、set_marks 作用于所选的每一张。
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
  /// How a frame is cut from its picture and turned, its file, and what was picked on it by hand.
  /// A frame's light-leak repair: used in its conversion (③ grades the repaired picture), or a
  /// 去漏光 job whose repair is not used yet.
  static func leakState(_ f: FilmFrame, job: LeakLab.FrameJob?) -> [String: Any]? {
    let iso = ISO8601DateFormatter()
    if let fix = f.adjustments.leakFix {
      var part: [String: Any] = ["state": "applied", "made": iso.string(from: fix.made)]
      if let e = fix.meanError { part["mean_difference_from_leak_page_of_255"] = (e * 10).rounded() / 10 }
      return part
    }
    guard let job else { return nil }
    return ["state": "job_not_applied", "job_modified": iso.string(from: job.modified)]
  }
  private static func geometry(_ f: FilmFrame) -> [String: Any] {
    let s = f.adjustments
    var g: [String: Any] = ["mirrored": s.flipHorizontal == true,
      "crop": ["x": round(f.rect.x), "y": round(f.rect.y), "width": round(f.rect.width), "height": round(f.rect.height)],
      "analysis_region": f.adjustments.analysisRegion.map { r -> Any in
        ["x": round(r.x), "y": round(r.y), "width": round(r.width), "height": round(r.height),
         "note": "in the crop, 0-1 from its top left, unturned; the base estimate, white balance, levels and highlight reach read only here"]
      } ?? "follows the crop: its outer 5% left out, and where the crop takes in the film's edge (rebate, sprocket holes, edge print) only the part inside it read",
      "picked": ["film_base": s.base != nil, "neutral": s.neutralSample != nil]]
    if let angle = s.angle { g["straighten_degrees"] = angle }
    // ③'s crop and straightening (裁切与拉直), within the crop above; colours do not follow it.
    if let o = s.composition {
      g["grade_crop"] = ["x": round(o.x), "y": round(o.y), "width": round(o.width), "height": round(o.height),
        "note": "③'s crop, 0-1 of the straightened picture before quarter turns and mirror; set by the user in ③ 裁切与拉直, it changes only what is shown and exported"]
    }
    if let path = f.sourcePath { g["file"] = URL(fileURLWithPath: path).lastPathComponent }
    return g
  }
  /// The selected frame and what converting it needs, read on the main thread.
  /// The colour labels by the names the tools use, in `FrameLabel`'s order.
  static let labelNames = ["red", "yellow", "green", "blue", "purple"]
  private static func selected(_ model: AppModel) throws -> (FilmFrame, FilmProfile) {
    try onMain {
      guard let frame = model.selected else { throw DeskError.message("没有选中的画面。先在 App 里预览或打开工程，或用 select_frame。") }
      return (frame, model.conversionProfile)
    }
  }
  /// The frame an edit goes to: `frame` given, that one by its name, selected first (and the
  /// edit not synced to others chosen: it was named alone); else the one selected. Its name, for
  /// the reply, so a caller sees which it changed (until 0.22.9 it had to select it first and
  /// trust that nothing in the App had moved the selection since).
  private static func target(_ model: AppModel, _ arguments: [String: Any]) throws -> (name: String, named: Bool) {
    try onMain {
      if let wanted = arguments["frame"] {
        guard let name = wanted as? String, !name.isEmpty else { throw DeskError.message("frame 是画面编号，如 \"09\"。") }
        guard let f = model.frames.first(where: { $0.name == name }) else {
          throw DeskError.message("没有编号为 \(name) 的画面。可用 list_frames 查看。")
        }
        if model.selectedID != f.id { model.select(f.id) }
        return (name, true)
      }
      guard let frame = model.selected else { throw DeskError.message("没有选中的画面。先在 App 里预览或打开工程，或用 select_frame，或给出 frame。") }
      return (frame.name, false)
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
    let (points, profile, names, measured, made) = onMain {
      (model.calibrationPoints, model.profile, model.calibrationPoints.map { p in model.frames.first { $0.id == p.frame }?.name ?? "?" },
        model.calibrationPoints.allSatisfy { p in model.frames.first { $0.id == p.frame }.map { ($0.adjustments.base ?? $0.adjustments.rollBase) != nil } ?? false },
        model.calibrationName)
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
      lines.append("可以 calibration_make_preset，会生成「\(made)」。")
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
  /// The negative's linear reading around a point of the frame as shown, 5 × 5 pixels, in floats:
  /// 8 bits keep only a few codes where a linear negative is dense (a sky's blue at 4–6 of 255,
  /// about 0.1 D apart), so densities, neutral picks and bases read there would come in steps.
  static func reading(_ samples: Samples, at p: CGPoint, settings: Adjustments) -> RGB {
    let raw = ImageGeometry.raw(p, settings: settings, aspect: Double(samples.width) / Double(max(1, samples.height)))
    let x = Int(raw.x * Double(samples.width - 1)), y = Int(raw.y * Double(samples.height - 1))
    var sum = [0.0, 0.0, 0.0], n = 0.0
    for dy in -2...2 { for dx in -2...2 {
      let v = samples.pixel(x + dx, y + dy).values
      for c in 0..<3 { sum[c] += v[c] }
      n += 1
    } }
    return RGB(sum.map { $0 / n })
  }
  /// The curves that bend the picture, channel by channel, as control points: none, an empty table.
  private static func curvesState(_ curves: ToneCurves?) -> [String: Any] {
    guard let curves else { return [:] }
    var out: [String: Any] = [:]
    for (i, name) in ["rgb", "red", "green", "blue"].enumerated() where !curves[i].isIdentity {
      out[name] = curves[i].points.map { [($0.x * 10000).rounded() / 10000, ($0.y * 10000).rounded() / 10000] }
    }
    // Lightroom's parametric curve, set by hand in the App: before the RGB curve.
    if let p = curves.parametric, !p.isIdentity {
      func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
      out["parametric"] = ["shadows": r(p.shadows), "darks": r(p.darks), "lights": r(p.lights), "highlights": r(p.highlights), "splits": p.splits.map(r),
        "note": "参数曲线（阴影、暗部、亮部、高光，-1 到 1，按 splits 分段），在 RGB 曲线之前生效；只能在 App 里调，set_curve 的 all 会一起清掉"]
    }
    return out
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
        var project: [String: Any] = ["film": model.filmName, "format": model.format.rawValue, "film_edges": model.filmEdges.rawValue, "frames": model.frames.count, "preview_dpi": model.overviewDPI]
        if let folder = model.sessionURL { project["folder"] = folder.lastPathComponent }
        return ["project": project, "view": model.singleView ? "single" : "contact"]
      }
      let s = frame.adjustments
      let source = try model.source(for: frame, maxDimension: 600)
      let analysis = pipe.analyze(source, settings: s, profile: profile)
      // The densities below are read where the statistics read (`ImagePipeline.analysisPart`).
      let part = pipe.analysisPart(source, s)
      let negative = pipe.samples(part.image, maxDimension: 300)
      // Its outer 5% left out where the statistics leave it out.
      let (rows, columns) = part.margin > 0
        ? (negative.height / 20..<negative.height * 19 / 20, negative.width / 20..<negative.width * 19 / 20)
        : (0..<negative.height, 0..<negative.width)
      let shown = try pipe.preview(source, settings: s, profile: profile)
      let positive = pipe.raster(shown, maxDimension: 300)
      var densities = [[Double]](repeating: [], count: 3), outputs = [[Double]](repeating: [], count: 3)
      var dark = 0.0, bright = 0.0, count = 0.0
      for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 2) {
        for x in stride(from: columns.lowerBound, to: columns.upperBound, by: 2) {
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
      framePart.merge(geometry(frame)) { a, _ in a }
      if s.analysisRegion == nil, let r = analysis.followed {
        framePart["analysis_region"] = ["x": round(r.x), "y": round(r.y), "width": round(r.width), "height": round(r.height),
          "note": "follows the crop, which takes in the film's edge (rebate, sprocket holes, edge print): read only inside it, here; in the crop, 0-1 from its top left, unturned"]
      }
      if frame.sensorRead == true { framePart["read_from_sensor"] = true; framePart["crosstalk_removed"] = frame.crosstalk != nil }
      // How the light falling off across the picture (the lens's vignetting, the light's unevenness) is taken out.
      let flatPart: [String: Any]? = onMain {
        guard let flat = frame.flatField else { return nil }
        var part: [String: Any] = ["darkest_share": rgb(flat.falloff), "variant": frame.crosstalk != nil ? "crosstalk removed" : "as the sensor read it"]
        if let p = model.flatProfile(of: frame) {
          part["from"] = "blank frame flat"
          part["id"] = p.id
          part["name"] = p.name
          part["source"] = p.source
          if let f = p.aperture { part["aperture"] = f }
        } else {
          part["from"] = "the copy light's calibration"
        }
        return part
      }
      if let flatPart { framePart["flat_field"] = flatPart }
      if let leak = onMain({ Self.leakState(frame, job: model.leakJobs[frame.id]) }) { framePart["light_leak"] = leak }
      var preset: [String: Any] = ["name": profile.name, "id": profile.id, "source": profile.publication, "channel_slopes": rgb(profile.slopes),
        "kind": PresetTable.kind(profile, builtin: FilmProfile.builtins.contains { $0.id == profile.id }).rawValue, "notes": profile.notes]
      if let toe = profile.toe { preset["toe"] = rgb(toe) }
      if let offsets = profile.offsets { preset["calibrated_neutral_offsets"] = rgb(offsets) }
      // The roll's calibrated preset switched off: it converts as the film above.
      let chosen: FilmProfile? = onMain { model.conversionProfile.id == model.profile.id ? nil : model.profile }
      if let chosen {
        preset["roll_preset"] = ["name": chosen.name, "id": chosen.id, "channel_slopes": rgb(chosen.slopes),
          "calibration_in_use": false,
          "note": "这一卷选的是这个标定预设，但在 App 里关了「用标定」，所以按上面这种胶片转换。要用标定，请用户在胶片一节打开「用翻拍标定」或「用本机标定」。"]
      }
      let fromEdges: String? = onMain {
        guard let i = model.frames.firstIndex(where: { $0.id == frame.id }), let from = model.edgeBaseSource(i) else { return nil }
        return from == i ? "the unexposed film at this frame's edges" : "the unexposed film at the edges of frame \(model.frames[from].name)"
      }
      var base: [String: Any] = ["rgb": rgb(analysis.base),
        "source": s.base != nil ? "manual pick" : s.rollBasePicked == true ? "picked once and shared with the roll"
          : fromEdges ?? (s.rollBase != nil ? "measured between frames of the roll" : "estimated from the thinnest part of this frame")]
      var state = summary
      state["frame"] = framePart
      state["preset"] = preset
      state["film_base"] = base
      if let slopes = s.rollSlopes { state["roll_estimate_slopes"] = rgb(slopes) }
      let used = ImagePipeline.slopes(s, profile), estimating = onMain { model.estimatesSlopes }
      state["slopes_in_use"] = ["rgb": rgb(used.slopes),
        "from": profile.offsets != nil ? "calibrated preset" : s.rollSlopes != nil ? "roll estimate"
          : estimating ? "preset (no roll estimate: it needs two frames or more with enough edges between light and dark)"
          : "preset (全卷斜率估计 is switched off for this roll)"]
      var auto: [String: Any] = ["film_base": rgb(analysis.base), "balance": rgb(analysis.balance), "channel_gain": rgb(analysis.gain),
        "levels_black_log_exposure": round(analysis.low), "levels_white_log_exposure": round(analysis.high)]
      if let reach = analysis.reach { auto["highlights_reach_log_exposure"] = round(reach) }
      state["analysis"] = auto
      state["roll"] = onMain { () -> [String: Any] in
        var roll: [String: Any] = ["shared_balance": s.sharedBalance == true, "shared_levels": s.sharedLevels == true,
          "calibration_points": model.calibrationPoints.count]
        if let source = model.rollSource { roll["source"] = source.rawValue }
        if model.hasSensorPictures { roll["crosstalk_removed"] = model.crosstalkRemoved }
        roll["slope_estimate"] = model.estimatesSlopes
        return roll
      }
      // 原片 / 自动 / 自定义, as the white balance menu shows it.
      var balance: [String: Any] = ["mode": model.balanceMode.rawValue, "auto": s.autoWhiteBalance, "warmth": s.warmth, "tint": s.tint, "shadow_warmth": s.shadowWarmthAmount, "shadow_tint": s.shadowTintAmount]
      if let neutral = s.neutralSample { balance["neutral_sample"] = rgb(neutral) }
      state["white_balance"] = balance
      state["levels"] = ["auto": s.autoLevels]
      state["curves"] = curvesState(s.curves)
      state["tone"] = ["exposure": s.exposure, "contrast": s.contrast, "saturation": s.saturation, "curves": s.curves != nil,
        "highlights": s.highlightsAmount, "shadows": s.shadowsAmount, "whites": s.whitesAmount, "blacks": s.blacksAmount,
        "texture": s.textureAmount, "clarity": s.clarityAmount, "dehaze": s.dehazeAmount, "vibrance": s.vibranceAmount,
        "colour_mixer": s.mixer.map { m in Dictionary(uniqueKeysWithValues: ColourMixer.bands.indices.map { b in (ColourMixer.bands[b].name, ["hue": m.values[b * 3], "saturation": m.values[b * 3 + 1], "luminance": m.values[b * 3 + 2]]) }) } ?? [:],
        "colour_grading": s.grading.map { g in ["shadows": [g.shadowHue, g.shadowAmount], "midtones": [g.midHue, g.midAmount], "highlights": [g.highHue, g.highAmount], "balance": [g.balance], "blending": [g.blending]] } ?? [:], "colour_noise": s.colourNoiseAmount, "soft_ends": s.softEndsOn]
      state["input"] = ["negative": s.inputIsNegative, "reversal": s.isSlide, "gamma": s.inputGamma]
      state["negative_density_above_base"] = ["r": percentiles(densities[0]), "g": percentiles(densities[1]), "b": percentiles(densities[2])]
      state["positive_srgb"] = ["r": percentiles(outputs[0]), "g": percentiles(outputs[1]), "b": percentiles(outputs[2]),
        "clipped_black_percent": round(dark / max(1, count) * 100, 10), "clipped_white_percent": round(bright / max(1, count) * 100, 10)]
      if var range = pipe.toneRange(source, settings: s, profile: profile, analysis: analysis) {
        (range.atWhite, range.atBlack) = pipe.screenShares(shown)
        // On the print's straight line before its ends: the levels' black at 0, white at 1.
        var sdr: [String: Any] = ["past_white_percent": round(range.pastWhite * 100, 100),
          "white_on_screen_percent": round(range.atWhite * 100, 100), "black_on_screen_percent": round(range.atBlack * 100, 100),
          "brightest_0_1_percent": round(range.brightest)]
        if let white = range.white { sdr["screen_white_from"] = round(white) }
        if let black = range.black { sdr["screen_black_up_to"] = round(black) }
        if let stop = range.stop { sdr["brightest_stops_past_white"] = round((range.brightest - 1) / stop, 100) }
        state["sdr_range"] = sdr
      }
      return text(state)
    case "list_frames":
      return text(onMain {
        model.frames.map { f -> [String: Any] in
          var item: [String: Any] = ["name": f.name, "ticked": f.enabled, "selected": f.id == model.selectedID,
            "scanned": AppModel.readsScan(f), "rotation_quarter_turns": f.adjustments.rotation]
          if let dpi = f.scanDPI, AppModel.readsScan(f) { item["scan_dpi"] = dpi }
          item.merge(geometry(f)) { a, _ in a }
          if let leak = Self.leakState(f, job: model.leakJobs[f.id]) { item["light_leak"] = leak["state"] }
          if model.alsoSelected.contains(f.id) { item["chosen"] = true }
          if let stars = f.rating { item["stars"] = stars }
          if let flag = f.flag { item["flag"] = flag > 0 ? "picked" : "rejected" }
          if let label = f.label, label >= 0, label < Self.labelNames.count { item["label"] = Self.labelNames[label] }
          return item
        }
      })
    case "list_presets":
      let rolls = RollLibrary.scan(onMain { model.libraryRoots })
      return text(onMain {
        model.presetRows(rolls).map { r -> [String: Any] in
          let p = r.profile
          return ["name": p.name, "id": p.id, "kind": r.kind.rawValue, "source": p.publication, "notes": p.notes,
            "channel_slopes": rgb(p.slopes), "calibrated_here": p.offsets != nil, "in_use": r.current, "deletable": r.deletable,
            "rolls_using": r.rolls.count, "rolls": r.rolls.prefix(12).map { "\($0.title) · \($0.folder.lastPathComponent)" }]
        }
      })
    case "list_rolls":
      let (roots, open) = onMain { (model.libraryRoots, model.sessionURL) }
      let started = ISO8601DateFormatter()
      return text(RollLibrary.scan(roots).map { r -> [String: Any] in
        ["title": r.title, "folder": r.folder.lastPathComponent, "started": started.string(from: r.date), "source": r.source.rawValue,
         "film": r.film, "preset": r.profile.name, "preset_id": r.profile.id, "frames": r.frames.count,
         "full_resolution": r.fullResolution, "exported": r.exported, "notes": r.notes,
         "open": open.map { $0.resolvingSymlinksInPath().standardizedFileURL.path == r.folder.resolvingSymlinksInPath().standardizedFileURL.path } ?? false]
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
    case "set_marks":
      let names = arguments["frames"] as? [String]
      let stars = (arguments["stars"] as? NSNumber)?.intValue
      let flag = (arguments["flag"] as? String).map { $0 == "picked" ? 1 : $0 == "rejected" ? -1 : 0 }
      let label = (arguments["label"] as? String).map { Self.labelNames.firstIndex(of: $0) ?? -1 }
      guard stars != nil || flag != nil || label != nil else { throw DeskError.message("给出 stars、flag 或 label 中的至少一项。") }
      let said: String = try onMain {
        let ids: Set<UUID>
        if let names {
          let missing = names.filter { n in !model.frames.contains { $0.name == n } }
          guard missing.isEmpty else { throw DeskError.message("没有编号为 \(missing.joined(separator: "、")) 的画面。可用 list_frames 查看。") }
          ids = Set(model.frames.filter { names.contains($0.name) }.map(\.id))
        } else {
          ids = model.selectionIDs
        }
        guard !ids.isEmpty else { throw DeskError.message("没有选中的画面。给出 frames，或先用 select_frame。") }
        model.setMarks(ids, stars: stars, flag: flag, label: label)
        return model.status
      }
      return [["type": "text", "text": said]]
    case "select_by_marks":
      let by = arguments["by"] as? String ?? ""
      let said: String = try onMain {
        guard !model.frames.isEmpty else { throw DeskError.message("这一卷没有画面。") }
        switch by {
        case "all": model.selectAllFrames()
        case "only_shown":
          model.selectOnlyShown()
          model.status = "只选第 \(model.selected?.name ?? "") 张"
        case "picked": model.selectMarked(.picked)
        case "unflagged": model.selectMarked(.unflagged)
        case "rejected": model.selectMarked(.rejected)
        case "stars":
          guard let n = (arguments["stars"] as? NSNumber)?.intValue, (1...5).contains(n) else { throw DeskError.message("by 为 stars 时要给 stars（1–5）。") }
          model.selectMarked(.stars(n))
        case "label":
          guard let l = (arguments["label"] as? String).flatMap({ Self.labelNames.firstIndex(of: $0) }).flatMap(FrameLabel.init(rawValue:))
          else { throw DeskError.message("by 为 label 时要给 label（red、yellow、green、blue、purple）。") }
          model.selectMarked(.label(l))
        default: throw DeskError.message("by 只能是 picked、unflagged、rejected、stars、label、all 或 only_shown。")
        }
        return model.status + "；所选：" + model.selection.map(\.name).joined(separator: "、")
      }
      return [["type": "text", "text": said]]
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
      let negative = pipe.samples(source, maxDimension: 1500)
      let positive = pipe.raster(try pipe.preview(source, settings: s, profile: profile), maxDimension: 1500)
      return text(points.map { p -> [String: Any] in
        let v = reading(negative, at: p, settings: s)
        let out = positive.pixel(Int(p.x * Double(positive.width - 1)), Int(p.y * Double(positive.height - 1)))
        let d = RGB((0..<3).map { log10(max(1e-6, analysis.base.values[$0]) / max(1e-6, v.values[$0])) * s.inputGamma })
        return ["x": p.x, "y": p.y, "negative_linear": rgb(v), "density_above_base": rgb(d), "positive_srgb": rgb(out)]
      })
    case "adjust":
      let known: Set = ["warmth", "tint", "shadow_warmth", "shadow_tint", "exposure", "contrast", "saturation", "highlights", "shadows", "whites", "blacks", "texture", "clarity", "dehaze", "vibrance", "auto_white_balance", "auto_levels", "angle", "shared_balance", "shared_levels", "auto_whites_blacks", "frame"]
      // Taken out in 0.22 (高光 / 阴影 / 白色 / 黑色 and the curves took its place): said so, not
      // only as one not known.
      if arguments["midtone"] != nil {
        throw DeskError.message("midtone（中间调）0.22 起已经去掉：整体明暗用 exposure，中间调的对比用 contrast，或 set_curve 的 rgb 曲线在中间加一个点。")
      }
      let unknown = Set(arguments.keys).subtracting(known)
      guard unknown.isEmpty else { throw DeskError.message("不认识的参数：\(unknown.sorted().joined(separator: ", "))") }
      guard arguments.keys.contains(where: { $0 != "frame" }) else { throw DeskError.message("没有要改的参数。") }
      func value(_ key: String, _ range: ClosedRange<Double>) throws -> Double? {
        guard let raw = arguments[key] else { return nil }
        guard let v = (raw as? NSNumber)?.doubleValue, v.isFinite else { throw DeskError.message("\(key) 应为数字。") }
        return min(range.upperBound, max(range.lowerBound, v))
      }
      let numbers: [(WritableKeyPath<Adjustments, Double>, String, ClosedRange<Double>)] = [
        (\.warmth, "warmth", -1...1), (\.tint, "tint", -1...1), (\.shadowWarmthAmount, "shadow_warmth", -1...1), (\.shadowTintAmount, "shadow_tint", -1...1), (\.exposure, "exposure", -2...2), (\.contrast, "contrast", 0.5...1.6),
        (\.saturation, "saturation", 0...1.8),
        (\.highlightsAmount, "highlights", -1...1), (\.shadowsAmount, "shadows", -1...1), (\.whitesAmount, "whites", -1...1), (\.blacksAmount, "blacks", -1...1),
        (\.textureAmount, "texture", -1...1), (\.clarityAmount, "clarity", -1...1), (\.dehazeAmount, "dehaze", -1...1), (\.vibranceAmount, "vibrance", -1...1),
      ]
      let values = try numbers.compactMap { n in try value(n.1, n.2).map { (n.0, $0) } }
      let angle = try value("angle", -45...45)
      let (frameName, named) = try target(model, arguments)
      onMain {
        model.change("AI 调整", separate: true, syncing: !named) { a in
          for (key, v) in values { a[keyPath: key] = v }
          if let b = arguments["auto_white_balance"] as? Bool {
            // Turned on from off it starts over from the picture; already on, a neutral pick stays.
            if b && !a.autoWhiteBalance {
              a.neutralSample = nil
            }
            a.autoWhiteBalance = b
          }
          if let b = arguments["auto_levels"] as? Bool { a.autoLevels = b }
          if let angle { a.angle = abs(angle) < 0.005 ? nil : angle }
        }
        if let b = arguments["shared_balance"] as? Bool { model.setSharedBalance(b) }
        if let b = arguments["shared_levels"] as? Bool { model.setSharedLevels(b) }
        if arguments["auto_whites_blacks"] as? Bool == true { model.autoWhitesBlacks() }
      }
      let changed = arguments.keys.filter { $0 != "frame" }.sorted().joined(separator: ", ")
      return [["type": "text", "text": "已调整第 \(frameName) 张：\(changed)。可用 ⌘Z 或 undo 撤销。"]]
    case "pick_film_base", "pick_neutral":
      let p = try coordinate(arguments)
      let (frame, _) = try selected(model)
      let read = pipe.samples(try model.source(for: frame, maxDimension: 2000), maxDimension: 2000)
      let v = reading(read, at: p, settings: frame.adjustments)
      // Where it was read, in the frame's picture: the point on the frame as cropped, unturned.
      let raw = ImageGeometry.raw(p, settings: frame.adjustments, aspect: Double(read.width) / Double(max(1, read.height)))
      let crop = frame.rect
      let place = NormalRect(x: crop.x + (raw.x - 0.005) * crop.width, y: crop.y + (raw.y - 0.005) * crop.height,
        width: 0.01 * crop.width, height: 0.01 * crop.height)
      onMain {
        switch name {
        // A base is picked on a camera's or imported picture whole, a scan as cropped (`basePlace`).
        case "pick_film_base":
          model.setFilmBase(v, at: frame.sourcePath != nil ? place : NormalRect(x: raw.x - 0.005, y: raw.y - 0.005, width: 0.01, height: 0.01))
        default: model.setNeutral(v, at: place)
        }
      }
      let reading = "负片线性 RGB \(String(format: "%.4f %.4f %.4f", v.r, v.g, v.b))"
      let said = ["pick_film_base": "已取片基：\(reading)；自动白平衡已关闭。"]
      return [["type": "text", "text": said[name] ?? "已按中性点自动白平衡：\(reading)。"]]
    case "set_curve":
      let channels = ["rgb": 0, "red": 1, "green": 2, "blue": 3]
      guard let channel = arguments["channel"] as? String, channel == "all" || channels[channel] != nil else {
        throw DeskError.message("channel 应为 rgb、red、green、blue 或 all。")
      }
      guard arguments["points"] == nil || arguments["points"] is [[Any]] else { throw DeskError.message("points 是 [[x, y], …]。") }
      var points = try ((arguments["points"] as? [[Any]]) ?? []).map { p -> CurvePoint in
        guard p.count == 2, let x = (p[0] as? NSNumber)?.doubleValue, let y = (p[1] as? NSNumber)?.doubleValue,
          (0...1).contains(x), (0...1).contains(y)
        else { throw DeskError.message("每个点是 [x, y]，都在 0 到 1 之间。") }
        return CurvePoint(x: x, y: y)
      }.sorted { $0.x < $1.x }
      guard points.count <= 16 else { throw DeskError.message("一条曲线最多 16 个点。") }
      guard channel != "all" || points.isEmpty else { throw DeskError.message("channel 为 all 时只能清掉全部曲线，不能给 points。") }
      if let first = points.first, first.x > 0 { points.insert(CurvePoint(x: 0, y: 0), at: 0) }
      if let last = points.last, last.x < 1 { points.append(CurvePoint(x: 1, y: 1)) }
      guard zip(points, points.dropFirst()).allSatisfy({ $1.x - $0.x >= 0.01 - 1e-9 }) else {
        throw DeskError.message("相邻两点的 x 至少相隔 0.01（两端补上的 (0, 0)、(1, 1) 也算）。")
      }
      let (frameName, named) = try target(model, arguments)
      let curves: ToneCurves? = onMain {
        model.change("AI 曲线", separate: true, syncing: !named) { a in
          guard let index = channels[channel] else { a.curves = nil; return }
          var curves = a.curves ?? ToneCurves()
          curves[index] = points.isEmpty ? ToneCurve() : ToneCurve(points: points)
          a.curves = curves.isIdentity ? nil : curves
        }
        return model.settings.curves
      }
      let said = channel == "all" ? "已清掉全部曲线" : points.isEmpty ? "已把 \(channel) 曲线恢复成直线" : "已设定 \(channel) 曲线"
      return text(["message": "第 \(frameName) 张：" + said + "。可用 ⌘Z 或 undo 撤销。", "frame": frameName, "curves": curvesState(curves)])
    case "pick_curve_point":
      let p = try coordinate(arguments)
      guard let mode = (arguments["mode"] as? String).flatMap(CurvePick.init(rawValue:)) else { throw DeskError.message("mode 应为 point 或 neutral。") }
      let channels = ["rgb": 0, "red": 1, "green": 2, "blue": 3]
      guard let channel = channels[(arguments["channel"] as? String) ?? "rgb"] else { throw DeskError.message("channel 应为 rgb、red、green 或 blue。") }
      let (frame, profile) = try selected(model)
      // Read from the single view's own picture where it shows this frame: the value under the pointer there.
      let shown = onMain { model.selected?.id == frame.id ? model.positiveBeforeCurves(at: p) : nil }
      let input = try shown
        ?? pipe.beforeCurves(try model.source(for: frame, maxDimension: 2000), settings: frame.adjustments, profile: profile, analysis: nil, at: p)
      let (done, said, curves) = onMain { (model.pickOnCurves(input, mode: mode, channel: channel), model.status, model.settings.curves) }
      guard done else { throw DeskError.message(said + "。没有改。") }
      return text(["message": said.replacingOccurrences(of: " · ⌘Z 撤销", with: "") + "。可用 ⌘Z 或 undo 撤销。",
        "before_curves": rgb(input), "curves": curvesState(curves)])
    case "pick_shadow_neutral":
      let p = try coordinate(arguments)
      let (frame, _) = try selected(model)
      let read = pipe.samples(try model.source(for: frame, maxDimension: 2000), maxDimension: 2000)
      let v = reading(read, at: p, settings: frame.adjustments)
      let set = onMain { model.setShadowNeutral(v) }
      guard set else { throw DeskError.message("这一点太暗或太亮（亮度在暗部到中间调之间时才够得着），没有改。换一处阴影里的中性物体。") }
      let after = onMain { model.settings }
      return [["type": "text", "text": String(format: "已按阴影中性点配平阴影：阴影冷暖 %+.2f、阴影色调 %+.2f。可用 ⌘Z 或 undo 撤销。", after.shadowWarmthAmount, after.shadowTintAmount)]]
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
      let base = pipe.analyze(try model.source(for: frame, maxDimension: 600), settings: frame.adjustments, profile: profile).base
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
      // A base only estimated from the frame's clearest film leans the points by how much denser it is.
      let estimated = (frame.adjustments.base ?? frame.adjustments.rollBase) == nil
        ? "注意：这张的片基只是按最透处估计的，标定会跟着偏；先用 pick_film_base 在片边或片头取片基，或在片边看得到片基的画面上取点。\n" : ""
      return [["type": "text", "text": "已在第 \(frame.name) 张加了 \(added.count) 个中性点。\n" + estimated + calibrationReport(model)]]
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
    case "auto_straighten":
      _ = try selected(model)
      let finished = DispatchSemaphore(value: 0)
      var said: String?
      onMain {
        model.autoStraighten { text in
          said = text
          finished.signal()
        }
      }
      // A frame takes a second or so; a whole roll chosen, longer.
      let end = Date().addingTimeInterval(240)
      if Thread.isMainThread {
        while said == nil && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
      } else {
        _ = finished.wait(timeout: .now() + 240)
      }
      guard let said else { throw DeskError.message("自动拉直还没做完，稍后用 get_state 看 straighten_degrees。") }
      return [["type": "text", "text": said]]
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
      onMain { model.change("自动片基") { $0.base = nil; $0.basePicked = nil } }
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
    case "list_grading_presets":
      let presets = onMain { model.preferences.gradingPresets }
      return text(presets.map { p -> [String: Any] in
        ["name": p.name, "groups": p.settingsGroups.map(\.name), "made": ISO8601DateFormatter().string(from: p.made)]
      })
    case "apply_grading_preset":
      _ = try selected(model)
      guard let wanted = (arguments["name"] as? String)?.lowercased(), !wanted.isEmpty else { throw DeskError.message("需要预设名称 name。") }
      let said: String = try onMain {
        let presets = model.preferences.gradingPresets
        guard let p = presets.first(where: { $0.name.lowercased() == wanted }) ?? presets.first(where: { $0.name.lowercased().contains(wanted) })
        else { throw DeskError.message("没有名为 \(wanted) 的调色预设。可用 list_grading_presets 查看。") }
        model.applyGradingPreset(p)
        return model.status
      }
      return [["type": "text", "text": said]]
    case "take_snapshot":
      _ = try selected(model)
      let said: String = onMain {
        model.takeSnapshot(named: arguments["name"] as? String ?? "")
        return model.status
      }
      return [["type": "text", "text": said]]
    case "restore_snapshot":
      let (frame, _) = try selected(model)
      let shots = onMain { model.shownSnapshots }
      guard let wanted = (arguments["name"] as? String)?.lowercased(), !wanted.isEmpty else {
        return text(["frame": frame.name, "snapshots": shots.map { ["name": $0.name, "made": ISO8601DateFormatter().string(from: $0.made)] }])
      }
      guard let s = shots.first(where: { $0.name.lowercased() == wanted }) ?? shots.first(where: { $0.name.lowercased().contains(wanted) })
      else { throw DeskError.message("第 \(frame.name) 张没有名为 \(wanted) 的快照。不给 name 调用 restore_snapshot 可列出它的快照。") }
      let said: String = onMain {
        model.restoreSnapshot(s)
        return model.status
      }
      return [["type": "text", "text": said]]
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
