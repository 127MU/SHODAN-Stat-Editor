"""Immutable defaults across foreign-tool block/record layout changes."""
import pathlib,sys,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
try:
    from lupa.luajit21 import LuaRuntime
except ImportError:
    LuaRuntime=None

@unittest.skipUnless(LuaRuntime,'LuaJIT required')
class OriginalMappingTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime()
        self.lua.execute("package.path="+repr((ROOT/'offline/?.lua').as_posix())+"..';'..package.path")
        self.lua.execute('''
ffi=require('ffi')
function put(p,at,v) ffi.cast('uint32_t*',p+at)[0]=v end
function get(s) return tonumber(ffi.cast('const uint32_t*',assert(s))[0]) end
function setup(n,m,a,b)
 original=ffi.new('uint8_t[?]',n);current=ffi.new('uint8_t[?]',m)
 package.loaded.gamedata={open_sealed=function(s)assert(s=='vanilla');return original,n end,
  headers=function(p)return p==original and a or b end,clear_correction=function()end,free=function()end}
 package.loaded.hostdata=nil;D=require('hostdata')
 D.files.test={p=current,n=m,cipher='modified',baseline='vanilla'}
end
function parse(blob)
 local p=ffi.cast('const uint8_t*',blob);local n=tonumber(ffi.cast('const uint32_t*',p+8)[0]);local index={}
 if 16+n*8~=#blob then return nil end
 for r=0,n-1 do index[tonumber(ffi.cast('const uint32_t*',p+16+r*8)[0])]=16+r*8 end
 return index
end
function register(at,size)
 local index=assert(parse(ffi.string(current+at+24,size)))
 D.register_original_layout(tonumber(ffi.cast('uintptr_t',current+at)),1,8,index,parse)
end
function read(at) return D.original_bytes(tonumber(ffi.cast('uintptr_t',current+at)),4) end
''')

    def test_appended_blocks_expanded_and_reordered_records(self):
        self.lua.execute('''
setup(88,128,{{at=0,type=1,size=32},{at=56,type=2,size=8}},
 {{at=0,type=99,size=8},{at=32,type=1,size=40},{at=96,type=2,size=8}})
put(original,32,2);put(original,40,11);put(original,44,70);put(original,48,22);put(original,52,1200);put(original,80,123)
put(current,64,3);put(current,72,22);put(current,76,9999);put(current,80,11);put(current,84,420);put(current,88,33);put(current,92,888);put(current,120,777)
register(32,40)
assert(get(read(76))==1200);assert(get(read(84))==70)
assert(read(92)==nil,'New records must not invent defaults')
assert(get(read(120))==123,'Unrelated component lost its baseline')
put(current,84,900);assert(get(read(84))==70,'Current edits became defaults')
assert(tonumber(ffi.cast('uint32_t*',current+92)[0])==888,'Unknown Mod record was changed')
''')

    def test_same_sized_record_reorder_uses_identity(self):
        self.lua.execute('''
setup(56,56,{{at=0,type=1,size=32}},{{at=0,type=1,size=32}})
put(original,32,2);put(original,40,11);put(original,44,70);put(original,48,22);put(original,52,1200)
put(current,32,2);put(current,40,22);put(current,44,999);put(current,48,11);put(current,52,888)
register(0,32)
assert(get(read(44))==1200 and get(read(52))==70,'Defaults followed row position instead of ID')
''')

    def test_one_incompatible_block_does_not_poison_other_blocks(self):
        self.lua.execute('''
setup(64,72,{{at=0,type=1,size=8},{at=32,type=2,size=8}},{{at=0,type=1,size=16},{at=40,type=2,size=8}})
put(original,56,70);put(current,64,420)
assert(read(24)==nil)
assert(get(read(64))==70,'An incompatible block invalidated the entire file')
''')

    def test_ambiguous_record_owner_remains_unknown(self):
        self.lua.execute('''
setup(128,80,{{at=0,type=1,size=24},{at=48,type=1,size=24},{at=96,type=2,size=8}},
 {{at=0,type=99,size=8},{at=32,type=1,size=24}})
put(original,32,1);put(original,40,11);put(original,44,70)
put(original,80,1);put(original,88,11);put(original,92,999)
put(current,64,1);put(current,72,11);put(current,76,420)
register(32,24)
assert(read(76)==nil,'Ambiguous vanilla owner was guessed')
''')

if __name__=='__main__':unittest.main()
