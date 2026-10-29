"""Steam command wrapper integration with a dummy child, never the game."""
import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bridge', type=Path, required=True)
    args = parser.parse_args()
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)]*4
    c, e, k, u = (wintypes.FILETIME() for _ in range(4))
    assert kernel.GetProcessTimes(kernel.GetCurrentProcess(), ctypes.byref(c), ctypes.byref(e), ctypes.byref(k), ctypes.byref(u))
    started = (c.dwHighDateTime << 32) | c.dwLowDateTime
    with tempfile.TemporaryDirectory(prefix='steam-bridge-') as temporary:
        root = Path(temporary)/'带空格 测试目录'
        root.mkdir()
        bridge = root/'steam-bridge.exe'
        shutil.copy2(args.bridge, bridge)
        child = root/'child probe.py'
        child.write_text('import json,os,sys\nfrom pathlib import Path\nPath(sys.argv[1]).write_text(json.dumps({"args":sys.argv[2:],"proxy":os.environ.get("HTTPS_PROXY"),"lower":os.environ.get("https_proxy"),"no_proxy":os.environ.get("NO_PROXY"),"cwd":os.getcwd()}),encoding="utf8")\nsys.exit(7)\n', encoding='utf-8')
        expected = ['空 格', 'quote"value', 'a&b', '%command%', 'end'+chr(92)]
        config = root/'steam-proxy.ini'
        listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(2);port=listener.getsockname()[1]
        for case, value in [('disabled', None), ('active', started), ('stale', started+1)]:
            if value is not None:
                config.write_text('[proxy]\r\nport='+str(port)+'\r\npid='+str(os.getpid())+'\r\nstarted='+str(value)+'\r\n', encoding='ascii')
            out = root/(case+'.json')
            env = dict(os.environ, HTTPS_PROXY='http://existing.invalid:1234', https_proxy='http://existing.invalid:1234')
            env['NO_PROXY']='preserve.example'
            proc = subprocess.run([str(bridge), sys.executable, str(child), str(out), *expected], cwd=root,
                                  env=env, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
            assert proc.returncode == 7, (case, proc.returncode)
            result = json.loads(out.read_text('utf-8'))
            assert result['args'] == expected, result
            assert Path(result['cwd']) == root, result
            proxy = 'http://127.0.0.1:'+str(port) if case=='active' else 'http://existing.invalid:1234'
            assert result['proxy'] == result['lower'] == proxy, result
            bypass=result['no_proxy'].split(',')
            assert 'preserve.example' in bypass, result
            if case=='active':
                active_bypass=result['no_proxy']
                assert 'playfabapi.com' in bypass and '.playfab.com' in bypass, result
                assert 'api.live.prod.thehelldiversgame.com' not in bypass and '*' not in bypass, result
            else:assert result['no_proxy']=='preserve.example',result
        listener.close()
        # Exercise libcurl's actual exclusion matching against a loopback-only
        # endpoint. An unreachable explicit proxy distinguishes bypass from
        # proxy routing without sending account data or contacting the game.
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200);self.end_headers();self.wfile.write(b'local-route-ok')
            def log_message(self,*args):
                pass
        server=HTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            route_env=dict(os.environ,NO_PROXY=active_bypass,no_proxy=active_bypass)
            endpoint=server.server_port
            assert endpoint!=port,'Test ports collided; rerun with new ephemeral ports'
            for host,bypass in [('route-check.playfabapi.com',True),('route-check.playfab.com',True),('route-check.easyanticheat.net',True),('route-check.easyanticheat.com',True),('route-check.epicgames.com',True),('route-check.epicgames.dev',True),('api.live.prod.thehelldiversgame.com',False)]:
                request=subprocess.run(['curl.exe','--silent','--show-error','--max-time','3','--proxy','http://127.0.0.1:'+str(port),'--resolve',host+':'+str(endpoint)+':127.0.0.1','http://'+host+':'+str(endpoint)+'/'],env=route_env,capture_output=True,timeout=6)
                if bypass:assert request.returncode==0 and request.stdout==b'local-route-ok',(host,request.stderr)
                else:assert request.returncode!=0,'Game API was incorrectly excluded from the proxy'
        finally:
            server.shutdown();server.server_close();thread.join(timeout=2)
    print('PASS: Steam command quoting, Unicode paths, working directory, active/stale session, ordinary launch and child exit code; no game or Steam launched')


if __name__ == '__main__':
    main()
