# SHODAN 维护交接手册

交接日期为 **2026-11-09（香港时间）**。本文记录当前稳定版与测试版、发布流程、排障入口和未验收事项。环境搭建、模块索引和开发约定见[开发指南](development-guide.md)。

[版本基线](#一接手基线) · [配置和备份](#二配置草稿和备份) · [发布流程](#三发布下一版) · [故障排查](#四故障排查) · [后续任务](#五后续任务与历史资料) · [交接清单](#六下一次交接至少记录什么)

## 一、接手基线

| 项目 | 交接时的状态 |
| --- | --- |
| 发布仓库 | [127MU/SHODAN-Stat-Editor](https://github.com/127MU/SHODAN-Stat-Editor)，默认分支 `main` |
| 当前稳定版 | [v4.6.0-r5](https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/v4.6.0-r5)，Windows x64 |
| 当前测试版 | [4.6.0-r5.1 dev](https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/dev)，预发布，不替代稳定版 latest |
| 测试版构建源码 | `097a2a4050495a2362cc79532b79792c740745fd`；后续纯文档提交不改变该二进制来源 |
| 历史 r2 CI 记录 | [Windows 构建检查](https://github.com/127MU/SHODAN-Stat-Editor/actions/runs/42204619586)，对应 PR 源码提交 `7be3a499cc702fcb04cd3731cfe99d0d29418ff2` |
| 游戏数据 | 交接基线对应游戏 build `26251122`。以随包目录记录的 `game_build` 校验游戏 `game.dll`，完整 SHA-256 为 `61dcfcd201dacbf3545c97beb8a5a6186e9850d2670bf60b0e058320b477f6df` |
| 当前参数目录 | 1,983 个条目、70,559 行静态参数、67,552 个字段描述；Rust 运行时补充后共 71,811 行。逻辑参数可共享或组合字段，计数含义不同 |
| 本地 Git 遥控 | 本工作副本的 `fork` 指向发布仓库，`origin` 指向 CarbonAnime 的上游参考。其他克隆的命名可能不同，操作前检查地址 |

### r5.1 dev 交付与验收

本地通过 96 项 Rust 核心测试、1 项启动器测试、63 项 Flutter 测试及相关隔离集成回归。预设库、浮点输入和坏表修复分别见[预设库说明](preset-library.md)及[数值审计](numeric-input-and-repair-audit.md)。本次交付没有以云端构建替代本地产物，也没有逐件验证游戏局内效果。

| 测试附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `SHODAN_4.6.0-r5.1_Windows_Single.exe` | 18,884,196 | `a0f0c5200b0942cad1591bdd430ddd3ab2ae52ee3a5f57a39c3022bace8f987e` |
| `SHODAN_4.6.0-r5.1_Windows.zip` | 18,491,863 | `b57ff6394672ed5afc0b86fc03dcd22a47fba035cd9920b4fedb548eade890c7` |

### 历史 r2 变更与验收记录

- 护甲被动弹窗关闭前等待保存结果，重新打开时读取修改后的值。保存失败保留输入，可在原弹窗修正或重试。
- 窗口控件移到独立标题栏。弹窗打开时可用，任务栏恢复时重新读取最大化状态。
- Windows 打包的 JSON 输出可在不支持中文的输出编码下打印。压缩包内实际文件名保持原样。
- 本地通过 75 项 Rust 测试、26 项 Flutter 测试和隔离游戏数据回归。Windows GitHub Actions 通过。单文件与 ZIP 均在本地编译打包并校验。
- 隔离回归验证了被动数值跨数据服务重启保存。标题栏覆盖了 Flutter 窗口消息和交互回归。此记录没有覆盖所有 Windows 显卡、多屏缩放组合或游戏局内表现。

| 发行附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `SHODAN_4.6.0-r2.exe` | 18,296,182 | `88f344f64cf092bb59a23a404975d6ee2bb83f21a692bc5b616ed520f8a322d3` |
| `SHODAN_4.6.0-r2_Windows.zip` | 17,906,193 | `9eb20b654fe33f35937834799abaae897b29396fc30624feb7b474d15e782477` |

以上 r2 附件仅为历史记录。当前 r5.1 附件从 `dev` 发行页下载；`dist/` 为本机产物，不随 Git 克隆。下载和更新入口应使用 GitHub 的发行页或 `/releases/download/<tag>/<文件名>`。浏览器重定向后的 `release-assets.githubusercontent.com` 签名地址有有效期，下载失败时回到正式链接重新获取。

## 二、配置、草稿和备份

默认配置根目录是 `%LOCALAPPDATA%\SHODAN\StatEditor`。设置 `SHODAN_PROFILE` 可为一轮测试指定独立配置。正式数据排障时先确认用户实际使用的配置根，避免误读另一份工作区。

| 位置 | 用途 | 接手注意事项 |
| --- | --- | --- |
| `morrow-ui.json` | 深浅色、玻璃材质、背景、字号及诊断开关 | 界面问题优先在独立配置下复现。背景可能是用户本机的文件路径 |
| `preset-library.json` | 命名预设组合与 TXT 分享库 | 导入仅存库，读取才应用草稿；保留作者自定义名称 |
| `native-presets.json` | 原有槽位与全局预设 | 新库不重写此文件，迁移前保留备份 |
| `game folder.txt` | 手动指定游戏安装位置 | 文件中只写一条路径，通常填写包含 `data` 的游戏根目录。先查配置根、启动器目录和运行目录，再查 Steam 安装信息 |
| `native-game/<安装路径指纹>/draft.json` | 当前待写入草稿和编辑器会话元数据 | 工作区按规范化安装路径分开。更换 Steam 库路径后应先确认正在读哪个工作区 |
| 同级的 `configuration.json` | 当前已安装的编辑器配置元数据 | 用于重新打开时读取已安装状态。恢复原版和保留编辑草稿可同时发生 |
| 同级的 `managed.json` | 受管数值文件与已安装、原始备份指纹 | 与事务备份配套。恢复报错时先保留证据 |
| 同级的 `transactions/` 和 `recovery/` | 安装、恢复事务及原始字节 | 保留 `journal.json`、`*.original`、提交与恢复标记。手工改动这些文件会破坏回滚判断 |
| 同级的 `residency.json` | 编辑器管理的资源驻留记录 | 确认补丁属于哪个宿主包、槽位及伴生文件 |
| 配置根的 `Logs/morrow-*.log` | 会话日志 | 反馈时优先从界面导出脱敏 JSON。无需收集用户整份配置或游戏数据 |
| `%LOCALAPPDATA%\SHODAN\DesktopRuntime` | 单文件 EXE 的解包缓存，按负载指纹分目录 | 运行缓存与配置分离。用户目录无法写入时启动器还会尝试临时目录。启动失败可用完整解压的 ZIP 版做对照 |

在隔离环境复现时，用新的配置目录和已复制的游戏数据。仅切换 `SHODAN_PROFILE` 只能隔离编辑器状态，游戏写入目标仍取决于选中的安装路径。集成测试隔离步骤见[开发指南](development-guide.md#使用隔离数据进行集成回归)。

## 三、发布下一版

### 提交和合并

1. 用 `git remote -v` 确认发布仓库所在的遥控，在新分支或独立 worktree 从它的最新 `main` 开始。历史 PR 分支和未跟踪的本地试验文件保留在原工作区。
2. 同步以下版本位置。以现有命名规则递增小版本，Flutter 的内部构建号也应递增。
   - [Rust 包版本](../rust/core/Cargo.toml)和 [Cargo.lock](../Cargo.lock)。
   - [Flutter 包版本](../desktop/morrow/pubspec.yaml)和[界面版本常量](../desktop/morrow/lib/app_version.dart)。
   - [README 的当前版本](../README.md)。解析历史版本的单元测试夹具按测试意图更新。
3. 按开发指南执行测试与本地编译。PR 写明用户可见变化、复现步骤、验证结果和实机验证范围。检查目标分支、提交 SHA 和 Actions。
4. 确认 PR 检查通过并获准合并后再合并。核对待发布提交的源码树与本地打包所用提交一致。如果合并后的内容发生变化，从合并后的提交重新构建。

### 本地打包与发布附件

当前附件命名为 `SHODAN_<版本>_Windows_Single.exe` 与 `SHODAN_<版本>_Windows.zip`。更新检查优先匹配同版本的单文件名，发行说明应包含用户可见的变更。以下版本和两个提交 SHA 均为占位值，发布前替换为实际值。构建时记录所用提交，确认已经运行[开发指南中的本地构建](development-guide.md#编译和单元测试)，且输出名尚未使用。

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = '127MU/SHODAN-Stat-Editor'
$version = '4.6.0-rX'
$tag = "v$version"
$commit = '已验证的合并提交SHA'
$builtCommit = '本地编译所用提交SHA'
git diff --exit-code $builtCommit $commit
git diff --exit-code $commit --

$base = "dist/SHODAN_${version}_Windows"
$exe = "dist/SHODAN_${version}_Windows_Single.exe"
$zip = "$base.zip"
python tools/package_morrow.py --output $base
if (Test-Path -LiteralPath $exe) { throw '发行 EXE 已存在，请使用全新的输出路径' }
Copy-Item -LiteralPath "${base}_单文件.exe" -Destination $exe
$result = Start-Process -FilePath (Resolve-Path -LiteralPath $exe).Path -ArgumentList '--verify-package' -WindowStyle Hidden -Wait -PassThru
if ($result.ExitCode -ne 0) { throw '单文件校验失败' }
Get-FileHash -LiteralPath $exe, $zip -Algorithm SHA256
```

按照[开发指南的打包检查](development-guide.md#本地打包与检查)核对 ZIP、`manifest.json` 版本号和文件哈希。手测两种附件启动到主界面、识别游戏目录、检查版本和下载入口。记录测试版本、附件 SHA-256、测试系统和结果。发布经授权的正式版时，将实际更新说明保存成 UTF-8 文本文件，再执行下列命令。

```powershell
gh release create $tag $exe $zip --repo $repo --target $commit --title "SHODAN $version" --notes-file 'dist/release-notes.md' --latest
gh release view $tag --repo $repo --json url,isDraft,isPrerelease,targetCommitish,assets
```

确认 tag 指向目标提交，发行版已公开，两个附件的文件名、大小和摘要与本地产物一致。公开发行版有回归时，保留原 tag，通过修复 PR 与新版本号发布替代版本，并在说明中指明影响与用户侧恢复步骤。

### dev 测试版规则

测试发行使用固定标签 `dev`，标题写完整版本，创建时用 `--prerelease --latest=false`。`--target` 使用完整提交 SHA。只有明确要求更新测试包时才移动标签或替换附件；如需移动已有标签，先读取远端 SHA，并用针对旧 SHA 的 `--force-with-lease`，避免覆盖别人更新。上传后复核标签、源码提交、附件名称、大小与摘要。纯文档更新只推送分支，不移动 `dev` 标签或重新上传二进制。

## 四、故障排查

收集最少信息即可开始。记录编辑器版本与附件类型、游戏 build、Windows 版本、具体操作顺序、装备或字段名、完整错误信息和脱敏诊断。标题栏问题另记录是否处于弹窗、最大化、从任务栏恢复、多显示器切换或自定义缩放。资源问题区分粒子、模型、震屏和声音。

| 现象 | 先做什么 | 对应代码或数据 |
| --- | --- | --- |
| 输入 2 后未保存或小数过长 | 区分显示值、原始值和用户提交。覆盖明确回车、编辑后离焦、只聚焦离焦；整数形式与浮点形式应写成同一 f32。哈希空间不足时的低位微调另需用户确认 | [输入状态](../desktop/morrow/lib/number_display.dart)、[数值审计](numeric-input-and-repair-audit.md) |
| LDLD 无效或表边界错误 | 定位具体文件，核对是否已隔离；修复仅接受同版本可信备份或随包原值，不能跳过结构检查强行写入 | [自动修复](automatic-repair.md) |
| 预设导入后参数没变 | 导入只存库；选择组合并读取才应用草稿，再点击写入游戏。检查识别到的条目及共享冲突 | [预设库](preset-library.md) |
| 被动数值关窗后恢复原样 | 用同一被动改一个可辨认的值，分别验证回车、点出输入框和直接关闭。比较同次会话、重启界面、重启后写入预览三处的值。检查保存失败提示和 `armor_set` 记录 | [被动弹窗](../desktop/morrow/lib/armor_page.dart)、[原生被动接口](../rust/core/src/desktop_armor.rs)、`draft.json` |
| 右上角按钮偶尔消失或无法点击 | 从无弹窗状态开始，逐步打开编辑弹窗、最大化、还原、最小化后恢复。观察按钮是否被遮罩拦住、是否更新图标和提示。记录显示器缩放比例 | [桌面框架](../desktop/morrow/lib/desktop_frame.dart)、[窗口回归测试](../desktop/morrow/test/desktop_frame_test.dart) |
| 单文件双击无窗口、解包失败或 ZIP 提示缺文件 | 先核对附件摘要。单文件执行 `--verify-package` 并检查退出码，ZIP 完整解压到独立目录后对照。窗口空白与缺少运行文件分开记录 | [单文件启动器](../rust/core/src/bin/shodan-portable.rs)、[桌面 runner](../desktop/morrow/windows/runner/) |
| 提示参数目录不匹配或原值未知 | 确认 Steam 版本和 `game.dll` 指纹，检查是否选错游戏副本。原值未知时确认版本及可信备份，再决定是否通过 Steam 校验游戏文件 | [游戏工作区](../rust/core/src/game_workspace.rs)、[可信原值](../rust/core/src/baseline.rs) |
| 写入失败、权限不足或报告外部修改 | 退出游戏和其他编辑器，保留完整报错与事务日志。检查目标文件是否被更新或锁定。重新打开编辑器获取新快照后再预览 | [安装事务](../rust/core/src/install.rs)、`managed.json`、`transactions/` |
| 检测到未完成事务或恢复失败 | 先保全受管文件和配置根，核对错误是备份缺失、目标已改变还是日志中断。使用程序恢复流程处理，恢复结果应再次核对文件指纹 | [恢复入口](../rust/core/src/game_workspace.rs)、`transactions/`、`recovery/` |
| 资源补丁装上但游戏里无效果 | 分别核对当前射弹、来源包、依赖解析和补丁伴生文件，再按装备做实机对照。声音单独核对 Wwise 事件身份与实际播放 | [资源解析器](../rust/core/src/resource_resolver.rs)、[资源驻留参考](residency-and-state-machine.md) |
| 软件提示新版本却无法下载 | 从正式发行页重试，确认附件是公开的稳定版且文件名匹配。检查 API 结果、回退来源和返回的正式下载链接 | [更新检测](../rust/core/src/update.rs)、[更新弹窗](../desktop/morrow/lib/release_updates.dart) |

### 回归检查顺序

1. **只读核对。** 查看错误、打开工作区、复现 UI、导出脱敏诊断。
2. **隔离写入。** 在游戏数据副本上验证预览、写入、重开与恢复，确认变动只覆盖预期文件。
3. **实机验证。** 涉及弹道、动画、音效或资源加载时，记录具体装备、参数、build、场景和观察结果。单独复测一项后再组合。
4. **交付复核。** 检查 CI、版本、附件摘要、发行说明和更新入口。留存能复现问题的最小测试记录。

## 五、后续任务与历史资料

- **需要额外覆盖的回归。** Windows 多显示器、高 DPI、任务栏还原与不同图形驱动的标题栏行为适合在接手后扩展手测矩阵。按「新配置 / 现有配置」区分结果。
- **游戏版本适配。** 收到新 build 后，先确认当前目录和旧基准的差异，再更新目录映射。先通过无改动预览、单字段离线回读和恢复，再测试资源与组合字段。
- **新增字段。** 先核对当前源码是否已有入口，再查适用 build、存储类型、基准及引用关系，避免把旧研究清单当作当前缺失功能。
- **当前维护边界。** Flutter/Morrow 负责 UI，Rust 负责数据核心。变种代理、Mod 管理和旧 Lua/Huskar 宿主属于历史范围。旧的兼容记录、页面优化和迁移对照资料保留了当时的设计与实测，接手时以现行源码、当前 CI 和对应版本的发行说明为准。
- **实机证据。** 资源依赖报告中的声音事件匹配、状态机和挂载实验只能说明各自已核对的部分。发布时对未逐件实测的功能标明实验范围。

## 六、下一次交接至少记录什么

- 日期、游戏 build 及指纹、编辑器版本、PR 与对应提交。
- 新增或修改的代码入口、配置格式、参数目录来源和兼容约束。
- 复现步骤、测试命令、实际结果与仍需验证的场景。
- 发行附件名、SHA-256、Actions 记录和恢复路径。
- 能继续推进的事项、阻塞原因和需要补齐的证据。账号令牌、私有路径和原始用户配置留在本机。
