-- Integrated mouse-driven armor selection and secondary value editor.
local ffi=require('ffi')
local M={plans={},on_change=function() end,navigate=function() end,tabs=function() return {} end,tr=function(x) return x end,transition=function() end}
local ui={mode='main',target=999,page=1,scroll=1,was={},message='',regions={},edit=nil,target_menu=false}
local C={back={255,237,242,234},panel={255,248,252,246},ink={255,23,46,35},muted={255,98,117,105},green={255,31,133,102},line={255,182,201,188},selected={255,217,238,223},white={255,255,255,255},warn={255,166,72,53}}
local function number(value) return string.format('%.9g',value) end
local function display(value) return string.format('%.6g',value) end
local function copy(profile)
    local out={enabled={},own=profile.own,conflicts=profile.conflicts,configured=profile.configured}
    for key,value in pairs(profile.enabled) do out.enabled[key]=value end
    return out
end
local function name(id)
    if id==999 then return '所有护甲' end
    for _,entry in ipairs(M.AR.list) do if entry.id==id then return entry.zh end end
    return '被动 #'..id
end
local function message(text) ui.message=text;ui.signature=nil end
function M.init(model,data,home)
    M.AR,M.D,M.path=model,data,home..'/armory-values.txt'
    local open=model.show
    model.show=function() open();M.transition();ui.mode='main';ui.edit=nil;ui.target_menu=false;ui.signature=nil end
    local file=io.open(M.path,'rb')
    if file then
        local content=file:read('*a');file:close()
        if content:match('^AFUI1\n') then
            for key,base,value in content:gmatch('(%d+:%d+:%d+:%d+:%d+)%s+(%S+)%s+(%S+)') do
                if tonumber(base) and tonumber(value) then M.plans[key]={pid=tonumber(key:match('^(%d+):')),default=tonumber(base),value=tonumber(value)} end
            end
        end
    end
end
function M.load_values()
    local accepted,skipped=0,0
    for key,plan in pairs(M.plans) do
        local found
        for _,row in ipairs(M.D.armor_values(plan.pid)) do if row.key==key then found=row;break end end
        local base=tonumber(ffi.new('float[1]',plan.default)[0])
        if found and found.default==base and M.D.set_armor_value(plan.pid,key,plan.value) then accepted=accepted+1
        else skipped=skipped+1 end
    end
    if accepted>0 then M.on_change() end
    if skipped>0 then message(skipped..' 条旧配置与当前数据不符，已跳过') end
    return accepted,skipped
