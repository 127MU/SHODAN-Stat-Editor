"""Verify documented Guard Dog default builds and presets; never install."""
import argparse,json,os,pathlib,sys,time,subprocess

def main():
 p=argparse.ArgumentParser();p.add_argument('--vendor',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
 resume=os.environ.get('DOG_DEFAULTS_RESUME')=='1'
 root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=resume)
 profile=out/'profile';profile.mkdir(exist_ok=resume);(profile/'game folder.txt').write_text('D:/steam/steamapps/common/Helldivers 2','utf8')
 os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,a.vendor)
 from lupa.luajit21 import LuaRuntime
 lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix())
 lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
 started=time.monotonic()
 result=lua.execute('''
require('install').write_files=function()error('Game writes forbidden')end
local ffi=require('ffi');local R=ShodanStatEditor.resident;local M=require('res_patch');local ctx=assert(R.ctx())
M.write_file=function()error('Patch writes forbidden')end
B.editor_mode(false);B.items('Secondary','')
if os.getenv('DOG_DEFAULTS_RESUME')=='1' then
 B.select('3575AABC5F1F9326');local a,b
 for _,r in ipairs(B.rows())do if r.label=='无人机直读射弹 ID'then a=r elseif r.choice_kind=='dogmag'then b=r end end
 assert(a and a.value==296 and a.original==0 and b and b.value==1 and b.original==0,'Default build lost on restart')
 return {restart_persistence=true,game_writes=0}
end
local results={}
local function select_rows(hash)
 B.select(hash);local a,b
 for _,r in ipairs(B.rows())do if r.label=='无人机直读射弹 ID'then a=r elseif r.choice_kind=='dogmag'then b=r end end
 assert(a and b,'Missing explicit default-build controls');return a,b
end
for _,v in ipairs({{'3575AABC5F1F9326',296,1,'C891ACF9E8DBDA97'},{'05E4E5C2DB6E44A2',342,2,'4F839E923046E631'}})do
 local a,b=select_rows(v[1]);assert(a.original==0 and b.original==0,'Dormant original changed')
 local options=B.choices(b.id);assert(#options==2,'Wrong-magazine choices exposed')
 assert(not pcall(B.choose,b.id,v[3]==1 and 2 or 1),'Mismatched magazine accepted')
 B.choose(a.id,v[2]);a,b=select_rows(v[1]);B.choose(b.id,v[3]);a,b=select_rows(v[1])
 assert(a.value==v[2] and a.original==0 and b.value==v[3] and b.original==0)
 local owner=B.registry[v[1]];local part=owner.by_id.drone_magazine
 local field=part.field;local raw
 -- Inspect host memory only: the exact eight-byte reference must be preserved.
 for n=1,100 do local k,t=debug.getupvalue(R.dependencies,n);if k=='tables'then
  raw=ffi.string(ffi.cast('const char*',t[field.kind].copies[1]+24+field.offset),8);break
 end end
 local hex={};for n=8,1,-1 do hex[#hex+1]=string.format('%02X',raw:byte(n))end
 assert(table.concat(hex)==v[4],'u64 model reference lost precision')
 local resources,events,why=R.dependencies(owner);assert(not why,why)
 local models=0;for _,r in ipairs(resources)do if r.id_hex==v[4]:lower()then models=models+1 end end;assert(models>=2)
 local preferred={};local names,missing=M.resolve_resources(ctx,preferred,resources,events);assert(names,missing)
 for _,m in ipairs(missing)do assert(m:sub(1,#'资源 ')~='资源 ',m)end
 B.full_preset('new',nil,'无人机默认配置');local list=B.full_presets();local last=list[#list].id
 local portable=B.preset_export('full',last);assert(portable:find('drone_magazine',1,true))
 B.reset(a.id);a,b=select_rows(v[1]);B.reset(b.id)
 local preview=B.preset_inspect('full',portable);assert(preview.count>=2 and preview.skipped==0)
 B.full_preset('load',last);a,b=select_rows(v[1]);assert(a.value==v[2] and b.value==v[3])
 B.reset(a.id);a,b=select_rows(v[1]);B.reset(b.id);a,b=select_rows(v[1]);assert(a.value==0 and b.value==0)
 results[#results+1]={weapon=v[1],projectile=v[2],model=v[4],resources=#resources,packages=#names}
end
-- Prove all sidearm/support entries are represented unless deliberately excluded.
local MOD,tables
for n=1,100 do local k,v=debug.getupvalue(R.dependencies,n);if k=='MOD'then MOD=v elseif k=='tables'then tables=v end end
assert(MOD and tables)
MOD.dogs.ensure();local eligible,excluded,recipe_count,field_checks=0,0,0,0
local excluded_items={}
for _,tab in ipairs({'Secondary','Support'})do
 for _,item in ipairs(B.items(tab,''))do
  local owner=B.registry[item.id];local raw=MOD.refs.hex(owner.key)
  local id=MOD.dogs.by_bytes[owner.key]
  if not id then
   local why=MOD.dogs.excluded[raw];assert(why,'Player weapon omitted without reason: '..item.name)
   excluded=excluded+1;excluded_items[#excluded_items+1]={name=item.name,reason=why}
  else
   eligible=eligible+1;B.select(item.id);B.rows()
   local recipe=MOD.dogs.recipes[owner.hash]
   if recipe and #recipe.fields>0 then
    recipe_count=recipe_count+1
    for _,field in ipairs(recipe.fields)do
     local part=owner.by_id[field.id];assert(part,'Missing default-build field: '..item.name..' / '..field.id)
     local n;for i,row in ipairs(owner.rows)do if row==part.row then n=i;break end end;assert(n)
     B.set(n,field.value)
     local bytes=ffi.string(ffi.cast('const char*',tables[field.kind].copies[1]+24+field.offset),field.model and 8 or 4)
     assert(bytes==field.bytes,'Default delta was applied incorrectly: '..item.name..' / '..field.id)
     field_checks=field_checks+1;B.reset(n)
    end
   end
  end
 end
end
assert(eligible>40 and recipe_count>2 and field_checks>10,'Coverage did not extend beyond the two examples')
local a,b=select_rows('3575AABC5F1F9326');B.choose(a.id,296);a,b=select_rows('3575AABC5F1F9326');B.choose(b.id,1);B.flush()
return {eligible=eligible,excluded=excluded,excluded_items=excluded_items,recipe_weapons=recipe_count,default_field_checks=field_checks,recipes=results,immutable_defaults=true,u64_exact=true,preset_roundtrip=true,model_residency=true,game_writes=0}
''')
 def convert(v):
  if hasattr(v,'items'):
   d={k:convert(x) for k,x in v.items()}
   return [d[i] for i in range(1,len(d)+1)] if d and all(isinstance(k,int) for k in d) else d
  return v
 report=convert(result);report['elapsed_seconds']=round(time.monotonic()-started,2)
 if not resume:
  child=subprocess.run([sys.executable,str(pathlib.Path(__file__).resolve()),'--vendor',a.vendor,'--output',str(out)],env=dict(os.environ,DOG_DEFAULTS_RESUME='1'),capture_output=True,text=True,encoding='utf8',timeout=45)
  assert child.returncode==0,child.stdout+child.stderr
  assert json.loads(child.stdout)['restart_persistence']
  report['restart_persistence']=True
 (out/('restart-report.json' if resume else 'report.json')).write_text(json.dumps(report,ensure_ascii=False,indent=2),'utf8');print(json.dumps(report,ensure_ascii=False))

if __name__=='__main__':main()
