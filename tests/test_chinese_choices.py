"""Audit Chinese UI text and resource choice round trips; never writes game files."""
import argparse,json,os,pathlib,re,sys

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',type=pathlib.Path,required=True);p.add_argument('--runtime-dir',type=pathlib.Path);p.add_argument('--tab',choices=['Primary','Secondary','Support','Throwables','Stratagems','Mechas','Boosters','Attachments','Helldiver','ArmorWeight','Records','Terminids','Automatons','Illuminate','SEAF','Spawning']);p.add_argument('--dump-inventory',action='store_true');a=p.parse_args()
 root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
 profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
 os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,str(a.vendor))
 from lupa.luajit21 import LuaRuntime
 lua=LuaRuntime();lua.globals().SHODAN_EUI=True
 app=a.runtime_dir.resolve()/'app' if a.runtime_dir else root/'offline';editor=app/'stat_editor.lua' if a.runtime_dir else root/'src/stat_editor.lua'
 lua.execute('arg={...}',editor.as_posix());lua.globals().B=lua.execute('return dofile(...)',(app/'host.lua').as_posix())
 lua.globals().AUDIT_TAB=a.tab
 result=lua.execute('''
local S=ShodanStatEditor;local I=require('install');local writes=0
I.write_files=function()writes=writes+1;error('test forbids game writes')end
local expected={['Attack: Acid spray']='攻击：酸液喷射',['Attack: Staff explosion']='攻击：法杖爆炸',
 ['Front left wheel hub health']='左前轮毂生命值',['Back right wheel hub armor']='右后轮毂装甲等级',
 ['SG-20 Halt (stun rounds)']='SG-20 止息（眩晕弹）',['PLAS-45 Epoch (full charge)']='PLAS-45 纪元（完全蓄力）',
 ['Carry Data（背包）']='携带数据（背包）',['SEAF primary weapon']='超级地球武装部队主武器',
 ['GR-8 Recoilless Rifle']='GR-8 无后坐力炮',['P-41 Ombudsman (variant 2)']='P-41 巡察者（变体 2）',
 ['CB-9 Exploding Crossbow (Model)']='CB-9 爆燃弩（主武器，模型）',
 ['E/GL-21 Grenadier Battlement']='E/GL-21 掷弹兵防卫墙'}
for raw,want in pairs(expected)do assert(S.tr(raw)==want,raw..' => '..S.tr(raw))end
local texts,seen,choices,owners={}, {},{},0
for _,mode in ipairs({false,true})do B.editor_mode(mode)
 local tabs=mode and {'Terminids','Automatons','Illuminate','SEAF','Spawning'} or {'Primary','Secondary','Support','Throwables','Stratagems','Mechas','Boosters','Attachments','Helldiver','ArmorWeight','Records'}
 for _,tab in ipairs(tabs)do if not AUDIT_TAB or tab==AUDIT_TAB then for _,item in ipairs(B.items(tab,''))do
  owners=owners+1;texts[item.name]=true;B.select(item.id)
  for _,row in ipairs(B.rows())do
   for _,k in ipairs({'label','section','note','inline_note','choice_name'})do if row[k] and row[k]~=''then texts[row[k]]=true end end
   for _,t in ipairs(row.help or {})do texts[t]=true end
   if row.choice and not seen[row.choice_kind]then
    seen[row.choice_kind]=true;choices[row.choice_kind]=B.choices(row.id)
    if row.choice_kind=='package' then
     local original=row.value;local named,unknown
     for _,c in ipairs(choices.package)do
      if c.raw=='05656B4B5B893AB8'then named=c end
      if c.raw=='055F887C3BC616FE'then unknown=c end
     end
     assert(named and named.name:find('固定重机枪',1,true),'workbook package label missing')
     assert(unknown and unknown.name:find('未命名资源包',1,true),'unknown package needs explicit label')
     B.choose(row.id,named.id);local changed=B.rows()[row.id]
     assert(changed.value==named.id and changed.choice_name==named.name,'resource name disagrees after selection')
     B.choose(row.id,original);assert(B.rows()[row.id].value==original,'resource original selection lost')
    end
   end
  end
 end end end
end
assert(writes==0)
return {owners=owners,texts=texts,choices=choices,inventory=S.qa_ui.translation_inventory()}
''')
 def convert(x):
  if hasattr(x,'items'):
   d={k:convert(v) for k,v in x.items()}
   if d and all(isinstance(k,int) for k in d) and set(d)==set(range(1,len(d)+1)):return [d[k] for k in range(1,len(d)+1)]
   return d
  return x
 r=convert(result)
 if a.dump_inventory:(out/'inventory.json').write_text(json.dumps(r,ensure_ascii=False,indent=2),encoding='utf8')
 def strings(v):
  if isinstance(v,str):yield v
  elif isinstance(v,dict):
   for x in v.values():yield from strings(x)
  elif isinstance(v,list):
   for x in v:yield from strings(x)
 for text in strings(r):
  assert '\ufffd' not in text and not re.search('[\ue000-\uf8ff\x00-\x08\x0b\x0c\x0e-\x1f]',text),repr(text)
 for text in r['texts']:
  assert not (re.search('[A-Za-z]{4,}',text) and not re.search('[\u3400-\u9fff]',text)),text
 for kind,items in r['choices'].items():
  for item in items:
   name=item['name'];assert not re.fullmatch('[A-Fa-f0-9]{16}',name),(kind,name)
   assert not (re.search('[A-Za-z]{4,}',name) and not re.search('[\u3400-\u9fff]',name)),(kind,name)
 report=dict(owners=r['owners'],ui_texts=len(r['texts']),inventory=len(r['inventory']),choice_kinds=len(r['choices']),package_choices=len(r['choices'].get('package',[])),unknown_packages=sum('未命名资源包' in x['name'] for x in r['choices'].get('package',[])),choice_roundtrip=True,invalid_utf8_or_replacement_characters=0,game_writes=0)
 (out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8');print(json.dumps(report))
if __name__=='__main__':main()
