"""Portable preset parsing, validation and preview tests; never writes game files."""
import tempfile
import unittest
from pathlib import Path
try:
    from lupa.luajit21 import LuaRuntime
except ImportError:
    LuaRuntime = None
ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(LuaRuntime, 'LuaJIT is required')
class DesktopFeaturesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.lua = LuaRuntime()
        self.lua.globals().TEST_DIR = self.temp.name.replace('\\', '/')
        self.lua.execute("package.path=" + repr(str(ROOT/'offline/?.lua').replace('\\', '/')) + "..';'..package.path")
        self.lua.execute('''
        F=require('desktop_features')
        H='0123456789ABCDEF'; OTHER='FEDCBA9876543210'
        field={key='damage',storage='f32',limit=10000,value=70,original=70}
        part={id='damage',field=field,row={label='伤害'}}
        w={hash=H,name='测试武器',rows={{parts={part}}},by_id={damage=part}}
        slots={};P={full={},full_count=50}
        function P.weapon_preset(_,n)return slots[n]end
        function P.weapon_put(_,n,values)slots[n]=values end
        function P.full_put(n,name,values)
          if not n then n=1;while P.full[n]do n=n+1 end end
          P.full[n]={name=name,values=values};return n
        end
        C={presets=P,by_hash={[H]=w},selected=function()return w end,
          overrides=function()return {{hash=H,id='damage',value=field.value}}end,
          parts=function(weapon,id)return weapon.by_id[id] and {weapon.by_id[id]}end,
          read=function(f)return f.value end,default=function(f)return f.original end,
          tr=function(s)return s end,number=tostring,file=function()return 'qa.dl_bin'end,
          path=function(name)return TEST_DIR..'/'..name end,
          write=function(path,data)local f=assert(io.open(path,'wb'));f:write(data);f:close();return true end}
        B={};F.attach(B,C)
        ''')
    def tearDown(self):
        self.temp.cleanup()
    def test_roundtrip_unicode_and_empty_preset(self):
        self.lua.execute('''
        local s=F.encode('weapon','中文预设',H,{{hash=H,id='damage',value=81.125}})
        local p=F.decode(s);assert(p.name=='中文预设' and p.values[1].value==81.125)
        assert(#F.decode(F.encode('full','空预设',nil,{})).values==0)
        ''')
    def test_rejects_malformed_duplicate_nonfinite_and_code(self):
        self.lua.execute('''
        for _,s in ipairs({'return os.execute("bad")','SHODAN-PRESET 2','SHODAN-PRESET 1\\nkind full\\nname 00\\n',
          'SHODAN-PRESET 1\\nkind full\\nkind full\\nname 61\\n',
          'SHODAN-PRESET 1\\nkind full\\nname 61\\nvalue '..H..' damage 1e999\\n',
          'SHODAN-PRESET 1\\nkind full\\nname 61\\nvalue '..H..' damage 1\\nvalue '..H..' damage 2\\n'})do
          assert(not pcall(F.decode,s),'accepted invalid preset')
        end
        ''')
    def test_import_validates_every_entry_before_replacing_slot(self):
        self.lua.execute('''
        slots[1]={{id='damage',value=80}}
        local bad=F.encode('weapon','坏预设',H,{{hash=H,id='damage',value=90},{hash=H,id='missing',value=3}})
        assert(not pcall(B.preset_import,'weapon',1,bad));assert(slots[1][1].value==80)
        local foreign=F.encode('weapon','其它装备',OTHER,{{hash=OTHER,id='damage',value=90}})
        assert(not pcall(B.preset_import,'weapon',1,foreign));assert(slots[1][1].value==80)
        local range=F.encode('weapon','超范围',H,{{hash=H,id='damage',value=1e39}})
        assert(not pcall(B.preset_import,'weapon',1,range));assert(slots[1][1].value==80)
        ''')
    def test_compare_includes_reset_and_never_changes_live_values(self):
        self.lua.execute('''
        field.value=90;slots[1]={}
        local p=B.preset_compare('weapon',1)
        assert(#p.entries==1 and p.entries[1].before=='90' and p.entries[1].after=='70')
        assert(field.value==90)
        slots[1]={{id='damage',value=120}}
        p=B.preset_compare('weapon',1);assert(p.entries[1].after=='120' and field.value==90)
        ''')
    def test_import_and_name_survive_reopen_without_applying_values(self):
        self.lua.execute('''
        local text=F.encode('weapon','近炸测试',H,{{hash=H,id='damage',value=180}})
        local p=B.preset_inspect('weapon',text);assert(p.count==1 and field.value==70)
        B.preset_import('weapon',2,text)
        assert(field.value==70 and slots[2][1].value==180 and B.preset_info(2).name=='近炸测试')
        local reopened={};F.attach(reopened,C);assert(reopened.preset_info(2).name=='近炸测试')
        local full=F.encode('full','全局中文',nil,{{hash=H,id='damage',value=200}})
        local result=B.preset_import('full',0,full)
        assert(P.full[result.id].name=='全局中文' and field.value==70)
        assert(F.decode(B.preset_export('full',result.id)).values[1].value==200)
        ''')
    def test_shared_requires_live_field_identity_and_deduplicates(self):
        self.lua.execute('''
        local another={hash=OTHER,name='其它武器',rows={{parts={{field=field}}}}}
        local stale={hash='AAAAAAAAAAAAAAAA',name='已换弹种',rows={{parts={{field={key='different',value=70}}}}}}
        local record={hash='BBBBBBBBBBBBBBBB',name='弹丸记录',record=true,rows={{parts={{field=field}}}}}
        field.users={w,another,another,stale,record}
        local list=F.shared(w,{part,part},function(s)return s end)
        assert(#list==1 and list[1].id==OTHER,'stale, self, duplicate or record leaked into equipment impact')
        assert(list[1].name=='其它武器')
        local from_record=F.shared(record,{part},function(s)return s end)
        assert(#from_record==2,'record page must list its actual equipment users')
        C.by_hash[OTHER]=another
        field.users={}
        assert(#F.shared(w,{part},nil,F.shared_index(C.by_hash))==1,'live index missed uncached references')
        field.value=95;local preview=B.pending_preview()
        assert(#preview[1].shared==1 and preview[1].shared[1].id==OTHER)
        another.rows={};assert(#F.shared(w,{part})==0,'stale references survived ammunition change')
        ''')
    def test_saved_legacy_preset_warns_without_discarding_valid_values(self):
        self.lua.execute('''
        P.full[1]={name='旧预设',values={{hash=H,id='damage',value=180},{hash=H,id='f018',value=3}}}
        local p=B.preset_compare('full',1)
        assert(p.accepted==1 and p.skipped==1 and #p.warnings==1)
        assert(p.warnings[1]:find('f018',1,true) and p.entries[1].after=='180')
        assert(field.value==70 and #P.full[1].values==2,'preview mutated values or discarded old fields')
        local ok=pcall(B.preset_import,'full',0,F.encode('full','未知参数',nil,P.full[1].values))
        assert(not ok,'portable import silently accepted an unknown parameter')
        ''')
    def test_all_unknown_saved_preset_cannot_clear_current_changes(self):
        self.lua.execute('''
        field.value=95;P.full[1]={name='失效预设',values={{hash=H,id='f018',value=3}}}
        local ok,why=pcall(B.preset_compare,'full',1)
        assert(not ok and tostring(why):find('以免清空当前修改',1,true))
        assert(field.value==95 and #P.full[1].values==1)
        local calls=0;local api={full_preset=function()calls=calls+1;field.value=70 end}
        F.attach(api,C);assert(not pcall(api.full_preset,'load',1) and calls==0 and field.value==95)
        ''')
    def test_direct_load_checks_match_preview_for_each_preset_kind(self):
        self.lua.execute('''
        slots[1]={{id='damage',value=120},{id='f018',value=2}}
        P.full[1]={name='全局',values={{hash=H,id='damage',value=180},{hash=H,id='f018',value=3}}}
        local weaponCalls,fullCalls=0,0
        local api={preset=function()weaponCalls=weaponCalls+1;return '装备' end,
                   full_preset=function()fullCalls=fullCalls+1;return '全局' end}
        F.attach(api,C)
        assert(api.preset('load',1):find('已跳过 1 项',1,true) and weaponCalls==1)
        assert(api.full_preset('load',1):find('已跳过 1 项',1,true) and fullCalls==1)
        P.full[1].values={{hash=OTHER,id='f018',value=3}}
        assert(not pcall(api.full_preset,'load',1) and fullCalls==1)
        ''')
    def test_pending_preview_and_shared_field_conflict(self):
        self.lua.execute('''
        assert(#B.pending_preview()==0);field.value=95
        local p=B.pending_preview();assert(p[1].before=='70' and p[1].after=='95' and p[1].file=='qa.dl_bin')
        w.by_id.alias={id='alias',field=field,row={label='共享伤害'}}
        local text=F.encode('weapon','冲突',H,{{hash=H,id='damage',value=80},{hash=H,id='alias',value=90}})
        assert(not pcall(B.preset_inspect,'weapon',text));assert(field.value==95)
        ''')

if __name__ == '__main__':
    unittest.main()
