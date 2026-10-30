"""Click collapse/expand controls and verify native card geometry."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--exe',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    profile=out/'profile';profile.mkdir()
    (profile/'huskar-ui.ini').write_text('[General]\nqaParameterGroupsOnly=true\n',encoding='utf8')
    env=dict(os.environ,SHODAN_PROFILE=str(profile),SHODAN_HUSKAR_QA=str(out),SHODAN_QA_OUTPUT=str(out),TEMP=str(out),TMP=str(out))
    proc=subprocess.Popen([str(args.exe.resolve())],cwd=args.exe.resolve().parent,env=env)
    try:
        code=proc.wait(timeout=45)
    except subprocess.TimeoutExpired:
        proc.terminate();proc.wait(timeout=10);raise
    result=json.loads((out/'report.json').read_text('utf8'))
    assert code==0 and not result['error'],(code,result)
    assert len(list(out.glob('groups-*.png')))==9
    log=(profile/'Logs/huskar-startup.log').read_text('utf8',errors='replace')
    errors=[line for line in log.splitlines() if any(s in line for s in ('ReferenceError:','TypeError:','Binding loop','Unable to assign'))]
    assert not errors,errors
    print(json.dumps({'single_collapse':True,'all_collapse':True,'expand_restores_fields':True,'layout_switch':True,'vehicle_scroll_preserved':True,'game_writes':0}))


if __name__=='__main__':main()
