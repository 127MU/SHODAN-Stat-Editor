#pragma once
#include "mcp_server.h"
#include <set>
inline Value huskarMcpCatalog(Backend& backend,std::set<std::string>& methods){
 using shodan::object;Value catalog;catalog.kind=Value::Table;methods.clear();
 const std::map<std::string,std::string> signatures={
 {"items","[tab, query] 查询装备；tab: Primary/Secondary/Support/Throwables/Stratagems/Mechas/Attachments/Records"},
 {"select","[hash] 选择装备；hash 使用 items 返回的 id"},{"rows","[] 当前装备的参数、原值、范围和共享影响"},
 {"game_text","[field, value?] 查看或修改游戏内文字；field: name/desc，空字符串恢复原文"},
 {"set","[row_id, value] 修改当前装备参数；value 可为数字或数值字符串，先调用 rows 获取 id"},
 {"reset","[row_id?] 恢复原值；省略 row_id 恢复当前装备"},{"choices","[row_id] 查询弹丸或状态效果候选项"},
 {"shared","[row_id] 查询共享此参数的装备"},{"preset","[action, slot] 当前装备预设；action: save/load/clear，slot: 1..5"},
 {"choose","[row_id, choice_id] 沿用原项目选择逻辑替换弹丸、爆炸或效果；先调用 choices"},
 {"full_presets","[] 列出全局预设"},{"full_preset","[action, id, name?] 全局预设 save/load/delete"},
 {"preset_info","[slot] 当前装备预设详情"},{"preset_rename","[kind, id, name] 重命名预设；kind: weapon/full"},
 {"preset_export","[kind, id] 导出预设文本；kind: weapon/full"},{"preset_import","[kind, id, text] 导入预设文本"},
 {"preset_inspect","[kind, text] 预览待导入预设"},{"preset_compare","[kind, id] 比较预设与当前修改"},
 {"armor_rows","[passive_id] 查询护甲被动可修改参数及原值"},{"armor_set","[passive_id, key, value] 修改护甲被动数值"},
 {"armor_profile","[target_id] 查询多被动组合；999 为所有护甲"},
 {"armor_update","[target_id, passive_id?, enabled?, keep_original?, policy?] 设置多被动；policy: stack/strongest"},
 {"pending_preview","[] 列出未写入修改"},{"install_preview","[] 检查写入内容、护甲组合和冲突"},
 {"install","[] 安装当前数值与开启的 Mod，执行原项目写入流程；必须先关闭游戏"},
 {"restore","[] 恢复游戏原版并移除本程序部署的资源补丁；必须先关闭游戏"},
 {"managed_mods","[inputs] 设置 .dl_bin 合并输入；每项 {name,label,data}，二进制 data 使用 {$base64:...}"},
 {"mod_management","[enabled] 内部 Mod 协调开关；写入和预览会以界面的隐藏功能开关为准"},
 {"merge_named","[name, inputs] 按可信原版合并指定 .dl_bin；inputs 每项 {label,data}"},
 {"merge_mods","[base, inputs, policy] 底层 .dl_bin 合并与冲突报告；二进制用 {$base64:...}"},
 {"game_running","[] 查询游戏是否运行"},{"write_succeeded","[] 查询上次写入结果"},{"status","[] 后端状态"},
 {"flush","[] 保存未落盘的编辑器设置"},{"tick","[] 推进一次后端任务"}};
 auto add=[&](const std::string& name,const std::string& description,const Value& schema,bool readOnly){
  catalog.array.push_back(object({{"name",name},{"description",description},{"inputSchema",schema},
   {"annotations",object({{"readOnlyHint",readOnly},{"destructiveHint",!readOnly},{"openWorldHint",false}})}}));};
 auto positional=shodan::jsonParse(R"({"type":"object","properties":{"args":{"type":"array","items":{},"maxItems":8,"description":"按工具描述顺序传入的位置参数；无参数时传 []"}},"additionalProperties":false})");
 const std::set<std::string> reads={"items","rows","choices","shared","preset_info","full_presets","preset_compare","preset_export","preset_inspect","pending_preview","armor_rows","armor_profile","install_preview","game_running","write_succeeded","status"};
 for(const auto& entry:backend.interfaces().array)if(entry["type"].str()=="function"){
  auto name=entry["name"].str();methods.insert(name);auto it=signatures.find(name);
  add("shodan_"+name,it==signatures.end()?"现有后端接口 "+name:it->second,positional,reads.count(name)!=0);
 }
 auto empty=shodan::jsonParse(R"({"type":"object","properties":{},"additionalProperties":false})");
 add("shodan_debug_interfaces","列出所有后端接口与属性类型，核对 MCP 覆盖情况",empty,true);
 add("shodan_debug_runtime","调试：Lua 内存、栈、游戏路径、当前页面、选中装备和后端状态",empty,true);
 add("shodan_debug_logs","调试：最近 100 条 MCP 调用记录；不记录参数和连接令牌",empty,true);
 add("shodan_debug_log_files","调试：列出编辑器 Logs 目录中的日志文件",empty,true);
 add("shodan_debug_read_log","调试：读取指定日志末尾，最多 64 KiB；仅限 Logs 目录的文件名",
  shodan::jsonParse(R"({"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false})"),true);
 add("shodan_debug_self_test","调试：检查当前参数的数值、原值和范围，返回异常行；不写入游戏",empty,true);
 add("shodan_debug_property","调试：只读查询公开后端属性，例如 armor_list、armor_groups、game",
  shodan::jsonParse(R"({"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false})"),true);
 add("shodan_mods_list","列出 Mod 名称、描述、开关、选项与缓存路径。需在界面开启隐藏功能",empty,true);
 add("shodan_mods_import","导入本地 ZIP 路径列表，复用界面的格式检查和缓存流程",
  shodan::jsonParse(R"({"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":32}},"required":["paths"],"additionalProperties":false})"),false);
 add("shodan_mods_update","设置 Mod 开关、名称、描述或选项；index 从 0 开始；关闭后重新写入游戏移除效果",
  shodan::jsonParse(R"({"type":"object","properties":{"index":{"type":"integer","minimum":0},"enabled":{"type":"boolean"},"name":{"type":"string"},"description":{"type":"string"},"choices":{"type":"array","items":{"type":"integer","minimum":0}}},"required":["index"],"additionalProperties":false})"),false);
 add("shodan_mods_remove","从管理列表移除指定 Mod；index 从 0 开始",
  shodan::jsonParse(R"({"type":"object","properties":{"index":{"type":"integer","minimum":0}},"required":["index"],"additionalProperties":false})"),false);
 add("shodan_mods_export","合并开启的 Mod 并导出 ZIP；指定绝对输出路径；已有文件会被覆盖",
  shodan::jsonParse(R"({"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false})"),false);
 return catalog;
}
