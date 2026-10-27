"""Residency dependency resolution and transactional safety, synthetic data only."""
from test_res_patch import ResourcePatchTests


class DependencyTests(ResourcePatchTests):
    def setUp(self):
        super().setUp()
        self.lua.execute('''
particle='a8193123526fad64';bank='535a7bd3e650d799';asset='0102030405060708'
function rawhex(s)local t={};for i=#s-1,1,-2 do t[#t+1]=string.char(tonumber(s:sub(i,i+1),16))end;return table.concat(t)end
function addpkg(n,items)
 local blobs={}
 for _,i in ipairs(items)do
  local e={id_raw=rawhex(i[1]),id_hex=i[1],type_raw=rawhex(i[2]),type_hex=i[2],unknown1_raw=I.u64(0),unknown2_raw=I.u64(0),unknown3=0,unknown4=0}
  blobs[#blobs+1]={entry=e,toc=i[3],gpu='',stream=''}
 end
 local toc=I.build_package({magic=0xF0000011,unknown=0,trailing=string.rep('\\0',56),types={}},blobs)
 local id=1;while ctx.set.heads[id]do id=id+1 end
 ctx.set.heads[id]={cache={[1]=toc},order={},chunks={{uoff=0,usize=#toc}}}
 ctx.set.packages[n]={size=#toc,items={{off=0,uoff=0,bundle=id}}}
 ctx.set.names=ctx.set.names or {};ctx.set.names[#ctx.set.names+1]=n
end
local hirc=I.u32(1)..string.char(4)..I.u32(4)..I.u32(98765)
bankbytes=string.rep('\\0',16)..'BKHD'..I.u32(4)..I.u32(123)..'HIRC'..I.u32(#hirc)..hirc
donor='aaaaaaaaaaaaaaaa';wrong='bbbbbbbbbbbbbbbb'
addpkg(donor,{{asset,particle,'real particle'},{'1234567812345678',bank,bankbytes}})
addpkg(wrong,{{asset,'0000000000000001','wrong type'},{'8765432187654321',bank,'random HIRC'..I.u32(98765)}})
''')

    def test_exact_resource_and_real_bank_event(self):
        self.lua.execute('''local names,missing=assert(M.resolve_resources(ctx,{wrong},{{id_hex=asset,type_hex=particle}},{98765}))
assert(#names==2 and names[2]==donor and #missing==0)
local _,unknown=M.resolve_resources(ctx,{},{{id_hex=asset,type_hex=particle}},{12345})
assert(#unknown==1 and unknown[1]:find('12345',1,true))''')

    def test_sidecar_and_hole_are_not_installed(self):
        self.lua.execute('''assert(M.install(ctx,host,name,'full'));os.remove(path(0,'.gpu_resources'));assert(M.state(ctx,host,name)==0)
assert(M.install(ctx,host,name,'full'));assert(M.install(ctx,host,donor,'full'));os.remove(path(0))
assert(M.state(ctx,host,donor)==0);local before=snapshot();local ok,why=M.install(ctx,host,donor,'full')
assert(not ok and why:find('不连续',1,true));unchanged(before)''')

    def test_preserve_edits_across_packages_and_remember_group(self):
        self.lua.execute('''assert(M.install(ctx,host,donor,'full'))
assert(M.update_entry(ctx,host,donor,'full',asset,particle,'edited particle'))
local other='cccccccccccccccc';addpkg(other,{{asset,particle,'real particle'}})
assert(M.install_many(ctx,host,{other},'full','page-1','signature'))
local edits=assert(M.saved_overrides(ctx,host,other));assert(edits[particle..':'..asset]=='edited particle')
assert(M.group(ctx,'page-1','signature')[1]==other);assert(not M.group(ctx,'page-1','different'))''')

    def test_batch_failure_rolls_back_files_ledger_and_group(self):
        self.lua.execute('''local before=snapshot();local write=M.write_file
M.write_file=function(p,b)if p:find('residency_dependencies.txt',1,true)then return false,'injected group failure' end;return write(p,b)end
local ok,why=M.install_many(ctx,host,{donor,wrong},'full','page-1','sig')
M.write_file=write;assert(not ok and why:find('injected',1,true));unchanged(before)
assert(not M.group(ctx,'page-1'))''')

    def test_later_vanilla_copy_cannot_undo_earlier_edit(self):
        self.lua.execute('''assert(M.install(ctx,host,donor,'full'))
assert(M.update_entry(ctx,host,donor,'full',asset,particle,'edited particle'))
local other='cccccccccccccccc';addpkg(other,{{asset,particle,'real particle'}})
assert(M.install(ctx,host,other,'full')) -- simulate an older release's overlapping vanilla patch
assert(M.install_many(ctx,host,{donor},'full'))
assert(M.saved_overrides(ctx,host,other)[particle..':'..asset]=='edited particle')''')


if __name__ == '__main__':
    import unittest
    unittest.main()
