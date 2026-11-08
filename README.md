<div align="center">

<img src="assets/shodan-transparent.png" alt="SHODAN 标志" width="96" />

# SHODAN 数值编辑器

**查找装备 · 调整参数 · 分享预设**

面向《绝地潜兵 2》的中文离线参数编辑器，适用于 Windows x64。

[![稳定版](https://img.shields.io/github/v/release/127MU/SHODAN-Stat-Editor?label=稳定版&color=7861c4)](https://github.com/127MU/SHODAN-Stat-Editor/releases/latest)
[![许可](https://img.shields.io/badge/License-GPL--3.0-398675)](LICENSE)

[下载](#下载) · [开始使用](#开始使用) · [分享预设](#预设与分享) · [使用文档](docs/README.md) · [反馈问题](https://github.com/127MU/SHODAN-Stat-Editor/issues)

</div>

SHODAN 将装备、战备、载具、护甲和敌人数据整理为可搜索的中文目录。选择条目后，在分类弹窗中编辑参数，查看原值与共享影响，最后预览并统一写入游戏。

界面采用 Flutter + Morrow，支持玻璃材质、自定义图片背景与 MiSans 字体。数据解析、编辑、预设、资源补丁及安装恢复由 Rust 实现，运行时无需 Lua。

## 下载

| 通道 | 当前版本 | 入口 |
| --- | --- | --- |
| 稳定版 | **4.6.0-r5** | [下载稳定版](https://github.com/127MU/SHODAN-Stat-Editor/releases/latest) |
| 测试版 | **4.6.0-r5.1 dev** | [查看说明与附件](https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/dev) |

**r5.1 测试版直达：** [单文件 EXE](https://github.com/127MU/SHODAN-Stat-Editor/releases/download/dev/SHODAN_4.6.0-r5.1_Windows_Single.exe) · [完整 ZIP](https://github.com/127MU/SHODAN-Stat-Editor/releases/download/dev/SHODAN_4.6.0-r5.1_Windows.zip)

单文件版直接运行，首次启动会释放运行文件；ZIP 版需完整解压后启动。无需另装 Python、Qt 或 Lua。r5.1 的单文件附件约 18.9 MB。

> 下文包含 r5.1 测试版功能，稳定版请以对应发行说明为准。`dev` 不替代稳定版；游戏更新后，请先确认编辑器与游戏数据版本匹配。

## 可以编辑什么

| 工作区 | 主要内容 |
| --- | --- |
| 装备 | 主武器、副武器、支援武器、投掷物、强化增益与配件 |
| 战略配备 | 冷却、使用次数、战备指令及对应组件 |
| 载具与机甲 | 本体、部件、挂载武器；关联条目集中选择 |
| 护甲与潜兵 | 护甲被动、多被动组合、被动数值和潜兵参数 |
| 敌人 | 单位属性、阵营及可解析的生成规则 |
| 数据库 | 射弹、伤害、爆炸及其他底层记录 |
| 游戏参数 | 策略球部署、植被交互、受击与布娃娃等设置 |

参数页提供搜索、仅已修改、恢复本项、修改记录、撤销与重做，以及射击引用链、共享影响和资源诊断。具体可编辑项由当前数据决定，各装备不一定拥有相同字段。

## 开始使用

1. **找到游戏。** 程序会搜索 Steam 安装目录。未找到时，在程序旁创建 `game folder.txt`，填入包含 `data` 文件夹的游戏根目录，再重新打开。
2. **选择条目。** 点击侧边栏分类，搜索名称、型号或 ID，再打开需要编辑的装备或数据。
3. **修改参数。** 点击参数分类卡片的「打开」。输入数值后按回车，或点击输入框外确认；开关与选择器直接提交。
4. **核对影响。** 查看原值、修改记录和共享影响，需要复用时保存预设。
5. **写入游戏。** 完全退出游戏，点击「写入游戏」，检查预览并确认。等待进度弹窗显示成功，再启动游戏。

**输入确认 → 编辑草稿；读取预设 → 应用到编辑区；写入游戏 → 修改游戏文件。**

### 编辑时需要了解

- **原值与当前值分开保存。** 原值来自可信的同版本基准；其他工具留下的修改不会被当成新默认值。无法确认时显示未知。
- **显示精度不等于保存精度。** 浮点值最多显示两位小数，底层保留完整精度。r5.1 支持直接提交 `2`，无需补写一串小数；只查看输入框不会将舍入值写回。
- **共享字段可能影响多件装备。** 更换射弹或修改伤害、爆炸等记录前，可查看「共享影响」。
- **资源包与发射类型分开设置。** 特效资源包负责加载资源；更换实际弹丸请使用射弹选择，并核对发射来源。
- **实验性字段需要实机核对。** 离线读写通过不代表任意组合的游戏表现都已验证。

## 预设与分享

r5.1 新增独立 **预设库**，用「切换预设」管理自己的命名方案。

| 需求 | 操作 |
| --- | --- |
| 保存一件或多件战备 | 选择「保存单件 / 多件战备」，搜索勾选条目，填写名称 |
| 保存整套参数修改 | 选择「保存整套修改」 |
| 发送给别人 | 导出当前预设或全部预设为 TXT，也可以复制分享文本 |
| 接收别人的方案 | 拖入 TXT / JSON、选择文件，或粘贴导入 |
| 使用已保存方案 | 选择预设，查看内容，再点击「读取预设」 |

拖入未松开时显示导入提示；松开后播放识别动画，确认识别到的名称与条目后再保存。导入会保留作者自定义名称，并按条目标识匹配目标。

**导入只存入预设库，不会立即改动参数或游戏文件。** 读取后仍需点击「写入游戏」。同一装备的不同方案可以分别保留，原有装备槽位和全局预设入口也继续保留。

[查看格式、容量限制与兼容说明 →](docs/preset-library.md)

## 外观与日常操作

- 深浅色切换、自定义强调色、图片背景、背景遮罩与字号调整。
- 玻璃、磨砂等材质用于卡片和参数弹窗，外观设置重启后保留。
- 分类卡片、页面和弹窗使用过渡动效，可按需调整动画。
- 写入、恢复和修复在当前窗口显示处理阶段与结果，进度来自实际流程。
- 设置中提供更新检查及本地 MCP 开关与配置。

资源驻留和状态机补丁另有确认操作。它们与参数预设用途不同，分享参数不会同时发送资源包或音效。[资源功能说明 →](docs/residency-and-state-machine.md)

## 遇到问题

| 情况 | 建议处理 |
| --- | --- |
| 修改后没有效果 | 确认写入成功并重启游戏，核对实际装备、射弹及共享记录 |
| 很多条目标记「与原值不同」 | 查看具体差异；该标签也可能来自此前的工具或 Mod。可用「整理已有差异」逐项核对 |
| 原值未知、游戏更新或用过其他工具 | 先核对版本和游戏副本；不要把现有修改值设为默认值 |
| 写入失败、坏表或登记冲突 | 退出游戏及其他编辑工具，在「设置 → 自动修复」查看处理结果 |
| 启动空白、卡顿或仍无法安装 | 开启诊断模式复现，运行只读诊断，再导出脱敏日志反馈 |

自动修复会检查中断事务、草稿、安装登记和资源补丁。r5.1 可隔离无法解析的数值表，保留其余可读内容；修复前先备份，并仅从匹配版本的可信来源恢复。

安装或预览失败时提供「强制写入」，恢复失败时提供「强制恢复」。这些入口仍检查版本、结构、备份和磁盘访问；损坏表、文件占用或缺少可信备份时会报告具体原因。部分表的校验需要用户允许对已修改浮点值做极小修正，结果会说明实际变化。

[自动修复](docs/automatic-repair.md) · [安装失败处理](docs/installation-failure-repair.md) · [诊断日志说明](docs/diagnostic-logging.md)

日志只保存在本地，不自动上传。导出会替换用户名和用户目录，并过滤已识别凭据；不记录输入参数或预设正文。反馈请附程序版本、游戏 build、Windows 版本、操作步骤及脱敏日志。

配置通常位于 `%LOCALAPPDATA%\SHODAN\StatEditor`；使用 `SHODAN_PROFILE` 时以指定目录为准。请保留备份和事务记录。

## 开发与文档

界面使用 **Flutter / Dart + Morrow**，数据核心和单文件启动器使用 **Rust**。Windows 构建需要 Visual Studio C++ 桌面工具链，依赖版本以锁文件和构建文档为准。

- [文档导航](docs/README.md)：使用指南、技术说明与历史记录。
- [开发指南](docs/development-guide.md)：模块入口、接口约定、构建与隔离测试。
- [维护交接](docs/maintainer-handover.md)：配置、发行基线、附件摘要和发布流程。
- [桌面构建](desktop/morrow/README.md)：编译、插件、字体子集和打包。
- [Rust 迁移状态](docs/pure-rust-migration.md)：运行链和语言边界。

## 特别鸣谢

- **[deepseekv41flash / hd2-datamined](https://github.com/deepseekv41flash/hd2-datamined)**：游戏数据结构、字段字典、本地化索引、资源加载和状态机研究。
- **[deepseekv41flash / hd2-srkit](https://github.com/deepseekv41flash/hd2-srkit)**：Stingray 与游戏资源研究工具。
- **[deepseekv41flash / hd2-network-proxy](https://github.com/deepseekv41flash/hd2-network-proxy)**：公开的网络协议研究与技术资料。
- [SHODAN-HORAI / SHODAN-Stat-Editor](https://github.com/SHODAN-HORAI/SHODAN-Stat-Editor) 与 [CarbonAnime / SHODAN-Stat-Editor](https://github.com/CarbonAnime/SHODAN-Stat-Editor)：编辑器核心、扩展与项目贡献。
- [StarrySky7D4 / Morrow](https://github.com/StarrySky7D4/morrow)：当前界面的玻璃组件与视觉效果。
- [HuskarUI](https://github.com/mengps/HuskarUI)：此前桌面版本的组件、图标与主题系统。
- [filediver](https://github.com/xypwn/filediver)：资源解析工具与资料。
- 提供中文对照表、代码、测试结果和问题反馈的所有贡献者。

## 许可

本项目采用 [GNU GPL v3](LICENSE)。第三方组件与字体遵循各自许可，发行包保留相关声明：

[Morrow 许可](desktop/morrow/MORROW-LICENSE) · [第三方声明](desktop/morrow/NOTICE.md) · [desktop_drop 许可](desktop/morrow/DESKTOP-DROP-LICENSE)
