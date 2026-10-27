"""Read actual bundles to audit effect donors and mount hashes; never install."""
import argparse,json,os,pathlib,sys,time

def main():
 p=argparse.ArgumentParser();p.add_argument('--vendor',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
 root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
 profile=out/'profile';profile.mkdir();(profile/'game folder.txt').write_text('D:/steam/steamapps/common/Helldivers 2','utf8')
 os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,a.vendor)
 from lupa.luajit21 import LuaRuntime
 lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix())
 lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
 started=time.monotonic()
 result=lua.execute('''
require('install').write_files=function()error('Game writes forbidden')end
local R=ShodanStatEditor.resident;local M=require('res_patch');local ctx=assert(R.ctx())
local write=M.write_file;M.write_file=function(path,bytes)assert(not path:find(ctx.root,1,true),'Game writes forbidden');return write(path,bytes)end
B.editor_mode(false);B.items('Primary','');B.select('968211C0033DCE64')
local shot
for _,r in ipairs(B.rows())do if r.projectile_source then shot=r.id;break end end
assert(shot,'No projectile selector')
local checks={}
for _,id in ipairs({67,253})do
 B.choose(shot,id);local mode
 for _,r in ipairs(B.rows())do if r.choice_kind=='resomode'then mode=B.registry['968211C0033DCE64'].rows[r.id]end end
 assert(mode)
 local initial=assert(R.targets(mode));local resources,events,err=R.dependencies(mode.page);assert(not err,err)
 assert(#resources>0,'Actual effect resource hashes were not collected')
 local names,missing=M.resolve_resources(ctx,initial,resources,events);assert(names,missing)
 for _,s in ipairs(missing)do assert(s:sub(1,#'资源 ')~='资源 ',s)end
 local dep={projectile=id,resources=#resources,events=#events,preferred=#initial,packages=#names,unresolved={}}
 for _,s in ipairs(missing)do dep.unresolved[#dep.unresolved+1]=s end
 checks[#checks+1]=dep
 -- Exercise the real UI action, substituting only the final disk writer.
 local install=M.install_many;local getenv=os.getenv;local running=require('install').game_running
 local captured
 M.install_many=function(_,_,targets,mode,group,signature)
  captured=targets;assert(mode=='full' and group and signature)
  local infos={};for i=1,#targets do infos[i]={index=i,entries=1,toc=1,gpu=0,stream=0}end;return infos
 end
 os.getenv=function(k)if k=='SHODAN_QA_OUTPUT' or k=='SHODAN_HUSKAR_QA'then return nil end;return getenv(k)end
 require('install').game_running=function()return false end
 local ok,message=R.act(mode,1)
 os.getenv=getenv;require('install').game_running=running;M.install_many=install
 assert(ok,message);assert(captured and #captured==#names,'UI action lost automatically located packages')
end
-- Audit every explosion's payload-relative shake list against its raw bytes.
local function upvalue(fn,wanted)
 for n=1,100 do local key,value=debug.getupvalue(fn,n);if not key then break end;if key==wanted then return value end end
 error('Missing test upvalue: '..wanted)
end
local tables=upvalue(R.dependencies,'tables');local api=upvalue(R.dependencies,'api')
local blast=tables[0x2AEA2592];assert(blast)
local function u32(bytes,off)return M._internal.le(bytes,off,4)end
local explosions,shake_lists,shake_ids=0,0,0
for id,at in pairs(blast.index)do
 local resources,events,err=R.dependencies({record=true,kind=0x2AEA2592,id=id,rows={}})
 assert(not err,err);explosions=explosions+1
 local row=api.read(blast.copies[1]+24+at,152)
 local rel,count=u32(row,40),u32(row,48)
 if count>0 then
  shake_lists=shake_lists+1
  local raw=api.read(blast.copies[1]+24+rel,count*8)
  local got={};for _,r in ipairs(resources)do got[r.type_hex..':'..r.id_hex]=true end
  for i=0,count-1 do
   local bytes=raw:sub(i*8+1,i*8+8)
   if bytes~=string.rep('\\0',8)then
    local hex={};for n=8,1,-1 do hex[#hex+1]=string.format('%02x',bytes:byte(n))end
    assert(got['fcaaf813b4d3cc1e:'..table.concat(hex)],'Lost payload-relative shake')
    shake_ids=shake_ids+1
   end
  end
 end
end
assert(explosions>400 and shake_lists>0 and shake_ids>0)
local unique_resources=0;for _ in pairs(ctx.resource_index)do unique_resources=unique_resources+1 end
assert(unique_resources>40000,'Actual bundle index is incomplete')
-- Malformed arrays must stop installation, without reading outside the allocation.
local id,at=next(blast.index);local address=blast.copies[1]+24+at+40
local original=api.read(address,12)
local function malformed(pointer,count)
 assert(api.write(address,pointer..M._internal.u32(count)))
 local _,_,why=R.dependencies({record=true,kind=0x2AEA2592,id=id,rows={}})
 assert(api.write(address,original));assert(why and why:find('越界',1,true),tostring(why))
end
malformed(M._internal.u64(blast.payload-4),2)
malformed(M._internal.u32(16)..M._internal.u32(1),1)
B.reset();local hashes=0
for _,item in ipairs(B.items('Mechas',''))do
 B.select(item.id)
 for _,r in ipairs(B.rows())do
  if r.label:find('附着节点哈希',1,true) or r.label:find('挂点名',1,true)then
   assert(r.text:match('^0x%x%x%x%x%x%x%x%x$'));assert(r.default_text:match('^0x%x%x%x%x%x%x%x%x$'))
   assert(tonumber(r.text)==r.value)
   B.set(r.id,r.text)
   assert(not pcall(B.set,r.id,'-1'));assert(not pcall(B.set,r.id,'0x100000000'))
   hashes=hashes+1
  end
 end
end
assert(hashes>0,'Mount hash rows not exercised')
return {hash_fields=hashes,checks=checks,explosions=explosions,shake_lists=shake_lists,shake_ids=shake_ids,unique_resources=unique_resources,
 malformed_arrays_rejected=true,game_writes=0}
''')
 def convert(v):
  if hasattr(v,'items'):
   d={k:convert(x) for k,x in v.items()}
   return [d[i] for i in range(1,len(d)+1)] if d and all(isinstance(k,int) for k in d) else d
  return v
 report=convert(result);report['elapsed_seconds']=round(time.monotonic()-started,2)
 (out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),'utf8');print(json.dumps(report,ensure_ascii=False))

if __name__=='__main__':main()
