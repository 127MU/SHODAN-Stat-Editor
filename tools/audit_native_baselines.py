"""Read every desktop parameter through the real Rust RPC and report missing defaults.

Uses a fresh isolated profile. Does not install, restore, or edit game files.
"""
import argparse
import collections
import gzip
import json
import os
import pathlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', type=pathlib.Path, required=True)
    parser.add_argument('--runtime', type=pathlib.Path, required=True)
    parser.add_argument('--game', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    catalog = json.loads(gzip.decompress((args.runtime / 'catalog.json.gz').read_bytes()))
    counts, missing, errors = collections.Counter(), [], []
    differences = []
    fields = catalog["fields"]
    with tempfile.TemporaryDirectory(prefix='shodan-audit-') as folder:
        process = subprocess.Popen([str(args.native.resolve()), '--stdio'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   text=True, encoding='utf8',
                                   env=os.environ | {'SHODAN_PROFILE': str(pathlib.Path(folder) / 'profile')})
        def call(method, **params):
            process.stdin.write(json.dumps(dict(method=method, params=params)) + '\n')
            process.stdin.flush()
            reply = json.loads(process.stdout.readline())
            if not reply['ok']:
                raise ValueError(reply['error'])
            return reply['result']
        try:
            call('game-open', runtime=str(args.runtime.resolve()), game=str(args.game.resolve()))
            for owner in catalog['owners']:
                try:
                    call('desktop-call', name='select', args=[owner['id']])
                    rows = call('desktop-call', name='rows_fast', args=[])
                    counts['owners'] += 1
                    for row in rows:
                        counts['rows'] += 1
                        if row.get('original') is None:
                            missing.append(dict(owner=owner['name'], owner_id=owner['id'],
                                                parameter=row['label'], key=row['id'],
                                                choice=row.get('choice_kind'), error=row.get('error')))
                        if row.get('baseline_state') == 'different':
                            source_row = next((r for r in owner['rows'] if r['key'] == row['id']), {})
                            differences.append(dict(owner=owner['name'], owner_id=owner['id'],
                                tab=owner['tab'], key=row['id'], parameter=row['label'],
                                current=row.get('value'), original=row.get('original'),
                                bindings=[b for part in source_row.get('parts', [])
                                          for b in fields[part['field']].get('bindings', [])]))
                        if row.get('error'):
                            errors.append(dict(owner=owner['name'], key=row['id'], error=row['error']))
                except ValueError as error:
                    errors.append(dict(owner=owner['name'], error=str(error)))
        finally:
            process.terminate()
            process.wait()
    counts.update(unknown=len(missing), errors=len(errors), different=len(differences))
    report = dict(counts=counts, unknown=missing, errors=errors, differences=differences,
                  differences_by_tab=dict(collections.Counter(d["tab"] for d in differences)))
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
    print(json.dumps(counts))


if __name__ == '__main__':
    main()
