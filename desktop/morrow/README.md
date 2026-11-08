# Windows 桌面构建

当前基线为 **4.6.0-r5.1+11**。Flutter / Morrow 负责界面，Rust 负责数据核心与单文件启动器；运行包无需 Lua。完整环境、模块和隔离回归说明见[开发指南](../../docs/development-guide.md)。

## 构建

需要 Windows x64、Visual Studio 桌面 C++ 工具链和 Windows SDK、Rust、Flutter，以及 Python 3.11+ 与 fonttools。具体固定工具版本见[构建工作流](../../.github/workflows/dev-build.yml)。

1. 根目录执行 `cargo test --workspace --locked`、`cargo build --release --workspace --locked`。
2. 本目录执行 `flutter pub get --enforce-lockfile`、`flutter analyze --no-pub`、`flutter test --no-pub`。
3. 本目录执行 `flutter build windows --release --no-pub --build-name=4.6.0-r5.1 --build-number=11`。
4. 根目录执行 `python tools/package_morrow.py --output dist/SHODAN_r51_local`，输出目录必须未被占用。

下一版同步 Rust Cargo.toml / Cargo.lock、Flutter pubspec.yaml 和 app_version.dart；构建参数必须与版本文件一致。

## 插件与打包

Windows 构建插件需要符号链接支持；出现 symlink 错误时，在开发机启用 Windows 开发者模式再重新获取依赖。运行发行包无需开启开发者模式。

文件拖入使用 `desktop_drop`，完整包必须保留 `desktop_drop_plugin.dll`、Flutter 运行库、资源及许可证，不能只发送界面 EXE。`DESKTOP-DROP-LICENSE` 随包保留。打包脚本生成 manifest 并限制 ZIP、单文件 EXE 各小于 20,000,000 字节。使用单文件的 `--verify-package` 检查解包与完整性；该参数不启动编辑器。

重建 MiSans 子集时，在根目录执行 `python tools/build_misans_subset.py <MiSans.zip> --catalog rust/core/data/catalog.json.gz`。保留界面、参数目录用字、常用中文与拉丁字符，字体许可随包提供。

安装进度由 Rust 返回。诊断导出会脱敏；不要提交本机配置、原始用户日志和游戏数据。预设拖入、命名及格式见[预设库说明](../../docs/preset-library.md)，发布流程与附件摘要见[维护交接](../../docs/maintainer-handover.md)。
