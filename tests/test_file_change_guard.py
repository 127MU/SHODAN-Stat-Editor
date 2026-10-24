"""Official 4.1 file-change guards, using only a temporary fake game directory."""
import os,tempfile,pathlib,sys,unittest
try:
 from lupa.luajit21 import LuaRuntime
except ImportError:LuaRuntime=None
ROOT=pathlib.Path(__file__).resolve().parents[1]
@unittest.skipUnless(LuaRuntime,'LuaJIT required')
class FileChangeGuardTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.old=os.environ.get('SHODAN_PROFILE');os.environ['SHODAN_PROFILE']=self.tmp.name+'/profile'
  self.lua=LuaRuntime();self.lua.globals().QA_GAME=self.tmp.name.replace('\\','/')+'/game';pathlib.Path(self.tmp.name,'game').mkdir()
  self.lua.execute("package.path="+repr((ROOT/'offline/?.lua').as_posix())+"..';'..package.path")
  self.lua.execute("I=require('install');I.game_running=function()return false end;function put(name,s)local f=assert(io.open(QA_GAME..'/'..name,'wb'));f:write(s);f:close()end")
 def tearDown(self):
  if self.old is None:os.environ.pop('SHODAN_PROFILE',None)
  else:os.environ['SHODAN_PROFILE']=self.old
  self.tmp.cleanup()
 def test_install_stops_on_external_change_and_restore_skips_it(self):
  self.lua.execute('''
   put('one.bin','external');put('two.bin','original-two')
   local originals={['one.bin']='original-one',['two.bin']='original-two'}
   local ok,why=I.write_files(QA_GAME,{['one.bin']='edited'},originals)
   assert(not ok and why:find('another tool changed',1,true));assert(I.read(QA_GAME..'/one.bin')=='external')
   local writes={['one.bin']='original-one',['two.bin']='restored-two'}
   ok,why=I.write_files(QA_GAME,writes,originals,true)
   assert(ok and #why==1 and why[1]=='one.bin' and writes['one.bin']==nil)
   assert(I.read(QA_GAME..'/one.bin')=='external' and I.read(QA_GAME..'/two.bin')=='restored-two')
  ''')
 def test_own_previous_install_can_be_replaced_but_foreign_edit_cannot(self):
  self.lua.execute('''
   put('own.bin','original');local originals={['own.bin']='original'}
   assert(I.write_files(QA_GAME,{['own.bin']='first'},originals))
   assert(I.write_files(QA_GAME,{['own.bin']='second'},originals))
   put('own.bin','foreign');local ok=I.write_files(QA_GAME,{['own.bin']='third'},originals)
   assert(not ok and I.read(QA_GAME..'/own.bin')=='foreign')
  ''')
if __name__=='__main__':unittest.main()
