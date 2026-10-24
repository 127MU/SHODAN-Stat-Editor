local F=require('desktop_features');local ffi=require('ffi');local D=require('hostdata');local G=require('gamedata');local I=require('install')
local function select(tab,id)
 local found;for _,item in ipairs(B.items(tab,''))do if item.id==id then found=item end end
 assert(found,tab..':'..id);B.select(id);return B.registry[id]
end
local function row(w,id)for n,r in ipairs(w.rows)do if r.id==id then return n,r end end;error('Missing row '..id)end
local hash='968211C0033DCE64';local w=select('Primary',hash)
for n=1,4 do row(w,'slot'..n);row(w,'slot'..n..'_strength')end
assert(B.rows()[row(w,'slot2_strength')].value==2.5,'Startup legacy config applied strength to the wrong slot')
local preview=B.preset_compare('full',1);assert(preview.skipped==0,'Named status strength was skipped')
local text=B.preset_export('full',1);assert(text:find('slot1_strength 2.5',1,true) and text:find('slot2_strength 7',1,true) and not text:find('status5_strength',1,true))
local before=F.encode('full','before',nil,{})
B.full_preset('load',1)
for id,value in pairs({slot1=5,slot2=38,slot1_strength=2.5,slot2_strength=7})do local n=row(w,id);assert(B.rows()[n].value==value,id)end
local ok,why=pcall(B.full_preset,'load',2);assert(not ok and tostring(why):find('多个槽位',1,true))
assert(B.rows()[row(w,'slot1_strength')].value==2.5,'Ambiguous load changed data')
local imported=B.preset_import('full',0,text);B.full_preset('load',imported.id);assert(B.rows()[row(w,'slot2_strength')].value==7)
B.reset()
local weights=B.items('ArmorWeight','');assert(#weights==1);B.select(weights[1].id);local wr=B.rows();assert(#wr>100,'Armor weight page empty')
local weight=wr[1];assert(weight.label:find('服从指挥',1,true),'Armor name not localized from game strings');assert(weight.choice_name=='轻型');assert(weight.choice_kind=='weight' and #B.choices(weight.id)==3)
B.choose(weight.id,(weight.original+1)%3);assert(B.rows()[weight.id].value==(weight.original+1)%3);B.reset(weight.id)
w=select('Primary',hash);local suppress=row(w,'suppressed');B.set(suppress,1);assert(B.rows()[suppress].value==1);B.reset(suppress)
local hand=row(w,'one_handed');B.set(hand,1);assert(B.rows()[hand].value==1);B.reset(hand)
local slot=row(w,'slot1');assert(#B.choices(slot)>=34,'New experimental statuses missing')
local player=B.items('Helldiver','')[1];B.select(player.id);for _,id in ipairs({'climb_height','drown_time','float_depth','drown_depth'})do row(B.registry[player.id],id)end
w=select('Support','B814EECE17533BC4');local n,r=row(w,'apex_fire_ability');assert(B.rows()[n].original==2677)
local f=r.parts[1].field;local file=D.files['generated_entities.dl_bin'];local at
for _,h in ipairs(G.headers(file.p,file.n))do if h.type==f.kind then at=h.at+24+f.offset end end
assert(at);local beforeBytes=ffi.string(file.p+at-8,20)
B.choose(n,2719);assert(B.rows()[n].value==2719 and ffi.cast('uint32_t*',file.p+at)[0]==2719)
local writes;I.game_running=function()return false end;I.write_files=function(_,files)writes=files;return true end
B.install();assert(B.write_succeeded());local p,len=G.open_sealed(writes['generated_entities.dl_bin']);assert(p,len)
assert(ffi.cast('uint32_t*',p+at)[0]==2719 and ffi.string(p+at-8,8)==beforeBytes:sub(1,8) and ffi.string(p+at+4,8)==beforeBytes:sub(13,20))
assert(G.game_dll_has(I.read(B.game..'/game.dll'),G.murmur64(p,len)));G.free(p);B.reset(n)
return {four_status_slots=true,legacy_strength_mapped=true,stable_export_roundtrip=true,ambiguous_mapping_blocked=true,armor_weights=#wr,suppressed=true,one_handed=true,helldiver_water_climbing=true,apex_reference_ability=true,sealed_output=true,game_writes=0}
