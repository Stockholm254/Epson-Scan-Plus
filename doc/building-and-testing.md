# 构建与测试

## 构建

安装 Xcode Command Line Tools 后，在仓库根目录执行（App 默认输出到上一级目录的 `Epson Scan plus.app`）：

```sh
bash build.sh
"../Epson Scan plus.app/Contents/MacOS/EpsonScanPlus" --self-test --test-output /tmp/EpsonScanPlus-tests
```

可指定 `EPSON_SCAN_PLUS_BUILD_DIR` 与 `EPSON_SCAN_PLUS_APP_DIR`，旧的 `FILMDESK_BUILD_DIR` / `FILMDESK_APP_DIR` 仍可使用。当前构建目标为 arm64；无 npm、Python 或第三方 Swift 包依赖。`CIColorKernel(source:)` 在本机可运行，但属于 Apple 已弃用 API，后续应迁移为预编译 Metal 内核。

自测可追加 `--overview /absolute/path/overview.png` 验证本次 18 格。下面的硬件测试会**实际驱动扫描仪**，以 48-bit 读取预览并扫描第 9 格（不足 9 格时取末格），检查采集精度、导出和整批结束后自动导出的正片，并报告整卷估计。它使用独立的临时设置，结束后删除。`--hardware-test` 是旧的 ICA 版本：

```sh
"../Epson Scan plus.app/Contents/MacOS/EpsonScanPlus" --sane-hardware-test --library /absolute/output/directory
```

离线批量导出工程中已正式扫描/导入的画面，不调用扫描仪：

```sh
"../Epson Scan plus.app/Contents/MacOS/EpsonScanPlus" --export-project /absolute/Session.filmdesk --output /absolute/export/directory --format tiff
```

`--rotation 0|1|2|3` 可在离线导出时覆盖方向，`--mirror` 启用水平镜像（均不改工程）。正常启动支持 `--library PATH`、`--project FILE` 或 `--image FILE`。

## 早期验证记录（2026-10-25，0.1–0.3）

2026-10-25，本机扫描仪实测：

- 150 dpi 透扫预览 885 × 1455，自动识别三条 135 胶片，共 18 格。
- 第 09 格 2400 dpi 正式扫描：2299 × 3483，每通道 8-bit。原始 TIFF 保留。
- 完整转换并导出 TIFF 16-bit/通道、JPEG 8-bit/通道；另测了旋转后的尺寸与 DPI。
- 同级 `FilmDesk Test Roll/2026-10-25_174913_6848/Final/` 是方向整理后的成片；`Exports/` 是旋转测试输出。工程保留 18 个裁切框，仅第 09 格已做正式扫描。
- 自动测试：坐标方向、裁切、正片直通、密度反相、旋转、TIFF 位深/DPI、JPEG、配置验证、工程读写、真实 18 格识别、120 的 6×4.5/6×6/6×7/6×9 合成样本。
- 16-bit 输入的 1024 个不同灰阶经导出后仍有 1024 个，不是 8-bit 图扩展成 16-bit。
- 0.2 回归：合成灰阶的通道偏色校正、片基微调不被自动算法抵消、中性点取样、四种旋转/镜像下坐标与实际像素对应、单张上下文稳定、16-bit 扫描后裁切/还原、越界重扫标记，以及旧工程读取。
- 0.2 在独立离屏位图中绘制自己的测试画布：8 倍放大时，画布外检测到 0 个被覆盖的抽样像素。此测试不是对用户桌面的截图，也不等同于窗口按钮全部点验。
- 0.3 回归：预览完成进入单张、左右按键导航与首尾边界、裁切按键优先级、收边保留旧参数和扫描原件、片基/漏光/片夹统计污染、混合透光边界、像素取整不带回边缘，以及横向/纵向 120 四种尺寸的合成条带。18 张真实预览的首尾和片间边界亦已检查。

尚未验证：真实 120 胶片、不同片夹/倾斜/重叠/复杂片基，批量 18 格完整扫描，以及窗口按钮/拖动/放大镜的实机自动化交互。界面控制权限未生效，因此没有把编译成功描述成界面全部点验通过。自动分格是启发式算法，务必检查画面框。
