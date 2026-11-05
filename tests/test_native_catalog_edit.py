"""Logical row formulas and joint history on independently specified bytes."""
import gzip
import json
import pathlib
import shutil
import struct
import subprocess
import tempfile
from test_native_data import expected

def table(data,kind,stride):
    block=next(b for b in expected(data)if b['type']==kind);base=block['payload_offset']
    return {struct.unpack_from('<I',data,base+16+i*stride)[0]:base+16+i*stride for i in range(struct.unpack_from('<I',data,base+8)[0])}

ROOT=pathlib.Path(__file__).resolve().parents[1]
source=ROOT/'offline/originals/generated_projectile_settings.dl_plain';original=source.read_bytes();at=table(original,'BD4042C2',272)[67]
owner='FFFFFFFFFFFFFFFF'
def field(key,offset,storage,**extra):
    return dict(key=key,storage=storage,bindings=[dict(file='projectiles',type='BD4042C2',record='id:67',relative=offset)],encoding=storage,**extra)
fields=[field('mass',36,'f32'),field('gravity',44,'f32'),field('rate',40,'f32'),
        dict(key='0:mult:test',storage='virtual',bindings=[],virtual_default=1),field('noise',4,'u32'),field('silent',250,'flag')]
fields[-1]['encoding']='bool'
def row(key,parts,storage='f32',**extra):
    return dict(id=key,key=key,label=key,section='test',storage=storage,parts=[dict(id=fields[p]['key'],field=p)for p in parts],**extra)
rows=[row('mass',[0]),row('gravity',[1]),row('time',[2],span={'op':'field','field':0}),
      row('mult',[3,0],lead=True,mult=True),row('inverse',[3,0],lead=True,mult=True,inverse=True),
      row('suppressed',[5,4],storage='flag',lead=True,suppression=True),row('swap',[0],choice=True)]
catalog=dict(format='SHODAN-NATIVE-DESCRIPTORS',version=1,owners=[dict(id=owner,name='测试',english='Test',tab='Primary',rows=rows)],fields=fields)
with tempfile.TemporaryDirectory(dir=ROOT/'dist/build-temp-r19',prefix='native-row-edit-')as folder:
    folder=pathlib.Path(folder);exe=folder/'shodan-native.exe';shutil.copy2(ROOT/'target/debug/shodan-native.exe',exe)
    path=folder/'input.plain';loaded=bytearray(original);struct.pack_into('<ff',loaded,at+36,4321,2);loaded[at+250]=0
    path.write_bytes(loaded);description=folder/'catalog.gz';description.write_bytes(gzip.compress(json.dumps(catalog).encode()))
    process=subprocess.Popen([str(exe),'--stdio'],cwd=folder,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,encoding='utf8')
    def call(method,ok=True,**params):
        process.stdin.write(json.dumps(dict(id=method,method=method,params=params))+'\n');process.stdin.flush();result=json.loads(process.stdout.readline());assert result['ok']==ok,result
        return result.get('result',result.get('error'))
    def current(key):return next(r['value']for r in call('catalog-read-rows',owner=owner)if r['parameter']==key)
    def edit(key,value):return call('catalog-set',owner=owner,key=key,value=value)
    def exported(name):
        target=folder/name;call('workspace-export-copy',output=str(target));return (target/'projectiles.dl_plain').read_bytes()
    try:
        call('catalog-load',path=str(description))
        call('workspace-open',files=[dict(name='projectiles',path=str(path),baseline_path=str(source),baseline_name=source.name)])
        assert current('mass')==4321
        before=call('workspace-preview');preview=call('catalog-edit-preview',owner=owner,key='mass',value=1000000)
        assert preview['applied']is False and call('workspace-preview')==before
        edit('mass',1000000);edit('gravity',-2.5)
        wanted=bytearray(loaded);struct.pack_into('<f',wanted,at+36,1000000);struct.pack_into('<f',wanted,at+44,-2.5)
        assert exported('numeric')==wanted
        edit('time',8);struct.pack_into('<f',wanted,at+40,1000000/8)
        assert current('time')==8 and exported('time')==wanted
        original_mass=struct.unpack_from('<f',original,at+36)[0]
        edit('mult',2);struct.pack_into('<f',wanted,at+36,original_mass*2)
        assert current('mult')==2 and exported('mult')==wanted
        assert call('workspace-undo')is True and current('mass')==1000000 and current('mult')==1
        assert call('workspace-redo')is True and current('mult')==2
        previous=call('workspace-preview');call('catalog-set',ok=False,owner=owner,key='inverse',value=0)
        assert call('workspace-preview')==previous
        call('catalog-set',ok=False,owner=owner,key='swap',value=123)
        assert call('workspace-preview')==previous
        call('catalog-restore',owner=owner,key='mult');struct.pack_into('<f',wanted,at+36,original_mass)
        assert current('mult')==1 and exported('restored')==wanted
        # Suppression changes noise and bool together; undo restores both.
        original_noise=struct.unpack_from('<I',original,at+4)[0]
        edit('suppressed',1);struct.pack_into('<I',wanted,at+4,0 if original_noise==0 else 10);wanted[at+250]=1
        assert exported('suppressed')==wanted
        call('workspace-undo');struct.pack_into('<I',wanted,at+4,struct.unpack_from('<I',loaded,at+4)[0]);wanted[at+250]=0
        assert exported('undo-suppressed')==wanted
        call('catalog-set',ok=False,owner=owner,key='mass',value=1e100)
        assert exported('after-failure')==wanted
        assert path.read_bytes()==loaded
    finally:
        process.stdin.close();assert process.wait(timeout=10)==0
print('Native logical rows: exact scaling/rates, inverse failure rollback, suppression, virtual+physical undo, previews and trusted resets passed; game writes 0')
