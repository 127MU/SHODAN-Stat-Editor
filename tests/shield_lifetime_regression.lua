-- Exercise the production bridge and sealed output without writing game files.
local ffi=require('ffi');local D=require('hostdata');local G=require('gamedata');local I=require('install')
local relay
for _,item in ipairs(B.items('Stratagems',''))do
 if item.english=='Shield Generator Relay' or item.english=='FX-12 Shield Generator Relay' then relay=item end
end
assert(relay,'Shield Generator Relay missing');B.select(relay.id)
local row,count=nil,0
for _,r in ipairs(B.rows())do if r.label=='防护罩持续时间（秒）' then row=r;count=count+1 end end
assert(row and count==1,'Shield lifetime missing or duplicated')
assert(row.value==40 and row.original==40,'Incorrect original relay lifetime')
assert(row.inline_note=='0 秒＝无限时间','Missing zero-time note')
local part=assert(B.registry[relay.id].rows[row.id].parts[1]);assert(part.field.kind==0xDDB5C03F)
local file=assert(D.files['generated_entities.dl_bin']);local offset
for _,h in ipairs(G.headers(file.p,file.n))do if h.type==part.field.kind then offset=h.at+24+part.field.offset end end
assert(offset and offset>=4 and offset+8<=file.n)
local before=ffi.string(file.p+offset-4,12)
B.set(row.id,0);assert(B.rows()[row.id].value==0);assert(ffi.cast('float*',file.p+offset)[0]==0)
B.reset(row.id);assert(B.rows()[row.id].value==40)
B.set(row.id,600);B.preset('save',5);B.reset(row.id);B.preset('load',5);assert(B.rows()[row.id].value==600)
B.preset('clear',5);B.reset(row.id);B.set(row.id,0)
local writes;I.game_running=function()return false end;I.write_files=function(_,f)writes=f;return true end
B.install();assert(B.write_succeeded(),'Install coordinator failed')
local p,n=G.open_sealed(assert(writes['generated_entities.dl_bin']));assert(p,n)
assert(ffi.cast('float*',p+offset)[0]==0,'Sealed output lifetime differs')
assert(ffi.string(p+offset-4,4)==before:sub(1,4),'RemoveTime changed')
assert(ffi.string(p+offset+4,4)==before:sub(9,12),'OnRetractAbility changed')
assert(G.game_dll_has(I.read(B.game..'/game.dll'),G.murmur64(p,n)),'Hash mismatch');G.free(p)
B.reset(row.id)
for _,item in ipairs(B.items('Stratagems',''))do
 if item.english=='Shield Generator Pack' or item.english=='SH-32 Shield Generator Pack' then
  B.select(item.id);for _,r in ipairs(B.rows())do assert(r.label~='防护罩持续时间（秒）','Relay timer leaked into backpack')end
 end
end
return {original_seconds=40,zero_saved=true,preset_roundtrip=true,reset_original=true,sealed_output=true,adjacent_fields_untouched=true,game_hash_valid=true,game_writes=0}
