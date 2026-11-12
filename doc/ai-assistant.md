# AI 助手（MCP）

Epson Scan plus 可以作为 [MCP](https://modelcontextprotocol.io) 服务器，让 Claude 等 AI 助手帮你看转换：读取选中画面的片基与来源、胶片的通道斜率、全卷斜率估计、白平衡、色阶、负片密度和正片的直方图、白点以上的高光和 SDR 范围，画面的裁切、拉直、去串色和手动取过的点，转换实际用的斜率和来源、自动分析定出的两端，高光、阴影和整卷同一白平衡 / 色阶，每个预设的说明和在哪些卷里用，以及图库里的各卷；看预览、在画面上取点，并调整片基、中性灰、冷暖、曝光、色阶等。每次调整都是 App 里的一步编辑，可以用 ⌘Z 撤销；助手不能扫描、删除或导出文件。

1. 点工具栏中间的「AI 助手」，打开「允许 AI 助手读取和调整转换」（默认关闭）。
2. 连接助手：
   - **Claude Desktop**：点「Claude Desktop 配置」复制，在 Claude Desktop 的设置 → 开发者 → 编辑配置里加入 `mcpServers`，重启 Claude Desktop。
   - **Claude Code**：点「Claude Code 命令」复制，在终端运行。
3. 在对话里让助手「看看这张为什么偏色」之类即可。App 没开或没开启 MCP 时，助手会收到提示。

**让助手做翻拍标定**：说「帮这卷做翻拍标定」。
- **它怎么做**：先看几张预览，按物体挑出本来就中性的东西，比如拍在胶片上的色卡灰块、白牌子、白墙、灰水泥、云。从亮到暗挑 3–6 个，用 `calibration_add_points` 交给 App。
- **它怎么查**：看每个点偏离拟合多少。有点偏离 0.03 D 以上时，报告给出彼此落在一条线上的最大一组，组外的点去掉。有两组各自一致、斜率却不同时，报告点名分歧在哪几个点，不替你猜，请助手在同样的光下再加点。
- **最后**：生成「胶片 · 翻拍 · 开拍时间」预设，并告诉你选了哪些地方。App 在那几张画面上标出这些点，「翻拍预设标定」里列出它们在哪几张。
- **试过的效果**（R22）：
  - **怎么试的**：只看 App 的预览，按物体挑点。7484 的白墙、7483 阳光下的水泥地、7479 的白石块留下了。7485 阴影里的柱子、7478 的人行道、7488 的柏油路和 7478 刷漆的灰铁箱偏离太大，按提示去掉。
  - **独立检验**：生成的预设用在没取点的几张上，和 C1 的色差 7478 从 7.9 降到 3.6，7493 从 8.0 降到 4.1，中性处的偏蓝（b* −13）回到 0 附近。7491 仍然变差（5.4 → 7.0），和其他标定一样，原因还没查清。
- **注意**：
  - 判断靠认出是什么东西，不靠颜色，所以预览整体偏色也不影响。
  - 取点用浮点读数，密的地方也不会因为 8 位量化而不准。
  - 看预览时，画面会发给助手所在的 AI 服务处理。

助手启动的是 App 自己（`EpsonScanPlus --mcp`），它通过只有你的账户能访问的本机连接与正在运行的 App 通信，不经过网络。工具列表：`get_state`、`list_frames`、`list_presets`、`list_rolls`、`select_frame`、`preview`、`sample`、`adjust`、`pick_film_base`、`auto_film_base`、`pick_neutral`、`choose_preset`、`apply_to_roll`、`reset_adjustments`、`undo`、`auto_crop`，以及预设标定的 `calibration_add_points`、`calibration_state`、`calibration_remove_point`、`calibration_clear`、`calibration_make_preset`。

去漏光页也在同一个 MCP 服务器里。FilmLightLab 原来本机 HTTP 接口能做的，这里都能做，对照表见 [去漏光](light-leak.md#通过-mcp)：

- **打开和导入**：`leak_open`（本卷某张或某个任务）、`leak_import`（给出路径导入正片，原文件不改）、`leak_import_reference`（导入别处做好的干净参考图，免费）。
- **查看**：`leak_get_state`、`leak_list_jobs`、`leak_list_regions`、`leak_preview`、`leak_sample`。
- **修复**：`leak_start`（有参考图按参考图，没有时按启用的局部区域）、`leak_set`、`leak_clear_correction`。
- **用自己的图像模型做参考图**：`leak_reference_prompt`（只读，给出和 API 一样的提示词和步骤）、`leak_export_upload`（只打开保存缩图的窗口）。
- **局部**：`leak_detect`、`leak_add_region`、`leak_update_region`、`leak_delete_region`、`leak_add_protection`。
- **对齐、方向和预设**：`leak_set_landmarks`、`leak_rotate`、`leak_crop`、`leak_load_preset`。

有几件事留给你在 App 里确认：

- **生成参考图**：要上传缩图并计费，`leak_request_reference` 只打开确认窗口，可以预填质量和附加要求。
- **写文件**：`leak_export`、`leak_save_preset` 只打开保存窗口，由你选位置。
- **API Key**：助手读不到，也改不了。
