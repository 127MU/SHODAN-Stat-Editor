# Rust 数据核心重构

4.6.0 已独立发布。后续迁移在 `refactor/pure-rust-core` 分支进行。按最新要求，Flutter/Morrow 界面保留，界面之外的解析、编辑、预设、资源补丁、安装恢复及诊断逻辑全部迁移至 Rust，不保留 Lua 运行依赖。

## 当前完成

- 新增独立的 `shodan-native` 可执行文件，不加载 Lua、Flutter、LuaJIT 或兼容宿主。
- Rust 原生 LDLD 索引：识别重复类型的数据块，保留块前的非零元数据，校验头部和载荷边界，拒绝无法解析的后缀。
- Rust 编辑文档：磁盘快照、可信原始数据和待应用修改分别保存。原始数据缺失时不提供虚假的恢复值。
- 数值修改限制在数据块载荷内，拒绝重叠修改与打开后发生变化的磁盘文件。此阶段仅在内存生成字节，不安装游戏文件。
- 测试覆盖浮点位解释、负重力、大数值、修改值不冒充原值、布局不匹配、错误输入与截断数据。
- 原生 NaCl 密封文件编解码采用 RustCrypto `crypto_box`；SHA-256 与游戏使用的 Murmur64 校验均不依赖 DLL。6 份本地原始数据完成与 libsodium 的双向互操作验证（测试进程加载参考库，Rust 程序不加载）。
- 哈希修正与密封导出已串联：有界并行搜索、取消、超时、保护区域检查和封装后回读。仅在显式指定已编辑浮点字段时才允许借用其低位，报告给出实际调整；不安装游戏文件。
- 原生 ID 行表与 64 位哈希表索引、按记录身份读取字段。6 份本地数据中 26 张受支持表、2660 个记录的 ID 和偏移与独立校验器一致；重排记录后原值仍可按 ID 对照。

## 仍需迁移

1. 原始基准来源认证、完整安装事务与备份集成。
2. 剩余表布局、动态数组、组件与引用链解析；目前仅迁移部分布局，不能视为全部游戏数据已覆盖。
3. 全部参数描述、共享影响、中文名称及搜索索引。
4. 护甲、装备与全局预设的导入导出和兼容规则。
5. 资源补丁、备份、事务写入、恢复、进度与诊断。
6. 现有界面接入原生 Rust 接口；界面只负责展示与交互，不承载数据读写和业务规则。

完成上述迁移并验证前，4.6.0 仍使用原有兼容数据层，不能称为纯 Rust 成品。新入口支持 `inspect`、`inspect-sealed`、`tables` 只读检查和 `seal-copy`、`unseal-copy`、`prepare-copy` 新文件导出，不覆盖现有文件，不连接正式安装按钮。密封认证和游戏哈希匹配均不能证明载荷为原版数值。

## 验证

`shodan-native --stdio` 提供逐行 JSON 原生会话接口，包含 `info/open/index/get/set/restore/preview/export-copy/close`。请求使用 `id/method/params`，响应保留 ID 并返回 `ok/result` 或 `ok/error`。记录身份使用 `id:9` 或 `hash:完整十六进制哈希`，避免 JavaScript 浮点数截断 64 位哈希。`open` 失败不丢弃现有会话；导出只创建新明文文件，先核对当前磁盘快照，不覆盖已有文件，不代表已安装游戏。正式 Flutter 界面尚未切换到此接口。

独立进程测试：`python tests/test_native_api.py`。仅写入项目隔离临时目录；覆盖精确字节比较、原文件保持不变、拒绝覆盖、外部修改拦截、错误恢复和正常退出。该环境的用户系统临时目录对原生进程写入受限，测试目录因此明确放在项目 `dist` 下。

新增原生 `Session`：整合只读磁盘快照、一次性表索引、按 ID 编辑、可信原值查询和恢复、待应用修改及过期快照拦截。未找到可信原值时禁止恢复；重复 ID 表拒绝编辑。尚未接入正式界面，不能视为兼容数据层已移除。

新增原生 `baseline` 模块：仅接受清单中六份原值文件的固定 SHA-256 指纹；按数据块类型和记录 ID/哈希读取原值，不使用当前文件的行位置推断默认值。记录重排、新增记录、重复 ID 和越界字段均有独立检查。指纹验证不代替游戏版本核对；此模块尚未接入正式界面的恢复按钮。

```sh
cargo test --workspace
cargo build --release --bin shodan-native
target/release/shodan-native inspect offline/originals/generated_arc_settings.dl_plain
python tests/test_native_data.py --exe target/release/shodan-native.exe --originals offline/originals --output dist/native-data-audit.json
python tests/test_native_codec.py --exe target/release/shodan-native.exe --originals offline/originals --output dist/native-codec-interop
python tests/test_native_correction.py --exe target/release/shodan-native.exe --originals offline/originals --output dist/native-export-regression
python tests/test_native_tables.py --exe target/release/shodan-native.exe --originals offline/originals --output dist/native-tables-audit.json
```

数据对照在本地原始文件上进行，报告只包含文件名、大小和块数量，不包含用户目录。自动测试不写入游戏。

格式与接口依据：[RustCrypto crypto_box](https://docs.rs/crypto_box/0.9.1/crypto_box/)、[libsodium sealed boxes](https://doc.libsodium.org/public-key_cryptography/sealed_boxes)。
