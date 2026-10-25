local ffi=require('ffi')
local G=require('gamedata')
local D=require('hostdata')
local I=require('install')
local guard=require('extra_stratagem_guard')
local function node(id,target,original) return {id=id,name='战备'..id,target=target,original=original or 0} end
assert(not guard.validate({node(1,3),node(2,0),node(3,0)}))
assert(guard.validate({node(1,3),node(2,3),node(3,0)}):find('重复',1,true))
assert(not guard.validate({node(1,3),node(2,3),node(3,0)},{id=2,target=0}))
assert(guard.validate({node(1,3),node(2,4),node(3,5),node(4,5),node(5,0)}):find('重复',1,true))
assert(guard.validate({node(1,2),node(2,1)}):find('循环',1,true))
assert(not guard.validate({node(1,3,3),node(2,3,3),node(3,0)}),'Unchanged native extras must stay valid')

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

-- Simulate conflicting settings from an old preset or another writer, bypassing
-- the picker deliberately. Preview and Install must still stop before writes.
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
a[0],b[0]=target,target
assert(B.extra_validate():find('重复',1,true),'Duplicate extras not detected')
local ok,why=pcall(B.install_preview)
assert(not ok and tostring(why):find('重复',1,true),'Preview accepted duplicate extras')
local writer=I.write_files;local writes=0
I.write_files=function()writes=writes+1;error('Game writes forbidden')end
B.install();assert(writes==0 and not B.write_succeeded(),'Duplicate extras reached game writer')
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
return {projectile_candidates=#candidates,contextual_candidates=contextual,matches_120=generic120,samples_120=table.concat(samples120,' | '),mount_choices=new_choices.mountitem,side_choices=new_choices.mountside,faction_choices=new_choices.faction,behavior_choices=new_choices.behavior,direct_duplicates=true,nested_duplicates=true,loops=true,preview_blocked=true,install_blocked=true,game_writes=0}
