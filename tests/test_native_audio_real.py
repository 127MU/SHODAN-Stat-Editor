"""Read-only audio provider comparison with an independent HIRC byte parser."""
import argparse,json,pathlib,struct,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--root',type=pathlib.Path,required=True);a=p.parse_args()
sys.path.insert(0,str(ROOT.parent/'hd2-hud-plus-repair/vendor'))
from lupa.luajit21 import LuaRuntime
lua=LuaRuntime(encoding=None,unpack_returned_tuples=True)
module=lua.execute((ROOT/'offline/res_patch.lua').read_bytes())[b'_internal']
bundle=module[b'bundle_index'](a.root.as_posix().encode());assert not isinstance(bundle,tuple),bundle
sample=None
for _,name in sorted(bundle[b'names'].items()):
    if len(name)!=16:continue
    head=module[b'package_head'](bundle,name);assert not isinstance(head,tuple),head
    for _,entry in head[b'entries'].items():
        if entry[b'type_hex']!=b'535a7bd3e650d799':continue
        size=entry[b'toc_size'];base=entry[b'toc_at']
        def read(at,n):
            b=module[b'package_read'](bundle,name,base+at,n);assert isinstance(b,bytes),b;return b
        first=read(0,min(size,24));at=0 if first.startswith(b'BKHD') else 16
        if first[at:at+4]!=b'BKHD':continue
        event=None
        while at+8<=size:
            chunk=read(at,8);n=struct.unpack_from('<I',chunk,4)[0]
            if at+8+n>size:break
            if chunk[:4]==b'HIRC':
                data=read(at+8,n);pos=4
                for _ in range(struct.unpack_from('<I',data)[0]):
                    kind=data[pos];length=struct.unpack_from('<I',data,pos+1)[0]
                    assert length>=4 and pos+5+length<=len(data)
                    if kind==4:event=struct.unpack_from('<I',data,pos+5)[0];break
                    pos+=5+length
                break
            at+=8+n
        if event:sample=(name.decode(),entry[b'id_hex'].decode(),event);break
    if sample:break
assert sample,'No bank event found in the installed archive set'
name,identity,event=sample
request=dict(id=1,method='resources-resolve',params=dict(root=str(a.root),preferred=[name],resources=[dict(type='535a7bd3e650d799',id=identity)],events=[event]))
run=subprocess.run([str(ROOT/'target/release/shodan-native.exe'),'--stdio'],input=json.dumps(request)+'\n',text=True,encoding='utf8',capture_output=True,timeout=60,check=True)
result=json.loads(run.stdout);assert result['ok'],result
result=result['result'];assert result['missing_resources']==[] and result['missing_events']==[],result
assert result['packages']==[name],result
print('Native audio: real HIRC event and full-width bank identity match independent byte parser; game writes 0')
