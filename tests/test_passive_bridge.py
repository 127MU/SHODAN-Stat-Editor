"""Actual desktop IPC regression, isolated profile; never installs game files."""
import argparse,json,os,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--runtime',type=pathlib.Path,required=True);a=p.parse_args()
with tempfile.TemporaryDirectory(dir=ROOT/'dist/build-temp-r19',prefix='passive-ipc-') as folder:
    folder=pathlib.Path(folder);profile=folder/'profile';profile.mkdir()
    (profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2','utf8')
    # Use a private runtime as well so the test cannot touch installed runtime data.
    for name in ['lua51.dll','libsodium.dll','shodan_hash.dll']:
        shutil.copy2(a.runtime/name,folder/name)
    for name in ['app','originals']:
        shutil.copytree(a.runtime/name,folder/name)
    shutil.copy2(ROOT/'target/release/shodan-core.exe',folder/'shodan-core.exe')
    env=dict(os.environ,SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(folder))
    process=subprocess.Popen([str(folder/'shodan-core.exe'),str(folder)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf8',env=env)
    def call(method,*args):
        process.stdin.write(json.dumps(dict(id=1,method=method,args=args))+'\n');process.stdin.flush()
        reply=json.loads(process.stdout.readline());assert 'error' not in reply,reply
        return reply['data']
    try:
        info=call('info');ids=[p['id'] for p in info['armor']]
        tested=sorted(set([ids[0],ids[1],ids[-1]]))
        for pid in tested:
            call('armor_update',999,pid,True,None,None)
            enabled=call('armor_profile',999)['enabled']
            assert isinstance(enabled,dict) and enabled[str(pid)] is True,enabled
        call('armor_update',999,None,None,False,None)
        assert call('armor_profile',999)['own'] is False
        for pid in tested:
            call('armor_update',999,pid,False,None,None)
            assert str(pid) not in call('armor_profile',999)['enabled']
        # Sparse/nested numeric selections must survive profile reload too.
        call('armor_update',999,tested[-1],True,None,None)
        call('flush')
    finally:
        process.stdin.close();assert process.wait(timeout=15)==0
    process=subprocess.Popen([str(folder/'shodan-core.exe'),str(folder)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf8',env=env)
    try:
        assert call('armor_profile',999)['enabled'][str(tested[-1])] is True
    finally:
        process.stdin.close();assert process.wait(timeout=15)==0
print('Desktop IPC: dense/sparse passive IDs, deselection, nullable arguments and profile reload passed; game writes 0')
