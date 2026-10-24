B.editor_mode(false)
local chosen;for _,item in ipairs(B.items('Primary',''))do if item.id=='968211C0033DCE64' then chosen=item end end
assert(chosen);B.select(chosen.id)
local damage;for _,r in ipairs(B.rows())do if r.label=='伤害' and not damage then damage=r end end;assert(damage)
local initial=B.rows()[damage.id].value
local preview=B.preset_compare('full',1)
assert(preview.skipped==1 and preview.accepted==1 and preview.warnings[1]:find('f018',1,true))
assert(B.rows()[damage.id].value==initial,'Preview changed live state')
local message=B.full_preset('load',1)
assert(message:find('已跳过 1 项',1,true) and B.rows()[damage.id].value==180)
B.set(damage.id,321)
local ok,why=pcall(B.full_preset,'load',2)
assert(not ok and tostring(why):find('以免清空当前修改',1,true) and B.rows()[damage.id].value==321,'Unknown-only preset cleared changes')
preview=B.preset_compare('weapon',1);assert(preview.skipped==1 and preview.accepted==1)
message=B.preset('load',1);assert(message:find('已跳过 1 项',1,true) and B.rows()[damage.id].value==120)
B.reset(damage.id)
return {partial_preset_preview=true,partial_preset_loaded=true,unknown_only_load_blocked=true,weapon_preset_checked=true,original_preset_untouched=true,game_writes=0}
