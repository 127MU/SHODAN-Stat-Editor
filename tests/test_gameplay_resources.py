"""Window-limited resource edits, version gates and preservation of other edits."""
import pathlib,unittest
from lupa.luajit21 import LuaRuntime
ROOT=pathlib.Path(__file__).resolve().parents[1]
class GameplayResourceTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime();self.lua.execute("package.path=.....';'..package.path",(ROOT/'offline/?.lua').as_posix())
        self.lua.execute('''
original='HEADaaaaKEEPbbbb';held={};installed=nil;writes=0
package.loaded.gamedata={sha256_hex=function(s)return s==original and 'ok' or 'wrong'end}
package.loaded.ragdoll_recipe={host='host',package='source',resources={{id='id',type='type',size=16,sha256='ok',edits={{4,'61616161','43434343'},{12,'62626262','44444444'}}}}}
package.loaded.res_patch={
 entry_of=function()return installed end,
 read_entry=function()return original end,
 saved_overrides=function()local t={};for k,v in pairs(held)do t[k]=v end;return t,nil,{}end,
 install_with=function(_,_,_,mode,values)held=values;installed={mode=mode};writes=writes+1;return {}end,
 remove=function()held={};installed=nil;writes=writes+1;return true end}
M=require('gameplay_resources');ctx={}
''')
    def test_preview_enable_and_restore_only_known_windows(self):
        self.lua.execute('''
assert(not M.preview(ctx).enabled and writes==0)
assert(M.apply(ctx,true));assert(held['type:id']=='HEADCCCCKEEPDDDD' and writes==1)
assert(M.preview(ctx).enabled and writes==1)
assert(M.apply(ctx,true));assert(writes==1)
held['type:id']='HEADCCCCUSERDDDD'
assert(M.apply(ctx,false));assert(held['type:id']=='HEADaaaaUSERbbbb' and installed)
''')
    def test_unknown_target_and_wrong_version_refused_without_writes(self):
        self.lua.execute('''
held['type:id']='HEADxxxxKEEPbbbb'
local ok,why=M.apply(ctx,true);assert(not ok and why and writes==0)
held={};package.loaded.res_patch.read_entry=function()return 'WRONGaaaKEEPbbbb'end
ok,why=M.apply(ctx,true);assert(not ok and why and writes==0)
''')
    def test_disable_removes_empty_owned_patch(self):
        self.lua.execute('assert(M.apply(ctx,true));assert(M.apply(ctx,false));assert(not installed and not next(held))')
if __name__=='__main__':unittest.main()
