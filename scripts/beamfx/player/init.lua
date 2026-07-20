---@omw-context player

local core = require("openmw.core")
local self = require("openmw.self")

local constants = require("scripts.beamfx.shared.constants")
local log = require("scripts.beamfx.shared.log").new("player.init")
local protocol = require("scripts.beamfx.shared.protocol")
local space = require("scripts.beamfx.shared.space")

local RESYNC_RATE_LIMIT_SECONDS = 0.5
local RENDERER_RETRY_SECONDS = 5

local state = {
    role = "ownership_pending",
    baseInterface = nil,
    baseCompatible = false,
    baseStatus = nil,
    renderer = nil,
    rendererLoadFailed = false,
    rendererFailureLogged = false,
    rendererSession = nil,
    readySerial = 0,
    readySent = false,
    lastSpaceKey = nil,
    spaceResyncPending = false,
    lastResyncAt = -math.huge,
    nextRendererRetryAt = 0,
}

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

local function simulationTime()
    local getter = guardedField(core, "getSimulationTime")
    if type(getter) ~= "function" then
        return 0
    end
    local ok, value = pcall(getter)
    if ok and type(value) == "number" then
        return value
    end
    return 0
end

local function realTime()
    local getter = guardedField(core, "getRealTime")
    if type(getter) ~= "function" then
        return 0
    end
    local ok, value = pcall(getter)
    if ok
        and type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
    then
        return value
    end
    return 0
end

local function freshRendererSession()
    return string.format(
        "beamfx-renderer-v1|%.9f|%.9f|%s",
        realTime(),
        simulationTime(),
        tostring({})
    )
end

local function currentSpaceKey()
    local ok_cell, cell = pcall(function()
        if self.cell ~= nil then
            return self.cell
        end
        return self.object and self.object.cell or nil
    end)
    if not ok_cell or cell == nil then
        return nil
    end
    local ok_key, key = pcall(space.spaceKeyForCell, cell)
    if not ok_key or not space.isValidKey(key) then
        return nil
    end
    return key
end

local function rendererStatus()
    if state.renderer ~= nil and type(state.renderer.protocolStatus) == "function" then
        local ok, status = pcall(state.renderer.protocolStatus)
        if ok and type(status) == "table" then
            return status
        end
    end
    return {
        providerEpoch = nil,
        viewerSyncGeneration = 0,
    }
end

local function sendGlobal(event_name, payload)
    local send_global = guardedField(core, "sendGlobalEvent")
    if type(send_global) ~= "function" then
        return false
    end
    local ok, err = pcall(send_global, event_name, payload)
    if not ok then
        log.debug(string.format(
            "Private viewer handshake failed event=%s err=%s",
            tostring(event_name),
            tostring(err)
        ))
    end
    return ok
end

local function viewerHandshakePayload(reason)
    local status = rendererStatus()
    local viewer = guardedField(self, "object")
    state.readySerial = state.readySerial + 1
    return {
        source = "beamfx",
        protocolVersion = constants.PROTOCOL_VERSION,
        viewer = viewer,
        rendererSession = state.rendererSession,
        readySerial = state.readySerial,
        observedProviderEpoch = status.providerEpoch,
        observedViewerSyncGeneration = status.viewerSyncGeneration,
        spaceKey = currentSpaceKey(),
        reason = reason,
    }
end

local function sendReady(reason)
    if state.role ~= "primary"
        or state.renderer == nil
        or state.rendererSession == nil
    then
        return false
    end
    local sent = sendGlobal(
        protocol.events.VIEWER_READY,
        viewerHandshakePayload(reason or "player_renderer_ready")
    )
    state.readySent = state.readySent or sent
    return sent
end

local function sendResync(reason, force)
    if state.role ~= "primary"
        or state.renderer == nil
        or state.rendererSession == nil
    then
        return false
    end
    local current_time = realTime()
    if force ~= true
        and current_time - state.lastResyncAt < RESYNC_RATE_LIMIT_SECONDS
    then
        return false
    end
    state.lastResyncAt = current_time
    return sendGlobal(
        protocol.events.VIEWER_RESYNC,
        viewerHandshakePayload(reason or "renderer_resync")
    )
end

