"""Verify extraction and damaged-cache recovery without starting the UI."""
import argparse
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    local = root / 'Local'
    temp = root / 'Temp'
    local.mkdir()
    temp.mkdir()
    env = os.environ | {'LOCALAPPDATA': str(local), 'TEMP': str(temp), 'TMP': str(temp)}

    def verify():
        result = subprocess.run([str(args.exe.resolve()), '--verify-package'],
                                env=env, capture_output=True, timeout=60)
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)

    verify()
    runtime = local / 'SHODAN/DesktopRuntime'
    cache, = [path for path in runtime.iterdir() if path.is_dir()]
    target = cache / 'manifest.json'
    expected = target.read_bytes()
    target.write_bytes(b'corrupted-cache-test')
    verify()
    assert target.read_bytes() == expected
    saved, = runtime.glob(cache.name + '.damaged-*')
    assert (saved / 'manifest.json').read_bytes() == b'corrupted-cache-test'
    verify()
    assert len(list(runtime.glob(cache.name + '.damaged-*'))) == 1
    print('Portable cache: verified extraction, damaged cache backup, rebuild and repeat verification passed; UI not started.')


if __name__ == '__main__':
    main()
