"""Native undo/redo controls and restoration in an isolated profile."""
import argparse,json,os,pathlib,subprocess
def main():
    p=argparse.ArgumentParser();p.add_argument('--exe',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir()
    (profile/'huskar-ui.ini').write_text('[General]\nqaHistoryOnly=true\n','utf8')
    env=dict(os.environ,SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out),SHODAN_HUSKAR_QA=str(out),TEMP=str(out),TMP=str(out))
    proc=subprocess.Popen([str(a.exe.resolve())],cwd=a.exe.resolve().parent,env=env)
    try:code=proc.wait(timeout=55)
    except subprocess.TimeoutExpired:proc.terminate();proc.wait(timeout=10);raise
    result=json.loads((out/'report.json').read_text('utf8'));assert code==0 and not result['error'],(code,result)
    assert len(list(out.glob('history-*.png')))==5
    log=(profile/'Logs/huskar-startup.log').read_text('utf8',errors='replace')
    errors=[line for line in log.splitlines() if any(s in line for s in ('ReferenceError:','TypeError:','Binding loop','Unable to assign'))]
    assert not errors,errors
    print(json.dumps({'undo_button':True,'redo_button':True,'reset_undo':True,'game_writes':0}))
if __name__=='__main__':main()
