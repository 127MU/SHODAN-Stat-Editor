"""Exercise the real desktop RPC against an isolated copy of a supported build."""
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
                  'generated_customization_armor_sets.dl_bin',
                  'generated_weapon_customization_settings.dl_bin'})
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
    def start(profile=None, expect_conflict=False):
        p = subprocess.Popen([options.exe.resolve(), '--stdio'], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, text=True, encoding='utf8',
                             env=env if profile is None else env | {'SHODAN_PROFILE': str(profile)})
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
        assert bool(opened['problems']) == expect_conflict, opened['problems']
        return p, call, desktop

    p, call, desktop = start()
    try:
        assert desktop('select', selected['id'])
        attachments = desktop('attachment_options')
        assert len(attachments) == 252, len(attachments)
        assert any(item['hex'] == '0xE790FA4F' and item['slots'] == ['瞄具'] for item in attachments)
        assert not desktop('baseline_check')['problems']
        terminids = desktop('items', 'Terminids', '')
        assert terminids and not any(item['changed'] for item in terminids), terminids
        for owner, key, choice in [
            ('80932FA0ED6901D3', 'empty_weapon', 1),
            ('25AA2FD4643CF4EE', 'spear_arc', 1),
            ('25AA2FD4643CF4EE', 'spear_dual', 1),
            ('CC786F6491FE7E65', 'wasp_burst', 1),
            ('CC786F6491FE7E65', 'wasp_burst', 2),
            ('295BEB26DC4F8FF1', 'heatlvl1_status', 43),
        ]:
            assert desktop('select', owner)
            before = next(row for row in desktop('rows_fast') if row['id'] == key)
            assert before['original'] is not None, before
            assert any(item['id'] == choice for item in desktop('choices', key))
            desktop('choose', key, choice)
            actual = next(row for row in desktop('rows_delta', key) if row['id'] == key)
            assert actual['value'] == choice and actual['changed'], actual
            if key == 'heatlvl1_status':
                assert any(entry['kind'] == 'status' and entry['id'] == 43
                           for entry in desktop('diagnostic_chain')['entries'])
            desktop('reset', key)
            actual = next(row for row in desktop('rows_delta', key) if row['id'] == key)
            assert actual['value'] == before['original'], (before, actual)
        desktop('select', '4D1C334D294DFA97')
        slide = next(row for row in desktop('rows_fast') if row['id'] == 'slide_flat_time')
        assert slide['original'] == 0.5, slide
        desktop('set', 'slide_flat_time', 0.75)
        assert desktop('rows_delta', 'slide_flat_time')[0]['value'] == 0.75
        desktop('reset', 'slide_flat_time')
        desktop('select', selected['id'])
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
        history = desktop('history')
        assert desktop('history_status') == {key: history[key] for key in ('undo', 'redo')}
        assert history['entries']
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
        assert desktop('items', 'Primary', selected['name'])[0]['changed']
        external, _, external_desktop = start(root / 'external-profile')
        try:
            assert not external_desktop('items', 'Primary', selected['name'])[0]['changed']
        finally:
            external.stdin.close()
            assert external.wait(timeout=30) == 0
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
    # Simulate a deleted editor-managed slot which held an archived parameter.
    resource, spec = next(iter(catalog['resource_sources'].items()))
    package = spec['package']
    key = resource.removesuffix('.resource')
    ledger = state.with_name('residency.json')
    ledger.write_text(json.dumps({'groups': {}, 'vacant': {}, 'overrides': {package: [key]},
                                  'slots': {package: {'index': 121, 'hashes': ['a' * 64, None, None]}}}),
                      encoding='utf8')
    p, call, desktop = start(expect_conflict=True)
    try:
        assert desktop('items', 'Primary', selected['name'])
        assert any('.patch_121' in issue for issue in desktop('baseline_check')['problems'])
        assert not desktop('install_preview')['problems']
        desktop('select', selected['id'])
        damage = next(row for row in desktop('rows_fast') if row['id'] == 'damage')
        desktop('set', damage['id'], damage['value'] + 1)
        assert call('game-install', allow_float_adjustment=True)['files'] > 0
        assert ledger.is_file() and not list(data.glob('*.patch_*'))
    finally:
        p.stdin.close()
        p.wait(timeout=30)
    assert ledger.is_file() and not list(data.glob('*.patch_*'))

    ledger.unlink()
    p, call, desktop = start()
    try:
        desktop('select', '25AA2FD4643CF4EE')
        desktop('choose', 'spear_dual', 1)
        assert call('game-install', allow_float_adjustment=True)['files'] > 0
        row = next(r for r in desktop('rows_fast') if r['id'] == 'spear_dual')
        assert row['value'] == 1 and row['original'] == 0 and row['changed'], row
        desktop('reset', 'spear_dual')
        call('game-restore')
        assert {name: digest(game / name) for name in names} == targets
    finally:
        p.stdin.close()
        p.wait(timeout=30)
    # A changed-source draft must be isolated once, without blocking fresh edits.
    draft_path = state.with_name('draft.json')
    stale = json.dumps({
        'version': 1, 'metadata': None,
        'files': {name: {'source': 'outdated-source', 'bytes': {'24': 1}}
                  for name in ('generated_arc_settings.dl_bin',
                               'generated_damage_settings.dl_bin',
                               'generated_entity_deltas.dl_bin',
                               'generated_projectile_settings.dl_bin')},
    }).encode()
    draft_path.write_bytes(stale)
    p, call, desktop = start(expect_conflict=True)
    try:
        preview = desktop('install_preview')
        assert not preview['problems'], preview
        assert any('草稿' in warning for warning in preview['warnings']), preview
        recovery = draft_path.with_name('draft-recovery-' + hashlib.sha256(stale).hexdigest() + '.json')
        assert recovery.read_bytes() == stale
        assert not json.loads(draft_path.read_bytes())['files']
    finally:
        p.stdin.close()
        p.wait(timeout=30)
    p, call, desktop = start()
    try:
        desktop('select', selected['id'])
        row = next(row for row in desktop('rows_fast') if row['id'] == 'damage')
        desktop('set', row['id'], row['value'] + 1)
        assert recovery.read_bytes() == stale
        assert not desktop('install_preview')['problems']
        assert call('game-install', allow_float_adjustment=True)['files'] > 0
        assert recovery.read_bytes() == stale
        call('game-restore')
        assert {name: digest(game / name) for name in names} == targets
    finally:
        p.stdin.close()
        p.wait(timeout=30)
    # Pre-existing edits without our install ledger still differ from verified originals.
    field = catalog['fields'][next(row for row in selected['rows']
                                   if row['key'] == 'damage')['parts'][0]['field']]
    binding, = field['bindings']
    target = game / binding['file']
    saved = target.read_bytes()
    plain = root / 'damage-before.bin'
    subprocess.run([options.exe, 'unseal-copy', target, plain], check=True, capture_output=True)
    tables = json.loads(subprocess.run([options.exe, 'tables', plain], check=True,
                                      capture_output=True, text=True).stdout)['tables']
    table = next(t for t in tables if t['type'] == binding['type'])
    record = next(r for r in table['rows'] if r['key'] == binding['record'])
    offset = record['offset'] + binding['relative']
    edited = bytearray(plain.read_bytes())
    value = struct.unpack_from('<I', edited, offset)[0] + 17
    struct.pack_into('<I', edited, offset, value)
    changed = root / 'damage-after.bin'
    changed.write_bytes(edited)
    sealed = root / 'damage-edited.dl_bin'
    subprocess.run([options.exe, 'prepare-copy', plain, changed, sealed],
                   check=True, capture_output=True)
    target.write_bytes(sealed.read_bytes())
    p, call, desktop = start(expect_conflict=True)
    try:
        assert not desktop('install_preview')['problems']
        desktop('select', selected['id'])
        row = next(r for r in desktop('rows_fast') if r['id'] == 'damage')
        assert row['value'] == value and not row['changed'], row
        assert row['baseline_state'] == 'different', row
        item = next(i for i in desktop('items', 'Primary', '') if i['id'] == selected['id'])
        assert item['baseline_state'] == 'different', item
    finally:
        p.stdin.close()
        p.wait(timeout=30)
        target.write_bytes(saved)
    assert {name: digest(game / name) for name in names} == targets
    print('Native desktop edits, presets, diagnosis, armor, residency, restore, draft recovery and existing-value comparison passed.')


if __name__ == '__main__':
    main()
