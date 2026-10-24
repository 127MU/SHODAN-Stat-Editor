"""Run with a Python environment containing lupa.luajit21; no game process needed."""
import sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
try:
    from lupa.luajit21 import LuaRuntime
except ImportError:
    LuaRuntime=None

@unittest.skipUnless(LuaRuntime,'LuaJIT runtime is optional for this test')
class ArmoryTests(unittest.TestCase):
    def test_installed_values_do_not_become_original_defaults(self):
        lua=LuaRuntime();lua.execute("package.path="+repr(str(ROOT/'offline/?.lua').replace('\\','/'))+"..';'..package.path")
        lua.execute(r'''local ffi=require('ffi')
        local original=ffi.new('uint8_t[64]');local current=ffi.new('uint8_t[64]')
        ffi.cast('float *',original+24)[0]=70;ffi.cast('float *',current+24)[0]=420
        package.loaded.gamedata={open_sealed=function(s) assert(s=='vanilla');return original,64 end,headers=function() return {} end,
          clear_correction=function() end}
        local D=require('hostdata')
        D.files.test={p=current,n=64,cipher='installed',baseline='vanilla'}
        local address=tonumber(ffi.cast('uintptr_t',current+24))
        local raw=assert(D.original_bytes(address,4));assert(ffi.cast('const float *',raw)[0]==70)
        ffi.cast('float *',current+24)[0]=900
        raw=assert(D.original_bytes(address,4));assert(ffi.cast('const float *',raw)[0]==70)
        assert(D.original_bytes(address+100,4)==nil)
        ''')
    def test_catalog_profiles_and_own_passive(self):
        lua=LuaRuntime();lua.execute("package.path="+repr(str(ROOT/'offline/?.lua').replace('\\','/'))+"..';'..package.path")
        lua.execute('''
        local A=require('armory')
        A.refresh({0,1,7,42,88})
        assert(#A.list==4 and A.find(88)==88)
        local profiles=A.parse('[profile: Every armor]\\nown_passive = 0\\n1 = on\\n7 = on\\n7 = off\\n')
        assert(profiles[999].own==false and profiles[999].enabled[1] and not profiles[999].enabled[7])
        A.profiles=profiles
        local stacks,off=A.selection({}, {}, {1,7,42,88})
        assert(off[1] and stacks[1][1]==1) -- can re-add the native effect after disabling it
        A.profiles[7]={enabled={},own=true,conflicts='stack',configured=true}
        stacks,off=A.selection({}, {}, {1,7,42,88})
        assert(#stacks[7]==0 and off[7]==nil) -- explicit empty profile overrides the global profile
        local saved=A.serialize()
        assert(saved:find('Passive #88',1,true)==nil) -- merely discovering an ID does not create a profile
        local roundtrip=A.parse(saved)
        assert(roundtrip[7] and not next(roundtrip[7].enabled))
        ''')
    def test_numeric_import_checks_entire_plan_before_writing(self):
        lua=LuaRuntime();lua.execute("package.path="+repr(str(ROOT/'offline/?.lua').replace('\\','/'))+"..';'..package.path")
        lua.execute(r'''local ffi=require('ffi')
        package.loaded.gamedata={headers=function() return {{at=0,type=0x63CE0FEB,size=72}} end}
        local D=require('hostdata')
        local p=ffi.new('uint8_t[96]')
        ffi.cast('uint32_t *',p+24)[0]=1
        ffi.cast('uint32_t *',p+48)[0]=1
        ffi.cast('uint64_t *',p+40)[0]=ffi.cast('uintptr_t',p+80)
        ffi.cast('float *',p+88)[0]=2
        D.files['generated_customization_passive_bonuses.dl_bin']={p=p,n=96}
        local count,why=D.import_forge_values('AFV1\n1:1:3.5\n1:2:7\n')
        assert(count==nil and why and ffi.cast('float *',p+88)[0]==2)
        assert(D.import_forge_values('AFV1\n1:1:3.5\n')==1)
        assert(ffi.cast('float *',p+88)[0]==3.5)
        assert(D.import_forge_values('AFV1\n1:1:1e99\n')==nil)
        ''')
    def test_armor_editor_limits_fields_to_selected_passive(self):
        lua=LuaRuntime();lua.execute("package.path="+repr(str(ROOT/'offline/?.lua').replace('\\','/'))+"..';'..package.path")
        lua.execute(r'''local ffi=require('ffi')
        local original=ffi.new('uint8_t[144]')
        local current=ffi.new('uint8_t[144]')
        local function fill(p,relocated)
            ffi.cast('uint32_t *',p+24)[0]=1
            ffi.cast('uint32_t *',p+48)[0]=4
            ffi.cast('uint64_t *',p+40)[0]=relocated and ffi.cast('uintptr_t',p+80) or 56
            for i,id in ipairs({2947431239,678818890,2947431239,1234567}) do
                local at=80+(i-1)*16
                ffi.cast('uint32_t *',p+at)[0]=id
                ffi.cast('uint32_t *',p+at+4)[0]=1
                ffi.cast('float *',p+at+8)[0]=i
            end
        end
        fill(original,false);fill(current,true)
        package.loaded.gamedata={headers=function() return {{at=0,type=0x63CE0FEB,size=120}} end,
            open_sealed=function() return original,144 end,free=function() end}
        local D=require('hostdata')
        D.files['generated_customization_passive_bonuses.dl_bin']={p=current,n=144,cipher='test'}
        local rows=D.armor_values(1)
        assert(#rows==1 and rows[1].label=='护甲加成（内部单位）')
        assert(D.set_armor_value(1,'1:16:678818890:1:1',99)==nil)
        assert(ffi.cast('float *',current+104)[0]==2)
        assert(D.set_armor_value(1,rows[1].key,5)==5)
        assert(D.armor_values(1)[1].default==1)
        assert(#D.armor_values(88)==0)
        ''')
    def test_lua_sources_compile(self):
        lua=LuaRuntime(unpack_returned_tuples=True)
        compile=lua.eval('function(s) local f,e=loadstring(s);return f~=nil,e end')
        for path in list((ROOT/'offline').glob('*.lua'))+list((ROOT/'src').glob('*.lua')):
            with self.subTest(file=path.name):
                ok,error=compile(path.read_text(encoding='utf8'));self.assertTrue(ok,error)

if __name__=='__main__':unittest.main()
