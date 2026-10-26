"""Reopen a foreign damage-table tail and edit weapon calibre; no game writes."""
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
    lua.execute('''
    local D=require('hostdata');local G=require('gamedata');local ffi=require('ffi');local load=D.load
    D.load=function(folder,working,baselines)
      local name='generated_damage_settings.dl_bin';local p,n=G.open_sealed(working[name]);assert(p,n)
      local headers=G.headers(p,n);local last=headers[#headers];assert(last.type==0xE0A72CF0)
      local changed=ffi.new('uint8_t[?]',n+16);ffi.copy(changed,p,n)
      ffi.cast('uint32_t*',changed+last.at+12)[0]=last.size+16
      assert(G.correct(changed,n+16,G.murmur64(p,n),{},function()end),'Fixture hash correction failed')
      working[name]=G.seal(changed,n+16);G.free(p)
      return load(folder,working,baselines)
    end
    require('install').write_files=function()error('Game writes forbidden')end
    ''')
    lua.execute('arg={...}',editor.as_posix());lua.globals().B=lua.execute('return dofile(...)',(app/'host.lua').as_posix())
    result=lua.execute('''
    local ffi=require('ffi');B.items('Primary','');B.select('968211C0033DCE64')
    local calibre,damage
    for _,r in ipairs(B.rows())do if r.label=='口径（毫米）'then calibre=r end;if r.label=='伤害'then damage=r end end
    assert(damage and type(damage.original)=='number','Foreign table tail hid weapon damage fields')
    assert(calibre and type(calibre.original)=='number','Weapon calibre field missing')
    local original=calibre.original;B.set(calibre.id,original+0.25)
    assert(math.abs(B.rows()[calibre.id].value-original-0.25)<1e-6,'Calibre edit not applied')
    local raw=B.registry['968211C0033DCE64'].rows[calibre.id].parts[1].field
    assert(raw.kind==0xBD4042C2,'Calibre must use the projectile table')
    local D=require('hostdata');local G=require('gamedata');local found=false
    for _,file in pairs(D.files)do for _,h in ipairs(G.headers(file.p,file.n))do
      if h.type==raw.kind then
        assert(tonumber(ffi.cast('float*',file.p+h.at+24+raw.offset)[0])==original+0.25,'Actual projectile calibre was not changed');found=true
      end
    end end
    assert(found)
    B.preset('save',5);local text=B.preset_export('weapon',5);assert(text:find(' calibre ',1,true),'Calibre missing from exported preset')
    B.reset(calibre.id);assert(B.rows()[calibre.id].value==original)
    B.preset('load',5);assert(math.abs(B.rows()[calibre.id].value-original-0.25)<1e-6,'Calibre preset did not load')
    B.reset();B.set(damage.id,damage.original+17);assert(B.rows()[damage.id].value==damage.original+17,'Foreign damage table cannot be edited')
    B.reset(damage.id);assert(B.rows()[damage.id].value==damage.original,'Foreign damage defaults changed')
    local changes,problems=D.diff();assert(#problems==0,'Foreign damage table cannot be prepared for install')
    for _,c in ipairs(changes)do G.free(c.plain)end
    return {foreign_damage_tail=true,damage_visible=true,damage_edit_and_reset=true,calibre_edit=true,calibre_export_load_reset=true,calibre_original=original,game_writes=0}
    ''')
    report=dict(result.items());(out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf8');print(json.dumps(report))

if __name__=='__main__':main()