end
local function save_values()
    local keys={};for key in pairs(M.plans) do keys[#keys+1]=key end;table.sort(keys)
    local file,why=io.open(M.path..'.tmp','wb');if not file then return nil,why end
    local ok=file:write('AFUI1\n')
    for _,key in ipairs(keys) do local p=M.plans[key];ok=ok and file:write(key,' ',number(p.default),' ',number(p.value),'\n') end
    file:close()
    if not ok then return nil,'写入失败' end
    if ffi.C.MoveFileExA(M.path..'.tmp',M.path,0x9)==0 then return nil,'无法替换配置文件' end
    return true
end
function M.set_value(pid,key,value)
    local old
    for _,row in ipairs(M.D.armor_values(pid)) do if row.key==key then old=row;break end end
    if not old then return nil,'当前版本找不到此效果' end
    local rounded,why=M.D.set_armor_value(pid,key,value)
    if rounded==nil then return nil,why end
    local previous=M.plans[key]
    M.plans[key]=rounded~=old.default and {pid=pid,default=old.default,value=rounded} or nil
    local ok,err=save_values()
    if not ok then M.D.set_armor_value(pid,key,old.value);M.plans[key]=previous;return nil,err end
    M.on_change();ui.rows=M.D.armor_values(pid);ui.signature=nil
    return rounded
end
function M.toggle(id)
    local shim=require('engine_shim');shim.pulse('toggle:'..id)
    local profile=M.AR.group(ui.target);local previous=copy(profile)
    profile.enabled[id]=not profile.enabled[id] or nil;profile.configured=true;M.AR.dirty=true
    if M.AR.save()==false then M.AR.profiles[ui.target]=previous;message('配置无法保存，请检查目录权限');return false end
    M.on_change();ui.signature=nil;return true
end
function M.secondary(id)
    M.transition()
    ui.mode,ui.pid,ui.scroll,ui.edit='values',id,1,nil
    ui.rows=M.D.armor_values(id);ui.signature=nil
end
local function commit()
    if not ui.edit then return true end
    local edit=ui.edit
    local value,why=M.set_value(ui.pid,edit.key,edit.text)
    if value==nil then message(why);return false end
    ui.edit=nil;message('数值已保存，点击主窗口「写入游戏」后生效');return true
end
local function change_profile(fn)
    local profile=M.AR.group(ui.target);local previous=copy(profile)
    fn(profile);profile.configured=true;M.AR.dirty=true
    if M.AR.save()==false then M.AR.profiles[ui.target]=previous;message('配置无法保存');return end
    M.on_change();ui.signature=nil
end
local function act(key)
    local kind,arg=key:match('^([^:]+):?(.*)$')
    if kind=='tab' then
        if not commit() then return end
        if arg=='Armors' then ui.mode='main';ui.signature=nil;M.transition()
        else M.AR.close();M.navigate(arg) end
    elseif kind=='exit' then M.AR.close()
    elseif kind=='targets' then ui.target_menu=not ui.target_menu
    elseif kind=='target' then ui.target=tonumber(arg);ui.target_menu=false
    elseif kind=='own' then change_profile(function(p) p.own=p.own==false end)
    elseif kind=='policy' then change_profile(function(p) p.conflicts=p.conflicts=='strongest' and 'stack' or 'strongest' end)
    elseif kind=='toggle' then M.toggle(tonumber(arg))
    elseif kind=='edit' then M.secondary(tonumber(arg))
    elseif kind=='back' then if commit() then ui.mode='main';ui.rows=nil;M.transition() end
    elseif kind=='all' then change_profile(function(p) p.enabled={};for _,passive in ipairs(M.AR.list) do p.enabled[passive.id]=true end end)
    elseif kind=='clear' then change_profile(function(p) p.enabled={} end)
    elseif kind=='page' then ui.page=math.max(1,ui.page+(arg=='next' and 1 or -1))
    elseif kind=='valuespage' then if commit() then ui.scroll=math.max(1,ui.scroll+(arg=='next' and 14 or -14)) end
    elseif kind=='input' then
        if commit() then local row=ui.rows[tonumber(arg)];ui.edit={key=row.key,text=number(row.value),fresh=true} end
    elseif kind=='apply' then commit()
    elseif kind=='reset' then local row=ui.rows[tonumber(arg)];local _,why=M.set_value(ui.pid,row.key,row.default);message(why or (M.D.armor_defaults_verified and '已恢复到游戏原版值' or '已恢复到备份中的数值（未验证为原版）'))
    end
    ui.signature=nil
end
function M.action(key) act(key) end
function M.flush() return commit() end
function M.invalidate() ui.signature=nil end
function M.effects() return ui.regions,ui.hover,'Armors',true end
local function pressed(shim,key)
    local now=tonumber(ffi.C.GetTickCount64())/1000
    if not shim.key_down(key) then ui.was[key]=nil;return false end
    if not ui.was[key] then ui.was[key]=now+0.4;return true end
    if now>=ui.was[key] then ui.was[key]=now+0.08;return true end
    return false
end
local function keyboard(shim)
    if not shim.focused() then return end
    if pressed(shim,0x1B) then
        if ui.target_menu then ui.target_menu=false
        elseif ui.edit then ui.edit=nil
        elseif ui.mode=='values' then ui.mode='main'
        else M.AR.close() end
        ui.signature=nil;return
    end
    if ui.edit and shim.key_down(0x11) and pressed(shim,0x41) then ui.edit.fresh=true end
end
function M.frame(shim)
    if not M.AR.is_open() then return end
    for _,event in ipairs(shim.take_text()) do
        if ui.edit then
            if event.kind=='enter' then commit()
            elseif event.kind=='backspace' then ui.edit.text=ui.edit.fresh and '' or ui.edit.text:sub(1,-2);ui.edit.fresh=false
            elseif event.kind=='text' then
                local text=event.text:gsub('[^%d%.,%-%+eE]','')
                if text~='' then ui.edit.text=(ui.edit.fresh and '' or ui.edit.text)..text;ui.edit.fresh=false end
            end
            ui.signature=nil
        end
    end
    keyboard(shim)
    local mx,my=shim.cursor();local focused=shim.focused();local hover
    if focused and mx then
        for i=#ui.regions,1,-1 do local r=ui.regions[i];if mx>=r.x and mx<r.x+r.w and my>=r.y and my<r.y+r.h then hover=r.key;break end end
    end
    local down=focused and shim.key_down(1)
    if down and not ui.down then ui.armed=hover end
    if not down and ui.down and ui.armed==hover and hover then act(hover) end
    ui.down=down;ui.hover=hover
    local wheel=shim.wheel or 0;shim.wheel=0
    if wheel~=0 and ui.mode=='values' and not ui.edit then ui.scroll=math.max(1,ui.scroll-(wheel>0 and 4 or -4));ui.signature=nil end
    local signature=table.concat({shim.w,shim.h,ui.mode,ui.target,ui.page,ui.scroll,tostring(ui.pid),tostring(hover),tostring(ui.target_menu),ui.edit and ui.edit.text or '',ui.message},'|')
    if ui.signature==signature then return end
    ui.signature=signature;ui.regions={}
    local s=shim.h/1080;local width=shim.w/s
    local function fill(x,y,w,h,color) shim.fill(x*s,y*s,(x+w)*s,(y+h)*s,color) end
    local function txt(text,x,y,size,color,bold,limit)
        text=tostring(text);size=size or 16
        if limit then while size>10 and shim.text_width(text,size*s)>limit*s do size=size-0.5 end end
        shim.text(text,x*s,y*s,size*s,color or C.ink,bold)
    end
    local function button(key,label,x,y,w,h,active)
        fill(x,y,w,h,active and C.selected or hover==key and C.selected or C.panel)
        fill(x,y,w,1,active and C.green or C.line);fill(x,y+h-1,w,1,C.line)
        fill(x,y,1,h,C.line);fill(x+w-1,y,1,h,C.line)
        txt(label,x+10,y+h/2+5,15,active and C.green or C.ink,false,w-20)
        ui.regions[#ui.regions+1]={key=key,x=x*s,y=y*s,w=w*s,h=h*s}
    end
    fill(0,0,width,1080,C.back)
    fill(30,50,width-60,980,C.panel)
    fill(30,50,width-60,1,C.green);fill(30,1029,width-60,1,C.green)
    fill(30,50,1,980,C.green);fill(width-31,50,1,980,C.green)
    local tabs=M.tabs();local widths,total={},0
    for i,tab in ipairs(tabs) do widths[i]=math.max(#tab*7+8,shim.text_width(M.tr(tab),16*s)/s+18);total=total+widths[i] end
    local fit=math.min(1,(1000-16-124-16-4*(#tabs-1))/math.max(1,total));local tx=46
    for i,tab in ipairs(tabs) do local w=math.floor(widths[i]*fit+0.5);button('tab:'..tab,M.tr(tab),tx,62,w,32,tab=='Armors');tx=tx+w+4 end
    txt(ui.mode=='values' and ('被动数值 / '..name(ui.pid)) or '护甲与被动',46,130,22,C.green,true)
    if ui.mode=='values' then button('back','返回被动列表',width-192,108,146,34) end
    if ui.mode=='main' then
        local profile=M.AR.group(ui.target)
        button('targets','应用护甲：'..name(ui.target),46,152,324,36,true)
        button('own',(profile.own~=false and '[√] ' or '[  ] ')..'保留原生被动',386,152,220,36,profile.own~=false)
        button('policy',profile.conflicts=='strongest' and '同类效果：保留最强' or '同类效果：叠加',622,152,width-668,36)
        local count=0;for _,v in pairs(profile.enabled) do if v then count=count+1 end end
        txt('勾选需要叠加的被动；点击「修改数值」进入二级页面。',46,223,16,C.muted)
        button('all','全选',width-224,202,82,32);button('clear','清空',width-132,202,86,32)
        local percol=17;local pages=math.max(1,math.ceil(#M.AR.list/(percol*2)));ui.page=math.min(ui.page,pages)
        local cw=(width-110)/2;local first=(ui.page-1)*percol*2+1
        for i=first,math.min(#M.AR.list,first+percol*2-1) do
            local item=M.AR.list[i];local n=i-first;local col=n%2;local row=math.floor(n/2);local x=46+col*(cw+18);local y=246+row*43
            button('toggle:'..item.id,(profile.enabled[item.id] and '[√] ' or '[  ] ')..item.zh,x,y,cw-110,36,profile.enabled[item.id])
            if #M.D.armor_values(item.id)>0 then button('edit:'..item.id,'修改数值',x+cw-104,y,104,36) end
        end
        txt('已选择 '..count..' / '..#M.AR.list..' 个被动',46,992,16,C.green,true)
        if pages>1 then button('page:prev','上一页',width-270,938,104,36);button('page:next','下一页',width-156,938,110,36) end
        if ui.target_menu then
            fill(46,108,width-92,890,C.panel);ui.regions={}
            txt('选择要应用的护甲组',46,134,22,C.green,true)
            button('targets','取消',width-156,108,110,36)
            for i,id in ipairs(M.AR.groups) do
                local col=(i-1)%3;local row=math.floor((i-1)/3);local cw2=(width-116)/3
                button('target:'..id,name(id),46+col*(cw2+12),160+row*60,cw2,48,id==ui.target)
            end
        end
    else
        txt('仅列出此被动对应的可修改项。输入数值后按回车或点击「应用」。',46,170,16,C.muted)
        local rows=ui.rows or {};ui.scroll=math.max(1,math.min(ui.scroll,math.max(1,#rows-13)))
        for i=ui.scroll,math.min(#rows,ui.scroll+13) do
            local row=rows[i];local y=194+(i-ui.scroll)*48;local editing=ui.edit and ui.edit.key==row.key
            fill(46,y,width-92,42,(i-ui.scroll)%2==0 and C.panel or C.back)
            txt(row.label,58,y+27,16,C.ink,false,width-490)
            txt((M.D.armor_defaults_verified and '游戏原值 ' or '备份值 ')..display(row.default),width-448,y+27,12,C.muted,false,132)
            button('input:'..i,editing and (ui.edit.text..'_') or display(row.value),width-302,y+3,132,36,editing)
            button(editing and 'apply' or 'input:'..i,editing and '应用' or '输入',width-160,y+3,52,36,editing)
            button('reset:'..i,'恢复',width-100,y+3,54,36)
        end
        txt('第 '..ui.scroll..'—'..math.min(#rows,ui.scroll+13)..' 项 / 共 '..#rows..' 项',46,952,16,C.muted)
        button('valuespage:prev','上一页',width-270,938,104,36);button('valuespage:next','下一页',width-156,938,110,36)
    end
    fill(46,1000,width-92,1,C.line)
    txt(ui.message~='' and ui.message or '配置自动保存；点击下方「写入游戏」使修改生效。',46,1020,13,ui.message~='' and C.green or C.muted,false,width-60)
end
return M
