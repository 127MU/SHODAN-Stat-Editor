# SHODAN 4.6.0 桌面界面

Flutter 界面使用 Morrow 的玻璃组件和着色器；Rust 宿主运行兼容数据引擎。源代码许可及第三方声明见 MORROW-LICENSE、NOTICE.md 和应用目录的 licenses。

在仓库根目录执行 `cargo build --release --workspace`，然后在本目录执行 `flutter pub get`、`flutter analyze`、`flutter test`、`flutter build windows --release`。Windows 构建需要 Visual Studio C++ 桌面工具链。

字体为用户提供 MiSans Regular 的字符子集，保留中英文及常用符号。重新生成可运行 `python tools/build_misans_subset.py <MiSans.zip>`，需要 fonttools。

打包运行 `python tools/package_morrow.py --output <新输出目录>`；需要 offline/runtime、offline/launcher 运行库和可信原始数据。单文件构建沿用 `tools/package_onefile.py`，打包文件限制小于 20 MB。

安装弹窗展示引擎发送的实际阶段和阶段内进度，不模拟百分比。设置支持诊断模式、只读检查和 JSON 日志导出，日志不自动上传。
