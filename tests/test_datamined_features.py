"""Exercise new component fields without writing game files."""
import argparse,json,os,pathlib,sys
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--runtime-dir',type=pathlib.Path);p.add_argument('--vendor',type=pathlib.Path);a=p.parse_args()
 root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
 os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out))
 if a.vendor:sys.path.insert(0,str(a.vendor))
 from lupa.luajit21 import LuaRuntime
 lua=LuaRuntime(encoding=None);lua.globals().SHODAN_EUI=True
 editor=(a.runtime_dir.resolve()/'app/stat_editor.lua') if a.runtime_dir else root/'src/stat_editor.lua';host=(a.runtime_dir.resolve()/'app/host.lua') if a.runtime_dir else root/'offline/host.lua'
 lua.execute(b'arg={...}',editor.as_posix().encode());lua.globals().B=lua.execute(b'return dofile(...)',host.as_posix().encode())
 result=lua.execute((root/'tests/datamined_features_regression.lua').read_bytes());report={k.decode():v for k,v in result.items()};(out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf8');print(json.dumps(report))
if __name__=='__main__':main()
