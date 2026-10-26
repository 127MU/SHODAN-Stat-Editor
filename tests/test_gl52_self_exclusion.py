"""GL52 self-exclusion edits exactly one byte and survives preset/reset; no game writes."""
import argparse,json,os,pathlib,sys

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',type=pathlib.Path,required=True);p.add_argument('--runtime-dir',type=pathlib.Path);a=p.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
    os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,str(a.vendor))
    from lupa.luajit21 import LuaRuntime
    lua=LuaRuntime();lua.globals().SHODAN_EUI=True
    app=a.runtime_dir.resolve()/'app' if a.runtime_dir else root/'offline';editor=app/'stat_editor.lua' if a.runtime_dir else root/'src/stat_editor.lua'
    lua.execute("package.path=.....';'..package.path",(app/'?.lua').as_posix())
    lua.execute("require('install').write_files=function()error('Game writes forbidden')end")
    lua.execute('arg={...}',editor.as_posix());lua.globals().B=lua.execute('return dofile(...)',(app/'host.lua').as_posix())
    result=lua.execute('''
    local D=require('hostdata');local G=require('gamedata');local ffi=require('ffi')
    B.items('Support','');B.select('FE3B29B2CFA63F9B');local row
    for _,r in ipairs(B.rows())do if r.label=='电弧排除发射者（实验）'then row=r end end
    assert(row and row.flag and row.original==0,'GL52 self-exclusion switch/default missing')
    local field=B.registry['FE3B29B2CFA63F9B'].rows[row.id].parts[1].field
    assert(field.kind==0xAFDF0267 and field.storage=='flag')
    local raw=D.files['generated_arc_settings.dl_bin'];assert(raw)
    local before=ffi.string(raw.p,raw.n)
    B.set(row.id,1);assert(B.rows()[row.id].value==1,'Switch did not enable')
    local after=ffi.string(raw.p,raw.n);local changed=0
    for i=1,#before do if before:byte(i)~=after:byte(i)then
      changed=changed+1;assert(i-1==0x640 and after:byte(i)==1,'Unexpected data changed')
    end end
    assert(changed==1,'Must change only ArcInfo 15 +100, preserving damage/range')
    B.preset('save',5);local text=B.preset_export('weapon',5)
    assert(text:find('exclude_self',1,true),'Switch missing from preset export')
    B.reset(row.id);assert(B.rows()[row.id].value==0,'Restore did not switch off')
    B.preset('load',5);assert(B.rows()[row.id].value==1,'Preset failed to enable')
    local changes,problems=D.diff();assert(#problems==0)
    local arc_change
    for _,c in ipairs(changes)do if c.name=='generated_arc_settings.dl_bin'then arc_change=c end end
    assert(arc_change,'Arc file missing from generated write')
    assert(tonumber(arc_change.plain[0x640])==1,'Generated file lost switch')
    for _,c in ipairs(changes)do G.free(c.plain)end
    B.reset(row.id);assert(B.rows()[row.id].original==0 and B.rows()[row.id].value==0)
    B.items('Support','');B.select('B814EECE17533BC4')
    local action
    for _,r in ipairs(B.rows())do if r.choice_kind=='apex_fire'then action=r end end
    assert(action,'Apex action missing')
    for _,c in ipairs(B.choices(action.id))do assert(not c.name:find('参考',1,true))end
    -- G-31 has a distinct arc record whose stock exclusion flag is already enabled.
    B.items('Throwables','');B.select('DB922A7AFC42894B');local grenade
    for _,r in ipairs(B.rows())do if r.label=='电弧排除发射者（实验）'then grenade=r end end
    assert(grenade and grenade.flag and grenade.original==1,'Arc grenade lost its stock enabled default')
    B.set(grenade.id,0);assert(B.rows()[grenade.id].value==0)
    B.reset(grenade.id);assert(B.rows()[grenade.id].value==1,'Arc grenade restore must use its own default')
    B.items('Support','');B.select('96DE9CD50F7306E6');local gun
    for _,r in ipairs(B.rows())do if r.label=='电弧排除发射者（实验）'then gun=r end end
    assert(gun and gun.original==1,'Direct arc weapon field missing')
    local all=B.items('Records','');local count=0
    for _,item in ipairs(all)do if item.id:sub(1,2)=='F4'then
      count=count+1;if item.id=='F40000000000000F'then assert(item.name:find('GL-52 缓和使者',1,true),'Arc owner name was not localized')end;B.select(item.id);local flag
      for _,r in ipairs(B.rows())do if r.label=='电弧排除发射者（实验）'then flag=r end end
      assert(flag and flag.flag,'Arc record missing switch: '..item.id)
      local id=tonumber(item.id:sub(3),16);local original=id==15 and 0 or 1
      assert(flag.original==original,'Arc stock default changed: '..id)
      B.set(flag.id,1-original);assert(B.rows()[flag.id].value==1-original)
      B.reset(flag.id);assert(B.rows()[flag.id].value==original)
    end end
    assert(count==16,'Not all stock arc records are exposed')
    B.select('F40000000000000F');local selected
    for _,r in ipairs(B.rows())do if r.label=='电弧排除发射者（实验）'then selected=r end end
    B.set(selected.id,1);B.preset('save',4);B.reset(selected.id);B.preset('load',4)
    assert(B.rows()[selected.id].value==1,'Arc record preset did not roundtrip')
    B.reset(selected.id)
    return {all_arc_records=count,gl52_self_exclusion=true,arc_throwable=true,arc_weapon=true,one_byte_change=true,damage_unchanged=true,default_off=true,
      preset_export_load_reset=true,generated_write=true,apex_labels_clean=true,game_writes=0}
    ''')
    report=dict(result.items());(out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf8');print(json.dumps(report))

if __name__=='__main__':main()
