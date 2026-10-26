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
    if not handle then return nil, '无法打开文件：' .. path end
    if off and off > 0 then
        local moved = handle:seek('set', off)
        if not moved then handle:close() return nil, '无法定位文件读取位置：' .. path end
    end
    local data = size and handle:read(size) or handle:read('*a')
    handle:close()
    if not data then return nil, '无法读取文件：' .. path end
    if size and #data < size then return nil, '读取的文件数据不完整：' .. path end
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
    if not handle then return false, '无法写入文件：' .. path end
    local wrote = handle:write(data)
    local closed = handle:close()
    if not wrote or not closed then pcall(os.remove, temp) return false, '无法写入文件：' .. path end
    os.remove(path)
    local moved = os.rename(temp, path)
    if not moved then pcall(os.remove, temp) return false, '无法替换文件：' .. path end
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
                if i > n then return nil, 'LZ4 原始数据长度字段不完整' end
                local extra = src:byte(i)
                i = i + 1
                literals = literals + extra
                if extra ~= 255 then break end
            end
        end
        if literals > 0 then
            if i + literals - 1 > n then return nil, 'LZ4 原始数据段不完整' end
            push(src:sub(i, i + literals - 1))
            i = i + literals
        end
        if i > n then break end
        if i + 1 > n then return nil, 'LZ4 匹配偏移字段不完整' end
        local offset = src:byte(i) + src:byte(i + 1) * 256
        i = i + 2
        if offset == 0 then return nil, 'LZ4 匹配偏移不能为 0' end
        local match = token % 16
        if match == 15 then
            while true do
                if i > n then return nil, 'LZ4 匹配长度字段不完整' end
                local extra = src:byte(i)
                i = i + 1
                match = match + extra
                if extra ~= 255 then break end
            end
        end
        match = match + 4
        if offset > #tail then return nil, 'LZ4 匹配位置超出数据块起点' end
        local pattern = tail:sub(#tail - offset + 1)
        local copies = math.ceil(match / #pattern)
        push(pattern:rep(copies):sub(1, match))
    end
    if out_size and total ~= out_size then return nil, '解压长度不匹配：预期 ' .. out_size .. '，实际 ' .. total end
    return table.concat(parts)
end

-- LuaJIT can decode into one bounded buffer. The string fallback repeatedly
-- copies a 256 KiB history for every match, which dominates large resource packs.
local has_ffi, ffi = pcall(require, 'ffi')
local string_lz4 = lz4_block
if has_ffi then
    lz4_block = function(src, out_size)
        if not out_size then return string_lz4(src, out_size) end
        if out_size < 0 or out_size ~= math.floor(out_size) then return nil, 'LZ4 解压长度无效' end
        local out = ffi.new('uint8_t[?]', math.max(1, out_size))
        local input = ffi.cast('const uint8_t *', src)
        local i, done, n = 0, 0, #src
        local function length(value)
            if value == 15 then
                while true do
                    if i >= n then return nil end
                    local extra = tonumber(input[i]); i = i + 1
                    value = value + extra
                    if extra ~= 255 then break end
                end
            end
            return value
        end
        while i < n do
            local token = tonumber(input[i]); i = i + 1
            local literals = length(math.floor(token / 16))
            if not literals or i + literals > n or done + literals > out_size then
                return nil, 'LZ4 原始数据段超出边界'
            end
            if literals > 0 then ffi.copy(out + done, input + i, literals) end
            i, done = i + literals, done + literals
            if i == n then break end
            if i + 2 > n then return nil, 'LZ4 匹配偏移字段不完整' end
            local offset = tonumber(input[i]) + tonumber(input[i+1]) * 256; i = i + 2
            if offset == 0 or offset > done then return nil, 'LZ4 匹配位置超出数据块起点' end
            local match = length(token % 16)
            if not match or done + match + 4 > out_size then return nil, 'LZ4 匹配段超出边界' end
            match = match + 4
            -- Never pass overlapping ranges to memcpy: seed from history, then
            -- double the copied prefix to expand overlapping LZ4 matches safely.
            local copied = math.min(offset, match)
            ffi.copy(out + done, out + done - offset, copied)
            while copied < match do
                local count = math.min(copied, match - copied)
                ffi.copy(out + done + copied, out + done, count)
                copied = copied + count
            end
            done = done + match
        end
        if done ~= out_size then return nil, 'LZ4 解压长度不匹配' end
        return ffi.string(out, done)
    end
end
M.lz4_block = lz4_block
M._string_lz4 = string_lz4 -- independent reference for codec regression tests


-- ---------------------------------------------------------------- DSAR chunks

local CACHE_LIMIT = 12

local function dsar_head(path)
    local head = read_at(path, 0, 32)
    if not head then return nil, '无法读取文件：' .. path end
    if head:sub(1, 4) ~= 'DSAR' then return nil, '文件不是有效的 DSAR 容器：' .. path end
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
        if not unpacked then return nil, 'LZ4 数据块解压失败，文件：' .. head.path .. ': ' .. tostring(unpacked_why) end
        data = unpacked
    elseif chunk.comp ~= 0 then
        return nil, '不支持的 DSAR 压缩类型：' .. tostring(chunk.comp) .. '，文件：' .. head.path
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
    if done ~= size then return nil, '资源读取长度不匹配：偏移 ' .. off .. '，预期 ' .. size .. ' 字节，实际 ' .. done end
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
    if count == 0 or count > 100000 then return nil, '资源索引中没有有效资源包：' .. path end
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
    if not package then return nil, '当前游戏中找不到资源包：' .. name end
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
    if done ~= size then return nil, '资源读取长度不匹配：偏移 ' .. off .. '，预期 ' .. size .. ' 字节，实际 ' .. done end
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
    if le(header, 0, 4) ~= MAGIC then return nil, '不是有效的资源包容器：' .. name end
    local types = le(header, 4, 4)
    local entries = le(header, 8, 4)
    if types > 4096 or entries > 100000 then return nil, '资源包目录结构异常：' .. name end
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
        if #toc < 0x14 then return nil, '资源包中的纹理目录数据不完整：' .. spec.name end
        return le(toc, 0x10, 4)
    end
    return nil, '资源包声明的数据流大小与实际文件不符：' .. spec.name
end

local function read_side(set, spec, suffix, at, size, what)
    if size == 0 then return '' end
    local side = set.packages[spec.name .. suffix]
    if not side then return nil, '资源包缺少配套文件：' .. spec.name .. '（' .. what .. '）' end
    if at + size > side.size then
        return nil, string.format('the %s of %s is %d bytes, but an entry wants %d bytes at %d',
            what, spec.name, side.size, size, at)
    end
    return package_read(set, spec.name .. suffix, at, size)
end

-- An override map comes from the panel, so an id may arrive in either case and with or without 0x.
local function hex_key(id_hex)
    return (tostring(id_hex):gsub('^0[xX]', '')):lower()
end

-- Override keys are '<type_hex>:<id_hex>'.  A bare id is accepted only when the package holds it
-- once: a real package reuses one id for four entries (bones, animations, the state machine, a mesh),
-- and a bare id there would put one blob in all four places.  So a repeated id is a refusal, never a
-- guess.  The count comes from the whole package, not from the subset being rebuilt.
local function override_index(overrides, spec)
    if overrides == nil then return {} end
    local counts = {}
    for _, entry in ipairs(spec.entries) do
        counts[entry.id_hex] = (counts[entry.id_hex] or 0) + 1
    end
    local index = {}
    for key, bytes in pairs(overrides) do
        if type(key) ~= 'string' or type(bytes) ~= 'string' then
            return nil, '资源覆盖内容必须是按资源 ID 给出的字节串'
        end
        local type_hex, id_hex = string.match(key, '^([^:]+):(.+)$')
        if type_hex then
            index[hex_key(type_hex) .. ':' .. hex_key(id_hex)] = bytes
        else
            local id = hex_key(key)
            if (counts[id] or 0) > 1 then
                return nil, '资源编号 ' .. id .. ' 在包里出现多次，请用 类型:编号 指定'
            end
            index['*:' .. id] = bytes
        end
    end
    return index
end

-- The toc bytes one entry is to carry: the ones for its type and id, otherwise the ones a bare id gave
-- it (only reachable when that id is unique in the package).
local function override_for(index, type_hex, id_hex)
    id_hex = hex_key(id_hex)
    return index[hex_key(type_hex) .. ':' .. id_hex] or index['*:' .. id_hex]
end

-- keep_streams keeps the heavy side files too.  overrides maps '<type>:<id>' to the toc bytes that
-- replace the ones the package holds; the streams of such an entry still come from the package.
local function package_slices(set, name, spec, keep_streams, overrides)
    local index, index_why = override_index(overrides, spec)
    if not index then return nil, index_why end
    local blobs = {}
    for _, entry in ipairs(spec.entries) do
        local heavy = entry.gpu_size > 0 or entry.stream_size > 0
        if keep_streams or not heavy then
            local why
            local toc = override_for(index, entry.type_hex, entry.id_hex)
            if toc == nil then
                toc, why = package_read(set, name, entry.toc_at, entry.toc_size)
                if not toc then return nil, why end
            end
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
    -- Enumerate real names: a fixed 0..63 probe ignored existing higher patches
    -- and could overwrite them when compacting an owned patch.
    local ok, installer = pcall(require, 'install')
    if not ok or type(installer.list_files) ~= 'function' then return nil end
    local names = installer.list_files(root, host .. '.patch_*')
    local used, seen, highest = {}, {}, -1
    for _, filename in ipairs(names) do
        local suffix = filename:sub(#host + 1)
        local number, tail = suffix:match('^%.patch_(%d+)(.*)$')
        local index = tonumber(number)
        if index and (tail == '' or tail == '.stream' or tail == '.gpu_resources') and not seen[index] then
            seen[index] = true
            used[#used + 1] = index
            highest = math.max(highest, index)
        end
    end
    table.sort(used)
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

-- 0: not resident, 1: everything, 2: the light resources only.  A 'res' patch holds edits of a few
-- resources instead of residency, so the panel must not report it as a resident package.
function M.state(ctx, host, name)
    local entry = M.entry_of(ctx, host, name)
    if not entry then return 0 end
    if M.file_size(ctx.root .. '/' .. patch_name(host, entry.index)) == nil then return 0 end
    if entry.mode == 'full' then return 1 end
    if entry.mode == 'res' then return 0 end
    return 2
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

-- Every entry of one type inside a package, for the panel's picker.  The directory is enough here;
-- no resource bytes are read.
function M.entries_of_type(ctx, name, type_hex)
    local set, why = bundle_set(ctx)
    if not set then return nil, why end
    if not set.packages[name] then return nil, '当前游戏中找不到资源包：' .. name end
    local spec, head_why = package_head(set, name)
    if not spec then return nil, head_why end
    local wanted = hex_key(type_hex)
    local list = {}
    for _, entry in ipairs(spec.entries) do
        if hex_key(entry.type_hex) == wanted then
            list[#list + 1] = { id_hex = entry.id_hex, type_hex = entry.type_hex,
                                toc_size = entry.toc_size,
                                gpu_size = entry.gpu_size, stream_size = entry.stream_size }
        end
    end
    return list
end

-- The toc bytes of one entry: what the panel shows, and what an edit starts from.  type_hex is
-- optional for the older callers; pass it whenever the id is not unique, because one id can carry the
-- bones, the animations, the state machine and the mesh of the same entity.
function M.read_entry(ctx, name, id_hex, type_hex)
    local set, why = bundle_set(ctx)
    if not set then return nil, why end
    if not set.packages[name] then return nil, '当前游戏中找不到资源包：' .. name end
    local spec, head_why = package_head(set, name)
    if not spec then return nil, head_why end
    local wanted = hex_key(id_hex)
    local wanted_type = type_hex ~= nil and hex_key(type_hex) or nil
    for _, entry in ipairs(spec.entries) do
        if entry.id_hex == wanted and (wanted_type == nil or entry.type_hex == wanted_type) then
            return package_read(set, name, entry.toc_at, entry.toc_size)
        end
    end
    if wanted_type then
        return nil, '当前资源包中找不到这条资源：' .. wanted_type .. ':' .. wanted
    end
    return nil, '当前资源包中找不到这条资源：' .. tostring(id_hex)
end

-- The ledger entry of one package, so the panel can show which slot holds it.
function M.patch_of(ctx, host, name) return M.entry_of(ctx, host, name) end

local function remove_files(root, host, index)
    local base = root .. '/' .. patch_name(host, index)
    for _, suffix in ipairs({ '', '.gpu_resources', '.stream' }) do
        local path = base .. suffix
        if M.file_size(path) ~= nil and not os.remove(path) then return nil, '无法移除补丁文件：' .. path end
    end
    return true
end

local function transaction(ctx, host, indexes, action)
    local before, read_error = {}, nil
    local function remember(path)
        local bytes, why = M.read_file(path)
        if not bytes and M.file_size(path) ~= nil then read_error = why or ('无法备份：' .. path) end
        before[#before + 1] = { path = path, bytes = bytes }
    end
    remember(M.ledger_path(ctx))
    for _, index in ipairs(indexes) do
        local base = ctx.root .. '/' .. patch_name(host, index)
        for _, suffix in ipairs({ '', '.gpu_resources', '.stream' }) do remember(base .. suffix) end
    end
    if read_error then return nil, read_error end
    local ran, result, why = pcall(action)
    if not ran then why = tostring(result); result = nil end
    if result then return result end
    local failures = {}
    for _, item in ipairs(before) do
        local ok, err
        if item.bytes then ok, err = M.write_file(item.path, item.bytes)
        else
            ok = M.file_size(item.path) == nil or os.remove(item.path)
            err = item.path
        end
        if not ok then failures[#failures + 1] = tostring(err) end
    end
    if #failures > 0 then why = tostring(why) .. '；回滚失败：' .. table.concat(failures, '，') end
    return nil, why
end

-- The spec a 'res' patch is built from: only the types that carry a blob, so the twelve texture
-- types of a real package cannot smuggle eleven empty ones into a patch of one state machine.
local function trimmed_spec(spec, blobs)
    local present = {}
    for _, blob in ipairs(blobs) do present[blob.entry.type_hex] = true end
    local types = {}
    for _, item in ipairs(spec.types) do
        if present[item.type_hex] then types[#types + 1] = item end
    end
    return { name = spec.name, magic = spec.magic, unknown = spec.unknown,
             trailing = spec.trailing, types = types, entries = spec.entries }
end

-- The slot this package takes: the one its ledger entry already owns, otherwise the next free
-- number.  Rebuilding a resident package keeps its slot, because taking a new one would leave the
-- old patch behind and the loader would merge both copies, the lower number's original bytes
-- winning over the edit.
local function slot_for(ctx, host, name)
    local entries = M.read_ledger(ctx)
    local at, existing = nil, nil
    for index, entry in ipairs(entries) do
        if entry.host == host and entry.name == name then at, existing = index, entry break end
    end
    if existing then return entries, at, existing.index end
    local used, highest = used_numbers(ctx.root, host)
    if not used then return nil, nil, nil, '找不到游戏资源目录：' .. ctx.root end
    if #used ~= highest + 1 then return nil, nil, nil, '补丁序号不连续，请先整理现有补丁；未修改任何文件' end
    return entries, nil, highest + 1
end

-- Writes the three files of one patch set, drops the side files a rebuild no longer needs, reads the
-- patch back to prove the bytes landed, and only then records the slot in the ledger.  Everything
-- runs inside a transaction, so a failure puts the previous patch back.
local function write_patch(ctx, host, name, mode, index, at, entries, toc, gpu, stream, count)
    return transaction(ctx, host, { index }, function()
    local base = ctx.root .. '/' .. patch_name(host, index)
    local ok, write_why = M.write_file(base, toc)
    if not ok then return nil, write_why end
    if #gpu > 0 then
        ok, write_why = M.write_file(base .. GPU_SUFFIX, gpu)
        if not ok then os.remove(base) return nil, write_why end
    end
    if #stream > 0 then
        ok, write_why = M.write_file(base .. STREAM_SUFFIX, stream)
        if not ok then os.remove(base) os.remove(base .. GPU_SUFFIX) return nil, write_why end
    end

    for _, suffix in ipairs({ GPU_SUFFIX, STREAM_SUFFIX }) do
        if (suffix == GPU_SUFFIX and #gpu == 0) or (suffix == STREAM_SUFFIX and #stream == 0) then
            if M.file_size(base .. suffix) ~= nil and not os.remove(base .. suffix) then return nil, '无法清理旧资源：' .. base .. suffix end
        end
    end

    local landed = M.read_file(base)
    if not landed or #landed ~= #toc then return nil, '补丁写入校验失败：' .. base end

    if at then table.remove(entries, at) end
    entries[#entries + 1] = { host = host, index = index, name = name, mode = mode, built = count }
    local saved, ledger_why = M.write_ledger(ctx, entries)
    if not saved then return nil, ledger_why end
    return { index = index, entries = count, toc = #toc, gpu = #gpu, stream = #stream, mode = mode }
    end)
end

-- Writes one patch set and returns the slot it took, plus what went into it.  overrides maps
-- '<type>:<id>' (or a bare id the package holds once) to the toc bytes that replace the ones the
-- package holds, which is how a single edited resource (a state machine, say) travels without a
-- second resident package.
--   'full'  every entry, side streams included
--   'light' the entries without side streams only
--   'res'   only the overridden entries, and only the types they belong to
-- A nil mode keeps the mode the package's ledger entry already has.
function M.install_with(ctx, host, name, mode, overrides)
    if mode == nil or mode == '' then
        local known = M.entry_of(ctx, host, name)
        mode = known and known.mode or nil
    end
    if mode ~= 'full' and mode ~= 'light' and mode ~= 'res' then return nil, '无效的资源驻留模式' end
    if mode == 'res' and (overrides == nil or next(overrides) == nil) then return nil, '没有要写入的资源' end
    if overrides ~= nil then
        for key, bytes in pairs(overrides) do
            if type(key) ~= 'string' or type(bytes) ~= 'string' then
                return nil, '资源覆盖内容必须是按资源 ID 给出的字节串'
            end
        end
    end
    local entries, at, slot_index, slot_why = slot_for(ctx, host, name)
    if not entries then return nil, slot_why end
    local set, why = bundle_set(ctx)
    if not set then return nil, why end
    if not set.packages[name] then return nil, '当前游戏中找不到资源包：' .. name end
    local spec, head_why = package_head(set, name)
    if not spec then return nil, head_why end
    -- Resolved against the whole package, so a bare id whose id repeats everywhere is refused here
    -- instead of quietly matching whichever entry came first.
    local index, index_why = override_index(overrides, spec)
    if not index then return nil, index_why end

    local picked, resolved = nil, {}
    for _, entry in ipairs(spec.entries) do
        local bytes = override_for(index, entry.type_hex, entry.id_hex)
        if bytes ~= nil then
            resolved[entry.type_hex .. ':' .. entry.id_hex] = bytes
            if mode == 'res' then
                if entry.gpu_size > 0 or entry.stream_size > 0 then
                    return nil, '这条资源带有独立数据流，不能单独写入资源补丁：'
                        .. entry.type_hex .. ':' .. entry.id_hex
                end
                picked = picked or {}
                picked[#picked + 1] = entry
            end
        end
    end
    if mode == 'res' and picked == nil then return nil, '这些资源不在此资源包中：' .. name end
    local slice_spec = picked and { name = spec.name, magic = spec.magic, unknown = spec.unknown,
                                    trailing = spec.trailing, types = spec.types,
                                    entries = picked } or spec
    local blobs, slice_why = package_slices(set, name, slice_spec, mode == 'full', resolved)
    if not blobs then return nil, slice_why end
    if #blobs == 0 then return nil, '此资源包没有可以写入常驻补丁的资源' end
    local build_spec = picked and trimmed_spec(spec, blobs) or spec
    local toc, gpu, stream = build_package(build_spec, blobs)

    return write_patch(ctx, host, name, mode, slot_index, at, entries, toc, gpu, stream, #blobs)
end

-- Writes one patch set and returns the slot it took, plus what went into it.
function M.install(ctx, host, name, mode)
    if mode ~= 'full' and mode ~= 'light' then return nil, '无效的资源驻留模式' end
    local overrides, why = M.saved_overrides(ctx, host, name)
    if not overrides then return nil, why end
    return M.install_with(ctx, host, name, mode, overrides)
end

-- Takes one patch set back out.  Later slots move down so the numbering stays continuous (a hole
-- would stop every later patch from being merged).
function M.remove(ctx, host, name)
    local entries = M.read_ledger(ctx)
    local at, found = nil, nil
    for index, entry in ipairs(entries) do
        if entry.host == host and entry.name == name then at, found = index, entry break end
    end
    if not found then return nil, '此资源包尚未安装常驻补丁，无需移除' end
    local used = used_numbers(ctx.root, host)
    if not used then return nil, '找不到游戏资源目录' end
    local owned = {}
    for _, entry in ipairs(entries) do if entry.host == host then owned[entry.index] = true end end
    local affected = { found.index }
    for _, index in ipairs(used) do
        if index > found.index then
            if not owned[index] then return nil, '后续槽位含有其他 Mod 补丁，请先移除该补丁；未修改任何文件' end
            affected[#affected + 1] = index
        end
    end
    if #used > 0 and #used ~= used[#used] + 1 then return nil, '补丁序号不连续；未修改任何文件' end
    return transaction(ctx, host, affected, function()
    local removed, remove_why = remove_files(ctx.root, host, found.index)
    if not removed then return nil, remove_why end
    if M.file_size(ctx.root .. '/' .. patch_name(host, found.index)) ~= nil then return nil, '无法移除补丁文件' end
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
            local removed, remove_why = remove_files(ctx.root, host, entry.index)
            if not removed then return nil, remove_why end
            entry.index = entry.index - 1
        end
    end
    table.remove(entries, at)
    local saved, why = M.write_ledger(ctx, entries)
    if not saved then return nil, why end
    return found
    end)
end

-- Takes our changes back out.  A 'res' patch exists only for them, so it goes away entirely and the
-- later slots move down; a full or light patch stays resident and is rebuilt from the source
-- package, which is what dropping the override means for it.
function M.revert(ctx, host, name)
    local entry = M.entry_of(ctx, host, name)
    if not entry then return nil, '此资源包尚未安装常驻补丁，无需撤销' end
    if entry.mode == 'res' then
        local done, why = M.remove(ctx, host, name)
        if not done then return nil, why end
        return true
    end
    local info, why = M.install_with(ctx, host, name, entry.mode, {})
    if not info then return nil, why end
    return true
end

-- ---------------------------------------------------------------- reading our own patch

-- A patch slot parsed as a container of its own, so what we wrote can be read back the same way the
-- source package is read.  A patch lives in the game folder, not in the bundles, so it becomes a one
-- package set in memory instead of going through bundle_index.
local function patch_set(ctx, host, name)
    local entry = M.entry_of(ctx, host, name)
    if not entry then return nil, nil, '未安装' end
    local base = patch_name(host, entry.index)
    local bytes, why = M.read_file(ctx.root .. '/' .. base)
    if not bytes then return nil, nil, '补丁文件读不到：' .. tostring(why) end
    if #bytes < HEADER_SIZE then return nil, nil, '补丁文件长度不足：' .. base end
    local set = { packages = {}, heads = {} }
    set.packages[name] = { size = #bytes, items = { { off = 0, uoff = 0, bundle = 0 } } }
    set.heads[0] = { cache = { [1] = bytes }, order = {}, chunks = { { uoff = 0, usize = #bytes } } }
    return set, entry
end

-- The directory of one patch slot, so the panel can see which entries our patch holds.
function M.patch_spec(ctx, host, name)
    local set, _, why = patch_set(ctx, host, name)
    if not set then return nil, why end
    return package_head(set, name)
end

-- The toc bytes of one entry inside our own patch.  An id is only as ambiguous as what we wrote, but
-- the rule stays the same as for a source package: a repeated id needs '<type>:<id>'.
function M.patch_entry(ctx, host, name, id_hex, type_hex)
    local set, _, why = patch_set(ctx, host, name)
    if not set then return nil, why end
    local spec, head_why = package_head(set, name)
    if not spec then return nil, head_why end
    local wanted = hex_key(id_hex)
    local wanted_type = type_hex ~= nil and hex_key(type_hex) or nil
    local hit, seen = nil, 0
    for _, item in ipairs(spec.entries) do
        if item.id_hex == wanted and (wanted_type == nil or item.type_hex == wanted_type) then
            hit = hit or item
            seen = seen + 1
        end
    end
    if seen == 0 then
        if wanted_type then return nil, '补丁中找不到这条资源：' .. type_hex .. ':' .. id_hex end
        return nil, '补丁中找不到这条资源：' .. tostring(id_hex)
    end
    if seen > 1 and wanted_type == nil then
        return nil, '资源编号 ' .. wanted .. ' 在补丁里出现多次，请用 类型:编号 指定'
    end
    return package_read(set, name, hit.toc_at, hit.toc_size)
end
M._internal.patch_name = patch_name
M._internal.used_numbers = used_numbers
M._internal.override_for = override_for
M._internal.trimmed_spec = trimmed_spec

-- Recover only edited TOC resources from our current patch. Read it once and
-- compare against source bytes; never turn an unreadable patch into an empty plan.
function M.saved_overrides(ctx, host, name)
    if not M.entry_of(ctx, host, name) then return {} end
    local held, _, why = patch_set(ctx, host, name)
    if not held then return nil, why end
    local spec, why = package_head(held, name)
    if not spec then return nil, why end
    local set, why = bundle_set(ctx)
    if not set then return nil, why end
    local source, why = package_head(set, name)
    if not source then return nil, why end
    local originals = {}
    for _, item in ipairs(source.entries) do originals[item.type_hex .. ':' .. item.id_hex] = item end
    local overrides = {}
    for _, item in ipairs(spec.entries) do
        local key = item.type_hex .. ':' .. item.id_hex
        local original = originals[key]
        if not original then return nil, '已安装补丁含有当前原包中不存在的资源：' .. key end
        local bytes, why = package_read(held, name, item.toc_at, item.toc_size)
        if not bytes then return nil, why end
        local baseline, why = package_read(set, name, original.toc_at, original.toc_size)
        if not baseline then return nil, why end
        if bytes ~= baseline then overrides[key] = bytes end
    end
    return overrides
end

function M.update_entry(ctx, host, name, mode, id, kind, bytes)
    local overrides, why = M.saved_overrides(ctx, host, name)
    if not overrides then return nil, why end
    overrides[hex_key(kind) .. ':' .. hex_key(id)] = bytes
    return M.install_with(ctx, host, name, mode, overrides)
end

function M.revert_entry(ctx, host, name, id, kind)
    local entry = M.entry_of(ctx, host, name)
    if not entry then return true end
    local overrides, why = M.saved_overrides(ctx, host, name)
    if not overrides then return nil, why end
    overrides[hex_key(kind) .. ':' .. hex_key(id)] = nil
    if entry.mode == 'res' and not next(overrides) then return M.remove(ctx, host, name) end
    return M.install_with(ctx, host, name, entry.mode, overrides)
end

return M
