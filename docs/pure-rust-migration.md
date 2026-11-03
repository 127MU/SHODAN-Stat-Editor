# 纯 Rust 重构

4.6.0 已独立发布。后续迁移在 `refactor/pure-rust-core` 分支进行，界面的外观与现有操作流程保持一致。

## 当前完成

- 新增独立的 `shodan-native` 可执行文件，不加载 Lua、Flutter、LuaJIT 或兼容宿主。
- Rust 原生 LDLD 索引：识别重复类型的数据块，保留块前的非零元数据，校验头部和载荷边界，拒绝无法解析的后缀。
- Rust 编辑文档：磁盘快照、可信原始数据和待应用修改分别保存。原始数据缺失时不提供虚假的恢复值。
- 数值修改限制在数据块载荷内，拒绝重叠修改与打开后发生变化的磁盘文件。此阶段仅在内存生成字节，不安装游戏文件。
- 测试覆盖浮点位解释、负重力、大数值、修改值不冒充原值、布局不匹配、错误输入与截断数据。
- 原生 NaCl 密封文件编解码采用 RustCrypto `crypto_box`；SHA-256 与游戏使用的 Murmur64 校验均不依赖 DLL。6 份本地原始数据完成与 libsodium 的双向互操作验证（测试进程加载参考库，Rust 程序不加载）。

## 仍需迁移

1. 原始基准来源认证、编辑后哈希修正与密封文件写入集成。
2. 表、行、组件及引用链解析；原值需按稳定身份匹配，不能仅按偏移推断。
3. 全部参数描述、共享影响、中文名称及搜索索引。
4. 护甲、装备与全局预设的导入导出和兼容规则。
5. 资源补丁、备份、事务写入、恢复、进度与诊断。
6. Rust 界面实现及与现有视觉、交互的对照验证。

完成上述迁移并验证前，4.6.0 仍使用原有兼容数据层，不能称为纯 Rust 成品。新入口支持 `inspect`、`inspect-sealed` 只读检查和 `seal-copy`、`unseal-copy` 新文件导出，不覆盖现有文件，不连接正式安装按钮。密封认证和游戏哈希匹配均不能证明载荷为原版数值。

## 验证

```sh
cargo test --workspace
cargo build --release --bin shodan-native
target/release/shodan-native inspect offline/originals/generated_arc_settings.dl_plain
python tests/test_native_data.py --exe target/release/shodan-native.exe --originals offline/originals --output dist/native-data-audit.json
python tests/test_native_codec.py --exe target/release/shodan-native.exe --originals offline/originals --output dist/native-codec-interop
```

数据对照在本地原始文件上进行，报告只包含文件名、大小和块数量，不包含用户目录。自动测试不写入游戏。

格式与接口依据：[RustCrypto crypto_box](https://docs.rs/crypto_box/0.9.1/crypto_box/)、[libsodium sealed boxes](https://doc.libsodium.org/public-key_cryptography/sealed_boxes)。
