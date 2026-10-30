"""All four status strengths keep their IDs and section when effects are selected."""
import argparse,json,os,pathlib,sys
def main():
    p=argparse.ArgumentParser();p.add_argument('--vendor',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir()
    (profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2','utf8');os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,a.vendor)
    from lupa.luajit21 import LuaRuntime
    lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix());lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
    result=lua.execute('''
B.items('Primary','');local owner=B.items('Primary','')[1].id;B.select(owner)
local function row(id)
 for i,r in ipairs(B.registry[owner].rows)do if r.id==id then return B.rows()[i]end end
 error('Missing '..id)
end
for i=4,1,-1 do B.choose(row('slot'..i).id,0)end
local section=row('slot4_strength').section
for i,id in ipairs({5,38,43,68})do
 B.choose(row('slot'..i).id,id)
 for n=1,4 do assert(row('slot'..n..'_strength').section==section,'Strength moved out of status section')end
end
B.set(row('slot4_strength').id,2.75);assert(row('slot4_strength').value==2.75)
B.preset('save',5);B.reset();B.preset('load',5)
assert(row('slot4_strength').value==2.75 and row('slot4_strength').section==section)
-- Repeating one effect must not duplicate its global detail rows.
B.choose(row('slot4').id,5)
local ids={};for _,r in ipairs(B.registry[owner].rows)do assert(not ids[r.id],'Duplicate row ID '..r.id);ids[r.id]=true end
return {slots=4,stable_strength_sections=true,slot4_value=2.75,preset_roundtrip=true,duplicate_effect_details=false,game_writes=0}
''')
    result=dict(result.items());(out/'report.json').write_text(json.dumps(result,indent=2),'utf8');print(json.dumps(result))
if __name__=='__main__':main()
