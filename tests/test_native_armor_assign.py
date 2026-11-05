"""Exact-byte per-armor assignment oracle. Native child has no Lua dependencies.

Only isolated copies under dist are written. The reference helper is loaded in
this test process and never used by the native runtime.
"""
import argparse
import json
import pathlib
import random
import shutil
import struct
import subprocess
import sys
import tempfile

from test_native_data import expected

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--exe', type=pathlib.Path, default=ROOT/'target/debug/shodan-native.exe')
parser.add_argument('--fixtures', type=pathlib.Path, default=ROOT/'dist/native-catalog-inventory-4/sources')
args = parser.parse_args()
sys.path.insert(0, str(ROOT.parent/'hd2-hud-plus-repair/vendor'))
from lupa.luajit21 import LuaRuntime

lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
lua.execute(b'jit.off();package.path=... .. ";" .. package.path', (ROOT/'offline/?.lua').as_posix().encode())
lua.globals()[b'py_headers'] = lambda data: lua.table_from([
    lua.table_from({b'at': r['offset'], b'type': int(r['type'],16), b'size': r['payload_bytes']})
    for r in expected(data)])
lua.execute(b'''
local ffi=require('ffi');local allocations={}
package.loaded.gamedata={headers=function(p,n)return py_headers(ffi.string(p,n))end,
    alloc=function(n)local p=ffi.new('uint8_t[?]',n);allocations[#allocations+1]=p;return p end,
    free=function()end}
local D=require('hostdata')
function assign_oracle(passive,armor,lists,lines)
    allocations={};D.files={};local changes={}
    for name,data in pairs({passive=passive,armor=armor})do
        local p=ffi.new('uint8_t[?]',#data);ffi.copy(p,data,#data);allocations[#allocations+1]=p
        D.files[name]={name=name,p=p,n=#data}
        changes[#changes+1]={name=name,plain=p,n=#data,bytes=0,floats={}}
    end
    assert(D.armor_passives(changes,lists,function()end,lines))
    local out={};for _,v in ipairs(changes)do out[v.name]=ffi.string(v.plain,v.n)end
    return out.passive,out.armor
end
''')

passives=(ROOT/'rust/core/data/armor-baseline.bin').read_bytes()
armors=(args.fixtures/'generated_customization_armor_sets.dl_plain').read_bytes()
ids=sorted(struct.unpack_from('<I',passives,b['payload_offset'])[0] for b in expected(passives) if b['type']=='63CE0FEB')
names=sorted(set(struct.unpack_from('<I',armors,b['payload_offset']+16)[0] for b in expected(armors)
                 if b['type']=='D9A55AA0' and struct.unpack_from('<I',armors,b['payload_offset']+40)[0]==0))
rng=random.Random(20261105)
with tempfile.TemporaryDirectory(dir=ROOT/'dist/build-temp-r19',prefix='native-armor-assign-') as folder:
    folder=pathlib.Path(folder);exe=folder/'shodan-native.exe';shutil.copy2(args.exe,exe)
    passive_path=folder/'passives.plain';passive_path.write_bytes(passives)
    armor_path=folder/'armors.plain';armor_path.write_bytes(armors)
    process=subprocess.Popen([str(exe),'--stdio'],cwd=folder,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,encoding='utf8')
    def call(method,ok=True,**params):
        process.stdin.write(json.dumps(dict(id=method,method=method,params=params))+'\n');process.stdin.flush()
        result=json.loads(process.stdout.readline());assert result['ok']==ok,result
        return result.get('result',result.get('error'))
    common=dict(passive_path=str(passive_path),armor_path=str(armor_path))
    cases=[({},{}),({names[0]:[]},{}),({names[0]:[7]},{}),({names[0]:[6,17],names[1]:[6,17]},{}),({names[0]:[1,2,7,16,38]},{38:1})]
    for _ in range(32):
        cases.append(({name:rng.choices(ids,k=rng.randrange(7)) for name in rng.sample(names,5)},
                      {pid:rng.randrange(4)for pid in rng.sample(ids,3)}))
    try:
        for index,(lists,lines) in enumerate(cases):
            params=dict(common,assignments={str(k):v for k,v in lists.items()},description_lines={str(k):v for k,v in lines.items()})
            preview=call('armor-assign-preview',**params)
            target=folder/f'case-{index}'
            report=call('armor-assign-export-copy',output=str(target),**params)
            assert report['installed'] is False and report['mapping']==preview['mapping']
            wanted=lua.globals()[b'assign_oracle'](passives,armors,lua.table_from({k:lua.table_from(v)for k,v in lists.items()}),lua.table_from(lines))
            for filename,reference in zip(['generated_customization_passive_bonuses.dl_plain','generated_customization_armor_sets.dl_plain'],wanted):
                actual=(target/filename).read_bytes()
                assert actual==reference,(index,filename,len(actual),len(reference),next((i for i,(a,b)in enumerate(zip(actual,reference))if a!=b),None))
            call('armor-assign-export-copy',ok=False,output=str(target),**params)
        missing=next(x for x in range(1,100000)if x not in names)
        call('armor-assign-preview',ok=False,assignments={str(missing):[1,2]},**common)
        call('armor-assign-preview',ok=False,assignments={str(names[0]):[123456789]},**common)
        call('armor-assign-preview',ok=False,assignments={},description_lines={'1':4},**common)
    finally:
        process.stdin.close();assert process.wait(timeout=10)==0
    assert passive_path.read_bytes()==passives and armor_path.read_bytes()==armors
print(f'Native per-armor assignment: {len(cases)} exact legacy output pairs, duplicate effects, descriptions, reuse and safe export passed; game writes 0')
