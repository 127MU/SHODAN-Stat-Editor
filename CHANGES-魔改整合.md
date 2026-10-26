# SHODAN 数值编辑器 · 魔改整合版 4.1.0-fm3

基于 127MU/SHODAN-Stat-Editor main（`be765e49`，含 PR #10 射击模式与 r15 的「不可变默认值」修复）与上游 4.1.0 面板；
本版已把 r15 对 `read_field` 的 original 取值改造（tier 门槛、敌人武器走 bytes()）、战备「不限使用次数」行内说明、
机甲臂区生命上限 0xFFFFFFFF 判定，一并移植过来。

## 一、本版新增（fm3）：载具/机甲挂载、阵营、AI 行为、机甲换臂

数据来自 deepseekv41flash 的解包仓库 docs/tables 下 MOUNT-SEATS-26088801.md、FACTION-BEHAVIOR-26088801.md、
EXO-ARM 相关文档，并在本机明文表上逐条核对过。

| 面板分节 | 新增行 | 偏移 | 说明 |
| --- | --- | --- | --- |
| 挂载 | 挂载槽 1–5（挂载件 / 左右侧） | MountInfo +0 u64 / +0x0C | 换件只写这 8 字节；左右侧 0 通用 / 1 右侧 / 2 左侧 |
| 挂载 | 挂点 A、挂点名、标记 1、标记 2 | +8 / +16 / +20 / +21 | 仅非空槽显示；挂点值是游戏认挂位的哈希；**挂点为实验性功能**；补给型载具（M-103）不开放挂点修改 |
| 座位 | 座位 | SeatInfo +0 | 载具/机甲的座位编号 |
| 阵营 | 阵营 | FactionComponentData +0 | 0 继承 / 1 超级地球 / 2 终结者 / 4 光明族 / 8 自动化军团 |
| AI 行为 | AI 行为 | BehaviorComponentData +0 | 行为 id；下拉给出表里出现过的全部 id |
| 机甲 | 臂件变体 | — | 10 个臂件（含游戏里没有任何机甲装它的 200 发机炮、导弹巢 MK2） |

- 组件表：`FactionComponentData 0x5653EA91`（stride 152）、`BehaviorComponentData 0xBA9B803D`（stride 12）、座位 stride 424。
- 只在真的带该组件的条目上出现：实测机甲 EXO-45 48 行 / TD-110 106 行、哨戒炮 83 行里 2 行（只有阵营与 AI 行为）、
  普通武器 AR-23 0 行（无假阳性）。
- 选择器数量：挂载件 370 项、AI 行为 584 项；越界值在状态栏给出原因而不是「已保存」。

## 二、fm2 已含：粘附、资源驻留、空投舱

- 粘附（StickyComponent，投掷物 24 条里 12 条有）：附着方式 +0、三枚标记 +4/+5/+6、命中伤害行 +44、命中特效 +48、
  表面命中 +52、能力 A/B +60/+64、附着力参数 +72。
- 资源驻留（StratagemSettings）：资源包 +168（u64 物品 → LoadoutPackage）、资源入口 +248（LoadoutEntry）。
- 空投舱（HellpodRack）：投放件数 +556、随机挑几件 +552、槽 1–8（每槽 64 字节，物品键在 +0）。

## 三、fm1 已含：射击模式

武器「开火」分节新增射击模式 1/2/3 槽（WeaponData +144/148/152）、连发发数 +140、功能键输入 1/2（+184/+188）；
枚举 0 空槽 / 1 自动 / 2 半自动 / 3 连发 / 4 齐射 / 5 安全 / 6 不安全 / 7 全射 / 8 未使用。

## 四、验证

- Lua 语法：载荷 lua51.dll（LuaJIT）loadfile 通过。
- 面板自带 QA 闸门（SHODAN_QA_OUTPUT）：EXIT=0、无 failure.txt、0 未译项。
- 无头探针：枪械 / 战备 / 机甲 / 投掷物逐条读取与写入+回滚全部通过（挂载件 103↔123、左右侧、阵营 0→8、行为 165→645）。
- 单文件 exe：266 文件、校验表 266 行逐条哈希一致，构建号 `4.1.0-fm3-desktop-349286e1a7440d36`。

## 五、补丁锚点

见同目录 PATCH-NOTES.txt（每个 hunk 的行号与含义）。

## 4.1.0-fm4：资源层驻留（补丁方案）

在群友 4.1.0-r15（127MU/SHODAN-Stat-Editor）之上，把群友工具包里的「资源层驻留」（6.9 节）做进面板。

## 新增功能

- 战备条目「资源驻留」分节下多一行 **资源常驻（补丁，不占口）**，四档：
  - 未安装
  - 完整（含贴图）：整个包连同贴图、模型、音效一起写进补丁
  - 仅轻资源：只写轻资源，体积小；缺贴图的件会变紫问号
  - 移除补丁：删掉补丁文件，资源还回资源包口
- 补丁写在游戏目录：`data/9ba626afa44a3aa3.patch_N`（注册表包永远被加载，所以补丁一定被合并）。
  槽位编号永远取「最高位 + 1」，不填洞（中间留洞会让后面的补丁全部失效）；移除时后面的槽位整体下移。
- 账本 `residency.txt` 存在配置目录，面板据此显示当前状态；重启游戏后生效。

## 实现

- `offline/res_patch.lua`：DSAR 解压（自带 LZ4 block）、bundles.nxa 索引、按 fragment 拼包、
  Package 容器解析与子集重建（toc 绝对偏移 + 16 对齐、gpu 64 对齐、entry_index 重排、type num_files 回填）、
  槽位与账本管理。纯 Lua 5.1，无外部依赖。
- `src/stat_editor.lua`：新增 `MOD.resident`（ctx / package_name / state_of / act），
  `stratagem_rows` 加行，`row_value` / `change` / `state.desktop.set` / `rows` / `choices` / `choose` 各接一处。
- `offline/host.lua`：把 `I.find_game` 的结果通过 `SHODAN_OFFLINE_GAME` 交给面板。

## 验证

- srkit 反向解析：full 10 条 / light 6 条，与源包逐字节一致（matched 全中、bad 0）。
- 真 LuaJIT 探针：0→1→2→3 全通，槽位复用正确，sidecar 会随模式切换清理。
- host 自带 QA 闸门：EXIT=0、无 failure.txt、0 未译项。
- 真实游戏目录零写入（探针跑在硬链接假数据树上）。
