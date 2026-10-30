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
 def test_progress_finishes_and_observer_cannot_interrupt_commit(self):
  self.lua.execute('''
   put('one.bin','original-one');put('two.bin','original-two')
   local events={}
   SHODAN_EUI_PROGRESS=function(message,done,total)
    events[#events+1]={message=message,done=done,total=total}
    if #events==2 then error('UI observer failure')end
   end
   assert(I.write_files(QA_GAME,{['one.bin']='edited-one',['two.bin']='edited-two'},
    {['one.bin']='original-one',['two.bin']='original-two'}))
   assert(#events>=8 and events[#events].done==2 and events[#events].total==2)
   assert(I.read(QA_GAME..'/one.bin')=='edited-one' and I.read(QA_GAME..'/two.bin')=='edited-two')
   assert(not I.read(QA_GAME..'/one.bin.shodan-new'))
  ''')
 def test_identical_file_skips_staging_after_external_change_guard(self):
  self.lua.execute('''
   put('one.bin','same');local events={}
   SHODAN_EUI_PROGRESS=function(message)events[#events+1]=message end
   assert(I.write_files(QA_GAME,{['one.bin']='same'},{['one.bin']='same'}))
   assert(not I.read(QA_GAME..'/one.bin.shodan-new'))
   assert(events[#events]=='跳过内容相同的文件')
   -- A matching desired value must never hide an external change after load.
   local ok=I.write_files(QA_GAME,{['one.bin']='same'},{['one.bin']='original'},false,{['one.bin']='not-the-observed-hash'})
   assert(not ok)
  ''')
 def test_startup_mod_with_canonical_baseline_can_be_written_and_restored(self):
  self.lua.execute('''
   local name='generated_damage_settings.dl_bin'
   put(name,'installed-before-startup')
   local originals,ours,problems,count,observed=I.originals(QA_GAME,{[name]='verified-vanilla'})
   assert(count==1 and originals[name]=='verified-vanilla' and not ours[name])
   assert(observed[name] and I.read(QA_GAME..'/'..name)=='installed-before-startup')
   assert(I.write_files(QA_GAME,{[name]='edited'},originals,false,observed))
   assert(I.read(I.originals_dir..'/'..name)=='verified-vanilla')
   assert(I.write_files(QA_GAME,{[name]='edited-again'},originals,false,observed))
   assert(I.write_files(QA_GAME,{[name]='verified-vanilla'},originals,true,observed))
   assert(I.read(QA_GAME..'/'..name)=='verified-vanilla')
  ''')
 def test_startup_snapshot_blocks_later_changes_and_deletions(self):
  self.lua.execute('''
   local name='generated_entities.dl_bin'
   put(name,'startup-mod')
   local originals,_,_,_,observed=I.originals(QA_GAME,{[name]='vanilla'})
   put(name,'changed-after-open')
   local ok,why=I.write_files(QA_GAME,{[name]='edited'},originals,false,observed)
   assert(not ok and why:find('another tool changed',1,true))
   assert(I.read(QA_GAME..'/'..name)=='changed-after-open')
   local writes={[name]='vanilla'}
   ok,why=I.write_files(QA_GAME,writes,originals,true,observed)
   assert(ok and #why==1 and writes[name]==nil)
   assert(os.remove(QA_GAME..'/'..name))
   assert(not I.write_files(QA_GAME,{[name]='edited'},originals,false,observed))
   assert(I.read(QA_GAME..'/'..name)==nil)
  ''')
if __name__=='__main__':unittest.main()
