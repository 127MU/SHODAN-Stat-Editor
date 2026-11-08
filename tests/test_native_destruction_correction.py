"""Regression for variable-sized destruction blocks during sealed export.

Writes only to a fresh test output directory, never to the game directory.
"""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    original = Path('offline/originals/generated_destruction_settings.dl_plain').read_bytes()
    blocks = []
    end = 0
    while end < len(original):
        start = original.find(b'LDLD\x01\0\0\0', end, end + 64)
        assert start >= 0
        size = int.from_bytes(original[start + 12:start + 16], 'little')
        end = start + 24 + size
        blocks.append((start, end))
    assert any(start % 4 for start, _ in blocks), blocks
    edited = bytearray(original)
    payload = next(start + 24 for start, end in blocks if end >= start + 28)
    edited[payload] ^= 1
    before = args.output / 'before.dl_plain'
    after = args.output / 'after.dl_plain'
    sealed = args.output / 'export.dl_bin'
    opened = args.output / 'opened.dl_plain'
    before.write_bytes(original)
    after.write_bytes(edited)

    def run(*argv):
        result = subprocess.run([str(args.exe.resolve()), *map(str, argv)],
                                capture_output=True, text=True, encoding='utf8',
                                timeout=125, check=True)
        return json.loads(result.stdout)

    report = run('prepare-copy', before, after, sealed)
    run('unseal-copy', sealed, opened)
    actual = opened.read_bytes()
    assert len(actual) == len(original)
    reserved = {i for start, _ in blocks for i in range(start + 17, start + 24)}
    assert all(a == b or i in reserved for i, (a, b) in enumerate(zip(actual, edited)))
    assert actual[payload] == edited[payload]
    assert before.read_bytes() == original
    print(json.dumps({'ok': True, 'blocks': len(blocks),
                      'unaligned_blocks': sum(start % 4 != 0 for start, _ in blocks),
                      'report': report}, ensure_ascii=False))


if __name__ == '__main__':
    main()
