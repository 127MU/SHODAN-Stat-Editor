local F=require('desktop_features')
local lock,spray,sticky,pid=0,0,0,0
local expected={['FAF-14 Spear']={300,1},['P-92 Warrant']={60,0.1},['P-33 Missile Pistol']={100,0.75},['StA-X3 W.A.S.P.']={300,0.5},['MLS-4X Commando']={300,2}}
for _,tab in ipairs({'Primary','Secondary','Support','Throwables'})do
 for _,item in ipairs(B.items(tab,''))do
  B.select(item.id);local w=B.registry[item.id];local rows=B.rows();local map={};for n,r in ipairs(w.rows)do map[r.id]=rows[n] end
  for n,r in ipairs(w.rows)do
   if r.id=='lock_range' then
    lock=lock+1;assert(r.parts[1].field.kind==0x14729B6A)
    assert(rows[n].label=='锁定距离（米）')
   elseif r.id=='spray_warmup' then spray=spray+1
   elseif r.id=='sticky_rx' then sticky=sticky+1;assert(r.parts[1].field.signed)
   elseif r.id=='missile_pid_p' then pid=pid+1 end
  end
  local checks=expected[item.english]
  if checks then
   local range,time=map.lock_range,map.lock_time
   assert(range and time,'Lock fields missing for '..item.english)
   assert(math.abs(range.original-checks[1])<0.001 and math.abs(time.original-checks[2])<0.001,'Wrong lock defaults')
   B.set(range.id,450);assert(B.rows()[range.id].value==450)
   local encoded=F.encode('weapon','lock regression',item.id,{{hash=item.id,id='lock_range',value=450},{hash=item.id,id='lock_time',value=0.05}})
   assert(B.preset_inspect('weapon',encoded).skipped==0);B.reset()
  end
 end
end
assert(lock==5 and spray>=5 and sticky>=10 and pid>=4,'New component coverage incomplete')
B.select('968211C0033DCE64');local row
for _,r in ipairs(B.rows())do if r.choice_kind=='status' then row=r.id;break end end
local choices=B.choices(row);assert(#choices==74,'All 73 statuses plus None must be present')
local thermite=false;for _,c in ipairs(choices)do if c.id==13 then thermite=c.name:find('热熔',1,true)~=nil end end;assert(thermite)
return {lock_weapons=lock,spray_weapons=spray,sticky_items=sticky,pid_weapons=pid,statuses=73,preset_roundtrip=true,game_writes=0}
