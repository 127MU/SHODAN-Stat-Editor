"""Single resource overrides and rebuilds of a resident patch: synthetic packages, temporary files."""
import pathlib,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
from lupa.luajit21 import LuaRuntime

# The fixture packages are built by res_patch itself, so the bytes under test are the bytes the module
# writes.  Ids and types are small u64 values: a real 64 bit id does not fit a Lua number, and these
# three packages only have to be told apart from each other.
SETUP = r'''
M=require('res_patch');I=M._internal;host='9ba626afa44a3aa3'
ctx={root=root,profile=root}
assert(M.write_file(root..'/bundles.nxa','fixture'))

local function hex(n)return string.format('%016x',n)end
T1,T2,T3=hex(0x11),hex(0x22),hex(0x33)
A_ID,B_ID,C_ID,D_ID=hex(0xcbfe1fc7),hex(0x0a1b2c3d),hex(0x0deadbee),hex(0x05f00d01)
SRC_A,SRC_B='STATE_MACHINE_V1____','other light resource'
GPU_B,STREAM_B='GPU_RESOURCES_BYTE','STREAM_BYTES_HERE'
NEW_A,NEW_A2,NEW_C='STATE_MACHINE_V2_EDITED','STATE_MACHINE_V3_REBUILT','type_two_light_edited'

local function ent(id,kind)local raw=I.u64(id)
  return{id_raw=raw,type_raw=I.u64(kind),type_hex=hex(kind),
         unknown1_raw=raw,unknown2_raw=raw,unknown3=0,unknown4=0}end
local function typ(kind,count)
  return{unknown_raw=I.u64(0),type_raw=I.u64(kind),type_hex=hex(kind),
         num_files=count,tail_a=16,tail_b=64}end
local function spec_of(types)
  return{magic=0xF0000011,unknown=3,trailing=string.rep('\0',56),types=types}end

local set={packages={},heads={}}
local bundle=0
local function add(n,text)
  bundle=bundle+1
  set.packages[n]={size=#text,items={{off=0,uoff=0,bundle=bundle}}}
  set.heads[bundle]={cache={[1]=text},order={},chunks={{uoff=0,usize=#text}}}
end

-- pkg_a: the state machine (light) next to one heavy entry of the same type.
local toc_a,gpu_a,stream_a=I.build_package(spec_of({typ(0x11,2)}),{
  {entry=ent(0xcbfe1fc7,0x11),toc=SRC_A,gpu='',stream=''},
  {entry=ent(0x0a1b2c3d,0x11),toc=SRC_B,gpu=GPU_B,stream=STREAM_B}})
add('pkg_a',toc_a)
add('pkg_a.gpu_resources',gpu_a)
add('pkg_a.stream',stream_a)

-- pkg_two: one entry of each of two types, for the type filter.
local toc_two=I.build_package(spec_of({typ(0x22,1),typ(0x33,1)}),{
  {entry=ent(0x0deadbee,0x22),toc='type_two_light',gpu='',stream=''},
  {entry=ent(0x05f00d01,0x33),toc='type_three_light',gpu='',stream=''}})
add('pkg_two',toc_two)

-- pkg_three: one more light package, to show the slots below a removed patch moving down.
local toc_three=I.build_package(spec_of({typ(0x11,1)}),
  {{entry=ent(0xcbfe1fc7,0x11),toc='THIRD_PACKAGE_LIGHT',gpu='',stream=''}})
add('pkg_three',toc_three)

-- pkg_dup: one id reused three times, the way a real package carries the bones, the state machine and
-- the mesh of the same entity.  A bare id here has no single meaning, so it must be refused.
T_BONE,T_MESH=hex(0x18),hex(0x48)
DUP_ID=hex(0x77aa11bb)
BONES_DUP='bones_of_the_same_entity'
SM_DUP,NEW_SM_DUP='STATE_MACHINE_BYTES_v1','STATE_MACHINE_BYTES_v2'
local toc_dup,gpu_dup,stream_dup=I.build_package(
  spec_of({typ(0x18,1),typ(0x11,1),typ(0x48,1)}),{
    {entry=ent(0x77aa11bb,0x18),toc=BONES_DUP,gpu='',stream=''},
    {entry=ent(0x77aa11bb,0x11),toc=SM_DUP,gpu='',stream=''},
    {entry=ent(0x77aa11bb,0x48),toc='mesh_toc_bytes',gpu='MESH_GPU_BYTES',stream='MESH_STREAM_BYTES'}})
add('pkg_dup',toc_dup)
add('pkg_dup.gpu_resources',gpu_dup)
add('pkg_dup.stream',stream_dup)

ctx.set=set

function path(n,suffix)return root..'/'..host..'.patch_'..n..(suffix or '')end
-- everything a refused call must leave alone: the files of the first nine slots plus the ledger
function snapshot()
  local t={}
  for n=0,8 do for _,s in ipairs({'','.gpu_resources','.stream'})do
    local p=path(n,s);t[#t+1]=p..'='..tostring(M.read_file(p))end end
  t[#t+1]='ledger='..tostring(M.read_file(M.ledger_path(ctx)))
  return table.concat(t,'|')
end
-- a written patch read back through the module's own package reader
function parse_patch(n)
  local bytes=assert(M.read_file(path(n)))
  local reader={packages={},heads={}}
  reader.packages['check']={size=#bytes,items={{off=0,uoff=0,bundle=0}}}
  reader.heads[0]={cache={[1]=bytes},order={},chunks={{uoff=0,usize=#bytes}}}
  return assert(I.package_head(reader,'check')),reader
end
function toc_of(spec,reader,id)
  for _,entry in ipairs(spec.entries)do
    if entry.id_hex==id then return I.package_read(reader,'check',entry.toc_at,entry.toc_size)end
  end
end
function toc_of2(spec,reader,type_hex,id)
  for _,entry in ipairs(spec.entries)do
    if entry.type_hex==type_hex and entry.id_hex==id then
      return I.package_read(reader,'check',entry.toc_at,entry.toc_size)
    end
  end
end
'''

class ResourceOverrideTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
  self.lua=LuaRuntime();self.lua.globals().root=self.temp.name.replace('\\','/')
  self.lua.execute("package.path="+repr((ROOT/'offline/?.lua').as_posix())+"..';'..package.path")
  self.lua.execute(SETUP)
 def check(self,code):
  """One Lua assertion block; a failed assert surfaces as a LuaError with its line."""
  self.lua.execute(code)
 def test_res_patch_holds_only_the_overridden_entry(self):
  self.check(r'''
local info=assert(M.install_with(ctx,host,'pkg_a','res',{[A_ID]=NEW_A}))
assert(info.index==0 and info.entries==1 and info.mode=='res')
assert(info.toc==M.file_size(path(0)) and info.gpu==0 and info.stream==0)
local spec,reader=parse_patch(0)
assert(#spec.entries==1 and spec.entries[1].id_hex==A_ID)
assert(toc_of(spec,reader,A_ID)==NEW_A)
-- the source header fields are carried over, and the package keeps no empty type of its own
assert(spec.unknown==3 and spec.trailing==string.rep('\0',56))
assert(#spec.types==1 and spec.types[1].type_hex==T1 and spec.types[1].num_files==1)
-- nothing else on disk: no side files, no second slot
assert(M.file_size(path(0)..'.gpu_resources')==nil and M.file_size(path(0)..'.stream')==nil)
assert(M.file_size(path(1))==nil and M.file_size(path(2))==nil)
local entry=assert(M.patch_of(ctx,host,'pkg_a'))
assert(entry.index==0 and entry.name=='pkg_a' and entry.mode=='res' and entry.built==1)
-- the standalone entry point: package_slices takes the same override map
local src=assert(I.package_head(ctx.set,'pkg_a'))
local blobs=assert(I.package_slices(ctx.set,'pkg_a',src,false,{[A_ID]=NEW_A}))
assert(#blobs==1 and blobs[1].entry.id_hex==A_ID and blobs[1].toc==NEW_A)
''')
 def test_full_rebuild_keeps_slot_entries_and_neighbours(self):
  self.check(r'''
local first=assert(M.install(ctx,host,'pkg_a','full'))
assert(first.index==0 and first.entries==2 and first.gpu==#GPU_B and first.stream==#STREAM_B)
local second=assert(M.install_with(ctx,host,'pkg_a','full',{[A_ID]=NEW_A2}))
assert(second.index==0 and second.entries==2 and second.mode=='full')
local spec,reader=parse_patch(0)
assert(#spec.entries==2)
assert(toc_of(spec,reader,A_ID)==NEW_A2)
assert(toc_of(spec,reader,B_ID)==SRC_B)
assert(M.read_file(path(0)..'.gpu_resources')==GPU_B)
assert(M.read_file(path(0)..'.stream')==STREAM_B)
assert(#M.read_ledger(ctx)==1 and M.state(ctx,host,'pkg_a')==1)
assert(M.file_size(path(1))==nil)
-- a nil mode keeps the mode the package already has, and an empty map rebuilds the source bytes
local third=assert(M.install_with(ctx,host,'pkg_a',nil,{}))
assert(third.mode=='full' and third.index==0 and third.entries==2)
local again,again_reader=parse_patch(0)
assert(toc_of(again,again_reader,A_ID)==SRC_A)
assert(toc_of(again,again_reader,B_ID)==SRC_B)
''')
 def test_light_rebuild_carries_the_override(self):
  self.check(r'''
local info=assert(M.install_with(ctx,host,'pkg_a','light',{[A_ID]=NEW_A}))
assert(info.index==0 and info.entries==1 and info.mode=='light')
assert(M.state(ctx,host,'pkg_a')==2)
local spec,reader=parse_patch(0)
assert(#spec.entries==1 and toc_of(spec,reader,A_ID)==NEW_A)
assert(M.file_size(path(0)..'.gpu_resources')==nil and M.file_size(path(0)..'.stream')==nil)
''')
 def test_state_reports_a_res_patch_as_not_installed(self):
  self.check(r'''
assert(M.install_with(ctx,host,'pkg_a','res',{[A_ID]=NEW_A}))
assert(M.file_size(path(0))~=nil)
assert(M.state(ctx,host,'pkg_a')==0)
assert(assert(M.patch_of(ctx,host,'pkg_a')).mode=='res')
assert(M.patch_of(ctx,host,'pkg_two')==nil)
assert(M.state(ctx,host,'pkg_two')==0)
''')
 def test_revert_removes_a_res_patch_and_shifts_later_slots(self):
  self.check(r'''
assert(M.install(ctx,host,'pkg_a','full'))
assert(M.install_with(ctx,host,'pkg_two','res',{[C_ID]=NEW_C}))
assert(M.install(ctx,host,'pkg_three','light'))
assert(assert(M.patch_of(ctx,host,'pkg_three')).index==2)
local moved=M.read_file(path(2))
assert(M.revert(ctx,host,'pkg_two'))
assert(M.patch_of(ctx,host,'pkg_two')==nil and M.state(ctx,host,'pkg_two')==0)
assert(M.file_size(path(2))==nil)
assert(assert(M.patch_of(ctx,host,'pkg_three')).index==1)
assert(M.read_file(path(1))==moved)
assert(M.read_file(path(0))~=nil)
assert(#M.read_ledger(ctx)==2)
-- nothing installed means nothing to revert
local ok,why=M.revert(ctx,host,'pkg_two')
assert(not ok and why)
''')
 def test_revert_rebuilds_a_resident_patch_from_the_source(self):
  self.check(r'''
assert(M.install(ctx,host,'pkg_a','full'))
assert(M.install_with(ctx,host,'pkg_a','full',{[A_ID]=NEW_A}))
local spec,reader=parse_patch(0)
assert(toc_of(spec,reader,A_ID)==NEW_A)
assert(M.revert(ctx,host,'pkg_a'))
assert(M.state(ctx,host,'pkg_a')==1)
local back,back_reader=parse_patch(0)
assert(#back.entries==2)
assert(toc_of(back,back_reader,A_ID)==SRC_A and toc_of(back,back_reader,B_ID)==SRC_B)
assert(M.read_file(path(0)..'.gpu_resources')==GPU_B)
assert(M.read_file(path(0)..'.stream')==STREAM_B)
-- a light patch stays a light patch
assert(M.install_with(ctx,host,'pkg_a','light',{[A_ID]=NEW_A}))
assert(M.revert(ctx,host,'pkg_a'))
assert(M.state(ctx,host,'pkg_a')==2)
local light,light_reader=parse_patch(0)
assert(#light.entries==1 and toc_of(light,light_reader,A_ID)==SRC_A)
''')
 def test_entries_of_type_and_read_entry(self):
  self.check(r'''
local both=assert(M.entries_of_type(ctx,'pkg_a',T1))
assert(#both==2)
assert(both[1].id_hex==A_ID and both[1].toc_size==#SRC_A)
assert(both[1].gpu_size==0 and both[1].stream_size==0)
assert(both[2].id_hex==B_ID and both[2].toc_size==#SRC_B)
assert(both[2].gpu_size==#GPU_B and both[2].stream_size==#STREAM_B)
-- the type is matched regardless of case, and the other package filters on its own types
local two=assert(M.entries_of_type(ctx,'pkg_two',T2:upper()))
assert(#two==1 and two[1].id_hex==C_ID and two[1].toc_size==#'type_two_light')
local three=assert(M.entries_of_type(ctx,'pkg_two',T3))
assert(#three==1 and three[1].id_hex==D_ID)
assert(#assert(M.entries_of_type(ctx,'pkg_two',T1))==0)
assert(M.read_entry(ctx,'pkg_two',C_ID)=='type_two_light')
assert(M.read_entry(ctx,'pkg_a',A_ID)==SRC_A)
assert(M.read_entry(ctx,'pkg_a',B_ID)==SRC_B)
local bytes,why=M.read_entry(ctx,'pkg_a',D_ID)
assert(bytes==nil and why)
local missing,missing_why=M.entries_of_type(ctx,'pkg_missing',T1)
assert(missing==nil and missing_why=='当前游戏中找不到资源包：pkg_missing')
''')
 def test_res_rejections_never_write(self):
  self.check(r'''
local before=snapshot()
local ok,why=M.install_with(ctx,host,'pkg_a','res',nil)
assert(not ok and why=='没有要写入的资源')
ok,why=M.install_with(ctx,host,'pkg_a','res',{})
assert(not ok and why=='没有要写入的资源')
ok,why=M.install(ctx,host,'pkg_a','res')
assert(not ok and why=='无效的资源驻留模式')
-- an id the package does not hold, and one that carries its own stream
ok,why=M.install_with(ctx,host,'pkg_a','res',{[C_ID]=NEW_C})
assert(not ok and why)
ok,why=M.install_with(ctx,host,'pkg_a','res',{[B_ID]='new heavy bytes'})
assert(not ok and why)
-- an override map must hold bytes, not numbers
ok,why=M.install_with(ctx,host,'pkg_a','full',{[A_ID]=12})
assert(not ok and why)
assert(snapshot()==before)
assert(#M.read_ledger(ctx)==0)
assert(M.state(ctx,host,'pkg_a')==0)
''')
 def test_read_entry_picks_the_entry_of_the_requested_type(self):
  self.check(r'''
-- a bare id still means the first entry, which is what the older panel code relies on
assert(M.read_entry(ctx,'pkg_dup',DUP_ID)==BONES_DUP)
-- with the type it is the state machine, not the bones that share its id
local sm=assert(M.read_entry(ctx,'pkg_dup',DUP_ID,T1))
assert(sm==SM_DUP and #sm==#SM_DUP)
assert(M.read_entry(ctx,'pkg_dup',DUP_ID,T_BONE)==BONES_DUP)
assert(M.read_entry(ctx,'pkg_dup',DUP_ID,T_MESH)=='mesh_toc_bytes')
-- type and id are accepted in either case
assert(M.read_entry(ctx,'pkg_dup',DUP_ID:upper(),T1:upper())==SM_DUP)
-- an entry the package does not hold says which pair it looked for
local missing,why=M.read_entry(ctx,'pkg_dup',DUP_ID,T2)
assert(missing==nil and why:find(T2,1,true) and why:find(DUP_ID,1,true))
-- entries_of_type hands out the type, because that is half of an override key
local list=assert(M.entries_of_type(ctx,'pkg_dup',T1))
assert(#list==1 and list[1].type_hex==T1 and list[1].id_hex==DUP_ID)
local all=assert(M.entries_of_type(ctx,'pkg_dup',T_MESH))
assert(#all==1 and all[1].type_hex==T_MESH and all[1].gpu_size==#'MESH_GPU_BYTES')
''')
 def test_bare_id_override_refuses_a_repeated_id(self):
  self.check(r'''
local before=snapshot()
local ok,why=M.install_with(ctx,host,'pkg_dup','res',{[DUP_ID]=NEW_SM_DUP})
assert(not ok and why:find('出现多次',1,true) and why:find(DUP_ID,1,true))
assert(snapshot()==before and #M.read_ledger(ctx)==0)
-- the same refusal on a resident rebuild, where it would otherwise rewrite all three entries
ok,why=M.install_with(ctx,host,'pkg_dup','full',{[DUP_ID]=NEW_SM_DUP})
assert(not ok and why:find('出现多次',1,true))
assert(snapshot()==before and M.state(ctx,host,'pkg_dup')==0)
-- and straight through the slice function
local src=assert(I.package_head(ctx.set,'pkg_dup'))
local blobs,slice_why=I.package_slices(ctx.set,'pkg_dup',src,false,{[DUP_ID]=NEW_SM_DUP})
assert(blobs==nil and slice_why:find('出现多次',1,true))
-- a unique id keeps working without a type
ok,why=M.install_with(ctx,host,'pkg_a','res',{[A_ID]=NEW_A})
assert(ok and ok.entries==1)
''')
 def test_type_id_override_touches_only_that_entry(self):
  self.check(r'''
local key=T1..':'..DUP_ID
local info=assert(M.install_with(ctx,host,'pkg_dup','full',{[key]=NEW_SM_DUP}))
assert(info.index==0 and info.entries==3 and info.mode=='full')
local spec,reader=parse_patch(0)
assert(#spec.entries==3)
assert(toc_of2(spec,reader,T1,DUP_ID)==NEW_SM_DUP)
-- the other two entries of the same id keep the bytes the package holds, side files included
assert(toc_of2(spec,reader,T_BONE,DUP_ID)==BONES_DUP)
assert(toc_of2(spec,reader,T_MESH,DUP_ID)=='mesh_toc_bytes')
assert(M.read_file(path(0)..'.gpu_resources')=='MESH_GPU_BYTES')
assert(M.read_file(path(0)..'.stream')=='MESH_STREAM_BYTES')
-- and the source package was only read
assert(M.read_entry(ctx,'pkg_dup',DUP_ID,T1)==SM_DUP)
assert(M.read_entry(ctx,'pkg_dup',DUP_ID,T_BONE)==BONES_DUP)
assert(M.read_entry(ctx,'pkg_dup',DUP_ID,T_MESH)=='mesh_toc_bytes')
-- a 'res' patch keyed the same way carries just that one entry
assert(M.revert(ctx,host,'pkg_dup'))
local one=assert(M.install_with(ctx,host,'pkg_dup','res',{[key]=NEW_SM_DUP}))
assert(one.index==0 and one.entries==1)
local res_spec,res_reader=parse_patch(0)
assert(#res_spec.entries==1 and res_spec.entries[1].type_hex==T1)
assert(toc_of2(res_spec,res_reader,T1,DUP_ID)==NEW_SM_DUP)
''')
 def test_patch_entry_reads_back_our_own_slot(self):
  self.check(r'''
-- nothing installed yet: the panel gets a plain refusal, not an error
local no_spec,no_spec_why=M.patch_spec(ctx,host,'pkg_dup')
assert(no_spec==nil and no_spec_why=='未安装')
local no_bytes,no_bytes_why=M.patch_entry(ctx,host,'pkg_dup',DUP_ID,T1)
assert(no_bytes==nil and no_bytes_why=='未安装')
-- a full rebuild of the three entry package reads back entry by entry
local key=T1..':'..DUP_ID
local full=assert(M.install_with(ctx,host,'pkg_dup','full',{[key]=NEW_SM_DUP}))
assert(full.index==0 and full.entries==3 and full.mode=='full')
local spec,spec_why=M.patch_spec(ctx,host,'pkg_dup')
assert(spec,spec_why)
assert(#spec.entries==3 and #spec.types==3 and spec.name=='pkg_dup')
assert(M.patch_entry(ctx,host,'pkg_dup',DUP_ID,T1)==NEW_SM_DUP)
assert(M.patch_entry(ctx,host,'pkg_dup',DUP_ID,T_BONE)==BONES_DUP)
assert(M.patch_entry(ctx,host,'pkg_dup',DUP_ID,T_MESH)=='mesh_toc_bytes')
-- a bare id in a patch holding that id three times is refused, not guessed
local bare,bare_why=M.patch_entry(ctx,host,'pkg_dup',DUP_ID)
assert(bare==nil and bare_why:find('出现多次',1,true))
local ghost,ghost_why=M.patch_entry(ctx,host,'pkg_dup',A_ID,T1)
assert(ghost==nil and ghost_why:find('补丁中找不到这条资源',1,true))
-- the same slot switched to a 'res' patch holds one entry, so its id is unambiguous
local res=assert(M.install_with(ctx,host,'pkg_dup','res',{[key]=NEW_SM_DUP}))
assert(res.index==0 and res.entries==1)
local res_spec,res_why=M.patch_spec(ctx,host,'pkg_dup')
assert(res_spec,res_why)
assert(#res_spec.entries==1 and #res_spec.types==1)
assert(M.patch_entry(ctx,host,'pkg_dup',DUP_ID)==NEW_SM_DUP)
assert(M.patch_entry(ctx,host,'pkg_dup',DUP_ID,T1)==NEW_SM_DUP)
assert(M.file_size(path(0)..'.gpu_resources')==nil and M.file_size(path(0)..'.stream')==nil)
-- a truncated or vanished slot file is a refusal, never a crash
local whole=assert(M.read_file(path(0)))
assert(M.write_file(path(0),whole:sub(1,10)))
local short,short_why=M.patch_spec(ctx,host,'pkg_dup')
assert(short==nil and short_why:find('长度不足',1,true))
assert(os.remove(path(0)))
local gone,gone_why=M.patch_entry(ctx,host,'pkg_dup',DUP_ID,T1)
assert(gone==nil and gone_why:find('补丁文件读不到',1,true))
''')
 def test_entry_updates_preserve_other_changes_and_residency(self):
  self.check("""assert(M.update_entry(ctx,host,'pkg_two','res',C_ID,T2,NEW_C))
assert(M.update_entry(ctx,host,'pkg_two','res',D_ID,T3,'SECOND_EDIT'))
assert(M.patch_entry(ctx,host,'pkg_two',C_ID,T2)==NEW_C)
assert(M.patch_entry(ctx,host,'pkg_two',D_ID,T3)=='SECOND_EDIT')
assert(M.revert_entry(ctx,host,'pkg_two',C_ID,T2))
assert(M.patch_entry(ctx,host,'pkg_two',D_ID,T3)=='SECOND_EDIT')
assert(M.install(ctx,host,'pkg_two','full'))
assert(M.patch_entry(ctx,host,'pkg_two',D_ID,T3)=='SECOND_EDIT')
assert(M.patch_entry(ctx,host,'pkg_two',C_ID,T2)=='type_two_light')
assert(M.revert_entry(ctx,host,'pkg_two',D_ID,T3))
assert(M.state(ctx,host,'pkg_two')==1)
assert(M.patch_entry(ctx,host,'pkg_two',D_ID,T3)=='type_three_light')""")
 def test_last_entry_removal_only_removes_resource_patch(self):
  self.check("""assert(M.update_entry(ctx,host,'pkg_two','res',C_ID,T2,NEW_C))
assert(M.revert_entry(ctx,host,'pkg_two',C_ID,T2))
assert(M.entry_of(ctx,host,'pkg_two')==nil)
assert(M.file_size(path(0))==nil)""")
 def test_unreadable_patch_is_not_discarded_by_update(self):
  self.check("""assert(M.update_entry(ctx,host,'pkg_two','res',C_ID,T2,NEW_C))
local before=snapshot();local read=M.read_file
M.read_file=function(p)if p==path(0)then return nil,'blocked read'end;return read(p)end
local ok,why=M.update_entry(ctx,host,'pkg_two','res',D_ID,T3,'SECOND_EDIT')
M.read_file=read;assert(not ok and why:find('blocked read',1,true));assert(snapshot()==before)""")
 def test_deleted_patch_ledger_rebuilds_at_next_real_slot(self):
  self.check("""assert(M.install(ctx,host,'pkg_a','full'))
for _,suffix in ipairs({'','.gpu_resources','.stream'})do assert(os.remove(path(0,suffix)))end
-- The old ledger can refer to a slot from a different installation.
local entries=M.read_ledger(ctx);entries[1].index=248;assert(M.write_ledger(ctx,entries))
local rebuilt=assert(M.install(ctx,host,'pkg_a','full'))
assert(rebuilt.index==0 and M.entry_of(ctx,host,'pkg_a').index==0)
assert(M.patch_entry(ctx,host,'pkg_a',A_ID)==SRC_A)
assert(M.file_size(path(248))==nil)""")
 def test_partial_patch_set_is_not_treated_as_deleted(self):
  self.check("""assert(M.install(ctx,host,'pkg_a','full'));assert(os.remove(path(0)))
local before=snapshot();local ok,why=M.install(ctx,host,'pkg_a','full')
assert(not ok and why:find('补丁文件读不到',1,true));assert(snapshot()==before)""")
 def test_deleted_entry_removal_does_not_move_foreign_patch(self):
  self.check("""assert(M.install(ctx,host,'pkg_two','light'));assert(os.remove(path(0)))
assert(M.write_file(path(1),'FOREIGN_PATCH'))
assert(M.remove(ctx,host,'pkg_two'))
assert(M.read_file(path(1))=='FOREIGN_PATCH' and not M.entry_of(ctx,host,'pkg_two'))""")
if __name__=='__main__':unittest.main()
