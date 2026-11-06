"""Build portable Windows artifacts with a Flutter UI and a Rust data engine."""
import argparse
import gzip
import hashlib
import json
import pathlib
import shutil
import struct
import tomllib
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
DATA = ROOT / 'rust/core/data/catalog.json.gz'
SIZE_LIMIT = 20_000_000


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--catalog', type=pathlib.Path, default=DATA)
    args = parser.parse_args()
    output = args.output
    archive = output.with_name(output.name + '.zip')
    single = output.with_name(output.name + '_单文件.exe')
    if any(path.exists() for path in (output, archive, single)):
        parser.error('Use a fresh output directory')
    ui = ROOT / 'desktop/morrow/build/windows/x64/runner/Release'
    native = ROOT / 'target/release/shodan-native.exe'
    launcher = ROOT / 'target/release/shodan-portable.exe'
    for path in (ui / 'shodan_desktop.exe', native, launcher, args.catalog):
        if not path.is_file():
            parser.error(f'Build the Release target and supply a native catalog: {path.name}')
    catalog = json.loads(gzip.decompress(args.catalog.read_bytes()))
    if catalog.get('format') != 'SHODAN-NATIVE-DESCRIPTORS' or not catalog.get('game_build'):
        parser.error('The native catalog is missing its build fingerprint')

    shutil.copytree(ui, output, ignore=shutil.ignore_patterns('*.pdb', '*.lib', '*.exp', '*.ilk'))
    from verify_material_icons import verify_material_icons
    verify_material_icons(ROOT, output)
    (output / 'shodan_desktop.exe').rename(output / 'SHODAN 数值编辑器.exe')
    shutil.copy2(native, output / native.name)
    shutil.copy2(args.catalog, output / 'catalog.json.gz')
    shutil.copytree(ROOT / 'offline/originals', output / 'originals')
    (output / 'licenses').mkdir()
    for name in ('MORROW-LICENSE', 'NOTICE.md', 'assets/fonts/MiSans-font-notice.txt'):
        shutil.copy2(ROOT / 'desktop/morrow' / name, output / 'licenses')
    shutil.copy2(ROOT / 'LICENSE', output)
    paths = sorted(path for path in output.rglob('*') if path.is_file())
    legacy = {'lua51.dll', 'luajit.dll', 'libsodium.dll', 'shodan_hash.dll'}
    if any(path.suffix.lower() == '.lua' or path.name.lower() in legacy for path in paths):
        raise SystemExit('The desktop output contains legacy runtime files')
    checksums = {path.relative_to(output).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in paths}
    version = tomllib.loads((ROOT / 'rust/core/Cargo.toml').read_text(encoding='utf8'))['package']['version']
    manifest = {'version': version, 'ui': 'Morrow / Flutter', 'core': 'Rust',
                'game_build': catalog['game_build'], 'files': checksums}
    manifest_path = output / 'manifest.json'
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf8')
    paths.append(manifest_path)
    with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path in paths:
            z.write(path, output.name + '/' + path.relative_to(output).as_posix())

    # The Rust launcher verifies a compact directory and inflates each file
    # directly. Flutter assets remain byte-identical to the ZIP distribution.
    rows = []
    payload = bytearray()
    for path in paths:
        raw = path.read_bytes()
        packed = gzip.compress(raw, compresslevel=9, mtime=0)
        rows.append({'path': path.relative_to(output).as_posix(), 'size': len(raw),
                     'packed': len(packed), 'sha256': hashlib.sha256(raw).hexdigest()})
        payload.extend(packed)
    directory = json.dumps(rows, ensure_ascii=False, separators=(',', ':')).encode()
    payload.extend(directory)
    with single.open('xb') as target:
        target.write(launcher.read_bytes())
        target.write(payload)
        target.write(hashlib.sha256(payload).digest())
        target.write(struct.pack('<QQ16s', len(payload), len(directory), b'SHODAN-PORTABLE!'))
    sizes = {'zip_bytes': archive.stat().st_size, 'exe_bytes': single.stat().st_size}
    # Windows CI may redirect stdout through a code page without CJK characters.
    print(json.dumps({'archive': str(archive), 'exe': str(single), **sizes}))
    if max(sizes.values()) >= SIZE_LIMIT:
        raise SystemExit('Package exceeds the 20 MB limit')


if __name__ == '__main__':
    main()
