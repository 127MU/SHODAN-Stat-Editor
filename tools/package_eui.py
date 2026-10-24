"""Package the EUI-NEO desktop using an explicit runtime allowlist."""
from pathlib import Path
import argparse, hashlib, json, shutil, zipfile, sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from package_lab import VERSION, CORE_VERSION, CORE_COMMIT, MODULES, set_icon

ROOT=Path(__file__).resolve().parents[1]
EUI_COMMIT='1647709068e36834ab26da5a97ef4ad98aa34c9d'

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--build-dir',type=Path,required=True)
    p.add_argument('--eui-root',type=Path,required=True)
    p.add_argument('--output-root',type=Path,default=ROOT/'dist/eui-release')
    p.add_argument('--base',type=Path,default=ROOT/'offline/runtime')
    a=p.parse_args()
    release=a.output_root/('SHODAN_'+VERSION)
    release.mkdir(parents=True,exist_ok=True)
    allowed=set()
    def copy(src,dest):
        dst=release/dest;dst.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(src,dst);allowed.add(dest)
    exe=a.build_dir/'SHODAN Stat Editor.exe'
    if not exe.exists():exe=a.build_dir/'Release/SHODAN Stat Editor.exe'
    copy(exe,'SHODAN 数值编辑器.exe')
    # The icon is compiled into the PE. Rewriting a linked MinGW PE with
    # BeginUpdateResource can corrupt its executable sections on this host.
    for name in ('lua51.dll','libsodium.dll'):copy(a.base/name,name)
    copy(ROOT/'offline/launcher/shodan_hash.dll','shodan_hash.dll')
    for name in MODULES:
        source=ROOT/('src/stat_editor.lua' if name=='stat_editor' else 'offline/'+name+'.lua')
        copy(source,'app/'+name+'.lua')
    for path in sorted((ROOT/'offline/originals').iterdir()):
        if path.name=='build.txt' or path.suffix=='.dl_plain':copy(path,'originals/'+path.name)
    copy(ROOT/'assets/shodan-lab-icon.png','assets/icon.png')
    copy(a.eui_root/'assets/Font Awesome 7 Free-Solid-900.otf','assets/Font Awesome 7 Free-Solid-900.otf')
    # Renderer shaders are embedded in this build. Demo media and unused fonts
    # are deliberately excluded. The text font is Windows' installed YaHei.
    for name in ('LICENSE','README.md'):copy(ROOT/name,name)
    for name in ('LuaJIT.txt','libsodium.txt','EUI-third-party.txt'):
        copy(ROOT/'offline/licenses'/name,'licenses/'+name)
    manifest={
        'version':VERSION,'core_version':CORE_VERSION,'core_commit':CORE_COMMIT,
        'ui_framework':'EUI-NEO','ui_commit':EUI_COMMIT,
        'write_flow':'official-3.2.0','transport':'in-process-luajit','mcp':'optional-loopback-http-session-only',
        'feature_source':'https://github.com/SHODAN-HORAI/SHODAN-Stat-Editor/releases/tag/v4.1.0',
        'feature_commit':'ed8f8be397c6d5b816394034ee724572d9f14607',
        'game_writes_during_tests':False,
        'files':{n:hashlib.sha256((release/n).read_bytes()).hexdigest() for n in sorted(allowed)}
    }
    (release/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf8')
    allowed.add('manifest.json')
    def archive(target,pairs):
        with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
            for source,name in pairs:z.write(source,name)
    target=a.output_root/(release.name+'_Windows.zip')
    archive(target,[(release/n,release.name+'/'+n) for n in sorted(allowed)])
    source_files=[ROOT/'LICENSE',ROOT/'README.md',ROOT/'src/stat_editor.lua',ROOT/'tools/package_lab.py',ROOT/'tools/package_eui.py',ROOT/'tools/package_onefile.py']
    source_files+=list((ROOT/'offline').glob('*.lua'))+list((ROOT/'offline/originals').iterdir())+list((ROOT/'offline/licenses').glob('*.txt'))
    source_files+=[x for x in (ROOT/'desktop/eui').rglob('*') if x.is_file() and x.suffix in ('.cpp','.h','.def','.md','.txt','.manifest')]
    source_files+=list((ROOT/'assets').glob('*.png'))
    source_files+=[ROOT/'offline/launcher'/n for n in ('hashsolve.c','fetch.c','update.c','sseo.ico')]
    source_files+=list((ROOT/'tests').glob('test_*.py'))+list((ROOT/'tests').glob('test_*.cpp'))+list((ROOT/'tests').glob('*.lua'))
    source=a.output_root/(release.name+'_Source.zip')
    archive(source,[(f,release.name+'_Source/'+f.relative_to(ROOT).as_posix()) for f in sorted(set(source_files)) if f.is_file()])
    print(json.dumps({'release':str(release),'zip':str(target),'bytes':target.stat().st_size,'files':len(allowed),'source':str(source)},ensure_ascii=False))

if __name__=='__main__':main()
