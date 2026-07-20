local core = require("openmw.core")
local self = require("openmw.self")

local events = require("scripts.example_beam_consumer.events")

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function copyPosition(value)
    if value == nil then
        return nil
    end
    local okX, x = pcall(function()
        return value.x
    end)
    local okY, y = pcall(function()
        return value.y
    end)
    local okZ, z = pcall(function()
        return value.z
    end)
    if not okX
        or not okY
        or not okZ
        or not finiteNumber(x)
        or not finiteNumber(y)
        or not finiteNumber(z)
    then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function showFrost(from, to)
    local safeFrom = copyPosition(from)
    local safeTo = copyPosition(to)
    if safeFrom == nil or safeTo == nil then
        return false
    end

    -- The payload contains only serializable positions and an object
    -- reference. In particular, it does not send the player's Cell.
    core.sendGlobalEvent(events.SHOW_FROST, {
        sender = self.object,
        from = safeFrom,
        to = safeTo,
    })
    return true
end

return {
    -- Other player scripts in this mod can call:
    -- I.ExampleAuthorBeamVisuals.showFrost(startPos, endPos)
    interfaceName = "ExampleAuthorBeamVisuals",
    interface = {
        showFrost = showFrost,
    },
}
