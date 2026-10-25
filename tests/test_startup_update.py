"""Verify one automatic update cycle per process, using mock release responses."""
import argparse,json,os,pathlib,subprocess
def main():
 p=argparse.ArgumentParser();p.add_argument('--exe',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
 root=a.output.resolve();root.mkdir(parents=True,exist_ok=False)
 for i,mode in enumerate(['newer','same','failed','newer']):
  out=root/(str(i)+'-'+mode);out.mkdir();profile=out/'profile';profile.mkdir()
  env=os.environ.copy()
  for key in ['SHODAN_MCP_QA','SHODAN_STARTUP_SMOKE']:env.pop(key,None)
  env.update(SHODAN_PROFILE=str(profile),SHODAN_EUI_QA=str(out),SHODAN_QA_OUTPUT=str(out),SHODAN_UPDATE_QA=mode)
  proc=subprocess.Popen([str(a.exe.resolve())],cwd=a.exe.resolve().parent,env=env)
  try:code=proc.wait(timeout=55)
  except subprocess.TimeoutExpired:
   subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],capture_output=True);raise
  assert code==0,code
  assert not (out/'failure.txt').exists(),(out/'failure.txt').read_text(encoding='utf8')
  report=json.loads((out/'update-report.json').read_text(encoding='utf8'))
  assert report==dict(startup_checks=1,newer_popup=mode=='newer',failed=mode=='failed',game_writes=0),report
 print(json.dumps({'fresh_launches':4,'exactly_one_check_per_launch':True,'newer_popup':True,'same_and_failed_no_popup':True,'game_writes':0}))
if __name__=='__main__':main()
