"""Retired switches stay unavailable; resource preview never writes game files."""
import argparse,json,os,pathlib,sys
def main():
    p=argparse.ArgumentParser();p.add_argument('--vendor',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir()
    (profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2','utf8');os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,a.vendor)
    from lupa.luajit21 import LuaRuntime
    lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix());lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
    result=lua.execute('''
local D=require('hostdata');local G=require('gamedata');local ffi=require('ffi')
require('install').write_files=function()error('Game writes forbidden')end
local snapshot={};for name,f in pairs(D.files)do snapshot[name]=ffi.string(f.p,f.n)end
local options=B.tweaks();assert(options.diving==nil and options.vaulting==nil)
assert(not pcall(B.tweaks,'diving',true));assert(not pcall(B.tweaks,'vaulting',true))
for name,f in pairs(D.files)do assert(ffi.string(f.p,f.n)==snapshot[name],'Removed switch changed bytes')end
local profile=assert(B.ragdoll_preview());assert(profile.supported and profile.resources==2 and profile.fields==514)
assert(not pcall(B.ragdoll_apply,true),'QA must block resource writes')
return {retired_switches_unavailable=true,ragdoll_fields=profile.fields,game_writes=0}
''')
    result=dict(result.items());(out/'report.json').write_text(json.dumps(result,indent=2),'utf8');print(json.dumps(result))
if __name__=='__main__':main()
