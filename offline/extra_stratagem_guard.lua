-- Validate configured extra chains without assuming a particular game loadout.
local M={}
function M.validate(nodes,change)
    local by_id,roots,claimed,warnings,reported={},{},{},{},{}
    for _,node in ipairs(nodes)do
        local target=change and change.id==node.id and change.target or node.target
        by_id[node.id]={id=node.id,name=node.name,target=target or 0,original=node.original or 0}
    end
    for _,node in ipairs(nodes)do
        local current=by_id[node.id]
        if current.target~=0 and current.target~=current.original then roots[#roots+1]=current end
    end
    for _,root in ipairs(roots)do
        local visited={[root.id]=true}
        local target=root.target
        for hop=1,65 do
            if target==0 then break end
            if visited[target] or hop==65 then return '附赠战备形成循环：'..root.name..'。请取消其中一个附赠战备。',warnings end
            visited[target]=true
            local node=by_id[target]
            if not node then return '附赠战备无法识别：'..root.name..' → #'..tostring(target)..'。',warnings end
            local other=claimed[target]
            if other and other.id~=root.id then
                local key=other.id..':'..root.id..':'..target
                if not reported[key]then
                    reported[key]=true
                    warnings[#warnings+1]='附赠战备重复：'..other.name..' 与 '..root.name..' 都会附赠 '..node.name..'。同时携带可能导致任务加载崩溃；可以取消操作进行调整，也可以自行决定继续。'
                end
            end
            claimed[target]=other or root
            target=node.target
        end
    end
    return nil,warnings
end
return M
