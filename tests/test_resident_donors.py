"""Check PR16 donor IDs against actual bundles; no game files are written."""
import argparse,json,os,pathlib,sys

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',type=pathlib.Path,required=True);p.add_argument('--runtime-dir',type=pathlib.Path);a=p.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2',encoding='utf8')
    os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,str(a.vendor))
    from lupa.luajit21 import LuaRuntime
    lua=LuaRuntime();lua.globals().SHODAN_EUI=True
    app=a.runtime_dir.resolve()/'app' if a.runtime_dir else root/'offline';editor=app/'stat_editor.lua' if a.runtime_dir else root/'src/stat_editor.lua'
    lua.execute('arg={...}',editor.as_posix());lua.globals().B=lua.execute('return dofile(...)',(app/'host.lua').as_posix())
    result=lua.execute('''
    local R=ShodanStatEditor.resident;assert(R,'PR16 detector missing')
    local writes=0;require('install').write_files=function()writes=writes+1;error('Game writes forbidden')end
    B.editor_mode(false);B.items('Primary','');B.select('968211C0033DCE64')
    local function mode_row()
      for _,row in ipairs(B.registry['968211C0033DCE64'].rows)do if row.choice=='resomode'then return row end end
      error('Residency row missing')
    end
    B.rows();local mode=mode_row();local empty=assert(R.targets(mode));assert(#empty==0,'Unmodified weapon unexpectedly needs a package')
    local choices,pkgrow,shot
    for _,row in ipairs(B.rows())do
      if row.choice_kind=='package'then pkgrow=row.id;choices=B.choices(row.id)end
      if row.choice and row.choice_kind==''then shot=row.id end
    end
    assert(pkgrow and choices and shot)
    local chosen
    for _,c in ipairs(choices)do if c.id>0 then chosen=c;break end end
    B.choose(pkgrow,chosen.id);B.rows();mode=mode_row()
    local manual=assert(R.targets(mode));assert(#manual==1 and manual[1]==chosen.raw:lower(),
      'Manual picker ID was not converted to a filename: '..tostring(chosen.id)..' => '..table.concat(manual,',')..' expected '..tostring(chosen.raw))
    B.choose(pkgrow,0);B.choose(shot,253);B.rows();mode=mode_row()
    local targets=assert(R.targets(mode));assert(#targets>0,'Foreign projectile donor not detected')
    local ctx=assert(R.ctx());local patch=require('res_patch');local set=assert(patch._internal.bundle_index(ctx.root))
    for _,name in ipairs(targets)do
      assert(type(name)=='string' and #name==16 and name:match('^%x+$'),'Numeric picker ID leaked to patch interface')
      assert(set.packages[name],'Detected package does not exist: '..name)
    end
    local count=#targets
    -- Aggregate state must cover every automatic target, even with no manual selection.
    local get_module,get_ctx=R.module,R.ctx;local state=1
    local stale_group=false
    R.module=function()return setmetatable({
      state=function(_,_,name)assert(set.packages[name]);return state end,
      group=function(_,_,signature)if stale_group and not signature then return targets end end
    },{__index=patch})end
    R.ctx=function()return ctx end
    R.memo=nil;assert(R.state_of(mode)==1,'Installed auto-donor packages display as not installed')
    state=2;R.memo=nil;assert(R.state_of(mode)==2,'Light residency state lost')
    state=0;R.memo=nil;assert(R.state_of(mode)==0,'Missing residency state lost')
    state=1;stale_group=true;R.memo=nil;assert(R.state_of(mode)==0,'Stale dependency group displayed as installed')
    R.module,R.ctx=get_module,get_ctx;R.memo=nil
    local ok,why=R.act(mode,1);assert(not ok and why:find('测试模式',1,true),'Test guard failed')
    B.reset();B.editor_mode(true);B.items('Illuminate','')
    local shields=0
    for _,id in ipairs({'DAC7D53FE0749F5F','C0DF2A134BD15AD5'})do
      B.select(id);local special=false
      for _,r in ipairs(B.rows())do
        if r.label=='承受爆炸伤害（倍率）'then
          assert(r.original==3.4028234663852886e38,'Shield default was changed')
          assert(r.inline_note:find('0x7F7FFFFF',1,true),'Special original value was not explained')
          special=true
        end
      end
      assert(special,'Shield explosion field missing');shields=shields+1
    end
    assert(writes==0)
    return {detected_packages=count,manual_picker_to_filename=true,all_targets_exist_in_bundles=true,
      automatic_state=true,light_state=true,missing_state=true,test_write_guard=true,shield_originals_checked=shields,game_writes=0}
    ''')
    report=dict(result.items());(out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf8');print(json.dumps(report))

if __name__=='__main__':main()
