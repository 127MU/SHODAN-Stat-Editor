"""Run the production Lua coordinator with a fake disk writer (Windows only)."""
import argparse,json,os,pathlib,sys
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',type=pathlib.Path);p.add_argument('--runtime-dir',type=pathlib.Path);a=p.parse_args()
 root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
 profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
 os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out))
 if a.vendor:sys.path.insert(0,str(a.vendor))
 from lupa.luajit21 import LuaRuntime
 lua=LuaRuntime();lua.globals().SHODAN_EUI=True
 editor=(a.runtime_dir.resolve()/'app/stat_editor.lua') if a.runtime_dir else root/'src/stat_editor.lua'
 host=(a.runtime_dir.resolve()/'app/host.lua') if a.runtime_dir else root/'offline/host.lua'
 lua.execute('arg={...}',editor.as_posix())
 lua.globals().B=lua.execute('return dofile(...)',host.as_posix())
 result=lua.execute((root/'tests/upstream_v4_regression.lua').read_text(encoding='utf8'))
 report=dict(result.items());(out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf8');print(json.dumps(report))
if __name__=='__main__':main()
