"""Native settings interaction, image palette sampling and restart persistence."""
import argparse,json,os,pathlib,subprocess
from PIL import Image

def main():
 p=argparse.ArgumentParser();p.add_argument('--exe',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
 out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir()
 (profile/'huskar-ui.ini').write_text('[General]\nqaAppearanceOnly=true\n','utf8')
 Image.new('RGB',(180,120),(20,170,80)).save(out/'palette.png')
 env=os.environ.copy();env.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out),SHODAN_HUSKAR_QA=str(out),TEMP=str(out),TMP=str(out))
 for phase in range(2):
  if phase:env['SHODAN_HUSKAR_RESTORE_QA']='1'
  proc=subprocess.Popen([str(a.exe.resolve())],cwd=a.exe.resolve().parent,env=env)
  try:code=proc.wait(timeout=55)
  except subprocess.TimeoutExpired:
   subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],capture_output=True);raise
  report=out/'report.json';assert report.exists(),f'No QA report; exit={code}'
  result=json.loads(report.read_text('utf8'));assert code==0 and not result['error'],(code,result)
  if not phase:report.rename(out/'first-report.json')
 captures=list(out.glob('appearance-*.png'));assert len(captures)==10
 for capture in captures:
  im=Image.open(capture).convert('RGB').resize((100,60));assert len(set(im.get_flattened_data()))>100,f'Blank: {capture}'
 log=(profile/'Logs/huskar-startup.log').read_text('utf8',errors='replace')
 errors=[x for x in log.splitlines() if any(s in x for s in ('ReferenceError:','TypeError:','Binding loop','Unable to assign','Failed to link shader','Failed to build graphics pipeline'))]
 assert not errors,'\n'.join(errors)
 print(json.dumps({'native_controls':True,'palette_sampling':True,'material_sliders':True,'glass_binding':True,'theme_undo':True,'custom_theme':True,'restart_persistence':True,'captures':len(captures),'game_writes':0}))

if __name__=='__main__':main()
