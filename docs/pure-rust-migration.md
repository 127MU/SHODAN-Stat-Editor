# Rust 数据核心迁移

桌面界面继续使用 Flutter 和 Morrow。Windows 桌面程序通过本地标准输入和输出连接 Rust 数据进程，单文件启动器也由 Rust 实现。常规构建直接使用已绑定游戏版本的参数目录，发行附件和 CI 构建均无需 Lua、LuaJIT 或旧宿主 DLL。

| 范围 | 当前实现 |
| --- | --- |
| 工作区 | Steam 路径发现、可信原值、数值与枚举编辑、跨记录引用、草稿持久化、撤销与重做 |
| 预设 | 装备与敌人预设、全局预设、被动组合与数值、旧格式导入和分享码 |
| 写入与恢复 | 密封数据编解码、原版哈希校正、备份、写入预览、回滚及恢复时保留草稿 |
| 战备 | 指令、附赠校验、常驻战备、替换射弹的来源包、同类载具配装开关 |
| 资源 | 按身份解析资源、追踪射弹和爆炸依赖、匹配 Wwise 事件、管理补丁槽位、同步同一资源的驻留副本 |
| 其他入口 | 游戏内文字、炮塔状态机、布娃娃、原生更新任务、本地 MCP、诊断脱敏 |

参数目录与游戏可执行文件指纹绑定。目录随包提供，物理数值由工作区读取。旧宿主和旧桌面界面可从 Git 历史检出。历史对照导出工具只接受独立参考目录，常规构建直接使用 Rust 参数目录。旧补丁只有通过当前来源包和伴生文件校验后才会纳入新版管理。游戏内的声音和实验性组合效果仍须实机核对。

## 本地验证

1. 在仓库根目录执行 `cargo test --workspace --locked` 和 `cargo build --workspace --release --locked`。
2. 在 `desktop/morrow` 执行 `flutter pub get --enforce-lockfile`、`flutter test --no-pub` 和 `flutter build windows --release --no-pub`。
3. 安装 Python 的 `fonttools` 后，从根目录执行 `python tools/package_morrow.py --output dist/SHODAN_Windows`。
4. `tests/test_native_desktop.py` 通过隔离的游戏数据副本核对桌面接口、写入、恢复和补丁。资源包只作为读取来源。
