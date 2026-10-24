"""Start the single-file EXE normally, without the native QA startup shortcuts."""
import argparse,json,os,pathlib,struct,subprocess

def main():
 p=argparse.ArgumentParser();p.add_argument('--exe',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
 out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir()
 (profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
 env=os.environ.copy()
 for key in ('SHODAN_EUI_QA','SHODAN_QA_OUTPUT','SHODAN_MCP_QA'):env.pop(key,None)
 env.update(SHODAN_PROFILE=str(profile),SHODAN_STARTUP_SMOKE=str(out))
 proc=subprocess.Popen([str(a.exe.resolve())],cwd=a.exe.resolve().parent,env=env)
 try:code=proc.wait(timeout=65)
 except subprocess.TimeoutExpired:
  subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],capture_output=True);raise
 assert code==0,code
 report=(out/'startup-report.txt').read_text(encoding='utf8')
 assert 'visible=1 minimized=0' in report,report
 pixels=(out/'startup-ready.bmp').read_bytes();offset=struct.unpack_from('<I',pixels,10)[0]
 assert len(set(pixels[offset::19]))>20,'Rendered frame appears blank'
 logs='\n'.join(f.read_text(encoding='utf8',errors='replace') for f in (profile/'Logs').glob('startup*.log'))
 assert '[startup] Window visible=1' in logs and '[startup] Host model ready' in logs and '[startup] First UI composition' in logs,logs[-1000:]
 print(json.dumps({'normal_startup':True,'visible_window':True,'rendered_frame':True,'startup_stage_logs':True,'game_writes':0}))
if __name__=='__main__':main()
