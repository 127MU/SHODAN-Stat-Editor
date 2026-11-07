# r4 接续交接记录

更新日期为 2026-11-07，时区 Asia/Hong_Kong。

## 当前状态

- 工作目录为 `D:/agent/shodan-stat-editor-publish`。
- 目标仓库为 <https://github.com/127MU/SHODAN-Stat-Editor>，远端名称为 `fork`。
- PR #44 与 #45 均已合并。本轮开始时本地 `HEAD` 和 `fork/main` 同为 `a5c197f`，已包含草稿冲突启动修复。
- 接续分支为 `codex/scroll-card-reveal`。
- 本轮 PR 为 <https://github.com/127MU/SHODAN-Stat-Editor/pull/46>。
- 版本保持 `4.6.0-r4`，Flutter 版本为 `4.6.0-r4+5`。
- 卡片滚动入场已完成。滚动回归、界面完整测试和静态分析已通过，新的 Flutter release 已构建。
- 用户随后提供的安装诊断也已处理。非 4 字节对齐的实体浮点字段不再被误判为禁止微调，真实数据导出回读已验证。
- 本轮生成的是供测试的本地 r4 修订包。代码通过 PR 交付。

## 已同步的启动修复

PR #45 对应提交为 `0d82759`，已在主分支中。

`Workspace::configure_draft` 发现旧草稿与新数据指纹冲突时，会挂起草稿，将原因保存在 `draft_problems`，继续打开工作区。过期草稿文件保持原样，偏移不会直接套用到新数据。偏移越界和草稿引用的数据文件缺失也采用同一流程。

相关文件为 `rust/core/src/workspace.rs` 和 `rust/core/src/game_workspace.rs`。界面可以继续进入，诊断与写入预览可以显示冲突。

## 卡片入场

### 行为

所有使用 `CatalogEntrance.card` 的卡片共享这一实现，覆盖装备目录、参数分类、被动组合、全局预设、游戏参数及设置页面。

- 初始入场由一个共享的 490 毫秒时钟驱动。多列按行从右往左错峰，单列按条目顺序错峰，延迟有上限。
- 取消旧版前 8 张卡片的限制。
- 卡片从窗口右边界外进入。实际横向位移为窗口宽度乘以剩余进度。
- 首次滚动入场由卡片自身在最近滚动视口中的位置控制。卡片从视口底部进入时逐渐滑到位。
- 滚动停止后，共享的 230 毫秒收尾时钟让已露出的卡片完整归位。即使只滚出半张卡片，也不会停在横向偏移处造成错列。
- 已归位的卡片继续滚动时保持列对齐，不会再次被拉离布局位置。
- 初始时间进度与滚动进度取较小值，避免首屏动画结束时把部分可见卡片突然拉回。
- 完整显示时精确回到布局位置，不保留错峰计算产生的小偏移。
- 系统开启减少动态效果后，卡片直接显示。

### 实现与性能边界

`desktop/morrow/lib/motion.dart` 中的 `_RenderRevealCard` 在绘制阶段测量位置。此时视口布局已完成，测量对象是未施加子控件横向位移的代理节点，避免读取上一帧布局或受自身动画影响。

动画和 `ScrollPosition` 的监听只标记绘制，不在每次滚动时重建卡片内容。`attach` 和 `detach` 分别注册、释放监听。`applyPaintTransform` 与点击命中使用同一个偏移，使文字坐标、控件绘制和点击位置一致。

`_CardSettleScope` 给整页卡片共享一个收尾时钟。`ScrollStartNotification` 暂停并复位收尾进度，`ScrollEndNotification` 启动收尾。每张卡片只记录是否已经归位，避免滚动开始时让刚刚归位的卡片突然向右弹走。收尾不创建每卡片计时器，也不重建卡片内容。

`CatalogEntrance` 使用 `LayoutBuilder` 感知可用区域变化，窗口或页面视口缩放后重新计算入场位置。它不在普通滚动帧中重建卡片。

`main.dart` 与 `armor_page.dart` 删除旧 `count` 参数。`main.dart` 保留原有格式，避免整文件格式化掩盖实际变化。

自动化已验证滚动不重建测试卡片内容。真实 Windows 显卡上的帧耗时和不同玻璃材质下的 FPS 尚未测量。

## 诊断中的安装失败

### 记录与根因

用户提供的诊断记录显示，安装在导出 `generated_entity_deltas.dl_bin` 时失败，错误为 `不允许借用此浮点字段：0x2d2a9`。

`0x2d2a9` 是十进制偏移 185001，不是 4 的倍数。旧校验将偏移按 4 字节对齐作为必要条件，而实体记录中的实际字段可能位于这样的非对齐地址。Rust 通过字节切片解码，不要求字段地址是 4 的倍数。

### 修复与保留的检查

改动位于 `rust/core/src/correction.rs`。

