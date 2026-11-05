"""Native cross-file editing through IPC with independent byte expectations."""
import argparse
import json
import pathlib
import shutil
import struct
import subprocess
import tempfile
from test_native_data import expected

ROOT=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--exe',type=pathlib.Path,default=ROOT/'target/debug/shodan-native.exe')
args=parser.parse_args()

def table(data,kind,stride,id_at=0):
    block=next(b for b in expected(data)if b['type']==kind)
    base=block['payload_offset'];count=struct.unpack_from('<I',data,base+8)[0]
    assert struct.unpack_from('<I',data,base+12)[0]==0
    return {struct.unpack_from('<I',data,base+16+i*stride+id_at)[0]:base+16+i*stride for i in range(count)}

projectile_source=ROOT/'offline/originals/generated_projectile_settings.dl_plain'
damage_source=ROOT/'offline/originals/generated_damage_settings.dl_plain'
projectiles=projectile_source.read_bytes();damage=damage_source.read_bytes()
pa=table(projectiles,'BD4042C2',272)[67]
damage_rows=table(damage,'E0A72CF0',76);damage_id=min(damage_rows);da=damage_rows[damage_id]
loaded=bytearray(projectiles);struct.pack_into('<f',loaded,pa+36,4321)
with tempfile.TemporaryDirectory(dir=ROOT/'dist/build-temp-r19',prefix='native-workspace-')as folder:
    folder=pathlib.Path(folder);exe=folder/'shodan-native.exe';shutil.copy2(args.exe,exe)
    paths=[folder/'projectiles.plain',folder/'damage.plain']
    paths[0].write_bytes(loaded);paths[1].write_bytes(damage)
    process=subprocess.Popen([str(exe),'--stdio'],cwd=folder,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,encoding='utf8')
    def call(method,ok=True,**params):
        process.stdin.write(json.dumps(dict(id=method,method=method,params=params))+'\n');process.stdin.flush()
        response=json.loads(process.stdout.readline());assert response['ok']==ok,response
        return response.get('result',response.get('error'))
    def field(name,typ,record,offset,encoding):
        return dict(file=name,type=typ,record=record,relative=offset,encoding=encoding)
    p=lambda offset,codec:field('projectiles','BD4042C2','id:67',offset,codec)
    d=lambda offset,codec:field('damage','E0A72CF0',f'id:{damage_id}',offset,codec)
    mass=p(36,'f32');gravity=p(44,'f32')
    loaded_ref=struct.unpack_from('<Q',loaded,pa+8)[0]
    other_ref=0xF1020304FEDCBA98
    picker_id=281419116899681
    ref=p(8,dict(kind='reference',entries={'0':f'{loaded_ref:016x}',str(picker_id):f'{other_ref:016x}'}))
    fields=[mass,gravity,p(244,dict(kind='flag',width=2,mask=16)),p(246,'u16'),p(250,'u8'),ref,d(4,'u32')]
    edits=[dict(field=f,value=v)for f,v in zip(fields,[1000000,-2.5,1,65534,254,picker_id,12345])]
    try:
        opened=call('workspace-open',files=[dict(name=n,path=str(path),baseline_path=str(base),baseline_name=base.name)
                for n,path,base in zip(['projectiles','damage'],paths,[projectile_source,damage_source])])
        assert not opened['problems'],opened
        before=call('workspace-get',**mass)
        assert before['value']==4321 and before['original']==struct.unpack_from('<f',projectiles,pa+36)[0]
        call('workspace-apply',values=edits,metadata={'armor':{'selected':[1,7]}})
        assert call('workspace-history')==dict(undo=1,redo=0)
        assert [v['value']for v in call('workspace-read-batch',fields=fields)]==[e['value']for e in edits]
        wanted=bytearray(loaded);struct.pack_into('<ff',wanted,pa+36,1000000,struct.unpack_from('<f',loaded,pa+40)[0])
        struct.pack_into('<f',wanted,pa+44,-2.5)
        struct.pack_into('<H',wanted,pa+244,struct.unpack_from('<H',wanted,pa+244)[0]|16)
        struct.pack_into('<H',wanted,pa+246,65534);wanted[pa+250]=254;struct.pack_into('<Q',wanted,pa+8,other_ref)
        wanted_damage=bytearray(damage);struct.pack_into('<I',wanted_damage,da+4,12345)
        output=folder/'edited';call('workspace-export-copy',output=str(output))
        assert (output/'projectiles.dl_plain').read_bytes()==wanted
        assert (output/'damage.dl_plain').read_bytes()==wanted_damage
        call('workspace-export-copy',ok=False,output=str(output))
        previous=call('workspace-preview')
        call('workspace-apply',ok=False,values=[dict(field=mass,value=5),dict(field=d(75,'u32'),value=1)],metadata={'armor':None})
        assert call('workspace-preview')==previous
        call('workspace-apply',ok=False,values=[dict(field=mass,value=5),dict(field=mass,value=6)])
        assert call('workspace-preview')==previous
        assert call('workspace-undo')is True
        assert call('workspace-get',**mass)['value']==4321
        assert call('workspace-preview')['metadata']is None
        call('workspace-apply',values=[])
        call('workspace-apply',ok=False,values=[dict(field=mass,value=1e100)])
        assert call('workspace-history')==dict(undo=0,redo=1)
        assert call('workspace-redo')is True
        assert call('workspace-preview')==previous
        call('workspace-restore',**mass)
        assert call('workspace-get',**mass)['value']==before['original']
        call('workspace-open',ok=False,files=[dict(name='same',path=str(paths[0])),dict(name='SAME',path=str(paths[1]))])
        assert call('workspace-get',**mass)['value']==before['original']
        paths[1].write_bytes(damage+b'changed externally')
        stale=folder/'stale';call('workspace-export-copy',ok=False,output=str(stale));assert not stale.exists()
        assert paths[0].read_bytes()==loaded
    finally:
        process.stdin.close();assert process.wait(timeout=10)==0
assert projectile_source.read_bytes()==projectiles and damage_source.read_bytes()==damage
print('Native workspace: cross-file exact bytes, bool masks, full64 refs, trusted defaults, joint history, rollback, stale-source protection passed; game writes 0')
