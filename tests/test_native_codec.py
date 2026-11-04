"""Independent libsodium interoperability oracle; the Rust executable loads no DLL.

Only temporary test exports are written. No game installation is read or changed.
"""
import argparse
import ctypes
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path


def murmur(data):
    mask = (1 << 64) - 1
    mul = 0xC6A4A7935BD1E995
    h = 16045690983977655786 ^ (len(data) * mul & mask)
    whole = len(data) // 8 * 8
    for at in range(0, whole, 8):
        k = int.from_bytes(data[at:at+8], 'little') * mul & mask
        k ^= k >> 47
        h = (h ^ (k * mul & mask)) * mul & mask
    if whole != len(data):
        h = (h ^ int.from_bytes(data[whole:], 'little')) * mul & mask
    h ^= h >> 47
    h = h * mul & mask
    return f'{h ^ (h >> 47):016x}'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--originals', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    root = Path(__file__).resolve().parents[1]
    a.output.mkdir(parents=True, exist_ok=False)
    isolated = (a.output/'isolated').resolve()
    isolated.mkdir()
    exe = isolated/'shodan-native.exe'
    shutil.copy2(a.exe, exe)
    # Reference implementation is loaded in this Python test process only.
    lib = ctypes.CDLL(str(root/'offline/runtime/libsodium.dll'))
    assert lib.sodium_init() >= 0
    lib.crypto_box_seal.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_void_p]
    lib.crypto_box_seal_open.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_void_p, ctypes.c_void_p]
    source = (root/'offline/gamedata.lua').read_text(encoding='utf8')
    pk = bytes.fromhex(re.search(r"local PK = unhex\('([0-9a-f]+)'\)", source)[1])
    sk = bytes.fromhex(re.search(r"local SK = unhex\('([0-9a-f]+)'\)", source)[1])
    def call(command, *paths, ok=True):
        result = subprocess.run([str(exe), command, *[str(x.resolve()) for x in paths]],
                                cwd=isolated, capture_output=True, text=True, encoding='utf8', timeout=120)
        assert (result.returncode == 0) == ok, result.stderr
        return json.loads(result.stdout) if ok else result.stderr
    results = []
    fixtures = sorted(a.originals.glob('*.dl_plain'))
    assert fixtures
    for path in fixtures:
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        oracle = ctypes.create_string_buffer(len(data)+48)
        assert lib.crypto_box_seal(oracle, data, len(data), pk) == 0
        sealed = a.output/(path.stem+'.sodium')
        sealed.write_bytes(oracle.raw)
        report = call('inspect-sealed', sealed)
        assert report['sha256'] == digest and report['murmur64'] == murmur(data)
        rust = a.output/(path.stem+'.rust')
        encoded = call('seal-copy', path, rust)
        assert encoded['sha256'] == digest
        cipher = rust.read_bytes()
        plain = ctypes.create_string_buffer(len(data))
        assert lib.crypto_box_seal_open(plain, cipher, len(cipher), pk, sk) == 0
        assert plain.raw == data
        recovered = a.output/(path.stem+'.decoded')
        call('unseal-copy', sealed, recovered)
        assert recovered.read_bytes() == data
        assert path.read_bytes() == data
        call('seal-copy', path, rust, ok=False)
        assert rust.read_bytes() == cipher, 'Export overwrote an existing file'
        results.append({'file': path.name, 'bytes': len(data), 'sha256': digest,
                        'cross_open': True, 'cross_seal': True})
    damaged = a.output/'damaged.sealed'
    bad = bytearray(sealed.read_bytes()); bad[-1] ^= 1; damaged.write_bytes(bad)
    rejected = a.output/'must-not-exist.plain'
    call('unseal-copy', damaged, rejected, ok=False)
    assert not rejected.exists()
    report = {'files': results, 'game_writes': 0, 'native_runtime_lua': False,
              'native_runtime_sodium_dll': False, 'corruption_rejected_before_export': True}
    (a.output/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf8')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
