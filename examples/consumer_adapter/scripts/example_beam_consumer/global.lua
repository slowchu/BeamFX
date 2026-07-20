local world = require("openmw.world")

local BeamFXAdapter =
    require("scripts.example_beam_consumer.beamfx_adapter")
local events = require("scripts.example_beam_consumer.events")

-- Replace this example table with your mod's real gameplay registry. BeamFX
-- deliberately does not save or reconstruct another mod's gameplay state.
local authoritativePersistentEffects = {}

local visuals

local function reconstructPersistentVisuals(adapter, reason)
    -- Rebuild only effects that are still true in authoritative gameplay
    -- state. Do not blindly replay expired transient effects after a load.
    for localBeamId, effect in pairs(authoritativePersistentEffects) do
        local result, err = adapter:invoke(
            "upsert",
            localBeamId,
            effect.beamSpec
        )
        if result == nil then
            return false, err
        end
    end
    return true
end

visuals = BeamFXAdapter.new({
    -- Change both values before shipping your mod.
    producerId = "example.author.easy_beams",
    displayName = "Example Author - Easy Beams",

    -- This callback runs after initial registration and after every provider
    -- epoch change. It may safely call adapter:invoke(...).
    reconstruct = reconstructPersistentVisuals,

    retryMinimumSeconds = 0.25,
    retryMaximumSeconds = 5,
    warningIntervalSeconds = 30,
})

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function validPosition(value)
    return type(value) == "table"
        and finiteNumber(value.x)
        and finiteNumber(value.y)
        and finiteNumber(value.z)
end

local function isPlayer(object)
    if object == nil then
        return false
    end
    local players = world.players
    local ok, count = pcall(function()
        return #players
    end)
    if not ok then
        return false
    end
    for index = 1, count do
        local readOk, player = pcall(function()
            return players[index]
        end)
        if readOk and player == object then
            return true
        end
    end
    return false
end

local function objectCell(object)
    local ok, cell = pcall(function()
        return object.cell
    end)
    if not ok then
        return nil
    end
    return cell
end

local function onShowFrost(request)
    if type(request) ~= "table"
        or not isPlayer(request.sender)
        or not validPosition(request.from)
        or not validPosition(request.to)
    then
        return
    end

    local cell = objectCell(request.sender)
    if cell == nil then
        return
    end

    -- BeamFX API 1.3 resolves the Cell immediately, generates a collision-safe
    -- beam ID, builds one segment, and supplies transient fade defaults.
    -- API 1.2 receives an automatic transient-upsert fallback from the adapter.
    local beamId, err, errorDetail = visuals:emit({
        cell = cell,
        from = request.from,
        to = request.to,
        preset = "frost",
        radius = 6,
        duration = 0.25,
    })

    -- This is visual-only best effort. Your spell, hit, cooldown, resource
    -- use, or other gameplay result must not depend on beamId being non-nil.
    if beamId == nil then
        return
    end
end

local function onUpdate()
    visuals:update()
end

local function onLoad()
    -- Load your authoritative gameplay state before or alongside this call.
    visuals:reset("load")
end

local function onNewGame()
    authoritativePersistentEffects = {}
    visuals:reset("new_game")
end

return {
    eventHandlers = {
        [events.SHOW_FROST] = onShowFrost,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad = onLoad,
        onNewGame = onNewGame,
    },
}
