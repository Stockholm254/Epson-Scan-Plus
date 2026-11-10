# 构建与测试

## 构建

安装 Xcode Command Line Tools 后，在仓库根目录执行（App 默认输出到上一级目录的 `Epson Scan plus.app`）：

```sh
bash build.sh
"../Epson Scan plus.app/Contents/MacOS/EpsonScanPlus" --self-test --test-output /tmp/EpsonScanPlus-tests
```

可指定 `EPSON_SCAN_PLUS_BUILD_DIR` 与 `EPSON_SCAN_PLUS_APP_DIR`。当前构建目标为 arm64；无 npm、Python 或第三方 Swift 包依赖。图像转换用的 Core Image 内核用 Metal 写（`Sources/Kernels.swift`），App 运行时才编译，所以构建不需要 Metal 工具链。系统会缓存编译结果，只有内核改过以后第一次运行时，每个内核多等约 0.3 秒。每个内核单独编译：同一个库里放两个内核时，Core Image 会在同一个渲染环境里把先渲染的那个也用在另一个上（macOS 27.2 上见到）。

自测可追加 `--overview /absolute/path/overview.png` 验证本次 18 格。下面的硬件测试会**实际驱动扫描仪**，以 48-bit 读取预览并扫描第 9 格（不足 9 格时取末格），检查采集精度、导出和整批结束后自动导出的正片，并报告整卷估计。它使用独立的临时设置，结束后删除：

```sh
"../Epson Scan plus.app/Contents/MacOS/EpsonScanPlus" --sane-hardware-test --library /absolute/output/directory
```

离线批量导出工程中已正式扫描/导入的画面，不调用扫描仪：

```sh
"../Epson Scan plus.app/Contents/MacOS/EpsonScanPlus" --export-project /absolute/Session.epscan --output /absolute/export/directory --format tiff --color-space srgb
```

`--rotation 0|1|2|3` 可在离线导出时覆盖方向，`--mirror` 启用水平镜像（均不改工程）。正常启动支持 `--library PATH`、`--project FILE` 或 `--image FILE`。

## 图标

App 图标是 Icon Composer 文档 `Icon/AppIcon.icon`：`icon.json` 加 `Assets/` 里的几层 SVG（暗盒的标签、片口、上下盖、筒身，和胶片片头）。

- **修改**：用 Xcode 附带的 Icon Composer（`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`）打开它，或者直接改 SVG 和 `icon.json`。
- **预览**：`ictool` 可以不开 Icon Composer 就画出各种外观，例如：
  ```sh
  "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" Icon/AppIcon.icon --export-image --output-file /tmp/icon.png --platform macOS --rendition Dark --width 512 --height 512 --scale 2
  ```
  `--rendition` 可以是 `Default`、`Dark`、`ClearLight`、`ClearDark`、`TintedLight`、`TintedDark`。
- **编译**：改完运行 `bash Icon/build-icon.sh`。它需要 Xcode，用 actool 编译出 `Icon/Assets.car`（分层图标，系统用它画液态玻璃）和 `Icon/AppIcon.icns`（扁平的备用图），然后把这两个文件和源文件一起提交。actool 每次的输出不完全相同，所以没改图标时不要运行它。
- **构建**：`build.sh` 只把这两个文件拷进 `Contents/Resources`，`Info.plist` 里的 `CFBundleIconFile` 和 `CFBundleIconName` 都是 `AppIcon`。

## 发布和更新

发布前先把 `Info.plist` 的 `CFBundleShortVersionString` 和 `CFBundleVersion` 改成新版本（版本号每次加一），`doc/CHANGELOG.md` 写好 `## <版本> …` 一节，然后提交。之后执行：

```sh
bash release.sh
```

**它依次做这些事：**

1. 工作区有没提交的改动时直接停下，所以每个版本都对应一个提交。
2. 版本已经发过（更新列表里有，或磁盘映像已经存在）时也停下。已发布的版本从不替换。
3. 从提交构建 App，校验代码签名，跑全部自检。
4. 输出两样东西：
   - 磁盘映像 `../Epson-Scan-plus-<版本>.dmg`，里面有 App 和指向「应用程序」的链接，用来手动安装。
   - 更新包 `Epson-Scan-plus-<版本>-<构建号>.zip`，放进更新列表的目录。
