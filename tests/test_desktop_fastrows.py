"""Navigation summaries preserve parameter values and avoid eager resource scans."""
import argparse
import json
import os
import sys
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--vendor', required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
root = Path(__file__).resolve().parents[1]
os.environ.update(SHODAN_PROFILE=str(a.output.resolve()), SHODAN_QA_OUTPUT=str(a.output.resolve()))
sys.path.insert(0, a.vendor)
from lupa.luajit21 import LuaRuntime

lua = LuaRuntime()
lua.globals().SHODAN_EUI = True
lua.execute('arg={...}', (root/'src/stat_editor.lua').as_posix())
lua.globals().B = lua.execute('return dofile(...)', (root/'offline/host.lua').as_posix())
lua.execute(r'''
local I=require('install');I.write_files=function()error('Game writes forbidden')end
I.write_patch=function()error('Game writes forbidden')end
local pages=0
for _,tab in ipairs({'Primary','Stratagems','Mechas','Records'})do
    local item=assert(B.items(tab,'')[1]);B.select(item.id)
    local impact=require('desktop_features');local old=impact.shared_index
    impact.shared_index=function()error('Eager shared scan on navigation')end
    local fast=B.rows_fast()
    impact.shared_index=old
    local complete=B.rows()
    assert(#fast==#complete,'Fast API lost parameters')
    local keys={'id','value','original','text','default_text','label','section','flag','choice','changed','code'}
    for n,row in ipairs(fast)do
        if not row.patch_pending then
            for _,key in ipairs(keys)do assert(row[key]==complete[n][key],tab..' changed '..tostring(row.label)..' '..key)end
        else assert(row.text=='待检查','Unscanned patch state shown as known')end
    end
    local section=fast[1].section
    for _,row in ipairs(B.rows_section(section))do
        assert(row.section==section and not row.patch_pending,'Section API did not resolve its fields')
    end
    pages=pages+1
end
local primary=B.items('Primary','')[1];B.select(primary.id)
local damage
for _,row in ipairs(B.rows_fast())do if row.label=='伤害'then damage=row;break end end
assert(damage and damage.value)
B.set(damage.id,damage.value+1)
local before=B.history().undo;assert(before>0)
B.tweaks();assert(B.history().undo==before,'Reading game tweaks erased undo history')
B.undo();assert(B.history().redo>0)
B.redo();assert(B.history().undo==before)
B.reset(damage.id)
assert(type(B.diagnostic_chain().entries)=='table','Reference chain missing')
assert(type(B.restore_task)=='function','Structured restore API missing')
''')
print(json.dumps({'categories': 4, 'value_parity': True, 'deferred_patch_state': True,
                  'game_tweaks_read_preserves_history': True, 'game_writes': 0}))
