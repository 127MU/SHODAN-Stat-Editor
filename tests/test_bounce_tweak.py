"""Check navmesh deployment toggle with premodified data; never write the game."""
import argparse,json,os,pathlib,sys

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',type=pathlib.Path,required=True);a=p.parse_args()
 root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);profile=out/'profile';profile.mkdir()
 (profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8');os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,str(a.vendor))
 from lupa.luajit21 import LuaRuntime
 lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute("package.path=.....';'..package.path",(root/'offline/?.lua').as_posix())
 lua.execute('''local D=require('hostdata');local G=require('gamedata');local ffi=require('ffi');local load=D.load
 local nav_addresses={};local original_read=D.original_bytes
 D.original_bytes=function(address,size,...)
  local data=original_read(address,size,...)
  if nav_addresses[address] and size==1 and data then local value=data:byte();if math.floor(value/2)%2==0 then data=string.char(value+2)end end
  return data
 end
 D.load=function(...)
 local results={load(...)}
 for _,f in pairs(D.files)do for _,h in ipairs(G.headers(f.p,f.n))do
 if h.type==0x30EB6399 then
 local data=f.p+h.at+24;local count=tonumber(ffi.cast('uint32_t*',data+8)[0])
 for i=0,count-1 do local at=data+16+i*400+368;local flags=tonumber(at[0])
 nav_addresses[tonumber(ffi.cast('uintptr_t',at))]=true
 -- Emulate a prior tool clearing only the navmesh bit, plus an unrelated bit.
 if math.floor(flags/2)%2==1 then at[0]=flags-2 end
 if math.floor(tonumber(at[0])/4)%2==0 then at[0]=at[0]+4 end
 end end end end
 return unpack(results)end
 require('install').write_files=function()error('Game writes forbidden')end
 ''')
 lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix());lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
 result=lua.execute('''local function locate(fn,seen)
 seen=seen or {};if seen[fn]then return end;seen[fn]=true
 for i=1,30 do local n,v=debug.getupvalue(fn,i);if not n then break end;if n=='MOD'then return v end
 if type(v)=='function'then local found=locate(v,seen);if found then return found end end end end
 local MOD=assert(locate(B.tweaks))
 local t=MOD.tweaks.bounce;assert(#t.rows>0,'Previously modified records were lost')
 local D=require('hostdata');local G=require('gamedata');local ffi=require('ffi')
 local function check(on)
 for _,r in ipairs(t.rows)do
 -- All nav records here are in separate blocks: use original mapped address via typed table lookup.
 local tables;for i=1,30 do local n,v=debug.getupvalue(MOD.tweaks.apply,i);if n=='tables'then tables=v end end;assert(tables)
 for _,copy in ipairs(tables[r.kind].copies)do
 local raw=ffi.cast('uint8_t*',copy+24+r.off);local value=tonumber(raw[0])
 assert(math.floor(value/2)%2==(on and 0 or 1),'Navmesh bit not applied')
 assert(math.floor(value/4)%2==1,'Unrelated navigation bit lost')
 end end end
 B.tweaks('bounce',true);check(true)
 local changes,problems=D.diff();assert(#problems==0);local found=false
 for _,c in ipairs(changes)do if c.name=='generated_stratagem_settings.dl_bin'then found=true end;G.free(c.plain)end
 assert(found,'Toggle did not reach write plan')
 B.tweaks('bounce',false);check(false);B.tweaks('bounce',true);check(true)
 return {targets=#t.rows,premodified_records_recovered=true,unrelated_bits_preserved=true,toggle_roundtrip=true,write_plan=true,game_writes=0}
 ''')
 report=dict(result.items());(out/'report.json').write_text(json.dumps(report,indent=2),'utf8');print(json.dumps(report))
if __name__=='__main__':main()
