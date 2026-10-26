-- Desktop-only previews and portable data presets. Input is parsed as data;
-- no Lua is evaluated and no game files are written here.
local M={}
local function finite(v)return type(v)=='number' and v==v and math.abs(v)~=math.huge end
local function clean_name(s)
    s=tostring(s or ''):gsub('[%z\1-\31\127]',' '):match('^%s*(.-)%s*$')
    assert(s~='' and #s<=96,'名称不能为空，且最多 32 个汉字或 96 个字节')
    return s
end
local function hex(s)return (s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)
    assert(#s%2==0 and not s:find('[^%x]'),'预设名称编码无效')
    return (s:gsub('%x%x',function(c)return string.char(tonumber(c,16))end))
end
function M.encode(kind,name,weapon,values,editor)
    local lines={'SHODAN-PRESET 1','kind '..kind,'name '..hex(clean_name(name))}
    if kind=='full' and editor then lines[#lines+1]='editor '..editor end
    if kind=='weapon' then lines[#lines+1]='weapon '..weapon end
    for _,v in ipairs(values) do lines[#lines+1]=string.format('value %s %s %.17g',v.hash,v.id,v.value) end
    return table.concat(lines,'\n')..'\n'
end
function M.decode(text)
    assert(type(text)=='string' and #text<=8*1024*1024,'预设文件过大')
    assert(not text:find('%z'),'预设文件包含无效字符')
    text=text:gsub('\r\n','\n')
    local result={values={}};local seen={};local first=true
    for line in (text..'\n'):gmatch('(.-)\n') do
        if first then assert(line=='SHODAN-PRESET 1','不是支持的 SHODAN 预设文件');first=false
        elseif line~='' then
            local key,body=line:match('^(%w+) (.+)$');assert(key,'预设行格式错误')
            if key=='value' then
                local hash,id,raw=body:match('^(%x+)%s+([%w_]+)%s+(%S+)$')
                local value=tonumber(raw);assert(hash and #hash==16 and finite(value),'预设含无效参数或数值')
                hash=hash:upper();local k=hash..':'..id;assert(not seen[k],'预设存在重复参数');seen[k]=true
                result.values[#result.values+1]={hash=hash,id=id,value=value}
                assert(#result.values<=50000,'预设参数过多')
            else
                assert((key=='kind' or key=='name' or key=='weapon' or key=='editor') and not result[key],'预设包含未知或重复字段')
                result[key]=body
            end
        end
    end
    assert(result.kind=='weapon' or result.kind=='full','预设类型无效')
    assert(result.editor==nil or result.editor=='enemy' or result.editor=='equipment','预设编辑器类型无效')
    result.name=clean_name(unhex(assert(result.name,'缺少预设名称')))
    if result.kind=='weapon' then
        assert(result.weapon and #result.weapon==16 and result.weapon:match('^%x+$'),'缺少装备标识')
        result.weapon=result.weapon:upper()
        for _,v in ipairs(result.values) do assert(v.hash==result.weapon,'装备预设混入了其它装备') end
    else assert(not result.weapon,'全局预设不应包含单个装备标识') end
    return result
end
-- Candidates come from field users, but a weapon can rebuild its rows after
-- changing ammunition. Verify its current rows to reject stale references.
function M.shared_index(registry)
    local index={}
    for _,other in pairs(registry or {}) do
        local seen={}
        for _,row in ipairs(other.rows or {}) do for _,p in ipairs(row.parts or {}) do
            local key=p.field.key
            if not seen[key] then
                seen[key]=true;index[key]=index[key] or {};index[key][#index[key]+1]=other
            end
        end end
    end
    return index
end
function M.shared(owner,parts,tr,index)
    local out,seen={},{};tr=tr or function(s)return s end
    for _,part in ipairs(parts or {}) do
        for _,other in ipairs(index and index[part.field.key] or part.field.users or {}) do
            local id=other.hash or other
            if other~=owner and not seen[id] and (owner.record or not other.record) then
                local current=false
                for _,row in ipairs(other.rows or {}) do
                    for _,p in ipairs(row.parts or {}) do
                        if p.field.key==part.field.key then current=true;break end
                    end
                    if current then break end
                end
                if current then
                    seen[id]=true;out[#out+1]={id=other.hash or '',name=tr(other.name or '未命名记录'),
                        category=other.record and '数据记录' or '装备'}
                end
            end
        end
    end
    table.sort(out,function(a,b)if a.name==b.name then return a.id<b.id end;return a.name<b.name end)
    return out
end
function M.attach(B,C)
    local P=C.presets;local names={}
    local path=C.path('preset_names.txt')
    local f=io.open(path,'rb')
    if f then
        for line in f:lines() do
            local hash,n,name=line:match('^(%x+)%s+([1-5])%s+(%x+)$')
            if hash and #hash==16 then local ok,s=pcall(unhex,name);if ok then names[hash:upper()..':'..n]=s end end
        end
        f:close()
    end
    local function name_key(n)return assert(C.selected(),'请先选择装备').hash..':'..n end
    local function save_names()
        local lines={};for k,v in pairs(names) do lines[#lines+1]=k:gsub(':',' ')..' '..hex(v) end
        table.sort(lines);assert(C.write(path,table.concat(lines,'\n')..'\n'),'预设名称保存失败')
    end
    local function source(kind,n)
        assert(kind=='weapon' or kind=='full','预设类型无效')
        n=assert(tonumber(n));assert(n%1==0 and n>=1 and n<=(kind=='weapon' and 5 or P.full_count),'预设编号无效')
        if kind=='weapon' then
            local w=assert(C.selected(),'请先选择装备');local values=assert(P.weapon_preset(w,n),'此预设尚未保存')
            local out={};for _,v in ipairs(values) do out[#out+1]={hash=w.hash,id=v.id,value=v.value} end
            return {kind=kind,name=names[name_key(n)] or ('预设 '..n),weapon=w.hash,values=out}
        end
        local preset=assert((P.list and P.list() or P.full)[n],'找不到全局预设')
        return {kind=kind,name=preset.name,values=preset.values,editor=C.editor and C.editor() or nil}
    end
    local function validate(bundle,allow_missing)
        if bundle.kind=='full' and C.editor then assert((bundle.editor or 'equipment')==C.editor(),'预设属于另一种编辑器，请先切换装备或敌人编辑') end
        local fields,warnings,accepted={},{},0
        for _,o in ipairs(bundle.values) do
            local w=C.by_hash[o.hash]
            if w and bundle.kind=='full' and C.in_scope then assert(C.in_scope(w),'预设混入了另一种编辑器的数据') end
            local resolved,why=o.id,nil
            if w and C.preset_id then resolved,why=C.preset_id(w,o.id,bundle.values) end
            if why then error(why,0) end
            local parts=w and resolved and C.parts(w,resolved,bundle.values)
            if not w or not parts or not parts[1] then
                local reason=not w and ('当前版本没有此装备：'..o.hash) or
                    ((C.name and C.name(w) or C.tr(w.name))..'：当前版本没有参数 '..o.id)
                if not allow_missing then error(reason,0) end
                warnings[#warnings+1]=reason..'（将跳过，原预设保留）'
            else
                accepted=accepted+1
            for _,p in ipairs(parts) do
                local f=p.field;local v=o.value;assert(not f.allowed or f.allowed[v],f.allowed and f.allowed.why or '预设含无效选项');local limit=(f.storage=='u32' and 4294967295 or f.storage=='u16' and 65535 or f.storage=='u8' and 255 or (f.storage=='flag' or f.storage=='bit') and 1 or 3.4028234663852886e38)
                assert(finite(v) and v>=((f.storage=='f32' or f.storage=='virtual') and -limit or 0) and v<=limit,'预设数值超出字段范围：'..o.id)
                if f.storage=='flag' or f.storage=='bit' then assert(v==0 or v==1,'开关数值必须为 0 或 1') end
                if f.storage=='u32' or f.storage=='u16' or f.storage=='u8' or f.storage=='grenade' then assert(v%1==0,'编号和整数参数不能有小数') end
                if f.storage=='u16' then assert(v<=65535,'数值超出 16 位范围') end
                if f.storage=='u8' then assert(v<=255,'数值超出 8 位范围') end
                assert(fields[f.key]==nil or fields[f.key]==v,'预设对共享参数指定了互相冲突的值：'..o.hash..' '..o.id..' ['..f.key..'] '..tostring(fields[f.key])..' / '..tostring(v))
                fields[f.key]=v
            end
            end
        end
        if allow_missing and #warnings>0 and accepted==0 then
            error('此预设的 '..#warnings..' 项参数均无法识别，已停止读取以免清空当前修改。请使用创建预设时的版本重新导出。首项：'..warnings[1],0)
        end
        if C.validate_values then C.validate_values(bundle,fields) end
        local skipped=#warnings
        if C.preset_warnings then for _,warning in ipairs(C.preset_warnings(bundle,fields))do warnings[#warnings+1]=warning end end
        return fields,warnings,accepted,skipped
    end
    local function describe(w,p,before,after,index)
        return {equipment=C.name and C.name(w) or C.tr(w.name),parameter=C.tr(p.row and p.row.label or p.id),
            before=C.number(before),after=C.number(after),file=C.file(p.field),shared=M.shared(w,{p},C.tr,index)}
    end
    local function current_registry()
        local all={};for id,w in pairs(C.by_hash) do all[id]=w end
        for id,w in pairs(C.record_pages and C.record_pages() or {}) do all[id]=w end
        return all
    end
    local function compare(bundle,allow_missing)
        local desired,warnings,accepted,skipped=validate(bundle,allow_missing);local out,seen={},{};local registry=current_registry();local index=M.shared_index(registry)
        for _,w in pairs(registry) do
            if (bundle.kind=='full' and (not C.in_scope or C.in_scope(w))) or w.hash==bundle.weapon then
                for _,row in ipairs(w.rows or {}) do for _,p in ipairs(row.parts) do
                    local f=p.field
                    if not seen[f.key] then
                        seen[f.key]=true;local before=f.pending_value or C.read(f);local after=desired[f.key]
                        if after==nil then after=C.default(f) end
                        if before~=nil and after~=nil and math.abs(before-after)>1e-6 then out[#out+1]=describe(w,p,before,after,index) end
                    end
                end end
            end
        end
        table.sort(out,function(a,b)return a.equipment..a.parameter<b.equipment..b.parameter end)
        return {name=bundle.name,entries=out,count=#out,kind=bundle.kind,warnings=warnings,skipped=skipped,accepted=accepted}
    end
    function B.preset_info(slot)
        local w=assert(C.selected());local values=P.weapon_preset(w,slot)
        return {name=names[name_key(slot)] or ('预设 '..slot),saved=values~=nil,count=values and #values or 0}
    end
    function B.preset_rename(kind,n,name)
        name=clean_name(name)
        if kind=='weapon' then
            assert(n>=1 and n<=5 and n%1==0,'预设编号无效');local k=name_key(n);local old=names[k];names[k]=name
            local ok,why=pcall(save_names);if not ok then names[k]=old;error(why) end
        else local p=assert((P.list and P.list() or P.full)[n]);P.full_put(n,name,p.values) end
        return '预设名称已保存'
    end
    function B.preset_compare(kind,n)return compare(source(kind,n),true)end
    -- Apply the same compatibility check for direct API/MCP loads as for the dialog.
    for method,kind in pairs({preset='weapon',full_preset='full'}) do
        local load=B[method]
        if type(load)=='function' then B[method]=function(action,n,...)
            local preview=action=='load' and compare(source(kind,n),true)
            local message=load(action,n,...)
            if preview and preview.skipped>0 then
                message=tostring(message)..'；已跳过 '..preview.skipped..' 项失效参数，原预设保留。'
            end
            return message
        end end
    end
    function B.preset_export(kind,n)
        local s=source(kind,n);local values,seen={},{}
        for _,v in ipairs(s.values) do
            local w=C.by_hash[v.hash];local id,why=v.id,nil
            if w and C.preset_id then id,why=C.preset_id(w,v.id,s.values) end
            if why then error(why,0) end
            id=id or v.id;local key=v.hash..':'..id
            assert(seen[key]==nil or seen[key]==v.value,'预设的旧名称与槽位名称指定了不同数值')
            if seen[key]==nil then values[#values+1]={hash=v.hash,id=id,value=v.value};seen[key]=v.value end
        end
        return M.encode(kind,s.name,s.weapon,values,s.editor)
    end
    local function imported(kind,text)
        local bundle=M.decode(text);assert(bundle.kind==kind,'导入预设的类型不匹配')
        if kind=='weapon' then assert(bundle.weapon==assert(C.selected()).hash,'此预设属于其它装备，请先选择对应装备') end
        validate(bundle);return bundle
    end
    function B.preset_inspect(kind,text)return compare(imported(kind,text))end
    function B.preset_import(kind,n,text)
        local bundle=imported(kind,text)
        if kind=='weapon' then
            assert(n>=1 and n<=5 and n%1==0,'预设编号无效')
            local values={};for _,o in ipairs(bundle.values) do values[#values+1]={id=o.id,value=o.value} end
            local k=name_key(n);local old=names[k];names[k]=bundle.name
            local named,why=pcall(save_names);if not named then names[k]=old;error(why) end
            local stored,reason=pcall(P.weapon_put,assert(C.selected()),n,values)
            if not stored then names[k]=old;pcall(save_names);error(reason) end
        else n=P.full_put(nil,bundle.name,bundle.values) end
        return {id=n,message='预设已导入，读取后才会改变编辑器数值'}
    end
    function B.pending_preview()
        local out,seen={},{};local index=M.shared_index(current_registry())
        for _,o in ipairs(C.overrides()) do
            local w=C.by_hash[o.hash];local parts=w and C.parts(w,o.id,C.overrides());local p=parts and parts[1]
            if p and not seen[p.field.key] then
                local d=C.default(p.field)
                if d~=nil and math.abs(o.value-d)>1e-6 then out[#out+1]=describe(w,p,d,o.value,index);seen[p.field.key]=true end
            end
        end
        table.sort(out,function(a,b)return a.equipment..a.parameter<b.equipment..b.parameter end)
        return out
    end
end
return M
