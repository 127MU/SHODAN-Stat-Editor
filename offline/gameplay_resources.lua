-- Version-checked ragdoll resource edits. Rebuild from local resources and keep
-- unrelated managed edits; never distribute or replace whole resource assets.
local M={}
local function unhex(text)return (text:gsub('%x%x',function(s)return string.char(tonumber(s,16))end))end
function M.transform(bytes,spec,on)
    if type(bytes)~='string' or #bytes~=spec.size then return nil,'布娃娃资源尺寸不匹配，未修改' end
    local chunks,position,active={},1,0
    for _,edit in ipairs(spec.edits)do
        local at,old,new=edit[1],unhex(edit[2]),unhex(edit[3])
        if at<position-1 or at+4>#bytes or #old~=4 or #new~=4 then return nil,'布娃娃修改配方无效，未修改'end
        local current=bytes:sub(at+1,at+4)
        if current~=old and current~=new then return nil,'布娃娃资源的目标字段已被其他修改改变，未覆盖'end
        if current==new then active=active+1 end
        chunks[#chunks+1]=bytes:sub(position,at);chunks[#chunks+1]=on and new or old;position=at+5
    end
    chunks[#chunks+1]=bytes:sub(position)
    return table.concat(chunks),active
end
function M.prepare(ctx,on)
    local R=require('res_patch');local recipe=require('ragdoll_recipe')
    local entry=R.entry_of(ctx,recipe.host,recipe.package)
    local overrides,why,extras=R.saved_overrides(ctx,recipe.host,recipe.package)
    if not overrides then return nil,why end
    local changed,active,total=0,0,0
    for _,spec in ipairs(recipe.resources)do
        local original,why=R.read_entry(ctx,recipe.package,spec.id,spec.type)
        if not original then return nil,why end
        if #original~=spec.size or require('gamedata').sha256_hex(original)~=spec.sha256 then
            return nil,'当前版本的布娃娃资源与已核验版本不同，未修改；需要重新适配'
        end
        local key=spec.type..':'..spec.id;local current=overrides[key] or original
        local bytes,count=M.transform(current,spec,on)
        if not bytes then return nil,count end
        active=active+count;total=total+#spec.edits
        if bytes~=current then changed=changed+1 end
        overrides[key]=bytes~=original and bytes or nil
    end
    return {recipe=recipe,entry=entry,overrides=overrides,extras=extras,changed=changed,active=active,total=total}
end
function M.preview(ctx)
    local plan,why=M.prepare(ctx,true);if not plan then return nil,why end
    return {supported=true,enabled=plan.active==plan.total,partial=plan.active>0 and plan.active<plan.total,
        resources=#plan.recipe.resources,fields=plan.total,
        message='已校验当前资源版本。实验性：调整受击与布娃娃状态，实际动作需进入游戏验证。此操作仅管理本编辑器的资源补丁。'}
end
function M.apply(ctx,on)
    local plan,why=M.prepare(ctx,on);if not plan then return nil,why end
    if plan.changed==0 then return true,on and '布娃娃优化已启用，无需重复写入' or '布娃娃优化未启用，无需恢复'end
    local R=require('res_patch');local recipe=plan.recipe;local ok,err
    if not on and plan.entry and plan.entry.mode=='res' and not next(plan.overrides)then
        ok,err=R.remove(ctx,recipe.host,recipe.package)
    else
        ok,err=R.install_with(ctx,recipe.host,recipe.package,plan.entry and plan.entry.mode or 'res',plan.overrides,plan.extras)
    end
    if not ok then return nil,err end
    return true,on and '布娃娃优化补丁已写入，重启游戏后生效' or '布娃娃优化已恢复，其他资源修改保留，重启游戏后生效'
end
return M
