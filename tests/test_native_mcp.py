"""Native loopback MCP auth, session sharing and lifecycle, no game writes."""
import http.client,json,pathlib,struct,subprocess,tempfile,urllib.parse
ROOT=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(dir=ROOT/'dist/build-temp-r19',prefix='native-mcp-') as folder:
    path=pathlib.Path(folder)/'fixture.plain'
    path.write_bytes(b'LDLD\x01\0\0\0'+struct.pack('<IIQ',1,32,0)+struct.pack('<QIIIfIf',0,2,0,5,1.3,9,-2.5))
    process=subprocess.Popen([str(ROOT/'target/release/shodan-native.exe'),'--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,encoding='utf8')
    def call(method,**params):
        process.stdin.write(json.dumps(dict(id=method,method=method,params=params))+'\n');process.stdin.flush()
        response=json.loads(process.stdout.readline());assert response['ok'],response
        return response['result']
    try:
        assert call('mcp-status')['enabled'] is False
        config=call('mcp-start')['config']['mcpServers']['shodan'];url=urllib.parse.urlparse(config['url'])
        assert config==call('mcp-config')['mcpServers']['shodan']
        def rpc(method,params=None,extra=None,authenticated=True):
            conn=http.client.HTTPConnection(url.hostname,url.port,timeout=10)
            headers={'Content-Type':'application/json'}
            if authenticated:headers.update(config['headers'])
            if extra:headers.update(extra)
            conn.request('POST','/mcp',json.dumps(dict(jsonrpc='2.0',id=1,method=method,params=params or {})),headers)
            response=conn.getresponse();status=response.status;body=response.read();conn.close()
            return status,json.loads(body) if body else None
        assert rpc('ping',authenticated=False)[0]==401
        assert rpc('ping',extra={'Origin':'https://example.com'})[0]==403
        assert rpc('ping')[0]==200
        assert rpc('initialize')[1]['result']['serverInfo']['name']=='SHODAN Native'
        assert rpc('tools/list')[1]['result']['tools'][0]['name']=='shodan_native_call'
        call('open',path=str(path));call('index',block=0,layout='rows',stride=8,id_offset=0)
        field=dict(block=0,record='id:9',relative=4,kind='f32')
        response=rpc('tools/call',dict(name='shodan_native_call',arguments=dict(method='set',params=dict(field,value=42))))[1]
        assert response['result']['isError'] is False,response
        assert call('get',**field)['value']==42
        call('undo');assert call('get',**field)['value']==-2.5
        assert rpc('tools/call',dict(name='shodan_native_call',arguments=dict(method='mcp-start',params={})))[1]['error']['code']==-32602
        call('mcp-stop');assert call('mcp-status')['enabled'] is False
        try:
            http.client.HTTPConnection(url.hostname,url.port,timeout=1).connect()
            raise AssertionError('listener remained open')
        except OSError:pass
    finally:
        process.stdin.close();assert process.wait(timeout=10)==0
print('Native MCP: loopback auth, browser-origin rejection, config, shared edits/undo and stop passed; game writes 0')
