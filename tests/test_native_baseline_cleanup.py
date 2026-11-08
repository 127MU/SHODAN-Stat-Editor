"""Restore selected old numeric differences without touching managed edits.

All installs run on isolated copies; Steam sources are read only.
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
    for name in ('exe', 'runtime', 'game-data', 'output'):
        parser.add_argument('--' + name, type=pathlib.Path, required=True)
    args = parser.parse_args()
    exe, runtime, source, root = (p.resolve() for p in (args.exe, args.runtime, args.game_data, args.output))
    root.mkdir()
    game = root / 'data/game'
    game.mkdir(parents=True)
    catalog = json.loads(gzip.decompress((runtime / 'catalog.json.gz').read_bytes()))
    names = {b['file'] for f in catalog['fields'] for b in f.get('bindings', [])}
    names.update(('game.dll', 'generated_customization_passive_bonuses.dl_bin',
                  'generated_customization_armor_sets.dl_bin', 'generated_weapon_customization_settings.dl_bin'))
    for name in names:
        shutil.copy2(source / name, game / name)
    for original in (runtime / 'originals').glob('*.dl_plain'):
        sealed = root / (original.stem + '.seed')
        subprocess.run([exe, 'seal-copy', original, sealed], check=True, capture_output=True)
        os.replace(sealed, game / (original.stem + '.dl_bin'))
    # Passive originals are embedded in the Rust core, not a runtime sidecar.
    passive = pathlib.Path(__file__).resolve().parents[1] / 'rust/core/data/armor-baseline.bin'
    sealed = root / 'seeded-passives'
    subprocess.run([exe, 'seal-copy', passive, sealed], check=True, capture_output=True)
    os.replace(sealed, game / 'generated_customization_passive_bonuses.dl_bin')
    for bundle in source.parent.glob('bundles*.nxa'):
        os.link(bundle, game.parent / bundle.name)
    liberator = next(o['id'] for o in catalog['owners'] if o['name'] == 'AR-23 解放者')
    adjudicator = next(o['id'] for o in catalog['owners'] if o['name'] == 'AR-11 仲裁者')
    sentinel_owner = 'F79CD8BB654397DF'
    def start(profile):
        p = subprocess.Popen([exe, '--stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            text=True, encoding='utf-8', env=os.environ | {'SHODAN_PROFILE': str(root / profile)})
        def call(method, **params):
            p.stdin.write(json.dumps(dict(method=method, params=params)) + '\n')
            p.stdin.flush()
            result = json.loads(p.stdout.readline())
            assert result['ok'], result
            return result['result']
        def desktop(name, *args):
            return call('desktop-call', name=name, args=list(args))
        call('game-open', runtime=str(runtime), game=str(game))
        return p, call, desktop
    def close(p):
        p.stdin.close()
        assert p.wait(timeout=30) == 0
    def row(desktop, key):
        return next(r for r in desktop('rows_fast') if r['id'] == key)

    # Emulate another tool's old edits: install under an independent profile.
    p, call, desktop = start('foreign-profile')
    try:
        assert desktop('baseline_cleanup_preview', '')['count'] == 0
        desktop('select', liberator)
        desktop('set', 'sway', 0)
        desktop('set', 'recoil_h', 2)
        desktop('select', sentinel_owner)
        assert row(desktop, 'explosive')['original'] == 1
        desktop('set', 'explosive', .5)
        call('game-install', allow_float_adjustment=True)
    finally:
        close(p)

    p, call, desktop = start('main-profile')
    try:
        desktop('select', adjudicator)
        original_damage = row(desktop, 'damage')['original']
        desktop('set', 'damage', original_damage + 1)
        desktop('select', liberator)
        unselected_recoil = row(desktop, 'recoil_h')['value']
        preview = desktop('baseline_cleanup_preview', '')
        assert preview['preserved'] >= 1
        assert all(not (e['owner_id'] == adjudicator and e['key'] == 'damage') for e in preview['entries'])
        sway = next(e for e in preview['entries'] if e['owner_id'] == liberator and e['key'] == 'sway')
        sentinel = next(e for e in preview['entries'] if e['owner_id'] == sentinel_owner and e['key'] == 'explosive')
        assert (sway['before'], sway['after']) == (0, 1), sway
        before = {n: hashlib.sha256((game / n).read_bytes()).hexdigest() for n in names}
        desktop('set', 'sway', .25)
        try:
            desktop('baseline_cleanup_apply', '', preview['token'], [sway['id']])
        except AssertionError as error:
            assert '重新预览' in str(error), error
        else:
            raise AssertionError('stale preview accepted')
        desktop('set', 'sway', 0)
        preview = desktop('baseline_cleanup_preview', '')
        result = desktop('baseline_cleanup_apply', '', preview['token'], [sway['id'], sentinel['id']])
        assert result['applied'] and not result['installed']
        assert row(desktop, 'sway')['value'] == 1
        assert row(desktop, 'recoil_h')['value'] == unselected_recoil
        desktop('undo')
        assert row(desktop, 'sway')['value'] == 0
        desktop('redo')
        assert row(desktop, 'sway')['value'] == 1
        assert before == {n: hashlib.sha256((game / n).read_bytes()).hexdigest() for n in names}
    finally:
        close(p)
    # Restored selections survive restart and use the ordinary install path.
    p, call, desktop = start('main-profile')
    try:
        desktop('select', liberator)
        assert row(desktop, 'sway')['value'] == 1
        assert row(desktop, 'recoil_h')['value'] == unselected_recoil
        desktop('select', adjudicator)
        assert row(desktop, 'damage')['value'] == original_damage + 1
        call('game-install', allow_float_adjustment=True)
        desktop('select', liberator)
        assert row(desktop, 'sway')['baseline_state'] == 'same'
        assert row(desktop, 'recoil_h')['baseline_state'] == 'different'
        decoded = root / 'restored-values.dl_plain'
        subprocess.run([exe, 'unseal-copy', game / 'generated_entities.dl_bin', decoded], check=True, capture_output=True)
        tables = json.loads(subprocess.check_output([exe, 'tables', decoded]))['tables']
        health = next(t for t in tables if t['type'] == 'B3915DE3')
        record = next(r for r in health['rows'] if r['key'] == 'hash:' + sentinel_owner)
        assert struct.unpack_from('<I', decoded.read_bytes(), record['offset'] + 388)[0] == 0x7F7FFFFF
        call('game-restore')
        assert before == {n: hashlib.sha256((game / n).read_bytes()).hexdigest() for n in names}
    finally:
        close(p)
    print('Baseline cleanup: clean originals, selective restoration, stale-preview rejection, '
          'managed edits, unselected values, undo/redo, restart, install and restore passed.')


if __name__ == '__main__':
    main()
