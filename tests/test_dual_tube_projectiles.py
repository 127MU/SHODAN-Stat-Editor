"""Dual tube capacities and foreign ammo attachment references; no game writes."""
import argparse,json,os,pathlib,sys

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',type=pathlib.Path,required=True);p.add_argument('--runtime-dir',type=pathlib.Path);a=p.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
    os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,str(a.vendor))
    from lupa.luajit21 import LuaRuntime
    lua=LuaRuntime();lua.globals().SHODAN_EUI=True
    app=a.runtime_dir.resolve()/'app' if a.runtime_dir else root/'offline';editor=app/'stat_editor.lua' if a.runtime_dir else root/'src/stat_editor.lua'
    lua.execute("package.path=.....';'..package.path",(app/'?.lua').as_posix())
    lua.execute('''
    local D=require('hostdata');local G=require('gamedata');local ffi=require('ffi');local load=D.load
    D.load=function(...)
      local result=load(...)
      for _,file in pairs(D.files)do for _,h in ipairs(G.headers(file.p,file.n))do
        if h.type==0x683E604F then
          local at=file.p+h.at+24+166544;assert(tonumber(ffi.cast('uint32_t*',at)[0])==264,'Fixture no longer matches the stock Punisher ammo attachment')
          ffi.cast('uint32_t*',at)[0]=220
        end
      end end
      return result
    end
    require('install').write_files=function()error('Game writes forbidden')end
    ''')
    lua.execute('arg={...}',editor.as_posix());lua.globals().B=lua.execute('return dofile(...)',(app/'host.lua').as_posix())
    result=lua.execute('''
    local ffi=require('ffi');local D=require('hostdata');local G=require('gamedata')
    local function find(key)
      for _,r in ipairs(B.rows())do if B.registry[SELECTED].rows[r.id].id==key then return r end end
    end
    local function select(hash,slot)B.items(slot or 'Primary','');B.select(hash);SELECTED=hash end
    select('41EAC4A03987FAA0');local swap=find('projectile');assert(swap.projectile_conflict,'Foreign attachment conflict was not detected')
    local source_count=#B.registry[SELECTED].rows[swap.id].parts;assert(source_count>=3,'Foreign edit hid an attachment source')
    B.choose(swap.id,352);assert(find('projectile').value==352 and not find('projectile').projectile_conflict,'Swap did not synchronize sources')
    local function raw(f)
      for _,file in pairs(D.files)do for _,h in ipairs(G.headers(file.p,file.n))do if h.type==f.kind then return tonumber(ffi.cast('uint32_t*',file.p+h.at+24+f.offset)[0])end end end
    end
    for _,p in ipairs(B.registry[SELECTED].rows[swap.id].parts)do assert(raw(p.field)==352,'Ammo attachment still overrides the selected projectile')end
    B.reset(swap.id);assert(find('projectile').value==264 and not find('projectile').projectile_conflict,'Restore did not restore all sources')
    local tubes=0
    for _,hash in ipairs({'D323DE60855898AC','41EAC4A03987FAA0','4F749E2EE26F532D'})do
      select(hash);local a,b=find('rounds_capacity'),find('rounds_capacity_2')
      assert(a and b and a.original==8 and b.original==8,'Tube defaults must remain 8+8')
      assert(a.label=='弹管 1 容量（发）'and b.label=='弹管 2 容量（发）')
      assert(a.inline_note:find('8 + 8 = 16',1,true),'Missing total capacity')
      B.set(a.id,10);assert(find('rounds_capacity_2').value==8,'First tube edit touched the second')
      assert(find('rounds_capacity').inline_note:find('10 + 8 = 18',1,true),'Total did not update')
      B.set(b.id,2);B.preset('save',3);local exported=B.preset_export('weapon',3)
      assert(exported:find('rounds_capacity_2',1,true),'Second tube missing in preset')
      B.reset(a.id);B.reset(b.id);B.preset('load',3)
      assert(find('rounds_capacity').value==10 and find('rounds_capacity_2').value==2,'Two tube preset failed')
      B.reset(a.id);B.reset(b.id);tubes=tubes+1
    end
    select('05D8D8C073B9D502');assert(not find('rounds_capacity_2')and find('capacity').original==10,'Plasma Punisher must keep its magazine')
    select('D323DE60855898AC');swap=find('projectile');local pkg=find('res_package');assert(swap.original==352)
    B.choose(swap.id,220);assert(find('projectile').value==220 and not find('projectile').projectile_conflict)
    local package
    for _,c in ipairs(B.choices(pkg.id))do if c.name:find('Cookout',1,true)or c.name:find('野炊',1,true)then package=c.id;break end end
    assert(package,'Cookout package not found');B.choose(pkg.id,package)
    assert(find('projectile').value==220,'Resource selection unexpectedly changed projectile')
    B.choose(swap.id,352);assert(find('projectile').value==352 and not find('projectile').projectile_conflict,'Cookout projectile cannot be restored')
    for _,p in ipairs(B.registry[SELECTED].rows[swap.id].parts)do assert(raw(p.field)==352,'Cookout source was not synchronized')end
    B.reset(swap.id);assert(find('projectile').value==352,'Stock Cookout projectile changed')
    return {dual_tube_weapons=tubes,defaults_eight_plus_eight=true,independent_tubes=true,preset_roundtrip=true,
      plasma_magazine_unchanged=true,foreign_ammo_attachment_preserved=true,source_conflicts_detected=true,
      projectile_swap_all_sources=true,resource_does_not_change_projectile=true,game_writes=0}
    ''')
    report=dict(result.items());(out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf8');print(json.dumps(report))

if __name__=='__main__':main()
