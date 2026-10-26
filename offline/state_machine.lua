-- state_machine: read and rewrite the Stingray `state_machine` resource of a deployable turret.
--
-- An airdropped turret (AC-8, MLS-4X, M-12, MG-43, ...) lands folded and plays a deploy transition into
-- the unfolded pose.  Mounted as a vehicle attachment it never runs that deployment, so it sits on
-- whatever layer0.DefaultState points at and the folded model sinks inside the carrier.  Pointing
-- layer0's DefaultState at the deployed state is the whole fix; the sweep layer has to be pushed to its
-- Empty state as well, because its scan clip rewinds the pose while the turret is attached.
--
-- Layout follows xypwn/filediver `stingray/state_machine` (BSD-3), reimplemented in plain Lua 5.1:
-- 15 u32 header, a layer table at groups_off, per layer {Magic, DefaultState, StateCount, Offsets[]},
-- then each state {Name(u64), Type, anim hashes, weights, ..., Loop, Additive, animation events,
-- transition links, EmitEndEvent(u32), EndTransitionTime(f32), ...}.  No ffi and no struct library
-- here: u32/u64/f32 are decoded by hand from string.byte, and every read is bounds-checked, because a
-- truncated or foreign blob must come back as nil, why instead of throwing inside the editor.

local M = {}

M.TYPE = 'A486D4045106165C'

M.NAMES = {
    ['79DE1870039A1A7E'] = 'deploy_transition',
    ['D23167BF92D249B8'] = 'retract',
    ['330CA356421F7ADA'] = 'folded',
    ['823905BD6B62BA3E'] = 'deployed',
    ['E954AED4871D630A'] = 'idle_b',
    ['69484BEF5AC55426'] = 'mortar_deployed',
    ['86342D705E08AD12'] = 'empty',
    ['9EA750D5873EB183'] = 'sweep_idle',
}

M.EVENTS = {
    ['3D0B77D2'] = 'DeployDone',
    ['27A2636E'] = 'RetractDone',
    ['72C4271D'] = 'PackageDeploy',
    ['6F8B215F'] = 'PackageRetract',
    ['F5EACFD8'] = 'Fire',
    ['A4DD22E8'] = 'FireDone',
    ['247452BF'] = 'Deployed',
}

M.STATE_TYPES = { [0] = 'Clip', [1] = 'Empty', [2] = 'Blend', [3] = 'Time', [4] = 'Unknown', [5] = 'Ragdoll' }
M.LINK_TYPES = { [0] = 'Immediate', [1] = 'WaitEnd', [2] = 'SyncBeatClosest', [3] = 'WaitUntilBeat',
                 [4] = 'SyncPercentage', [5] = 'SyncInversePercentage' }

-- The two hashes the recipe looks for, plus the sweep pair.  Kept as plain strings: a hash is an id,
-- not a number, and adding it as a number would lose the high bits past 2^53.
local DEPLOYED, TRANSITION = '823905BD6B62BA3E', '79DE1870039A1A7E'
local SWEEP, EMPTY = '9EA750D5873EB183', '86342D705E08AD12'

local HEADER = { 'unk00', 'group_count', 'groups_off', 'event_hash_count', 'event_hash_off',
                 'var_count', 'var_map_off', 'opacity_count', 'opacity_off',
                 'unk0_count', 'unk0_off', 'unk1_count', 'unk1_off', 'unk2_count', 'unk2_off' }

-- ---------------------------------------------------------------- reading bytes

-- Every reader takes a 0-based offset and returns nil when the field is not fully inside the blob.
-- Callers turn that nil into one message instead of an arithmetic error.
local function u32(bytes, at)
    local a, b, c, d = bytes:byte(at + 1, at + 4)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function i32(bytes, at)
    local value = u32(bytes, at)
    if not value then return nil end
    if value >= 2147483648 then return value - 4294967296 end
    return value
end

