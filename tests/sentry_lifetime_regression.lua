-- Run with the production B bridge, an isolated SHODAN_PROFILE and EXPECTED_SENTRIES.
-- Uses a fake install writer; never touches the game directory.
local ffi=require('ffi')
local D=require('hostdata');local G=require('gamedata');local I=require('install')
local writer,running=I.write_files,I.game_running
I.game_running=function()return false end
local writes,calls=nil,0
I.write_files=function(_,values)writes=values;calls=calls+1;return true end
local checked=0
local before={}
for _,sentry in ipairs(EXPECTED_SENTRIES) do
 local found
 for _,item in ipairs(B.items('Stratagems','')) do if item.id==sentry.key then found=item;break end end
 assert(found,'Missing sentry '..sentry.key);B.select(found.id)
 local lifetime
 for _,row in ipairs(B.rows()) do if row.label=='炮塔持续时间（秒）' then lifetime=row;break end end
 assert(lifetime and lifetime.original==sentry.original and lifetime.value==sentry.original,'Incorrect sentry lifetime baseline')
 assert(lifetime.inline_note=='0 秒＝无限时间','Unlimited-time note missing')
 assert(lifetime.min==0 and lifetime.max>=3600,'Timer range does not support zero or long durations')
 local file=assert(D.files['generated_entities.dl_bin'])
 before[sentry.key]=ffi.string(file.p+sentry.offset,12)
 B.set(lifetime.id,0);assert(B.rows()[lifetime.id].value==0)
 assert(ffi.cast('float*',file.p+sentry.offset+4)[0]==0,'Zero did not reach lifetime offset')
 assert(ffi.string(file.p+sentry.offset,4)==before[sentry.key]:sub(1,4),'Retraction delay changed')
 assert(ffi.string(file.p+sentry.offset+8,4)==before[sentry.key]:sub(9,12),'Retraction ability changed')
 B.reset(lifetime.id);assert(B.rows()[lifetime.id].value==sentry.original,'Reset used a modified baseline')
 -- Duration is persisted through the same per-equipment preset path.
 B.set(lifetime.id,600);B.preset('save',5);B.reset(lifetime.id);B.preset('load',5)
 assert(B.rows()[lifetime.id].value==600,'Per-sentry preset lost duration')
 B.preset('clear',5);B.reset(lifetime.id)
 B.set(lifetime.id,checked%2==0 and 0 or 600)
 sentry.row=lifetime.id;sentry.value=checked%2==0 and 0 or 600
 checked=checked+1
end
assert(checked==10,'Expected ten sentry types')
B.install();assert(B.write_succeeded() and calls==1,'Prepared output did not reach fake writer')
local sealed=assert(writes['generated_entities.dl_bin'])
local p,n=G.open_sealed(sealed);assert(p,n)
for _,sentry in ipairs(EXPECTED_SENTRIES) do
 assert(ffi.cast('float*',p+sentry.offset+4)[0]==sentry.value,'Sealed output timer differs from input')
 assert(ffi.string(p+sentry.offset,4)==before[sentry.key]:sub(1,4),'Prepared output changed retraction delay')
 assert(ffi.string(p+sentry.offset+8,4)==before[sentry.key]:sub(9,12),'Prepared output changed retraction ability')
end
G.free(p)
for _,sentry in ipairs(EXPECTED_SENTRIES) do B.select(sentry.key);B.reset(sentry.row) end
I.write_files,I.game_running=writer,running
return {sentries=checked,sealed_output=true,zero_supported=true,presets=true,original_defaults=true,adjacent_fields_untouched=true,game_writes=0}
