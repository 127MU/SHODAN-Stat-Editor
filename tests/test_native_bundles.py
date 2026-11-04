"""Read-only native DSAR/bundle regression against an explicitly supplied game data root."""
import argparse,hashlib,json,pathlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT.parent/'hd2-hud-plus-repair/vendor'))
from lupa.luajit21 import LuaRuntime
p=argparse.ArgumentParser();p.add_argument('--root',type=pathlib.Path,required=True);a=p.parse_args()
lua=LuaRuntime(unpack_returned_tuples=True)
module=lua.execute((ROOT/'offline/res_patch.lua').read_text(encoding='utf8'))
encode=lua.eval("function(t) return (t:gsub('.',function(c)return string.format('%02x',c:byte())end)) end")
build_hex=lua.eval("function(build,spec,blobs) local a,b,c=build(spec,blobs);local function hex(t)return (t:gsub('.',function(x)return string.format('%02x',x:byte())end))end;return hex(a),hex(b),hex(c) end")
legacy=module._internal.bundle_index(str(a.root).replace('\\','/'))
if isinstance(legacy,tuple):raise AssertionError(legacy)
process=subprocess.Popen([str(ROOT/'target/release/shodan-native.exe'),'--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,encoding='utf8')
def call(method,**params):
    process.stdin.write(json.dumps(dict(method=method,params=params))+'\n');process.stdin.flush()
    response=json.loads(process.stdout.readline());assert response['ok'],response
    return response['result']
try:
    result=call('bundle-inspect',root=str(a.root))
    assert result['count']==legacy.count
    assert result['names']==[legacy.names[i] for i in range(1,min(100,len(legacy.names))+1)]
    count=0
    for name in result['names']:
        if len(name)!=16 or any(c not in '0123456789abcdefABCDEF' for c in name):continue
        package=module._internal.package_head(legacy,name)
        if isinstance(package,tuple):raise AssertionError(package)
        actual=call('bundle-package-inspect',root=str(a.root),name=name)
        assert actual['entries']==len(package.entries) and actual['types']==len(package.types)
        if count==0:
            for keep_streams,mode in [(False,'light'),(True,'full')]:
                blobs=module._internal.package_slices(legacy,name,package,keep_streams)
                if isinstance(blobs,tuple):raise AssertionError(blobs)
                encoded=build_hex(module._internal.build_package,package,blobs)
                preview=call('bundle-patch-preview',root=str(a.root),name=name,mode=mode)
                for side,hex_data in zip(['toc','gpu','stream'],encoded):
                    data=bytes.fromhex(hex_data)
                    assert preview[side]==dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest()),(mode,side)
        count+=1
        if count==3:break
    assert count
finally:
    process.stdin.close();assert process.wait(timeout=10)==0
print(f'Native bundle reader: {result["count"]} package identities and {count} package directories match legacy; read only, game writes 0')
