"""Compare native resource package rebuild byte-for-byte with the old builder."""
import json,pathlib,struct,subprocess,sys,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT.parent/'hd2-hud-plus-repair/vendor'))
from lupa.luajit21 import LuaRuntime
lua=LuaRuntime(encoding=None)
module=lua.execute((ROOT/'offline/res_patch.lua').read_bytes())
def table(**values):return lua.table_from({k.encode():v for k,v in values.items()})
type_raw=struct.pack('<Q',0xFEDCBA9876543210)
spec=table(magic=0xF0000011,unknown=123,trailing=bytes(range(56)),types=lua.table_from([
    table(unknown_raw=b'A'*8,type_raw=type_raw,type_hex=b'FEDCBA9876543210',num_files=0,tail_a=16,tail_b=64)]))
blobs=[]
for i in range(1,4):
    entry=table(id_raw=struct.pack('<Q',0xFFFFFFFFFFFFFFF0+i),type_raw=type_raw,type_hex=b'FEDCBA9876543210',unknown1_raw=b'B'*8,unknown2_raw=b'C'*8,unknown3=17,unknown4=18)
    blobs.append(table(entry=entry,toc=bytes([i])*(i*5),gpu=bytes([i+3])*(i*7),stream=bytes([i+6])*(i*9)))
toc,gpu,stream=module[b'_internal'][b'build_package'](spec,lua.table_from(blobs))
with tempfile.TemporaryDirectory(dir=ROOT/'dist/build-temp-r19',prefix='native-resource-') as folder:
    folder=pathlib.Path(folder);source=folder/'package';source.write_bytes(toc)
    (folder/'gpu').write_bytes(gpu);(folder/'stream').write_bytes(stream)
    output=folder/'rebuilt'
    request=dict(id=1,method='package-rebuild-copy',params=dict(path=str(source),gpu_path=str(folder/'gpu'),stream_path=str(folder/'stream'),output=str(output)))
    run=subprocess.run([str(ROOT/'target/release/shodan-native.exe'),'--stdio'],input=json.dumps(request)+'\n',text=True,encoding='utf8',capture_output=True,check=True)
    response=json.loads(run.stdout);assert response['ok'],response
    assert output.read_bytes()==toc
    assert pathlib.Path(str(output)+'.gpu_resources').read_bytes()==gpu
    assert pathlib.Path(str(output)+'.stream').read_bytes()==stream
    assert source.read_bytes()==toc
print('Native resource package: TOC/GPU/stream bytes match legacy builder; no game writes')
