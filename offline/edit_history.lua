-- Session-only parameter history. Patch installation is deliberately excluded.
local M={}
function M.attach(B,C)
    local undo,redo={},{}
    local depth=0
    local function status()
        local entries={};for i=#undo,1,-1 do entries[#entries+1]={label=undo[i].label,count=undo[i].changes and #undo[i].changes or 1}end
        return {undo=#undo,redo=#redo,undo_label=undo[#undo] and undo[#undo].label or '',redo_label=redo[#redo] and redo[#redo].label or '',entries=entries}
    end
    local function push(entry)
        undo[#undo+1]=entry;redo={};if #undo>100 then table.remove(undo,1)end
    end
    B._record_edit=function(label,before,after,apply)
        assert(type(apply)=='function','仅供内部编辑事务使用')
        push({label=label,before=before,after=after,apply=apply})
    end
    B.history=status
    local function replay(from,to,reverse)
        local entry=assert(from[#from],'没有可撤销或重做的编辑')
        if entry.apply then entry.apply(reverse and entry.before or entry.after,reverse and entry.after or entry.before)
        else C.restore(entry,reverse)end
        table.remove(from);to[#to+1]=entry
        return status()
    end
    B.undo=function()return replay(undo,redo,true)end
    B.redo=function()return replay(redo,undo,false)end
    for _,name in ipairs({'set','choose','reset','code_set'})do
        local original=B[name]
        B[name]=function(...)
            if depth>0 then return original(...)end
            local before=C.capture(...)
            depth=depth+1
            local ok,result=pcall(original,...)
            depth=depth-1
            if not ok then error(result,0)end
            if before then
                local entry=C.finish(before)
                if entry then
                    push(entry)
                end
            else undo={};redo={} end
            return result
        end
    end
    -- Bulk loads can touch fields outside the visible owner. Start a new history
    -- after these operations so replay never replaces unrelated preset values.
    for _,name in ipairs({'preset','full_preset','preset_import','tweaks'})do
        local original=B[name]
        if original then B[name]=function(...)
            local result=original(...)
            local action=select(1,...)
            if name=='tweaks' or action=='load' then undo={};redo={}end
            return result
        end end
    end
end
return M
