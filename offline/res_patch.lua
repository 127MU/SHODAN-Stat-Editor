-- SHODAN Stat Editor Offline: resource residency through the game's patch archives.
--
-- The game requests a stratagem's package only when that stratagem is in the mission's loadout, and the
-- loadout has a limited number of package slots.  A patch archive (data/<package>.patch_<n>) is merged
-- into <package> when the game starts, so what it holds is resident without spending a slot.  The three
-- container formats below (bundle set, DSAR chunks, package container) follow srkit by
-- deepseekv41flash (github.com/deepseekv41flash/hd2-srkit), reimplemented in Lua so the panel builds a
-- patch by itself with nothing else installed.

local M = {}

-- ---------------------------------------------------------------- reading bytes

local function le(s, off, n)
    if n <= 4 then
        local a, b, c, d = s:byte(off + 1, off + n)
        if n == 1 then return a or 0 end
        if n == 2 then return (a or 0) + (b or 0) * 256 end
        if n == 3 then return (a or 0) + (b or 0) * 256 + (c or 0) * 65536 end
        return (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216
    end
    local v, mul = 0, 1
    for i = 0, n - 1 do
        v = v + s:byte(off + 1 + i) * mul
        mul = mul * 256
    end
    return v
end

local function u32(v)
    v = v % 4294967296
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256,
                       math.floor(v / 16777216) % 256)
end

local function u64(v)
    local parts = {}
    for i = 1, 8 do
        parts[i] = string.char(v % 256)
        v = math.floor(v / 256)
    end
    return table.concat(parts)
end

local function align_up(value, alignment)
    local rest = value % alignment
    return rest == 0 and value or value + alignment - rest
end

local function read_at(path, off, size)
    local handle = io.open(path, 'rb')
    if not handle then return nil, 'cannot open ' .. path end
    if off and off > 0 then
        local moved = handle:seek('set', off)
        if not moved then handle:close() return nil, 'cannot seek ' .. path end
    end
    local data = size and handle:read(size) or handle:read('*a')
    handle:close()
    if not data then return nil, 'cannot read ' .. path end
    if size and #data < size then return nil, 'short read ' .. path end
    return data
end

function M.read_file(path) return read_at(path, 0, nil) end

function M.file_size(path)
    local handle = io.open(path, 'rb')
    if not handle then return nil end
    local size = handle:seek('end')
    handle:close()
    return size
end

-- Writes through <path>.tmp and swaps it in, so a failure leaves the old file whole.
function M.write_file(path, data)
    local temp = path .. '.tmp'
    local handle = io.open(temp, 'wb')
    if not handle then return false, 'cannot write ' .. path end
    local wrote = handle:write(data)
    local closed = handle:close()
    if not wrote or not closed then pcall(os.remove, temp) return false, 'cannot write ' .. path end
    os.remove(path)
    local moved = os.rename(temp, path)
    if not moved then pcall(os.remove, temp) return false, 'cannot replace ' .. path end
    return true
end

-- ---------------------------------------------------------------- LZ4 block

