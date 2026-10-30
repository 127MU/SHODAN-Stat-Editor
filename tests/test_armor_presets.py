"""Armor numeric snapshots in global presets; no game writes, isolated profile."""
import argparse,json,os,pathlib,sys

def main():
    p=argparse.ArgumentParser();p.add_argument('--vendor',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2','utf8')
    os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,a.vendor)
    from lupa.luajit21 import LuaRuntime
    lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix());lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
    result=lua.execute(r'''
require('install').write_files=function()error('Game writes forbidden')end
B.items('Primary','');B.select(B.items('Primary','')[1].id)
local row=B.armor_rows(7)[1];assert(row and row.default==2)
local weapon;for _,r in ipairs(B.rows())do if not r.choice and not r.flag and type(r.value)=='number' then weapon=r;break end end
local function value()for _,r in ipairs(B.armor_rows(7))do if r.key==row.key then return r.value end end end
local function find(name)for _,p in ipairs(B.full_presets())do if p.name==name then return p.id end end;error('Missing preset '..name)end
B.set(weapon.id,weapon.value+1);B.armor_set(7,row.key,5.5);B.full_preset('new',0,'Armor A');local a=find('Armor A')
B.set(weapon.id,weapon.value+2);B.armor_set(7,row.key,9);B.full_preset('new',0,'Armor B');local b=find('Armor B')
assert(B.preset_compare('full',a).count>0,'Armor missing from preview')
B.full_preset('load',a);assert(value()==5.5 and B.rows()[weapon.id].value==weapon.value+1,'Armor A did not restore')
B.full_preset('load',b);assert(value()==9 and B.rows()[weapon.id].value==weapon.value+2,'Armor B did not restore')
local text=B.preset_export('full',a);assert(text:find('\narmor ',1,true),'Armor missing from export')
local imported=B.preset_import('full',0,text).id;B.full_preset('load',imported);assert(value()==5.5)
B.preset_rename('full',imported,'Armor imported');B.armor_set(7,row.key,8);B.full_preset('load',imported);assert(value()==5.5,'Rename discarded armor')
B.armor_set(7,row.key,row.default);B.full_preset('save',a);B.armor_set(7,row.key,7);B.full_preset('load',a);assert(value()==row.default,'Overwrite/default restore failed')
local legacy=text:gsub('armor [^\n]+\n','');local old=B.preset_import('full',0,legacy).id
B.armor_set(7,row.key,6);local preview=B.preset_compare('full',old);assert(#preview.warnings>0)
B.full_preset('load',old);assert(value()==6,'Legacy preset changed armor')
local payload=B.armor_capture();local bad=payload:gsub(' 2 6',' 3 6',1)
assert(not pcall(B.armor_apply,bad),'Incompatible baseline accepted');assert(value()==6)
local ARM=require('armor_ui');local plans=ARM.plans;local open=io.open
io.open=function(path,mode)if path==ARM.path..'.tmp' then return nil,'simulated failure'end;return open(path,mode)end
local failed=not pcall(B.armor_apply,payload:gsub(' 2 6',' 2 8',1));io.open=open
assert(failed and value()==6 and ARM.plans==plans,'Write failure did not roll back')
return {switching=true,export_import=true,rename=true,overwrite=true,legacy_preserved=true,failure_rollback=true,game_writes=0}
''')
    report=dict(result.items());(out/'report.json').write_text(json.dumps(report,indent=2),'utf8');print(json.dumps(report))
    restart=LuaRuntime();restart.globals().SHODAN_EUI=True;restart.execute('arg={...}',(root/'src/stat_editor.lua').as_posix())
    restart.globals().B=restart.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
    restart.execute("B.items('Primary','');for _,p in ipairs(B.full_presets())do if p.name=='Armor B'then B.full_preset('load',p.id);assert(B.armor_rows(7)[1].value==9);return end end;error('Preset lost after restart')")
    report['restart']=True;(out/'report.json').write_text(json.dumps(report,indent=2),'utf8');print('Restart persistence passed')
if __name__=='__main__':main()
