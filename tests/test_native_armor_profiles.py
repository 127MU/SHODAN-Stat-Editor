"""Armor choices + numeric snapshots against the legacy oracle, isolated files only.

LuaJIT is used by this Python oracle, never by the standalone Rust executable.
"""
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
sys.path.insert(0, str(ROOT.parent / 'hd2-hud-plus-repair/vendor'))
from lupa.luajit21 import LuaRuntime

lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
lua.execute(b"jit.off()")  # Avoid the legacy shared u32*/float* scratch-buffer alias optimization.
lua.execute(b'package.path=... .. ";" .. package.path', (ROOT / 'offline/?.lua').as_posix().encode())


def headers(data):
    return lua.table_from([
        lua.table_from({b'at': r['offset'], b'type': int(r['type'], 16), b'size': r['payload_bytes']})
        for r in expected(data)
    ])


lua.globals()[b'py_headers'] = headers
lua.execute(b'''
local ffi=require('ffi')
local allocations={}
package.loaded.gamedata={
    headers=function(p,n)return py_headers(ffi.string(p,n))end,
    alloc=function(n)local p=ffi.new('uint8_t[?]',n);allocations[#allocations+1]=p;return p end,
    free=function()end,
}
local A=require('armory');local D=require('hostdata')
function profile_oracle(config,ids)
    A.refresh(ids);A.profiles=A.parse(config)
    local stacks,off,policy=A.selection({}, {}, ids)
    local groups,sources=A.count()
    return stacks,off,policy,groups,sources
end
function composed_oracle(data,config,ids)
    allocations={}
    local p=ffi.new('uint8_t[?]',#data);ffi.copy(p,data,#data)
    D.files={armor={name='armor',p=p,n=#data}}
    local changes={{name='armor',plain=p,n=#data,bytes=0,floats={}}}
    local stacks,off,policy=profile_oracle(config,ids)
    assert(D.stack(changes,stacks,function()end,off,policy))
    return ffi.string(changes[1].plain,changes[1].n)
end
''')

source = ROOT / 'rust/core/data/armor-baseline.bin'
original = source.read_bytes()
ids = sorted(struct.unpack_from('<I', original, b['payload_offset'])[0]
             for b in expected(original) if b['type'] == '63CE0FEB')
