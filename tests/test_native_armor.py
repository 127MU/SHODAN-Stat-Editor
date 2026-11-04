"""Independent armor numeric-byte and AVP1 protocol regression; isolated copies only."""
import json,pathlib,struct,subprocess,tempfile
from test_native_data import expected
ROOT=pathlib.Path(__file__).resolve().parents[1]
source=ROOT/'rust/core/data/armor-baseline.bin'
original=source.read_bytes()
values={}
for block in expected(original):
    if block['type'] != '63CE0FEB':
        continue
    payload=original[block['payload_offset']:block['payload_offset']+block['payload_bytes']]
    pid=struct.unpack_from('<I',payload,0)[0]
    seen={}
    for width,po,co in [(16,16,24),(12,32,40)]:
        start=struct.unpack_from('<Q',payload,po)[0]
        count=struct.unpack_from('<I',payload,co)[0]
        for i in range(count):
            at=start+i*width
            effect=struct.unpack_from('<I',payload,at)[0]
            op=struct.unpack_from('<I',payload,at+4)[0] if width==16 else 0
            identity=f'{pid}:{width}:{effect}:{op}'
            seen[identity]=seen.get(identity,0)+1
            values[f'{identity}:{seen[identity]}']=struct.unpack_from('<f',payload,at+8)[0]
with tempfile.TemporaryDirectory(dir=ROOT/'dist/build-temp-r19',prefix='native-armor-') as folder:
    folder=pathlib.Path(folder);disk=folder/'armor.plain';disk.write_bytes(original)
    process=subprocess.Popen([str(ROOT/'target/release/shodan-native.exe'),'--stdio'],cwd=folder,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,encoding='utf8')
    def call(method,**params):
        process.stdin.write(json.dumps(dict(method=method,params=params))+'\n');process.stdin.flush()
        r=json.loads(process.stdout.readline());assert r['ok'],r
        return r['result']
    try:
        call('armor-open',path=str(disk),baseline_path=str(source))
        rows=call('armor-rows');assert rows
        for row in rows:
            assert row['value']==values[row['key']] and row['original']==values[row['key']]
        snapshot=call('armor-capture');key=rows[0]['key']
        call('armor-set',key=key,value=99)
        assert next(r for r in call('armor-rows') if r['key']==key)['value']==99
        call('armor-apply-snapshot',text=snapshot)
        target=folder/'restored.plain';call('armor-export-copy',path=str(target))
        assert target.read_bytes()==original and disk.read_bytes()==original
    finally:
        process.stdin.close();assert process.wait(timeout=10)==0
assert source.read_bytes()==original
print(f'Native armor: {len(rows)} named fields matched independent binary oracle; AVP1 restores exact bytes; game writes 0')
