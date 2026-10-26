local ffi=require('ffi')
local G=require('gamedata')
local D=require('hostdata')
local I=require('install')
local guard=require('extra_stratagem_guard')
local function node(id,target,original) return {id=id,name='战备'..id,target=target,original=original or 0} end
local function duplicate_warning(nodes,change)local err,warnings=guard.validate(nodes,change);assert(not err,err);return table.concat(warnings,'\n')end
assert(not guard.validate({node(1,3),node(2,0),node(3,0)}))
assert(duplicate_warning({node(1,3),node(2,3),node(3,0)}):find('重复',1,true))
assert(not guard.validate({node(1,3),node(2,3),node(3,0)},{id=2,target=0}))
assert(duplicate_warning({node(1,3),node(2,4),node(3,5),node(4,5),node(5,0)}):find('重复',1,true))
assert(guard.validate({node(1,2),node(2,1)}):find('循环',1,true))
assert(not guard.validate({node(1,3,3),node(2,3,3),node(3,0)}),'Unchanged native extras must stay valid')

-- Hidden StratagemInfo #51 is a valid chain target although absent from the picker.
local hidden_checked=false
for _,item in ipairs(B.items('Stratagems',''))do
 if item.name:find('A/FLAM-40',1,true)then
  B.select(item.id)
  for n,row in ipairs(B.registry[item.id].rows)do if row.choice=='stratagem'then
   local ptr=ffi.cast('uint32_t*',row.def.at+200);local old=tonumber(ptr[0]);ptr[0]=51
   assert(not B.extra_validate(),'Valid hidden extra #51 was treated as missing')
   local eagle=false
   for _,choice in ipairs(B.choices(n))do
    if choice.name:find('飞鹰',1,true) and not choice.disabled then eagle=true end
   end
   assert(eagle,'Unrelated Eagle choices were disabled by hidden extra #51')
   ptr[0]=old;hidden_checked=true
  end end
 end
end
assert(hidden_checked,'Flame sentry regression fixture missing')

-- Candidate names must use the same donor identity shown after choosing.
B.editor_mode(false)
local primary=B.items('Primary','');B.select(primary[1].id)
local projectile
for _,row in ipairs(B.rows())do if row.choice and row.choice_kind=='' then projectile=row.id;break end end
assert(projectile,'Projectile picker unavailable')
local candidates=B.choices(projectile)
local contextual,generic120,samples120=0,0,{}
for _,item in ipairs(candidates)do
 assert(type(item.name)=='string' and item.name~='')
 if item.description and item.description~='' then contextual=contextual+1 end
 if (item.raw or ''):find('120',1,true) then generic120=generic120+1;samples120[#samples120+1]='#'..item.id..' '..item.name..' '..(item.description or '') end
end
assert(contextual>0 and generic120>1,'Projectile donors/context were not included')

-- Duplicate extras are warnings. Preview stays read-only; continuing can reach
-- the writer. Cycles remain fatal. The test writer never touches game files.
local sources,seen={},{}
for _,entry in ipairs(B.items('Stratagems',''))do
 B.select(entry.id)
 local w=B.registry[entry.id]
 for n,row in ipairs(w.rows)do if row.choice=='stratagem' then
  local f=row.parts[1].field
  if not seen[f.key] then sources[#sources+1]={f=f,def=row.def,row=n,entry=entry};seen[f.key]=true end
 end end
 if #sources>=3 then break end
end
assert(#sources>=3)
B.select(sources[3].entry.id)
local target
for _,choice in ipairs(B.choices(sources[3].row))do
 if choice.id~=0 and not choice.disabled then target=choice.id;break end
end
assert(target)
local a,b=ffi.cast('uint32_t*',sources[1].def.at+200),ffi.cast('uint32_t*',sources[2].def.at+200)
local old_a,old_b=tonumber(a[0]),tonumber(b[0])

local F=require('desktop_features')
local function preset_value(source,value)
 return {hash=source.entry.id,id=B.registry[source.entry.id].rows[source.row].parts[1].id,value=value}
end
local text=F.encode('full','重复附赠测试',nil,{preset_value(sources[1],target),preset_value(sources[2],target)},'equipment')
local prospective=B.preset_inspect('full',text)
assert(#prospective.warnings>0 and prospective.skipped==0,'Import preview must warn without treating duplicates as skipped values')
assert(tonumber(a[0])==old_a and tonumber(b[0])==old_b,'Import preview applied values before confirmation')
local imported=B.preset_import('full',0,text)
assert(imported.id and tonumber(a[0])==old_a,'Confirmed import must store the preset without applying it')
assert(#B.preset_compare('full',imported.id).warnings>0,'Saved preset load preview lost duplicate warning')
local own_a=tonumber(ffi.cast('uint32_t*',sources[1].def.at)[0])
local own_b=tonumber(ffi.cast('uint32_t*',sources[2].def.at)[0])
local cyclic=F.encode('full','循环附赠测试',nil,{preset_value(sources[1],own_b),preset_value(sources[2],own_a)},'equipment')
assert(not pcall(B.preset_inspect,'full',cyclic),'Cycle inside imported preset must still be blocked')
a[0],b[0]=target,target
assert(not B.extra_validate(),'Duplicate extras still treated as a fatal error')
assert(table.concat(B.extra_warnings(),'\n'):find('重复',1,true),'Duplicate warning missing')
local writer=I.write_files;local writes=0
I.write_files=function()writes=writes+1;return nil,'测试写入终止'end
local preview=B.install_preview()
assert(#preview.problems==0 and table.concat(preview.warnings,'\n'):find('重复',1,true),'Preview must allow explicit continuation')
assert(writes==0,'Preview wrote game files')
B.install();assert(writes==1 and not B.write_succeeded(),'Explicit continuation did not reach the mock writer')
I.write_files=writer;a[0],b[0]=old_a,old_b
assert(not B.extra_validate(),'Restoring extras did not clear conflict')
local new_choices={}
for _,entry in ipairs(B.items('Mechas',''))do
 B.select(entry.id)
 for _,row in ipairs(B.rows())do
  local kind=row.choice_kind
  if (kind=='mountitem' or kind=='mountside' or kind=='faction' or kind=='behavior') and not new_choices[kind] then
   local available=B.choices(row.id);assert(#available>0,'PR12 choice list is empty: '..kind)
   new_choices[kind]=#available
  end
 end
end
for _,kind in ipairs({'mountitem','mountside','faction','behavior'})do assert(new_choices[kind],'PR12 field missing: '..kind)end
return {projectile_candidates=#candidates,contextual_candidates=contextual,matches_120=generic120,samples_120=table.concat(samples120,' | '),mount_choices=new_choices.mountitem,side_choices=new_choices.mountside,faction_choices=new_choices.faction,behavior_choices=new_choices.behavior,direct_duplicates_warn=true,nested_duplicates_warn=true,loops_blocked=true,preview_read_only=true,explicit_continue_reaches_mock_writer=true,game_writes=0}
