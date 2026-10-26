"""Resource patch lifecycle against synthetic packages and temporary files only."""
import pathlib,sys,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
from lupa.luajit21 import LuaRuntime

class ResourcePatchTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
  self.lua=LuaRuntime();self.lua.globals().root=self.temp.name.replace('\\','/')
  self.lua.execute("package.path="+repr((ROOT/'offline/?.lua').as_posix())+"..';'..package.path")
  self.lua.execute('''
M=require('res_patch');I=M._internal;host='9ba626afa44a3aa3';name='0123456789abcdef'
ctx={root=root,profile=root}
assert(M.write_file(root..'/bundles.nxa','fixture'))
local raw=I.u64(1)
local entry={id_raw=raw,type_raw=raw,type_hex='0000000000000001',unknown1_raw=raw,unknown2_raw=raw,unknown3=0,unknown4=0}
local spec={magic=0xF0000011,unknown=0,trailing=string.rep('\\0',56),types={}}
local toc,gpu,stream=I.build_package(spec,{{entry=entry,toc='light',gpu='',stream=''},
 {entry=entry,toc='heavy',gpu='gpu',stream='stream'}})
local bytes=toc..gpu..stream
ctx.set={packages={},heads={[0]={cache={[1]=bytes},order={},chunks={{uoff=0,usize=#bytes}}}}}
local function pkg(n,off,size)ctx.set.packages[n]={size=size,items={{off=0,uoff=off,bundle=0}}}end
pkg(name,0,#toc);pkg(name..'.gpu_resources',#toc,#gpu);pkg(name..'.stream',#toc+#gpu,#stream)
function path(n,suffix)return root..'/'..host..'.patch_'..n..(suffix or '')end
function snapshot()local t={};for n=0,5 do for _,s in ipairs({'','.gpu_resources','.stream'})do t[path(n,s)]=M.read_file(path(n,s))end end;t[M.ledger_path(ctx)]=M.read_file(M.ledger_path(ctx));return t end
function unchanged(t)for p,b in pairs(t)do assert(M.read_file(p)==b,p)end end
''')
 def test_full_light_remove(self):
  self.lua.execute('''local a=assert(M.install(ctx,host,name,'full'));assert(a.index==0 and a.entries==2);assert(M.state(ctx,host,name)==1)
assert(M.read_file(path(0,'.gpu_resources'))=='gpu');local b=assert(M.install(ctx,host,name,'light'));assert(b.index==0 and b.entries==1)
assert(M.file_size(path(0,'.gpu_resources'))==nil and M.file_size(path(0,'.stream'))==nil);assert(M.state(ctx,host,name)==2)
assert(M.remove(ctx,host,name));assert(M.state(ctx,host,name)==0 and M.file_size(path(0))==nil)''')
 def test_holes_and_foreign_slots_preserved(self):
  self.lua.execute('''assert(M.write_file(path(2),'foreign'));local before=snapshot();assert(not M.install(ctx,host,name,'full'));unchanged(before)
os.remove(path(2));assert(M.install(ctx,host,name,'full'));assert(M.write_file(path(1),'foreign'));before=snapshot()
assert(not M.remove(ctx,host,name));unchanged(before)''')
 def test_ledger_failure_rolls_back_replacement(self):
  self.lua.execute('''assert(M.install(ctx,host,name,'full'));local before=snapshot();local write=M.write_file;local failed=false
M.write_file=function(p,b)if p==M.ledger_path(ctx) and not failed then failed=true;return false,'injected ledger failure' end;return write(p,b)end
local ok,why=M.install(ctx,host,name,'light');assert(not ok and why=='injected ledger failure');unchanged(before)''')
 def test_sidecar_failure_rolls_back_replacement(self):
  self.lua.execute('''assert(M.install(ctx,host,name,'light'));local before=snapshot();local write=M.write_file;local failed=false
M.write_file=function(p,b)if p==path(0,'.stream') and not failed then failed=true;return false,'injected stream failure' end;return write(p,b)end
assert(not M.install(ctx,host,name,'full'));unchanged(before);assert(M.file_size(path(0,'.gpu_resources'))==nil)''')
 def test_remove_compacts_owned_and_rolls_back_failure(self):
  self.lua.execute('''assert(M.install(ctx,host,name,'full'));local second='1111111111111111';ctx.set.packages[second]=ctx.set.packages[name]
assert(M.install(ctx,host,second,'light'));local before=snapshot();local save=M.write_ledger
M.write_ledger=function()return false,'injected ledger failure'end
assert(not M.remove(ctx,host,name));unchanged(before);M.write_ledger=save
assert(M.remove(ctx,host,name));assert(M.entry_of(ctx,host,second).index==0);assert(M.file_size(path(1))==nil)
assert(M.file_size(path(0,'.stream'))==nil and M.file_size(path(0,'.gpu_resources'))==nil)''')
 def test_unreadable_original_never_overwritten(self):
  self.lua.execute("""assert(M.install(ctx,host,name,'full'));local before=snapshot();local read=M.read_file
M.read_file=function(p)if p==path(0)then return nil,'injected read failure'end;return read(p)end
local ok,why=M.install(ctx,host,name,'light');assert(not ok and why:find('injected read failure',1,true));M.read_file=read;unchanged(before)""")
 def test_exception_rolls_back_replacement(self):
  self.lua.execute("""assert(M.install(ctx,host,name,'full'));local before=snapshot();local write=M.write_file;local failed=false
M.write_file=function(p,b)if p==M.ledger_path(ctx) and not failed then failed=true;error('injected exception')end;return write(p,b)end
assert(not M.install(ctx,host,name,'light'));unchanged(before)""")
 def test_invalid_mode_never_writes(self):
  self.lua.execute("local before=snapshot();assert(not M.install(ctx,host,name,'unknown'));unchanged(before)")
 def test_high_slots_preserved_and_owned_removal_compacts(self):
  self.lua.execute("""for i=0,79 do assert(M.write_file(path(i),'foreign '..i))end
local info=assert(M.install(ctx,host,name,'light'));assert(info.index==80)
assert(M.read_file(path(79))=='foreign 79')
assert(M.install(ctx,host,name,'full').index==80)
assert(M.remove(ctx,host,name));assert(M.read_file(path(79))=='foreign 79')
assert(M.file_size(path(80))==nil)""")
 def test_hole_preflight_does_not_decode_bundles(self):
  self.lua.execute("""assert(M.write_file(path(80),'foreign'));ctx.set=nil
local ok,why=M.install(ctx,host,name,'full')
assert(not ok and why:find('不连续',1,true),tostring(why))
assert(ctx.set==nil and ctx.error==nil)""")
 def test_lz4_fast_matches_reference_and_rejects_bad_input(self):
  self.lua.execute("""local src=string.char(0x10)..'a'..string.char(1,0)
..string.rep(string.char(0x0f,1,0,0),8000)..string.char(0x50)..'hello'
local size=5+8000*19+5
local expected=assert(M._string_lz4(src,size));local actual=assert(M.lz4_block(src,size))
assert(actual==expected and actual==string.rep('a',size-5)..'hello')
for _,bad in ipairs({string.char(0x0f),string.char(0,0,0),string.char(0,1,0),string.char(0xf0,255)})do
local ok,value=pcall(M.lz4_block,bad,32);assert(ok and value==nil)
end
assert(not M.lz4_block(src,size-1));assert(not M.lz4_block(src,size+1))""")
if __name__=='__main__':unittest.main()
