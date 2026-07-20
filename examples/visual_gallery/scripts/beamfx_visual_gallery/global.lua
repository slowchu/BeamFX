---@omw-context global

local core = require("openmw.core")
local I = require("openmw.interfaces")
local world = require("openmw.world")

local shared = require("scripts.beamfx_visual_gallery.shared")

local PROVIDER_CHECK_INTERVAL = 0.5

local state = {
    actor = nil,
    active = false,
    paused = false,
    config = shared.defaultConfig(),
    producer = nil,
    providerEpoch = nil,
    spaceKey = nil,
    points = nil,
    pathLength = 0,
    phaseOffset = 0,
    phaseUpdatedAt = nil,
    appliedSpeed = 0,
    lastProviderCheckAt = nil,
    lastWarning = nil,
}

local function finite(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function xyz(value)
    if value == nil then
        return nil
    end
    local ok_x, x = pcall(function()
        return value.x
    end)
    local ok_y, y = pcall(function()
        return value.y
    end)
    local ok_z, z = pcall(function()
        return value.z
    end)
    if not ok_x
        or not ok_y
        or not ok_z
        or not finite(x)
        or not finite(y)
        or not finite(z)
    then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function isPlayer(actor)
    if actor == nil or world.players == nil then
        return false
    end
    for index = 1, #world.players do
        local ok, candidate = pcall(function()
            return world.players[index]
        end)
        if ok and candidate == actor then
            return true
        end
    end
    return false
end

local function actorCell(actor)
    local ok, cell = pcall(function()
        return actor.cell
    end)
    if ok then
        return cell
    end
    return nil
end

local function facingBasis(actor)
    local ok_yaw, yaw = pcall(function()
        return actor.rotation:getYaw()
    end)
    if not ok_yaw or not finite(yaw) then
        yaw = 0
    end
    local forward = {
        x = math.sin(yaw),
        y = math.cos(yaw),
        z = 0,
    }
    return forward, {
        x = forward.y,
        y = -forward.x,
        z = 0,
    }
end

local function relativePoint(origin, forward, right, ahead, lateral, up)
    return {
        x = origin.x + forward.x * ahead + right.x * lateral,
        y = origin.y + forward.y * ahead + right.y * lateral,
        z = origin.z + up,
    }
end

local function distance(left, right)
    local x = right.x - left.x
    local y = right.y - left.y
    local z = right.z - left.z
    return math.sqrt(x * x + y * y + z * z)
end

local function pathLength(points)
    local result = 0
    for index = 2, #points do
        result = result + distance(points[index - 1], points[index])
    end
    return result
end

local function provider()
    -- The gallery is an independent consumer data root. It deliberately uses
    -- only BeamFX's runtime public interface.
    ---@diagnostic disable-next-line: undefined-field
    local api = I.BeamFX
    if api == nil
        or api.apiMajor ~= shared.API_MAJOR
        or type(api.apiMinor) ~= "number"
        or api.apiMinor < shared.API_MINOR
    then
        return nil, "BeamFX API 1.3 or newer is unavailable"
    end
    if type(api.providerEpoch) ~= "function"
        or type(api.registerProducer) ~= "function"
        or type(api.spaceKeyForCell) ~= "function"
    then
        return nil, "BeamFX public interface is incomplete"
    end
    return api
end

local function sendStatus(ok, code, detail)
    local actor = state.actor
    if not isPlayer(actor) then
        return
    end
    local payload = {
        ok = ok == true,
        code = tostring(code or (ok and "ready" or "unknown_error")),
        active = state.active,
        paused = state.paused,
    }
    if type(detail) == "table" then
        if type(detail.path) == "string" then
            payload.path = detail.path
        end
        if type(detail.reason) == "string" then
            payload.reason = detail.reason
        end
        if type(detail.message) == "string" then
            payload.message = detail.message
        end
    elseif type(detail) == "string" then
        payload.message = detail
    end
    local ok_send, err = pcall(function()
        actor:sendEvent(shared.EVENT_STATUS, payload)
    end)
    if not ok_send then
        print(
            "[BeamFX visual gallery] status event failed: "
                .. tostring(err)
        )
    end
end

local function warnOnce(message)
    local text = tostring(message)
    if state.lastWarning == text then
        return
    end
    state.lastWarning = text
    print("[BeamFX visual gallery] " .. text)
end

local function discardProducer()
    state.producer = nil
    state.providerEpoch = nil
end

local function acquireProducer()
    local api, provider_error = provider()
    if api == nil then
        discardProducer()
        warnOnce(provider_error)
        return nil, "unsupported_api", {
            path = "I.BeamFX.apiMinor",
            reason = "requires_api_1_3",
            message = provider_error,
        }
    end

    local epoch = api.providerEpoch()
    if state.producer ~= nil and state.providerEpoch == epoch then
        return state.producer
    end

    discardProducer()
    local producer, err, detail = api.registerProducer({
        id = shared.PRODUCER_ID,
        displayName = "BeamFX visual gallery",
        apiMajor = shared.API_MAJOR,
        apiMinor = shared.API_MINOR,
    })
    if producer == nil then
        warnOnce("producer registration failed: " .. tostring(err))
        return nil, err, detail
    end
    if type(producer.upsertPath) ~= "function" then
        pcall(function()
            producer:release("gallery_requires_upsert_path")
        end)
        return nil, "unsupported_api", {
            path = "producer.upsertPath",
            reason = "missing_method",
            message = "BeamFX API 1.3 path helper is unavailable",
        }
    end

    state.producer = producer
    state.providerEpoch = epoch
    state.lastWarning = nil
    return producer
end

local function invoke(method, ...)
    local producer, acquire_error, acquire_detail = acquireProducer()
    if producer == nil then
        return nil, acquire_error, acquire_detail
    end
    local operation = producer[method]
    if type(operation) ~= "function" then
        return nil, "unsupported_api", {
            path = "producer." .. tostring(method),
            reason = "missing_method",
            message = "Required BeamFX producer method is unavailable",
        }
    end

    local result, err, detail = operation(producer, ...)
    if err ~= "stale_producer" and err ~= "provider_reset" then
        return result, err, detail
    end

    discardProducer()
    producer, acquire_error, acquire_detail = acquireProducer()
    if producer == nil then
        return nil, acquire_error, acquire_detail
    end
    operation = producer[method]
    if type(operation) ~= "function" then
        return nil, "unsupported_api", {
            path = "producer." .. tostring(method),
            reason = "missing_method",
            message = "Required BeamFX producer method is unavailable",
        }
    end
    return operation(producer, ...)
end

local function settlePhase(now)
    if state.phaseUpdatedAt ~= nil and state.appliedSpeed ~= 0 then
        state.phaseOffset = state.phaseOffset
            - state.appliedSpeed * math.max(0, now - state.phaseUpdatedAt)
        if state.phaseOffset > 1000000 or state.phaseOffset < -1000000 then
            state.phaseOffset = state.phaseOffset % 100000
        end
    end
    state.phaseUpdatedAt = now
end

local function configuredSpeed(config)
    if state.paused then
        return 0
    end
    if config.longitudinalMode == "travel" then
        return 90
    end
    if config.longitudinalMode == "pulse" then
        return 70
    end
    if config.longitudinalMode == "dash" then
        return 45
    end
    return 0
end

local function longitudinal(config)
    local speed = configuredSpeed(config)
    local result = {
        mode = config.longitudinalMode,
        pathOffset = state.phaseOffset,
    }
    if config.longitudinalMode == "travel" then
        result.visibleLength = 55
        result.speed = speed
        if speed == 0 then
            -- travel requires a nonzero speed, so use a nearly stationary
            -- window while the gallery is paused.
            result.speed = 0.000001
        end
        result.headFadeLength = 8
        result.tailFadeLength = 14
        result.loop = true
        result.loopLength = math.max(0.01, state.pathLength)
        result.loopDelay = 0.15
    elseif config.longitudinalMode == "pulse" then
        result.period = 48
        result.pulseLength = 18
        result.speed = speed
        result.carrierLevel = 0.20
        result.fadeLength = 3
    elseif config.longitudinalMode == "dash" then
        result.dashLength = 24
        result.gapLength = 12
        result.speed = speed
        result.fadeLength = 2
    end
    return result, speed
end

local function captureAnchor(actor)
    local position = xyz(actor and actor.position)
    local cell = actorCell(actor)
    if position == nil or cell == nil then
        return nil, "Player position or Cell is unavailable"
    end
    local api, provider_error = provider()
    if api == nil then
        return nil, provider_error
    end
    local space_key, space_error = api.spaceKeyForCell(cell)
    if type(space_key) ~= "string" then
        return nil, "Unable to resolve player Cell: " .. tostring(space_error)
    end

    local forward, right = facingBasis(actor)
    local points = {
        relativePoint(position, forward, right, 145, -105, 120),
        relativePoint(position, forward, right, 205, -45, 155),
        relativePoint(position, forward, right, 275, 35, 115),
        relativePoint(position, forward, right, 345, 110, 150),
    }
    state.spaceKey = space_key
    state.points = points
    state.pathLength = pathLength(points)
    return true
end

local function pathSpec()
    local config = state.config
    local pattern, speed = longitudinal(config)
    local spec = {
        spaceKey = state.spaceKey,
        lifecycle = { mode = "persistent" },
        audience = { mode = "same_space" },
        priority = "normal",
        maxSegments = math.max(1, #state.points - 1),
        points = state.points,
        preset = config.preset,
        radius = config.radius,
        intensity = config.intensity,
        minPixelWidth = config.minPixelWidth,
        startFadeLength = config.startFadeLength,
        endFadeLength = config.endFadeLength,
        longitudinal = pattern,
    }
    if config.styleOverride then
        spec.style = config.style
        spec.styleScale = shared.STYLE_SCALES[config.style] or 0
    end
    if config.taper == "pointed_end" then
        spec.startRadius = config.radius
        spec.endRadius = 0
    elseif config.taper == "pointed_start" then
        spec.startRadius = 0
        spec.endRadius = config.radius
    elseif config.taper == "narrow_end" then
        local minimum_radius = config.style == "filament" and 0.1 or 0.25
        spec.startRadius = config.radius
        spec.endRadius = math.max(minimum_radius, config.radius * 0.25)
    end
    return spec, speed
end

local function publish(reason)
    if not state.active then
        return nil, "gallery_inactive"
    end
    if state.points == nil or state.spaceKey == nil then
        local anchored, anchor_error = captureAnchor(state.actor)
        if anchored == nil then
            sendStatus(false, "invalid_space_key", anchor_error)
            return nil, "invalid_space_key"
        end
    end

    local now = core.getSimulationTime()
    settlePhase(now)
    local spec, speed = pathSpec()
    local result, err, detail = invoke(
        "upsertPath",
        shared.BEAM_ID,
        spec
    )
    if result == nil then
        sendStatus(false, err, detail)
        warnOnce(
            "preview update failed"
                .. (reason and " (" .. tostring(reason) .. ")" or "")
                .. ": "
                .. tostring(err)
                .. (detail and " at " .. tostring(detail.path) or "")
        )
        return nil, err, detail
    end
    state.appliedSpeed = speed
    state.phaseUpdatedAt = now
    state.lastWarning = nil
    sendStatus(true, state.paused and "paused" or "ready")
    return result
end

local function clearPreview(reason)
    if state.producer ~= nil then
        local _, err = invoke("clear", reason or "gallery_clear")
        if err ~= nil and err ~= "stale_producer" then
            warnOnce("preview clear failed: " .. tostring(err))
        end
    end
    state.points = nil
    state.spaceKey = nil
    state.phaseOffset = 0
    state.phaseUpdatedAt = nil
    state.appliedSpeed = 0
end

local function setConfig(raw, reset_phase)
    local next_config = shared.normalizeConfig(raw)
    local now = core.getSimulationTime()
    settlePhase(now)
    if reset_phase
        or next_config.longitudinalMode
            ~= state.config.longitudinalMode
    then
        state.phaseOffset = 0
    end
    state.config = next_config
end

local function start(actor, config)
    state.actor = actor
    state.active = true
    state.paused = false
    setConfig(config, true)
    local anchored, anchor_error = captureAnchor(actor)
    if anchored == nil then
        sendStatus(false, "invalid_space_key", anchor_error)
        return
    end
    publish("start")
end

local function reposition()
    local anchored, anchor_error = captureAnchor(state.actor)
    if anchored == nil then
        sendStatus(false, "invalid_space_key", anchor_error)
        return
    end
    publish("reposition")
end

local function printRecipes()
    local concise = shared.conciseRecipe(state.config)
    local expanded = shared.expandedRecipe(state.config)
    print("[BeamFX visual gallery] Copy-ready concise recipe:\n" .. concise)
    print("[BeamFX visual gallery] Resolved appearance:\n" .. expanded)
    sendStatus(true, "printed", {
        message = "Both recipes were written to openmw.log",
    })
end

local function stop(reason)
    clearPreview(reason or "gallery_stop")
    state.active = false
    state.paused = false
    sendStatus(true, "stopped")
end

local function handleCommand(payload)
    if type(payload) ~= "table" or not isPlayer(payload.actor) then
        return
    end
    local command = payload.command
    if command == "start" then
        start(payload.actor, payload.config)
        return
    end
    if payload.actor ~= state.actor then
        return
    end
    if command == "stop" then
        stop("gallery_closed")
    elseif command == "update" and state.active then
        setConfig(payload.config, false)
        publish("control")
    elseif command == "reposition" and state.active then
        reposition()
    elseif command == "pause" and state.active then
        local now = core.getSimulationTime()
        settlePhase(now)
        state.paused = payload.paused == true
        publish("pause")
    elseif command == "reset" and state.active then
        state.paused = false
        setConfig(payload.config, true)
        publish("reset")
    elseif command == "print" and state.active then
        printRecipes()
    end
end

local function onUpdate()
    if not state.active or not isPlayer(state.actor) then
        return
    end
    local now = core.getSimulationTime()
    if state.lastProviderCheckAt ~= nil
        and now - state.lastProviderCheckAt < PROVIDER_CHECK_INTERVAL
    then
        return
    end
    state.lastProviderCheckAt = now

    local api = provider()
    if api == nil then
        acquireProducer()
        sendStatus(false, "unsupported_api", {
            path = "I.BeamFX.apiMinor",
            reason = "requires_api_1_3",
            message = "BeamFX API 1.3 or newer is unavailable",
        })
        return
    end

    local current_epoch = api.providerEpoch()
    if state.providerEpoch ~= current_epoch or state.producer == nil then
        discardProducer()
        publish("provider_reset")
        return
    end

    local cell = actorCell(state.actor)
    local space_key = cell and api.spaceKeyForCell(cell) or nil
    if type(space_key) == "string" and space_key ~= state.spaceKey then
        reposition()
    end
end

local function resetRuntime()
    if state.producer ~= nil
        and type(state.producer.release) == "function"
    then
        pcall(function()
            state.producer:release("gallery_runtime_reset")
        end)
    end
    state.points = nil
    state.spaceKey = nil
    state.phaseOffset = 0
    state.phaseUpdatedAt = nil
    state.appliedSpeed = 0
    state.actor = nil
    state.active = false
    state.paused = false
    state.config = shared.defaultConfig()
    state.lastProviderCheckAt = nil
    discardProducer()
end

return {
    eventHandlers = {
        [shared.EVENT_COMMAND] = handleCommand,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad = resetRuntime,
        onNewGame = resetRuntime,
    },
}
