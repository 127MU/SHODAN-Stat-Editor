"""Package the native HuskarUI desktop. Qt is deployed locally, without CI."""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess, sys, zipfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_lab import MODULES, CORE_VERSION, CORE_COMMIT
ROOT = Path(__file__).resolve().parents[1]
VERSION = '4.1.0-r14'

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--build-dir', type=Path, required=True)
    p.add_argument('--qt-dir', type=Path, required=True)
    p.add_argument('--compiler-bin', type=Path, required=True)
    p.add_argument('--huskar-root', type=Path, required=True)
    p.add_argument('--output-root', type=Path, default=ROOT/'dist/huskar-r14')
    a = p.parse_args()
    release = a.output_root/('SHODAN_'+VERSION)
    release.mkdir(parents=True, exist_ok=True)
    def copy(src, name):
        dst=release/name; dst.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(src,dst)
    copy(a.build_dir/'SHODAN Huskar.exe','SHODAN 数值编辑器.exe')
    for name in ('lua51.dll','libsodium.dll'): copy(ROOT/'offline/runtime'/name,name)
    copy(ROOT/'offline/launcher/shodan_hash.dll','shodan_hash.dll')
    for name in MODULES:
        source=ROOT/('src/stat_editor.lua' if name=='stat_editor' else 'offline/'+name+'.lua')
        copy(source,'app/'+name+'.lua')
    for f in (ROOT/'offline/originals').iterdir():
        if f.name=='build.txt' or f.suffix=='.dl_plain': copy(f,'originals/'+f.name)
    copy(ROOT/'assets/shodan-transparent.png','assets/shodan.png')
    for name in ('LICENSE','README.md'): copy(ROOT/name,name)
    for name in ('LuaJIT.txt','libsodium.txt'): copy(ROOT/'offline/licenses'/name,'licenses/'+name)
    copy(a.huskar_root/'LICENSE','licenses/HuskarUI.txt')
    copy(a.huskar_root/'3rdparty/qwindowkit/LICENSE','licenses/QWindowKit.txt')
    for name in ('Qt-NOTICE.txt','Qt-LGPL-3.0.txt','Qt-GPL-3.0.txt'):copy(ROOT/'offline/licenses'/name,'licenses/'+name)
    helpers=a.build_dir/'_deps/eui_helpers-src'
    for line in (a.build_dir/'CMakeCache.txt').read_text(encoding='utf8').splitlines():
        if line.startswith('FETCHCONTENT_SOURCE_DIR_EUI_HELPERS:') and line.split('=',1)[1]:helpers=Path(line.split('=',1)[1])
    copy(helpers/'LICENSE','licenses/JSON-helper-Apache-2.0.txt')
    copy(helpers/'3rd/yyjson-0.12.0/LICENSE','licenses/yyjson.txt')
    zlib_notice=(helpers/'3rd/zlib-1.3.1/zlib.h').read_text(encoding='utf8').split('*/',1)[0]+'*/\n'
    (release/'licenses/zlib.txt').write_text(zlib_notice,encoding='utf8')
    shutil.copytree(a.build_dir/'HuskarUI/qml/HuskarUI',release/'qml/HuskarUI',dirs_exist_ok=True)
    for f in (a.build_dir/'HuskarUI/bin').glob('*.dll'): copy(f,f.name)
    env=os.environ.copy();env['PATH']=str(a.compiler_bin)+';'+str(a.qt_dir/'bin')+';'+env['PATH']
    temporary=a.output_root/'deploy-temp';temporary.mkdir(parents=True,exist_ok=True)
    env['TEMP']=env['TMP']=str(temporary.resolve())
    subprocess.run([str(a.qt_dir/'bin/windeployqt.exe'),'--release','--qmldir',str(ROOT/'desktop/huskar'),
                    '--qmlimport',str(a.build_dir/'HuskarUI/qml'),'--no-translations','--no-opengl-sw',
                    '--no-system-d3d-compiler',str(release/'SHODAN 数值编辑器.exe')],env=env,check=True)
    (release/'qt.conf').write_text('[Paths]\nPrefix=.\nPlugins=.\nQmlImports=qml\n',encoding='utf8')
    # Runtime only. Exclude developer metadata and debug/import libraries.
    for f in list(release.rglob('*')):
        if f.is_file() and (f.suffix.lower() in ('.pdb','.a','.lib','.prl','.qmltypes') or f.name.endswith('d.dll') and f.name.startswith('Qt6')):
            f.unlink()
    files={f.relative_to(release).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in release.rglob('*') if f.is_file() and f.name!='manifest.json'}
    manifest={'version':VERSION,'core_version':CORE_VERSION,'core_commit':CORE_COMMIT,'ui_framework':'HuskarUI',
              'ui_commit':'d760773ee0f440284965fe443f765caeb66d8114','qt_version':'6.8.3','transport':'in-process-luajit',
              'game_writes_during_tests':False,'files':files}
    (release/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf8')
    target=a.output_root/(release.name+'_Windows.zip')
    with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for f in release.rglob('*'):
            if f.is_file():z.write(f,release.name+'/'+f.relative_to(release).as_posix())
    sources=[ROOT/'LICENSE',ROOT/'README.md',ROOT/'src/stat_editor.lua']
    sources+=list((ROOT/'assets').glob('*.png'))
    sources+=[f for f in (ROOT/'offline/launcher').iterdir() if f.is_file() and f.suffix in ('.cpp','.h','.c','.ico','.def','.manifest')]
    sources+=list((ROOT/'offline').glob('*.lua'))+list((ROOT/'offline/originals').glob('*'))+list((ROOT/'offline/licenses').glob('*.txt'))
    sources+=[f for folder in ('desktop/huskar','desktop/eui') for f in (ROOT/folder).rglob('*') if f.is_file() and f.suffix in ('.cpp','.h','.qml','.def','.txt','.md','.manifest')]
    sources+=[ROOT/'tools'/n for n in ('package_huskar.py','package_lab.py','package_eui.py','package_onefile.py')]
    sources+=[ROOT/'tests/test_huskar.py',ROOT/'tests/test_release_update.cpp',ROOT/'tests/test_startup_update.py']
    with zipfile.ZipFile(a.output_root/(release.name+'_Source.zip'),'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for f in sorted(set(sources)):
            if f.is_file():z.write(f,release.name+'_Source/'+f.relative_to(ROOT).as_posix())
    print(json.dumps({'release':str(release),'zip':str(target),'files':len(files),'bytes':target.stat().st_size},ensure_ascii=False))

if __name__=='__main__':main()
