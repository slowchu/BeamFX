---@omw-context player | none

local constants = require("scripts.beamfx.shared.constants")

local scheduler = {}

local PRIORITY_RANK = {
    low = 0,
    normal = 1,
    high = 2,
}

function scheduler.new()
    return {
        cursorKey = nil,
        cycleActive = false,
        cycleNumber = 0,
        cycleMembers = {},
        unserved = {},
    }
end

function scheduler.reset(state)
    state.cursorKey = nil
    state.cycleActive = false
    state.cycleNumber = 0
    state.cycleMembers = {}
    state.unserved = {}
end

local function candidateLess(left, right)
    local left_priority = PRIORITY_RANK[left.priority] or PRIORITY_RANK.normal
    local right_priority = PRIORITY_RANK[right.priority] or PRIORITY_RANK.normal
    if left_priority ~= right_priority then
        return left_priority > right_priority
    end
    if left.viewportPriority ~= right.viewportPriority then
        return left.viewportPriority < right.viewportPriority
    end
    if left.distanceSquared ~= right.distanceSquared then
        return left.distanceSquared < right.distanceSquared
    end
    local left_freshness = tonumber(left.freshness) or 0
    local right_freshness = tonumber(right.freshness) or 0
    if left_freshness ~= right_freshness then
        return left_freshness > right_freshness
    end
    if left.compositeKey ~= right.compositeKey then
        return left.compositeKey < right.compositeKey
    end
    return left.order < right.order
end

local function groupedCandidates(candidates)
    local groups = {}
    local keys = {}
    for _, candidate in ipairs(candidates or {}) do
        local producer_key = tostring(candidate.producerKey or "")
        if producer_key ~= "" then
            local group = groups[producer_key]
            if group == nil then
                group = {
                    key = producer_key,
                    candidates = {},
                    nextIndex = 1,
                }
                groups[producer_key] = group
                keys[#keys + 1] = producer_key
            end
            group.candidates[#group.candidates + 1] = candidate
        end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        table.sort(groups[key].candidates, candidateLess)
    end
    return groups, keys
end

local function firstIndex(keys, cursor_key)
    if #keys == 0 or cursor_key == nil then
        return 1
    end
    for index, key in ipairs(keys) do
        if key >= cursor_key then
            return index
        end
    end
    return 1
end

local function nextMatching(keys, start_index, predicate)
    for offset = 0, #keys - 1 do
        local index = ((start_index + offset - 1) % #keys) + 1
        local key = keys[index]
        if predicate(key) then
            return key, index
        end
    end
    return nil
end

local function successor(keys, index)
    if #keys == 0 then
        return nil
    end
    return keys[(index % #keys) + 1]
end

local function reconcileCycle(state, groups, keys)
    local eligible = {}
    for _, key in ipairs(keys) do
        eligible[key] = true
    end
    for key in pairs(state.cycleMembers) do
        if not eligible[key] then
            state.cycleMembers[key] = nil
            state.unserved[key] = nil
        end
    end

    if not state.cycleActive then
        state.cycleNumber = state.cycleNumber + 1
        state.cycleActive = true
        state.cycleMembers = {}
        state.unserved = {}
    end
    for _, key in ipairs(keys) do
        if groups[key] ~= nil and not state.cycleMembers[key] then
            state.cycleMembers[key] = true
            state.unserved[key] = true
        end
    end
end

local function hasUnserved(state)
    return next(state.unserved) ~= nil
end

function scheduler.select(candidates, requested_capacity, state)
    local schedule_state = state or scheduler.new()
    local capacity = math.max(
        0,
        math.min(
            constants.SEGMENT_CAPACITY,
            math.floor(tonumber(requested_capacity) or constants.SEGMENT_CAPACITY)
        )
    )
    if capacity == 0 then
        return {}, {
            eligibleProducers = 0,
            eligibleSegments = #(candidates or {}),
            selectedSegments = 0,
            cycleNumber = schedule_state.cycleNumber,
        }
    end

    local groups, keys = groupedCandidates(candidates)
    if #keys == 0 then
        schedule_state.cycleActive = false
        schedule_state.cycleMembers = {}
        schedule_state.unserved = {}
        return {}, {
            eligibleProducers = 0,
            eligibleSegments = 0,
            selectedSegments = 0,
            cycleNumber = schedule_state.cycleNumber,
        }
    end

    reconcileCycle(schedule_state, groups, keys)
    local selected = {}
    local cursor_index = firstIndex(keys, schedule_state.cursorKey)

    -- Mandatory one-segment service quantum. This phase persists across frames
    -- and is the source of the ceil(P / 64) service bound.
    while #selected < capacity and hasUnserved(schedule_state) do
        local key, index = nextMatching(keys, cursor_index, function(candidate_key)
            local group = groups[candidate_key]
            return schedule_state.unserved[candidate_key] == true
                and group ~= nil
                and group.nextIndex <= #group.candidates
        end)
        if key == nil then
            break
        end
        local group = groups[key]
        selected[#selected + 1] = group.candidates[group.nextIndex]
        group.nextIndex = group.nextIndex + 1
        schedule_state.unserved[key] = nil
        schedule_state.cursorKey = successor(keys, index)
        cursor_index = firstIndex(keys, schedule_state.cursorKey)
    end

    local completed_cycle = not hasUnserved(schedule_state)
    if completed_cycle then
        schedule_state.cycleActive = false
    end

    -- Only after every eligible producer has received its mandatory quantum
    -- may unused slots be redistributed for continuity and utilization.
    if completed_cycle then
        local redistribution_index = firstIndex(keys, schedule_state.cursorKey)
        while #selected < capacity do
            local key, index = nextMatching(keys, redistribution_index, function(candidate_key)
                local group = groups[candidate_key]
                return group ~= nil and group.nextIndex <= #group.candidates
            end)
            if key == nil then
                break
            end
            local group = groups[key]
            selected[#selected + 1] = group.candidates[group.nextIndex]
            group.nextIndex = group.nextIndex + 1
            redistribution_index = (index % #keys) + 1
        end
    end

    return selected, {
        eligibleProducers = #keys,
        eligibleSegments = #(candidates or {}),
        selectedSegments = #selected,
        cycleNumber = schedule_state.cycleNumber,
        cycleComplete = completed_cycle,
        unservedProducers = (function()
            local count = 0
            for _ in pairs(schedule_state.unserved) do
                count = count + 1
            end
            return count
        end)(),
    }
end

function scheduler.serviceWindowFrames(producer_count)
    local count = math.max(0, math.floor(tonumber(producer_count) or 0))
    if count == 0 then
        return 0
    end
    return math.ceil(count / constants.SEGMENT_CAPACITY)
end

return scheduler