local function lz4_block(src, out_size)
    local parts, total, tail = {}, 0, ''
    local function push(text)
        parts[#parts + 1] = text
        total = total + #text
        tail = tail .. text
        if #tail > 262144 then tail = tail:sub(-262144) end
    end
    local n, i = #src, 1
    while i <= n do
        local token = src:byte(i)
        i = i + 1
        local literals = math.floor(token / 16)
        if literals == 15 then
            while true do
                if i > n then return nil, 'truncated literal length' end
                local extra = src:byte(i)
                i = i + 1
                literals = literals + extra
                if extra ~= 255 then break end
            end
        end
        if literals > 0 then
            if i + literals - 1 > n then return nil, 'truncated literal run' end
            push(src:sub(i, i + literals - 1))
            i = i + literals
        end
        if i > n then break end
        if i + 1 > n then return nil, 'truncated match offset' end
        local offset = src:byte(i) + src:byte(i + 1) * 256
        i = i + 2
        if offset == 0 then return nil, 'invalid match offset 0' end
        local match = token % 16
        if match == 15 then
            while true do
                if i > n then return nil, 'truncated match length' end
                local extra = src:byte(i)
                i = i + 1
                match = match + extra
                if extra ~= 255 then break end
            end
        end
        match = match + 4
        if offset > #tail then return nil, 'match before the start of the block' end
        local pattern = tail:sub(#tail - offset + 1)
        local copies = math.ceil(match / #pattern)
        push(pattern:rep(copies):sub(1, match))
    end
    if out_size and total ~= out_size then return nil, 'wanted ' .. out_size .. ', produced ' .. total end
    return table.concat(parts)
end

M.lz4_block = lz4_block

-- ---------------------------------------------------------------- DSAR chunks

local CACHE_LIMIT = 12

local function dsar_head(path)
    local head = read_at(path, 0, 32)
    if not head then return nil, 'cannot read ' .. path end
    if head:sub(1, 4) ~= 'DSAR' then return nil, 'not a DSAR container: ' .. path end
    local count = le(head, 8, 4)
    local table_data, why = read_at(path, 32, count * 32)
    if not table_data then return nil, why end
    local chunks = {}
    for index = 0, count - 1 do
        local at = index * 32
        chunks[#chunks + 1] = {
            uoff = le(table_data, at, 8),
            coff = le(table_data, at + 8, 8),
            usize = le(table_data, at + 16, 4),
            csize = le(table_data, at + 20, 4),
            comp = table_data:byte(at + 25),
        }
    end
    return { path = path, chunks = chunks, cache = {}, order = {} }
end

local function chunk_data(head, index)
    local cached = head.cache[index]
    if cached then return cached end
    local chunk = head.chunks[index]
    local raw, why = read_at(head.path, chunk.coff, chunk.csize)
    if not raw then return nil, why end
    local data = raw
    if chunk.comp == 3 then
        local unpacked, unpacked_why = lz4_block(raw, chunk.usize)
        if not unpacked then return nil, 'LZ4 block failed in ' .. head.path .. ': ' .. tostring(unpacked_why) end
        data = unpacked
    elseif chunk.comp ~= 0 then
        return nil, 'unknown DSAR compression ' .. tostring(chunk.comp) .. ' in ' .. head.path
    end
    head.cache[index] = data
    head.order[#head.order + 1] = index
    if #head.order > CACHE_LIMIT then
        local drop = table.remove(head.order, 1)
        head.cache[drop] = nil
    end
    return data
end

local function dsar_all(head)
    local parts = {}
    for index = 1, #head.chunks do
        local data, why = chunk_data(head, index)
        if not data then return nil, why end
        parts[#parts + 1] = data
    end
    return table.concat(parts)
end

local function dsar_read(head, off, size)
    if size <= 0 then return '' end
    local chunks = head.chunks
    local out, done = {}, 0
    local finish = off + size
    local low, high, first = 1, #chunks, #chunks
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local chunk = chunks[middle]
        if chunk.uoff + chunk.usize > off then
            first = middle
            high = middle - 1
        else
            low = middle + 1
        end
    end
    for index = first, #chunks do
        local chunk = chunks[index]
        if chunk.uoff >= finish then break end
        local data, why = chunk_data(head, index)
        if not data then return nil, why end
        local from = math.max(off, chunk.uoff) - chunk.uoff
        local to = math.min(finish, chunk.uoff + chunk.usize) - chunk.uoff
        if to > from then
            out[#out + 1] = data:sub(from + 1, to)
            done = done + (to - from)
        end
    end
    if done ~= size then return nil, 'wanted ' .. size .. ' bytes at ' .. off .. ', built ' .. done end
    return table.concat(out)
end

-- ---------------------------------------------------------------- bundle set

local function bundle_index(data_root)
    local path = data_root .. '/bundles.nxa'
    local data, why = read_at(path, 0, nil)
    if not data then return nil, why end
    if data:sub(1, 4) == 'DSAR' then
        local head, head_why = dsar_head(path)
        if not head then return nil, head_why end
        local payload, payload_why = dsar_all(head)
        if not payload then return nil, payload_why end
        data = payload
    end
    local count = le(data, 0x10, 4)
    if count == 0 or count > 100000 then return nil, 'the bundle index holds no packages: ' .. path end
    local packages, names = {}, {}
    for index = 0, count - 1 do
        local at = 0x18 + index * 24
        local size = le(data, at, 8)
        local name_off = le(data, at + 8, 4)
        local items = le(data, at + 12, 4)
        local items_off = le(data, at + 16, 4)
        local name = data:match('^([^%z]*)%z', name_off + 1)
        if name and name ~= '' then
            local list = {}
            for item = 0, items - 1 do
                local entry = items_off + item * 16
                list[#list + 1] = {
                    off = le(data, entry, 8),
                    uoff = le(data, entry + 8, 4),
                    bundle = data:byte(entry + 16),
                }
            end
            table.sort(list, function(a, b) return a.off < b.off end)
            packages[name] = { name = name, size = size, items = list }
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return { root = data_root, packages = packages, names = names, heads = {}, count = count }
end

local function bundle_stream(set, index)
    local head = set.heads[index]
    if head then return head end
    local path = set.root .. string.format('/bundles.%02d.nxa', index)
    local made, why = dsar_head(path)
    if not made then return nil, why end
    set.heads[index] = made
    return made
end

-- The bytes of one package file, assembled from the bundle fragments that hold it.
local function package_read(set, name, off, size)
    if size <= 0 then return '' end
    local package = set.packages[name]
    if not package then return nil, 'this game has no package ' .. name end
    local out, done = {}, 0
    local finish = off + size
    for index, item in ipairs(package.items) do
        local start = item.off
        local following = package.items[index + 1]
        local stop = following and following.off or package.size
        if stop > off and start < finish then
            local from = math.max(off, start)
            local to = math.min(finish, stop)
            local head, why = bundle_stream(set, item.bundle)
            if not head then return nil, why end
            local data, read_why = dsar_read(head, item.uoff + (from - start), to - from)
            if not data then return nil, read_why end
            out[#out + 1] = data
            done = done + #data
        end
        if start >= finish then break end
    end
    if done ~= size then return nil, 'wanted ' .. size .. ' bytes at ' .. off .. ', built ' .. done end
    return table.concat(out)
end

-- ---------------------------------------------------------------- package container

local ENTRY_SIZE = 0x50
local TYPE_SIZE = 0x20
local HEADER_SIZE = 0x48
local MAGIC = 0xF0000011
local TYPE_UNIT = 'e0a48d0be9a7453f'
local TYPE_BONES = '18dead01056b72e9'
local TYPE_TEXTURE = 'cd4238c6a0c69e32'
local GPU_SUFFIX = '.gpu_resources'
local STREAM_SUFFIX = '.stream'

-- 64 bit ids never fit a Lua number, so they stay as their eight little endian bytes and are
-- compared as the hex string people write down.
local function hex_of(raw)
    local parts = {}
    for index = #raw, 1, -1 do parts[#parts + 1] = string.format('%02x', raw:byte(index)) end
    return table.concat(parts)
end

local function package_head(set, name)
    local header, why = package_read(set, name, 0, HEADER_SIZE)
    if not header then return nil, why end
    if le(header, 0, 4) ~= MAGIC then return nil, 'not a package container: ' .. name end
    local types = le(header, 4, 4)
    local entries = le(header, 8, 4)
    if types > 4096 or entries > 100000 then return nil, 'the package table of ' .. name .. ' looks wrong' end
    local table_size = HEADER_SIZE + types * TYPE_SIZE + entries * ENTRY_SIZE
    local data, table_why = package_read(set, name, 0, table_size)
    if not data then return nil, table_why end
    local spec = { name = name, magic = MAGIC, unknown = le(header, 12, 4),
                   trailing = data:sub(17, 16 + 56), types = {}, entries = {} }
    for index = 0, types - 1 do
        local at = HEADER_SIZE + index * TYPE_SIZE
        local type_raw = data:sub(at + 9, at + 16)
        spec.types[#spec.types + 1] = {
            unknown_raw = data:sub(at + 1, at + 8),
            type_raw = type_raw,
            type_hex = hex_of(type_raw),
            num_files = le(data, at + 16, 8),
            tail_a = le(data, at + 24, 4),
            tail_b = le(data, at + 28, 4),
        }
    end
    for index = 0, entries - 1 do
        local at = HEADER_SIZE + types * TYPE_SIZE + index * ENTRY_SIZE
        local id_raw = data:sub(at + 1, at + 8)
        local type_raw = data:sub(at + 9, at + 16)
        spec.entries[#spec.entries + 1] = {
            id_raw = id_raw,
            id_hex = hex_of(id_raw),
            type_raw = type_raw,
            type_hex = hex_of(type_raw),
            toc_at = le(data, at + 16, 8),
            stream_at = le(data, at + 24, 8),
            gpu_at = le(data, at + 32, 8),
            unknown1_raw = data:sub(at + 41, at + 48),
            unknown2_raw = data:sub(at + 49, at + 56),
            toc_size = le(data, at + 56, 4),
            stream_size = le(data, at + 60, 4),
            gpu_size = le(data, at + 64, 4),
            unknown3 = le(data, at + 68, 4),
            unknown4 = le(data, at + 72, 4),
            entry_index = le(data, at + 76, 4),
        }
    end
    return spec
end

-- Units and bones never carry streamed bytes, some builds write a poison length for textures, and
-- the rest simply declares the size it has (the same policy the reference tool applies).
local function stream_length(set, spec, entry, toc)
    if entry.stream_size == 0 then return 0 end
    if entry.type_hex == TYPE_UNIT or entry.type_hex == TYPE_BONES then return 0 end
    local side = set.packages[spec.name .. STREAM_SUFFIX]
    local length = side and side.size or 0
    if length == 0 then return 0 end
    if entry.stream_at + entry.stream_size <= length then return entry.stream_size end
    if entry.type_hex == TYPE_TEXTURE then
        if #toc < 0x14 then return nil, 'a texture in ' .. spec.name .. ' has a toc too small to read' end
        return le(toc, 0x10, 4)
    end
    return nil, 'a resource in ' .. spec.name .. ' declares a stream size that does not fit the archive'
end

local function read_side(set, spec, suffix, at, size, what)
    if size == 0 then return '' end
    local side = set.packages[spec.name .. suffix]
    if not side then return nil, 'this game has no ' .. what .. ' for ' .. spec.name end
    if at + size > side.size then
        return nil, string.format('the %s of %s is %d bytes, but an entry wants %d bytes at %d',
            what, spec.name, side.size, size, at)
    end
    return package_read(set, spec.name .. suffix, at, size)
end

local function package_slices(set, name, spec, keep_streams)
    local blobs = {}
    for _, entry in ipairs(spec.entries) do
        local heavy = entry.gpu_size > 0 or entry.stream_size > 0
        if keep_streams or not heavy then
            local toc, why = package_read(set, name, entry.toc_at, entry.toc_size)
            if not toc then return nil, why end
            local gpu, stream = '', ''
            if keep_streams and entry.gpu_size > 0 then
                gpu, why = read_side(set, spec, GPU_SUFFIX, entry.gpu_at, entry.gpu_size, 'gpu resources')
                if not gpu then return nil, why end
            end
            if keep_streams and entry.stream_size > 0 then
                local size, size_why = stream_length(set, spec, entry, toc)
                if not size then return nil, size_why end
                if size > 0 then
                    stream, why = read_side(set, spec, STREAM_SUFFIX, entry.stream_at, size, 'stream')
                    if not stream then return nil, why end
                end
            end
            blobs[#blobs + 1] = { entry = entry, toc = toc, gpu = gpu, stream = stream }
        end
    end
    return blobs
end

-- Rebuilds a package holding only these blobs (srkit Package.to_bytes, without the source hints).
local function build_package(spec, blobs)
    local types, known = {}, {}
    for _, item in ipairs(spec.types) do
        types[#types + 1] = { unknown_raw = item.unknown_raw, type_raw = item.type_raw,
                              type_hex = item.type_hex, num_files = 0,
                              tail_a = item.tail_a, tail_b = item.tail_b }
        known[item.type_hex] = true
    end
    for _, blob in ipairs(blobs) do
        if not known[blob.entry.type_hex] then
            types[#types + 1] = { unknown_raw = string.rep('\0', 8), type_raw = blob.entry.type_raw,
                                  type_hex = blob.entry.type_hex, num_files = 0,
                                  tail_a = 16, tail_b = 64 }
            known[blob.entry.type_hex] = true
        end
    end
    local counts = {}
    for _, blob in ipairs(blobs) do
        counts[blob.entry.type_hex] = (counts[blob.entry.type_hex] or 0) + 1
    end
    for _, item in ipairs(types) do item.num_files = counts[item.type_hex] or 0 end

    local head = { u32(spec.magic), u32(#types), u32(#blobs), u32(spec.unknown), spec.trailing }
    for _, item in ipairs(types) do
        head[#head + 1] = item.unknown_raw .. item.type_raw .. u64(item.num_files)
                      .. u32(item.tail_a) .. u32(item.tail_b)
    end

    -- toc offsets are absolute in the file, so the body starts after the header and both tables
    local base = HEADER_SIZE + #types * TYPE_SIZE + #blobs * ENTRY_SIZE
    local body, body_len = {}, base
    local gpu, gpu_len = {}, 0
    local stream, stream_len = {}, 0
    local placed = {}
    for index, blob in ipairs(blobs) do
        local at = align_up(body_len, 16)
        if at > body_len then body[#body + 1] = string.rep('\0', at - body_len) end
        body_len = at
        local where = { toc_at = body_len, gpu_at = gpu_len, stream_at = stream_len }
        if #blob.toc > 0 then
            body[#body + 1] = blob.toc
            body_len = body_len + #blob.toc
        end
        if #blob.gpu > 0 then
            local target = align_up(gpu_len, 64)
            if target > gpu_len then gpu[#gpu + 1] = string.rep('\0', target - gpu_len) end
            where.gpu_at = target
            gpu[#gpu + 1] = blob.gpu
            gpu_len = target + #blob.gpu
        end
        if #blob.stream > 0 then
            stream[#stream + 1] = blob.stream
            stream_len = stream_len + #blob.stream
        end
        placed[index] = where
    end

    local offsets = {}
    for index, blob in ipairs(blobs) do
        local where = placed[index]
        local entry = blob.entry
        offsets[index] = entry.id_raw .. entry.type_raw .. u64(where.toc_at)
            .. u64(where.stream_at) .. u64(where.gpu_at) .. entry.unknown1_raw .. entry.unknown2_raw
            .. u32(#blob.toc) .. u32(#blob.stream) .. u32(#blob.gpu)
            .. u32(entry.unknown3) .. u32(entry.unknown4) .. u32(index)
    end
    local text = table.concat(head) .. table.concat(offsets) .. table.concat(body)
    local minimum = math.max(align_up(#text, 16), 256 * math.max(1, #blobs))
    if minimum > #text then text = text .. string.rep('\0', minimum - #text) end
    return text, table.concat(gpu), table.concat(stream)
end

M._internal = { le = le, u32 = u32, u64 = u64, align_up = align_up,
                package_head = package_head, package_slices = package_slices,
                build_package = build_package, bundle_index = bundle_index,
                package_read = package_read }

-- ---------------------------------------------------------------- which patch slot

local function patch_name(host, index) return string.format('%s.patch_%d', host, index) end

-- The patch files already in the game folder for one package: the numbers it uses, and the first free one.
local function used_numbers(root, host)
    local handle = io.open(root .. '/bundles.nxa', 'rb')
    if not handle then return nil end
    handle:close()
    local used, highest = {}, -1
    for index = 0, 63 do
        local base = root .. '/' .. patch_name(host, index)
        local size = M.file_size(base)
        if size == nil then
            size = M.file_size(base .. '.stream') or M.file_size(base .. '.gpu_resources')
        end
        if size == nil then break end
        used[#used + 1] = index
        highest = index
    end
    return used, highest
end

-- ---------------------------------------------------------------- ledger

function M.ledger_path(ctx) return (ctx.profile or '') .. '/residency.txt' end

function M.read_ledger(ctx)
    if not ctx.profile or ctx.profile == '' then return {} end
    local text = M.read_file(M.ledger_path(ctx))
    local entries = {}
    for line in (text or ''):gmatch('[^\r\n]+') do
        local host, index, name, mode = line:match('^(%S+) (%d+) (%S+) (%S+)')
        if host then
            entries[#entries + 1] = { host = host, index = tonumber(index), name = name, mode = mode,
                                      built = tonumber(line:match(' (%d+)$') or '0') }
        end
    end
    table.sort(entries, function(a, b)
        if a.host ~= b.host then return a.host < b.host end
        return a.index < b.index
    end)
    return entries
end

function M.write_ledger(ctx, entries)
    local lines = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = string.format('%s %d %s %s %d', entry.host, entry.index, entry.name,
                                          entry.mode, entry.built or 0)
    end
    return M.write_file(M.ledger_path(ctx), table.concat(lines, '\n') .. (#lines > 0 and '\n' or ''))
end

function M.entry_of(ctx, host, name)
    for _, entry in ipairs(M.read_ledger(ctx)) do
        if entry.host == host and entry.name == name then return entry end
    end
    return nil
end

-- 0: not resident, 1: everything, 2: the light resources only.
function M.state(ctx, host, name)
    local entry = M.entry_of(ctx, host, name)
    if not entry then return 0 end
    if M.file_size(ctx.root .. '/' .. patch_name(host, entry.index)) == nil then return 0 end
    return entry.mode == 'full' and 1 or 2
end

-- ---------------------------------------------------------------- installing

local function bundle_set(ctx)
    if ctx.error then return nil, ctx.error end
    if ctx.set then return ctx.set end
    local set, why = bundle_index(ctx.root)
    if not set then ctx.error = why return nil, why end
    ctx.set = set
    return set
end

local function remove_files(root, host, index)
    local base = root .. '/' .. patch_name(host, index)
    os.remove(base)
    os.remove(base .. '.gpu_resources')
    os.remove(base .. '.stream')
end

-- Writes one patch set and returns the slot it took, plus what went into it.
function M.install(ctx, host, name, mode)
    local set, why = bundle_set(ctx)
    if not set then return nil, why end
    if not set.packages[name] then return nil, 'this game has no package ' .. name end
    local spec, head_why = package_head(set, name)
    if not spec then return nil, head_why end
    local blobs, slice_why = package_slices(set, name, spec, mode == 'full')
    if not blobs then return nil, slice_why end
    if #blobs == 0 then return nil, 'this package holds nothing a patch can carry' end
    local toc, gpu, stream = build_package(spec, blobs)

    -- Replacing a resident package keeps its slot: taking a new one would leave the old patch
    -- behind, and the loader would merge both copies of the same files.
    local entries = M.read_ledger(ctx)
    local existing
    for at, entry in ipairs(entries) do
        if entry.host == host and entry.name == name then existing = at break end
    end
    local index
    if existing then
        index = entries[existing].index
        remove_files(ctx.root, host, index)
    else
        local used, highest = used_numbers(ctx.root, host)
        if not used then return nil, 'the game data folder was not found: ' .. ctx.root end
        index = highest + 1
    end
    local base = ctx.root .. '/' .. patch_name(host, index)
    local ok, write_why = M.write_file(base, toc)
    if not ok then return nil, write_why end
    if #gpu > 0 then
        ok, write_why = M.write_file(base .. '.gpu_resources', gpu)
        if not ok then os.remove(base) return nil, write_why end
    end
    if #stream > 0 then
        ok, write_why = M.write_file(base .. '.stream', stream)
        if not ok then os.remove(base) os.remove(base .. '.gpu_resources') return nil, write_why end
    end

    if existing then table.remove(entries, existing) end
    entries[#entries + 1] = { host = host, index = index, name = name, mode = mode, built = #blobs }
    M.write_ledger(ctx, entries)
    return { index = index, entries = #blobs, toc = #toc, gpu = #gpu, stream = #stream, mode = mode }
end

-- Takes one patch set back out.  Later slots move down so the numbering stays continuous (a hole
-- would stop every later patch from being merged).
function M.remove(ctx, host, name)
    local entries = M.read_ledger(ctx)
    local at, found = nil, nil
    for index, entry in ipairs(entries) do
        if entry.host == host and entry.name == name then at, found = index, entry break end
    end
    if not found then return nil, 'nothing to take back: this package is not resident' end
    remove_files(ctx.root, host, found.index)
    local after = {}
    for _, entry in ipairs(entries) do
        if entry.host == host and entry.index > found.index then after[#after + 1] = entry end
    end
    table.sort(after, function(a, b) return a.index < b.index end)
    for _, entry in ipairs(after) do
        local from = ctx.root .. '/' .. patch_name(host, entry.index)
        local to = ctx.root .. '/' .. patch_name(host, entry.index - 1)
        local toc = M.read_file(from)
        if toc then
            local ok, why = M.write_file(to, toc)
            if not ok then return nil, why end
            for _, suffix in ipairs({ '.gpu_resources', '.stream' }) do
                local extra = M.read_file(from .. suffix)
                if extra then
                    local written, extra_why = M.write_file(to .. suffix, extra)
                    if not written then return nil, extra_why end
                end
            end
            remove_files(ctx.root, host, entry.index)
            entry.index = entry.index - 1
        end
    end
    table.remove(entries, at)
    M.write_ledger(ctx, entries)
    return found
end

M._internal.patch_name = patch_name
M._internal.used_numbers = used_numbers

return M
