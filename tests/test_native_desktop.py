"""Exercise the real desktop RPC against an isolated copy of a supported build."""
import argparse
import gzip
import hashlib
import json
import os
import pathlib
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--exe', type=pathlib.Path, required=True)
    parser.add_argument('--runtime', type=pathlib.Path, required=True)
    parser.add_argument('--game-data', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    options = parser.parse_args()
    runtime = options.runtime.resolve()
    source = options.game_data.resolve()
    root = options.output.resolve()
    root.mkdir()
    data = root / 'data'
    game = data / 'game'
    game.mkdir(parents=True)
    catalog = json.loads(gzip.decompress((runtime / 'catalog.json.gz').read_bytes()))
    names = {binding['file'] for field in catalog['fields']
             for binding in field.get('bindings', [])}
    names.update({'game.dll', 'generated_customization_passive_bonuses.dl_bin',
                  'generated_customization_armor_sets.dl_bin'})
    for name in names:
        shutil.copy2(source / name, game / name)
    # Resource bundles are read-only sources. Every writable target (numeric
    # files, .patch_N files and profiles) is isolated from the Steam tree.
    for bundle in source.parent.glob('bundles*.nxa'):
        os.link(bundle, data / bundle.name)

    env = os.environ | {'SHODAN_PROFILE': str(root / 'profile')}
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    targets = {name: digest(game / name) for name in names}
    selected = next(owner for owner in catalog['owners'] if owner['name'].startswith('AR-11 '))
    sentry = next(owner for owner in catalog['owners'] if owner['name'].startswith('A/G-16 '))
    armor = next(owner for owner in catalog['owners'] if 'armor' in owner)
    def start():
        p = subprocess.Popen([options.exe.resolve(), '--stdio'], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, text=True, encoding='utf8', env=env)
        def call(method, **params):
            request = {'method': method, 'params': params}
            p.stdin.write(json.dumps(request) + '\n')
            p.stdin.flush()
            reply = json.loads(p.stdout.readline())
            assert reply['ok'], (method, params.get('name'), reply.get('error'))
            return reply['result']
        def desktop(name, *args):
            return call('desktop-call', name=name, args=args)
        opened = call('game-open', runtime=str(runtime), game=str(game))
        assert not opened['problems'], opened['problems']
        return p, call, desktop

    p, call, desktop = start()
    try:
        assert desktop('select', selected['id'])
        assert desktop('game_text', 'name')['available']
        assert desktop('armor_item', armor['id'])['available']
        armor_profile = desktop('armor_profile', 999)
        assert isinstance(armor_profile['enabled'], dict)
        passive_id = desktop('info')['armor'][0]['id']
        passive_row = desktop('armor_rows', passive_id)[0]
        passive_value = 123.25 if passive_row['value'] != 123.25 else 124.25
        desktop('armor_set', passive_id, passive_row['key'], passive_value)
        assert desktop('armor_rows', passive_id)[0]['value'] == passive_value
        assert desktop('ragdoll_preview')['supported']
        assert desktop('tweaks').keys() == {'reticle', 'bounce', 'foliage', 'vehicles'}
        assert desktop('tweaks', 'vehicles', True)['vehicles']
        assert not desktop('tweaks', 'vehicles', False)['vehicles']

        rows = desktop('rows_fast')
        damage = next(row for row in rows if row['id'] == 'damage')
        desktop('set', damage['id'], damage['value'] + 1)
        assert desktop('undo')
        assert desktop('redo')
        desktop('full_preset', 'new', None, '隔离测试')
        code = desktop('preset_code', 1)
        assert code.startswith('SSEO-S2-')
        desktop('preset_code_import', code)
        assert len(desktop('full_presets')) == 2
        desktop('preset_description', 'full', 1, '隔离测试说明')
        desktop('preset_duplicate', 'full', 1, '隔离测试副本')
        assert desktop('full_presets')[2]['description'] == '隔离测试说明'
        desktop('editor_mode', True)
        desktop('restore_examples')
        assert len(desktop('full_presets')) == 4
        desktop('editor_mode', False)
        assert any(check['name'] == '游戏数据目录' and check['ok']
                   for check in call('diagnostic-check'))
        report = root / 'diagnostics.json'
        call('diagnostic-export', path=str(report), report={
            'events': [r'C:\Users\PrivateUser\Local\SHODAN token=must-hide'],
        })
        exported = report.read_text(encoding='utf8')
        assert 'PrivateUser' not in exported and 'must-hide' not in exported
    finally:
        p.stdin.close()
        p.wait(timeout=30)

    p, call, desktop = start()
    try:
        assert desktop('armor_rows', passive_id)[0]['value'] == passive_value
        desktop('armor_set', passive_id, passive_row['key'], passive_row['value'])
        desktop('select', selected['id'])
        changed = desktop('rows_delta', damage['id'])
        assert any(row['id'] == damage['id'] and row['value'] == damage['value'] + 1
                   for row in changed), changed
        installed = call('game-install', allow_float_adjustment=True)
        assert installed['files'] > 0, installed
        assert {name: digest(game / name) for name in names} != targets
        restored = call('game-restore')
        assert restored['files'] == installed['files'], (installed, restored)
        assert {name: digest(game / name) for name in names} == targets
        desktop('select', selected['id'])
        retained = desktop('rows_delta', damage['id'])
        assert retained[0]['value'] == damage['value'] + 1, retained

        projectile = next(row for row in desktop('rows_fast') if row['id'] == 'projectile')
        desktop('choose', projectile['id'], 220)
        desktop('select', sentry['id'])
        rows = desktop('rows_fast')
        assert any(row['id'] == 'smmode' for row in rows)
        assert desktop('choices', 'smres'), rows
        desktop('set', 'always', 1)
        assert desktop('install_preview')['entries']
        installed = call('game-install', allow_float_adjustment=True)
        assert installed['files'] >= 2, installed
        state = next((root / 'profile' / 'native-game').glob('*/configuration.json'))
        derived = json.loads(state.read_text(encoding='utf8'))['derived_stratagem_words']
        assert any('200' in fields for fields in derived.values()), derived
        assert any('168' in fields for fields in derived.values()), derived
        desktop('select', sentry['id'])
        desktop('set', 'always', 0)
        desktop('select', selected['id'])
        desktop('reset', projectile['id'])
        call('game-install', allow_float_adjustment=True)
        assert 'derived_stratagem_words' not in json.loads(state.read_text(encoding='utf8'))
        call('game-restore')
        assert {name: digest(game / name) for name in names} == targets

        desktop('armor_update', 2, 1, True)
        assert desktop('armor_profile', 2)['enabled'] == {'1': True}
        assert any(row['equipment'] == '护甲被动组合' for row in desktop('install_preview')['entries'])
        call('game-install', allow_float_adjustment=True)
        desktop('armor_update', 2, 1, False)
        call('game-install', allow_float_adjustment=True)
        assert not desktop('armor_profile', 2)['enabled']
        call('game-restore')
        assert {name: digest(game / name) for name in names} == targets

        desktop('ragdoll_apply', True)
        assert desktop('ragdoll_preview')['enabled']
        desktop('select', selected['id'])
        packages = desktop('choices', 'res_package')
        donor = next(p for p in packages if 'A/M-23' in p.get('name', p.get('label', '')))
        desktop('choose', 'res_package', donor['id'])
        desktop('choose', 'resomode', 1)
        resource = next(row for row in desktop('rows_delta', 'resomode') if row['id'] == 'resomode')
        assert resource['value'] == 1, resource
        desktop('choose', 'resomode', 3)
        assert desktop('ragdoll_preview')['enabled']
        desktop('ragdoll_apply', False)
        assert not desktop('ragdoll_preview')['enabled']
        assert not list(data.glob('*.patch_*'))
    finally:
        p.stdin.close()
        p.wait(timeout=30)
    print('Native desktop edits, presets, diagnosis, armor, resource residency and restore passed.')


if __name__ == '__main__':
    main()
