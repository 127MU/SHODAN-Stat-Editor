"""Import missing defaults only from files matching a pinned Steam depot manifest.

Developer tool: does not change the Steam installation or use its current values
as defaults without checking the depot's exact content SHA-1 first. The resulting
plaintext SHA-256 values must also be pinned in baseline.rs before distribution.
"""
import argparse
import hashlib
import json
import pathlib
import struct
import subprocess
import tempfile


def fields(data):
    def integer(at):
        result = 0
        for shift in range(0, 70, 7):
            if at >= len(data):
                raise ValueError('Truncated manifest integer')
            byte = data[at]
            at += 1
            result |= (byte & 127) << shift
            if byte < 128:
                return result, at
        raise ValueError('Manifest integer too long')

    at = 0
    while at < len(data):
        tag, at = integer(at)
        wire = tag & 7
        if wire == 0:
            value, at = integer(at)
        else:
            if wire == 2:
                size, at = integer(at)
            elif wire in (1, 5):
                size = 8 if wire == 1 else 4
            else:
                raise ValueError('Unsupported manifest wire type')
            if at + size > len(data):
                raise ValueError('Truncated manifest field')
            value = data[at:at + size]
            at += size
        yield tag >> 3, value


def mappings(data):
    magic, size = struct.unpack_from('<II', data)
    if magic != 0x71F617D0 or size > len(data) - 8:
        raise ValueError('Invalid Steam manifest payload')
    result = {}
    for key, raw in fields(data[8:8 + size]):
        if key != 1:
            continue
        row = dict(fields(raw))
        name = row[1].decode('utf8').replace('\\', '/')
        if len(row.get(5, b'')) == 20:
            result[name] = (row[2], row[5].hex())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=pathlib.Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--native', type=pathlib.Path, required=True)
    parser.add_argument('--game', type=pathlib.Path, required=True)
    parser.add_argument('--backup', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    data = args.manifest.read_bytes()
    if hashlib.sha256(data).hexdigest() != args.manifest_sha256:
        raise ValueError('Steam manifest fingerprint mismatch')
    entries = mappings(data)
    names = ['customization_armor_sets', 'entity_deltas', 'status_effect_settings',
             'destruction_settings', 'beam_settings', 'stratagem_settings',
             'entities', 'damage_settings', 'projectile_settings', 'arc_settings',
             'explosion_settings', 'customization_passive_bonuses']
    inputs, evidence = [], {}
    for stem in names:
        name = f'generated_{stem}.dl_bin'
        size, expected = entries['data/game/' + name]
        source = None
        for candidate in (args.game / name, args.backup / name):
            if candidate.is_file():
                raw = candidate.read_bytes()
                if len(raw) == size and hashlib.sha1(raw).hexdigest() == expected:
                    source = candidate
                    break
        if source is None:
            raise ValueError(f'No depot-matching original for {name}')
        inputs.append(dict(name=name, path=str(source.resolve()), sealed=True))
        evidence[name] = dict(sealed_sha1=expected, bytes=size)
    with tempfile.TemporaryDirectory(prefix='shodan-baseline-') as folder:
        output = pathlib.Path(folder) / 'plain'
        process = subprocess.Popen([str(args.native.resolve()), '--stdio'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   text=True, encoding='utf8')
        try:
            def call(method, **params):
                process.stdin.write(json.dumps(dict(method=method, params=params)) + '\n')
                process.stdin.flush()
                response = json.loads(process.stdout.readline())
                if not response['ok']:
                    raise ValueError(response['error'])
            call('workspace-open', files=inputs)
            call('workspace-export-copy', output=str(output))
        finally:
            process.terminate()
            process.wait()
        args.output.mkdir(parents=True, exist_ok=True)
        for name, record in evidence.items():
            plain_name = name.replace('.dl_bin', '.dl_plain')
            raw = (output / plain_name).read_bytes()
            record['plain_sha256'] = hashlib.sha256(raw).hexdigest()
            destination = args.output / plain_name
            if destination.exists() and destination.read_bytes() != raw:
                raise ValueError('Refusing to replace a different baseline')
            destination.write_bytes(raw)
    report = dict(depot_manifest=args.manifest.name,
                  manifest_sha256=args.manifest_sha256, files=evidence)
    (args.output / 'depot-baseline-evidence.json').write_text(
        json.dumps(report, indent=2) + '\n', encoding='utf8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
