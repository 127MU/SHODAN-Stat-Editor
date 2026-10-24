"""Build the single-EXE CAB/FDI distribution with per-file SHA-256 validation."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess, zipfile, shutil

ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--release',type=Path,required=True)
    p.add_argument('--compiler-bin',type=Path,required=True)
    a=p.parse_args()
    work=a.release.parent/'onefile-build';work.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy();env['PATH']=str(a.compiler_bin.resolve())+';'+env.get('PATH','')
    temp=work/'temp';temp.mkdir(exist_ok=True)
    env['TEMP']=env['TMP']=str(temp.resolve())
    manifest=json.loads((a.release/'manifest.json').read_text(encoding='utf8'))
    files=[]
    for n in manifest['files']:
        files.append((a.release/n,'shodan.exe' if n=='SHODAN 数值编辑器.exe' else n))
    files.append((a.release/'manifest.json','manifest.json'))
    lines=[]
    for source,name in files:lines.append(hashlib.sha256(source.read_bytes()).hexdigest()+' '+name)
    content='\n'.join(sorted(lines))+'\n'
    build=manifest['version']+'-desktop-'+hashlib.sha256(content.encode()).hexdigest()[:16]
    (work/'checksums.txt').write_text(content,encoding='utf8')
    (work/'build.txt').write_text(build,encoding='utf8')
    dff=['.OPTION EXPLICIT','.Set CabinetNameTemplate=payload.cab',
         '.Set DiskDirectory1="'+str(work.resolve())+'"','.Set MaxDiskSize=0',
         '.Set CompressionType=LZX','.Set CompressionMemory=21',
         '.Set Cabinet=ON','.Set Compress=ON']
    # MakeCAB reads directive paths using the system ANSI codepage. Stage under
    # ASCII names so the Chinese executable name never passes through it.
    staged=[]
    for source,name in files:
        target=work/'input'/name;target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,target);staged.append((target,name))
    dff+=['"'+str(source.resolve())+'" "'+name.replace('/','\\')+'"' for source,name in staged]
    (work/'payload.dff').write_text('\n'.join(dff),encoding='utf8')
    with (work/'makecab.log').open('wb') as log:
        result=subprocess.run(['makecab.exe','/F',str((work/'payload.dff').resolve())],cwd=work,stdout=log,stderr=subprocess.STDOUT,env=env)
    if result.returncode:
        raise RuntimeError((work/'makecab.log').read_bytes()[-2000:].decode('utf8',errors='replace'))
    def resource_path(path):return str(path.resolve()).replace('\\','/')
    rc='1 ICON "'+resource_path(ROOT/'offline/launcher/sseo.ico')+'"\n'
    rc+='1 24 "'+resource_path(ROOT/'desktop/eui/application.manifest')+'"\n'
    for rid,name in [(101,'payload.cab'),(102,'checksums.txt'),(103,'build.txt')]:
        rc+=str(rid)+' RCDATA "'+resource_path(work/name)+'"\n'
    (work/'onefile.rc').write_text(rc,encoding='utf8')
    subprocess.run([str(a.compiler_bin/'windres.exe'),str(work/'onefile.rc'),'-o',str(work/'onefile.res.o')],env=env,check=True)
    target=a.release.parent/('SHODAN_'+manifest['version']+'_单文件.exe')
    subprocess.run([str(a.compiler_bin/'g++.exe'),'-std=c++17','-O2','-s','-static','-mwindows','-municode',
                    str(ROOT/'desktop/eui/onefile.cpp'),str(work/'onefile.res.o'),'-lcabinet','-lbcrypt','-o',str(target)],env=env,check=True)
    print(json.dumps({'exe':str(target),'bytes':target.stat().st_size,'cache_build':build},ensure_ascii=False))

if __name__=='__main__':main()
