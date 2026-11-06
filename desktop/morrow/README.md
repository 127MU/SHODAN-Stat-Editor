# Windows 桌面构建

Flutter 界面使用 Morrow 的玻璃组件与着色器。Rust 数据进程和单文件启动器由根目录的 Cargo 工作区构建。依赖、组件许可与字体声明随发行包提供。

1. 在仓库根目录运行 `cargo test --workspace --locked` 和 `cargo build --release --workspace --locked`。
2. 在本目录运行 `flutter pub get --enforce-lockfile`、`flutter test --no-pub`、`flutter build windows --release --no-pub`。Windows 构建需要 Visual Studio 的桌面 C++ 工具链。
3. 安装 Python 的 `fonttools` 后，在仓库根目录运行 `python tools/package_morrow.py --output dist/SHODAN_Windows`，生成单文件 EXE 和 ZIP。目录名称须未被占用。

如需重建 MiSans 子集，在仓库根目录执行 `python tools/build_misans_subset.py <MiSans.zip> --catalog rust/core/data/catalog.json.gz`。子集包含界面、参数目录用字、常用中文与拉丁字符。

写入弹窗显示 Rust 进程提供的安装阶段和文件进度。诊断模式与脱敏日志保存在本机。
