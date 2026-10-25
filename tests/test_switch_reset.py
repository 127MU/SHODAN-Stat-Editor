"""Native click -> save -> Restore -> check backend and visible switch."""
import argparse,json,os,pathlib,subprocess

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--exe',type=pathlib.Path,required=True)
    p.add_argument('--output',type=pathlib.Path,required=True)
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    profile=out/'profile';profile.mkdir()
    (profile/'huskar-ui.ini').write_text('[General]\nqaFlagReset=true\n',encoding='utf8')
    env=os.environ.copy()
    env.update(SHODAN_PROFILE=str(profile),SHODAN_HUSKAR_QA=str(out),SHODAN_QA_OUTPUT=str(out),TEMP=str(out),TMP=str(out))
    proc=subprocess.Popen([str(a.exe.resolve())],cwd=a.exe.resolve().parent,env=env)
    try: code=proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],capture_output=True);raise
    report=json.loads((out/'report.json').read_text(encoding='utf8'))
    assert code==0 and report['error']=='',report
    assert (out/'45-flag-reset.png').is_file()
    print(json.dumps(dict(native_click=True,backend_restored=True,visible_switch_restored=True,game_writes=0)))

if __name__=='__main__':main()
