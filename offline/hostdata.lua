-- SHODAN Stat Editor Offline: the game's data files as the game holds them in memory.
-- Every data file is decrypted into its own allocation (high in the address space, like the game's), so Stat
-- Editor's table scan finds the tables as it does in game. The game turns a table's stored offsets into
-- addresses when it loads it; the host does the same for the fields Stat Editor follows, and links each
-- destruction level to its demolition tier (stored unlinked). Those fields always go back as they were stored.
-- Install: per file, the bytes Stat Editor changed go into the original plain text, the hash is corrected, the
-- file is sealed, read back and checked.
local ffi = require('ffi')
local bit = require('bit')
local G = require('gamedata')

-- (VirtualAlloc, VirtualFree and memcmp are declared by gamedata.lua)
local MEM_COMMIT_RESERVE_TOP, PAGE_READWRITE, MEM_RELEASE = 0x103000, 0x04, 0x8000

local M = { files = {}, log = print }
local u64p = ffi.typeof('uint64_t *')
local NONE = 0xFFFFFFFFFFFFFFFFULL

local function u32(p, o) return ffi.cast('uint32_t *', p + o)[0] end
local function addr(p) return ffi.cast('uint64_t', ffi.cast('uintptr_t', p)) end

-- ---------------------------------------------------------------- the fields the game resolves at load
-- per table type: function(payload pointer, size, rel) calling rel(offset) for each stored offset Stat Editor
-- follows (payload-relative u64; 0 and -1 are none)
local RELOC = {
    [0x683E604F] = function(P, size, rel) for k = 0, 4 do rel(k * 16) end end,                -- attachment deltas
    [0x63CE0FEB] = function(P, size, rel)                                                     -- armor passive
        if u32(P, 24) > 0 then rel(16) end
        if u32(P, 40) > 0 then rel(32) end
    end,
    [0x49795156] = function(P, size, rel) rel(0) end,                                         -- destruction map
    [0xFB45E243] = function(P, size, rel) rel(0) end,                                         -- demolition tiers
    [0xD6A11545] = function(P, size, rel) rel(0) end,                                         -- destruction settings
    [0x1E604234] = function(P, size, rel)                                                     -- attachment items
        rel(0)
        for r = 0, u32(P, 8) - 1 do rel(16 + r * 88); rel(16 + r * 88 + 48) end
    end,
    [0x30EB6399] = function(P, size, rel)                                                     -- stratagems
        rel(0)
        for r = 0, u32(P, 8) - 1 do rel(16 + r * 400 + 16); rel(16 + r * 400 + 64); rel(16 + r * 400 + 152) end
    end,
}

-- ---------------------------------------------------------------- loading
local function read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a'); f:close()
    return s
end

-- `cipher`: the original sealed file. The plain text goes into a top-down allocation.
local function place(name, cipher)
    local n = #cipher - G.SEALBYTES
    local p = ffi.cast('uint8_t *', ffi.C.VirtualAlloc(nil, math.max(n, 1), MEM_COMMIT_RESERVE_TOP, PAGE_READWRITE))
    assert(p ~= nil, 'out of memory for ' .. name)
    local tmp, m = G.open_sealed(cipher)
    if not tmp then ffi.C.VirtualFree(p, 0, MEM_RELEASE); return nil, m end
    ffi.copy(p, tmp, n)
    G.free(tmp)
    return p, n
end

local function open_base(cipher)
    local p,n=G.open_sealed(cipher)
    if p then G.clear_correction(p,n) end
    return p,n
end
M.modded={}

-- folder: data/game; originals: name -> sealed original (from the backups, else the game folder)
function M.load(folder, originals, baselines)
    local dll = assert(read(folder .. '/game.dll'), 'game.dll not found in ' .. folder)
    local problems = {}
    for name, cipher in pairs(originals) do
        local p, n = place(name, cipher)
        if not p then
            problems[#problems + 1] = name .. ': ' .. tostring(n)
        else
            local hash = G.murmur64(p, n)
            if not G.game_dll_has(dll, hash) then
                problems[#problems + 1] = name .. ': not the version this game expects'
                ffi.C.VirtualFree(p, 0, MEM_RELEASE)
            else
                local valid = true
                for _, header in ipairs(G.headers(p, n)) do
                    if header.at + 24 + header.size > n then valid = false; break end
                end
                if valid then
                    if G.clear_correction(p,n) then M.modded[name]=true end
                    M.files[name] = { name = name, p = p, n = n, hash = hash, cipher = cipher,
                                      baseline = baselines and baselines[name] or cipher, fields = {} }
                else
                    problems[#problems + 1] = name .. ': invalid table boundary'
                    ffi.C.VirtualFree(p, 0, MEM_RELEASE)
                end
            end
        end
    end
    M.relocate()
    return problems
end

-- Translate a working-buffer address to its immutable, unrelocated original.
-- Keeping the defaults separate lets installed values remain visible without
-- turning those installed values into the target of a Reset operation.
function M.original_bytes(address,size)
    for _,file in pairs(M.files) do
        local offset=address-tonumber(ffi.cast('uintptr_t',file.p))
        if offset>=0 and offset+size<=file.n then
            if file.original_unavailable then return nil end
            if not file.original_p then
                local p,n=G.open_sealed(file.baseline or file.cipher)
                if not p then return nil end
                local compatible=n==file.n
                local working,original=G.headers(file.p,file.n),G.headers(p,n)
                compatible=compatible and #working==#original
                for k,h in ipairs(working) do
                    local ref=original[k]
                    if not ref or h.at~=ref.at or h.type~=ref.type or h.size~=ref.size then compatible=false;break end
                end
                if not compatible and #working==#original then
                    -- Longer call-in codes grow a stratagem block's tail and
                    -- shift later blocks. Match unchanged row identities first;
                    -- defaults then use payload-relative positions, not old file offsets.
                    local ranges={};local mapped=true
                    for k,h in ipairs(working)do
                        local ref=original[k]
                        if h.type~=0x30EB6399 or ref.type~=h.type or h.size<ref.size then mapped=false;break end
                        local live,base=h.at+24,ref.at+24
                        local rows=u32(p,base+8)
                        if rows~=u32(file.p,live+8) or 16+rows*400>math.min(h.size,ref.size) then mapped=false;break end
                        for r=0,rows-1 do if u32(file.p,live+16+r*400)~=u32(p,base+16+r*400) then mapped=false;break end end
                        if not mapped then break end
                        ranges[#ranges+1]={at=live,finish=live+ref.size,original=base}
                    end
                    if mapped then compatible=true;file.original_ranges=ranges end
                end
                if not compatible then G.free(p);file.original_unavailable=true;return nil end
                G.clear_correction(p,n);file.original_p,file.original_n=p,n
            end
            if file.original_ranges then
                for _,range in ipairs(file.original_ranges)do
                    if offset>=range.at and offset+size<=range.finish then return ffi.string(file.original_p+range.original+offset-range.at,size) end
                end
                return nil
            end
            if offset+size>file.original_n then return nil end
            return ffi.string(file.original_p+offset,size)
        end
    end
end

function M.relocate()
    local tiers = {}   -- demolition tier type -> its template's address
    for _, f in pairs(M.files) do
        for _, h in ipairs(G.headers(f.p, f.n)) do
            local P, size = f.p + h.at + 24, h.size
            local fn = RELOC[h.type]
            if fn then
                fn(P, size, function(o)
                    if o + 8 > size then return end
                    local v = ffi.cast(u64p, P + o)[0]
                    if v ~= 0 and v ~= NONE and v < size then
                        ffi.cast(u64p, P + o)[0] = addr(P) + v
                        f.fields[#f.fields + 1] = h.at + 24 + o
                    end
                end)
            end
            if h.type == 0xFB45E243 and u32(P, 8) > 0 then
                for k = 0, u32(P, 8) - 1 do tiers[u32(P, 16 + k * 16)] = addr(P) + 16 + k * 16 end
            end
        end
    end
    for _, f in pairs(M.files) do
        for _, h in ipairs(G.headers(f.p, f.n)) do
            if h.type == 0xD6A11545 and h.size >= 144 then
                local P = f.p + h.at + 24
                for level = 0, 2 do
                    for _, o in ipairs({ 16, 32 }) do
                        local at = level * 48 + o
                        local t = tiers[u32(P, at + 8)]
                        if t and ffi.cast(u64p, P + at)[0] == NONE then
                            ffi.cast(u64p, P + at)[0] = t
                            f.fields[#f.fields + 1] = h.at + 24 + at
                        end
                    end
                end
            end
        end
    end
    for _, f in pairs(M.files) do
        f.resolved = {}
        for _, o in ipairs(f.fields) do for k = 0, 7 do f.resolved[o + k] = true end end
    end
end

-- a float read off a pointer: a plain read never answers nil, but a scan that reaches a buffer the
-- engine moves under it can, and one nil must not stop the whole install: no value is no candidate
local function float_at(p, o)
    local v = ffi.cast('float *', p + o)[0]
    if v == nil then return nil end
    v = tonumber(v)
    if v == nil or v ~= v then return nil end
    return v
end
-- a value with decimals, between 1e-4 and 1e7: what a hash correction can move by a few units in the
-- last place
local function decimal(p, o)
    local v = float_at(p, o)
    return v ~= nil and math.abs(v) >= 1e-4 and math.abs(v) < 1e7 and u32(p, o) >= 0x38D1B717
end

-- a record of whole numbers may hold a word that only looks like a float: the fields around it tell - a value
-- this editor may move sits with other values with decimals (velocity, mass, drag), an id or a count does not
local function crowded(p, n, at, blocked, resolved)
    local around = 0
    for k = -32, 32, 4 do
        local o = at + k
        if k ~= 0 and o >= 0 and o + 4 <= n and not blocked[o] and not (resolved and resolved[o]) then
            local v = decimal(p, o) and float_at(p, o)
            if v and math.abs(v) >= 1e-3 then around = around + 1 end
        end
    end
    return around >= 2
end

-- A file of one block has no spare header bytes to vary, so a change with no decimal value in it (an explosion
-- id, a count) leaves the hash correction nothing to work with: borrow the nearest decimal value of the same
-- record (a projectile's Caliber, its Drag...) and the correction moves it by under 0.05 %. `words`: the 4-byte
-- words that changed. No candidate: the table grows instead (see M.build).
local function borrowing(f, p, n, words)
    if type(p) ~= 'cdata' then return {} end
    local blocked = {}
    for _, h in ipairs(G.headers(p, n)) do for o = h.at, h.at + 23 do blocked[o] = true end end
    local starts = {}
    for o in pairs(words) do
        blocked[o] = true
        starts[#starts + 1] = o
    end
    table.sort(starts)
    local out, seen = {}, {}
    for step = 4, 1024, 4 do
        for _, base in ipairs(starts) do
            for _, at in ipairs({ base + step, base - step }) do
                at = at - at % 4
                if at >= 0 and at + 4 <= n and not seen[at] then
                    seen[at] = true
                    local free = true
                    for k = at, at + 3 do
                        if blocked[k] or (f.resolved and f.resolved[k]) then free = false; break end
                    end
                    local v = free and decimal(p, at) and float_at(p, at)
                    if v and math.abs(v) >= 1e-3 and crowded(p, n, at, blocked, f.resolved) then
                        out[#out + 1] = at
                        if #out >= 6 then return out end
                    end
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------- what changed
-- the plain text to install for a file (a new buffer) and the offsets of changed f32-looking words, or nil when
-- nothing changed. Resolved fields keep their stored bytes.
local function changes(f)
    -- The working snapshot may already be installed and modified. Comparing
    -- against it makes an unchanged saved override disappear from the next
    -- write plan, whose restore pass would then undo that installed file.
    -- Defaults and the write plan must use the same immutable reference.
    local orig, n = open_base(f.baseline or f.cipher)
    assert(orig,n)
    -- Header size/reserved words belong to the hash container, not parameters.
    -- An installed one-table file may have a trailing hash-correction area;
    -- rebuilding from the reference must not copy that enlarged size into the
    -- shorter reference buffer. The builder adds fresh correction space later.
    local container={}
    local before,live=G.headers(orig,n),G.headers(f.p,f.n)
    local function compatible(headers,length)
        if length>f.n or #headers~=#live then return false end
        for i,h in ipairs(headers)do
            local other=live[i]
            local padding=#headers==1 and other.size-h.size==f.n-length and f.n-length>=0 and f.n-length<=24
            if h.at~=other.at or h.type~=other.type or (h.size~=other.size and not padding) then return false end
        end
        return true
    end
    local preserve_layout=false
    if not compatible(before,n) then
        -- A validated installed Mod can resize arrays or add blocks. Its byte
        -- offsets no longer describe the canonical reference. Rebuild from the
        -- unrelocated snapshot we actually loaded, preserving its extra data;
        -- never apply a positional diff to an incompatible canonical buffer.
        G.free(orig)
        orig,n=open_base(f.cipher);assert(orig,n)
        before=G.headers(orig,n)
        if not compatible(before,n) then
            G.free(orig);error('编辑期间数据表结构发生变化，请重新打开程序后重试')
        end
        preserve_layout=true
    end
    for _,h in ipairs(before)do
        for k=h.at,h.at+23 do container[k]=true end
    end
    local changed, words = 0, {}
    local a, b = ffi.cast('uint64_t *', f.p), ffi.cast('uint64_t *', orig)
    for w = 0, math.floor(n / 8) - 1 do
        if a[w] ~= b[w] then
            for k = w * 8, w * 8 + 7 do
                if f.p[k] ~= orig[k] and not f.resolved[k] and not container[k] then
                    orig[k] = f.p[k]
                    changed = changed + 1
                    words[k - k % 4] = true
                end
            end
        end
    end
    for k = n - n % 8, n - 1 do
        if f.p[k] ~= orig[k] and not f.resolved[k] and not container[k] then orig[k] = f.p[k]; changed = changed + 1; words[k - k % 4] = true end
    end
    -- Keep this file in the plan even when its saved values were already
    -- installed: the coordinator's restore pass must not replace its Mod layout.
    if changed == 0 and not preserve_layout then G.free(orig); return nil end
    -- floats among the changed words (a salt for one-table files): a value with decimals between 1e-4 and 1e7
    local floats = {}
    for o in pairs(words) do
        local v = float_at(orig, o)
        local i = u32(orig, o)
        if v and math.abs(v) >= 1e-4 and math.abs(v) < 1e7 and i >= 0x38D1B717 then floats[#floats + 1] = o end
    end
    table.sort(floats)
    -- nothing with decimals changed: borrow the nearest one of the same record, so a whole-number change can
    -- still be installed (see borrowing)
    local borrowed
    if #floats == 0 then
        local ok, list = pcall(borrowing, f, orig, n, words)
        floats = ok and list or {}
        borrowed = #floats > 0 and floats or nil
    end
    return orig, n, changed, floats, borrowed
end

-- every file whose plain text differs from its original: { name, plain, n, bytes, floats, borrowed, hash }
-- and the files that could not be read at all ({ name, why }): one unreadable file must not stop the rest
function M.diff()
    local out, problems = {}, {}
    for name, f in pairs(M.files) do
        local read, plain, n, count, floats, borrowed = pcall(changes, f)
        if not read then
            problems[#problems + 1] = { name = name, why = tostring(plain) }
        elseif plain then
            out[#out + 1] = { name = name, plain = plain, n = n, bytes = count, floats = floats,
                              borrowed = borrowed, hash = f.hash }
        end
    end
    table.sort(out, function(x, y) return x.name < y.name end)
    table.sort(problems, function(x, y) return x.name < y.name end)
    return out, problems
end

-- ---------------------------------------------------------------- passive stacking
-- Every armor with passive T also gets passive S's modifiers and weapon stat modifiers (their values as edited):
-- they are appended to T's block (payload: 56 bytes, the modifiers at +56, 16 bytes each, then the weapon stat
-- modifiers, 12 bytes each), so the file grows; the hash correction works at any length.
-- stacks: target passive id -> { source passive id, ... }; own_off: passive id -> true: its own modifiers left out
-- (only the stacked ones; none: the passive does nothing); policy: passive id -> 'stack' | 'strongest' (one value
-- per effect, the strongest, as the Armory Forge mod does). Adds to / changes `changes` (from M.diff) in place.
local PASSIVE = 0x63CE0FEB

-- a 32-bit word and a float32 read out of a byte string (Lua 5.1 has no string.unpack)
local u32buf = ffi.new('uint32_t[1]')
local f32buf = ffi.cast('float *', u32buf)
local function u32s(b, at)
    local a1, a2, a3, a4 = b:byte(at, at + 3)
    return a1 + a2 * 256 + a3 * 65536 + a4 * 16777216
end
local function f32s(b, at)
    u32buf[0] = u32s(b, at)
    return f32buf[0]
end

-- the rows of a record's arrays: { key, type, value, bytes } (16-byte modifiers: id, type, value, text;
-- 12-byte weapon stat modifiers: id, a float, the value)
local function split_rows(s, width)
    local out = {}
    for at = 1, #s - width + 1, width do
        local b = s:sub(at, at + width - 1)
        out[#out + 1] = { key = b:sub(1, 4),
                          type = width == 16 and u32s(b, 5) or 2,
                          value = f32s(b, 9), bytes = b }
    end
    return out
end

-- how strong an effect's value is: a factor counts by how far it is from 1, an amount by its size
local function strength(typ, v)
    if typ == 2 then
        if v <= 0 then return math.huge end
        return math.abs(math.log(v))
    end
    return math.abs(v)
end

-- one effect may arrive from several passives: an identical value is written once; 'strongest' keeps only the
-- strongest of them
local function collapse(rows, policy)
    local order, groups = {}, {}
    for _, r in ipairs(rows) do
        local g = groups[r.key]
        if not g then g = {}; groups[r.key] = g; order[#order + 1] = r.key end
        local dup = false
        for _, u in ipairs(g) do if u.value == r.value then dup = true; break end end
        if not dup then g[#g + 1] = r end
    end
    local out = {}
    for _, key in ipairs(order) do
        local g = groups[key]
        if #g > 1 and policy == 'strongest' then
            local best = g[1]
            for i = 2, #g do
                if strength(g[i].type, g[i].value) > strength(best.type, best.value) then best = g[i] end
            end
            g = { best }
        end
        if #g>1 then g={g[1]} end
        for _, r in ipairs(g) do out[#out + 1] = r.bytes end
    end
    return table.concat(out)
end

-- The armory's preview of a passive lists at most 3 described modifiers (no native passive has more; a 4th crashes
-- the game, issue #74): past the 3rd, a modifier keeps its effect but loses its description id (+12). The ids
-- that lose it go to `hidden`.
local MAX_DESCRIBED = 3
local function cap_descriptions(mods, hidden)
    local out, shown = {}, 0
    for o = 1, #mods, 16 do
        local m = mods:sub(o, o + 15)
        if m:sub(13, 16) ~= '\0\0\0\0' then
            shown = shown + 1
            if shown > MAX_DESCRIBED then
                local b1, b2, b3, b4 = m:byte(1, 4)
                hidden[#hidden + 1] = string.format('%08X', ((b4 * 256 + b3) * 256 + b2) * 256 + b1)
                m = m:sub(1, 12) .. '\0\0\0\0'
            end
        end
        out[#out + 1] = m
    end
    return table.concat(out)
end

-- the record's own rows, then the stacked ones: a row already there (same effect and value) is written once
local function append_unique(existing,extra,width)
    local seen,out={},{}
    for _,source in ipairs({existing,extra}) do
        for at=1,#source-width+1,width do
            local row=source:sub(at,at+width-1);local key=row:sub(1,4)
            if not seen[key] then seen[key]=true;out[#out+1]=row end
        end
    end
    return table.concat(out)
end

function M.stack(changes, stacks, log, own_off, policy)
    log, stacks, own_off, policy = log or function() end, stacks or {}, own_off or {}, policy or {}
    local any = next(own_off) ~= nil
    for _, list in pairs(stacks) do if #list > 0 then any = true end end
    if not any then return true end
    local f
    for _, file in pairs(M.files) do
        for _, h in ipairs(G.headers(file.p, file.n)) do if h.type == PASSIVE then f = file; break end end
        if f then break end
    end
    if not f then return nil, 'the armor passive file is not loaded' end
    local c
    for _, x in ipairs(changes) do if x.name == f.name then c = x end end
    if not c then
        local plain, n = open_base(f.cipher)
        if not plain then return nil, f.name .. ': ' .. tostring(n) end
        c = { name = f.name, plain = plain, n = n, bytes = 0, floats = {}, hash = f.hash }
        changes[#changes + 1] = c
        table.sort(changes, function(x, y) return x.name < y.name end)
    end
    local p, n = c.plain, c.n
    local hs = G.headers(p, n)
    -- every passive's modifiers and weapon stat modifiers, as edited (before any grows)
    local blocks = {}
    for _, h in ipairs(hs) do
        if h.type == PASSIVE and h.size >= 56 then
            local P = h.at + 24
            local mc, sc = u32(p, P + 24), u32(p, P + 40)
            local mo = mc > 0 and tonumber(ffi.cast(u64p, p + P + 16)[0]) or 56
            local so = sc > 0 and tonumber(ffi.cast(u64p, p + P + 32)[0]) or 56 + mc * 16
            if mo == 56 and so == 56 + mc * 16 and h.size == so + sc * 12 then
                blocks[u32(p, P)] = { mods = ffi.string(p + P + 56, mc * 16), stats = ffi.string(p + P + so, sc * 12) }
            end
        end
    end
    local out, done = { ffi.string(p, hs[1].at) }, 0
    for k, h in ipairs(hs) do
        local P = h.at + 24
        local id = h.type == PASSIVE and h.size >= 56 and u32(p, P)
        local own, list = id and blocks[id], id and stacks[id]
        local mods, stats, names = '', '', {}
        if own and not own_off[id] then mods, stats = own.mods, own.stats end
        local add_m, add_s = {}, {}
        for _, s in ipairs(own and list or {}) do
            if (s ~= id or own_off[id]) and blocks[s] then
                for _, r in ipairs(split_rows(blocks[s].mods, 16)) do add_m[#add_m + 1] = r end
                for _, r in ipairs(split_rows(blocks[s].stats, 12)) do add_s[#add_s + 1] = r end
                names[#names + 1] = tostring(s)
            elseif s ~= id then
                log('passive ' .. s .. ' (stacked on ' .. id .. ') is not in this game file: left out')
            end
        end
        local pol=policy[id] or 'stack'
        if pol=='strongest' then
            local own_m=split_rows(mods,16);for _,row in ipairs(add_m) do own_m[#own_m+1]=row end
            local own_s=split_rows(stats,12);for _,row in ipairs(add_s) do own_s[#own_s+1]=row end
            mods,stats=collapse(own_m,pol),collapse(own_s,pol)
        else
            mods=append_unique(mods,collapse(add_m,pol),16)
            stats=append_unique(stats,collapse(add_s,pol),12)
        end
        local block_end = k < #hs and hs[k + 1].at or n
        if #names > 0 then
            local hidden = {}
            mods = cap_descriptions(mods, hidden)
            if #hidden > 0 then
                log('passive ' .. id .. ': modifier ' .. table.concat(hidden, ', ') .. ' not described in the armory' ..
                    ' (it lists ' .. MAX_DESCRIBED .. ' at most), still applied')
            end
        end
        if #names > 0 or (own and own_off[id]) then
            local head = ffi.new('uint8_t[80]')
            ffi.copy(head, p + h.at, 80)
            local payload = head + 24
            local mc, sc = #mods / 16, #stats / 12
            ffi.cast('uint32_t *', head + 12)[0] = 56 + #mods + #stats                           -- block size
            ffi.cast(u64p, payload + 16)[0] = mc > 0 and 56 or NONE
            ffi.cast('uint32_t *', payload + 24)[0] = mc
            ffi.cast(u64p, payload + 32)[0] = sc > 0 and 56 + #mods or NONE
            ffi.cast('uint32_t *', payload + 40)[0] = sc
            out[#out + 1] = ffi.string(head, 80) .. mods .. stats
            out[#out + 1] = ffi.string(p + P + h.size, block_end - P - h.size)                   -- any padding after
            log(string.format('passive %d: %s, stacked %s (%d modifiers, %d weapon stat modifiers, %s)', id,
                own_off[id] and 'own effects off' or 'own effects on',
                #names > 0 and table.concat(names, ', ') or 'none', mc, sc, pol))
            done = done + 1
        else
            out[#out + 1] = ffi.string(p + h.at, block_end - h.at)
        end
    end
    if done == 0 then return true end
    local s = table.concat(out)
    local grown = G.alloc(#s)
    ffi.copy(grown, s, #s)
    G.free(c.plain)
    -- the edited floats moved: the other headers' reserved bytes salt the hash correction
    c.plain, c.n, c.bytes, c.floats = grown, #s, c.bytes + #s - n, {}
    return true
end

-- the passive ids this game's file holds: the Armory page's "all armor" profile applies to those without one
function M.passives()
    local f
    for _, file in pairs(M.files) do
        for _, h in ipairs(G.headers(file.p, file.n)) do if h.type == PASSIVE then f = file; break end end
        if f then break end
    end
    local ids = {}
    if not f then return ids end
    for _, h in ipairs(G.headers(f.p, f.n)) do
        if h.type == PASSIVE and h.size >= 56 then ids[#ids + 1] = u32(f.p, h.at + 24) end
    end
    table.sort(ids)
    return ids
end

-- ---------------------------------------------------------------- stratagem codes
-- StratagemInfo (rows of 400 bytes, the stratagem type at +0) +64: its call-in code, the payload offset of a u32
-- per arrow (1 up, 2 right, 3 down, 4 left), +72 the arrow count. A code no longer than the game's goes over its
-- own; a longer one is appended to its table, which grows (by whole 16 bytes, so the tables after keep their
-- alignment). codes: stratagem type -> { arrow, ... } (1 to 9: the game's code readers take 9 at most).
-- Adds to / changes `changes` (from M.diff) in place.
local STRATAGEM = 0x30EB6399
function M.codes(changes, codes, log)
    log, codes = log or function() end, codes or {}
    if not next(codes) then return true end
    local f
    for _, file in pairs(M.files) do
        for _, h in ipairs(G.headers(file.p, file.n)) do if h.type == STRATAGEM then f = file; break end end
        if f then break end
    end
    if not f then return nil, 'the stratagem file is not loaded' end
    local c
    for _, x in ipairs(changes) do if x.name == f.name then c = x end end
    if not c then
        local plain, n = open_base(f.cipher)
        if not plain then return nil, f.name .. ': ' .. tostring(n) end
        c = { name = f.name, plain = plain, n = n, bytes = 0, floats = {}, hash = f.hash }
        changes[#changes + 1] = c
        table.sort(changes, function(x, y) return x.name < y.name end)
    end
    local p, n = c.plain, c.n
    local hs = G.headers(p, n)
    local out, grown, done = { ffi.string(p, hs[1].at) }, 0, 0
    for k, h in ipairs(hs) do
        local P = h.at + 24
        local block_end = k < #hs and hs[k + 1].at or n
        local extra = {}   -- longer codes, appended after the payload
        if h.type == STRATAGEM and h.size >= 16 then
            local rows = u32(p, P + 8)
            for r = 0, rows - 1 do
                local R = P + 16 + r * 400
                local code = R + 400 <= P + h.size and codes[u32(p, R)]
                local ok = type(code) == 'table' and #code >= 1 and #code <= 9
                for _, a in ipairs(ok and code or {}) do ok = ok and (a == 1 or a == 2 or a == 3 or a == 4) end
                if code and not ok then
                    log('stratagem ' .. u32(p, R) .. ': code left as it is (1 to 9 arrows, 1-4 each)')
                elseif code then
                    local at, count = tonumber(ffi.cast(u64p, p + R + 64)[0]), u32(p, R + 72)
                    if at < 16 + rows * 400 or at + count * 4 > h.size then
                        log('stratagem ' .. u32(p, R) .. ': its code is not where it should be: left as it is')
                    else
                        if #code > count then   -- appended: 8-aligned, after the payload and earlier ones
                            local size = h.size
                            for _, s in ipairs(extra) do size = size + #s end
                            local pad = (8 - size % 8) % 8
                            extra[#extra + 1] = string.rep('\0', pad)
                            at = size + pad
                            ffi.cast(u64p, p + R + 64)[0] = at
                            local arrows = {}
                            for j, a in ipairs(code) do arrows[j] = string.char(a, 0, 0, 0) end
                            extra[#extra + 1] = table.concat(arrows)
                        else
                            for j, a in ipairs(code) do ffi.cast('uint32_t *', p + P + at)[j - 1] = a end
                        end
                        ffi.cast('uint32_t *', p + R + 72)[0] = #code
                        done = done + 1
                        log(string.format('stratagem %d: code of %d arrows (was %d)%s', u32(p, R), #code, count,
                            #code > count and ', appended to its table' or ''))
                    end
                end
            end
        end
        if #extra > 0 then
            local add = table.concat(extra)
            add = add .. string.rep('\0', (16 - #add % 16) % 16)
            local head = ffi.new('uint8_t[24]')
            ffi.copy(head, p + h.at, 24)
            ffi.cast('uint32_t *', head + 12)[0] = h.size + #add                                 -- block size
            out[#out + 1] = ffi.string(head, 24) .. ffi.string(p + P, h.size) .. add
            out[#out + 1] = ffi.string(p + P + h.size, block_end - P - h.size)                   -- any padding after
            grown = grown + #add
        else
            out[#out + 1] = ffi.string(p + h.at, block_end - h.at)
        end
    end
    c.bytes = c.bytes + done
    if grown == 0 then return true end
    local s = table.concat(out)
    local bigger = G.alloc(#s)
    ffi.copy(bigger, s, #s)
    G.free(c.plain)
    -- the edited floats moved: the other headers' reserved bytes salt the hash correction
    c.plain, c.n, c.floats = bigger, #s, {}
    return true
end

-- seal one changed file: { name, sealed } or nil, why
-- Typed values used by the integrated armor editor. Keys include the effect identity,
-- operation and duplicate ordinal, so persisted edits do not target a shifted row.
do
    local DATA = require('armory_data')
    local labels, editable, groups = {}, {}, {}
    for _, passive in ipairs(DATA.list) do
        editable[passive.id] = {};groups[passive.id]={}
        for _, effect in ipairs(passive.effects or {}) do
            local identity=(effect.kind == 'stat' and 12 or 16)..':'..effect.a..':'..effect.b
            labels[identity] = effect.label
            -- Each passive exposes only its own named effects from the supplied catalog.
            if not effect.label:find('不明',1,true) and not effect.label:find('标记',1,true) then
                editable[passive.id][identity] = effect.label
                if effect.group then groups[passive.id][identity]={name=effect.group,canonical=effect.canonical} end
            end
        end
    end
    local defaults
    local function read_values(p,n,relocated)
        local out = {}
        for _, header in ipairs(G.headers(p,n)) do
            if header.type == PASSIVE and header.size >= 56 then
                local base=header.at+24
                local id=u32(p,base)
                if id~=0 then
                    out[id]={}
                    local occurrences={}
                    for _, spec in ipairs({{16,16,24},{12,32,40}}) do
                        local width,po,co=unpack(spec)
                        local count=u32(p,base+co)
                        assert(count<=4096,'too many passive modifiers')
                        local pointer=ffi.cast(u64p,p+base+po)[0]
                        local start=relocated and tonumber(pointer-addr(p)) or base+tonumber(pointer)
                        if count>0 then
                            assert(start>=base+56 and start+count*width<=base+header.size,'invalid passive array bounds')
                            for i=0,count-1 do
                                local at=start+i*width;local effect=u32(p,at);local op=width==16 and u32(p,at+4) or 0
                                local identity=width..':'..effect..':'..op
                                occurrences[identity]=(occurrences[identity] or 0)+1
                                local key=id..':'..identity..':'..occurrences[identity]
                                out[id][#out[id]+1]={key=key,label=labels[identity] or string.format('效果 %08X / 类型 %d',effect,op),
                                    value=tonumber(ffi.cast('float *',p+at+8)[0]),at=at+8}
                            end
                        end
                    end
                end
            end
        end
        return out
    end
    function M.armor_values(id)
        local file=M.files['generated_customization_passive_bonuses.dl_bin']
        assert(file,'passive data unavailable')
        if not defaults then
            local original,n=assert(G.open_sealed(file.cipher))
            defaults={}
            for _, rows in pairs(read_values(original,n,false)) do for _, row in ipairs(rows) do defaults[row.key]=row.value end end
            G.free(original)
        end
        local rows=read_values(file.p,file.n,true)[id] or {}
        local allowed=editable[id] or {}
        local filtered,linked={},{}
        for _, row in ipairs(rows) do
            local identity,ordinal=row.key:match('^%d+:(%d+:%d+:%d+):(%d+)$')
            -- Stacked copies and unrelated modifiers are not additional editable fields.
            if allowed[identity] and ordinal=='1' then
                row.default=defaults[row.key];row.label=allowed[identity]
                local group=groups[id] and groups[id][identity]
                if group and linked[group.name] then
                    local target=linked[group.name];target.ats[#target.ats+1]=row.at
                    if group.canonical then target.key,target.at,target.value,target.default=row.key,row.at,row.value,row.default end
                else
                    row.ats={row.at};filtered[#filtered+1]=row
                    if group then linked[group.name]=row end
                end
            end
        end
        return filtered
    end
    function M.set_armor_value(id,key,value)
        value=tonumber(value)
        if not value or value~=value or math.abs(value)==math.huge then return nil,'请输入有效的有限数值' end
        local rounded=tonumber(ffi.new('float[1]',value)[0])
        if rounded~=rounded or math.abs(rounded)==math.huge then return nil,'数值超出浮点数范围' end
        for _, row in ipairs(M.armor_values(id)) do
            if row.key==key then
                local file=M.files['generated_customization_passive_bonuses.dl_bin']
                for _,at in ipairs(row.ats or {row.at}) do ffi.cast('float *',file.p+at)[0]=rounded end
                return rounded
            end
        end
        return nil,'当前版本不存在此被动效果'
    end
end

function M.import_forge_values(text)
    if text == nil then return 0 end
    text = text:gsub('\r\n', '\n')
    if not text:match('^AFV1\n') then return nil, 'Unsupported AFV1 format' end
    local file = M.files.generated_customization_passive_bonuses
    file = M.files['generated_customization_passive_bonuses.dl_bin'] or file
    if not file then return nil, 'Passive data unavailable' end
    local blocks = {}
    for _, h in ipairs(G.headers(file.p, file.n)) do
        if h.type == PASSIVE and h.size >= 56 then blocks[u32(file.p,h.at+24)] = h end
    end
    local plan = {}
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        if line ~= '' and line ~= 'AFV1' then
            local id, row, raw = line:match('^(%d+):(%d+):([%-%+%d%.eE]+)$')
            id, row = tonumber(id), tonumber(row)
            local value = tonumber(raw)
            if not id or not row or not value or value ~= value or math.abs(value) == math.huge then return nil, 'Invalid AFV1 row' end
            local h = blocks[id]
            if not h then return nil, 'Unknown passive ' .. id end
            local base = h.at+24
            if row < 1 or row > u32(file.p,base+24) then return nil, 'Modifier row out of range' end
            -- Stored pointers are relocated by M.load; only this verified allocation is allowed.
            local pointer = ffi.cast(u64p,file.p+base+16)[0]
            local offset = tonumber(pointer - addr(file.p)) + (row-1)*16 + 8
            if offset < base+56 or offset+4 > base+h.size then return nil, 'Modifier pointer out of bounds' end
            local rounded = ffi.new('float[1]',value)[0]
            if rounded ~= rounded or math.abs(tonumber(rounded)) == math.huge then return nil, 'Value overflows float32' end
            plan[#plan+1] = { at=offset, value=value }
        end
    end
    for _, p in ipairs(plan) do ffi.cast('float *',file.p+p.at)[0] = p.value end
    return #plan
end

function M.build(change, log)
    log = log or function() end
    -- a one-table file whose changes hold no float to vary (whole numbers, zeros): nothing in it may vary for the
    -- hash correction, so its table grows by 16 zero bytes after everything it holds (the game reads only what
    -- its offsets name; grown tables load, as stacked passives do), and those vary instead
    local hs = G.headers(change.plain, change.n)
    -- Input may be a hash-validated file already prepared by another editor.
    -- Discard only its old correction in this private output buffer, before solving
    -- the target hash again. Preserve flags, sizes, payload and the loaded baseline.
    for _,header in ipairs(hs) do
        if header.at+24+header.size>change.n or change.plain[header.at+16]~=1 then
            G.free(change.plain);return nil,'invalid output block header'
        end
        ffi.fill(change.plain+header.at+17,7,0)
    end
    if #change.floats == 0 and #hs == 1 and hs[1].at + 24 + hs[1].size == change.n then
        local n = change.n
        local salt = n + (8 - n % 8) % 8                -- a word of its own (the native search needs the words whole)
        local grown = G.alloc(salt + 16)               -- (zeroed)
        ffi.copy(grown, change.plain, n)
        ffi.cast('uint32_t *', grown + hs[1].at + 12)[0] = salt + 16 - hs[1].at - 24
        G.free(change.plain)
        change.plain, change.n, change.floats = grown, salt + 16, { salt }
        log(string.format('no float among the changes: the table grows by %d bytes for the hash correction', salt + 16 - n))
    end
    local called, ok, why = pcall(G.correct, change.plain, change.n, change.hash, change.floats, log)
    if not called then G.free(change.plain); return nil, tostring(ok) end
    if not ok then G.free(change.plain); return nil, why end
    local sealed_at, sealed = pcall(G.seal, change.plain, change.n)
    if not sealed_at then G.free(change.plain); return nil, tostring(sealed) end
    local back, m = G.open_sealed(sealed)
    local good = back and m == change.n and ffi.C.memcmp(back, change.plain, m) == 0 and G.murmur64(back, m) == change.hash
    if back then G.free(back) end
    G.free(change.plain)
    if not good then return nil, 'read-back check failed' end
    return sealed
end

return M
