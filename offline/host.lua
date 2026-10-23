-- SHODAN Stat Editor Offline: Stat Editor's own panel (stat_editor.lua, the in-game mod) in a desktop window,
-- editing the game's data files instead of the running game. The files are decrypted into memory as the game
-- holds them, the panel finds and edits them there, and Install writes the changed ones into the game folder.
-- host.lua [stat_editor.lua]
local here = (debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or './')
package.path = here .. '?.lua;' .. package.path

local ffi = require('ffi')
local shim = require('engine_shim')
local G = require('gamedata')
local D = require('hostdata')
local I = require('install')
local U = require('update')
local AR = require('armory')
local ARM = require('armor_ui')
-- An opt-in render check for the packaged application; never writes game files.
local qa_output = os.getenv('SHODAN_QA_OUTPUT')
if qa_output then U.available = false end

pcall(ffi.cdef, 'uint64_t GetTickCount64(void);')
local function clock() return tonumber(ffi.C.GetTickCount64()) / 1000 end
local log_file = nil
local function log(text)
    if not log_file then
        I.mkdirs(I.logs)
        log_file = io.open(I.logs .. '/SHODANStatEditorHost.log', 'w')
        if not log_file then log_file = false end
    end
    if log_file then log_file:write(os.date('%H:%M:%S '), text, '\n'); log_file:flush() end
end

local BACK = { 255, 237, 242, 234 }
local GOLD, WHITE, MUTED, WARN, GOOD = { 255, 31, 133, 102 }, { 255, 23, 37, 33 }, { 255, 97, 112, 107 },
                                        { 255, 160, 91, 36 }, { 255, 31, 133, 102 }

local function centred(text, y, size, c)
    shim.text(text, (shim.w - shim.text_width(text, size)) / 2, y, size, c)
end

-- a screen with a few lines of text (loading, problems)
local function screen(lines)
    shim.fill(0, 0, shim.w, shim.h, BACK)
    local s = shim.h / 1080
    local y = shim.h * 0.42
    for k, line in ipairs(lines) do
        local size = (k == 1 and 34 or 20) * s
        centred(line, y, size, k == 1 and GOLD or MUTED)
        y = y + size * 1.8
    end
    shim.present()
end

local function fatal(text)
    log('stopped: ' .. text)
    if qa_output then local f=io.open(qa_output..'/failure.txt','wb');if f then f:write(text);f:close() end
    else shim.message_box(text, 0x10) end
    os.exit(1)
end

-- ---------------------------------------------------------------- start
-- where the window was when it last closed: its top left (window.txt: x y)
local PLACE = I.home .. '/window.txt'
local function saved_place()
    local f = io.open(PLACE, 'r')
    local text = f and f:read('*a') or ''
    if f then f:close() end
    local x, y = text:match('^(%-?%d+) (%-?%d+)')
    return x and { tonumber(x), tonumber(y) } or nil
end

