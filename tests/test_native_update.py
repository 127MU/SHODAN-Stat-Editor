"""Release metadata and nonblocking update jobs; offline by default."""
import json,pathlib,subprocess,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
process=subprocess.Popen([str(ROOT/'target/release/shodan-native.exe'),'--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,encoding='utf8')
def call(method,**params):
    process.stdin.write(json.dumps(dict(id=1,method=method,params=params))+'\n');process.stdin.flush()
    return json.loads(process.stdout.readline())
try:
    release=dict(tag_name='v4.6.0-r2',html_url='https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/v4.6.0-r2',body='修复被动勾选\n资源定位优化',assets=[dict(name='SHODAN_4.6.0-r2.exe',browser_download_url='https://github.com/127MU/SHODAN-Stat-Editor/releases/download/v4.6.0-r2/SHODAN_4.6.0-r2.exe')])
    response=call('update-parse',json=json.dumps(release,ensure_ascii=False),current='4.6.0-r1')
    assert response['ok'] and response['result']['newer'] and response['result']['notes']==release['body'],response
    assert response['result']['download_url']==release['assets'][0]['browser_download_url']
    start=time.monotonic();assert call('update-start',current='invalid')['ok']
    assert call('info')['result']['lua'] is False
    assert time.monotonic()-start<2
    for _ in range(30):
        response=call('update-poll')
        if not response['ok']:break
        time.sleep(.02)
    assert not response['ok'] and '版本号无效' in response['error'],response
    assert call('update-poll')['result']==dict(pending=False,idle=True)
finally:
    process.stdin.close();assert process.wait(timeout=10)==0
print('Native updates: Chinese notes, revision versions, repository-bound downloads and asynchronous error recovery passed')
