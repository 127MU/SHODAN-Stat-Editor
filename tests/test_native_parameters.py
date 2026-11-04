"""Native logical parameter/preset regression against a copied shipped fixture."""
import json, pathlib, struct, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
exe = ROOT / 'target/release/shodan-native.exe'
source = ROOT / 'offline/originals/generated_projectile_settings.dl_plain'
original = source.read_bytes()
tables = json.loads(subprocess.check_output([str(exe), 'tables', str(source)], encoding='utf8'))
table = next(t for t in tables['tables'] if t['type'] == 'BD4042C2')
row = next(r for r in table['rows'] if r['key'] == 'id:67')
with tempfile.TemporaryDirectory(dir=ROOT / 'dist/build-temp-r19', prefix='native-parameters-') as folder:
    folder = pathlib.Path(folder)
    disk = folder / 'projectile.plain'
    disk.write_bytes(original)
    process = subprocess.Popen([str(exe), '--stdio'], cwd=folder, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding='utf8')
    def call(method, **params):
        process.stdin.write(json.dumps(dict(id=method, method=method, params=params))+'\n'); process.stdin.flush()
        return json.loads(process.stdout.readline())
    try:
        opened = call('open', path=str(disk), baseline_path=str(source), baseline_name=source.name)
        assert opened['ok'], opened
        block = next(b['index'] for b in opened['result']['blocks'] if b['type'] == 'BD4042C2')
        assert call('index', block=block, layout='rows', stride=272, id_offset=0)['ok']
        owner = 'FFFFFFFFFFFFFFFF'
        for parameter in ['mass', 'gravity']:
            result = call('bind-parameter', owner=owner, parameter=parameter, fields=[dict(block=block, record='id:67', parameter=parameter)])
            assert result['ok'], result
        preset = 'SHODAN-PRESET 1\nkind full\nname 41\nvalue FFFFFFFFFFFFFFFF mass 1000000\nvalue FFFFFFFFFFFFFFFF gravity -2.5\n'
        preview = call('preset-compare', text=preset)
        assert preview['ok'], preview
        assert preview['result']['pending'] == 0
        changes = {c['parameter']: c for c in preview['result']['changes']}
        assert changes['mass']['before'] == struct.unpack_from('<f', original, row['offset']+36)[0]
        assert changes['gravity']['after'] == -2.5
        assert call('preset-apply-values', text=preset)['ok']
        assert call('history')['result']['undo'] == 1
        exported = folder / 'edited.plain'
        assert call('export-copy', path=str(exported))['ok']
        expected = bytearray(original)
        struct.pack_into('<f', expected, row['offset']+36, 1000000)
        struct.pack_into('<f', expected, row['offset']+44, -2.5)
        assert exported.read_bytes() == expected
        assert disk.read_bytes() == original
        assert call('undo')['result']['pending'] == 0
        invalid = preset + 'value FFFFFFFFFFFFFFFF missing_field 3\n'
        assert not call('preset-apply-values', text=invalid)['ok']
        assert call('preview')['result']['pending'] == 0
        assert call('preset-apply-values', text=invalid, allow_missing=True)['result']['warnings']
    finally:
        process.stdin.close(); assert process.wait(timeout=10) == 0
assert source.read_bytes() == original
print('Native parameters: projectile #67, trusted baseline, preview, atomic preset, exact bytes and undo passed; game writes 0')
