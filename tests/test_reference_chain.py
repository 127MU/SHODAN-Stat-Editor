"""Bounded, read-only graph traversal; IDs are separated by record kind."""
import pathlib,unittest
from lupa.luajit21 import LuaRuntime
ROOT=pathlib.Path(__file__).resolve().parents[1]
class ChainTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime();self.lua.execute("package.path=.....';'..package.path",(ROOT/'offline/?.lua').as_posix())
    def test_cycles_shared_damage_missing_and_zero(self):
        self.lua.execute('''
local M=require('reference_chain');local calls=0
local graph={['shot:1']={exists=true,links={{kind='damage',id=1,via='命中'},{kind='blast',id=2,via='爆炸'},{kind='shot',id=0}}},
 ['damage:1']={exists=true,links={{kind='status',id=1}}},['status:1']={exists=true,links={{kind='damage',id=1}}},
 ['blast:2']={exists=true,links={{kind='shot',id=1},{kind='shot',id=999}}}}
local out=M.build({{kind='shot',id=1},{kind='shot',id=1,via='备弹'}},function(kind,id)calls=calls+1;return graph[kind..':'..id]end)
assert(calls==5 and #out.nodes==5)
local repeated,missing=0,0
for _,row in ipairs(out.entries)do if row.repeated then repeated=repeated+1 end;if row.missing then missing=missing+1 end end
assert(repeated==3 and missing==1)
assert(out.nodes[1].kind=='shot' and out.nodes[2].kind=='damage')
''')
    def test_depth_and_node_limits(self):
        self.lua.execute('''
local out=require('reference_chain').build({{kind='shot',id=1}},function(kind,id)return {exists=true,links={{kind=kind,id=id+1}}}end)
assert(#out.entries==25 and #out.warnings==1)
''')
if __name__=='__main__':unittest.main()
