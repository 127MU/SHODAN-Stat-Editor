"""Current-build transport layouts and typed edits; isolated profile, no game writes."""
import argparse,json,os,pathlib,sys

def main():
    p=argparse.ArgumentParser();p.add_argument('--vendor',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2','utf8')
    os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,a.vendor)
    from lupa.luajit21 import LuaRuntime
    lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix())
    lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
    result=lua.execute('''
local ffi=require('ffi');local D=require('hostdata')
require('install').write_files=function()error('Game writes forbidden')end
local hosts={DB90077E76FAA025=6,['98152772A72F7838']=6,['3EC790806D0B0540']=3,
 ['74E2285C01DA4F71']=5,D37E8D120D2836E3=1,['30F2DEE2333F227A']=1}
local count=0;local fields=0
for _,tab in ipairs({'Mechas','Automatons','Illuminate','SEAF'})do B.items(tab,'')end
for hex,expected in pairs(hosts)do
 B.select(hex)
 local owner=B.registry[hex];local function row(id)
  for i,r in ipairs(owner.rows)do if r.id=='squad_'..id then return B.rows()[i],r end end
  error('Missing carrier field '..hex..':'..id)
 end
 assert(row('param0').value==expected,'u32 interpretation mismatch')
 local float=row('param12');assert(math.abs(float.value-(hex=='3EC790806D0B0540' and .45 or .2))<1e-5,'f32 interpretation mismatch')
 local ids={};local transportRows=0
 for _,r in ipairs(owner.rows)do
  assert(not ids[r.id],'Duplicate row ID');ids[r.id]=true
  if r.id:match('^squad_')then transportRows=transportRows+1 end
 end
 assert(transportRows==25,'Expected 25 bounded fields, got '..transportRows)
 local saved={};for name,f in pairs(D.files)do saved[name]=ffi.string(f.p,f.n)end
 B.set(float.id,.625);assert(math.abs(row('param12').value-.625)<1e-6);B.reset(float.id)
 for slot=1,6 do
  local choice,raw=row('slot'..slot..'_resource');local param,rawParam=row('slot'..slot..'_value')
  assert(rawParam.parts[1].field.offset-raw.parts[1].field.offset==8,'Resource/value stride wrong')
  assert(choice.choice_kind=='rackitem' and param.value<100,'Resource mistaken for float parameter')
 end
 local flag=row('flag128');B.set(flag.id,flag.value==0 and 1 or 0);B.reset(flag.id)
 for name,f in pairs(D.files)do assert(ffi.string(f.p,f.n)==saved[name],'Reset changed unrelated bytes')end
 count=count+1;fields=fields+transportRows
end
return {hosts=count,fields=fields,typed_values=true,reset_roundtrip=true,game_writes=0}
''')
    result=dict(result.items());(out/'report.json').write_text(json.dumps(result,indent=2),'utf8');print(json.dumps(result))
if __name__=='__main__':main()
