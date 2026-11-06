<div align="center">

<img src="assets/shodan-transparent.png" alt="SHODAN" width="88" />

# SHODAN 数值编辑器

《绝地潜兵 2》中文离线参数编辑器 · Windows x64

[![发行版](https://img.shields.io/github/v/release/127MU/SHODAN-Stat-Editor?label=发行版&color=7861c4)](https://github.com/127MU/SHODAN-Stat-Editor/releases/latest)
[![许可](https://img.shields.io/badge/License-GPL--3.0-398675)](LICENSE)

[下载发行版](https://github.com/127MU/SHODAN-Stat-Editor/releases) · [快速开始](#快速开始) · [问题反馈](https://github.com/127MU/SHODAN-Stat-Editor/issues) · [特别鸣谢](#特别鸣谢)

</div>

## 当前版本：4.6.0-r1

使用中文名称查找装备，在分类弹窗中调整参数，预览后统一写入游戏。新版桌面界面采用 **Flutter + Morrow**，支持玻璃材质、自定义背景与 MiSans 字体。

当前桌面版保留 **Flutter + Morrow** 界面，使用 **Rust 数据核心**。数值编辑、预设、写入与恢复、资源补丁、更新检查和 MCP 共用原生后端。正式打包从已校验的参数目录构建。已发布附件的功能以对应发行说明为准。 [迁移状态](docs/pure-rust-migration.md)

## 快速开始

1. 下载 Windows 发行附件。单文件版直接运行；ZIP 版请完整解压后运行 `SHODAN 数值编辑器.exe`。
2. 程序通过 Steam 安装信息寻找游戏。若未找到，在程序旁创建 `game folder.txt`，填写包含 `data` 文件夹的游戏根目录，再重新打开程序。
3. 选择左侧分类，搜索名称、型号或 ID，打开条目，再点击参数分类的 **“打开”**。
4. 输入数值后按 **回车**，或点击输入框外确认。开关直接切换；“恢复”还原对应参数。
5. **完全退出游戏**，点击 **“写入游戏”**，核对变化并确认。等待进度弹窗显示成功，再启动游戏。

> 确认输入和保存预设只保存编辑器配置；普通数值修改需要写入游戏后才会生效。

单文件版首次启动会释放内置运行文件，无需另外安装 Python、Qt 或 Lua。请使用与当前游戏数据版本兼容的编辑器。

## 编辑工作区

| 分类 | 内容 |
| --- | --- |
| 装备 | 主武器、副武器、支援武器、投掷物及强化增益 |
| 战略配备 | 冷却、次数、指令及对应组件参数 |
| 载具与机甲 | 本体、部件、挂载武器等可解析记录 |
| 护甲 | 护甲装备、逐护甲被动和多被动组合 |
| 潜兵 | 直接打开潜兵参数，不在护甲列表重复显示 |
| 敌人 | 单位属性与可解析的生成规则 |
| 数据与预设 | 底层数据记录及全局预设 |
| 游戏参数 | 准星、策略球部署、植被交互及受击与布娃娃补丁 |
| 设置 | 外观、背景、字号、日志与诊断 |

页面根据实际数据生成，并非每件装备都拥有相同参数。参数分类使用四列卡片，点击打开后在弹窗编辑；装备预设跟随当前选中的条目。参数页工具栏提供修改记录、撤销、重做、射击引用链和资源诊断；报告可独立搜索、导出。

### 数值、原值与共享影响

- **原值**来自可信的原版基准，不应把其他工具已经修改过的数值当作默认值。无法可靠取得的原值应视为未知。
- 浮点数最多显示 **两位小数**，底层精度保留；未编辑的输入框不会因为显示舍入而写回数值。
- 参数受实际存储类型约束：浮点数必须有限，整数必须可表示，引用 ID 必须有效。
- 多个装备可能共用同一伤害、弹丸或爆炸记录。编辑前留意 **共享影响** 和参数旁的说明。
- **特效资源包不改变实际发射类型**。更换弹丸应使用射弹选择，并核对实际发射来源。
- 标有 **实验性** 的字段仍需实机验证，能够读写不代表所有组合都可正常运行。

### 护甲与预设

护甲装备可设置对应被动，多被动组合可选择应用范围、是否保留原生被动及同类效果处理方式。点击“修改数值”进入被动数值弹窗。

装备预设只管理当前条目；全局预设用于保存整套修改，支持导入、导出及分享码。读取前检查差异与兼容提示。清空当前护甲组不会自动清空其他组。

### 资源补丁

资源驻留与状态机补丁有各自的确认操作，按照弹窗提示安装或移除。处理前关闭游戏，完成后重新启动。

资源驻留用于加载所需资源，不能保证任意装备与资源组合都兼容。状态机、挂载等实验性修改可能影响共享资源。具体说明见 [资源驻留与状态机](docs/residency-and-state-machine.md)。

## 外观与操作

设置支持深浅色模式、自定义图片背景、背景遮罩、字号，以及玻璃、磨砂和透明材质。卡片与参数弹窗使用同一材质设置，外观配置会在重启后恢复。

参数输入支持回车或离焦确认。关闭窗口直接退出，不出现退出前保存页面；需要复用的配置请事先保存为预设。

## 安装进度与诊断

写入操作在当前窗口内显示预览和进度弹窗，包括动态指示、实际处理阶段、阶段内文件计数及完成结果。进度来自安装流程，不使用模拟百分比。

遇到启动、空白、卡顿或写入失败，可在 **设置 → 日志与诊断**：

1. 运行 **只读诊断**，检查运行文件、数据引擎和游戏目录，不写入游戏。
2. 必要时开启 **诊断模式**，重现问题，记录接口耗时与安装阶段。
3. 点击 **导出诊断日志**，选择 JSON 文件保存位置；安装结果弹窗也提供导出入口。

日志只保存在本地，**不会自动上传**。导出时会替换用户目录和当前用户名，并过滤已识别的凭据；详细诊断不记录输入参数或预设正文。分享前仍可自行查看导出内容。

反馈请附上程序版本、游戏 build、Windows 版本、操作步骤、具体装备与参数，以及脱敏后的日志或截图。

## 常见问题

**修改后没有效果？**

确认写入成功并重启游戏；核对当前装备、实际射弹、对应记录和共享影响。资源加载与发射类型是不同设置。

**写入提示权限不足或文件已改变？**

关闭游戏及其他编辑工具，检查报错目录是否可写。编辑期间文件被其他程序改变时，重新打开编辑器读取数据。不要删除原始备份来绕过错误。

**游戏更新或使用过其他编辑器？**

先核对版本兼容性，再重新打开程序。若原版数据无法确认，先通过 Steam 验证游戏文件完整性，不要将未知数据强行写回。

**配置和日志在哪里？**

通常位于 `%LOCALAPPDATA%\SHODAN\StatEditor`。显式指定 `SHODAN_PROFILE` 时以该目录为准。单文件版释放的运行文件与用户配置分开存放。

## 开发与构建

| 部分 | 实现 |
| --- | --- |
| 桌面界面 | Flutter / Dart，Morrow 玻璃组件与着色器 |
| 启动器、数据解析与写入 | Rust |
| 字体 | MiSans 字符子集，保留中英文及常用符号 |

在仓库根目录构建 Rust 宿主，再构建 Flutter Windows 界面：

```sh
cargo build --release --workspace
cd desktop/morrow
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

Windows 构建需要 Visual Studio C++ 桌面工具链。打包使用随源码提供的参数目录和可信原值，并校验图标字体与 20 MB 体积限制。 [桌面构建说明](desktop/morrow/README.md)

## 特别鸣谢

- **[deepseekv41flash / hd2-datamined](https://github.com/deepseekv41flash/hd2-datamined)**：公开的数据结构、字段字典、本地化索引、资源加载和状态机研究，为功能核对与排错提供依据。
- **[deepseekv41flash / hd2-srkit](https://github.com/deepseekv41flash/hd2-srkit)**：Stingray 与游戏资源研究工具。
- **[deepseekv41flash / hd2-network-proxy](https://github.com/deepseekv41flash/hd2-network-proxy)**：公开的网络协议研究与技术资料。
- [SHODAN-HORAI / SHODAN-Stat-Editor](https://github.com/SHODAN-HORAI/SHODAN-Stat-Editor) 与 [CarbonAnime / SHODAN-Stat-Editor](https://github.com/CarbonAnime/SHODAN-Stat-Editor)：编辑器核心、扩展与项目贡献。
- [StarrySky7D4 / Morrow](https://github.com/StarrySky7D4/morrow)：当前界面使用的玻璃组件与视觉效果。
- [HuskarUI](https://github.com/mengps/HuskarUI)：此前桌面版本使用的组件、图标与主题系统。
- [filediver](https://github.com/xypwn/filediver)：公开的资源解析工具与资料。
- 提供中文对照表、代码、测试结果和问题反馈的所有贡献者。

## 许可

项目许可见 [LICENSE](LICENSE)。第三方组件遵循各自许可；Morrow 的许可与声明见 [MORROW-LICENSE](desktop/morrow/MORROW-LICENSE) 和 [NOTICE](desktop/morrow/NOTICE.md)，发行包保留相关第三方声明。
