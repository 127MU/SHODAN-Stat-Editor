"""Exercise the packaged editor through authenticated MCP, using an isolated profile.
No Install/Restore calls and no game writes. Supply --exe and --output.
"""
import argparse, json, os, pathlib, subprocess, time, urllib.request, urllib.error

def main():
    p=argparse.ArgumentParser();p.add_argument('--exe',required=True,type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path)
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
    retired=(profile/'Mods/farm_pods.zip').as_posix()
    (profile/'mods-v2.txt').write_text('1 '+json.dumps(retired)+' "retired builtin" "removed" 2 1 1\n',encoding='utf8')
    (profile/'preset_01.txt').write_text('name Legacy compatibility\n968211C0033DCE64 damage 180\n968211C0033DCE64 f018 3\n',encoding='utf8')
    env=os.environ.copy();env.update(SHODAN_PROFILE=str(profile),SHODAN_EUI_QA=str(out),SHODAN_QA_OUTPUT=str(out),SHODAN_MCP_QA='1')
    proc=subprocess.Popen([str(a.exe.resolve())],env=env,cwd=a.exe.resolve().parent)
    count=0
    try:
        deadline=time.monotonic()+70
        while not (out/'mcp-ready.json').exists():
            if proc.poll() is not None:raise AssertionError('Editor exited before MCP readiness: '+((out/'failure.txt').read_text() if (out/'failure.txt').exists() else str(proc.returncode)))
            if time.monotonic()>deadline:raise TimeoutError('MCP readiness timed out')
            time.sleep(.1)
        info=json.loads((out/'mcp-ready.json').read_text(encoding='utf8'))
        def http(data=None,auth=True,origin=None,method='POST'):
            headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream'}
            if auth:headers['Authorization']='Bearer '+info['token']
            if origin:headers['Origin']=origin
            request=urllib.request.Request(info['url'],None if data is None else json.dumps(data).encode(),headers,method=method)
            try:
                with urllib.request.urlopen(request,timeout=30) as r:return r.status,r.read()
            except urllib.error.HTTPError as e:return e.code,e.read()
        def rpc(method,params=None):
            nonlocal count;count+=1
            status,data=http({'jsonrpc':'2.0','id':count,'method':method,'params':params or {}})
            assert status==200,(status,data)
            result=json.loads(data);assert 'error' not in result,result
            return result['result']
        def call(name,arguments=None,error=False):
            result=rpc('tools/call',{'name':name,'arguments':arguments or {}})
            assert result['isError']==error,result
            return json.loads(result['content'][0]['text'])
        assert http({},auth=False)[0]==401
        assert http({},origin='https://untrusted.example')[0]==403
        assert http(method='GET')[0]==405
        assert http({'jsonrpc':'2.0','method':'notifications/initialized'})[0]==202
        assert rpc('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'QA','version':'1'}})['capabilities']['tools']
        rpc('ping')
        tools=rpc('tools/list')['tools'];names={t['name'] for t in tools}
        interfaces=call('shodan_debug_interfaces')
        assert all('shodan_'+i['name'] in names for i in interfaces if i['type']=='function')
        assert {'shodan_install','shodan_restore','shodan_mods_export','shodan_armor_update','shodan_debug_read_log'}<=names
        players=call('shodan_items',{'args':['Helldiver','']});assert len(players)==1
        call('shodan_select',{'args':[players[0]['id']]})
        rows=call('shodan_rows');health=next(r for r in rows if r['label']=='生命值');assert health['value']==health['original']>0
        call('shodan_set',{'args':[health['id'],health['original']+1]})
        assert next(r for r in call('shodan_rows') if r['id']==health['id'])['value']==health['original']+1
        call('shodan_reset',{'args':[health['id']]})
        assert next(r for r in call('shodan_rows') if r['id']==health['id'])['value']==health['original']
        primary=call('shodan_items',{'args':['Primary','']});call('shodan_select',{'args':[primary[0]['id']]})
        swaps=[r for r in call('shodan_rows') if r['choice'] and not r['choice_kind']]
        assert swaps,'Projectile swap row missing'
        swap=swaps[0];choices=call('shodan_choices',{'args':[swap['id']]})
        chosen=next(c for c in choices if c['id']!=swap['value'])
        call('shodan_choose',{'args':[swap['id'],chosen['id']]})
        assert next(r for r in call('shodan_rows') if r['id']==swap['id'])['value']==chosen['id']
        call('shodan_reset',{'args':[swap['id']]})
        call('shodan_select',{'args':[players[0]['id']]})
        call('shodan_preset',{'args':['save',5]});call('shodan_preset_export',{'args':['weapon',5]});call('shodan_preset',{'args':['clear',5]})
        call('shodan_set',{'args':[999999,1]},error=True)
        call('shodan_mods_list',error=True) # hidden feature is not silently unlocked by MCP
        call('shodan_debug_property',{'name':'game'})
        call('shodan_debug_property',{'name':'not_an_interface'},error=True)
        diagnostic=call('shodan_debug_runtime');assert diagnostic['lua_stack']==0
        call('shodan_debug_self_test');call('shodan_debug_logs');call('shodan_debug_log_files')
        call('shodan_debug_read_log',{'name':'../gamefolder.txt'},error=True)
        preview=call('shodan_install_preview')
        assert not any('清理' in name or '.patch_' in name for name in preview['files'])
        call('shodan_unknown',error=True)
        call('shodan_flush')
        (out/'mcp-done.txt').write_text('done')
        assert proc.wait(timeout=15)==0
        assert (out/'report.txt').exists() and not (out/'failure.txt').exists()
        try:urllib.request.urlopen(info['url'],timeout=1);raise AssertionError('Endpoint still listening after disable')
        except urllib.error.URLError:pass
        report={'rpc_calls':count,'tools':len(tools),'all_backend_functions_exposed':True,'health_edit_reset':True,'auth_origin_checks':True,'game_writes':0}
        (out/'mcp-report.json').write_text(json.dumps(report,indent=2),encoding='utf8');print(json.dumps(report))
    finally:
        if proc.poll() is None:
            (out/'mcp-done.txt').write_text('stop QA')
            try:proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                proc.wait(timeout=10)
        (out/'mcp-ready.json').unlink(missing_ok=True) # ephemeral token is not part of QA artifacts

if __name__=='__main__':main()
