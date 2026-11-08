"""PR149 vehicle regression through real RPC, sealing and isolated install.

Never writes the supplied Steam tree. Seed entities from the pinned original
so the physical offsets below refer to that exact fixture only.
"""
import argparse
import gzip
import hashlib
import json
import os
import pathlib
import shutil
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=pathlib.Path, required=True)
    parser.add_argument('--runtime', type=pathlib.Path, required=True)
    parser.add_argument('--game-data', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    exe, runtime, source, root = (p.resolve() for p in
        (args.exe, args.runtime, args.game_data, args.output))
    root.mkdir()
    game = root / 'data/game'
    game.mkdir(parents=True)
    catalog = json.loads(gzip.decompress((runtime / 'catalog.json.gz').read_bytes()))
    names = {b['file'] for f in catalog['fields'] for b in f.get('bindings', [])}
    names.update(('game.dll', 'generated_customization_passive_bonuses.dl_bin',
                  'generated_customization_armor_sets.dl_bin', 'generated_weapon_customization_settings.dl_bin'))
    for name in names:
        shutil.copy2(source / name, game / name)
    for bundle in source.parent.glob('bundles*.nxa'):
        os.link(bundle, game.parent / bundle.name)
    entities = game / 'generated_entities.dl_bin'
    plain = runtime / 'originals/generated_entities.dl_plain'
    seeded = root / 'seeded-entities.dl_bin'
    subprocess.run([exe, 'seal-copy', plain, seeded], check=True, capture_output=True)
    os.replace(seeded, entities)
    initial = entities.read_bytes()
    original = plain.read_bytes()
    tables = json.loads(subprocess.check_output([exe, 'tables', plain]))['tables']
    records = {t['type']: {r['key']: r['offset'] for r in t['rows']} for t in tables}
    entity = 'hash:CC21C7FFD3EBEFB9'
    vehicle = '00000000EA902C4B'
    # Both float bit patterns and packed one-byte booleans are checked.
    cases = [
        ('vehicle_fuel_max', 'EAEB2B0D', 0x864, 'f', 12345.5),
        ('wheel1_length', 'EAEB2B0D', 8, 'f', 0.625),
        ('wheel1_drive', 'EAEB2B0D', 12, 'B', 0),
        ('seat_stratagem', '4AEAFC86', 0x110, 'B', 1),
        ('motion_acceleration', '83B65443', 0, 'f', -2.5),
        ('motion_steering', '83B65443', 0x16C, 'f', 23.5),
        ('collision_damage_base', '20288698', 16, 'f', 432.5),
        ('collision_demolition_lower_speed', '20288698', 60, 'f', -1.0),
    ]
    process = subprocess.Popen([exe, '--stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        text=True, encoding='utf-8', env=os.environ | {'SHODAN_PROFILE': str(root / 'profile')})
    def call(method, **params):
        process.stdin.write(json.dumps(dict(method=method, params=params)) + '\n')
        process.stdin.flush()
        result = json.loads(process.stdout.readline())
        assert result['ok'], result
        return result['result']
    def desktop(name, *values):
        return call('desktop-call', name=name, args=list(values))
    try:
        call('game-open', runtime=str(runtime), game=str(game))
        desktop('select', vehicle)
        rows = {r['id']: r for r in desktop('rows_fast')}
        assert 'wheel4_length' in rows and 'wheel5_length' not in rows
        for key, typ, relative, fmt, value in cases:
            offset = records[typ][entity] + relative
            assert rows[key]['original'] == struct.unpack_from('<' + fmt, original, offset)[0], rows[key]
            desktop('set', key, value)
        desktop('full_preset', 'new', None, '载具组件回归')
        exported = desktop('preset_export', 'full', 1)
        assert 'motion_acceleration' in exported
        for key, *_ in cases:
            desktop('reset', key)
        desktop('preset_import', 'full', 2, exported)
        # Import stores a preset; explicitly load it through the same UI action.
        desktop('full_preset', 'load', 2)
        actual = {r['id']: r for r in desktop('rows_fast')}
        for key, _, _, _, value in cases:
            assert actual[key]['value'] == value, actual[key]
        desktop('select', '00000000119EF38F')
        exo = desktop('rows_fast')
        assert not any(r['id'].startswith('wheel') or r['id'].startswith('motion_') for r in exo)
        installed = call('game-install', allow_float_adjustment=True)
        assert installed['files'] > 0, installed
        decoded = root / 'installed-entities.dl_plain'
        subprocess.run([exe, 'unseal-copy', entities, decoded], check=True, capture_output=True)
        changed = decoded.read_bytes()
        for key, typ, relative, fmt, value in cases:
            offset = records[typ][entity] + relative
            packed = struct.pack('<' + fmt, value)
            assert changed[offset:offset + len(packed)] == packed, key
            if fmt == 'B':
                assert changed[offset + 1:offset + 4] == original[offset + 1:offset + 4], key
        call('game-restore')
        assert entities.read_bytes() == initial
        print(json.dumps(dict(cases=len(cases), preset_roundtrip=True, install_restore=True,
            original_sha256=hashlib.sha256(original).hexdigest())))
    finally:
        process.stdin.close()
        process.wait(timeout=30)


if __name__ == '__main__':
    main()
