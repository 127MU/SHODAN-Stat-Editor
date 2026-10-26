"""Selector identities must survive enumeration order, labels and new resources."""
import pathlib,unittest
from lupa.luajit21 import LuaRuntime
ROOT=pathlib.Path(__file__).resolve().parents[1]
class ReferenceIdentityTests(unittest.TestCase):
 def test_identity_survives_order_and_labels(self):
  s=(ROOT/'src/stat_editor.lua').read_text(encoding='utf8')
  begin=s.index('function MOD.refs.stable_id(');end=s.index('\nfunction MOD.refs.items()',begin)
  L=LuaRuntime();L.execute("MOD={refs={built={},names=function()return{}end,hex=function(k)return(k:gsub('.',function(c)return string.format('%02X',c:byte())end))end}};settings={tr=function(s)return s end}")
  L.execute(s[begin:end])
  L.execute("""
local function bytes(s)return(s:gsub('%x%x',function(c)return string.char(tonumber(c,16))end))end
local raw={'05656B4B5B893AB8','055F887C3BC616FE','A32621E3BDE13379','0000000000000002','0000000000000003'}
local function build(reverse,extra)
 MOD.refs.built={}
 return MOD.refs.list_of('packages',function(r)
  for n=1,#raw do local i=reverse and #raw+1-n or n;local key=bytes(raw[i]);local it={id=#r.list,label=reverse and '新译名' or '旧译名',bytes=key}
   r.list[#r.list+1]=it;r.by_id[it.id]=it;r.by_bytes[key]=it.id end
  if extra then local k=bytes('0000000000000001');r.list[#r.list+1]={id=99,label='新增',bytes=k}end
 end)
end
local a,b=build(false,false),build(true,true)
local ids={};for _,raw in ipairs(raw)do local k=bytes(raw);assert(a.by_bytes[k]==b.by_bytes[k]);assert(not ids[a.by_bytes[k]]);ids[a.by_bytes[k]]=true;assert(a.by_id[a.by_bytes[k]].bytes==k)end
assert(a.by_id[0].id==0 and b.by_id[0].id==0)
assert(a.by_bytes[bytes(raw[1])]~=a.by_bytes[bytes(raw[2])])
assert(tonumber(string.format('%.0f',a.by_bytes[bytes(raw[1])]))==a.by_bytes[bytes(raw[1])])
""")
if __name__=='__main__':unittest.main()
