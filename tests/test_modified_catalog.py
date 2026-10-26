"""Verify live changed metadata and experimental labels without game writes."""
import argparse,pathlib,os,sys,json

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',type=pathlib.Path,required=True);a=p.parse_args()
 root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir()
 (profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8');os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,str(a.vendor))
 from lupa.luajit21 import LuaRuntime
 lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix());lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
 result=lua.execute('''require('install').write_files=function()error('No game writes')end
 B.editor_mode(false)
 local item=assert(B.items('Primary','')[1]);B.select(item.id)
 local field;for _,r in ipairs(B.rows())do if not r.choice and not r.flag and not r.code and type(r.value)=='number' and r.value==r.original then field=r;break end end;assert(field)
 B.set(field.id,field.value+1)
 local function changed()for _,x in ipairs(B.items('Primary',''))do if x.id==item.id then return x.changed end end end
 assert(changed(),'Edited item missing changed metadata');B.reset(field.id);assert(not changed(),'Reset item still marked changed')
 local mounts,sm,supply=0,0,0
 for _,x in ipairs(B.items('Mechas',''))do B.select(x.id);for i,r in ipairs(B.rows())do
 local key=B.registry[x.id].rows[i].id
 if x.english:lower():find('supply frv',1,true)then assert(not key:find('_anchor_',1,true),'Supply FRV anchor remained editable');if key:match('^mount%d+_flag')then supply=supply+1 end end
 if key:match('^mount%d+_')then assert(r.label:find('实验性',1,true),r.label);mounts=mounts+1 end
 end end
 for _,x in ipairs(B.items('Stratagems',''))do B.select(x.id);for _,r in ipairs(B.rows())do
 if r.choice_kind=='smmode' or r.choice_kind=='smres'then assert(r.label:find('实验性',1,true));sm=sm+1 end
 end end
 assert(mounts>0 and sm>0 and supply>0)
 return {live_change_detection=true,reset_clears_marker=true,supply_flags_retained=supply,experimental_mount_fields=mounts,experimental_state_machine_fields=sm,game_writes=0}
 ''')
 report=dict(result.items());(out/'report.json').write_text(json.dumps(report,indent=2),'utf8');print(json.dumps(report))
if __name__=='__main__':main()
