"""Public API probe only; no game, trust-store or system-proxy changes."""
import argparse
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import time


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--runtime', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--upstream', default='')
    a = p.parse_args()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    mode = ('upstream:' + a.upstream if a.upstream else 'regular') + '@127.0.0.1:' + str(port)
    plan = out / 'plan.json'
    plan.write_text(json.dumps({'schema': 2, 'targets': [], 'health_path': str(out/'health.json')}), encoding='utf-8')
    addon = Path(__file__).resolve().parents[1]/'offline/war_status_addon.py'
    args = [str(a.runtime/'python.exe'), '-I', str(a.runtime/'proxy_main.py'), '--mode', mode,
            '--allow-hosts', r'^api\.live\.prod\.thehelldiversgame\.com(:443)?$',
            '--set', 'confdir='+str(out/'ca'), '--set', 'flow_detail=0', '-s', str(addon)]
    result = {'game_started': False, 'trust_changes': False, 'system_settings_changed': False}
    with (out/'core.log').open('wb') as log:
        proc = subprocess.Popen(args, env=dict(os.environ, SHODAN_WAR_PLAN=str(plan)), stdout=log, stderr=log)
        try:
            for _ in range(150):
                if proc.poll() is not None:
                    raise RuntimeError('proxy exited before ready')
                try:
                    if json.loads((out/'health.json').read_text('utf-8')).get('ready'):
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(.2)
            else:
                raise RuntimeError('proxy startup timed out')
            host = 'api.live.prod.thehelldiversgame.com'
            with socket.create_connection(('127.0.0.1', port), timeout=20) as raw:
                raw.sendall(('CONNECT '+host+':443 HTTP/1.1\r\nHost: '+host+':443\r\n\r\n').encode())
                response = b''
                while not response.endswith(b'\r\n\r\n'):
                    response += raw.recv(1)
                context = ssl.create_default_context(cafile=str(out/'ca/mitmproxy-ca-cert.pem'))
                with context.wrap_socket(raw, server_hostname=host) as secure:
                    (out/'peer.cer').write_bytes(secure.getpeercert(binary_form=True))
                    result['verified_tls'] = True
            for path in ['/api/WarSeason/current/WarId', '/api/WarSeason/GalacticWarEffects']:
                check = subprocess.run(['curl.exe', '--silent', '--show-error', '--max-time', '25',
                    '--proxy', 'http://127.0.0.1:'+str(port), '--cacert', str(out/'ca/mitmproxy-ca-cert.pem'),
                    '--output', os.devnull, '--write-out', '%{http_code}',
                    'https://api.live.prod.thehelldiversgame.com'+path], capture_output=True, text=True)
                result[path] = {'exit': check.returncode, 'http': check.stdout, 'error': check.stderr}
        finally:
            (out/'stop.request').write_text('stop')
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            result['exit'] = proc.returncode
            if (out/'health.json').exists():
                result['health'] = json.loads((out/'health.json').read_text('utf-8'))
            (out/'report.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
