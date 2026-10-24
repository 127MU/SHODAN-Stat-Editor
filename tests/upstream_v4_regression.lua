local G=require('gamedata');local D=require('hostdata');local I=require('install');local ffi=require('ffi')
local counts={};for _,tab in ipairs({'Terminids','Automatons','Illuminate','SEAF','Spawning','Boosters'})do counts[tab]=#B.items(tab,'');assert(counts[tab]>0,tab)end
assert(counts.Boosters==7)
local names={};for _,item in ipairs(B.items('Terminids',''))do names[item.id]=item.name;assert(#item.groups>0,'Enemy group metadata missing')end
assert(names['36AA99CCE5E60146']=='腐蚀喷涌虫','Caustic variant translation does not match workbook T27')
assert(names['6B202392F4AB605E']=='腐蚀强袭虫','Caustic Charger translation does not match workbook T32')
assert(names['5CA832447445C0BA']=='追猎虫 MK3','Hunter variant translation does not match workbook P15')
for _,item in ipairs(B.items('Mechas',''))do assert(#item.groups>0,'Vehicle group metadata missing')end

local records=B.items('Records','')
for _,case in ipairs({{67,'质量',1000000},{226,'重力',-2.5}})do
 local id=string.format('F1%014X',case[1]);local exists=false
 for _,item in ipairs(records)do if item.id==id then exists=true end end
 assert(exists,'Projectile record missing: '..case[1]);B.select(id)
 local target;local angles=0
 for _,r in ipairs(B.rows())do
  if r.label:find(case[2],1,true)then target=r end
  if r.label:find('引爆判定角',1,true) or r.label:find('爆炸角',1,true)then angles=angles+1 end
 end
 assert(target and target.value~=nil,'Projectile value unread: '..case[1])
 assert(angles==1,'Duplicate blast angle rows: '..angles)
 B.set(target.id,case[3]);assert(B.rows()[target.id].value==case[3],'Projectile input capped')
 B.set(target.id,0.000001);assert(math.abs(B.rows()[target.id].value-0.000001)<1e-12,'Small float rounded to zero')
 B.reset(target.id)
end
B.editor_mode(true);assert(#B.full_presets()==4);B.editor_mode(false);assert(#B.full_presets()==0)
local primary=B.items('Primary','')[1];B.select(primary.id)
local damage,slot;for _,r in ipairs(B.rows())do if r.label=='伤害' and not damage then damage=r end;if r.choice_kind=='slot' then slot=r end end
assert(damage and slot);B.set(damage.id,3000000000);assert(B.rows()[damage.id].value==3000000000,'UI cap retained');B.reset(damage.id)
B.choose(slot.id,3);assert(B.rows()[slot.id].value==3);B.reset(slot.id)
local enemy=B.items('Terminids','')[2];B.select(enemy.id);local health
for _,r in ipairs(B.rows())do if r.label=='生命值' and not health then health=r end end
assert(health);B.set(health.id,health.original+500);assert(B.rows()[health.id].value==health.original+500)
local ehealth=health;local eid=enemy.id
local chosen,code
for _,item in ipairs(B.items('Stratagems',''))do B.select(item.id);for _,r in ipairs(B.rows())do if r.code then chosen=item;code=r;break end end;if code then break end end
assert(code);print('code',chosen.name,code.text)
B.code_set(code.id,{4,4,4,4,4,4,4,4,4});assert(B.rows()[code.id].text=='← ← ← ← ← ← ← ← ←')
B.tweaks('bounce',true);assert(B.tweaks().bounce)
local preview=B.install_preview();assert(#preview.problems==0,table.concat(preview.problems,';'))
local files;I.game_running=function()return false end;I.write_files=function(_,f)files=f;return true end
B.install();assert(B.write_succeeded(),'Installation coordinator failed');assert(files['generated_stratagem_settings.dl_bin'] and files['generated_entities.dl_bin'])
for name,sealed in pairs(files)do local p,n=G.open_sealed(sealed);assert(p,n);assert(G.game_dll_has(I.read(B.game..'/game.dll'),G.murmur64(p,n)),name);G.free(p)end
B.reset(code.id);B.tweaks('bounce',false);B.select(eid);B.reset(ehealth.id)
local plan,problems=D.diff();for _,c in ipairs(plan)do G.free(c.plain)end;assert(#problems==0)
return {terminids=counts.Terminids,automatons=counts.Automatons,illuminate=counts.Illuminate,seaf=counts.SEAF,spawning=counts.Spawning,boosters=counts.Boosters,enemy_presets_separate=true,weapon_slot=true,nine_arrow_code=true,numeric_caps_removed=true,game_hash_valid=true,game_writes=0}
