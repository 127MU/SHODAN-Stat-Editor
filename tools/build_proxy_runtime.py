"""Assemble a portable CPython + upstream mitmproxy source runtime.
Install pinned wheels into a separate staging directory first. This script never
installs anything into the user's Python or system certificate store.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import zipfile
import subprocess
from proxy_runtime_policy import include_proxy_file


def main():
    p=argparse.ArgumentParser()
    p.add_argument("--python-root",type=Path,required=True)
    p.add_argument("--site-packages",type=Path,required=True)
    p.add_argument("--output",type=Path,required=True)
    a=p.parse_args();root=a.output.resolve()
    if root.exists() and any(root.iterdir()):p.error('Use a fresh runtime output directory')
    root.mkdir(parents=True,exist_ok=True)
    included=set()
    def copy(src,name):
        target=root/name;target.parent.mkdir(parents=True,exist_ok=True)
        if src.resolve()!=target.resolve():shutil.copy2(src,target)
        included.add(name.replace("\\","/"))
    for name in ("python.exe","python312.dll","python3.dll","vcruntime140.dll","vcruntime140_1.dll"):
        copy(a.python_root/name,name)
    copy(a.python_root/"LICENSE.txt","licenses/Python.txt")
    for f in (a.python_root/"DLLs").iterdir():
        if f.suffix.lower() in (".dll",".pyd") and not f.name.startswith("_test"):copy(f,"DLLs/"+f.name)
    excluded={"site-packages","__pycache__","test","tests","idlelib","tkinter","turtledemo","ensurepip","venv","lib2to3"}
    with zipfile.ZipFile(root/"python312.zip","w",zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for f in (a.python_root/"Lib").rglob("*"):
            rel=f.relative_to(a.python_root/"Lib")
            if f.is_file() and f.suffix==".py" and not any(part in excluded for part in rel.parts):z.write(f,rel.as_posix())
    included.add("python312.zip")
    for f in a.site_packages.rglob("*"):
        rel=f.relative_to(a.site_packages)
        if f.is_file() and include_proxy_file(rel.as_posix()) and not any(part in {"__pycache__","tests","test","bin"} for part in rel.parts) and f.suffix not in (".pyc",".pyo"):
            copy(f,"Lib/site-packages/"+rel.as_posix())
    (root/"python312._pth").write_text("python312.zip\n.\nDLLs\nLib/site-packages\nimport site\n",encoding="ascii");included.add("python312._pth")
    (root/"proxy_main.py").write_text("from mitmproxy.tools.main import mitmdump\nif __name__ == '__main__':\n    mitmdump()\n",encoding="utf8");included.add("proxy_main.py")
    probe=json.loads(subprocess.check_output([str(root/"python.exe"),"-I","-c","import platform,json,importlib.metadata;print(json.dumps({'python':platform.python_version(),'mitmproxy':importlib.metadata.version('mitmproxy')}))"],text=True))
    if probe['mitmproxy']!='12.3.1' or not probe['python'].startswith('3.12.'):raise RuntimeError('unexpected proxy/Python runtime')
    files={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in sorted(included)}
    (root/"runtime.json").write_text(json.dumps({"core":"mitmproxy","version":probe['mitmproxy'],"python":probe['python'],"source":"https://github.com/mitmproxy/mitmproxy/tree/v12.3.1","capture_modes":["regular","upstream"],"files":files},indent=2),encoding="utf8")
    print(json.dumps({"runtime":str(root),"files":len(files)}))


if __name__=="__main__":main()
