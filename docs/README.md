# 文档导航

更新日期：2026-11-09（香港时间）。当前稳定版为 **4.6.0-r5**，测试版为 **4.6.0-r5.1**，测试发行标签为 [`dev`](https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/dev)。

## 使用指南

| 文档 | 内容 |
| --- | --- |
| [项目首页](../README.md) | 下载、快速开始、分类与常见问题 |
| [预设库与 TXT 分享](preset-library.md) | 自定义名称、单件 / 多件战备、整套导出、文件拖入和粘贴导入 |
| [编辑流程](editing-workflow.md) | 参数弹窗、保存、原值、共享影响与写入 |
| [自动修复](automatic-repair.md) | 设置入口、坏表隔离、备份和恢复范围 |
| [安装失败处理](installation-failure-repair.md) | 不同错误的修复能力及强制写入 / 恢复边界 |
| [诊断日志](diagnostic-logging.md) | 复现、脱敏导出与诊断字段 |
| [已有差异整理](baseline-difference-cleanup.md) | 核对启动前存在的差异，不把修改值当成默认值 |
| [资源驻留与状态机](residency-and-state-machine.md) | 资源补丁与实验性配置；按文中适用 build 核对 |
| [护卫犬配置](guard-dog-configuration.md) | 无人机武器替换与支持范围 |
| [小队运输](squad-transport.md) | 运输组件字段与验证范围 |

## 开发与交接

| 文档 | 内容 |
| --- | --- |
| [开发指南](development-guide.md) | 环境、模块入口、构建与隔离测试 |
| [维护交接](maintainer-handover.md) | 源码与发行基线、配置、附件摘要及发布流程 |
| [Windows 桌面构建](../desktop/morrow/README.md) | Flutter / Rust 构建、文件拖入插件和打包 |
| [Rust 核心迁移](pure-rust-migration.md) | 现行运行链与语言边界 |
| [r5.1 数值及修复核对](numeric-input-and-repair-audit.md) | 浮点输入、全量原值扫描与坏表修复证据 |
| [载具组件补充](pr149-vehicle-components.md) | 参数表布局及验证 |
| [弹窗过渡](dialog-aperture-motion.md) | 当前弹窗动效与减少动画处理 |

## 历史记录

以下文档保留当时的版本与验证结果，不能据此推断当前界面仍有相同入口、所有旧功能已验收，或当前游戏版本仍匹配。

- [桌面重构保留清单](desktop-function-parity.md)、[早期迁移](rust-morrow-migration.md)。
- [r4 交接](handoff-r4-draft-and-card-reveal.md)、[r4.1 审计](audit-r41-20261108.md)、[r4.2 诊断修正](post-r42-diagnostic-fixes.md)。
- [2026-11-08 项目复查](project-review-20261108.md)、[build 26251122 兼容记录](compatibility-build26251122.md)。

涉及代码行为时，以现行源码、对应发行版说明及明确标注的测试范围为准。离线验证不等于游戏局内效果已逐项验证。
