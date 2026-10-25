# HuskarUI 桌面版

使用 Qt 6.8.3、MinGW 13.1、CMake 3.22+ 与 Ninja 本地构建。
HuskarUI 固定为 `d760773ee0f440284965fe443f765caeb66d8114`，自动获取其子模块。
配置时 `PatchShaderUniforms.cmake` 会为依赖源码的玻璃和动态背景顶点着色器补齐 uniform 声明；同时支持本地依赖路径，重新构建会重烘对应 QSB。构建目录需允许写入依赖源码。

```powershell
cmake -S desktop/huskar -B build/huskar -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<Qt SDK 路径>
cmake --build build/huskar --parallel
python tools/package_huskar.py --build-dir build/huskar --qt-dir <Qt SDK 路径> --compiler-bin <MinGW bin 路径> --huskar-root build/huskar/_deps/huskar-src
python tools/package_onefile.py --release dist/huskar-r14/SHODAN_4.1.0-r14 --compiler-bin <MinGW bin 路径>
```

离线复用源码可传入 `FETCHCONTENT_SOURCE_DIR_HUSKAR` 和
`FETCHCONTENT_SOURCE_DIR_EUI_HELPERS`。EUI 只提供既有 ZIP 元信息解析所需的
JSON 工具和 zlib/yyjson 源码，不编译、不链接其界面或渲染器。

`Workspace.qml` 负责业务状态，`Main.qml` 只组合窗口与页面。
首页、资源库、独立参数工作区、护甲和设置分为单独页面。
可见控件优先采用 HuskarUI；Gallery 背景与材质使用原生效果，标识使用 SHODAN 透明 Logo。
现有 LuaJIT 后端、原版文件写入逻辑、预设格式及本机会话 MCP 接口继续复用。

运行包自带 Qt，不需要用户安装 Qt 或 Python。LuaJIT、libsodium 和
shodan_hash.dll 沿用现有运行库。构建和打包不会启动游戏或写入游戏文件。

```powershell
python tests/test_huskar.py --exe "dist/huskar-r14/SHODAN_4.1.0-r14/SHODAN 数值编辑器.exe" --output dist/qa-huskar
```

该测试创建隔离配置，验证界面、回车/失焦保存、无效输入、预设、主题和图片；
测试模式明确禁止写入游戏。离屏测试可附加
`--qa-platform-dir <Qt SDK>/plugins/platforms`，生产包只携带 Windows 平台插件。
