---@omw-context global | player | none

local constants = require("scripts.beamfx.shared.constants")

local space = {}

local function guardedField(object, key)
    if object == nil then
        return nil, false
    end
    local ok, value = pcall(function()
        return object[key]
    end)
    if not ok then
        return nil, false
    end
    return value, true
end

local function opaqueId(value)
    if type(value) == "string"
        and value ~= ""
        and value:find("[%z\1-\31\127]") == nil
    then
        return value
    end
    return nil
end

local function exteriorFlag(cell)
    local value, readable = guardedField(cell, "isExterior")
    if not readable then
        return nil
    end
    if type(value) == "function" then
        local ok, result = pcall(value, cell)
        if not ok then
            return nil
        end
        value = result
    end
    if type(value) ~= "boolean" then
        return nil
    end
    return value
end

function space.isValidKey(value)
    if type(value) ~= "string"
        or value == ""
        or #value > constants.MAX_SPACE_KEY_LENGTH
        or value:find("[%z\1-\31\127]") ~= nil
    then
        return false
    end

    local interior_prefix = "interior:"
    local exterior_prefix = "exterior:"
    if value:sub(1, #interior_prefix) == interior_prefix then
        return #value > #interior_prefix
    end
    if value:sub(1, #exterior_prefix) == exterior_prefix then
        return #value > #exterior_prefix
    end
    return false
end

function space.normalizeKey(value)
    if not space.isValidKey(value) then
        return nil, "invalid_space_key"
    end
    return value
end

function space.spaceKeyForCell(cell)
    local is_exterior = exteriorFlag(cell)
    if is_exterior == nil then
        return nil, "invalid_space_key"
    end

    local id = nil
    if is_exterior then
        local world_space_id = guardedField(cell, "worldSpaceId")
        id = opaqueId(world_space_id)
        if id == nil then
            local cell_id = guardedField(cell, "id")
            id = opaqueId(cell_id)
        end
        if id ~= nil then
            return space.normalizeKey("exterior:" .. id)
        end
    else
        local cell_id = guardedField(cell, "id")
        id = opaqueId(cell_id)
        if id ~= nil then
            return space.normalizeKey("interior:" .. id)
        end
    end

    return nil, "invalid_space_key"
end

space.forCell = space.spaceKeyForCell

return space
