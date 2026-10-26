"""Verify Guard Dog mount replacement without game writes."""
import argparse,pathlib,os,sys,json

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',type=pathlib.Path,required=True);a=p.parse_args()
 root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir()
 (profile/'game folder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8');os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,str(a.vendor))
 from lupa.luajit21 import LuaRuntime
 lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix());lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
 result=lua.execute('''require('install').write_files=function()error('No game writes')end
 B.editor_mode(false)
 local dogs,donor_count,combinations=0,0,0
 for _,item in ipairs(B.items('Stratagems',''))do
  B.select(item.id)
  local selected,old_count
  local rows=B.rows();old_count=#rows
  for _,r in ipairs(rows)do if r.choice_kind=='dogweapon'then selected=r;break end end
  if selected then
   dogs=dogs+1
   assert(selected.value and selected.original,'Dog original reference missing')
   local options=B.choices(selected.id);assert(#options>16);donor_count=#options
   local seen={}
   for _,c in ipairs(options)do
    assert(not seen[c.id]);seen[c.id]=true
    assert(not c.description:find('96DE9CD50F7306E6',1,true),'ARC-3 remained selectable')
    assert(not c.description:find('3575AABC5F1F9326',1,true),'Redeemer remained selectable')
    if c.id>16 then assert(c.name:find('实验性',1,true),'Untested donor missing experimental label')end
   end
   assert(not pcall(B.choose,selected.id,999999),'Invalid donor accepted')
   for oi,donor in ipairs(options)do
    if oi<=16 or oi==#options then
    collectgarbage('collect')
    combinations=combinations+1
    local swaprow
    for _,r in ipairs(B.rows())do if r.choice_kind=='dogweapon'then swaprow=r end end
    B.choose(swaprow.id,donor.id)
    local cfg=assert(io.open(os.getenv('SHODAN_PROFILE')..'/config.txt','rb'));local text=cfg:read('*a');cfg:close()
    if donor.id~=selected.original then assert(text:find(string.format('%.0f',donor.id),1,true),'Saved donor ID lost precision')end
    local changed=B.rows();local swapped
    for _,r in ipairs(changed)do if r.choice_kind=='dogweapon'then swapped=r end end
    assert(swapped.value==donor.id,'Swap did not persist')
    if donor.id~=selected.original then
     assert(swapped.changed,'Swap marker missing')
     assert(#changed<old_count,'Old gun controls remained after swap')
    end
    B.reset(swapped.id)
    local restored=B.rows();assert(#restored==old_count,'Reset lost original gun controls')
    for _,r in ipairs(restored)do if r.choice_kind=='dogweapon'then assert(r.value==selected.original and not r.changed)end end
    end
   end
  end
 end
 assert(dogs==5,'Expected five Guard Dog carriers, got '..dogs)
 return {carriers=dogs,donors=donor_count,combinations=combinations,swap_and_reset=true,stale_gun_rows_hidden=true,game_writes=0}
 ''')
 report=dict(result.items());(out/'report.json').write_text(json.dumps(report,indent=2),'utf8');print(json.dumps(report))
if __name__=='__main__':main()
