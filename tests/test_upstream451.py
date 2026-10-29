"""Audit numeric storage requests across every editable owner, without game writes."""
import argparse,json,os,pathlib,sys

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',type=pathlib.Path,required=True);p.add_argument('--runtime-dir',type=pathlib.Path);p.add_argument('--diagnose',action='store_true');a=p.parse_args()
 root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
 os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,str(a.vendor));from lupa.luajit21 import LuaRuntime
 lua=LuaRuntime();lua.globals().SHODAN_EUI=True
 app=a.runtime_dir.resolve()/'app' if a.runtime_dir else root/'offline';editor=app/'stat_editor.lua'if a.runtime_dir else root/'src/stat_editor.lua'
 source=editor.read_text(encoding='utf8');anchor='    local f = fields[key]\n    if not f then'
 assert source.count(anchor)==1
 source=source.replace(anchor,"""    local f = fields[key]
    QA_TYPE_HOOK_USED=true;QA_TABLES=tables
    if f and f.storage~=storage then
        local conflict=key..':'..f.storage..':'..storage
        if not QA_TYPE_CONFLICTS[conflict] then QA_TYPE_CONFLICTS[conflict]={key=key,kind=kind,offset=offset,existing=f.storage,requested=storage,trace=debug.traceback('',2)} end
    end
    if not f then""")
 lua.globals().QA_TYPE_CONFLICTS=lua.table();lua.globals().QA_SOURCE=source;lua.globals().QA_EDITOR=editor.as_posix()
 lua.execute("package.path=.....';'..package.path",(app/'?.lua').as_posix())
 lua.execute("local original=loadfile;loadfile=function(path)if path==QA_EDITOR then return loadstring(QA_SOURCE,'@'..path)end;return original(path)end;require('install').write_files=function()error('Game writes forbidden')end")
 lua.execute('arg={...}',editor.as_posix());lua.globals().B=lua.execute('return dofile(...)',(app/'host.lua').as_posix())
 result=lua.execute(r"""
 local V=require('vehicles');local ffi=require('ffi');local B=B
 assert(not B.game_text('name').available,'Unselected read must not fail or open an error dialog')
 assert(V.shared and V.shared.size>0 and next(V.texts),'Missing archive metadata or game strings')
 local tested=0;local infinite=0;local holsters=0;local twins=0
 for _,tab in ipairs({'Primary','Secondary','Support','Stratagems','Mechas'})do for _,item in ipairs(B.items(tab,''))do
  B.select(item.id);local w=B.registry[item.id]
  for _,r in ipairs(B.rows())do local raw=w.rows[r.id]
   if raw.id=='infinite_ammo' then infinite=infinite+1;if infinite==1 then B.set(r.id,1);assert(B.rows()[r.id].value==1);B.reset(r.id);assert(B.rows()[r.id].value==0)end end
   if raw.choice=='holster' then holsters=holsters+1;if holsters==1 then assert(#B.choices(r.id)==2);B.choose(r.id,1);assert(B.rows()[r.id].value==1);B.reset(r.id);assert(B.rows()[r.id].value==0)end end
   if raw.choice=='pod_twin' then twins=twins+1;if twins==1 then assert(#B.choices(r.id)==2);B.choose(r.id,2);assert(B.rows()[r.id].value==2);B.reset(r.id);assert(B.rows()[r.id].value==1)end end
   local f=raw.parts[1].field
   if f.kind==0x5F7203C8 and raw.storage=='f32' and #raw.parts==1 and not raw.mult and tested==0 then
    local initial=r.original;assert(type(initial)=='number');B.set(r.id,initial+0.125);assert(B.rows()[r.id].original==initial);assert(V.patch());B.reset(r.id);assert(B.rows()[r.id].value==initial);tested=tested+1
   end
  end
 end end
 assert(infinite>20 and holsters>10 and twins>0 and tested==1,'Missing new edit paths')
 B.items('Primary','');B.select('41EAC4A03987FAA0');local old=B.game_text('name');assert(old.available)
 local d=V.patch();assert(d==nil,'Reset left an unwanted archive patch')
 B.game_text('name','QA test name');local patch,changed=V.patch();assert(patch and #changed>0,'Renamed text absent from patch')
 assert(B.game_text('name').value=='QA test name');B.game_text('name','');assert(V.patch()==nil,'Rename reset left a patch')
 local checks=0;for _,name in ipairs({'O-44 Bonded Pilot','KDM-500 Outrider','CPH-26 Commandant','RS-100 Sanctioner','RS-89 Shadow Paragon','CPG-48 Sapper','BFM-16 Tanker'})do local zh=V.translate(name);assert(zh and zh~=name,'Missing Chinese game name: '..name);checks=checks+1 end
 return {infinite_ammo_owners=infinite,holsters=holsters,twin_drops=twins,physics_reset=true,game_text_patch=true,chinese_names=checks,game_writes=0}
 """)
 print(json.dumps(dict(result.items()),ensure_ascii=False))
if __name__=='__main__':main()
