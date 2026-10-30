"""Trace current game records and resource dependencies without game writes."""
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
require('install').write_files=function()error('Game writes forbidden')end
local M=require('res_patch');M.write_file=function()error('Resource writes forbidden')end
local checked,nodes=0,0
for _,tab in ipairs({'Primary','Secondary','Support','Mechas'})do
 for i,item in ipairs(B.items(tab,''))do
  if i>8 then break end;B.select(item.id)
  local before=#B.pending_preview();local report=B.diagnostic_chain()
  assert(report.owner==item.id and #report.entries<=512)
  assert(#B.pending_preview()==before,'Read-only trace changed parameters')
  for _,entry in ipairs(report.entries)do assert(entry.depth<=24)end
  checked=checked+1;nodes=nodes+#report.nodes
 end
end
B.select(B.items('Primary','')[1].id)
local selector;for _,r in ipairs(B.rows())do if r.projectile_source then selector=r.id;break end end
assert(selector);B.choose(selector,67)
local changed=B.diagnostic_chain();local found=false
for _,node in ipairs(changed.nodes)do if node.kind=='shot' and node.id==67 then found=true end end
assert(found,'Trace ignored current projectile swap')
local report=B.diagnostic_resources();assert(report.owner==changed.owner and #report.entries>0)
assert(report.missing==0,'Known projectile resources missing')
return {equipment=checked,nodes=nodes,swapped_projectile=found,resources=#report.entries,packages=#report.packages,
 unresolved_audio=report.unresolved_audio,game_writes=0}
''')
    result=dict(result.items());(out/'report.json').write_text(json.dumps(result,indent=2),'utf8');print(json.dumps(result))
if __name__=='__main__':main()
