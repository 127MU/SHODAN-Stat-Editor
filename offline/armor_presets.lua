-- Armor numeric snapshots are data, not Lua. Global equipment presets own them;
-- per-weapon and enemy presets leave armor alone.
local M={}
local ffi=require('ffi')
local function finite(v)return type(v)=='number' and v==v and math.abs(v)<=3.4028234663852886e38 end
function M.attach(B,D,ARM,AR)
    local function rows()
        local out={}
        for _,a in ipairs(AR.list)do
            for _,r in ipairs(D.armor_values(a.id))do
                out[r.key]={pid=a.id,key=r.key,value=r.value,default=r.default,label=r.label,name=a.zh}
            end
        end
        return out
    end
    function B.armor_capture()
        local all=rows();local keys={};for key in pairs(all)do keys[#keys+1]=key end;table.sort(keys)
        local lines={'AVP1'}
        for _,key in ipairs(keys)do
            local r=all[key];assert(finite(r.default) and finite(r.value),'护甲参数缺少可靠基准：'..key)
            lines[#lines+1]=string.format('%s %.17g %.17g',key,r.default,r.value)
        end
        return table.concat(lines,'\n')..'\n'
    end
    function B.armor_validate(text)
        assert(type(text)=='string' and #text<=1024*1024 and text:match('^AVP1\n'),'护甲预设数据无效')
        local all,seen,desired=rows(),{},{}
        for line in text:sub(6):gmatch('[^\n]+')do
            local key,base,raw=line:match('^(%d+:%d+:%d+:%d+:%d+) (%S+) (%S+)$')
            local r=key and all[key];base=tonumber(base);local value=tonumber(raw)
            assert(r and not seen[key],'护甲预设包含重复或失效参数：'..tostring(key))
            assert(finite(base) and finite(value),'护甲预设包含无效数值')
            assert(tonumber(ffi.new('float[1]',base)[0])==r.default,'护甲预设基准与当前版本不一致：'..key)
            local rounded=tonumber(ffi.new('float[1]',value)[0]);assert(finite(rounded),'护甲数值超出浮点范围')
            seen[key]=true;r.value=rounded;desired[#desired+1]=r
        end
        for key,r in pairs(all)do if not seen[key]then
            assert(finite(r.default),'护甲参数缺少可靠基准：'..key);r.value=r.default;desired[#desired+1]=r
        end end
        return desired
    end
    function B.armor_apply(text)ARM.apply_values(B.armor_validate(text));return true end
    function B.armor_count(text)
        local n=0;for _,r in ipairs(B.armor_validate(text))do if r.value~=r.default then n=n+1 end end;return n
    end
    function B.armor_compare(text)
        local wanted=B.armor_validate(text);local current=rows();local entries={}
        for _,r in ipairs(wanted)do
            local before=current[r.key].value
            if before~=r.value then entries[#entries+1]={equipment=r.name,parameter=r.label,
                before=tostring(before),after=tostring(r.value),file=AR.FILE}end
        end
        table.sort(entries,function(a,b)return a.equipment..a.parameter<b.equipment..b.parameter end)
        return entries
    end
end
return M
