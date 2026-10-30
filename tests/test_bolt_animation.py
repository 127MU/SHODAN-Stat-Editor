import argparse,json,os,pathlib,sys
p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',required=True);a=p.parse_args();root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2','utf8');os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,a.vendor)
from lupa.luajit21 import LuaRuntime
lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix());lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
r=lua.execute('''
local D=require('hostdata');local ffi=require('ffi');require('install').write_files=function()error('No game writes')end
B.items('Primary','');local count=0
for hash,n in pairs({B6AFF2195568767F=3,['41F2DEF484634B59']=1})do
 B.select(hash);local owner=B.registry[hash];local row
 for i,r in ipairs(owner.rows)do if r.id=='disable_bolt'then row=B.rows()[i];assert(#r.parts==n);for _,p in ipairs(r.parts)do assert(p.field.bolt_on>0 and p.field.bolt_off>0)end end end
 assert(row and row.flag and row.value==0,'Missing/default switch '..hash)
 local snapshots={};for name,f in pairs(D.files)do snapshots[name]=ffi.string(f.p,f.n)end
 B.set(row.id,1);assert(B.rows()[row.id].value==1)
 local changed=0;for name,f in pairs(D.files)do local after=ffi.string(f.p,f.n);if after~=snapshots[name]then assert(name=='generated_entities.dl_bin');for i=1,#after do if after:byte(i)~=snapshots[name]:byte(i)then changed=changed+1 end end end end
 assert(changed>0 and changed<=n*4)
 B.preset('save',5);B.reset(row.id);assert(B.rows()[row.id].value==0);B.preset('load',5);assert(B.rows()[row.id].value==1)
 B.reset(row.id);for name,f in pairs(D.files)do assert(ffi.string(f.p,f.n)==snapshots[name],'Restore changed other bytes')end
 count=count+1
end
return {weapons=count,game_writes=0,preset_roundtrip=true,byte_scope=true}
''');result=dict(r.items());(out/'report.json').write_text(json.dumps(result,indent=2),'utf8');print(json.dumps(result))
