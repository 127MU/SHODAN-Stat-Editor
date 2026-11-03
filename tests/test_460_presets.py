"""4.6.0 per-armor passives and share-code regression; no game writes."""
import argparse,json,os,pathlib,sys
p=argparse.ArgumentParser();p.add_argument('--vendor',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[1];a.output.mkdir(parents=True,exist_ok=False)
os.environ.update(SHODAN_PROFILE=str(a.output.resolve()),SHODAN_QA_OUTPUT=str(a.output.resolve()))
sys.path.insert(0,a.vendor);from lupa.luajit21 import LuaRuntime
lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix());lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
lua.execute(r"""
require('install').write_files=function()error('Game writes forbidden')end
require('armory').profiles={};require('armory').dirty=false
local divers=B.items('Helldiver','');assert(#divers==1,'Missing direct Helldiver page')
for _,w in ipairs(B.items('Armors',''))do
    assert(w.id~=divers[1].id,'Duplicate Helldiver in armor catalog')
    assert(not w.name:match('Helmet:') and not w.name:match('Cape:'),'Untranslated equipment prefix')
end
B.select(divers[1].id);assert(#B.rows()>0,'Helldiver page lost parameters')
local owner,first
for _,w in ipairs(B.items('Armors',''))do local info=B.armor_item(w.id);if info.available then owner=w;first=info;break end end
assert(owner,'No per-armor page')
B.select(owner.id);B.armor_item(owner.id,{1,7});assert(#B.armor_item(owner.id).selected==2)
B.full_preset('new',0,'460 Armor')
local n;for _,p in ipairs(B.full_presets())do if p.name=='460 Armor'then n=p.id end end;assert(n)
local code=B.preset_code(n);assert(code:match('^SSEO%-S1%-'))
B.preset_code_import(code)
local imported;for _,p in ipairs(B.full_presets())do if p.id~=n and p.name=='460 Armor'then imported=p.id end end;assert(imported)
B.armor_item(owner.id,{});B.full_preset('load',imported);assert(#B.armor_item(owner.id).selected==2,'Share code lost armor passives')
local portable=B.preset_export('full',n);local another=B.preset_import('full',0,portable).id
B.armor_item(owner.id,{});B.full_preset('load',another);assert(#B.armor_item(owner.id).selected==2,'Portable preset lost armor passives')
local preview=B.install_preview();assert(#preview.problems==0,table.concat(preview.problems,';'))
local I=require('install');local G=require('gamedata');local writes=0
I.game_running=function()return false end
I.write_patch=function()error('Unexpected real resource patch')end
I.write_files=function(folder,files)
    for name,sealed in pairs(files)do
        local p,n=G.open_sealed(sealed);assert(p and n>0,'Prepared file cannot be opened: '..name);G.free(p);writes=writes+1
    end
    return true
end
local stages={};SHODAN_EUI_PROGRESS=function(stage,done,total)stages[#stages+1]={stage,done,total}end
local result=B.install_task();assert(result.ok and B.write_succeeded(),'Simulated installation failed');assert(writes>0,'No armor files prepared')
assert(#stages>=2,'Installation stages were not emitted')
B.armor_item(owner.id,first.selected);B.flush()
""")
print(json.dumps(dict(per_armor=True,share_code=True,portable_roundtrip=True,install_preflight=True,sealed_install_simulation=True,game_writes=0)))
