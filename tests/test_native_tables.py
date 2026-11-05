"""Independent stored-table indexing oracle for the local data fixtures."""
import argparse
import json
import re
import struct
import subprocess
from pathlib import Path
from test_native_data import expected


def reference(payload, base, layout, type_id):
    stride = int(re.search(r'stride: (\d+)', layout)[1])
    rows = {}
    if layout.startswith('Rows'):
        count, zero = struct.unpack_from('<II', payload, 8)
        assert zero == 0 and 16+count*stride <= len(payload)
        for k in range(count):
            at = 16+k*stride
            id_offset = int(re.search(r'id_offset: (\d+)', layout)[1])
            key = 'id:'+str(struct.unpack_from('<I', payload, at+id_offset)[0])
            rows.setdefault(key, {'key': key, 'offset': base+at, 'bytes': stride})
    elif type_id == '4F2CF417':
        live, fits = [], []
        for slot_index, (key, slot, pad) in enumerate(struct.iter_unpack('<QII', payload[:len(payload)//16*16])):
            if pad or slot > 100000:
                break
            if key:
                live.append((slot_index, key, slot))
            count = slot_index + 1
            if count < 64 or count != 2 * len(live):
                continue
            records = (len(payload) - count * 16) // stride
            if all((index - key % count) % count < 16 and slot < records for index, key, slot in live):
                fits.append((count, list(live)))
        assert len(fits) == 1
        buckets, entries = fits[0]
        for _, key, slot in entries:
            name = f'hash:{key:016X}'
            rows.setdefault(name, {'key': name, 'offset': base+buckets*16+slot*stride, 'bytes': stride})
    else:
        # Try every feasible bucket count using size, slot range and occupancy.
        candidates, twice = [], []
        live, top = 0, 0
        slack = int(re.search(r'slack: (\d+)', layout)[1])
        for offset in range(0, len(payload)-15, 16):
            key, slot, pad = struct.unpack_from('<QII', payload, offset)
            if pad:
                break
            count = offset//16+1
            if key:
                live += 1
                top = max(top, slot)
            array = len(payload)-count*16-slack
            if count <= 2*live and array > 0 and array % stride == 0:
                records = array//stride
                if records > top and records <= live+2:
                    candidates.append(count)
                    if count == 2*live:
                        twice.append(count)
        def placed(n):
            for k in range(n):
                key = struct.unpack_from('<Q', payload, k*16)[0]
                if key:
                    at = key % n
                    while at != k:
                        if struct.unpack_from('<Q', payload, at*16)[0] == 0:
                            return False
                        at = (at+1) % n
            return True
        fits = [n for n in candidates if placed(n)]
        if len(fits) != 1:
            fits = twice
        assert len(fits) == 1
        buckets = fits[0]
        for k in range(buckets):
            key, slot = struct.unpack_from('<QI', payload, k*16)
            if key:
                name = f'hash:{key:016X}'
                rows.setdefault(name, {'key': name, 'offset': base+buckets*16+slot*stride, 'bytes': stride})
    return rows


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--originals', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    reports = []
    for file in sorted(a.originals.glob('*.dl_plain')):
        data = file.read_bytes()
        blocks = {b['offset']: b for b in expected(data)}
        result = json.loads(subprocess.check_output([str(a.exe.resolve()), 'tables', str(file.resolve())], encoding='utf8'))
        assert not result['problems'], (file.name, result['problems'])
        for table in result['tables']:
            expected_id = {'30EB6399': 4, '1E604234': 8}.get(table['type'], 0)
            if table['layout'].startswith('Rows'):
                assert int(re.search(r'id_offset: (\d+)', table['layout'])[1]) == expected_id
            b = blocks[table['offset']]
            base = b['payload_offset']
            payload = data[base:base+b['payload_bytes']]
            rows = reference(payload, base, table['layout'], table['type'])
            assert rows == {r['key']: r for r in table['rows']}, (file.name, table['type'])
            reports.append({'file': file.name, 'type': table['type'], 'rows': len(rows), 'layout': table['layout']})
    assert reports
    a.output.parent.mkdir(parents=True, exist_ok=True)
    summary = {'tables': reports, 'total_tables': len(reports), 'total_rows': sum(t['rows'] for t in reports), 'game_writes': 0}
    a.output.write_text(json.dumps(summary, indent=2), encoding='utf8')
    print(json.dumps({'tables': len(reports), 'rows': summary['total_rows'], 'offset_and_id_parity': True, 'game_writes': 0}))


if __name__ == '__main__':
    main()
