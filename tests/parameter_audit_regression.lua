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
local count,owners,skipped,baseline_rows,reset_paths,unlimited_uses,arm_checks=0,0,0,0,0,0,0
local sampled={}
local function same(a,b) return a==b or type(a)=='number' and type(b)=='number' and math.abs(a-b)<=math.max(1,math.abs(b))*1e-6 end
for _,mode in ipairs({false,true})do
 B.editor_mode(mode);local values,seen={},{ }
 local tabs=mode and {'Terminids','Automatons','Illuminate','SEAF','Spawning'} or {'Primary','Secondary','Support','Throwables','Stratagems','Mechas','Boosters','Attachments','Helldiver','ArmorWeight','Records'}
 for _,tab in ipairs(tabs)do
  for _,item in ipairs(B.items(tab,''))do
   local w=B.registry[item.id];assert(w);owners=owners+1
   B.select(item.id)
   local displayed=B.rows()
   for _,row in ipairs(displayed)do
    if type(row.value)=='number' and type(row.original)=='number' then
     baseline_rows=baseline_rows+1
     assert(same(row.value,row.original),'Clean profile differs from immutable default: '..item.name..' / '..row.label..' '..row.value..' vs '..row.original)
     local slot=tab..':'..row.section
     if not sampled[slot] and not row.choice and not row.flag and not row.code and math.abs(row.value)<1000000 then
      sampled[slot]=true
      local before=row.original
      local ok=pcall(B.set,row.id,row.value+1)
      if ok then
       local edited=B.rows()[row.id]
       assert(same(edited.original,before),'Edited value became default: '..item.name..' / '..row.label)
       B.reset(row.id)
       local restored=B.rows()[row.id]
       assert(same(restored.value,before),'Reset did not restore immutable default: '..item.name..' / '..row.label)
       reset_paths=reset_paths+1
      end
     end
    end
   end
   if w.by_id and w.by_id.uses then
    local r=w.by_id.uses.row
    for _,shown in ipairs(displayed)do if w.rows[shown.id]==r and shown.original==4294967295 then
     assert(shown.inline_note:find('不限',1,true),'Unlimited-use sentinel has no explanation');unlimited_uses=unlimited_uses+1
    end end
   end
   if w.by_id and w.by_id.arm_health then
    local row=w.by_id.arm_health.row
    local first=row.parts[1]
    assert(first.id~='arm_zone_health' or value(first.field)~=4294967295,'Inherited arm zone used as real arm health')
    arm_checks=arm_checks+1
   end
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
return {owners=owners,scalar_parameters=count,baseline_rows=baseline_rows,reset_paths=reset_paths,unlimited_uses=unlimited_uses,arm_checks=arm_checks,non_scalar_or_unavailable_parts=skipped,live_ids_roundtrip=true,record_preview=true,game_writes=0}
