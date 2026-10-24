local ffi=require('ffi');local bit=require('bit');local D=require('hostdata');local G=require('gamedata');local F=require('desktop_features')
local blocks={};for name,file in pairs(D.files)do for _,h in ipairs(G.headers(file.p,file.n))do blocks[h.type]={p=file.p+h.at+24,n=h.size}end end
local function value(f)
 if f.storage=='virtual' then local v=f.value;if v==nil then v=f.default end;return type(v)=='number' and v or nil end
 local block=blocks[f.kind];if not block or f.offset<0 or f.offset+4>block.n then return nil end;local p=block.p+f.offset
 if f.storage=='f32' then return tonumber(ffi.cast('float*',p)[0]) end
 if f.storage=='u32' then return tonumber(ffi.cast('uint32_t*',p)[0]) end
 if f.storage=='u16' then return tonumber(ffi.cast('uint16_t*',p)[0]) end
 if f.storage=='u8' or f.storage=='flag' then return tonumber(p[0]) end
 if f.storage=='bit' then return bit.band(bit.rshift(tonumber(ffi.cast('uint16_t*',p)[0]),f.bit),1) end
end
local count,owners,skipped=0,0,0
for _,mode in ipairs({false,true})do
 B.editor_mode(mode);local values,seen={},{ }
 local tabs=mode and {'Terminids','Automatons','Illuminate','SEAF','Spawning'} or {'Primary','Secondary','Support','Throwables','Stratagems','Mechas','Boosters','Attachments','Helldiver','ArmorWeight','Records'}
 for _,tab in ipairs(tabs)do
  for _,item in ipairs(B.items(tab,''))do
   local w=B.registry[item.id];assert(w);owners=owners+1
   for _,row in ipairs(w.rows)do for _,p in ipairs(row.parts)do
    local v=value(p.field);if p.row and p.row.choice and #p.row.parts>1 and p.row.parts[1]==p then v=nil end;local key=w.hash..':'..p.id
    if v and v==v and math.abs(v)~=math.huge then
     if not seen[key] then values[#values+1]={hash=w.hash,id=p.id,value=v};seen[key]=p.field.key end
     assert(seen[key]==p.field.key,'Duplicate ID maps different fields: '..key)
    else skipped=skipped+1 end
   end end
  end
 end
 local text=F.encode('full','参数审计',nil,values,mode and 'enemy' or 'equipment')
 local decoded=F.decode(text);assert(#decoded.values==#values)
 local preview=B.preset_inspect('full',text);assert(preview.skipped==0,'Live catalog ID did not import')
 count=count+#values
end
B.editor_mode(false)
-- Record-only values must appear in the compare dialog, not disappear behind the equipment index.
local record;for _,item in ipairs(B.items('Records',''))do if item.id=='F100000000000043' then record=item end end
assert(record);B.select(record.id);local n;for _,r in ipairs(B.rows())do if r.label:find('质量',1,true)then n=r.id end end;assert(n)
B.set(n,2000000);local exported=B.full_preset('new',nil,'审计记录');local presets=B.full_presets();local last=presets[#presets].id
local portable=B.preset_export('full',last);B.reset(n);local preview=B.preset_inspect('full',portable);assert(preview.count>0,'Record-only preset missing from preview')
return {owners=owners,scalar_parameters=count,non_scalar_or_unavailable_parts=skipped,live_ids_roundtrip=true,record_preview=true,game_writes=0}
