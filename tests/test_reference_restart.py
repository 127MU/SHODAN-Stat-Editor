"""Verify saved resource identity in two independent processes without game writes."""
import argparse,pathlib,os,sys,json

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',type=pathlib.Path,required=True);a=p.parse_args()
 root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=True);profile=out/'profile';profile.mkdir(exist_ok=True)
 (profile/'game folder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8');os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,str(a.vendor))
 from lupa.luajit21 import LuaRuntime
 lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix());lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
 phase=os.environ.get('REFERENCE_PHASE','write')
 saved=out/'expected.json'
 if phase=='write':
  result=lua.execute('''require('install').write_files=function()error('No game writes')end
B.editor_mode(false)
for _,item in ipairs(B.items('Primary',''))do B.select(item.id)
 for _,r in ipairs(B.rows())do if r.choice_kind=='package'then
  for _,c in ipairs(B.choices(r.id))do if c.raw=='05656B4B5B893AB8'then
   assert(not pcall(B.choose,r.id,36),'Legacy positional ID was accepted')
   B.choose(r.id,c.id)
   return {owner=item.id,row=r.id,value=c.id,raw=c.raw,name=c.name}
  end end
 end end
end
error('No package selector')''')
  saved.write_text(json.dumps(dict(result.items()),ensure_ascii=False),'utf8')
  print('saved',dict(result.items()))
 else:
  expected=json.loads(saved.read_text(encoding='utf8'))
  lua.globals().expected=lua.table_from(expected)
  result=lua.execute('''require('install').write_files=function()error('No game writes')end
B.editor_mode(false);B.select(expected.owner)
local r;for _,v in ipairs(B.rows())do if v.choice_kind=='package'then r=v;break end end;assert(r,'No package row');assert(r.value==expected.value,'Package changed on restart: '..tostring(r.value)..' vs '..tostring(expected.value)..' '..r.label)
assert(r.choice_name==expected.name,'Package label changed on restart')
assert(r.reference,'Opaque selector ID not hidden')
local found=false
for _,c in ipairs(B.choices(r.id))do if c.id==r.value then assert(c.raw==expected.raw);found=true end end
assert(found)
return {restart_identity=true,legacy_positional_id_rejected=true,game_writes=0}''')
  print(json.dumps(dict(result.items())))
if __name__=='__main__':main()