-- IEEE-754 single, by hand: Lua 5.1 has no string.unpack and struct is not shipped with the game.
-- byte() hands back (lsb, ..., msb), so the sign/exponent byte is the fourth one.
local function f32(bytes, at)
    local a, b, c, d = bytes:byte(at + 1, at + 4)
    if not d then return nil end
    local sign = d >= 128 and -1 or 1
    local exponent = d % 128 * 2 + math.floor(c / 128)
    local mantissa = c % 128 * 65536 + b * 256 + a
    if exponent == 0 then
        if mantissa == 0 then return 0 end
        return sign * mantissa * 2 ^ -149
    end
    if exponent == 255 then
        if mantissa == 0 then return sign * math.huge end
        return 0                                  -- a NaN here is meaningless; show 0 instead of crashing
    end
    return sign * (mantissa + 8388608) * 2 ^ (exponent - 150)
end

local function hex32(value) return string.format('%08X', value % 4294967296) end
local function hex64(hi, lo) return string.format('%08X%08X', hi % 4294967296, lo % 4294967296) end
local function u32le(value)
    value = value % 4294967296
    return string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256,
                       math.floor(value / 16777216) % 256)
end

-- ---------------------------------------------------------------- states and layers

local function read_state(bytes, at, index)
    if at + 80 > #bytes then return nil, '状态数据越界' end
    local state = {
        index = index, at = at, name = hex64(u32(bytes, at + 4), u32(bytes, at)),
        type = u32(bytes, at + 8), anim_count = u32(bytes, at + 12), anims = {},
        loop = bytes:byte(at + 33) or 0, additive = bytes:byte(at + 37) or 0,
        emit = nil, end_t = f32(bytes, at + 76), links = {}, trans = {},
    }
    local anim_at = u32(bytes, at + 16)
    if state.anim_count > 0 and anim_at > 0 then
        if at + anim_at + state.anim_count * 8 > #bytes then return nil, '动画哈希表越界' end
        for k = 0, state.anim_count - 1 do
            local base = at + anim_at + k * 8
            state.anims[k + 1] = hex64(u32(bytes, base + 4), u32(bytes, base))
        end
    end
    local event_count, event_at = u32(bytes, at + 40), u32(bytes, at + 44)
    if event_count > 0 and event_at > 0 then
        if at + event_at + event_count * 8 > #bytes then return nil, '事件表越界' end
        for k = 0, event_count - 1 do
            local base = at + event_at + k * 8
            state.trans[hex32(u32(bytes, base))] = i32(bytes, base + 4)
        end
    end
    local link_count, link_at = u32(bytes, at + 48), u32(bytes, at + 52)
    if link_count > 0 and link_at > 0 then
        if at + link_at + link_count * 16 > #bytes then return nil, '过渡表越界' end
        for k = 0, link_count - 1 do
            local base = at + link_at + k * 16
            state.links[k + 1] = { index = u32(bytes, base), blend = f32(bytes, base + 4),
                                   type = u32(bytes, base + 8), beat = u32(bytes, base + 12) }
        end
    end
    local emit = u32(bytes, at + 72)
    if emit and emit ~= 0 then state.emit = hex32(emit) end
    return state
end

local function read_layer(bytes, base, index)
    if base + 12 > #bytes then return nil, '层头部越界' end
    local count = u32(bytes, base + 8)
    if base + 12 + count * 4 > #bytes then return nil, '状态偏移表越界' end
    local layer = { index = index, at = base, magic = u32(bytes, base), default = u32(bytes, base + 4),
                    default_at = base + 4, states = {} }
    for j = 0, count - 1 do
        local state, why = read_state(bytes, base + u32(bytes, base + 12 + j * 4), j)
        if not state then return nil, string.format('状态 %d：%s', j, why) end
        layer.states[j + 1] = state
    end
    return layer
end

-- ---------------------------------------------------------------- parse