local function initializePrimaryRenderer()
    if state.role == "inert" then
        return false
    end
    if state.role == "ownership_pending" then
        -- The first deferred frame is the ownership checkpoint. A duplicate
        -- that observed an override never reaches a renderer require.
        state.role = "primary"
    elseif state.role ~= "primary" then
        return false
    end
    if state.renderer ~= nil then
        return true
    end

    local current_real_time = realTime()
    if current_real_time < state.nextRendererRetryAt then
        return false
    end

    local ok, renderer_or_error = pcall(
        require,
        "scripts.beamfx.player.renderer"
    )
    if not ok or type(renderer_or_error) ~= "table" then
        state.rendererLoadFailed = true
        state.nextRendererRetryAt =
            current_real_time + RENDERER_RETRY_SECONDS
        if not state.rendererFailureLogged then
            state.rendererFailureLogged = true
            log.error(string.format(
                "BeamFX player renderer initialization failed err=%s",
                tostring(renderer_or_error)
            ))
        end
        return false
    end

    state.renderer = renderer_or_error
    state.rendererLoadFailed = false
    local renderer_session = freshRendererSession()
    if type(state.renderer.beginRendererSession) ~= "function" then
        state.renderer = nil
        state.rendererLoadFailed = true
        state.nextRendererRetryAt =
            current_real_time + RENDERER_RETRY_SECONDS
        if not state.rendererFailureLogged then
            state.rendererFailureLogged = true
            log.error("BeamFX renderer has no session initialization gate")
        end
        return false
    end
    local call_ok, session_ok, session_err = pcall(
        state.renderer.beginRendererSession,
        renderer_session
    )
    if not call_ok or session_ok ~= true then
        state.renderer = nil
        state.rendererLoadFailed = true
        state.nextRendererRetryAt =
            current_real_time + RENDERER_RETRY_SECONDS
        if not state.rendererFailureLogged then
            state.rendererFailureLogged = true
            log.error(string.format(
                "BeamFX renderer session initialization failed err=%s",
                tostring(call_ok and session_err or session_ok)
            ))
        end
        return false
    end
    state.rendererFailureLogged = false
    state.nextRendererRetryAt = 0
    state.rendererSession = renderer_session
    state.readySerial = 0
    if type(state.renderer.setResyncHandler) == "function" then
        state.renderer.setResyncHandler(function(reason)
            -- The reducer emits at most one request while a sync generation is
            -- quarantined. It must not be swallowed by the ordinary retry
            -- limiter or that generation could remain blocked indefinitely.
            sendResync(reason, true)
        end)
    end
    state.lastSpaceKey = currentSpaceKey()
    state.spaceResyncPending =
        not sendReady("player_renderer_ready")
    return true
end

local function baseCompatibility(base_interface)
    local protocol_version, protocol_ok =
        guardedField(base_interface, "protocolVersion")
    local shader_abi, shader_ok =
        guardedField(base_interface, "shaderAbi")
    local status, status_ok =
        guardedField(base_interface, "status")
    return protocol_ok
            and shader_ok
            and protocol_version == constants.PROTOCOL_VERSION
            and shader_abi == constants.SHADER_ABI,
        status_ok and type(status) == "function"
            and status
            or nil
end

local function onInterfaceOverride(base_interface)
    if state.role ~= "ownership_pending" then
        return
    end
    state.role = "inert"
    state.baseInterface = base_interface
    state.baseCompatible, state.baseStatus =
        baseCompatibility(base_interface)
    log.warn(string.format(
        "Duplicate BeamFX player renderer is inert compatibleBase=%s",
        tostring(state.baseCompatible)
    ))
end

local function onFrame(dt)
    if state.role == "inert" then
        return
    end
    if (state.role == "ownership_pending"
            or (state.role == "primary" and state.renderer == nil))
        and not initializePrimaryRenderer()
    then
        return
    end
    if state.role ~= "primary" or state.renderer == nil then
        return
    end

    local current_space_key = currentSpaceKey()
    local space_changed = current_space_key ~= state.lastSpaceKey
    if space_changed then
        state.lastSpaceKey = current_space_key
        state.spaceResyncPending = true
    end
    if not state.readySent then
        if sendReady("player_renderer_retry") then
            state.spaceResyncPending = false
        end
    elseif state.spaceResyncPending then
        if sendResync("viewer_space_changed", space_changed) then
            state.spaceResyncPending = false
        end
    end
    local protocol_status = rendererStatus()
    if protocol_status.resyncRequested == true
        or protocol_status.blockedSyncGeneration ~= nil
    then
        sendResync("renderer_resync_retry", false)
    end
    state.renderer.onFrame(dt)
end

local function dispatch(method_name, payload)
    if state.role ~= "primary" or state.renderer == nil then
        return
    end
    local handler = state.renderer[method_name]
    if type(handler) == "function" then
        handler(payload)
    end
end

local renderer_interface = {
    version = constants.PACKAGE_VERSION,
    protocolVersion = constants.PROTOCOL_VERSION,
    shaderAbi = constants.SHADER_ABI,
}

function renderer_interface.status()
    if state.role == "inert"
        and state.baseCompatible
        and state.baseStatus ~= nil
    then
        local ok, value = pcall(state.baseStatus)
        if ok then
            return value
        end
    end
    local status = rendererStatus()
    local result = {
        role = state.role,
        compatibleBase = state.baseCompatible,
        rendererLoaded = state.renderer ~= nil,
        rendererLoadFailed = state.rendererLoadFailed,
        rendererSession = state.rendererSession,
        readySerial = state.readySerial,
        providerEpoch = status.providerEpoch,
        viewerSyncGeneration = status.viewerSyncGeneration,
        tombstoneCount = status.tombstoneCount,
        blockedSyncGeneration = status.blockedSyncGeneration,
        resyncRequested = status.resyncRequested,
        error = state.role == "inert"
                and not state.baseCompatible
                and "duplicate_provider"
            or nil,
    }
    for name, value in pairs(status) do
        if result[name] == nil then
            result[name] = value
        end
    end
    return result
end

return {
    interfaceName = "BeamFXRenderer",
    interface = renderer_interface,
    engineHandlers = {
        onFrame = onFrame,
        onInterfaceOverride = onInterfaceOverride,
    },
    eventHandlers = {
        [protocol.events.RENDER_SNAPSHOT] = function(payload)
            dispatch("onSnapshot", payload)
        end,
        [protocol.events.RENDER_REMOVE] = function(payload)
            dispatch("onProtocolRemove", payload)
        end,
        [protocol.events.PROVIDER_RESET] = function(payload)
            dispatch("onProviderReset", payload)
        end,
        [protocol.events.VIEWER_RECONCILE_RESET] = function(payload)
            dispatch("onViewerReconcileReset", payload)
        end,
    },
}
