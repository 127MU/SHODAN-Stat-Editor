"""Extend core table tails as foreign editors do; preserve controls and defaults."""
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
    QA_CORE_TYPES={[0x88E4DBB1]=true,[0xFB8D88A3]=true,[0x66081072]=true,[0x45171B68]=true,
      [0xBD4042C2]=true,[0xE0A72CF0]=true,[0x2AEA2592]=true,[0xC63E0B22]=true,
      [0xAFDF0267]=true,[0xB3915DE3]=true,[0x30EB6399]=true}
    QA_PATCHED={}
    D.load=function(folder,working,baselines)
      for name,cipher in pairs(working)do
        local p,n=G.open_sealed(cipher);assert(p,n);local headers=G.headers(p,n);local count=0
        for _,h in ipairs(headers)do if QA_CORE_TYPES[h.type]then count=count+1 end end
        if count>0 then
          local extra=#headers==1 and 40 or 0
          local changed=ffi.new('uint8_t[?]',n+count*16+extra);local cursor,shift=0,0
          for _,h in ipairs(headers)do
            local finish=h.at+24+h.size;ffi.copy(changed+cursor+shift,p+cursor,finish-cursor)
            if QA_CORE_TYPES[h.type]then
              ffi.cast('uint32_t*',changed+h.at+shift+12)[0]=h.size+16
              QA_PATCHED[h.type]=true;shift=shift+16
            end
            cursor=finish
          end
          if cursor<n then ffi.copy(changed+cursor+shift,p+cursor,n-cursor)end
          if extra>0 then
            local at=n+shift;ffi.copy(changed+at,p+headers[1].at,8)
            ffi.cast('uint32_t*',changed+at+8)[0]=0xDEAD0012
            ffi.cast('uint32_t*',changed+at+12)[0]=16;changed[at+16]=1
            if headers[1].at==4 then ffi.cast('uint32_t*',changed)[0]=2 end
          end
          assert(G.correct(changed,n+shift+extra,G.murmur64(p,n),{},function()end),'Foreign fixture hash correction failed: '..name)
          working[name]=G.seal(changed,n+shift+extra)
        end
        G.free(p)
      end
      return load(folder,working,baselines)
    end
    require('install').write_files=function()error('Game writes forbidden')end
    ''')
    lua.execute('arg={...}',editor.as_posix());lua.globals().B=lua.execute('return dofile(...)',(app/'host.lua').as_posix())
    result=lua.execute('''
    local D=require('hostdata');local G=require('gamedata');local ffi=require('ffi');local registered={};local total=0
    for address,layout in pairs(D.original_layouts)do if QA_PATCHED[layout.kind]then registered[layout.kind]=true end end
    for kind in pairs(QA_PATCHED)do assert(registered[kind],string.format('Table disappeared after a foreign tail: 0x%08X',kind));total=total+1 end
    assert(total==11,'Core fixture did not cover all 11 component families')
    B.items('Primary','');B.select('968211C0033DCE64');local labels={};local numbers=0
    for _,r in ipairs(B.rows())do
      labels[r.label]=true
      if type(r.value)=='number'then assert(type(r.original)=='number','Lost default: '..r.label);numbers=numbers+1 end
    end
    assert(labels['伤害']and labels['口径（毫米）']and labels['弹匣容量'],'Weapon controls disappeared')
    local records=#B.items('Records','');assert(records>500,'Record pages disappeared')
    B.editor_mode(true);B.items('Illuminate','');B.select('DAC7D53FE0749F5F');local health=false
    for _,r in ipairs(B.rows())do if r.label=='生命值'and not health then health=true;assert(r.original==2000,'Shield defaults changed')end end
    assert(health,'Enemy health disappeared')
    local changes,problems=D.diff();assert(#problems==0,'Foreign extended tables cannot be prepared')
    for _,c in ipairs(changes)do G.free(c.plain)end
    return {families=total,weapon_numeric_fields=numbers,records=records,weapon_controls=true,enemy_health=true,originals_preserved=true,game_writes=0}
    ''')
    report=dict(result.items());(out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf8');print(json.dumps(report))

if __name__=='__main__':main()