- 允许调用方明确授权的非对齐浮点字段参与校正。
- 校验该字段完整位于有效载荷中，且当前值有限。
- 字段的四个字节必须完整落在哈希算法可处理的完整字范围内。跨入不足八字节的文件尾部时返回错误。
- 浮点字段仍不得与求解的头部区域重叠。
- 上层导出仍要求微调字段确实已被修改。
- 修改字节范围校验、哈希校验和加密回读校验继续执行。

### 验证

新增回归覆盖非对齐字段位于单个哈希字中、横跨两个完整哈希字，以及跨入不完整尾部时的拒绝行为。失败测试也检查输入保持原样。

另使用 `dist/native-desktop-smoke-19/data/game/generated_entity_deltas.dl_bin` 的隔离副本验证日志里的同一偏移。

- 原始值为 4，测试输入为 5。
- `prepare-copy` 成功导出，导出文件重新解密成功。
- 导出目标哈希、原始快照哈希及回读哈希完全一致。
- 已授权的浮点校正实际输出约 `5.000036239624023`。这是现有校正机制产生的微调，界面按两位小数显示为 `5.00`。
- 读写均发生在 `target/tmp/r4-unaligned-export-*` 的临时副本中。

日志中另有两次 `请输入有效的有限数值`。诊断没有记录输入文本，不能据此确定用户当时输入了什么。

## 验证结果

- `flutter analyze --no-pub` 无问题。
- Flutter 完整测试为 34 项通过。
- Rust 完整测试为 79 项通过。
- `cargo fmt --all -- --check` 通过。
- `flutter build windows --release --no-pub` 通过。
- `cargo build --workspace --release --locked` 通过。
- 真实实体数据同偏移导出回读验证通过。

Flutter 回归额外覆盖首屏错峰、减少动画、懒加载列表中的第 8 张之后的卡片、单帧滚动更新、停在半张卡片时自动归位、反向滚动保持列对齐、窗口缩放、卡片移动后点击命中，以及滚动和收尾不重建测试卡片内容。

## 本地包与复验

输出文件为以下三个路径，目录版也保留。

- `dist/SHODAN_4.6.0-r4.exe`
- `dist/SHODAN_4.6.0-r4_Windows.zip`
- `dist/SHODAN_4.6.0-r4_Windows_单文件.exe`
- `dist/SHODAN_4.6.0-r4_Windows/`

旧包在替换前已移入 `dist/.r4-before-scroll-repair-*`。每个源路径和目标路径均核对位于当前项目的 `dist` 中。

使用正式 `tools/package_morrow.py` 打包，`fontTools` 来自 `D:/agent/build-temp/shodan-r3-python`，仍执行图标子集检查。

包校验需要检查 ZIP CRC、条目集合、manifest 中每个文件的 SHA-256、目录与 ZIP 字节一致、UI 和数据核心与本轮构建字节一致、目录中的数据目录 build 与 manifest 一致，以及单文件别名一致。EXE 与 ZIP 均需小于 20,000,000 字节。

单文件验证入口为 `--verify-package`，当前源码明确在校验和解包后返回，不启动编辑器。验证使用独立 `LOCALAPPDATA`，30 秒超时后只结束本次创建的进程，不结束其他编辑器实例。

## 构建环境

Rust 使用 `D:/agent/tools/rust/cargo/bin`，并设置以下环境变量。

```powershell
$env:CARGO_HOME='D:/agent/tools/rust/cargo'
$env:RUSTUP_HOME='D:/agent/tools/rust/rustup'
$env:PATH='D:/agent/tools/rust/cargo/bin;'+$env:PATH
$env:TEMP='D:/agent/shodan-stat-editor-publish/target/tmp'
$env:TMP=$env:TEMP
```

Flutter 使用 `D:/agent/tools/flutter/bin/flutter.bat`，本轮采用的状态目录如下。

```powershell
$env:APPDATA='D:/agent/tools/flutter-dev-profile/roaming'
$env:LOCALAPPDATA='D:/agent/tools/flutter-dev-profile/local'
$env:PUB_CACHE='D:/agent/tools/flutter-pub-cache'
$env:FLUTTER_SUPPRESS_ANALYTICS='true'
$env:MSBUILDDISABLENODEREUSE='1'
$env:MSBUILDNOINPROCNODE='1'
```

Python 使用 `C:/Users/Administrator/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe`。打包时设置 `PYTHONPATH=D:/agent/build-temp/shodan-r3-python`。

执行 GitHub CLI 时使用正常登录环境。覆盖 `APPDATA` 后可能无法读取原有 GitHub 登录状态，应在独立命令中执行 GitHub 操作。

## 后续核对

- 在真实 Windows 环境手动检查慢速与快速滚动、缩放窗口、深浅色和玻璃材质下的表现。
- 用新测试包重试用户原来的安装方案，确认日志所示错误消失。
- 若无效数值提示可以重现，需要具体字段和输入文本才能继续定位。
