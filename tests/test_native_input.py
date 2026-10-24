import unittest,sys,json,zipfile,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
try:
 from lupa.luajit21 import LuaRuntime
except ImportError:LuaRuntime=None
@unittest.skipUnless(LuaRuntime,'LuaJIT is needed')
class NativeInputTests(unittest.TestCase):
 def lua(self):
  runtime=LuaRuntime();runtime.execute("package.path="+repr(str(ROOT/'offline/?.lua').replace('\\','/'))+"..';'..package.path");return runtime
 def test_unicode_surrogates_paste_and_backspace(self):
  self.lua().execute("""local T=require('text_input')
   T.push(0x89E3);T.push(0x653E);T.push(0x8005)
   local a=T.take();assert(a[1].text..a[2].text..a[3].text=='解放者')
   T.push(0xD83D);T.push(0xDE80);assert(T.take()[1].text=='🚀')
   T.paste('AR-11'..string.char(13,10));local p=T.take();assert(#p==1 and p[1].text=='AR-11')
   T.push(8);T.push(13);T.push(1);local q=T.take();assert(#q==2 and q[1].kind=='backspace' and q[2].kind=='enter')
   assert(#T.take()==0)
  """)
 def test_theme_mapping_does_not_mutate_originals(self):
  self.lua().execute("""local T=require('theme');local c={255,255,255,255}
   assert(T.color(c,false)==c);T.set('dark');local field=T.color(c,false)
   local text=T.color({255,23,37,33},true)
   assert(field[2]==0 and field[3]==0 and field[4]==0 and text[2]>220 and c[2]==255)
   for _,rgb in ipairs({{255,248,252,246},{255,237,242,234},{255,203,231,210}}) do local p=T.color(rgb,false);assert(p[2]==0 and p[3]==0 and p[4]==0) end
   local mask=T.color({100,30,60,43},false);assert(mask[1]==100 and mask[2]==0 and mask[3]==0 and mask[4]==0)
   assert(T.color(c,false)==field);T.set('light');assert(T.color(c,false)==c)
  """)
@unittest.skipUnless(LuaRuntime,'LuaJIT is needed')
class LocalizationTests(unittest.TestCase):
 def test_user_reference_and_nested_sections(self):
  lua=LuaRuntime();lua.execute("package.path="+repr(str(ROOT/'offline/?.lua').replace('\\','/'))+"..';'..package.path")
  lua.execute('''local R=require('zh_reference');local U=require('zh_ui')
   assert(R.translate('AR-23 Liberator')=='AR-23 解放者')
   assert(not R.translate('FAF-14 Spear'):find('模型'))
   assert(U.translate('Anti-Tank Mine Deployer')=='反坦克地雷布设器')
   assert(U.translate('Status effects (Arc)',function(s) return U.translate(s) or s end)=='状态效果（电弧）')
   assert(U.translate('President rewards stratagem (PRESIDENT REWARDS. AMMO CACHE).')=='总统奖励战略配备。')
   assert(U.early("Looking for Helldivers 2..."):find('正在查找'))
  ''')
 def test_parameter_coefficients_are_not_mislabelled(self):
  lua=LuaRuntime();lua.execute("package.path="+repr(str(ROOT/'offline/?.lua').replace('\\','/'))+"..';'..package.path")
  lua.execute('''local P=require('zh_params')
   assert(P.translate('Fire damage taken')=='承受火焰伤害倍率')
   assert(P.hint('Fire damage taken')[1]:find('75%%'))
   assert(P.translate('Durable damage')=='耐久伤害')
   assert(P.translate('Blast proximity (m)')=='近炸引信半径（米）')
   assert(P.translate('Lifetime (s)')~=P.translate('Lifetime randomness (s)'))
   assert(P.translate('Gas')=='毒气' and P.translate('Status damage')=='状态伤害')
  ''')
 def test_names_match_game_text(self):
  lua=LuaRuntime();lua.execute("package.path="+repr(str(ROOT/'offline/?.lua').replace('\\','/'))+"..';'..package.path")
  lua.execute('''local T=require('zh_game')
   assert(T.translate('Dominator')=='主宰' and T.translate('Nova')=='新星')
   local A=require('armory_data');local found
   for _,p in ipairs(A.list) do if p.id==7 then found=p.zh end end
   assert(found=='急救包')
  ''')

@unittest.skipUnless(LuaRuntime,'LuaJIT is needed')
class ReleaseTests(unittest.TestCase):
 def test_updater_skips_source_archive(self):
  lua=LuaRuntime();lua.execute("package.path="+repr(str(ROOT/'offline/?.lua').replace('\\','/'))+"..';'..package.path")
  lua.execute('''package.loaded.install={home='.'};local U=require('update')
   local base='https://github.com/'..U.REPO..'/releases/download/v3.2.0/'
   local source='{"tag_name":"v3.2.0","assets":[{"browser_download_url":"'..base..'SHODAN_3.2.0_Source.zip"}]}'
   assert(U.parse(source,'releases')==nil)
   local json=source:sub(1,-3)..',{"browser_download_url":"'..base..'SHODAN_3.2.0_Windows.zip"}]}'
   local release=assert(U.parse(json,'releases'))
   assert(release.version=='3.2.0' and release.name=='SHODAN_3.2.0_Windows.zip')
  ''')

class OfficialFlowTests(unittest.TestCase):
 def test_official_write_function_is_unchanged(self):
  text=(ROOT/'offline/install.lua').read_text(encoding='utf8')
  start=text.index('function M.write_files(');end=text.index('\n-- the files written by an install',start)
  self.assertEqual(hashlib.sha256(text[start:end].encode()).hexdigest(),'9b4ef05eb20d3a2c760ffa7933b40084802c7a290b57844e2a510aa8c7d45140')

class PackageTests(unittest.TestCase):
 def test_native_package_allowlist_and_manifest(self):
  from runpy import run_path
  VERSION=run_path(str(ROOT/'tools/package_lab.py'))['VERSION']
  path=ROOT/('dist/SHODAN_'+VERSION+'_Windows.zip')
  if not path.exists():self.skipTest('Build the release first')
  with zipfile.ZipFile(path) as z:
   names=z.namelist();self.assertEqual(sum(n.endswith('.exe') for n in names),1)
   self.assertFalse(any(n.endswith('/game folder.txt') for n in names))
   self.assertFalse(any('/python/' in n or n.endswith('.bmp') or 'Workbench' in n for n in names))
   prefix='SHODAN_'+VERSION+'/';manifest=json.loads(z.read(prefix+'manifest.json'))
   self.assertEqual(manifest['core_commit'],'c5d837150ea9ba48c631a5f69932439177fd3b21')
   for name,digest in manifest['files'].items():self.assertEqual(hashlib.sha256(z.read(prefix+name)).hexdigest(),digest)
if __name__=='__main__':unittest.main()
