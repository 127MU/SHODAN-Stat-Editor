"""Real hash and sealed-box merge regression; never writes game files."""
import unittest
from pathlib import Path
try:
 from lupa.luajit21 import LuaRuntime
except ImportError:
 LuaRuntime=None
@unittest.skipUnless(LuaRuntime,'LuaJIT required')
class MergeTests(unittest.TestCase):
 def test_union_conflict_and_sealed_roundtrip(self):
  lua=LuaRuntime()
  lua.execute("package.path="+repr(str(Path(__file__).resolve().parents[1]/'offline/?.lua').replace('\\','/'))+"..';'..package.path")
  lua.execute(r'''local ffi=require('ffi');local G=require('gamedata');local M=require('mod_merge')
local p=ffi.new('uint8_t[60]');ffi.cast('uint32_t*',p)[0]=1
ffi.copy(p+4,'LDLD\1\0\0\0',8)
ffi.cast('uint32_t*',p+12)[0]=123;ffi.cast('uint32_t*',p+16)[0]=32;p[20]=1
local base=ffi.string(p,60)
local a=M.tail(base,{[29]={byte=11}});local b=M.tail(base,{[30]={byte=22}})
local result=M.merge(base,{{label='A',data=a},{label='B',data=b}})
assert(not result.blocked and result.changed==2)
local out,n=G.open_sealed(result.data);assert(out[29]==11 and out[30]==22);G.free(out)
local c=M.tail(base,{[29]={byte=12}})
assert(M.merge(base,{{data=a},{data=c}}).blocked)
local last=M.merge(base,{{data=a},{data=c}},'after');out,n=G.open_sealed(last.data);assert(out[29]==12);G.free(out)
assert(M.merge(base,{{data=a},{data=a}}).changed==1)
assert(not pcall(M.merge,base,{{data=base:sub(1,29)..'x'..base:sub(31)}}))
''')