5. 用发布密钥签名，加进 `appcast.json`。列表里每个版本的说明是更新记录里那一节各条的标题。

**各个位置：**

- **更新列表**：默认 `~/Library/Application Support/epscan/Releases/`。
- **发布密钥**：`~/Library/Application Support/epscan-release/update-signing.key`，Ed25519 私钥，只有本人能读，不在仓库里。第一次执行时生成。
  - 它的公钥写在 `Sources/UpdateFeed.swift` 里，`release.sh` 会核对两边是否一致。
  - 要备份这个文件。丢了以后，装好的 App 不会接受用新密钥签的版本，只能用磁盘映像重装一次。
- **可以换的位置**：`EPSCAN_RELEASE_FEED_DIR`、`EPSCAN_RELEASE_KEY`、`EPSCAN_RELEASE_IMAGE_DIR`。`EPSCAN_RELEASE_SKIP_TESTS=1` 跳过自检。

**装好的 App 怎么更新**（`Sources/Updater.swift`）：

- **哪一份会更新**：只有放在 `/Applications` 或 `~/Applications`、而且能被替换的那一份。
- **检查**：打开约 5 秒后和之后每六小时读一次更新列表，取比自己构建号新、而且这台系统能运行的最新版本。
- **核对**：下载后核对大小、SHA-256、Ed25519 签名（签名覆盖 App 标识、版本、构建号、校验值和最低系统）、包里 App 的标识和版本，以及 `codesign --verify --deep --strict`。
- **替换**：App 退出后，一个独立的脚本把旧版本移到 `~/Library/Application Support/epscan/旧版/Epson Scan plus <版本> (<构建号>).app`，再把新版本放回原处。新版本放不进去时，把旧版本放回去。日志在 `~/Library/Application Support/epscan/Updates/install.log`。
  - 结果写在同一目录的 `install-result` 里。没换上的那个版本，下次打开时只显示原因，不再自动下载；在「检查更新…」里点检查会再试。
- **换更新列表**：用 `defaults write local.epscan.mac updateFeed <URL>`，https 地址也行，签名照样核对。
- **签名方式**：`build.sh` 在这台 Mac 有代码签名身份「Epson Scan plus Signing」时用它签名（0.18.1 起的发布都是），没有时退回临时签名（ad-hoc）；名字可以用环境变量 `EPSON_SCAN_PLUS_SIGNING_IDENTITY` 换。都没有 Apple 公证。
  - **为什么要固定证书**：临时签名的身份是这一份构建的散列，每个版本对 macOS 都是新 App，钥匙串里的 OpenAI Key 每次更新后都要再问一次。用同一张证书签名，各个版本就是同一个 App，「始终允许」一直有效。
  - **建证书**：「钥匙串访问」→「证书助理」→「创建证书…」，名称 `Epson Scan plus Signing`，身份类型「自签名根证书」，证书类型「代码签名」，放在登录钥匙串里，不用设成信任。默认一年有效，换证书的那一版钥匙串会再问一次。第一次用它签名时 macOS 问 codesign 能否使用这把密钥，选「始终允许」。
  - **别的 Mac**：自签名证书和临时签名一样不被系统认可，从网上下载到别的 Mac 时，第一次打开要在「系统设置 → 隐私与安全性」里允许。

## 界面截图

README 和[界面说明](interface.md)里窗口的截图由程序拍，推送前自动更新：

```sh
bash Tools/screenshots.sh            # 拍到 doc/images
bash Tools/screenshots.sh <文件夹>   # 拍到别处
```

