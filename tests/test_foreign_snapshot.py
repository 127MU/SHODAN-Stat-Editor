"""Reopen a foreign-shaped sealed entity snapshot, without game file writes."""
import argparse,json,os,pathlib,sys

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',type=pathlib.Path,required=True)
    parser.add_argument('--vendor',type=pathlib.Path,required=True)
    parser.add_argument('--runtime-dir',type=pathlib.Path)
    args=parser.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1]
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    profile=out/'profile';profile.mkdir()
    (profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
    os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out))
    sys.path.insert(0,str(args.vendor))
    from lupa.luajit21 import LuaRuntime
    lua=LuaRuntime();lua.globals().SHODAN_EUI=True
    app=args.runtime_dir.resolve()/'app' if args.runtime_dir else root/'offline'
    editor=app/'stat_editor.lua' if args.runtime_dir else root/'src/stat_editor.lua'
    lua.execute("package.path=.....';'..package.path",(app/'?.lua').as_posix())
    lua.execute('''
local D=require('hostdata');local G=require('gamedata');local ffi=require('ffi')
local load=D.load
D.load=function(folder,working,baselines)
 local name='generated_entities.dl_bin'
 local p,n=G.open_sealed(working[name]);assert(p,n)
 local hash=G.murmur64(p,n);local headers=G.headers(p,n)
 local changed=ffi.new('uint8_t[?]',n+40);ffi.copy(changed,p,n)
 ffi.copy(changed+n,p+headers[1].at,8)
 ffi.cast('uint32_t*',changed+n+8)[0]=0xDEAD0011
 ffi.cast('uint32_t*',changed+n+12)[0]=16
 changed[n+16]=1
 ffi.copy(changed+n+24,'QA foreign block',16)
 assert(G.correct(changed,n+40,hash,{},function()end),'Could not seal foreign-shaped fixture')
 assert(G.murmur64(changed,n+40)==hash,'Fixture hash does not match this game')
 working[name]=G.seal(changed,n+40);G.free(p)
 return load(folder,working,baselines)
end
require('install').write_files=function()error('Game writes forbidden')end
''')
    lua.execute('arg={...}',editor.as_posix())
    lua.globals().B=lua.execute('return dofile(...)',(app/'host.lua').as_posix())
    result=lua.execute('''
local D=require('hostdata');local G=require('gamedata')
local f=assert(D.files['generated_entities.dl_bin'])
local p,n=G.open_sealed(f.baseline);assert(#G.headers(f.p,f.n)==#G.headers(p,n)+1);G.free(p)
B.editor_mode(false);local entries=B.items('Primary','');B.select(entries[1].id)
local rows=B.rows();local numeric,rate,modes=0,false,0
for _,row in ipairs(rows)do
 if type(row.value)=='number' then
  assert(type(row.original)=='number','Lost default after foreign tool: '..row.label)
  numeric=numeric+1
 end
 if row.label:find('射速',1,true) then rate=true end
 if row.choice_kind=='firemode' then modes=modes+1 end
end
assert(rate and modes==3 and numeric>20,'Weapon controls disappeared after foreign tool')
local changes,problems=D.diff();assert(#problems==0,'Foreign-shaped snapshot cannot be prepared')
for _,change in ipairs(changes)do G.free(change.plain)end
return {foreign_layout_reopened=true,weapon_numeric_defaults=numeric,fire_modes=modes,rate_control=true,snapshot_prepared=true,game_writes=0}
''')
    report=dict(result.items())
    (out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf8')
    print(json.dumps(report))

if __name__=='__main__':main()
