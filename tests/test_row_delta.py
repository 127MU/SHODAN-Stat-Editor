"""Compare partial parameter refresh with full reads, without game writes."""
import argparse
import json
import os
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--vendor', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    profile = out / 'profile'
    profile.mkdir()
    (profile/'gamefolder.txt').write_text('D:/steam/steamapps/common/Helldivers 2', encoding='utf8')
    os.environ.update(SHODAN_PROFILE=str(profile), SHODAN_QA_OUTPUT=str(out))
    sys.path.insert(0, str(args.vendor))
    from lupa.luajit21 import LuaRuntime
    lua = LuaRuntime()
    lua.globals().SHODAN_EUI = True
    lua.execute('arg={...}', (root/'src/stat_editor.lua').as_posix())
    lua.globals().B = lua.execute('return dofile(...)', (root/'offline/host.lua').as_posix())
    result = lua.execute('''
        local checks,flags,partial=0,0,0
        for _,tab in ipairs({'Primary','Secondary','Support','Mechas','Attachments'})do
            for i,item in ipairs(B.items(tab,''))do
                if i>8 then break end
                B.select(item.id)
                local original=B.rows()
                local tested=0
                for _,row in ipairs(original)do
                    if not row.choice and not row.code and type(row.value)=='number' and math.abs(row.value)<100000 and (tested<4 or row.flag) then
                        local next_value=row.flag and (row.value==0 and 1 or 0) or row.value+1
                        if pcall(B.set,row.id,next_value) then
                            local delta=B.rows_delta(row.id)
                            local full=B.rows()
                            assert(#delta>0)
                            local seen={}
                            for _,r in ipairs(delta)do
                                assert(r.value==full[r.id].value and r.original==full[r.id].original)
                                seen[r.id]=true
                            end
                            for _,r in ipairs(full)do
                                if r.value~=original[r.id].value then assert(seen[r.id],'Changed shared row missing from delta')end
                            end
                            assert(seen[row.id]);B.reset(row.id)
                            for _,r in ipairs(B.rows_delta(row.id))do assert(r.value==original[r.id].value)end
                            checks=checks+1;if row.flag then flags=flags+1 end
                            if #delta<#full then partial=partial+1 end
                            tested=tested+1
                        end
                    end
                end
            end
        end
        assert(checks>=40 and partial>0 and flags>0)
        return {checks=checks,flags=flags,partial_refreshes=partial,game_writes=0}
    ''')
    report = dict(result.items())
    (out/'report.json').write_text(json.dumps(report, indent=2), encoding='utf8')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
