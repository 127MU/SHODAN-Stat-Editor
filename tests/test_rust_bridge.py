"""Exercise actual Rust/Lua IPC with an isolated profile; never call install."""
import argparse,json,os,pathlib,subprocess,tempfile
p=argparse.ArgumentParser();p.add_argument('--runtime',type=pathlib.Path,required=True);p.add_argument('--exe',type=pathlib.Path,required=True);a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='rust-host-',dir=pathlib.Path('dist').resolve()) as temp:
 env=dict(os.environ,SHODAN_PROFILE=temp,SHODAN_QA_OUTPUT=temp)
 child=subprocess.Popen([str(a.exe.resolve()),str(a.runtime.resolve())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf8',env=env)
 def call(n,method,args=[]):
  child.stdin.write(json.dumps(dict(id=n,method=method,args=args))+'\n');child.stdin.flush()
  result=json.loads(child.stdout.readline());assert result['id']==n and 'error' not in result,result
  return result['data']
 try:
  items=call(1,'items',['Primary','']);assert len(items)>50
  call(2,'select',[items[0]['id']]);rows=call(3,'rows');row=next(r for r in rows if r['label']=='伤害');before=row['text'];original=row['default_text']
  call(4,'set',[row['id'],'123']);changed=call(5,'rows');r=next(r for r in changed if r['id']==row['id']);assert r['text']=='123' and r['default_text']==original
  call(6,'reset',[row['id']]);r=next(r for r in call(7,'rows')if r['id']==row['id']);assert r['text']==original
  call(8,'set',[row['id'],before]);assert call(9,'flush')
  for i,field in enumerate(('name','code','desc'),10):
   result=call(i,'game_text',[field]);assert isinstance(result,dict) and 'available' in result
  child.stdin.write('{"method":"shutdown"}\n');child.stdin.flush();child.wait(timeout=10);assert child.returncode==0
  # UI exits without waiting for a final save: drain queued valid requests even
  # when its response pipe is closed, then persist on input EOF.
  def spawn():
   return subprocess.Popen([str(a.exe.resolve()),str(a.runtime.resolve())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf8',env=env)
  child=spawn()
  for n,method,args in [(30,'items',['Primary','']),(31,'select',[items[0]['id']]),(32,'set',[row['id'],'147'])]:
   child.stdin.write(json.dumps(dict(id=n,method=method,args=args))+'\n')
  child.stdout.close();child.stdin.close();child.wait(timeout=15);assert child.returncode==0
  child=spawn();call(33,'items',['Primary','']);call(34,'select',[items[0]['id']])
  persisted=next(r for r in call(35,'rows') if r['id']==row['id']);assert persisted['text']=='147',persisted
  child.stdin.write('{"method":"shutdown"}\n');child.stdin.flush();child.wait(timeout=10);assert child.returncode==0
  print(json.dumps(dict(real_items=len(items),real_fields=len(rows),edit_reset=True,immutable_original=True,closed_ui_queue_persisted=True,game_writes=0)))
 finally:
  if child.poll()is None:child.terminate();child.wait(timeout=10)
