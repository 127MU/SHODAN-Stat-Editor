"""One-time static-data migration. Lua is a build-time oracle, never a Rust runtime dependency."""
import hashlib,json,pathlib,re,sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT.parent/'hd2-hud-plus-repair/vendor'))
from lupa.luajit21 import LuaRuntime
lua=LuaRuntime()
def plain(value):
    if hasattr(value,'items'):
        keys=list(value.keys())
        if keys and all(isinstance(k,int) for k in keys) and sorted(keys)==list(range(1,len(keys)+1)):
            return [plain(value[k]) for k in sorted(keys)]
        return {str(k):plain(v) for k,v in value.items()}
    return value
source=(ROOT/'offline/armory_data.lua').read_text(encoding='utf8')
data=plain(lua.execute(source))
output=ROOT/'rust/core/data';output.mkdir(parents=True,exist_ok=True)
(output/'armor-catalog.json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
source=(ROOT/'offline/armor_baseline.lua').read_text(encoding='utf8')
section=source.split('local hex=',1)[1].split('local plain=',1)[0]
blob=bytes.fromhex(''.join(re.findall("'([0-9a-fA-F]+)'",section)))
digest=hashlib.sha256(blob).hexdigest()
assert digest=='6ba67061fa05b1aa98cd9cbea19df182a80c6c07c5294440c6da41f3bbb8ad40'
(output/'armor-baseline.bin').write_bytes(blob)
print(json.dumps(dict(passives=len(data['list']),baseline_bytes=len(blob),sha256=digest)))
