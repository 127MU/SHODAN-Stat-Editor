local ffi=require('ffi');local D=require('hostdata');local G=require('gamedata')
local blocks={};for _,file in pairs(D.files)do for _,h in ipairs(G.headers(file.p,file.n))do blocks[h.type]={p=file.p+h.at+24,n=h.size}end end
assert(QA_TYPE_HOOK_USED,'Storage instrumentation was not loaded')
local count,owners,floats,decoded,scaled_integer_parts,simple_checks=0,0,0,0,0,0;local mismatches,scopes,undecoded={},{},{}
for _,mode in ipairs({false,true})do
 B.editor_mode(mode)
 local tabs=mode and {'Terminids','Automatons','Illuminate','SEAF','Spawning'}or{'Primary','Secondary','Support','Throwables','Stratagems','Mechas','Boosters','Attachments','Helldiver','ArmorWeight','Records'}
 for _,tab in ipairs(tabs)do for _,item in ipairs(B.items(tab,''))do
  B.select(item.id);local w=B.registry[item.id];owners=owners+1;local shown=B.rows()
  for row_index,row in ipairs(w.rows)do for _,p in ipairs(row.parts)do
    count=count+1
    if row.storage=='f32'and p.field.storage~='virtual'then
      floats=floats+1
      if row.mult and p.field.storage~='f32' then scaled_integer_parts=scaled_integer_parts+1
      elseif p.field.storage~='f32'then mismatches[#mismatches+1]={owner=item.name,row=row.label,part=p.id,kind=p.field.kind,offset=p.field.offset,actual=p.field.storage,expected=row.storage}end
      local b=blocks[p.field.kind]
      if not b and QA_TABLES[p.field.kind] then local t=QA_TABLES[p.field.kind];b={p=ffi.cast('uint8_t*',t.copies[1]+24),n=t.payload} end
      if p.field.storage=='f32'and b and p.field.offset>=0 and p.field.offset+4<=b.n then
        local v=tonumber(ffi.cast('float*',b.p+p.field.offset)[0]);assert(v==v and math.abs(v)<math.huge,'Nonfinite value: '..item.name..' / '..row.label);decoded=decoded+1
        if #row.parts==1 and not(row.mult or row.span or row.scale or row.zero or row.choice or p.field.unset) then
          local r=shown[row_index];assert(r and type(r.value)=='number','Missing numeric UI value')
          assert(math.abs(r.value-v)<=math.max(1,math.abs(v))*1e-6,'UI/float bytes disagree: '..item.name..' / '..row.label)
          local original=SHODAN_OFFLINE_DEFAULT_READ(tonumber(ffi.cast('uintptr_t',b.p+p.field.offset)),4)
          assert(original,'Missing immutable bytes: '..item.name..' / '..row.label)
          local base=tonumber(ffi.cast('const float*',original)[0]);assert(type(r.original)=='number'and math.abs(r.original-base)<=math.max(1,math.abs(base))*1e-6,'Default/float bytes disagree: '..item.name..' / '..row.label)
          simple_checks=simple_checks+1
        end
      elseif p.field.storage=='f32' then undecoded[#undecoded+1]={kind=p.field.kind,offset=p.field.offset,owner=item.name,row=row.label} end
    end
  end end
  if tab=='Attachments'then for _,r in ipairs(shown)do if r.label:find('放大倍率',1,true)or r.label:find('归零距离',1,true)or r.label:find('跟随速度',1,true)then
    scopes[#scopes+1]={owner=item.name,label=r.label,value=r.value,original=r.original}
  end end end
 end end
end
local conflicts,float_conflicts={},0
for _,v in pairs(QA_TYPE_CONFLICTS)do conflicts[#conflicts+1]=v;if v.existing=='f32'or v.requested=='f32'then float_conflicts=float_conflicts+1 end end
local scope_write_checks,preset_roundtrips=0,0
if float_conflicts==0 and #mismatches==0 then
 B.editor_mode(false)
 for _,item in ipairs(B.items('Attachments',''))do
  B.select(item.id);local selected=B.registry[item.id];local rows=B.rows()
  for _,r in ipairs(rows)do if r.label:find('放大倍率',1,true)or r.label:find('归零距离',1,true)or r.label:find('跟随速度',1,true)then
    local f=selected.rows[r.id].parts[1].field;assert(f.storage=='f32','Scope registered as integer')
    local t=QA_TABLES[f.kind];local p=ffi.cast('float*',t.copies[1]+24+f.offset)
    local target=r.original+0.125;B.set(r.id,target)
    assert(math.abs(tonumber(p[0])-target)<1e-5,'Wrong write type: '..item.name..' / '..r.label)
    assert(B.rows()[r.id].original==r.original,'Write replaced immutable default')
    B.reset(r.id);assert(math.abs(tonumber(p[0])-r.original)<1e-5,'Restore wrote integer bits')
    scope_write_checks=scope_write_checks+1
  end end
  if item.id=='FFFFFFFFE8C28B34' then
    local zoom;for _,r in ipairs(B.rows())do if selected.rows[r.id].id=='zoom1'then zoom=r end end
    assert(zoom and zoom.original==1,'4x scope default is not 1.0')
    B.set(zoom.id,1.25);B.preset('save',5);local text=B.preset_export('weapon',5)
    assert(text:find('zoom1 1.25',1,true),'Preset exported the float bit pattern')
    B.reset(zoom.id);B.preset('load',5);assert(B.rows()[zoom.id].value==1.25)
    B.reset(zoom.id);preset_roundtrips=preset_roundtrips+1
  end
 end
 assert(scope_write_checks==#scopes and preset_roundtrips==1,'Scope write coverage incomplete')
end
return {owners=owners,parts=count,float_parts=floats,raw_float_decodes=decoded,float_storage_mismatches=#mismatches,float_request_conflicts=float_conflicts,storage_conflicts=#conflicts,conflicts=conflicts,mismatches=mismatches,scopes=scopes,scope_values=#scopes,scaled_integer_parts=scaled_integer_parts,undecoded=undecoded,ui_float_byte_checks=simple_checks,scope_write_checks=scope_write_checks,preset_roundtrips=preset_roundtrips,game_writes=0}
