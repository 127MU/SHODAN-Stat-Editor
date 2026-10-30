-- Read-only graph traversal. IDs stay in their own namespace; cycles are edges,
-- never recursive expansion. No table values or resource patches are changed.
local M={}
function M.build(roots,read_node)
    local out={nodes={},edges={},entries={},warnings={}}
    local seen,expanded,edge_seen={},{},{}
    local labels={shot='射弹',blast='爆炸',damage='伤害',status='状态效果',arc='电弧',beam='激光'}
    local visit
    visit=function(kind,id,parent,via,depth)
        if type(id)~='number' or id<=0 then return end
        local key=kind..':'..string.format('%.0f',id)
        local edge=(parent or '')..'>'..key..':'..(via or '')
        if edge_seen[edge]then return end;edge_seen[edge]=true
        if #out.entries>=512 or depth>24 then out.warnings[1]='引用链过大，显示已限制为 512 条、24 层。';return end
        local node=seen[key]
        if not node then
            node=read_node(kind,id) or {exists=false};node.kind=kind;node.id=id;node.key=key
            node.title=(labels[kind] or kind)..' #'..id..(node.name and node.name~='' and (' · '..node.name) or '')
            seen[key]=node;out.nodes[#out.nodes+1]=node
        end
        out.edges[#out.edges+1]={source=parent or '',target=key,via=via or ''}
        out.entries[#out.entries+1]={key=key,title=node.title,parent=parent or '',parent_title=parent and seen[parent] and seen[parent].title or '',via=via or '',depth=depth,
            summary=node.summary or '',record_hash=node.record_hash or '',missing=node.exists==false,
            repeated=expanded[key] or false}
        if expanded[key] or node.exists==false then return end
        expanded[key]=true
        for _,link in ipairs(node.links or {})do visit(link.kind,link.id,key,link.via,depth+1)end
    end
    for _,root in ipairs(roots)do visit(root.kind,root.id,nil,root.via or '当前装备',0)end
    return out
end
return M
