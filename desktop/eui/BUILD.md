# EUI-NEO desktop

The desktop is a C++17 EUI-NEO application with an in-process LuaJIT backend.
EUI-NEO is pinned to `1647709068e36834ab26da5a97ef4ad98aa34c9d`.
MCP is optional and disabled at startup. Enable it in Settings and copy the
session's authenticated loopback HTTP connection configuration. No browser
runtime is needed. See `MCP.md` for the API and debugging tools.

Build with CMake 3.22+, Ninja and MinGW-w64 GCC 12+, or Visual Studio 2022
with the Windows SDK installed:

```powershell
cmake -S desktop/eui -B build/eui -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/eui --parallel
python tools/package_eui.py --build-dir build/eui --eui-root build/eui/_deps/eui-src
```

The packager needs the existing `offline/runtime/lua51.dll`, `libsodium.dll`
and `offline/launcher/shodan_hash.dll`. These are also distributed with the
Windows release. The LuaJIT public headers are vendored under `lua/` with
their original copyright notices. The executable does not require Python.

For an existing local EUI-NEO checkout, pass
`-DFETCHCONTENT_SOURCE_DIR_EUI=<checkout>` when configuring CMake.
The source README and the official game-file writer remain unchanged.

QA uses an isolated `LOCALAPPDATA` profile. `SHODAN_EUI_QA=<output-directory>`
renders this application's own framebuffer across ten pages, writes BMPs,
and exits. It does not inject desktop input or write game files. The bridge
regression script is `tests/eui_bridge_regression.lua` and expects the
production bridge in global `B`; it forbids game writes explicitly.
