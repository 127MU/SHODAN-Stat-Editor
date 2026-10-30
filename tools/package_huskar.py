"""Package the native HuskarUI desktop. Qt is deployed locally, without CI."""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess, sys, tempfile, zipfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_lab import MODULES, CORE_VERSION, CORE_COMMIT
from proxy_runtime_policy import include_proxy_file
ROOT = Path(__file__).resolve().parents[1]
VERSION = '4.5.1-r2'
MITMDUMP_SHA256 = 'e2f05da6385d8c76c2f5b7b23b5d0f7e2c23483b5ece99fe1f4e3b0c04c5f8b5'

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--build-dir', type=Path, required=True)
    p.add_argument('--qt-dir', type=Path, required=True)
    p.add_argument('--compiler-bin', type=Path, required=True)
    p.add_argument('--huskar-root', type=Path, required=True)
    p.add_argument('--output-root', type=Path, default=ROOT/'dist/huskar-r17')
    p.add_argument('--mitmdump', type=Path, help='Official mitmdump.exe to bundle; never builds/downloads a proxy implicitly')
    p.add_argument('--mitmproxy-license', type=Path, help='Upstream MIT license accompanying bundled mitmdump')
    p.add_argument('--proxy-runtime',type=Path,help='Portable upstream source runtime produced by build_proxy_runtime.py')
    a = p.parse_args()
    release = a.output_root/('SHODAN_'+VERSION)
    if a.proxy_runtime and release.exists() and any(release.iterdir()):
        p.error('Use a fresh output directory so old capture drivers cannot remain in the package')
    release.mkdir(parents=True, exist_ok=True)
    def copy(src, name):
        dst=release/name; dst.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(src,dst)
    copy(a.build_dir/'SHODAN Huskar.exe','SHODAN 数值编辑器.exe')
    copy(a.build_dir/'shodan-steam-bridge.exe','shodan-steam-bridge.exe')
    if a.proxy_runtime:
        if a.mitmdump:p.error('choose either --proxy-runtime or --mitmdump')
        data=json.loads((a.proxy_runtime/'runtime.json').read_text('utf8'))
        if data.get('core')!='mitmproxy' or data.get('version')!='12.3.1':p.error('unexpected proxy runtime version')
        filtered={name:digest for name,digest in data['files'].items() if include_proxy_file(name)}
        for name,digest in filtered.items():
            f=a.proxy_runtime/name
            if f.resolve().is_relative_to(a.proxy_runtime.resolve()) and hashlib.sha256(f.read_bytes()).hexdigest()==digest:copy(f,'mitmproxy/'+name)
            else:p.error('proxy runtime hash/path validation failed: '+name)
        data['files']=filtered;data['capture_modes']=['regular','upstream'];data['component_policy']='http-only; packet capture drivers and redirector excluded'
        (release/'mitmproxy/runtime.json').write_text(json.dumps(data,indent=2),encoding='utf8')
        subprocess.run([str((release/'mitmproxy/python.exe').resolve()),'-I','-c',
                        'import ssl;c=ssl.create_default_context();assert c.check_hostname and c.verify_mode==ssl.CERT_REQUIRED'],check=True)
    if a.mitmdump:
        if not a.mitmproxy_license or not a.mitmproxy_license.is_file():
            p.error('--mitmproxy-license is required when bundling mitmdump')
        if a.mitmdump.name.lower() != 'mitmdump.exe':
            p.error('--mitmdump must point to mitmdump.exe')
        if hashlib.sha256(a.mitmdump.read_bytes()).hexdigest() != MITMDUMP_SHA256:
            p.error('mitmdump does not match the pinned official 12.3.1 Windows binary')
        copy(a.mitmdump,'mitmproxy/mitmdump.exe')
        copy(a.mitmproxy_license,'licenses/mitmproxy-MIT.txt')
        (release/'mitmproxy/source.json').write_text(json.dumps({'version':'12.3.1','url':'https://downloads.mitmproxy.org/12.3.1/mitmproxy-12.3.1-windows-x86_64.zip','mitmdump_sha256':MITMDUMP_SHA256},indent=2),encoding='utf8')
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
    # QML debugger/profiler plugins are only needed by development tooling.
    shutil.rmtree(release/'qmltooling',ignore_errors=True)
    # Strip only our MinGW build outputs, never third-party signed Qt/Python DLLs.
    # COFF symbol tables can exceed the loaded code size, especially HuskarUI.
    strip=a.compiler_bin/'strip.exe'
    stripped=[]
    for name in ('SHODAN 数值编辑器.exe','HuskarUIBasic.dll','HuskarUIImpl.dll','shodan-steam-bridge.exe'):
        f=release/name
        if f.is_file():
            before=f.stat().st_size
            # MinGW binutils use the system ANSI codepage for argv filenames.
            # Python copies Unicode paths; strip sees only an ASCII basename.
            with tempfile.TemporaryDirectory(prefix='shodan-strip-',dir=a.build_dir.resolve()) as temporary:
                staged=Path(temporary)/'input.exe'
                shutil.copy2(f,staged)
                strip_env=dict(env,TEMP=temporary,TMP=temporary)
                subprocess.run([str(strip.resolve()),'--strip-unneeded',staged.name],cwd=temporary,check=True,env=strip_env)
                shutil.copy2(staged,f)
            stripped.append({'file':name,'before':before,'after':f.stat().st_size})
    files={f.relative_to(release).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in release.rglob('*') if f.is_file() and f.name!='manifest.json'}
    manifest={'version':VERSION,'core_version':CORE_VERSION,'core_commit':CORE_COMMIT,'ui_framework':'HuskarUI',
              'ui_commit':'d760773ee0f440284965fe443f765caeb66d8114','qt_version':'6.8.3','transport':'in-process-luajit',
              'game_writes_during_tests':False,'files':files}
    (release/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf8')
    target=a.output_root/(release.name+'_Windows.zip')
    with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for f in release.rglob('*'):
            if f.is_file():z.write(f,release.name+'/'+f.relative_to(release).as_posix())
    sources=[ROOT/'LICENSE',ROOT/'README.md',ROOT/'src/stat_editor.lua',ROOT/'docs/guard-dog-configuration.md',ROOT/'docs/war-proxy-integration.md',ROOT/'offline/war_status_addon.py',ROOT/'tests/test_war_proxy.cpp',ROOT/'tests/test_war_status_addon.py',ROOT/'tests/test_war_proxy_ui.py',ROOT/'tests/mitmproxy_native_smoke.py']
    sources += [ROOT/'assets/war_catalog.json', ROOT/'tools/build_war_catalog.py', ROOT/'tools/build_proxy_runtime.py', ROOT/'tools/proxy_runtime_policy.py', ROOT/'tools/probe_war_connection.py', ROOT/'tools/import_war_reference.py', ROOT/'tests/test_steam_bridge.py']
    sources += [ROOT/'tests/test_edit_history.py',ROOT/'tests/test_edit_history_ui.py',ROOT/'tests/test_status_strength_layout.py',ROOT/'tests/test_status_strength_ui.py',ROOT/'tests/test_row_delta.py',ROOT/'tests/test_file_change_guard.py',ROOT/'tests/test_parameter_groups_ui.py',ROOT/'tests/test_hash_reference.py',ROOT/'docs/editing-workflow.md',ROOT/'docs/compatibility-build26251122.md']
    sources += [ROOT/'docs/gameplay-options.md']
    sources += [ROOT/'docs/squad-transport.md',ROOT/'tests/test_squad_transport.py']
    sources += [ROOT/'tests/test_armor_presets.py']
    sources += [ROOT/'tests/test_bolt_animation.py']
    sources += [ROOT/'tests'/name for name in ('test_reference_chain.py','test_diagnostics_readonly.py','test_diagnostics_ui.py','test_gameplay_resources.py','test_gameplay_options.py')]
    sources+=list((ROOT/'assets').glob('*.png'))
    sources+=[f for f in (ROOT/'offline/launcher').iterdir() if f.is_file() and f.suffix in ('.cpp','.h','.c','.ico','.def','.manifest')]
    sources+=list((ROOT/'offline').glob('*.lua'))+list((ROOT/'offline/originals').glob('*'))+list((ROOT/'offline/licenses').glob('*.txt'))
    sources+=[f for folder in ('desktop/huskar','desktop/eui') for f in (ROOT/folder).rglob('*') if f.is_file() and f.suffix in ('.cpp','.h','.qml','.js','.cmake','.def','.txt','.md','.manifest')]
    sources+=[ROOT/'tools'/n for n in ('package_huskar.py','package_lab.py','package_eui.py','package_onefile.py')]
    sources+=[ROOT/'tests'/name for name in ('test_huskar.py','test_huskar_shaders.py','test_parameter_audit.py','parameter_audit_regression.lua','test_release_update.cpp','test_startup_update.py','test_search_context_extra.py','search_context_extra_regression.lua','test_original_mapping.py','test_foreign_snapshot.py','test_switch_reset.py','test_res_patch.py','test_chinese_choices.py','test_resident_donors.py','test_weapon_calibre.py','test_foreign_core_tails.py','test_gl52_self_exclusion.py','test_dual_tube_projectiles.py','test_field_storage_audit.py','test_upstream451.py','field_storage_audit.lua','test_state_machine.py','test_res_patch_override.py','test_state_machine_integration.py','test_bounce_tweak.py','test_modified_catalog.py','test_guard_dog_swap.py','test_guard_dog_defaults.py','test_reference_identity.py','test_reference_restart.py','test_residency_dependencies.py','test_residency_game_readonly.py','test_appearance_settings.py')]
    with zipfile.ZipFile(a.output_root/(release.name+'_Source.zip'),'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for f in sorted(set(sources)):
            if f.is_file():z.write(f,release.name+'_Source/'+f.relative_to(ROOT).as_posix())
    print(json.dumps({'release':str(release),'zip':str(target),'files':len(files),'bytes':target.stat().st_size,'stripped':stripped},ensure_ascii=False))

if __name__=='__main__':main()
