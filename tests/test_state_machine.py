"""state_machine: parse/recipe/apply over synthetic Stingray resources; a real AC-8 blob only if present."""
import pathlib, struct, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
from lupa.luajit21 import LuaRuntime

# hashes from the turret/fortification state-machine recipe table
DEPLOYED = '823905BD6B62BA3E'
TRANSITION = '79DE1870039A1A7E'
FOLDED = '330CA356421F7ADA'
RETRACT = 'D23167BF92D249B8'
SWEEP = '9EA750D5873EB183'
EMPTY = '86342D705E08AD12'
DEPLOY_DONE = 0x3D0B77D2
# a real AC-8 blob, if somebody dropped one next to the tests; never required
REAL_BLOBS = [ROOT / 'tests/fixtures/ac8_state_machine.bin',
              ROOT / 'tests/fixtures/state_machine_ac8.bin',
              pathlib.Path('D:/Helldiver2Mod/mod/out/sm-patch8/sm_rocket.bin')]


def state(name, stype=0, loop=0, additive=0, anims=(), emit=0, end_t=0.0, links=(), events=()):
    """One state record: 80 fixed bytes, then the animation hash / event / link tables it points at."""
    body = bytearray(80)
    struct.pack_into('<II', body, 0, int(name[8:], 16), int(name[:8], 16))   # low u32 first
    struct.pack_into('<I', body, 8, stype)
    body[32] = loop
    body[36] = additive
    struct.pack_into('<I', body, 72, emit)
    struct.pack_into('<f', body, 76, end_t)
    after = len(body)
    anim_at = after if anims else 0
    event_at = after + 8 * len(anims) if events else 0
    link_at = after + 8 * len(anims) + 8 * len(events) if links else 0
    struct.pack_into('<II', body, 12, len(anims), anim_at)
    struct.pack_into('<II', body, 40, len(events), event_at)
    struct.pack_into('<II', body, 48, len(links), link_at)
    tail = bytearray()
    for anim in anims:
        tail += struct.pack('<Q', int(anim, 16))
    for event, link in events:
        tail += struct.pack('<Ii', event, link)
    for index, blend, kind, beat in links:
        tail += struct.pack('<IfII', index, blend, kind, beat)
    return bytes(body + tail)


def layer(states, default, magic=0x11):
    """magic | default_state | state_count | state offsets[] , then the state records themselves."""
    head = bytearray(12 + 4 * len(states))
    struct.pack_into('<III', head, 0, magic, default, len(states))
    offsets, body, cursor = [], bytearray(), 12 + 4 * len(states)
    for item in states:
        offsets.append(cursor)
        body += item
        cursor += len(item)
    if offsets:
        struct.pack_into('<%dI' % len(offsets), head, 12, *offsets)
    return bytes(head + body)


def build(layers, events=()):
    """15 u32 header, layer table at offset 60, layer records, event hash table.  Returns (bytes, default_at[])."""
    count = len(layers)
    groups = 60
    cursor = groups + 4 + 4 * count
    rel, blobs, defaults = [], [], []
    for states, default in layers:
        blob = layer(states, default)
        rel.append(cursor - groups)
        defaults.append(groups + rel[-1] + 4)
        blobs.append(blob)
        cursor += len(blob)
    out = bytearray(60)
    struct.pack_into('<15I', out, 0, 0, count, groups, len(events), cursor if events else 0, *([0] * 10))
    out += struct.pack('<I', count)
    if count:
        out += struct.pack('<%dI' % count, *rel)
    for blob in blobs:
        out += blob
    for event in events:
        out += struct.pack('<I', event)
    return bytes(out), defaults


def deploy_states():
    return [state(RETRACT, stype=0, loop=1),
            state(FOLDED, stype=0, loop=1),
            state(TRANSITION, stype=3, loop=0, anims=('0123456789ABCDEF', 'FEDCBA9876543210'),
                  emit=DEPLOY_DONE, end_t=1.0, links=((2, 0.0, 1, 0),), events=((DEPLOY_DONE, 0),)),
            state(DEPLOYED, stype=3, loop=1)]


def template_a(layer0_default=1, layer1_default=0):
    return [(deploy_states(), layer0_default),
            ([state(SWEEP, stype=0, loop=1), state(EMPTY, stype=1, loop=0)], layer1_default)]


