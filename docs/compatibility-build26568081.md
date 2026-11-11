# Build 26568081 兼容检查

检查日期：2026-11-12。依据本机 Steam buildid `26568081`、用户提供的 `THEIA_B26568081_20261112` 解密模块，以及 EAC 时序报告（2026-11-11）。
所有检查都在独立配置目录中完成；游戏目录只读，未启动游戏，未写入任何游戏文件。

## 已确认

- Steam `appmanifest_553850.acf` 的 `buildid` / `TargetBuildID` 均为 `26568081`。
- 弹目录 `game.dll`（原版，未经页面还原）SHA-256 为 `08b756f5…11acf5f`；解密模块内的 `game.dll` 是页面/.pdata/IAT 还原版，哈希不同、大小 +3,584 B，属预期差异。
- 55 张 `.dl_bin` 中 48 张可正常解封为 LDLD；其余 7 张（`planet_data`、`zone_data`、`route_settings`、`resource_swap`、`modifier_settings`、`galactic_presence_settings`、`planet_region_settings`）不是 LDLD 结构，参数目录也未绑定它们。
- 参数目录实际绑定的 12 张表全部与随包原值**逐字节一致**（SHA-256 相同）：
  `entities`、`projectile`、`damage`、`explosion`、`arc`、`stratagem`、`armor_sets`、`passive_bonuses`、`entity_deltas`、`status_effect`、`destruction`、`beam`。
- 这 12 张表的 murmur64 指纹同时存在于原版与解密版 `game.dll`，说明记录布局未变，仅版本指纹不同。
- 74 个独立资源用 `rescan-resources` 从新版 bundles 重扫：包名与字节长度不变，**29 个内容哈希更新**。

## 修改

| 项 | 旧值 | 新值 |
| --- | --- | --- |
| `catalog.game_build` | `61dcfcd2…`（26251122） | `08b756f5…`（26568081） |
| `catalog.sources`（damage/projectile/stratagem） | 旧构建哈希 | 与随包原值一致 |
| `catalog.resource_sources` | 74 条旧指纹 | 74 条重扫结果（29 条更新） |
| `offline/originals/build.txt` | `61dcfcd2…` | `08b756f5…` |
| `catalog_supplement.rs` 的 `BUILD` | `61dcfcd2…` | `08b756f5…` |

新增 `rust/core/src/bin/rescan-resources.rs`：只读扫描已安装 bundles，重算资源指纹，供以后游戏更新时复用。

## 验证

- `game-open` 成功，`problems` 为空。
- 13 个分类（主武器、副武器、支援、投掷物、强化、配件、护甲、潜兵、三个敌人阵营、载具、战略配备）全部可列出条目；每类抽样 3 个条目读取参数，错误数 0。
- `install_preview` 与 `baseline_check` 的 `problems` 均为空。
- Rust `cargo test` 与 Flutter 测试见本次提交记录。

## EAC 结论（来自 2026-11-11 时序报告）

- 引擎先读取并解封数据表，EAC 的完整性校验是**独立的第二轮全量读取**；加载结束到校验开始约 17.9 s，到判决约 23.1 s（单次审计样本）。
- 4 张懒加载表（`candidate_descs`、`corporation_logos`、`credits_settings`、`policy_settings`）不在启动校验范围内。
- 内容改变仍会被第二轮抓到（报告 E1/E3），所以"不能改内容"的结论不变；本项目**不提供**抢占该窗口或绕过校验的工具。
- 写入游戏后 EAC 仍可能提示"未知的文件版本"；编辑器保持退出游戏后的显式写入与恢复流程，不涉及校验面，也不自动上传或隐藏修改。

## 未验证

- 局内行为（准星、树冠碰撞、布娃娃等）仍需实机确认。
- 资源补丁的实机效果；本次只重算了指纹，未写入资源包。
- 未绑定的 43 张表：编辑器不读取它们，其结构变化不影响参数目录。