local THEME=I.home..'/theme.txt'
local function main()
    local theme_file=io.open(THEME,'rb')
    local selected_theme=theme_file and theme_file:read('*a') or 'light'
    if theme_file then theme_file:close() end
    shim.set_theme(selected_theme:match('dark') and 'dark' or 'light')
    shim.open('SHODAN 数值编辑器 3.2.0', saved_place())
    shim.pump()
    local migrated = I.migrate()
    if migrated then log('copied ' .. migrated .. ' files from the CowboyBingus folder') end
    screen({ 'SHODAN Stat Editor Offline', 'Looking for Helldivers 2...' })
    local exe_dir = here:gsub('[/\\]app[/\\]$', ''):gsub('[/\\]$', '')
    local game = I.find_game(exe_dir)
    if not game then
        fatal('Helldivers 2 was not found.\n\nWrite the path of its folder (the one holding "data") into\n'
              .. I.home:gsub('/', '\\') .. '\\game folder.txt\nand start again.')
    end
    local backup_count,backup_error=I.migrate_compat_backups(game)
    if backup_count==nil then fatal(backup_error) end
    if backup_count>0 then log('migrated to official backups: '..backup_count) end
    log('game: ' .. game)
    AR.log = log
    log('hash search: ' .. (G.native and 'native, every core' or 'Lua (shodan_hash.dll not found)'))
    screen({ 'SHODAN Stat Editor Offline', 'Reading the game\'s data files...' })
    shim.pump()
    local originals, ours, problems, count = I.originals(game)
    -- Validated legacy originals remain usable if copying into originals is denied.
    -- The official writer still requires a successful disk backup before game writes.
    for name,data in pairs(I.compat_originals or {}) do originals[name]=data;ours[name]=true end
    for i=#problems,1,-1 do
        local name=problems[i]:match('^(generated_[%w_]+%.dl_bin):')
        if name and I.compat_originals[name] then table.remove(problems,i) end
    end
    for _,warning in ipairs(I.compat_warnings or {}) do log(warning) end

    if count == 0 then fatal('No game data files in ' .. game) end
    local armor_file='generated_customization_passive_bonuses.dl_bin'
    local canonical,repaired,verified=require('armor_baseline').original(originals[armor_file],I.read(game..'/game.dll'))
    if canonical then originals[armor_file]=canonical end
    D.armor_defaults_verified=verified
    if repaired then log('armor baseline: replaced modified backup in memory with verified vanilla table; legacy backup retained') end
    for _, p in ipairs(D.load(game, originals)) do problems[#problems + 1] = p end
    AR.refresh(D.passives())
    AR.import_values = D.import_forge_values
    AR.init(game, I.home .. '/armory.ini')
    for _, p in ipairs(problems) do log('problem: ' .. p) end
    local loaded = 0
    for _ in pairs(D.files) do loaded = loaded + 1 end
    log(string.format('%d of %d files loaded, %d installed by an earlier install', loaded, count,
        (function() local n = 0; for _ in pairs(ours) do n = n + 1 end return n end)()))
    if loaded == 0 then
        fatal('None of the game\'s data files could be read:\n\n' .. table.concat(problems, '\n', 1, math.min(#problems, 8))
              .. '\n\nVerify the game files in Steam and start again.')
    end
    if #problems > 0 then
        shim.message_box('Some of the game\'s data files are not as this editor expects; their stats cannot be edited:\n\n'
                         .. table.concat(problems, '\n', 1, math.min(#problems, 10))
                         .. '\n\nIf another tool changed them, verify the game files in Steam.', 0x30)
    end

    -- ------------------------------------------------------------ the editor
    screen({ 'SHODAN Stat Editor Offline', 'Finding the stats...' })
    rawset(_G, 'SHODAN_OFFLINE', true)
    rawset(_G,'SHODAN_OFFLINE_TEXT',shim.take_text)
    rawset(_G,'SHODAN_OFFLINE_WHEEL',function() local value=shim.wheel or 0;shim.wheel=0;return value end)
    rawset(_G,'SHODAN_OFFLINE_ZH',require('zh_extra'))
    rawset(_G,'SHODAN_OFFLINE_TRANSITION',shim.transition)
    rawset(_G, 'SHODAN_OFFLINE_TABLES', function()
        local blocks = {}
        for name, file in pairs(D.files) do
            for _, header in ipairs(G.headers(file.p, file.n)) do
                blocks[#blocks+1] = { address = tonumber(ffi.cast('uintptr_t', file.p + header.at)),
                                     type = header.type, size = header.size, file = name }
            end
        end
        table.sort(blocks, function(a,b) return a.address < b.address end)
        return blocks
    end)
    if rawget(_G, 'SHODAN_OFFLINE_LANG') == nil then rawset(_G, 'SHODAN_OFFLINE_LANG', 'zh-Hans') end
    -- the panel's first language (until one is chosen in Settings): Windows' display language, if translated
    pcall(ffi.cdef, 'uint16_t GetUserDefaultUILanguage(void);')
    local id = ffi.C.GetUserDefaultUILanguage()
    local primary, sub = id % 1024, math.floor(id / 1024)
    if rawget(_G, 'SHODAN_OFFLINE_LANG') == nil then rawset(_G, 'SHODAN_OFFLINE_LANG', primary == 0x04 and ((sub == 2 or sub == 4) and 'zh-Hans' or 'zh-Hant')
                                      or primary == 0x19 and 'ru' or nil) end
    stingray = shim.engine()
    function update(dt) end
    local editor = arg and arg[1] or here .. 'stat_editor.lua'
    local chunk, why = loadfile(editor)
    if not chunk then fatal('Could not load ' .. editor .. ':\n' .. tostring(why)) end
    local ok, err = pcall(chunk)
    if not ok then fatal('Stat Editor did not start:\n' .. tostring(err)) end
    local state = rawget(_G, 'ShodanStatEditor')
    if type(state) ~= 'table' then fatal('Stat Editor did not start (no state).') end
    if state.phase == 'gave_up' then fatal('数据读取失败：' .. tostring(state.status)) end
    ARM.init(AR, D, I.home)
    ARM.on_change = function() state.writes = (state.writes or 0) + 1 end
    AR.frame = ARM.frame
    ARM.tabs=state.desktop_tabs;ARM.navigate=state.desktop_navigate
    ARM.tr=state.tr;ARM.transition=shim.transition
    state.open_armor = AR.show
    local build = U.build(here)   -- app/build.txt: version, commit, channel
    shim.set_title('SHODAN 数值编辑器 3.2.0')
    -- the host's own text in the panel's language, drawn with its font
    local function tr(text) return type(state.tr) == 'function' and state.tr(text) or text end
    if type(state.lang) == 'function' then shim.lang = state.lang end

    -- ------------------------------------------------------------ the host's bar (below the panel)
    local bar = { hover = nil, message = nil, tone = MUTED, note = nil, busy = nil, base = nil, buttons = {} }
    local function layout()
        local s = shim.h / 1080
        local y0, y1 = 1038 * s, 1072 * s
        bar.buttons = {
            { key = 'install', label = '写入游戏', x0 = 30 * s, x1 = 290 * s, y0 = y0, y1 = y1 },
            { key = 'restore', label = 'Restore the game\'s files', x0 = 302 * s, x1 = 562 * s, y0 = y0, y1 = y1 },
            { key = 'theme', label = shim.theme=='dark' and '浅色模式' or '深色模式', x0 = 574 * s, x1 = 714 * s, y0 = y0, y1 = y1 },
        }
        if bar.release then
            local x1 = shim.w - 30 * s
            bar.buttons[#bar.buttons + 1] = { key = 'update', label = 'Update to ' .. bar.release.label, x0 = x1 - 170 * s, x1 = x1,
                               y0 = 9 * s, y1 = 41 * s, gold = true }   -- top right, in the tagline's place
        end
        bar.s, bar.h = s, shim.h
    end
    layout()

    local function toggle_theme()
        shim.set_theme(shim.theme=='dark' and 'light' or 'dark');layout();ARM.invalidate()
        I.mkdirs(I.home)
        local file,why=io.open(THEME,'wb')
        if file then file:write(shim.theme);file:close()
        else bar.message='主题已切换，但无法保存偏好：'..tostring(why);bar.tone=WARN end
    end

    local function installed_count() local n = 0; for _, v in pairs(ours) do if v then n = n + 1 end end return n end

    local function status()
        if bar.busy then return bar.busy, WARN end
        if bar.message then return bar.message, bar.tone end
        if state.phase ~= 'ready' then return 'Finding the stats...', MUTED end
        local n = installed_count()
        local dirty = bar.base and state.writes ~= bar.base
        if dirty and n == 0 then return 'Your values are not in the game yet: close the game, then Install.', WARN end
        if dirty then return 'Changed since the last install: Install to put it in the game.', WARN end
        if n > 0 then return 'Your values are installed (' .. n .. ' game files). Close the game before installing.', GOOD end
        return 'The game\'s own files are in place. Close the game, then Install to play with your values.', MUTED
    end

    local function paint_bar()
        local s = bar.s
        shim.fill(0, 1032 * s, shim.w, shim.h, BACK)
        shim.fill(0, 0, shim.w, 46 * s, BACK)
        shim.text('SHODAN 数值编辑器', 30 * s, 32 * s, 24 * s, GOLD, true)
        local t = tr('OFFLINE  -  edits the game\'s files; they apply when the game starts')
        if not bar.release then shim.text(t, shim.w - 30 * s - shim.text_width(t, 15 * s), 31 * s, 15 * s, MUTED) end
        for _, b in ipairs(bar.buttons) do
            local hovered = bar.hover == b.key and not bar.busy
            shim.fill(b.x0, b.y0, b.x1, b.y1, hovered and { 255, 213, 233, 218 } or { 255, 247, 250, 245 })
            local edge = hovered and GOLD or { 255, 183, 199, 188 }
            local e = math.max(1, math.floor(2 * s + 0.5))
            shim.fill(b.x0, b.y0, b.x1, b.y0 + e, edge); shim.fill(b.x0, b.y1 - e, b.x1, b.y1, edge)
            shim.fill(b.x0, b.y0, b.x0 + e, b.y1, edge); shim.fill(b.x1 - e, b.y0, b.x1, b.y1, edge)
            shim.flush()
            local size, label = 16 * s, tr(b.label)
            while size > 10 * s and shim.text_width(label, size) > b.x1 - b.x0 - 12 * s do size = size - 0.5 end
            shim.text(label, (b.x0 + b.x1 - shim.text_width(label, size)) / 2, (b.y0 + b.y1) / 2 + size * 0.35, size,
                      b.gold and GOLD or WHITE)
        end
        local text, tone = status()
        text = tr(text)
        if bar.note then text = text .. ' ' .. tr(bar.note) end
        if not bar.busy and not bar.message then text = (bar.base and state.writes ~= bar.base) and '有未写入修改' or '编辑器已就绪' end
        local x = 730 * s
        local size = 14 * s
        local limit = shim.w - 30 * s - x
        while size > 9 * s and shim.text_width(text, size) > limit do size = size - 0.5 end
        shim.text(text, x, 1055 * s + size * 0.35, size, tone)
    end

    local function paint()
        if state.phase == 'ready' then
            if AR.is_open() then ARM.frame(shim) else shim.paint_guis(BACK) end
        else
            shim.fill(0, 0, shim.w, shim.h, BACK)
            centred(tr('Finding the stats...'), shim.h * 0.45, 30 * bar.s, GOLD)
            centred(tostring(state.status or ''), shim.h * 0.45 + 40 * bar.s, 18 * bar.s, MUTED)
        end
        local provider=AR.is_open() and ARM.effects or state.desktop_effects
        if provider then shim.effects(provider()) end
        shim.progress=bar.busy~=nil
        paint_bar()
        shim.present()
    end

    local function say(text, tone, note) bar.message, bar.tone, bar.note = text, tone or MUTED, note end

    local function busy(text)
        bar.busy = text
        paint()
        shim.pump()
    end

    -- ------------------------------------------------------------ install / restore
    local function install()
        if not ARM.flush() then say('请先修正护甲数值输入。',WARN);return end
        if state.desktop_commit and not state.desktop_commit() then say('请输入有效数值，再写入游戏。',WARN);return end
        if I.game_running() then say('Helldivers 2 is running: close it, then Install.', WARN); return end
        busy('Installing: finding what changed...')
        local changes, problems = D.diff()
        if problems and #problems > 0 then
            for _, c in ipairs(changes) do G.free(c.plain) end
            bar.busy = nil
            local first = problems[1]
            log('install stopped: ' .. first.name .. ': ' .. tostring(first.why))
            say('Not installed: ' .. first.name .. ' could not be read (' .. tostring(first.why)
                .. '). Nothing was changed.', WARN)
            return
        end
        -- the Armor page's choices on top of the panel's own passive page: one writer, one hash correction
        local stacks, own_off, policy = AR.selection(state.stacks and state.stacks() or {},
                                                     state.own_off and state.own_off() or {}, D.passives())
        local stacked, why_not = D.stack(changes, stacks, log, own_off, policy)
        if not stacked then
            for _, c in ipairs(changes) do G.free(c.plain) end
            bar.busy = nil
            log('install stopped: passive stacking: ' .. tostring(why_not))
            say('Not installed: the armor passives could not be stacked (' .. tostring(why_not) .. '). Nothing was changed.', WARN)
            return
        end
        local writes, made, back, nudged = {}, 0, 0, 0
        for k, c in ipairs(changes) do
            busy(string.format('Installing: preparing %s (%d of %d)...', c.name, k, #changes))
            local sealed, why = D.build(c, function(text) log(c.name .. ': ' .. text); shim.pump() end)
            if not sealed then
                for j = k + 1, #changes do G.free(changes[j].plain) end
                bar.busy = nil
                log('install stopped: ' .. c.name .. ': ' .. tostring(why))
                say('Not installed: ' .. c.name .. ' could not be prepared (' .. tostring(why) .. '). Nothing was changed.', WARN)
                return
            end
            writes[c.name], made = sealed, made + 1
            if c.borrowed and #c.borrowed > 0 then nudged = nudged + 1 end
        end
        for name, mine in pairs(ours) do
            if mine and not writes[name] then writes[name], back = originals[name], back + 1 end
        end
        if not next(writes) then
            bar.busy, bar.base = nil, state.writes
            say('Nothing to install: your values are the game\'s own.', GOOD)
            return
        end
        busy('Installing: writing the files...')
        local done, why = I.write_files(game, writes, originals)
        bar.busy = nil
        if not done then
            log('install failed: ' .. tostring(why))
            say('Not installed: ' .. tostring(why), WARN)
            return
        end
        for name, data in pairs(writes) do ours[name] = data ~= originals[name] end
        bar.base = state.writes
        local armor = AR.touches() and ('  ' .. AR.summary()) or ''
        log(string.format('installed: %d changed, %d back to the original, %d had a decimal value borrowed for the hash',
            made, back, nudged))
        say(string.format('Installed (%d game files changed%s). Start the game to play with your values.', made,
            back > 0 and ', ' .. back .. ' back to the original' or '') .. armor, GOOD,
            nudged > 0 and 'A file of one block has no spare header room, so one decimal value in it moved a few units'
                .. ' in the last place: that is how it keeps the hash the game knows.' or nil)
    end

    local function restore()
        if I.game_running() then say('Helldivers 2 is running: close it, then restore.', WARN); return end
        local writes = {}
        for name, mine in pairs(ours) do if mine then writes[name] = originals[name] end end
        if not next(writes) then say('The game\'s own files are already in place.', GOOD); return end
        busy('Restoring the game\'s files...')
        local done, why = I.write_files(game, writes, originals)
        bar.busy = nil
        if not done then say('Not restored: ' .. tostring(why), WARN); return end
        for name in pairs(writes) do ours[name] = false end
        bar.base = nil
        log('restored the originals')
        say('The game\'s own files are back. Your values stay saved here (Install puts them in again).', GOOD)
    end

    local function dispatch(action)
        bar.message,bar.note=nil,nil
        log('clicked: '..action)
        local ok,why=pcall(action=='install' and install or restore)
        if not ok then bar.busy=nil;say('操作失败：'..tostring(why),WARN);log('action failed: '..tostring(why)) end
        ARM.invalidate()
        paint()
        if not qa_output and bar.message then shim.message_box(tr(bar.message),bar.tone==WARN and 0x30 or 0x40) end
        return bar.message
    end

    -- ------------------------------------------------------------ updates (update.lua)
    local exe_dir = exe_dir
    local function update_program()
        local release = bar.release
        busy('Updating: downloading ' .. release.label .. '...')
        local zip = U.dir .. '/' .. release.name
        local job, why = U.fetch(release.url, zip)
        local done = nil
        if job then
            repeat
                if not shim.pump() then bar.busy = nil; return false end
                shim.sleep(20)
                done, why = U.poll(job)
            until done ~= nil
        end
        if not done then
            bar.busy = nil
            log('update: download failed: ' .. tostring(why))
            say('Update failed: ' .. tostring(why) .. '. The release page has it: ' .. U.PAGE, WARN)
            return false
        end
        busy('Updating: installing ' .. release.label .. '...')
        local exe, problem = U.install(zip, exe_dir, log)
        bar.busy = nil
        if not exe then
            log('update: not installed: ' .. tostring(problem))
            say('Update failed: ' .. tostring(problem) .. '. Nothing was changed.', WARN)
            return false
        end
        log('update: ' .. release.label .. ' installed, restarting: ' .. exe)
        U.note(release.label)
        bar.restart = exe
        return true
    end

    -- ------------------------------------------------------------ the frame loop
    local painted, was_down, was_f5, armed, said_ready = nil, false, false, nil, false
    local last = clock()
    local qa_ready_frames = 0
    local last_paint=0
    local loading_started = clock()
    while shim.pump() do
        local now = clock()
        update(math.min(0.1, now - last))
        last = now
        if state.phase == 'gave_up' then fatal('数据读取失败：' .. tostring(state.status)) end
        if state.phase ~= 'ready' and now-loading_started > 30 then fatal('读取超过 30 秒：'..tostring(state.status)..'\n请查看 Logs 目录中的日志。') end
        if bar.h ~= shim.h then layout() end   -- moved onto another screen: sized for that one
        if state.phase == 'ready' and not said_ready then
            said_ready = true
            bar.base = state.writes or 0
            ARM.load_values()
            log(string.format('ready: %s weapons, %s values applied, %s refused', tostring(state.weapons),
                tostring(state.applied), tostring(state.refused)))
            local stacks = state.stacks and state.stacks() or {}
            local own_off = state.own_off and state.own_off() or {}
            if installed_count() == 0 and ((state.applied or 0) > 0 or next(stacks) or next(own_off)) then bar.base = -1 end
            if I.game_running() then say('Helldivers 2 is running: you can edit, but close it before you Install.', WARN) end
            if #(I.compat_warnings or {})>0 then say('旧版备份已保留；迁移目录不可写，写入游戏前仍需解决备份权限。',WARN) end
            local updated = U.cleanup()
            if updated then say('Updated to ' .. updated .. '.', GOOD) end
        end
        -- updates: asked at start, and again when Settings > Update channel changes
        local channel = type(state.update_channel) == 'function' and state.update_channel() or 'releases'
        if said_ready and U.available and channel ~= bar.channel and not U.checking and not bar.restart then
            bar.channel = channel
            if bar.release then bar.release = nil; layout() end
            U.check(channel)
        end
        if U.checking then
            local current = { version = state.version, commit = build.commit }
            local release = U.check_poll(current)
            if release and bar.channel ~= U.channel then release = nil end   -- the channel changed meanwhile
            if release then
                bar.release = release
                layout()
                log('update: ' .. release.label .. ' is available (' .. release.name .. ')')
                -- Settings > Updates: Automatic
                if type(state.updates) == 'function' and state.updates() == 'auto' and update_program() then break end
            elseif release == false then
                log('update: nothing newer on ' .. tostring(U.channel) .. ' than v' .. tostring(current.version)
                    .. (current.commit and ' (' .. current.commit:sub(1, 7) .. ')' or ''))
            end
        end
        -- the bar's buttons
        -- F5 opens the armor page: it draws instead of the panel, and parks the panel's tick while it is up
        local f5 = state.phase == 'ready' and shim.focused() and shim.key_down(0x74) or false
        if f5 and not was_f5 then
            if AR.is_open() then AR.close() else AR.show() end
            painted = nil
        end
        was_f5 = f5
        local x, y = nil, nil
        if shim.focused() then x, y = shim.cursor() end
        local hover = nil
        for _, b in ipairs(bar.buttons) do
            if x and x >= b.x0 and x < b.x1 and y >= b.y0 and y < b.y1 then hover = b.key end
        end
        bar.hover = hover
        local down = shim.focused() and shim.key_down(0x01)
        if down and not was_down then armed = hover end
        if not down and was_down and armed and armed == hover and state.phase == 'ready' then
            bar.message = nil
            if hover == 'install' or hover == 'restore' then dispatch(hover);painted=nil
            elseif hover == 'theme' then toggle_theme();painted=nil
            elseif hover == 'update' and update_program() then break end
            armed = nil
        end
        was_down = down
        local text = status()
        local signature = table.concat({ shim.version, state.phase, tostring(state.status), tostring(hover), text,
                                         shim.lang(), bar.release and bar.release.label or '', tostring(bar.note) }, '|')
        if signature ~= painted or (AR.is_open() or shim.animating()) and now-last_paint>=0.033 then
            last_paint=now
            painted = signature
            paint()
        end
        if qa_output and state.phase == 'ready' then
            qa_ready_frames = qa_ready_frames + 1
            if qa_ready_frames >= 30 and (shim.draw_items or 0) > 30 then
                paint()
                shim.save_bmp(qa_output .. '/full-editor.bmp')
                local qa = assert(state.qa_ui, 'UI test driver unavailable')
                local saved_weapon=qa.current()
                for _,tab in ipairs({'Primary','Stratagems','Records'}) do
                    qa.navigate(tab);qa.redraw()
                    local page,total,scrollbar,active=qa.left_state()
                    assert(active==tab and page==1 and not scrollbar,'left list is not a fixed page')
                    qa.left_wheel(-8);qa.redraw()
                    assert(qa.left_state()==1,'left wheel changed the page')
                    local rows=qa.list_rows()
                    if total>rows then
                        qa.page_next();qa.redraw();assert(qa.left_state()==rows+1,'next page did not start after the current page')
                        qa.left_wheel(8);qa.redraw();assert(qa.left_state()==rows+1,'left wheel changed second page')
                        qa.page_prev();qa.redraw();assert(qa.left_state()==1,'previous page failed')
                    end
                end
                qa.select(saved_weapon.hash)
                qa.redraw();assert(qa.no_feature_shortcuts(),'redundant feature shortcut still visible')
                qa.redraw();paint();shim.save_bmp(qa_output..'/feature-entries.bmp')
                local features=qa.upstream_features()
                assert(features.status>100 and features.extra>50 and features.regen>=10 and features.callin>50 and features.eagle>0,'official 3.2.0 fields missing')
                assert(qa.test_choice('status'),'status selector failed')
                assert(qa.test_choice('stratagem'),'extra stratagem selector failed')
                -- Back up and write only a synthetic file under the isolated QA folder.
                local fake=qa_output..'/fake-game';I.mkdirs(fake)
                local filename='generated_qa_backup.dl_bin'
                local f=assert(io.open(fake..'/'..filename,'wb'));f:write('QA original');f:close()
                local running=I.game_running;I.game_running=function() return false end
                local written,why=I.write_files(fake,{[filename]='QA modified'},{[filename]='QA original'})
                assert(written,why)
                local backups=I.originals(fake);assert(backups[filename]=='QA original','official backup missing')
                -- Old indexed backups migrate before the official reader is used.
                local original='QA original'
                local hash=G.hex64(G.murmur64(ffi.cast('const uint8_t *',original),#original))
                I.mkdirs(I.home..'/backups')
                local relative='backups/'..hash..'_'..filename
                local prior=assert(io.open(I.home..'/'..relative,'wb'));prior:write(original);prior:close()
                local index=assert(io.open(I.home..'/backup-index.txt','wb'));index:write(filename..' '..relative..'\n');index:close()
                assert(os.remove(I.originals_dir..'/'..filename))
                local migrated,migration_error=I.migrate_compat_backups(fake);assert(migrated==1,migration_error)
                backups=I.originals(fake);assert(backups[filename]==original,'migrated original not restored')
                local previous_originals_dir=I.originals_dir
                I.originals_dir=qa_output..'/blocked-originals'
                local occupied=assert(io.open(I.originals_dir,'wb'));occupied:write('file occupies the directory');occupied:close()
                local count,why=I.migrate_compat_backups(fake)
                assert(count==0 and I.compat_originals[filename]==original and #I.compat_warnings==1,'read-only migration fallback failed')
                assert(I.read(I.home..'/'..relative)==original,'legacy backup was lost')
                I.originals_dir=previous_originals_dir;I.compat_originals={};I.compat_warnings={}
                I.game_running=running
                local text_input=require('text_input')
                qa.search_open();text_input.push(string.byte('A'));text_input.push(string.byte('R'))
                qa.text_events(shim.take_text());local entered,active,matches=qa.search_state()
                assert(entered=='AR' and active and matches>0,'English search input failed')
                qa.search_clear();qa.search_open()
                for _,code in ipairs({0x89E3,0x653E,0x8005}) do text_input.push(code) end
                qa.text_events(shim.take_text());entered,active,matches=qa.search_state()
                assert(entered=='解放者' and matches>0,'Chinese search input failed')
                qa.redraw();paint();shim.save_bmp(qa_output..'/search.bmp')
                qa.search_clear()
                -- Test install feedback using stubbed dependencies; never write game files.
                local running,diff,stack,write,buildfn=I.game_running,D.diff,D.stack,I.write_files,D.build
                local saved_ours=ours;ours={}
                I.game_running=function() return true end
                assert(dispatch('install'):find('running',1,true),'blocked install feedback missing')
                I.game_running=function() return false end
                D.diff=function() return {} end;D.stack=function() return true end
                assert(dispatch('install'):find('Nothing to install',1,true),'unchanged install feedback missing')
                D.diff=function() return {{name='qa-only.dl_bin'}} end
                D.build=function() return 'memory-only' end
                I.write_files=function() return nil,'QA simulated write failure' end
                assert(dispatch('install'):find('QA simulated write failure',1,true),'write failure feedback missing')
                I.write_files=function() return true end
                assert(dispatch('install'):find('Installed',1,true),'success feedback missing')
                I.game_running,D.diff,D.stack,I.write_files,D.build=running,diff,stack,write,buildfn
                ours=saved_ours;bar.message=nil;bar.note=nil
                local before = qa.current().rows[1]
                local original = qa.value_current(1)
                -- Read through the same UI controller that handles direct input.
                local old = qa.value(1, 1234)
                assert(old == 1234, 'custom numeric input did not apply')
                qa.redraw();paint();shim.save_bmp(qa_output..'/changed-values.bmp')
                qa.value(1, original)
                shim.transition()
                for frame=1,4 do shim.capture_path=qa_output..'/motion-'..frame..'.bmp';paint();shim.sleep(90) end
                local old_ammo = qa.ammo_current()
                assert(qa.ammo_open(), 'ammo picker did not open')
                local choices = qa.ammo_rows()
                assert(#choices > 20, 'ammo names were not enumerated')
                qa.redraw();paint();shim.save_bmp(qa_output .. '/ammo-picker.bmp')
                local selected
                for _, item in ipairs(choices) do if item.id ~= old_ammo then selected=item;break end end
                assert(selected and qa.ammo_choose(selected.id), 'ammo name selection failed')
                assert(qa.ammo_current() == selected.id, 'selected ammo was not applied')
                assert(qa.ammo_open() and qa.ammo_choose(old_ammo), 'ammo restore failed')
                local previous_weapon=qa.current().hash
                toggle_theme();assert(shim.theme=='dark')
                assert(qa.open_status_popup(),'status popup unavailable')
                qa.redraw();paint();shim.save_bmp(qa_output..'/dark-status-popup.bmp')
                local scale=shim.h/1080;local px,py=math.floor(60*scale),math.floor(55*scale)
                assert(shim.bits[py*shim.w+px]==0,'modal backdrop is not pure black')
                qa.close_popup();qa.select(previous_weapon);toggle_theme();qa.redraw()
                AR.show();ARM.action('toggle:1');ARM.action('toggle:7')
                assert(AR.group(999).enabled[1] and AR.group(999).enabled[7], 'multi-passive selection failed')
                ARM.frame(shim);paint_bar();shim.save_bmp(qa_output .. '/armor-main.bmp')
                toggle_theme();assert(shim.theme=='dark');paint();shim.save_bmp(qa_output..'/dark-armor.bmp')
                toggle_theme();assert(shim.theme=='light');paint()
                ARM.secondary(1)
                local effect=assert(D.armor_values(1)[1])
                local changed, why=ARM.set_value(1,effect.key,effect.value+0.25)
                assert(changed~=nil,why)
                ARM.frame(shim);paint_bar();shim.save_bmp(qa_output .. '/armor-values.bmp')
                local function preflight(stacking)
                    local changes,problems=D.diff();assert(#problems==0,'diff failed')
                    if stacking then
                        local stacks,own_off,policy=AR.selection({}, {}, D.passives())
                        local ok,why=D.stack(changes,stacks,log,own_off,policy);assert(ok,why)
                    end
                    local count,prepared=0,{}
                    for _,change in ipairs(changes) do
                        if stacking and change.name=='generated_customization_passive_bonuses.dl_bin' then
                            for _,header in ipairs(G.headers(change.plain,change.n)) do
                                if header.type==0x63CE0FEB then
                                    local base=header.at+24;local count=tonumber(ffi.cast('uint32_t *',change.plain+base+24)[0])
                                    local offset=base+tonumber(ffi.cast('uint64_t *',change.plain+base+16)[0])
                                    local seen,described={},0
                                    for i=0,count-1 do
                                        local row=change.plain+offset+i*16
                                        local id=tonumber(ffi.cast('uint32_t *',row)[0]);assert(not seen[id],'duplicate passive modifier');seen[id]=true
                                        if ffi.cast('uint32_t *',row+12)[0]~=0 then described=described+1 end
                                    end
                                    assert(described<=3,'too many armor descriptions')
                                end
                            end
                        end
                        local sealed,why=D.build(change,log);assert(sealed,why)
                        assert(type(sealed)=='string' and #sealed>0,'empty prepared file')
                        prepared[change.name]=sealed
                        count=count+1
                    end
                    assert(count>0,'no armor changes to prepare');return prepared
                end
                preflight(false)
                local armor_writes=preflight(true)
                local armor_folder=qa_output..'/armor-game';I.mkdirs(armor_folder)
                local armor_originals={}
                for name in pairs(armor_writes) do
                    armor_originals[name]=D.files[name].cipher
                    local file=assert(io.open(armor_folder..'/'..name,'wb'));file:write(armor_originals[name]);file:close()
                end
                local previous_running=I.game_running;I.game_running=function() return false end
                local committed,commit_error=I.write_files(armor_folder,armor_writes,armor_originals);assert(committed,commit_error)
                for name,sealed in pairs(armor_writes) do assert(I.read(armor_folder..'/'..name)==sealed,'official armor write differs') end
                I.game_running=previous_running


                assert(ARM.set_value(1,effect.key,effect.value)~=nil,'passive reset failed')
                assert(D.armor_defaults_verified,'armor baseline not verified against game.dll')
                local med=D.armor_values(7);assert(#med==2 and med[1].default==2 and med[2].default==2,'medical vanilla defaults differ')
                local fire=D.armor_values(11);assert(fire[1].default==0.25,'fire vanilla default differs')
                local baseline=require('armor_baseline')
                local armor=D.files['generated_customization_passive_bonuses.dl_bin']
                assert(baseline.is_clean(armor.cipher),'editor still uses modified passive baseline')
                local corrupted,n=assert(G.open_sealed(armor.cipher))
                for _,header in ipairs(G.headers(corrupted,n)) do
                    local base=header.at+24
                    if ffi.cast('uint32_t *',corrupted+base)[0]==7 then
                        local at=base+tonumber(ffi.cast('uint64_t *',corrupted+base+16)[0])+8
                        ffi.cast('float *',corrupted+at)[0]=0
                    end
                end
                assert(G.correct(corrupted,n,armor.hash,{},log))
                local modified=G.seal(corrupted,n);G.free(corrupted)
                local repaired,changed,verified=baseline.original(modified,I.read(game..'/game.dll'))
                assert(changed and verified and baseline.is_clean(repaired),'modified backup was accepted as vanilla')
                local refused,changed,verified=baseline.original(modified,'unknown game version')
                assert(refused==modified and not changed and not verified,'unknown version baseline was replaced')
                local stationary=D.armor_values(42);assert(#stationary==2,'Stationary Shroud fields missing')
                local sway
                for _,row in ipairs(stationary) do if row.label=='瞄准晃动' then sway=row end end
                assert(sway and #sway.ats==3,'Stationary Shroud sway fields are not linked')
                assert(ARM.set_value(42,sway.key,sway.value+0.1)~=nil)
                for _,at in ipairs(sway.ats) do assert(math.abs(tonumber(ffi.cast('float *',D.files[AR.FILE].p+at)[0])-sway.value-0.1)<1e-5) end
                assert(ARM.set_value(42,sway.key,sway.value)~=nil)
                ARM.secondary(42);ARM.frame(shim);paint_bar();shim.save_bmp(qa_output..'/stationary-shroud.bmp')

                AR.close()
                local file = assert(io.open(qa_output .. '/report.json', 'wb'))
                local values = {}
                for _, key in ipairs({ 'weapons', 'stratagems', 'vehicles', 'attachments', 'throwables', 'passives', 'tables', 'ui_errors' }) do
                    values[#values+1] = string.format('"%s":%d', key, tonumber(state[key]) or 0)
                end
                file:write('{"phase":"ready","language":"', state.lang(), '","draw_items":', tostring(shim.draw_items or 0), ',"armor_choices":',tostring(#AR.list),',"ammo_choices":',tostring(#choices),',"unicode_search":true,"install_feedback":true,"custom_input":true,"ammo_selection":true,"armor_value_edit":true,"armor_write_preflight":true,"backup_migration":true,"migration_fallback":true,"core_320_features":true,"theme_switch":true,"fixed_left_pages":true,"no_redundant_shortcuts":true,"pure_black_modal":true,"stationary_shroud":true,"official_write_flow":true,"official_multi_passive_write":true,"vanilla_armor_defaults":true,', table.concat(values, ','), '}')
                file:close()
                break
            end
        end
        shim.sleep(state.phase == 'ready' and 10 or 1)
    end
    if shim.place then
        I.mkdirs(I.home)
        local f = io.open(PLACE, 'w')
        if f then f:write(shim.place[1], ' ', shim.place[2], '\n'); f:close() end
    end
    -- the editor saves its values a moment after a change
    local stop = clock() + 1.5
    while clock() < stop do update(0.05); shim.sleep(20) end
    if bar.restart then
        local go = true
        if go and not U.launch(bar.restart) then
            shim.message_box('Updated. Start ' .. bar.restart:gsub('/', '\\') .. ' again.', 0x40)
        end
    end
    log('closed')
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    log('error: ' .. tostring(err))
    if qa_output then local f=io.open(qa_output..'/failure.txt','wb');if f then f:write(tostring(err));f:close() end;os.exit(1)
    else shim.message_box('SHODAN Stat Editor Offline stopped:\n\n' .. tostring(err), 0x10) end
end
