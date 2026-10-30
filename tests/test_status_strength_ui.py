"""Native four-slot status editing; uses an isolated profile and never installs."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--exe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=('status', 'squad'), default='status')
    args = parser.parse_args()
    out = args.output.resolve()
    profile = out / 'profile'
    profile.mkdir(parents=True, exist_ok=False)
    setting = 'qaSquadTransportOnly' if args.mode == 'squad' else 'qaStatusStrengthOnly'
    (profile / 'huskar-ui.ini').write_text('[General]\n' + setting + '=true\n', encoding='utf8')
    env = dict(os.environ, SHODAN_PROFILE=str(profile), SHODAN_QA_OUTPUT=str(out),
               SHODAN_HUSKAR_QA=str(out), TEMP=str(out), TMP=str(out))
    exe = args.exe.resolve()
    proc = subprocess.Popen([str(exe)], cwd=exe.parent, env=env)
    try:
        code = proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        proc.terminate()
        proc.wait(timeout=10)
        raise
    result = json.loads((out / 'report.json').read_text('utf8'))
    assert code == 0 and not result['error'], (code, result)
    assert len(list(out.glob(args.mode + '-*.png'))) == 2
    log = (profile / 'Logs/huskar-startup.log').read_text('utf8', errors='replace')
    errors = [line for line in log.splitlines() if any(token in line for token in
              ('ReferenceError:', 'TypeError:', 'Binding loop', 'Unable to assign'))]
    assert not errors, errors
    print(json.dumps({'mode': args.mode, 'fields_visible': True, 'edit_saved': True, 'game_writes': 0}))


if __name__ == '__main__':
    main()
