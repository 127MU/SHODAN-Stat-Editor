-- SHODAN Stat Editor Offline: updates from the GitHub releases.
-- At start the latest release is asked for in the background (shodan_hash.dll's fetch thread). When it is newer,
-- Update downloads its zip (only from this repository's releases), unpacks it with Windows' tar, swaps the new files
-- in next to the program (the running exe and DLLs are renamed to *.old, removed at the next start) and starts
-- the new one. Nothing in %LOCALAPPDATA%\SHODAN\StatEditor (values, presets, originals) is touched.
local ffi = require('ffi')
local I = require('install')

for _, declaration in ipairs({
    'int MultiByteToWideChar(uint32_t cp, uint32_t flags, const char *s, int n, uint16_t *w, int wn);',
    'int WideCharToMultiByte(uint32_t cp, uint32_t flags, const uint16_t *w, int wn, char *s, int n, const char *d, int *u);',
    'typedef struct { uint32_t attributes, times[6], size_high, size_low, reserved[2]; uint16_t name[260], short_name[14]; } update_find_data;',
    'void *FindFirstFileW(const uint16_t *pattern, update_find_data *data);',
    'int FindNextFileW(void *find, update_find_data *data);',
    'int FindClose(void *find);',
    'int MoveFileExW(const uint16_t *from, const uint16_t *to, uint32_t flags);',
    'int CopyFileW(const uint16_t *from, const uint16_t *to, int fail_if_exists);',
    'int DeleteFileW(const uint16_t *path);',
    'int RemoveDirectoryW(const uint16_t *path);',
    'int CreateDirectoryW(const uint16_t *path, void *security);',
    'uint32_t GetFileAttributesW(const uint16_t *path);',
    'uint32_t GetModuleFileNameW(void *module, uint16_t *path, uint32_t size);',
    'uint32_t GetSystemDirectoryW(uint16_t *path, uint32_t size);',
    'typedef struct { uint32_t cb; void *reserved, *desktop, *title; uint32_t x, y, w, h, cx, cy, fill, flags; uint16_t show, reserved2; void *reserved3, *input, *output, *error; } update_startup;',
    'typedef struct { void *process, *thread; uint32_t pid, tid; } update_process;',
    'int CreateProcessW(const uint16_t *app, uint16_t *command, void *pa, void *ta, int inherit, uint32_t flags, void *env, const uint16_t *dir, update_startup *si, update_process *pi);',
    'uint32_t WaitForSingleObject(void *handle, uint32_t ms);',
    'int GetExitCodeProcess(void *process, uint32_t *code);',
    'int TerminateProcess(void *process, uint32_t code);',
    'int CloseHandle(void *handle);',
    'void *shodan_fetch(const uint16_t *url, const uint16_t *path);',
    'int shodan_fetch_result(void *handle);',
}) do pcall(ffi.cdef, declaration) end
local C = ffi.C

local M = {}
M.REPO = 'SHODAN-HORAI/SHODAN-Stat-Editor'
M.LATEST = 'https://api.github.com/repos/' .. M.REPO .. '/releases/latest'
M.PAGE = 'https://github.com/' .. M.REPO .. '/releases/latest'
M.EVERY_COMMIT = 'https://api.github.com/repos/' .. M.REPO .. '/releases/tags/dev'   -- the development build
local DOWNLOADS = 'https://github.com/' .. M.REPO .. '/releases/download/'
local INVALID = 0xFFFFFFFF
M.dir = I.home .. '/update'

local here = (debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or '')
local native
for _, at in ipairs({ here .. 'launcher/shodan_hash.dll', here .. 'shodan_hash.dll', here .. '../shodan_hash.dll' }) do
    local ok, lib = pcall(ffi.load, at)
    if ok then
        local has = pcall(function() return lib.shodan_fetch end)
        if has then native = lib; break end
    end
end
M.available = native ~= nil

-- ---------------------------------------------------------------- text and files (UTF-8 <-> UTF-16)
local function wide(s)
    if not s:match('^%a+://') then s = s:gsub('/', '\\') end   -- paths with Windows' separators; URLs as they are
    local n = C.MultiByteToWideChar(65001, 0, s, #s, nil, 0)
    local w = ffi.new('uint16_t[?]', n + 1)
    C.MultiByteToWideChar(65001, 0, s, #s, w, n)
    w[n] = 0
    return w
end
local function narrow(w)
    local n = C.WideCharToMultiByte(65001, 0, w, -1, nil, 0, nil, nil)
    local s = ffi.new('char[?]', n)
    C.WideCharToMultiByte(65001, 0, w, -1, s, n, nil, nil)
    return ffi.string(s)
end
local function attributes(path) return C.GetFileAttributesW(wide(path)) end
local function exists(path) return attributes(path) ~= INVALID end

-- the entries of a folder: { name, dir } (no '.' / '..')
local function entries(folder)
    local out, data = {}, ffi.new('update_find_data')
    local find = C.FindFirstFileW(wide(folder .. '/*'), data)
    if find == nil or ffi.cast('intptr_t', find) == -1 then return out end
    repeat
        local name = narrow(data.name)
        if name ~= '.' and name ~= '..' then out[#out + 1] = { name = name, dir = data.attributes % 32 >= 16 } end
    until C.FindNextFileW(find, data) == 0
    C.FindClose(find)
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function remove_tree(folder)
    for _, e in ipairs(entries(folder)) do
        local path = folder .. '/' .. e.name
        if e.dir then remove_tree(path) else C.DeleteFileW(wide(path)) end
    end
    C.RemoveDirectoryW(wide(folder))
end

local function mkdirs(folder)
    local path = ''
    for part in folder:gsub('\\', '/'):gmatch('[^/]+') do
        path = path == '' and part or path .. '/' .. part
        if not path:match('^%a:$') and not exists(path) then C.CreateDirectoryW(wide(path), nil) end
    end
end

-- every file under a folder, as paths relative to it
local function files(folder, prefix, out)
    out = out or {}
    for _, e in ipairs(entries(folder)) do
        local rel = (prefix and prefix .. '/' or '') .. e.name
        if e.dir then files(folder .. '/' .. e.name, rel, out) else out[#out + 1] = rel end
    end
    return out
end

-- runs a program without a window and waits for it; its exit code, or nil
local function run(app, command, seconds)
    local si, pi = ffi.new('update_startup'), ffi.new('update_process')
    si.cb = ffi.sizeof(si)
    local line = wide(command)
    if C.CreateProcessW(wide(app), line, nil, nil, 0, 0x08000000, nil, nil, si, pi) == 0 then return nil end   -- CREATE_NO_WINDOW
    local code = nil
    if C.WaitForSingleObject(pi.process, seconds * 1000) == 0 then
        local out = ffi.new('uint32_t[1]')
        if C.GetExitCodeProcess(pi.process, out) ~= 0 then code = out[0] end
    else
        C.TerminateProcess(pi.process, 1)
    end
    C.CloseHandle(pi.thread); C.CloseHandle(pi.process)
    return code
end

-- ---------------------------------------------------------------- versions
local function parts(v)
    local out = {}
    for n in tostring(v or ''):gmatch('%d+') do out[#out + 1] = tonumber(n) end
    return out
end
-- true when version a is newer than b
function M.newer(a, b)
    local x, y = parts(a), parts(b)
    for k = 1, math.max(#x, #y) do
        local p, q = x[k] or 0, y[k] or 0
        if p ~= q then return p > q end
    end
    return false
end

-- what the API's JSON offers: { version, url, name, label } for a release (its zip: this repository's downloads
-- only, not a language-only zip), { commit, url, name, label } for the development build (its zip is named
-- ...-dev-<commit>.zip, built by .github/workflows/dev-build.yml from every commit)
function M.parse(json, channel)
    for url in json:gmatch('"browser_download_url"%s*:%s*"([^"]+)"') do
        local name = url:match('([^/]+)$')
        if url:sub(1, #DOWNLOADS) == DOWNLOADS and name:match('%.zip$') then
            if channel == 'commits' then
                local commit = name:match('%-dev%-(%x+)%.zip$')
                if commit then return { commit = commit:lower(), url = url, name = name, label = 'dev ' .. commit:sub(1, 7) } end
            elseif not name:match('%-zh%-Hans%.zip$') and not name:match('%-zh%-Hant%.zip$') and not name:match('%-ru%.zip$')
                   and not name:match('%-dev%-') then
                local version = json:match('"tag_name"%s*:%s*"v?([%d%.]+)"')
                if not version then return nil end
                return { version = version, url = url, name = name, label = 'v' .. version }
            end
        end
    end
    return nil
end

-- this program's build (app/build.txt, written by package.py): { version, commit, channel } (empty if missing)
function M.build(app)
    local out = {}
    local f = io.open(app .. 'build.txt', 'rb')
    if not f then return out end
    for k, v in f:read('*a'):gmatch('(%a+)%s*=%s*([^\r\n]+)') do out[k] = v end
    f:close()
    return out
end

-- ---------------------------------------------------------------- downloads
-- starts a download into a file; poll(job) is nil while it runs, then true or false and the reason
function M.fetch(url, path)
    if not native then return nil, 'the download helper (shodan_hash.dll) is missing' end
    mkdirs(M.dir)
    C.DeleteFileW(wide(path))
    local job = native.shodan_fetch(wide(url), wide(path))
    if job == nil then return nil, 'could not start the download' end
    return { handle = job, path = path }
end
function M.poll(job)
    if job.done ~= nil then return job.done, job.why end
    local r = native.shodan_fetch_result(job.handle)
    if r == -1 then return nil end
    job.done = r == 200 and exists(job.path)
    if not job.done then job.why = r > 0 and 'the server answered ' .. r or 'no connection (' .. r .. ')' end
    return job.done, job.why
end

-- asks (in the background) for the latest release, or the development build when channel is 'commits';
-- call M.check_poll() each frame until it gives a result
function M.check(channel)
    M.channel = channel == 'commits' and 'commits' or 'releases'
    M.checking = M.fetch(M.channel == 'commits' and M.EVERY_COMMIT or M.LATEST, M.dir .. '/latest.json')
end
-- nil while asking; then what to update to, or false. current: { version, commit } of this program. A release
-- is newer by its version; the development build is new when it was built from another commit than this program.
function M.check_poll(current)
    if not M.checking then return false end
    local done = M.poll(M.checking)
    if done == nil then return nil end
    M.checking = nil
    if not done then return false end
    local f = io.open(M.dir .. '/latest.json', 'rb')
    local json = f and f:read('*a') or ''
    if f then f:close() end
    os.remove(M.dir .. '/latest.json')
    local offer = M.parse(json, M.channel)
    if not offer then return false end
    if offer.commit then
        local mine = (current.commit or ''):lower()
        if mine ~= '' and mine:sub(1, #offer.commit) == offer.commit then return false end
        return offer
    end
    if M.newer(offer.version, current.version) then return offer end
    return false
end

-- ---------------------------------------------------------------- installing
-- the program's own path (the running exe)
function M.exe_path()
    local buffer = ffi.new('uint16_t[1024]')
    local n = C.GetModuleFileNameW(nil, buffer, 1024)
    return n > 0 and narrow(buffer):gsub('\\', '/') or nil
end

-- unpacks the downloaded zip and swaps its files in over `program` (the folder holding the exe).
-- Returns the new exe's path, or nil and the reason (everything put back as it was).
function M.install(zip, program, log)
    log = log or function() end
    program = program:gsub('\\', '/'):gsub('/$', '')
    local unpacked = M.dir .. '/files'
    if exists(unpacked) then remove_tree(unpacked) end
    mkdirs(unpacked)
    local system = ffi.new('uint16_t[260]')
    C.GetSystemDirectoryW(system, 260)
    local tar = narrow(system) .. '\\tar.exe'
    if not exists(tar) then return nil, 'Windows\' tar.exe is missing (Windows 10 1803 or newer has it)' end
    local code = run(tar, string.format('"%s" -xf "%s" -C "%s"', tar, zip:gsub('/', '\\'), unpacked:gsub('/', '\\')), 120)
    if code ~= 0 then return nil, 'the download could not be unpacked (' .. tostring(code) .. ')' end
    -- the zip holds one folder: the program's files
    local top = entries(unpacked)
    if #top ~= 1 or not top[1].dir then return nil, 'the download is not a release of this program' end
    local root = unpacked .. '/' .. top[1].name
    local list, exe = files(root), nil
    for _, rel in ipairs(list) do
        if not rel:find('/') and rel:lower():match('%.exe$') then
            if exe then return nil, 'the download holds two programs' end
            exe = rel
        end
    end
    if not exe or not exists(root .. '/app/host.lua') or not exists(root .. '/app/stat_editor.lua') then
        return nil, 'the download is not a release of this program'
    end
    -- swap: each file in place, the old one kept as *.old (a running exe or loaded DLL can be renamed, not overwritten)
    local done = {}
    local function undo()
        for k = #done, 1, -1 do
            local d = done[k]
            C.DeleteFileW(wide(d.target))
            if d.old then C.MoveFileExW(wide(d.target .. '.old'), wide(d.target), 1) end
        end
    end
    for _, rel in ipairs(list) do
        local target = program .. '/' .. rel
        local folder = target:match('^(.*)/[^/]+$')
        if folder then mkdirs(folder) end
        local had = exists(target)
        if had and C.MoveFileExW(wide(target), wide(target .. '.old'), 1) == 0 then
            undo(); return nil, 'could not replace ' .. rel .. ' (is it open somewhere?)'
        end
        if C.CopyFileW(wide(root .. '/' .. rel), wide(target), 0) == 0 then
            if had then C.MoveFileExW(wide(target .. '.old'), wide(target), 1) end
            undo(); return nil, 'could not write ' .. rel
        end
        done[#done + 1] = { target = target, old = had }
        log('updated ' .. rel)
    end
    local aside = {}
    for _, d in ipairs(done) do if d.old then aside[#aside + 1] = d.target .. '.old' end end
    -- the running program under another name (a renamed release): set aside too, so one program is left
    local running = M.exe_path()
    if running and running:lower() ~= (program .. '/' .. exe):lower() and running:lower():find(program:lower(), 1, true) == 1 then
        if C.MoveFileExW(wide(running), wide(running .. '.old'), 1) ~= 0 then aside[#aside + 1] = running .. '.old' end
    end
    remove_tree(unpacked)
    os.remove(zip)
    local f = io.open(M.dir .. '/set aside.txt', 'wb')   -- removed by M.cleanup at the next start
    if f then f:write(table.concat(aside, '\n'), '\n'); f:close() end
    return program .. '/' .. exe
end

-- what was just installed, for the next start to say so
function M.note(label)   -- 'v3.0.2' or 'dev abc1234'
    local f = io.open(M.dir .. '/updated.txt', 'wb')
    if f then f:write(label); f:close() end
end

-- starts a program (the updated one) in its folder
function M.launch(exe)
    local si, pi = ffi.new('update_startup'), ffi.new('update_process')
    si.cb = ffi.sizeof(si)
    local folder = exe:match('^(.*)/[^/]+$')
    if C.CreateProcessW(wide(exe), wide('"' .. exe:gsub('/', '\\') .. '"'), nil, nil, 0, 0, nil, wide(folder), si, pi) == 0 then
        return false
    end
    C.CloseHandle(pi.thread); C.CloseHandle(pi.process)
    return true
end

-- after an update: the files it set aside (listed in 'set aside.txt'; the old program may still be closing, so
-- what can't go yet stays listed for the next start) and its other leftovers. Returns the version an update just
-- installed ('v3.0.2', 'dev abc1234'), if any.
function M.cleanup()
    if not exists(M.dir) then return nil end
    local note = io.open(M.dir .. '/updated.txt', 'rb')
    local updated = note and note:read('*a'):match('^([%w%. ]+)$')
    if note then note:close() end
    local list = M.dir .. '/set aside.txt'
    local f = io.open(list, 'rb')
    local left = {}
    if f then
        for path in f:read('*a'):gmatch('[^\r\n]+') do
            if path:match('%.old$') and exists(path) and C.DeleteFileW(wide(path)) == 0 then left[#left + 1] = path end
        end
        f:close()
    end
    if #left == 0 then remove_tree(M.dir); return updated end
    for _, e in ipairs(entries(M.dir)) do
        if e.name ~= 'set aside.txt' then
            if e.dir then remove_tree(M.dir .. '/' .. e.name) else C.DeleteFileW(wide(M.dir .. '/' .. e.name)) end
        end
    end
    f = io.open(list, 'wb')
    if f then f:write(table.concat(left, '\n'), '\n'); f:close() end
    return updated
end

return M
