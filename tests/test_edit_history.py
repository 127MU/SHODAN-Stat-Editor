"""Session undo/redo against real parsed rows; isolated profile, no game writes."""
import argparse,json,os,pathlib,sys

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--vendor',required=True);a=p.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    profile=out/'profile';profile.mkdir();(profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2','utf8')
    os.environ.update(SHODAN_PROFILE=str(profile),SHODAN_QA_OUTPUT=str(out));sys.path.insert(0,a.vendor)
    from lupa.luajit21 import LuaRuntime
    lua=LuaRuntime();lua.globals().SHODAN_EUI=True;lua.execute('arg={...}',(root/'src/stat_editor.lua').as_posix())
    lua.globals().B=lua.execute('return dofile(...)',(root/'offline/host.lua').as_posix())
    result=lua.execute('''
        local count,flags,shared,choices=0,0,0,0
        for _,tab in ipairs({'Primary','Secondary','Support','Mechas','Attachments'})do
            for i,item in ipairs(B.items(tab,''))do
                if i>3 then break end;B.select(item.id)
                local rows=B.rows();local tested=0
                for _,r in ipairs(rows)do
                    if not r.choice and not r.code and type(r.value)=='number' and math.abs(r.value)<10000 and (tested<3 or r.flag) then
                        local v=r.flag and (r.value==0 and 1 or 0) or r.value+1
                        B.set(r.id,v);assert(B.rows()[r.id].value==v)
                        assert(B.history().undo>0);B.undo();assert(B.rows()[r.id].value==r.value)
                        B.redo();assert(B.rows()[r.id].value==v)
                        B.reset(r.id);B.undo();assert(B.rows()[r.id].value==v)
                        B.set(r.id,r.value);assert(B.history().redo==0)
                        assert(B.rows()[r.id].loaded_text==r.loaded_text,'Startup source changed after edit')
                        assert(B.rows()[r.id].original==r.original,'Restore baseline changed')
                        count=count+1;tested=tested+1
                        if r.flag then flags=flags+1 end;if #r.shared>0 then shared=shared+1 end
                    elseif r.choice_kind=='mountside' or r.choice_kind=='firemode' then
                        local options=B.choices(r.id)
                        for _,o in ipairs(options)do if o.id~=r.value then
                            B.choose(r.id,o.id);B.undo();assert(B.rows()[r.id].value==r.value)
                            B.redo();assert(B.rows()[r.id].value==o.id);B.choose(r.id,r.value);choices=choices+1;break
                        end end
                    end
                end
            end
        end
        assert(count>=20 and shared>0 and choices>0 and flags>0)
        local armor_checks=0
        for _,a in ipairs(B.armor_list)do
            local rows=B.armor_rows(a.id)
            if #rows>0 then
                local r=rows[1];local v=r.value+0.1
                local changed=B.armor_set(a.id,r.key,v)
                B.undo();assert(B.armor_rows(a.id)[1].value==r.value)
                B.redo();assert(B.armor_rows(a.id)[1].value==changed)
                B.armor_set(a.id,r.key,r.value);armor_checks=armor_checks+1;break
            end
        end
        local profile=B.armor_profile(999);local own=profile.own
        B.armor_update(999,nil,nil,not own,nil);B.undo();assert(B.armor_profile(999).own==own)
        B.redo();assert(B.armor_profile(999).own==not own);armor_checks=armor_checks+1
        assert(armor_checks==2)
        local r=B.rows()[1];local old=B.history().undo
        assert(not pcall(B.set,r.id,'invalid'));assert(B.history().undo==old)
        return {roundtrips=count,switches=flags,shared=shared,choices=choices,armor_checks=armor_checks,game_writes=0}
    ''')
    report=dict(result.items());(out/'report.json').write_text(json.dumps(report,indent=2),'utf8');print(json.dumps(report))
if __name__=='__main__':main()