ids.remove(0)  # Empty sentinel is present in the real file, never a selectable passive.
lua_ids = lua.table_from(ids)
with tempfile.TemporaryDirectory(dir=ROOT / 'dist/build-temp-r19', prefix='native-profiles-') as folder:
    folder = pathlib.Path(folder)
    exe = folder / 'shodan-native.exe'
    shutil.copy2(ROOT / 'target/release/shodan-native.exe', exe)
    disk = folder / 'armor.plain'
    disk.write_bytes(original)
    process = subprocess.Popen([str(exe), '--stdio'], cwd=folder, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, text=True, encoding='utf8')
    serial = 0

    def call(method, ok=True, **params):
        global serial
        serial += 1
        process.stdin.write(json.dumps(dict(id=serial, method=method, params=params)) + '\n')
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        assert response['id'] == serial and response['ok'] == ok, response
        return response['result'] if ok else response['error']

    try:
        call('armor-open', path=str(disk), baseline_path=str(source))
        blank = call('armor-state-capture')
        row = call('armor-rows')[0]
        call('armor-set', key=row['key'], value=7.25)
        edited_path = folder / 'numeric.plain'
        call('armor-export-copy', path=str(edited_path))
        edited = edited_path.read_bytes()

        configs = [
            '[profile: Every armor]\n侦察=on\n[profile: 42]\n',
            '[profile: 额外垫料]\nown=no\n侦察=on\n侦察=off\n',
            '[profile: 999]\nown_passive=off\n1=on\n7=on\n',
            '[profile: 999]\n1=on\nconflicts=strongest\n[profile: 7]\n2=on\n',
            '[profile: 42]\n2=on\n[profile: 42]\n1=on\n1=off\n',
            '[profile: 999]\nMedic.damage=555\nraw=1\nconflicts=stack\n',
            '',
        ]
        rng = random.Random(20261105)
        for _ in range(32):
            parts = []
            for pid in [999, *rng.sample(ids, 3)]:
                parts.append(f'[profile: {pid}]\nown_passive={rng.choice(["on", "off"])}\n'
                             f'conflicts={rng.choice(["stack", "strongest"])}\n')
                parts.extend(f'{src}=on\n' for src in rng.sample(ids, rng.randrange(5)))
            configs.append(''.join(parts))
        for index, config in enumerate(configs):
            result = call('armor-profiles-load', text=config)
            _, _, _, groups, sources = lua.globals()[b'profile_oracle'](config.encode(), lua_ids)
            assert result['configured_groups'] == groups and result['selected_sources'] == sources
            path = folder / f'composed-{index}.plain'
            preview = call('armor-compose-preview')
            exported = call('armor-compose-export-copy', path=str(path))
            assert exported == preview and exported['installed'] is False
            wanted = lua.globals()[b'composed_oracle'](edited, config.encode(), lua_ids)
            actual=path.read_bytes()
            if actual!=wanted:
                differences=[i for i,(a,b) in enumerate(zip(actual,wanted)) if a!=b]
                for block in expected(actual):
                    if differences and block['payload_offset']<=differences[0]<block['payload_offset']+block['payload_bytes']:
                        pid=struct.unpack_from('<I',actual,block['payload_offset'])[0]
                        print('target',pid,'payload',actual[block['payload_offset']:block['payload_offset']+block['payload_bytes']].hex(), flush=True)
                raise AssertionError(f'legacy composition mismatch, case {index}: {config!r}; '
                                     f'lengths={len(actual)}/{len(wanted)}, first offsets={differences[:16]}; '
                                     f'bytes={[(i,actual[max(0,i-8):i+12].hex(),wanted[max(0,i-8):i+12].hex()) for i in differences[:4]]}')
            # Numeric configuration lines never replace edited values.
            assert next(r for r in call('armor-rows') if r['key'] == row['key'])['value'] == 7.25

        # Dense and sparse selected IDs remain dictionaries across IPC/reloads.
        call('armor-profiles-clear')
        for enabled in [{'1': True, '2': True}, {'7': True, '42': True}]:
            result = call('armor-profiles-update', id=999, own=True, policy='stack', enabled=enabled)
            assert result['groups'][0]['enabled'] == enabled
            assert call('armor-profiles-load', text=result['text'])['groups'][0]['enabled'] == enabled
        state = call('armor-state-capture')
        ini = folder / 'choices.ini'
        call('armor-profiles-export-copy', path=str(ini))
        assert ini.read_text(encoding='utf8') == call('armor-profiles-get')['text']
        call('armor-state-apply', text=blank)
        assert call('armor-profiles-get')['configured_groups'] == 0
        assert next(r for r in call('armor-rows') if r['key'] == row['key'])['value'] == row['original']
        call('armor-state-apply', text=state)
        assert call('armor-profiles-get')['groups'][0]['enabled'] == {'7': True, '42': True}
        assert next(r for r in call('armor-rows') if r['key'] == row['key'])['value'] == 7.25
        assert call('armor-undo') is True
        assert call('armor-state-capture') == blank
        redo = call('armor-history')['redo']
        call('armor-state-apply', ok=False, text='invalid')
        # A successful no-op and failed edit both preserve the redo branch.
        call('armor-profiles-clear')
        assert call('armor-history')['redo'] == redo
        assert call('armor-redo') is True
        assert call('armor-state-capture') == state

        # Failed settings and snapshot imports leave BOTH halves unchanged.
        for params in [dict(id=999, own=True, policy='stack', enabled=['1']),
                       dict(id=999, own=True, policy='stack', enabled={'7': 1}),
                       dict(id=888, own=True, policy='stack', enabled={'7': True}),
                       dict(id=999, own=True, policy='invalid', enabled={})]:
            call('armor-profiles-update', ok=False, **params)
            assert call('armor-state-capture') == state
        for key, value in [('profiles', '[profile: 888]\n1=on\n'), ('numeric', 'AVP1\ninvalid 1 3\n'),
                           ('profiles', '[profile: 999]\n7=garbage\n'), ('future', 'unsupported')]:
            broken = json.loads(state)
            broken[key] = value
            call('armor-state-apply', ok=False, text=json.dumps(broken))
            assert call('armor-state-capture') == state
        call('armor-profiles-update', id=42, own=True, policy='stack', enabled={})
        call('armor-profiles-update', id=999, own=True, policy='stack', enabled={})
        preview = call('armor-compose-preview')
        assert preview['configured_groups'] == preview['applied_groups'] == 0
        call('armor-profiles-remove', id=42)
        assert [g['id'] for g in call('armor-profiles-get')['groups']] == [999]
        call('armor-profiles-clear')
        path = folder / 'cleared.plain'
        call('armor-compose-export-copy', path=str(path))
        assert path.read_bytes() == edited
        # Never overwrite input/previous exports; never export stale source.
        call('armor-compose-export-copy', ok=False, path=str(path))
        assert path.read_bytes() == edited
        call('armor-compose-export-copy', ok=False, path=str(disk))
        disk.write_bytes(original + b'external edit')
        stale_target = folder / 'stale.plain'
        call('armor-compose-export-copy', ok=False, path=str(stale_target))
        assert not stale_target.exists()
        disk.write_bytes(original)
        call('armor-profiles-update', id=999, own=True, policy='stack', enabled={'7': True})
        call('armor-open', path=str(disk), baseline_path=str(source))
        assert call('armor-profiles-get')['groups'] == []
        assert call('armor-history') == {'undo': 0, 'redo': 0}
        for value in range(110):
            call('armor-set', key=row['key'], value=20+value)
        assert call('armor-history')['undo'] == 100
        history_state = call('armor-state-capture')
        history = call('armor-history')
        call('armor-open', ok=False, path=str(folder/'missing'), baseline_path=str(source))
        assert call('armor-state-capture') == history_state and call('armor-history') == history
        for _ in range(100):
            assert call('armor-undo') is True
        assert call('armor-undo') is False
        assert next(r for r in call('armor-rows') if r['key'] == row['key'])['value'] == 29
        call('armor-set', key=row['key'], value=10)
        assert call('armor-history')['redo'] == 0
    finally:
        process.stdin.close()
        assert process.wait(timeout=10) == 0
    assert disk.read_bytes() == original
assert source.read_bytes() == original
print(f'Native armor profiles: {len(configs)} legacy-byte comparisons; combined snapshots, clear, '
      'dense/sparse selection, failed-import atomicity, stale/overwrite guards passed; game writes 0')
