local F=require('desktop_features')
local weights=B.items('ArmorWeight','');B.select(weights[1].id);local row=B.registry[weights[1].id].rows[1]
local invalid=F.encode('weapon','非法重量',weights[1].id,{{hash=weights[1].id,id=row.id,value=3}})
assert(not pcall(B.preset_inspect,'weapon',invalid),'Preset accepted armor weight 3 outside the valid choices')
local hash='968211C0033DCE64';for _,item in ipairs(B.items('Primary',''))do if item.id==hash then B.select(hash)end end
for _,values in ipairs({{{hash=hash,id='slot2',value=5}},{{hash=hash,id='slot1',value=999999}},{{hash=hash,id='slot1',value=5.5}}})do
 local text=F.encode('weapon','非法状态',hash,values)
 assert(not pcall(B.preset_inspect,'weapon',text),'Preset accepted a gap or unknown status ID')
end
local weapon=B.registry[hash];local swap;for _,r in ipairs(weapon.rows)do if r.choice==true then swap=r.parts[1].id;break end end;assert(swap)
local bad_ammo=F.encode('weapon','非法弹丸',hash,{{hash=hash,id=swap,value=999999}});assert(not pcall(B.preset_inspect,'weapon',bad_ammo),'Preset accepted unknown ammunition ID')
local good=F.encode('weapon','合法状态',hash,{{hash=hash,id='slot1',value=5},{hash=hash,id='slot2',value=38},{hash=hash,id='slot1_strength',value=2}})
assert(B.preset_inspect('weapon',good).skipped==0)
local rows=B.rows();local damage;for _,r in ipairs(rows)do if r.label=='伤害' and not damage then damage=r end end;assert(damage)
assert(not pcall(B.set,damage.id,-1),'Failed numeric write returned a successful API result');assert(B.rows()[damage.id].value==damage.value)
local n
for _,r in ipairs(rows)do if r.choice_kind=='status' then n=r.id;break end end
assert(n);B.choose(n,5)
local chosen=B.rows()[n];assert(chosen.choice_name~='' and chosen.choice_name:find('燃烧',1,true),'Status choice displays ID without its name')
B.reset()
return {armor_enum_guard=true,status_slot_guard=true,status_id_guard=true,projectile_id_guard=true,valid_multi_slot_preset=true,status_choice_name=true,write_failure_reported=true,game_writes=0}
