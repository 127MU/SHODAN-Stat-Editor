"""Exercise state-machine UI backend routing with mocked patch writes only."""
import pathlib,sys,tempfile,os,unittest,gc
ROOT=pathlib.Path(__file__).resolve().parents[1]
from lupa.luajit21 import LuaRuntime

class StateMachineIntegrationTests(unittest.TestCase):
 def test_entry_scoped_actions_and_zero_change_removal(self):
  with tempfile.TemporaryDirectory() as tmp:
   old=dict(os.environ)
   try:
    profile=pathlib.Path(tmp);(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
    os.environ.update(SHODAN_PROFILE=tmp,SHODAN_QA_OUTPUT=tmp)
    lua=LuaRuntime();lua.globals().SHODAN_EUI=True
    lua.execute("QA_LOG_FILES={};local open=io.open;io.open=function(path,mode)local f,e=open(path,mode);if f and path:find('SHODANStatEditorHost.log',1,true)then QA_LOG_FILES[#QA_LOG_FILES+1]=f end;return f,e end")
    lua.execute('arg={...}', (ROOT/'src/stat_editor.lua').as_posix())
    lua.execute('return dofile(...)',(ROOT/'offline/host.lua').as_posix())
    lua.execute('''local S=assert(ShodanStatEditor.sm)
local I=require('install');I.game_running=function()return false end
local calls={};local P={state=function()return 0 end,
 update_entry=function(ctx,host,pkg,mode,id,kind,bytes)
  calls.update={pkg,mode,id,kind,bytes};return {index=81}end,
 revert_entry=function(ctx,host,pkg,id,kind)calls.revert={pkg,id,kind};return true end}
S.patch_module=function()return P end;S.ctx=function()return {}end
S.module=function()return {apply=function(bytes)assert(bytes=='original');return 'edited'end}end
S.package_of=function()return 'testpackage'end;S.pick_of=function()return 1 end
local info={id='resource_id',bytes='original',plan={changes={}},count=1}
S.info=function()return info end
local ok,why=S.act({},1);assert(not ok and why:find('测试模式',1,true))
local getenv=os.getenv;os.getenv=function(key)if key=='SHODAN_QA_OUTPUT' or key=='SHODAN_HUSKAR_QA'then return nil end;return getenv(key)end
assert(S.act({},1));assert(calls.update[2]=='res' and calls.update[3]=='resource_id' and calls.update[5]=='edited')
info.plan=nil;info.count=0
assert(S.act({},2));assert(calls.revert[2]=='resource_id' and calls.revert[3]==S.TYPE)
I.game_running=function()return true end
calls.revert=nil;assert(not S.act({},2));assert(calls.revert==nil)
os.getenv=getenv
''')
   finally:
    if 'lua' in locals():
     lua.execute('for _,f in ipairs(QA_LOG_FILES or {})do pcall(function()f:close()end)end')
     del lua
    gc.collect()
    os.environ.clear();os.environ.update(old)

if __name__=='__main__':unittest.main()