function M.parse(bytes)
    if type(bytes) ~= 'string' then return nil, 'state_machine 数据不是字符串' end
    if #bytes < 60 then return nil, string.format('数据只有 %d 字节，连头部都不完整', #bytes) end
    local header = {}
    for i = 1, 15 do header[HEADER[i]] = u32(bytes, (i - 1) * 4) end
    local events = {}
    if header.event_hash_count > 0 and header.event_hash_off > 0 then
        if header.event_hash_off + header.event_hash_count * 4 > #bytes then return nil, '事件哈希表越界' end
        for i = 0, header.event_hash_count - 1 do
            events[i + 1] = hex32(u32(bytes, header.event_hash_off + i * 4))
        end
    end
    local layers = {}
    -- group_count gates the layer table the same way filediver does; some blobs carry groups_off = 0.
    if header.group_count > 0 and header.groups_off > 0 then
        local groups = header.groups_off
        local count = u32(bytes, groups)
        if not count then return nil, string.format('层表越界（groups_off=%d）', groups) end
        if groups + 4 + count * 4 > #bytes then return nil, '层偏移表越界' end
        for i = 0, count - 1 do
            local layer, why = read_layer(bytes, groups + u32(bytes, groups + 4 + i * 4), i)
            if not layer then return nil, string.format('层 %d：%s', i, why) end
            layers[i + 1] = layer
        end
    end
    return { size = #bytes, header = header, events = events, layers = layers }
end

-- ---------------------------------------------------------------- recipe

local function find_state(layer, name)
    for _, state in ipairs(layer.states) do
        if state.name == name then return state end
    end
end

local function find_layer(sm, index)
    for _, layer in ipairs(sm.layers) do
        if layer.index == index then return layer end
    end
end

-- Pure: reads sm, never touches bytes.  One change for layer0 (which state the turret shows at rest)
-- and one for a sweep layer, which is what the recipe table in the field notes describes.
function M.recipe(sm)
    if type(sm) ~= 'table' or type(sm.layers) ~= 'table' then return nil, '没有可用的解析结果' end
    local plan = { changes = {}, count = 0, template = 'none', warn = nil, notes = {} }
    local layer0 = find_layer(sm, 0)
    local target, why
    if not layer0 then
        plan.notes[#plan.notes + 1] = '没有层0，保持原样'
    elseif #layer0.states < 2 then
        plan.notes[#plan.notes + 1] = '层0 的状态少于两个，保持原样'
    else
        local open, transition = find_state(layer0, DEPLOYED), find_state(layer0, TRANSITION)
        if open then
            plan.template, target, why = 'A', open.index, 'deployed_open'
            plan.notes[#plan.notes + 1] = '模板A：层0 直接指向部署完成态，出场即展开'
        elseif transition then
            plan.template, target, why = 'B', transition.index, 'deploy_transition'
            plan.notes[#plan.notes + 1] = '模板B：层0 指向部署过渡（loop=0 且无出口），引擎会停在过渡末帧'
        else
            plan.notes[#plan.notes + 1] = '层0 既没有部署完成态也没有部署过渡态，保持原样'
        end
    end
    if target then
        if layer0.default == target then
            plan.notes[#plan.notes + 1] = string.format('层0 的默认态已经是 %d，不用改', target)
        else
            plan.changes[1] = { layer = 0, from = layer0.default, to = target, why = why }
        end
    end
    for _, layer in ipairs(sm.layers) do
        if layer.index ~= 0 and #layer.states >= 2 then
            local sweep, empty = find_state(layer, SWEEP), find_state(layer, EMPTY)
            if sweep and empty and layer.default ~= empty.index then
                plan.changes[#plan.changes + 1] = { layer = layer.index, from = layer.default,
                                                    to = empty.index, why = 'sweep_off' }
                plan.notes[#plan.notes + 1] = string.format(
                    '层%d 的扫视 clip 挂载时会让姿态回卷，已切到 Empty', layer.index)
            end
        end
    end
    plan.count = #plan.changes
    -- The recipe table only ever produces one or two changes; more means the blob is not what we think.
    if plan.count > 2 then plan.warn = '改动超过 2 处，请复核' end
    if plan.count == 0 then plan.notes[#plan.notes + 1] = '没有需要改动的地方' end
    return plan
end

-- ---------------------------------------------------------------- apply

-- Writes plan.changes[i].to over the four bytes at that layer's DefaultState, then re-reads the result:
-- every change must be visible, and no byte outside those windows may differ.  Anything else is nil, why
-- and the caller keeps the original blob.
function M.apply(bytes, plan)
    if type(bytes) ~= 'string' then return nil, 'state_machine 数据不是字符串' end
    if type(plan) ~= 'table' or type(plan.changes) ~= 'table' then return nil, '缺少改动计划' end
    local sm, why = M.parse(bytes)
    if not sm then return nil, why end
    local edits, taken = {}, {}
    for i, change in ipairs(plan.changes) do
        if type(change) ~= 'table' or type(change.to) ~= 'number' then
            return nil, string.format('改动计划第 %d 条不完整', i)
        end
        if change.to ~= math.floor(change.to) or change.to < 0 then
            return nil, string.format('改动计划第 %d 条的目标不是合法索引', i)
        end
        local layer = find_layer(sm, change.layer)
        if not layer then return nil, string.format('改动计划指向不存在的层 %s', tostring(change.layer)) end
        if change.to > #layer.states - 1 then
            return nil, string.format('层%d 只有 %d 个状态，索引 %d 越界', layer.index, #layer.states, change.to)
        end
        if layer.default ~= change.from then
            return nil, string.format('层%d 的默认态是 %d，与计划里的 %s 不符', layer.index, layer.default,
                                      tostring(change.from))
        end
        if taken[layer.default_at] then return nil, string.format('改动计划里层%d 出现了两次', layer.index) end
        taken[layer.default_at] = true
        edits[#edits + 1] = { at = layer.default_at, layer = layer.index, to = change.to }
    end
    if #edits == 0 then return bytes end
    table.sort(edits, function(a, b) return a.at < b.at end)
    local parts, cursor = {}, 1
    for _, edit in ipairs(edits) do
        parts[#parts + 1] = bytes:sub(cursor, edit.at)
        parts[#parts + 1] = u32le(edit.to)
        cursor = edit.at + 5
    end
    parts[#parts + 1] = bytes:sub(cursor)
    local out = table.concat(parts)
    if #out ~= #bytes then return nil, '改动后长度发生了变化' end
    local after, after_why = M.parse(out)
    if not after then return nil, '改动后无法解析：' .. tostring(after_why) end
    for _, edit in ipairs(edits) do
        local layer = find_layer(after, edit.layer)
        if not layer or layer.default ~= edit.to then
            return nil, string.format('层%d 的默认态没有落地', edit.layer)
        end
        if out:sub(edit.at + 1, edit.at + 4) ~= u32le(edit.to) then
            return nil, string.format('层%d 的默认态字节不符', edit.layer)
        end
    end
    local touched = {}
    for _, edit in ipairs(edits) do
        for k = 0, 3 do touched[edit.at + k] = true end
    end
    for i = 1, #bytes do
        if bytes:byte(i) ~= out:byte(i) and not touched[i - 1] then
            return nil, string.format('第 %d 字节被意外改写', i - 1)
        end
    end
    return out
end

-- ---------------------------------------------------------------- preview

local REASON = {
    deployed_open = '部署完成态',
    deploy_transition = '部署过渡（停在展开末帧）',
    sweep_off = '扫视层切到 Empty',
}

function M.preview(sm, plan)
    local lines = {}
    if type(plan) ~= 'table' or type(plan.changes) ~= 'table' then return lines end
    for _, change in ipairs(plan.changes) do
        lines[#lines + 1] = string.format('层%d：%d → %d（%s）', change.layer, change.from, change.to,
                                          REASON[change.why] or tostring(change.why))
    end
    if #lines == 0 then
        if plan.template == 'none' then
            lines[1] = '层0 没有部署状态可选：不改动'
        else
            lines[1] = '无需改动：层0 的默认态已经是展开态'
        end
    end
    return lines
end

return M