- **拍哪几张**：`main-window`、`main-annotated`（带 1–9 号区域）、`panels`、`single-view`、`library`、`leak-page`。扫描头、看片镜和裁切玻璃泡的特写不在其中，要手动截。
- **怎么拍**：`Tools/Screenshots.swift` 和 `Sources` 一起编译（不含 `EpsonScanPlus.swift`），用 App 自己的界面开一个窗口。窗口只有 2 点露在屏幕右边，在所有窗口后面，不接鼠标；由窗口服务器画出来，再用 `screencapture -l` 拍下。界面固定为深色，窗口 1440 × 920 点。
- **用哪些画面**：图库里的一卷海和天空，Portra 160，V850 扫描（`2026-10-29_225926_1C87`）。库那张只放同一卷胶片的六次扫描。这些照片原来就在 GitHub 上。
- **只读**：工程以只读打开；设置复制到临时的一组里，布局相关的几项用默认值。图库、缩略图缓存和 App 的设置都不改。
- **不改就不重写**：新拍的和原来的平均差别不到 1/255 时，原文件不动。
- **需要**：屏幕没锁，运行它的程序（终端或 Claude）有「屏幕录制」权限。编译约一分半，拍摄约半分钟。

**推送前的钩子**：`.githooks/pre-push`。启用一次：

```sh
git config core.hooksPath "$(pwd)/.githooks"
```

- **什么时候拍**：推送到远端的 `main` 时，如果 `Sources` 或 `Tools` 自上次拍摄以来改过，就从要推送的那个提交重新编译并拍摄。上次拍摄时的版本记在 `.git/epscan-screenshots`。
- **拍出来一样**：照常推送。
- **拍出来不一样**：新图提交在推送的分支上（提交说明 “Interface screenshots taken again”），这次推送停下。看过新图后再推送一次，截图就一起推上去。其他会话没提交的改动不受影响；图本身有没提交的改动时不覆盖，停下来说明。
- **拍不了**：屏幕锁着，或者编译、拍摄失败时，推送停下，并说明原因。这次不更新截图就推送：`EPSCAN_SKIP_SCREENSHOTS=1 git push`。

## 早期验证记录（2026-10-25，0.1–0.3）

2026-10-25，本机扫描仪实测：

- 150 dpi 透扫预览 885 × 1455，自动识别三条 135 胶片，共 18 格。
- 第 09 格 2400 dpi 正式扫描：2299 × 3483，每通道 8-bit。原始 TIFF 保留。
- 完整转换并导出 TIFF 16-bit/通道、JPEG 8-bit/通道；另测了旋转后的尺寸与 DPI。
- 同级 `epscan Test Roll/2026-10-25_174913_6848/Final/` 是方向整理后的成片；`Exports/` 是旋转测试输出。工程保留 18 个裁切框，仅第 09 格已做正式扫描。
- 自动测试：坐标方向、裁切、正片直通、密度反相、旋转、TIFF 位深/DPI、JPEG、配置验证、工程读写、真实 18 格识别、120 的 6×4.5/6×6/6×7/6×9 合成样本。
- 16-bit 输入的 1024 个不同灰阶经导出后仍有 1024 个，不是 8-bit 图扩展成 16-bit。
- 0.2 回归：合成灰阶的通道偏色校正、片基微调不被自动算法抵消、中性点取样、四种旋转/镜像下坐标与实际像素对应、单张上下文稳定、16-bit 扫描后裁切/还原、越界重扫标记，以及旧工程读取。
- 0.2 在独立离屏位图中绘制自己的测试画布：8 倍放大时，画布外检测到 0 个被覆盖的抽样像素。此测试不是对用户桌面的截图，也不等同于窗口按钮全部点验。
- 0.3 回归：预览完成进入单张、左右按键导航与首尾边界、裁切按键优先级、收边保留旧参数和扫描原件、片基/漏光/片夹统计污染、混合透光边界、像素取整不带回边缘，以及横向/纵向 120 四种尺寸的合成条带。18 张真实预览的首尾和片间边界亦已检查。

尚未验证：真实 120 胶片、不同片夹/倾斜/重叠/复杂片基，批量 18 格完整扫描，以及窗口按钮/拖动/放大镜的实机自动化交互。界面控制权限未生效，因此没有把编译成功描述成界面全部点验通过。自动分格是启发式算法，务必检查画面框。
