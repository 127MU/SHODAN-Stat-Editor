"""Build identities only; never copy current game values as vanilla defaults.

Input tables JSON is produced by shodan-native tables against the shipped
generated_entities.dl_plain. No game installation is modified.
"""
import gzip
import hashlib
import json
import math
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
plain = (ROOT / 'offline/originals/generated_entities.dl_plain').read_bytes()
assert hashlib.sha256(plain).hexdigest() == 'dc6d52a14900942b2f59f56bf8ab1552259832202dcb0745c3c84a009ff5f98b'
tables = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8-sig'))
assert not tables['problems']
tables = {t['type']: {r['key']: r for r in t['rows']} for t in tables['tables']}
catalog = json.loads(gzip.decompress((ROOT / 'rust/core/data/catalog.json.gz').read_bytes()))
result = {}
for owner in catalog['owners']:
    if owner['tab'] != 'Mechas':
        continue
    candidates = set()
    for row in owner['rows']:
        for part in row['parts']:
            for binding in catalog['fields'][part['field']]['bindings']:
                if binding.get('type') in ('5653EA91', '4AEAFC86', '3845B1E0'):
                    candidates.add(binding['record'])
    candidates.intersection_update(tables['EAEB2B0D'])
    if len(candidates) != 1:
        continue
    key = candidates.pop()
    offset = tables['EAEB2B0D'][key]['offset']
    wheels = []
    for i in range(32):
        start = offset + 8 + i * 64
        length = struct.unpack_from('<f', plain, start)[0]
        nodes = struct.unpack_from('<5I', plain, start + 16)
        # Empty slots have length=1 and no node bindings. Tracked vehicles
        # can have real suspension slots without named wheel nodes.
        if any(nodes) or (math.isfinite(length) and length > 0 and length != 1):
            wheels.append(i)
    result[owner['id']] = dict(entity=key[5:], wheels=wheels,
        components=[t for t in ('EAEB2B0D', '3845B1E0', '4AEAFC86', '83B65443', '20288698') if key in tables[t]])
(ROOT / 'rust/core/data/vehicle_inventory.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
print(f'Verified {len(result)} vehicle identities')
