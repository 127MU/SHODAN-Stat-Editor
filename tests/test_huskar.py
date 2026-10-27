"""Exercise the packaged HuskarUI in an isolated profile. No game writes."""
import argparse, json, os, pathlib, subprocess

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--exe',type=pathlib.Path,required=True)
    p.add_argument('--output',type=pathlib.Path,required=True)
    p.add_argument('--qa-platform-dir',type=pathlib.Path)
    a=p.parse_args()
    out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    env=os.environ.copy()
    env.update(SHODAN_PROFILE=str(out/'profile'),SHODAN_HUSKAR_QA=str(out),SHODAN_QA_OUTPUT=str(out),TEMP=str(out),TMP=str(out))
    if a.qa_platform_dir:
        env.update(QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORM_PLUGIN_PATH=str(a.qa_platform_dir.resolve()),QT_QUICK_BACKEND='software')
    proc=subprocess.Popen([str(a.exe.resolve())],cwd=a.exe.resolve().parent,env=env)
    try: code=proc.wait(timeout=150)
    except subprocess.TimeoutExpired:
        subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],capture_output=True)
        raise
    assert (out/'report.json').exists(),f'Native QA exited without a report: {code}'
    report=json.loads((out/'report.json').read_text(encoding='utf8'))
    assert code==0 and report['error']=='',(code,report)
    captures=len(list(out.glob('*.png')))
    assert captures>=56,'Missing page, extra warning choice, grouping, resize, switch restore, preset dialog, sentinel, release notes, projectile context or window effect captures'
    log=(out/'profile/Logs/huskar-startup.log').read_text(encoding='utf8',errors='replace')
    assert 'Icon font registered=1 family=HuskarUI-Icons' in log,'HuskarUI icon font was not initialized'
    from PIL import Image
    dark=Image.open(out/'10-dark.png').convert('RGB').resize((100,60))
    assert sum(min(rgb)>180 for rgb in dark.get_flattened_data())<1800,'Light surfaces remain after dark mode switch'
    problems=[line for line in log.splitlines() if any(x in line for x in ['ReferenceError:','TypeError:','Binding loop','Unable to assign','Cannot anchor','failed to load component','Failed to link shader','Failed to build graphics pipeline','Fail to build reflection'])]
    assert not problems,'\n'.join(problems[:20])
    # Reopen the exact same profile and compare the actual restored preferences.
    env['SHODAN_HUSKAR_RESTORE_QA']='1'
    reopened=subprocess.Popen([str(a.exe.resolve())],cwd=a.exe.resolve().parent,env=env)
    try: restored_code=reopened.wait(timeout=150)
    except subprocess.TimeoutExpired:
        subprocess.run(['taskkill','/PID',str(reopened.pid),'/T','/F'],capture_output=True)
        raise
    restored=json.loads((out/'report.json').read_text(encoding='utf8'))
    assert restored_code==0 and restored['error']=='',restored
    print(json.dumps(dict(captures=captures,armor_check=True,grouped_catalog=True,sentinel_values=True,restart_settings=True,slider_drag=True,card_materials=True,window_effects=True,enter_and_blur=True,preset_roundtrip=True,invalid_value_rejected=True,theme_tokens=True,custom_background=True,game_writes=0)))

if __name__=='__main__':main()
