-- Run against an isolated profile and the production desktop bridge (B).
-- Game writes are deliberately forbidden even if a regression calls Install.
local I=require('install')
local writer=I.write_files
I.write_files=function() error('QA must never write game files') end
local running=I.game_running
I.game_running=function() return true end
assert(B.install():find('running') or B.install():find('运行'))
assert(B.restore())
I.game_running=running

-- Drive the real install coordinator with synthetic prepared data and a fake
-- writer, so progress reporting is tested without touching the game directory.
local D=require('hostdata')
local saved={diff=D.diff,stack=D.stack,build=D.build,write=I.write_files,running=I.game_running}
local progress,writes={},0
local old_progress=SHODAN_EUI_PROGRESS
SHODAN_EUI_PROGRESS=function(message,done,total) progress[#progress+1]={message,done,total} end
D.diff=function() return {{name='qa_one.dl_bin'},{name='qa_two.dl_bin'}},{} end
D.stack=function() return true end
D.build=function(c) return 'qa prepared '..c.name end
I.game_running=function() return false end
I.write_files=function() writes=writes+1;return true end
assert(B.install())
D.diff,D.stack,D.build,I.write_files,I.game_running=saved.diff,saved.stack,saved.build,saved.write,saved.running
SHODAN_EUI_PROGRESS=old_progress
assert(writes==1,'install did not reach the fake writer')
local first,last=false,false
for _,event in ipairs(progress) do
 assert(type(event[1])=='string' and event[1]~='')
 if event[2]==1 and event[3]==2 then first=true end
 if event[2]==2 and event[3]==2 then last=true end
end
assert(first and last,'file preparation progress is missing')

local pages,fields,choices,helped=0,0,0,0
for _,tab in ipairs({'Primary','Secondary','Support','Throwables','Stratagems','Mechas','Attachments','Records'}) do
 local entries=B.items(tab,'')
 assert(#entries>0,tab..' is empty')
 for k=1,math.min(#entries,6) do
  B.select(entries[k].id)
  local rows=B.rows();assert(#rows>0)
  pages=pages+1
  for _,row in ipairs(rows) do
   assert(type(row.label)=='string' and row.label~='')
   assert(type(row.help)=='table','parameter help is missing from the bridge')
   for _,line in ipairs(row.help) do assert(type(line)=='string' and line~='');helped=helped+1 end
   if row.value~=nil then assert(row.original~=nil,'missing original: '..row.label) end
   fields=fields+1
   if row.choice then
    local list=B.choices(row.id);assert(#list>0,'missing named choices')
    for _,c in ipairs(list) do assert(type(c.id)=='number' and type(c.name)=='string') end
    choices=choices+1
   end
  end
 end
end
assert(helped>0,'original parameter descriptions were not exported')
local entries=B.items('Primary','');B.select(entries[1].id)
local rows=B.rows();local first
for _,row in ipairs(rows) do if not row.choice and not row.flag and row.value then first=row;break end end
assert(first)
local before=first.value
B.set(first.id,before+1)
assert(B.rows()[first.id].value~=before)
assert(not pcall(B.set,first.id,'invalid-number'))
assert(not pcall(B.set,first.id,math.huge))
B.preset('save',5)
B.set(first.id,before)
B.preset('load',5)
assert(B.rows()[first.id].value~=before,'per-weapon preset failed')
B.reset(first.id);assert(B.rows()[first.id].value==first.original)
B.preset('clear',5)
B.set(first.id,before)

local count=#B.full_presets()
B.full_preset('new',0,'界面回归测试')
local full=B.full_presets();assert(#full==count+1)
local saved
for _,p in ipairs(full) do if p.name=='界面回归测试' then saved=p.id end end
assert(saved);B.full_preset('delete',saved)
assert(#B.full_presets()==count)

local armor_fields=0
for _,p in ipairs(B.armor_list) do
 local values=B.armor_rows(p.id)
 for _,r in ipairs(values) do
  local old=r.value
  assert(type(r.default)=='number','armor baseline missing')
  assert(B.armor_set(p.id,r.key,old)~=nil)
  armor_fields=armor_fields+1
 end
end
assert(armor_fields>0)
local passive=B.armor_list[1].id
local profile=B.armor_profile(999)
local previous=profile.enabled[passive] or false
B.armor_update(999,passive,not previous)
assert(B.armor_profile(999).enabled[passive]==not previous)
B.armor_update(999,passive,previous)
B.flush()
I.write_files=writer
return {pages=pages,fields=fields,choices=choices,armor_fields=armor_fields,progress_events=#progress,game_writes=0}
