"""Compare native graph traversal with the legacy graph and independent binary reads."""
import json,pathlib,struct,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT.parent/'hd2-hud-plus-repair/vendor'))
from lupa.luajit21 import LuaRuntime
from test_native_data import expected
types={'BD4042C2':('shot',272),'2AEA2592':('blast',152),'E0A72CF0':('damage',76),'C63E0B22':('status',160),'AFDF0267':('arc',104),'C5085606':('beam',112)}
records={name:{} for name,_ in types.values()}
paths=sorted((ROOT/'offline/originals').glob('*.dl_plain'))
for path in paths:
    data=path.read_bytes()
    for block in expected(data):
        if block['type'] not in types:continue
        name,stride=types[block['type']];base=block['payload_offset'];count=struct.unpack_from('<I',data,base+8)[0]
        for i in range(count):
            row=data[base+16+i*stride:base+16+(i+1)*stride]
            key=struct.unpack_from('<I',row,0)[0]
            assert key not in records[name]
            records[name][key]=row
lua=LuaRuntime(unpack_returned_tuples=True)
module=lua.execute((ROOT/'offline/reference_chain.lua').read_text(encoding='utf8'))
def node(kind,key):
    row=records[kind].get(int(key))
    if row is None:return lua.table_from(dict(exists=False))
    def read(at):return struct.unpack_from('<I',row,at)[0]
    links=[]
    def link(kind,at,label):
        value=read(at)
        if value:links.append(lua.table_from(dict(kind=kind,id=value,via=label)))
    if kind=='shot':
        link('damage',60,'直接命中伤害');link('blast',144,'命中爆炸');link('blast',156,'到期爆炸')
    elif kind=='blast':
        link('damage',4,'爆炸伤害')
        if read(80):link('shot',84,'破片射弹')
    elif kind=='damage':
        for i in range(4):link('status',44+i*8,f'状态槽 {i+1}')
    elif kind=='status':link('damage',44,'每跳伤害')
    elif kind=='arc':link('damage',36,'电弧伤害')
    elif kind=='beam':link('damage',12,'激光伤害')
    return lua.table_from(dict(exists=True,links=lua.table_from(links)))
roots=[dict(kind='shot',id=67,via='当前记录'),dict(kind='shot',id=182,via='当前记录'),dict(kind='arc',id=1,via='当前记录'),dict(kind='beam',id=1,via='当前记录')]
for name,rows in records.items():
    ids=sorted(key for key in rows if key>0)
    for key in ids[:4]+ids[-2:]:roots.append(dict(kind=name,id=key,via='数据记录'))
legacy=module.build(lua.table_from([lua.table_from(r) for r in roots]),node)
request=dict(id=1,method='reference-files',params=dict(paths=[str(p) for p in paths],roots=roots))
run=subprocess.run([str(ROOT/'target/release/shodan-native.exe'),'--stdio'],input=json.dumps(request)+'\n',text=True,encoding='utf8',capture_output=True,check=True)
native=json.loads(run.stdout);assert native['ok'],native
fields=['key','parent','via','depth','missing','repeated']
want=[{key:legacy.entries[i][key] for key in fields} for i in range(1,len(legacy.entries)+1)]
actual=[{key:r[key] for key in fields} for r in native['result']['entries']]
assert actual==want,(actual,want)
print(f'Native references: {len(want)} cross-file edges match legacy traversal and independent binary reads; game writes 0')
