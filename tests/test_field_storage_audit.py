"""Audit numeric storage requests across every editable owner, without game writes."""
import argparse,json,os,pathlib,sys

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',type=pathlib.Path,required=True);p.add_argument('--runtime-dir',type=pathlib.Path);p.add_argument('--diagnose',action='store_true');a=p.parse_args()
 root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
 os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,str(a.vendor));from lupa.luajit21 import LuaRuntime
 lua=LuaRuntime();lua.globals().SHODAN_EUI=True
 app=a.runtime_dir.resolve()/'app' if a.runtime_dir else root/'offline';editor=app/'stat_editor.lua'if a.runtime_dir else root/'src/stat_editor.lua'
 source=editor.read_text(encoding='utf8');anchor='    local f = fields[key]\n    if not f then'
 assert source.count(anchor)==1
 source=source.replace(anchor,"""    local f = fields[key]
    QA_TYPE_HOOK_USED=true;QA_TABLES=tables
    if f and f.storage~=storage then
        local conflict=key..':'..f.storage..':'..storage
        if not QA_TYPE_CONFLICTS[conflict] then QA_TYPE_CONFLICTS[conflict]={key=key,kind=kind,offset=offset,existing=f.storage,requested=storage,trace=debug.traceback('',2)} end
    end
    if not f then""")
 lua.globals().QA_TYPE_CONFLICTS=lua.table();lua.globals().QA_SOURCE=source;lua.globals().QA_EDITOR=editor.as_posix()
 lua.execute("package.path=.....';'..package.path",(app/'?.lua').as_posix())
 lua.execute("local original=loadfile;loadfile=function(path)if path==QA_EDITOR then return loadstring(QA_SOURCE,'@'..path)end;return original(path)end;require('install').write_files=function()error('Game writes forbidden')end")
 lua.execute('arg={...}',editor.as_posix());lua.globals().B=lua.execute('return dofile(...)',(app/'host.lua').as_posix())
 result=lua.execute((root/'tests/field_storage_audit.lua').read_text(encoding='utf8'))
 def convert(v):
  if hasattr(v,'items'):
   d=dict(v.items())
   if d and all(isinstance(k,int)for k in d):return [convert(d[k])for k in sorted(d)]
   return {k:convert(x)for k,x in d.items()}
  return v
 report=convert(result);(out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
 print(json.dumps({k:v for k,v in report.items()if k not in ('conflicts','mismatches','scopes','undecoded')},ensure_ascii=False))
 if not a.diagnose:assert report['float_storage_mismatches']==0 and report['storage_conflicts']==0 and not report['undecoded'],report
if __name__=='__main__':main()
