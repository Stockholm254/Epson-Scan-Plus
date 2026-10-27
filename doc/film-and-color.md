# 胶片配置、转换与颜色

## 通道斜率从哪里来

转换每张负片都需要红、绿、蓝三个通道的反差（斜率）。程序按以下顺序选用：

1. **本机标定预设**：在「胶片」页用两个以上中性点（灰卡、白墙、灰色水泥等）为这台扫描仪标定的「· V850」预设。输入胶片名称时会自动选用。
2. **整卷自动估计**：没有本机预设时，按整卷画面里的明暗过渡估计（局部密度梯度之比）。至少需要 2 张，画面越多越准。
3. **Kodak 数据表斜率**：画面太少、无法估计时使用。

选「通用」且没有整卷估计时，每张按自己的画面拉伸各通道。各方法的实测对比见[版本记录](CHANGELOG.md)中的 0.4.5 和 0.4.6。

## 胶片配置和颜色边界

内置 Portra 160、Portra 400、Ektar 100，输入名称并应用即可切换。未匹配名称回到通用配置，不猜测未知胶片特性。可从「配置与技术文档」导入 JSON；示例见 [`custom-profile.example.json`](../custom-profile.example.json)。

转换过程：扫描编码值 → 片基相对光学密度 → 胶片各通道中段斜率近似 → 白平衡/色阶 → 手动调整 → sRGB。旧 ICA 与普通导入默认输入 Gamma 2.2；0.4.0 实验接口的新预览与画面自动设为 1.0。自动白平衡采用图像统计，单一色调场景可能需要关闭或选中性点。自动片基采用亮端统计，最好用「取片基」从未曝光的橙色片基采样；单张模式会显示周边可用区域，已扫描文件则只能取其实际包含的区域。

胶片资料引用 Kodak 官方 2016 年版 E-4051、E-4050、E-4046 的特性曲线。斜率是人工读图得到的近似起点，**不是官方 RGB 转换公式、扫描仪 ICC 标定或准确色彩保证**。技术文档中的测量条件与扫描仪光谱响应不同；冲洗、片龄、曝光、光源也会改变结果。没有人为添加胶片颗粒或“胶片滤镜”。

- [Portra 160 / E-4051](https://business.kodakmoments.com/sites/default/files/files/products/e4051_portra_160.pdf)
- [Portra 400 / E-4050](https://imaging.kodakalaris.com/sites/default/files/files/resources/e4050_portra_400.pdf)
- [Ektar 100 / E-4046](https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4046_ektar_100.pdf)

## 作者的两张 IT8 色卡

照片中反射卡是 `IT8.7/2`，批号 `MONR2022:05-03`；透射卡是 `IT8.7/1`，批号 `MONT45:2022:07`。胶片透扫应使用透射卡。必须取得完全匹配批次的参考数值文件（按厂商命名规则，透射卡对应 `MONT45.2022.07.txt`），再实际扫描色卡，不能从手机照片取值。

本次已找到 [X-Rite 官方参考文件下载页](https://www.xrite.com/service-support/downloads/m/monaco-it8-reference-files)，但下载页返回 403，**尚未取得并核验这个批次的数据，也没有扫描实体色卡，因此本版没有生成或应用 IT8 ICC 配置**。不要把任意年份的参考文件代替它。

IT8 透射标定描述的是扫描仪/目标材料的响应，不能直接当成 Portra 160 的去色罩配方。将来加入校准需要独立保留扫描仪配置、扫描设置、目标批次和误差验证；不能直接把正片 ICC 套在橙色负片上并声称准确。色卡老化也可能影响结果。参考：[X-Rite 色彩管理指南](https://www.xrite.com/-/media/xrite/files/literature/l11/l11-100_l11-199/l11-176_a_guide_to_color_management/l11-176_guide_to_cm_en.pdf)。
