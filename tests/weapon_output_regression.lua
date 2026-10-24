-- Prepare real sealed damage/projectile/entity files; replace only the disk writer.
local ffi=require('ffi');local D=require('hostdata');local G=require('gamedata');local I=require('install')
local writer,running=I.write_files,I.game_running
local writes,calls=nil,0
I.game_running=function()return false end
I.write_files=function(_,files)writes=files;calls=calls+1;return true end
local expected,checked={},0
for _,key in ipairs({'968211C0033DCE64','43A58CB89CFA197C','84354339522C932D'}) do
 local found
 for _,tab in ipairs({'Primary','Support'}) do for _,w in ipairs(B.items(tab,''))do if w.id==key then found=w end end end
 assert(found,'Missing weapon '..key);B.select(key)
 local damage,swap
 for _,row in ipairs(B.rows())do
  if row.label=='伤害' and not damage then damage=row end
  if row.choice and row.choice_kind=='' and not swap then swap=row end
 end
 assert(damage and swap,'Damage or projectile swap missing for '..key)
 B.set(damage.id,damage.original+321)
 local chosen
 for _,item in ipairs(B.choices(swap.id))do if item.id~=(swap.value or 0) and item.id==(key=='43A58CB89CFA197C' and 293 or 311) then chosen=item.id;break end end
 assert(chosen,'Known projectile choice missing');B.choose(swap.id,chosen)
 local rows=B.rows();assert(rows[damage.id].value==damage.original+321 and rows[swap.id].value==chosen,'Selection was not applied')
 local weapon=B.registry[key]
 for _,r in ipairs({weapon.rows[damage.id],weapon.rows[swap.id]})do for _,part in ipairs(r.parts)do
  local field=part.field
  for name,file in pairs(D.files)do for _,h in ipairs(G.headers(file.p,file.n))do if h.type==field.kind then
   local offset=h.at+24+field.offset;assert(offset+4<=file.n)
   expected[#expected+1]={file=name,at=offset,bytes=ffi.string(file.p+offset,4)}
  end end end
 end end
 checked=checked+1
end
assert(#expected>=6,'No concrete output addresses')
B.install();assert(B.write_succeeded() and calls==1,'Install did not reach the fake writer')
local decoded={}
for _,e in ipairs(expected)do
 if not decoded[e.file]then local sealed=assert(writes[e.file],'Changed file omitted: '..e.file);local p,n=G.open_sealed(sealed);assert(p,n);decoded[e.file]={p=p,n=n};assert(G.game_dll_has(I.read(B.game..'/game.dll'),G.murmur64(p,n)),'Game hash mismatch')end
 local file=decoded[e.file];assert(e.at+4<=file.n and ffi.string(file.p+e.at,4)==e.bytes,'Saved damage/projectile bytes differ at '..e.file..'+'..e.at)
end
-- Simulate reopening with the installed files as working snapshots, while
-- preserving the immutable defaults. Reapplying the same settings must still
-- write those values; the coordinator must not restore them as "unchanged".
for name,sealed in pairs(writes)do
 local file=D.files[name]
 -- Armor stacks are deliberately reopened from the canonical armor reference
 -- by host.lua; only ordinary numeric working snapshots are loaded from disk.
 if file and name~='generated_customization_passive_bonuses.dl_bin' then
  local p,n=G.open_sealed(sealed);assert(p,n);G.clear_correction(p,n)
  for k=0,math.min(file.n,n)-1 do if not file.resolved[k]then file.p[k]=p[k]end end
  file.cipher=sealed;G.free(p)
 end
end
local all_files=D.files;local damage=assert(all_files['generated_damage_settings.dl_bin'])
D.files={['generated_damage_settings.dl_bin']=damage}
local baseline=damage.baseline;damage.baseline=damage.cipher
local old_plan=D.diff();assert(#old_plan==0,'Old snapshot comparison did not reproduce omission')
damage.baseline=baseline
local fixed_plan=D.diff();assert(#fixed_plan==1,'Immutable reference did not preserve the changed damage file')
for _,c in ipairs(fixed_plan)do G.free(c.plain)end
D.files=all_files
writes=nil;B.install();assert(B.write_succeeded() and calls==2,'Repeat write failed')
for _,e in ipairs(expected)do
 local p,n=G.open_sealed(assert(writes[e.file],'Repeat write omitted a modified file'))
 assert(p,n);assert(e.at+4<=n and ffi.string(p+e.at,4)==e.bytes,'Repeat install restored modified damage/projectile to stock');G.free(p)
end
-- A disabled manager neither applies queued inputs nor restores managed files.
B.mod_management(true)
B.managed_mods({{name='generated_damage_settings.dl_bin',label='QA managed damage',data=assert(writes['generated_damage_settings.dl_bin'])}})
B.install();assert(B.write_succeeded(),'Managed setup failed')
local marker=assert(I.read(I.home..'/managed-files.txt'));assert(marker:find('generated_damage_settings',1,true))
B.mod_management(false);B.managed_mods({})
local before_calls=calls;B.install();assert(not B.write_succeeded() and calls==before_calls,'Disabled manager overwrote a managed numeric file')
assert(#B.install_preview().problems>0,'Protected file was absent from preview')
B.restore();assert(B.write_succeeded() and writes['generated_damage_settings.dl_bin']==nil,'Disabled manager removed a numeric Mod')
assert(I.read(I.home..'/managed-files.txt')==marker,'Disabled manager rewrote its ledger')
B.mod_management(true);B.restore();assert(B.write_succeeded() and writes['generated_damage_settings.dl_bin'],'Enabled manager failed to restore its own Mod')
B.armor_update(999,assert(B.armor_list[1]).id,true,true,'stack')
local feedback=B.install();assert(B.write_succeeded(),'Stacked armor fixture failed')
assert(not feedback:find('Installed',1,true) and not feedback:find('Start the game',1,true),'Mixed armor install result left in English')
assert(feedback:find('护甲叠加',1,true),'Stacked armor summary was lost')

for _,file in pairs(decoded)do G.free(file.p)end
-- A pre-installed stratagem Mod can enlarge its final variable-length block.
-- Its validated working layout must survive preview/reinstall, with edits at
-- its own offsets rather than offsets from the shorter canonical table.
local name='generated_stratagem_settings.dl_bin'
local stock=assert(all_files[name]);local p,n=G.open_sealed(stock.baseline)
assert(p,n);G.clear_correction(p,n)
local headers=G.headers(p,n);local last=headers[#headers]
assert(last.at+24+last.size==n)
local grown=G.alloc(n+8);ffi.copy(grown,p,n);G.free(p)
ffi.cast('uint32_t*',grown+last.at+12)[0]=last.size+8
ffi.copy(grown+n,'MOD-TAIL',8)
local snapshot=G.seal(grown,n+8)
local file={p=grown,n=n+8,cipher=snapshot,baseline=stock.baseline,resolved={},hash=stock.hash}
D.files={[name]=file}
local at=last.at+24+100;local value=bit.bxor(grown[at],1);grown[at]=value
local plan,problems=D.diff();assert(#problems==0 and #plan==1,'Installed layout rejected')
assert(plan[1].n==n+8 and plan[1].plain[at]==value and ffi.string(plan[1].plain+n,8)=='MOD-TAIL','Installed layout or edit lost')
local address=tonumber(ffi.cast('uintptr_t',grown))+at
assert(D.original_bytes(address,1)==string.char(bit.bxor(value,1)),'Grown stratagem block lost immutable defaults')
local sealed,why=D.build(plan[1]);assert(sealed,why)
local built,length=G.open_sealed(sealed);assert(built,length)
assert(length==n+8 and built[at]==value and ffi.string(built+n,8)=='MOD-TAIL','Prepared output lost the installed Mod or edit')
assert(G.murmur64(built,length)==stock.hash,'Prepared stratagem hash does not match game.dll')
G.free(built)
grown[at]=bit.bxor(value,1)
plan,problems=D.diff();assert(#problems==0 and #plan==1,'Unchanged installed layout omitted from plan')
G.free(plan[1].plain)
ffi.cast('uint32_t*',grown+last.at+12)[0]=last.size+4
plan,problems=D.diff();assert(#plan==0 and #problems==1,'Unexpected in-memory layout change was accepted')
G.free(grown);D.files=all_files
I.write_files,I.game_running=writer,running
return {weapons=checked,output_fields=#expected,all_saved_fields_match=true,old_snapshot_omission_reproduced=true,repeat_install_preserves_changes=true,installed_stratagem_layout_preserved=true,unexpected_layout_change_rejected=true,disabled_mods_untouched=true,game_hash_valid=true,game_writes=0}
