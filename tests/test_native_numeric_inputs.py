"""Integer-looking float inputs survive Rust drafts, install and reopen.

Creates a new isolated game/profile; never writes to Steam files.
"""
import argparse
import gzip
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
    originals = list((runtime / 'originals').glob('*.dl_plain'))
    originals.append(pathlib.Path(__file__).resolve().parents[1] / 'rust/core/data/armor-baseline.bin')
    for i, original in enumerate(originals):
        target = 'generated_customization_passive_bonuses.dl_bin' if original.name == 'armor-baseline.bin' else original.stem + '.dl_bin'
        sealed = root / f'seed-{i}'
        subprocess.run([exe, 'seal-copy', original, sealed], check=True, capture_output=True)
        os.replace(sealed, game / target)
    for bundle in source.parent.glob('bundles*.nxa'):
        os.link(bundle, game.parent / bundle.name)

    def start():
        p = subprocess.Popen([exe, '--stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            text=True, encoding='utf8', env=os.environ | {'SHODAN_PROFILE': str(root / 'profile')})
        def call(method, **params):
            p.stdin.write(json.dumps(dict(method=method, params=params)) + '\n')
            p.stdin.flush()
            reply = json.loads(p.stdout.readline())
            assert reply['ok'], reply
            return reply['result']
        def desktop(name, *values):
            return call('desktop-call', name=name, args=list(values))
        call('game-open', runtime=str(runtime), game=str(game))
        return p, call, desktop
    def close(p):
        p.stdin.close()
        assert p.wait(timeout=30) == 0
    def values(desktop):
        return {r['id']: r for r in desktop('rows_fast')}

    p, call, desktop = start()
    try:
        desktop('select', '96DE9CD50F7306E6')
        for key in ('arc_range', 'mul_arc_splits_min', 'mul_arc_splits_max',
                    'mul_arc_chains_min', 'mul_arc_chains_max'):
            for text in ('2', '2.000000001', '2.0', '2e0'):
                desktop('set', key, text)
                assert values(desktop)[key]['value'] == 2, (key, text, values(desktop)[key])
        for key in ('arc_chain', 'arc_split'):
            desktop('set', key, '2')
            assert values(desktop)[key]['value'] == 2
    finally:
        close(p)
    p, call, desktop = start()
    try:
        desktop('select', '96DE9CD50F7306E6')
        expected = {k: v['value'] for k, v in values(desktop).items() if k.startswith(('arc_', 'mul_arc_'))}
        assert expected['arc_range'] == 2
        result = call('game-install', allow_float_adjustment=True)
        assert result['files'] > 0, result
    finally:
        close(p)
    p, call, desktop = start()
    try:
        desktop('select', '96DE9CD50F7306E6')
        actual = values(desktop)
        for key, value in expected.items():
            # Hash correction in single-block tables may use up to 4095 low
            # float bits, and only with the explicit install opt-in above.
            asked_bits = struct.unpack('<I', struct.pack('<f', value))[0]
            actual_bits = struct.unpack('<I', struct.pack('<f', actual[key]['value']))[0]
            assert asked_bits ^ actual_bits <= 4095, (key, value, actual[key])
        call('game-restore')
    finally:
        close(p)
    # A malformed game table must not blank all categories or trap auto-repair.
    damaged = game / 'generated_stratagem_settings.dl_bin'
    damaged.write_bytes(b'corrupt-sealed-stratagem')
    before = {n: (game / n).read_bytes() for n in names if n != damaged.name}
    p, call, desktop = start()
    try:
        desktop('select', '96DE9CD50F7306E6')
        assert values(desktop)['arc_range']['original'] == 55
        report = call('game-repair')
        assert any('1' in action and '无法解析' in action for action in report['actions']), report
        assert before == {n: (game / n).read_bytes() for n in before}
        assert damaged.read_bytes() != b'corrupt-sealed-stratagem'
        assert any(path.read_bytes() == b'corrupt-sealed-stratagem'
                   for path in (root / 'profile/native-game').rglob('*.original'))
    finally:
        close(p)
    print(json.dumps(dict(ok=True, inputs=['2', '2.0', '2e0', '2.000000001'],
                         invalid_table_repaired=True, game=str(game))))


if __name__ == '__main__':
    main()
