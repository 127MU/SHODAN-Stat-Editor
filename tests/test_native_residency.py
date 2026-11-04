"""Synthetic resource/slot integration; no game paths, Lua or codec DLLs."""
import json, pathlib, struct, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST = '9ba626afa44a3aa3'
SOURCE = '0123456789abcdef'
OTHER = '0123456789abcdee'

def package(typ, identity, payload):
    head = bytearray(184)
    struct.pack_into('<III', head, 0, 0xF0000011, 1, 1)
    struct.pack_into('<Q', head, 80, typ)
    struct.pack_into('<Q', head, 104, identity)
    struct.pack_into('<Q', head, 112, typ)
    struct.pack_into('<Q', head, 120, len(head))
    struct.pack_into('<I', head, 160, len(payload))
    return bytes(head) + payload

def bundle(root, contents):
    index = bytearray(24 + 24 * len(contents))
    struct.pack_into('<I', index, 16, len(contents))
    stream = bytearray()
    for i, (name, content) in enumerate(contents.items()):
        name_at = len(index); index.extend(name.encode() + b'\0')
        fragment_at = len(index)
        index.extend(struct.pack('<QI3xB', 0, len(stream), 0))
        struct.pack_into('<QIIII', index, 24 + i*24, len(content), name_at, 1, fragment_at, 0)
        stream.extend(content)
    (root/'bundles.nxa').write_bytes(index)
    dsar = bytearray(64)
    dsar[:4] = b'DSAR'; struct.pack_into('<I', dsar, 8, 1)
    struct.pack_into('<QQIIB7x', dsar, 32, 0, 64, len(stream), len(stream), 0)
    (root/'bundles.00.nxa').write_bytes(dsar + stream)

with tempfile.TemporaryDirectory(dir=ROOT/'dist/build-temp-r19', prefix='native-residency-') as folder:
    root = pathlib.Path(folder)
    bank = b'BKHD'+struct.pack('<I',0)+b'HIRC'+struct.pack('<II',13,1)+bytes([4])+struct.pack('<II',4,123)+bytes(7)
    blob = package(0x535a7bd3e650d799, 0xfffffffffffffff1, bank)
    bundle(root, {SOURCE: blob, OTHER: package(9, 8, bytes(8))})
    before = {f.name:f.read_bytes() for f in root.iterdir()}
    process = subprocess.Popen([str(ROOT/'target/release/shodan-native.exe'),'--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf8')
    def call(method, **params):
        process.stdin.write(json.dumps(dict(id=method,method=method,params=params))+'\n'); process.stdin.flush()
        response = json.loads(process.stdout.readline()); assert response['ok'],response
        return response['result']
    try:
        result = call('resources-resolve',root=str(root), preferred=[], resources=[dict(type='535a7bd3e650d799',id='fffffffffffffff1')], events=[123,999])
        assert result['packages']==[SOURCE] and result['missing_events']==[999],result
        assert result['details'][1]['providers']==[SOURCE],result
        found = call('resource-scan',root=str(root),blobs=[(bytes(4)+struct.pack('<Q',0xfffffffffffffff1)).hex()])
        assert found['candidates']==[dict(type='535a7bd3e650d799',id='fffffffffffffff1')]
        plan = call('residency-plan',root=str(root),ledger=str(root/'residency.txt'),host=HOST,name=SOURCE)
        assert plan==dict(slot=0,reuse=False,state=0,read_only=True),plan
        (root/f'{HOST}.patch_0').write_bytes(blob)
        (root/'residency.txt').write_text(f'{HOST} 0 {SOURCE} full 1\n',encoding='utf8')
        plan = call('residency-plan',root=str(root),ledger=str(root/'residency.txt'),host=HOST,name=SOURCE)
        assert plan==dict(slot=0,reuse=True,state=1,read_only=True),plan
        # Repeat queries preserve cached full-width IDs and event bindings.
        assert call('resources-resolve',root=str(root),preferred=[SOURCE],resources=[],events=[123])['missing_events']==[]
        for name,data in before.items(): assert (root/name).read_bytes()==data
    finally:
        process.stdin.close(); assert process.wait(timeout=10)==0
print('Native residency: full-width providers, event IDs, missing events, aligned scans, ledger reuse; game writes 0')