def template_b(layer0_default=1, layer1_default=0):
    """The same turret without a deployed state: the transition's last frame is all it has."""
    return [(deploy_states()[:3], layer0_default),
            ([state(SWEEP, stype=0, loop=1), state(EMPTY, stype=1, loop=0)], layer1_default)]


def items(table):
    """Lua arrays come back as proxies whose iteration yields keys; read them by index instead."""
    return [table[i] for i in range(1, len(table) + 1)]


LUA = '''
M = require('state_machine')
function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
function HEX(s) return (s:gsub('.', function(c) return string.format('%02X', c:byte()) end)) end
function P(b) local sm, why = M.parse(b) if sm then return sm, '' end return false, why or '' end
function R(b) local sm, why = M.parse(b) if not sm then return false, why end
  local plan, pwhy = M.recipe(sm) if plan then return plan, '' end return false, pwhy or '' end
function A(b, plan) local out, why = M.apply(b, plan) if out then return HEX(out), '' end return false, why or '' end
function V(sm, plan) return table.concat(M.preview(sm, plan), string.char(10)) end
'''


class StateMachineTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("package.path=" + repr((ROOT / 'offline/?.lua').as_posix()) + "..';'..package.path")
        self.lua.execute(LUA)
        self.g = self.lua.globals()
        self.M = self.g.M

    # ---- helpers: blobs travel as arguments only, a byte-returning global would trip lupa's utf-8 decode
    def parse(self, data):
        return self.g.P(data)

    def recipe_of(self, data):
        return self.g.R(data)

    def apply_to(self, data, plan):
        out, why = self.g.A(data, plan)
        return (bytes.fromhex(out) if out is not False else False), why

    def preview_of(self, data, plan):
        sm, why = self.parse(data)
        self.assertIsNot(sm, False, why)
        return self.g.V(sm, plan).split('\n')

    def state_index(self, data, name):
        sm, why = self.parse(data)
        self.assertIsNot(sm, False, why)
        for index, item in enumerate(items(sm['layers'][1]['states'])):
            if item['name'] == name:
                return index
        raise AssertionError('state ' + name + ' missing from layer0')

    # ---- 1. parse a template-A blob
    def test_parse_template_a(self):
        data, defaults = build(template_a(), events=(DEPLOY_DONE,))
        sm, why = self.parse(data)
        self.assertIsNot(sm, False, why)
        self.assertEqual(sm['size'], len(data))
        self.assertEqual(sm['header']['group_count'], 2)
        self.assertEqual(sm['header']['groups_off'], 60)
        self.assertEqual(sm['header']['event_hash_count'], 1)
        self.assertEqual(sm['events'][1], '3D0B77D2')
        self.assertEqual(len(sm['layers']), 2)
        first = sm['layers'][1]
        self.assertEqual(first['index'], 0)
        self.assertEqual(first['default'], 1)
        self.assertEqual(first['default_at'], defaults[0])
        self.assertEqual(len(first['states']), 4)
        self.assertEqual([first['states'][i]['name'] for i in (1, 2, 3, 4)],
                         [RETRACT, FOLDED, TRANSITION, DEPLOYED])
        deploy = first['states'][3]
        self.assertEqual(deploy['index'], 2)
        self.assertEqual(deploy['type'], 3)
        self.assertEqual(deploy['loop'], 0)
        self.assertEqual(deploy['additive'], 0)
        self.assertEqual(deploy['emit'], '3D0B77D2')
        self.assertAlmostEqual(deploy['end_t'], 1.0, places=6)
        self.assertEqual(deploy['anim_count'], 2)
        self.assertEqual(items(deploy['anims']), ['0123456789ABCDEF', 'FEDCBA9876543210'])
        self.assertEqual(len(deploy['links']), 1)
        self.assertEqual(deploy['links'][1]['index'], 2)
        self.assertEqual(deploy['links'][1]['type'], 1)
        self.assertAlmostEqual(deploy['links'][1]['blend'], 0.0, places=6)
        self.assertEqual(deploy['trans']['3D0B77D2'], 0)
        second = sm['layers'][2]
        self.assertEqual(second['default'], 0)
        self.assertEqual([item['name'] for item in items(second['states'])], [SWEEP, EMPTY])
        self.assertEqual(second['states'][2]['type'], 1)
        self.assertIsNone(second['states'][2]['emit'])
        self.assertEqual(self.g.count(self.M.NAMES), 8)
        self.assertEqual(self.g.count(self.M.EVENTS), 7)
        self.assertEqual(self.M.TYPE, 'A486D4045106165C')
        self.assertEqual(self.M.NAMES[DEPLOYED], 'deployed')
        self.assertEqual(self.M.EVENTS['3D0B77D2'], 'DeployDone')
        ok, kind = self.lua.execute("local ok, m = pcall(require, 'state_machine') return ok, type(m)")
        self.assertTrue(ok)
        self.assertEqual(kind, 'table')

    # ---- 2. recipe for both templates, plus idempotence
    def test_recipe_templates(self):
        data, _ = build(template_a(), events=(DEPLOY_DONE,))
        plan, why = self.recipe_of(data)
        self.assertIsNot(plan, False, why)
        self.assertEqual(plan['template'], 'A')
        self.assertEqual(plan['count'], 2)
        self.assertEqual(len(plan['changes']), 2)
        self.assertEqual((plan['changes'][1]['layer'], plan['changes'][1]['from'],
                          plan['changes'][1]['to'], plan['changes'][1]['why']), (0, 1, 3, 'deployed_open'))
        self.assertEqual((plan['changes'][2]['layer'], plan['changes'][2]['from'],
                          plan['changes'][2]['to'], plan['changes'][2]['why']), (1, 0, 1, 'sweep_off'))
        self.assertIsNone(plan['warn'])
        self.assertEqual(plan['changes'][1]['to'], self.state_index(data, DEPLOYED))

        data, _ = build(template_b(), events=(DEPLOY_DONE,))
        plan, why = self.recipe_of(data)
        self.assertIsNot(plan, False, why)
        self.assertEqual(plan['template'], 'B')
        self.assertEqual(plan['count'], 2)
        self.assertEqual(plan['changes'][1]['to'], 2)
        self.assertEqual(plan['changes'][1]['why'], 'deploy_transition')
        self.assertEqual(plan['changes'][1]['to'], self.state_index(data, TRANSITION))

        # already deployed and already swept: nothing to do
        data, _ = build(template_a(layer0_default=3, layer1_default=1), events=(DEPLOY_DONE,))
        plan, why = self.recipe_of(data)
        self.assertIsNot(plan, False, why)
        self.assertEqual(plan['template'], 'A')
        self.assertEqual(plan['count'], 0)
        self.assertEqual(len(plan['changes']), 0)
        self.assertIsNone(plan['warn'])

        # a turret with neither deployed nor transition state is left alone
        data, _ = build([([state(SWEEP, stype=0, loop=1), state(EMPTY, stype=1, loop=0)], 0)])
        plan, why = self.recipe_of(data)
        self.assertIsNot(plan, False, why)
        self.assertEqual(plan['template'], 'none')
        self.assertEqual(plan['count'], 0)

        # a single-state layer0 is below the two-state floor and is skipped
        data, _ = build([([state(FOLDED, stype=0, loop=1)], 0),
                         ([state(SWEEP, stype=0, loop=1), state(EMPTY, stype=1, loop=0)], 0)])
        plan, why = self.recipe_of(data)
        self.assertIsNot(plan, False, why)
        self.assertEqual(plan['template'], 'none')
        self.assertEqual(plan['count'], 1)
        self.assertEqual(plan['changes'][1]['why'], 'sweep_off')

        # three changes means the blob is not the shape the recipe expects: flag it, do not hide it
        sweep = ([state(SWEEP, stype=0, loop=1), state(EMPTY, stype=1, loop=0)], 0)
        data, _ = build([template_a()[0], sweep, sweep])
        plan, why = self.recipe_of(data)
        self.assertIsNot(plan, False, why)
        self.assertEqual(plan['count'], 3)
        self.assertEqual(plan['warn'], '改动超过 2 处，请复核')

    # ---- 3. apply touches only the default-state words
    def test_apply_patches_only_default_state(self):
        data, defaults = build(template_a(), events=(DEPLOY_DONE,))
        plan, why = self.recipe_of(data)
        self.assertIsNot(plan, False, why)
        out, why = self.apply_to(data, plan)
        self.assertIsNot(out, False, why)
        self.assertEqual(len(out), len(data))
        windows = {offset + k for offset in (defaults[0], defaults[1]) for k in range(4)}
        changed = {i for i in range(len(data)) if data[i] != out[i]}
        self.assertEqual(changed, {defaults[0], defaults[1]})
        self.assertLessEqual(changed, windows)
        after, why = self.parse(out)
        self.assertIsNot(after, False, why)
        self.assertEqual(after['layers'][1]['default'], 3)
        self.assertEqual(after['layers'][2]['default'], 1)
        self.assertEqual(after['layers'][1]['states'][4]['name'], DEPLOYED)
        self.assertEqual(items(after['events']), ['3D0B77D2'])
        # the same plan is now stale (its from-value no longer matches); refuse instead of writing
        again, why = self.apply_to(out, plan)
        self.assertIs(again, False)
        self.assertIn('不符', why)

    # ---- 4. malformed blobs come back as nil, why
    def test_bad_input_returns_nil(self):
        data, defaults = build(template_a(), events=(DEPLOY_DONE,))
        for name, blob in (('short', data[:59]), ('header only', data[:60]),
                           ('cut mid layer', data[:100]), ('empty', b'')):
            sm, why = self.parse(blob)
            self.assertIs(sm, False, name)
            self.assertTrue(why, name)
        for name, offset, value in (('groups_off', 8, 0xFFFFFFF0),        # past the end
                                    ('event count', 12, 0x10000000),      # 268M entries
                                    ('state count', defaults[0] - 4 + 8, 0x7FFFFFFF),
                                    ('state offset', defaults[0] - 4 + 12, 0x7FFFFFF0)):
            buf = bytearray(data)
            struct.pack_into('<I', buf, offset, value)
            sm, why = self.parse(bytes(buf))
            self.assertIs(sm, False, name)
            self.assertTrue(why, name)
        sm, why = self.parse(None)
        self.assertIs(sm, False)
        self.assertTrue(why)
        sm, why = self.parse(12345)
        self.assertIs(sm, False)
        self.assertTrue(why)
        plan, why = self.M.recipe(None)
        self.assertIsNone(plan)
        self.assertTrue(why)
        out, why = self.apply_to(data, None)
        self.assertIs(out, False)
        self.assertTrue(why)
        for label, poison in (('to beyond the layer', 99), ('to negative', -1), ('to fractional', 1.5)):
            plan, _ = self.recipe_of(data)
            plan['changes'][1]['to'] = poison
            out, why = self.apply_to(data, plan)
            self.assertIs(out, False, label)
            self.assertTrue(why, label)
        plan, _ = self.recipe_of(data)
        plan['changes'][1]['layer'] = 7                                  # no such layer
        out, why = self.apply_to(data, plan)
        self.assertIs(out, False)
        self.assertTrue(why)
        plan, _ = self.recipe_of(data)
        plan['changes'][1]['from'] = 3                                   # wrong current value
        out, why = self.apply_to(data, plan)
        self.assertIs(out, False)
        self.assertIn('不符', why)

    # ---- 5. a real AC-8 blob when one is around (never a hard failure)
    def test_real_ac8_blob_when_present(self):
        for candidate in REAL_BLOBS:
            if candidate.is_file():
                break
        else:
            self.skipTest('no real state_machine blob at ' + ', '.join(str(p) for p in REAL_BLOBS))
        data = candidate.read_bytes()
        sm, why = self.parse(data)
        self.assertIsNot(sm, False, str(candidate) + ': ' + why)
        first = sm['layers'][1]
        self.assertEqual(len(first['states']), 3)
        plan, why = self.recipe_of(data)
        self.assertIsNot(plan, False, why)
        self.assertIn(plan['template'], ('A', 'B'))
        self.assertGreaterEqual(plan['count'], 1)

    # ---- 6. preview is human-readable and keeps the arrow
    def test_preview_lines(self):
        data, _ = build(template_a(), events=(DEPLOY_DONE,))
        plan, why = self.recipe_of(data)
        self.assertIsNot(plan, False, why)
        lines = self.preview_of(data, plan)
        self.assertEqual(len(lines), 2)
        self.assertTrue(all('→' in line for line in lines), lines)
        self.assertIn('层0：1 → 3', lines[0])
        self.assertIn('部署完成态', lines[0])
        self.assertIn('Empty', lines[1])
        data, _ = build(template_a(layer0_default=3, layer1_default=1), events=(DEPLOY_DONE,))
        plan, why = self.recipe_of(data)
        lines = self.preview_of(data, plan)
        self.assertGreaterEqual(len(lines), 1)


if __name__ == '__main__':
    unittest.main()
