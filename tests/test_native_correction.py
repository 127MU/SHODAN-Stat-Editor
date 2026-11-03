"""End-to-end Rust correction + sealing on copies of the six local fixtures.

The chosen payload word is a binary-format test edit, not a gameplay assertion.
"""
import argparse
import hashlib
import json
import struct
import subprocess
import time
from pathlib import Path
from test_native_data import expected
from test_native_codec import murmur


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--originals', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    exe = a.exe.resolve()
    results = []
    for source in sorted(a.originals.glob('*.dl_plain')):
        original = source.read_bytes()
        blocks = expected(original)
        offset = None
        for block in blocks:
            start = block['payload_offset']
            end = start + block['payload_bytes']
            for at in range((start+7)//4*4, end-3, 4):
                if original[at:at+4] == struct.pack('<f', 1.0):
                    offset = at
                    break
            if offset is not None:
                break
        assert offset is not None, source.name
        modified = bytearray(original)
        modified[offset:offset+4] = struct.pack('<f', 1.5)
        edit = a.output/(source.stem+'.edited')
        edit.write_bytes(modified)
        output = a.output/(source.stem+'.sealed')
        args = [str(exe), 'prepare-copy', str(source.resolve()), str(edit.resolve()), str(output.resolve())]
        # Single-block files have only 56 spare header bits. Payload borrowing
        # must be explicitly opted into and must target our actual test edit.
        if len(blocks) == 1:
            args.append(str(offset))
        start = time.perf_counter()
        run = subprocess.run(args, capture_output=True, text=True, encoding='utf8', timeout=125)
        assert run.returncode == 0, f'{source.name}: {run.stderr}'
        report = json.loads(run.stdout)
        plain = a.output/(source.stem+'.verified')
        subprocess.run([str(exe), 'unseal-copy', str(output.resolve()), str(plain.resolve())],
                       capture_output=True, text=True, encoding='utf8', check=True)
        verified = plain.read_bytes()
        assert len(verified) == len(original)
        assert murmur(verified) == murmur(original) == report['target_hash']
        assert hashlib.sha256(verified).hexdigest() == report['plaintext_sha256']
        adjusted = report['adjusted_float']
        if len(blocks) > 1:
            assert adjusted is None, 'Header-only correction altered payload'
        elif adjusted:
            assert adjusted['offset'] == offset
            asked_bits = int.from_bytes(modified[offset:offset+4], 'little')
            actual_bits = int.from_bytes(verified[offset:offset+4], 'little')
            assert asked_bits ^ actual_bits <= 4095
        for at, (before, after) in enumerate(zip(modified, verified)):
            if before != after:
                assert any(b['offset']+17 <= at < b['offset']+24 for b in blocks) or (
                    adjusted and offset <= at < offset+4), (source.name, at)
        assert source.read_bytes() == original
        assert edit.read_bytes() == modified
        results.append({'file': source.name, 'bytes': len(original), 'target_hash': report['target_hash'],
                        'seconds': round(time.perf_counter()-start, 3), 'adjusted_float': adjusted})
        print(json.dumps(results[-1]), flush=True)
    (a.output/'report.json').write_text(json.dumps({'files': results, 'game_writes': 0}, indent=2), encoding='utf8')


if __name__ == '__main__':
    main()
