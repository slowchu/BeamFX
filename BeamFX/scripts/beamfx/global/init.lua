---@omw-context global

local core = require("openmw.core")
local types = require("openmw.types")
local util = require("openmw.util")
local world = require("openmw.world")

local constants = require("scripts.beamfx.shared.constants")
local log = require("scripts.beamfx.shared.log").new("global.init")
local protocol = require("scripts.beamfx.shared.protocol")
local space = require("scripts.beamfx.shared.space")
local styles = require("scripts.beamfx.shared.styles")

local MAX_PENDING_HANDSHAKES = 256
local MAX_PENDING_PLAYERS = constants.MAX_REGISTERED_PRODUCERS
local PROVIDER_RETRY_SECONDS = 5
local ERROR_LOG_INTERVAL_SECONDS = 5

local state = {
    role = "ownership_pending",
    baseInterface = nil,
    baseCompatible = false,
    baseMethods = nil,
    duplicateLogged = false,
    initialized = false,
    initializationErrorLogged = false,
    providerEpoch = nil,
    epochSerial = 0,
    broker = nil,
    registry = nil,
    viewerSync = nil,
    pendingResetReason = nil,
    pendingPlayers = {},
    pendingHandshakes = {},
    nextInitializationRetryAt = 0,
    nextResetRetryAt = 0,
    errorLoggedAt = {},
}

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

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
        return nil
    end
    local ok, value = pcall(getter)
    if ok and finiteNumber(value) then
        return value
    end
    return nil
end

local function realTime()
    local getter = guardedField(core, "getRealTime")
    if type(getter) ~= "function" then
        return 0
    end
    local ok, value = pcall(getter)
    if ok and finiteNumber(value) then
        return value
    end
    return 0
end

local function freshEpoch()
    state.epochSerial = state.epochSerial + 1
    return string.format(
        "beamfx-provider-v1|%.9f|%.9f|%d|%s",
        realTime(),
        simulationTime() or 0,
        state.epochSerial,
        tostring({})
    )
end

local function validPlayer(viewer)
    if viewer == nil then
        return false
    end
    local player_type = guardedField(types, "Player")
    local object_is_instance =
        guardedField(player_type, "objectIsInstance")
    if type(object_is_instance) ~= "function" then
        return false
    end
    local ok_type, is_player =
        pcall(object_is_instance, viewer)
    if not ok_type or is_player ~= true then
        return false
    end

    local member, member_ok = guardedField(viewer, "isValid")
    if not member_ok then
        return false
    end
    if type(member) == "function" then
        local ok_valid, result = pcall(member, viewer)
        return ok_valid and result == true
    end
    return member ~= false
end

local function playerId(viewer)
    local id, id_ok = guardedField(viewer, "id")
    if not id_ok or id == nil then
        return nil
    end
    local ok, text = pcall(tostring, id)
    return ok and text or nil
end

local function sendToViewer(viewer, event_name, payload)
    if not validPlayer(viewer) then
        return false
    end
    local send_event = guardedField(viewer, "sendEvent")
    if type(send_event) ~= "function" then
        return false
    end
    local ok, result = pcall(
        send_event,
        viewer,
        event_name,
        payload
    )
    return ok and result ~= false
end

local function listPlayers()
    local players, ok = guardedField(world, "players")
    return ok and players or nil
end

local function internalError(operation, ...)
    local current_time = realTime()
    local previous = state.errorLoggedAt[operation]
    if previous ~= nil
        and current_time - previous < ERROR_LOG_INTERVAL_SECONDS
    then
        return
    end
    state.errorLoggedAt[operation] = current_time
    local parts = {}
    for index = 1, select("#", ...) do
        parts[index] = tostring(select(index, ...))
    end
    log.error(string.format(
        "BeamFX internal error operation=%s detail=%s",
        tostring(operation),
        table.concat(parts, " ")
    ))
end

local function capabilities()
    local quotas = {}
    for name, value in pairs(constants.QUOTAS) do
        quotas[name] = value
    end
    return {
        apiMajor = constants.API_MAJOR,
        apiMinor = constants.API_MINOR,
        version = constants.PACKAGE_VERSION,
        protocolVersion = constants.PROTOCOL_VERSION,
        shaderAbi = constants.SHADER_ABI,
        producerApiShape = constants.PRODUCER_API_SHAPE,
        styles = styles.names(),
        segmentCapacity = constants.SEGMENT_CAPACITY,
        paletteCapacity = constants.PALETTE_CAPACITY,
        lifecycleModes = { "transient", "persistent" },
        audienceModes = { "same_space" },
        spaceFiltering = true,
        coalescing = {
            fullSnapshots = true,
            latestRevisionPerUpdate = true,
            terminalPrecedence = true,
        },
        optionalLeases = true,
        features = {
            globalProvider = true,
            globalDiagnostics = true,
            playerPostprocessing = true,
            perViewerRouting = true,
            targetedReconciliation = true,
        },
        quotas = quotas,
        fairness = {
            capacity = constants.FAIRNESS_CAPACITY,
            maxPublicServiceWindowFrames =
                constants.serviceWindowFrames(
                    constants.MAX_REGISTERED_PRODUCERS
                ),
            temporaryBridgeProducerGroups = 0,
            maxServiceWindowFrames =
                constants.FAIRNESS_MAX_SERVICE_WINDOW_FRAMES,
            serviceWindowFormula = "ceil(P / 64)",
        },
    }
end

local function diagnosticCount(value)
    if not finiteNumber(value) or value < 0 then
        return 0
    end
    return math.floor(value)
end

local function producerDiagnosticKey(producer_id, generation)
    return tostring(producer_id)
        .. "\0"
        .. tostring(generation)
end

local function providerDiagnostics()
    if not state.initialized
        or state.broker == nil
        or state.registry == nil
        or state.viewerSync == nil
    then
        return nil, "provider_reset"
    end

    local broker_diagnostics = state.broker:diagnostics()
    local registry_diagnostics = state.registry:diagnostics()
    local viewer_status = state.viewerSync:status()
    if type(broker_diagnostics) ~= "table"
        or type(registry_diagnostics) ~= "table"
        or type(viewer_status) ~= "table"
    then
        return nil, "provider_reset"
    end

    local broker_by_key = {}
    for _, producer in ipairs(broker_diagnostics.producers or {}) do
        broker_by_key[producerDiagnosticKey(
            producer.producerId,
            producer.producerGeneration
        )] = producer
    end

    local producers = {}
    local included = {}
    for _, registered in ipairs(registry_diagnostics.producers or {}) do
        local key = producerDiagnosticKey(
            registered.producerId,
            registered.producerGeneration
        )
        local broker_producer = broker_by_key[key] or {}
        local broker_current = broker_producer.current or {}
        local broker_cumulative =
            broker_producer.cumulative or {}
        local boundary_invalid = diagnosticCount(
            registered.boundaryInvalidRequests
        )
        producers[#producers + 1] = {
            producerId = registered.producerId,
            producerGeneration =
                registered.producerGeneration,
            displayName = registered.displayName,
            current = {
                activeBeams = diagnosticCount(
                    registered.beamCount
                        or broker_current.activeBeams
                ),
                retainedSegments = diagnosticCount(
                    registered.segmentCount
                        or broker_current.retainedSegments
                ),
            },
            cumulative = {
                successfulMutations = diagnosticCount(
                    broker_cumulative.successfulMutations
                ),
                acceptedSegments = diagnosticCount(
                    broker_cumulative.acceptedSegments
                ),
                invalidRequests = diagnosticCount(
                    broker_cumulative.invalidRequests
                ) + boundary_invalid,
                createdBeamGenerations = diagnosticCount(
                    broker_cumulative.createdBeamGenerations
                ),
                removedBeamGenerations = diagnosticCount(
                    broker_cumulative.removedBeamGenerations
                ),
                boundaryInvalidRequests = boundary_invalid,
                staleProducerRequests = diagnosticCount(
                    registered.staleProducerRequests
                ),
            },
        }
        included[key] = true
    end

    -- This should be empty in production because release removes the broker
    -- record before invalidating the registry state. Retaining unmatched
    -- records makes diagnostics fail-safe if an internal integration changes.
    for _, broker_producer in ipairs(
        broker_diagnostics.producers or {}
    ) do
        local key = producerDiagnosticKey(
            broker_producer.producerId,
            broker_producer.producerGeneration
        )
        if not included[key] then
            local current = broker_producer.current or {}
            local cumulative =
                broker_producer.cumulative or {}
            producers[#producers + 1] = {
                producerId = broker_producer.producerId,
                producerGeneration =
                    broker_producer.producerGeneration,
                displayName = broker_producer.producerId,
                current = {
                    activeBeams = diagnosticCount(
                        current.activeBeams
                    ),
                    retainedSegments = diagnosticCount(
                        current.retainedSegments
                    ),
                },
                cumulative = {
                    successfulMutations = diagnosticCount(
                        cumulative.successfulMutations
                    ),
                    acceptedSegments = diagnosticCount(
                        cumulative.acceptedSegments
                    ),
                    invalidRequests = diagnosticCount(
                        cumulative.invalidRequests
                    ),
                    createdBeamGenerations = diagnosticCount(
                        cumulative.createdBeamGenerations
                    ),
                    removedBeamGenerations = diagnosticCount(
                        cumulative.removedBeamGenerations
                    ),
                    boundaryInvalidRequests = 0,
                    staleProducerRequests = 0,
                },
            }
        end
    end
    table.sort(producers, function(left, right)
        if left.producerId ~= right.producerId then
            return left.producerId < right.producerId
        end
        return left.producerGeneration
            < right.producerGeneration
    end)

    local broker_current = broker_diagnostics.current or {}
    local broker_cumulative =
        broker_diagnostics.cumulative or {}
    local registry_current =
        registry_diagnostics.current or {}
    local registry_cumulative =
        registry_diagnostics.cumulative or {}
    local boundary_invalid = diagnosticCount(
        registry_cumulative.boundaryInvalidRequests
    )
    return {
        apiMajor = constants.API_MAJOR,
        apiMinor = constants.API_MINOR,
        version = constants.PACKAGE_VERSION,
        providerEpoch = state.providerEpoch,
        current = {
            registeredProducers = diagnosticCount(
                registry_current.activeProducers
            ),
            brokerProducerStates = diagnosticCount(
                broker_current.registeredProducerStates
            ),
            activeBeams = diagnosticCount(
                broker_current.activeBeams
            ),
            retainedSegments = diagnosticCount(
                broker_current.retainedSegments
            ),
            pendingChanges = diagnosticCount(
                broker_current.pendingChanges
            ),
            updateSerial = diagnosticCount(
                broker_current.updateSerial
            ),
            viewers = diagnosticCount(viewer_status.viewers),
            readyViewers =
                diagnosticCount(viewer_status.readyViewers),
            deliveredBeams =
                diagnosticCount(viewer_status.deliveredBeams),
            rendererTombstones =
                diagnosticCount(viewer_status.tombstones),
        },
        cumulative = {
            successfulMutations = diagnosticCount(
                broker_cumulative.successfulMutations
            ),
            acceptedSegments = diagnosticCount(
                broker_cumulative.acceptedSegments
            ),
            invalidRequests = diagnosticCount(
                broker_cumulative.invalidRequests
            ) + boundary_invalid,
            createdBeamGenerations = diagnosticCount(
                broker_cumulative.createdBeamGenerations
            ),
            removedBeamGenerations = diagnosticCount(
                broker_cumulative.removedBeamGenerations
            ),
            registrationAttempts = diagnosticCount(
                registry_cumulative.registrationAttempts
            ),
            successfulRegistrations = diagnosticCount(
                registry_cumulative.successfulRegistrations
            ),
            boundaryInvalidRequests = boundary_invalid,
            staleProducerRequests = diagnosticCount(
                registry_cumulative.staleProducerRequests
            ),
            releasedProducers = diagnosticCount(
                registry_cumulative.releasedProducers
            ),
        },
        producers = producers,
    }
end

local BASE_INTERFACE_METHODS = {
    "capabilities",
    "diagnostics",
    "providerEpoch",
    "registerProducer",
    "spaceKeyForCell",
}

local function baseIsCompatible(base_interface)
    local api_major, api_major_ok =
        guardedField(base_interface, "apiMajor")
    local api_minor, api_minor_ok =
        guardedField(base_interface, "apiMinor")
    local version, version_ok =
        guardedField(base_interface, "version")
    local protocol_version, protocol_version_ok =
        guardedField(base_interface, "protocolVersion")
    local shader_abi, shader_abi_ok =
        guardedField(base_interface, "shaderAbi")
    if not api_major_ok
        or not api_minor_ok
        or not version_ok
        or not protocol_version_ok
        or not shader_abi_ok
        or api_major ~= constants.API_MAJOR
        or api_minor ~= constants.API_MINOR
        or version ~= constants.PACKAGE_VERSION
        or protocol_version ~= constants.PROTOCOL_VERSION
        or shader_abi ~= constants.SHADER_ABI
    then
        return false, nil
    end

    local methods = {}
    for _, name in ipairs(BASE_INTERFACE_METHODS) do
        local method, ok = guardedField(base_interface, name)
        if not ok or type(method) ~= "function" then
            return false, nil
        end
        methods[name] = method
    end
    return true, methods
end

local function queuePlayer(viewer)
    if #state.pendingPlayers >= MAX_PENDING_PLAYERS then
        table.remove(state.pendingPlayers, 1)
    end
    state.pendingPlayers[#state.pendingPlayers + 1] = viewer
end

local function copyHandshake(payload, resync)
    if type(payload) ~= "table" then
        return {
            payload = payload,
            resync = resync == true,
        }
    end
    return {
        payload = {
            source = payload.source,
            protocolVersion = payload.protocolVersion,
            viewer = payload.viewer,
            rendererSession = payload.rendererSession,
            readySerial = payload.readySerial,
            observedProviderEpoch =
                payload.observedProviderEpoch,
            observedViewerSyncGeneration =
                payload.observedViewerSyncGeneration,
            spaceKey = payload.spaceKey,
            reason = payload.reason,
        },
        resync = resync == true,
    }
end

local function queueHandshake(payload, resync)
    if #state.pendingHandshakes >= MAX_PENDING_HANDSHAKES then
        table.remove(state.pendingHandshakes, 1)
    end
    state.pendingHandshakes[#state.pendingHandshakes + 1] =
        copyHandshake(payload, resync)
end

local function handleHandshake(payload, resync)
    if state.role == "inert" then
        return
    end
    if not state.initialized then
        queueHandshake(payload, resync)
        return
    end
    local now = simulationTime()
    local result, err
    if resync then
        result, err = state.viewerSync:handleResync(payload, now)
    else
        result, err = state.viewerSync:handleReady(payload, now)
    end
    if result == nil then
        internalError(
            resync and "viewer_resync" or "viewer_ready",
            err
        )
    end
    return result, err
end

local function initializePrimary()
    if state.role == "inert" then
        return false
    end
    if state.initialized then
        return true
    end
    if state.role == "ownership_pending" then
        state.role = "primary"
    end
    if state.role ~= "primary" then
        return false
    end
    local current_real_time = realTime()
    if current_real_time < state.nextInitializationRetryAt then
        return false
    end

    local ok_modules, broker_module, registry_module,
        viewer_sync_module = pcall(function()
            return require("scripts.beamfx.global.broker"),
                require("scripts.beamfx.global.producer_registry"),
                require("scripts.beamfx.global.viewer_sync")
        end)
    if not ok_modules then
        state.nextInitializationRetryAt =
            current_real_time + PROVIDER_RETRY_SECONDS
        if not state.initializationErrorLogged then
            state.initializationErrorLogged = true
            log.error(string.format(
                "BeamFX provider modules failed to load err=%s",
                tostring(broker_module)
            ))
        end
        return false
    end

    local epoch = freshEpoch()
    local broker_instance, err = broker_module.new({
        providerEpoch = epoch,
        now = simulationTime,
        onError = internalError,
    })
    if broker_instance == nil then
        internalError("broker_init", err)
        state.nextInitializationRetryAt =
            current_real_time + PROVIDER_RETRY_SECONDS
        return false
    end
    local registry_instance
    registry_instance, err = registry_module.new({
        providerEpoch = epoch,
        invoke = function(producer_state, operation, ...)
            return broker_instance:invoke(
                producer_state,
                operation,
                ...
            )
        end,
        util = util,
        onError = internalError,
    })
    if registry_instance == nil then
        internalError("registry_init", err)
        state.nextInitializationRetryAt =
            current_real_time + PROVIDER_RETRY_SECONDS
        return false
    end
    local viewer_sync_instance
    viewer_sync_instance, err = viewer_sync_module.new({
        providerEpoch = epoch,
        broker = broker_instance,
        sendToViewer = sendToViewer,
        listPlayers = listPlayers,
        isValidViewer = validPlayer,
        viewerId = playerId,
        retryNow = realTime,
        onError = internalError,
    })
    if viewer_sync_instance == nil then
        internalError("viewer_sync_init", err)
        state.nextInitializationRetryAt =
            current_real_time + PROVIDER_RETRY_SECONDS
        return false
    end

    state.providerEpoch = epoch
    state.broker = broker_instance
    state.registry = registry_instance
    state.viewerSync = viewer_sync_instance
    state.initialized = true
    state.initializationErrorLogged = false
    state.nextInitializationRetryAt = 0

    for _, viewer in ipairs(state.pendingPlayers) do
        state.viewerSync:onPlayerAdded(viewer)
    end
    state.pendingPlayers = {}

    local initial_reason =
        state.pendingResetReason or "provider_initialized"
    state.pendingResetReason = nil
    state.viewerSync:providerReset(nil, epoch, initial_reason)

    local handshakes = state.pendingHandshakes
    state.pendingHandshakes = {}
    for _, pending in ipairs(handshakes) do
        if pending.resync then
            state.viewerSync:handleResync(
                pending.payload,
                simulationTime()
            )
        else
            state.viewerSync:handleReady(
                pending.payload,
                simulationTime()
            )
        end
    end
    return true
end

local function resetPrimary(reason)
    if state.role ~= "primary" or not state.initialized then
        return false
    end
    local old_epoch = state.providerEpoch
    local new_epoch = freshEpoch()
    local broker_result, broker_err =
        state.broker:reset(new_epoch)
    if broker_result == nil then
        internalError("broker_reset", broker_err)
        return false
    end
    local registry_result, registry_err =
        state.registry:reset(new_epoch)
    if registry_result == nil then
        internalError("registry_reset", registry_err)
        return false
    end
    state.providerEpoch = new_epoch
    local sync_result, sync_err = state.viewerSync:providerReset(
        old_epoch,
        new_epoch,
        reason or "provider_reset"
    )
    if sync_result == nil then
        internalError("viewer_sync_reset", sync_err)
    end
    state.nextResetRetryAt =
        realTime() + PROVIDER_RETRY_SECONDS
    return true
end

local function requestReset(reason)
    if state.role == "inert" then
        return
    end
    state.pendingResetReason = reason or "provider_reset"
end

local function onUpdate()
    if state.role == "inert" then
        return
    end
    if not initializePrimary() then
        return
    end

    local now = simulationTime()
    if now == nil then
        internalError(
            "simulation_time",
            "temporarily unavailable"
        )
        return
    end

    if state.pendingResetReason ~= nil
        and realTime() >= state.nextResetRetryAt
    then
        local reason = state.pendingResetReason
        state.pendingResetReason = nil
        if not resetPrimary(reason) then
            state.pendingResetReason = reason
            state.nextResetRetryAt =
                realTime() + PROVIDER_RETRY_SECONDS
            return
        end
    end

    local broker_result, broker_err = state.broker:update(now)
    if broker_result == nil then
        internalError("broker_update", broker_err)
        requestReset("broker_update_failed")
        return
    end
    local sync_result, sync_err = state.viewerSync:update(now)
    if sync_result == nil then
        internalError("viewer_sync_update", sync_err)
        if sync_err == "provider_reset" then
            requestReset("viewer_sync_failed")
        end
    end
end

local function onPlayerAdded(viewer)
    if state.role == "inert" then
        return
    end
    if not state.initialized then
        queuePlayer(viewer)
        return
    end
    state.viewerSync:onPlayerAdded(viewer)
end

local function onInterfaceOverride(base_interface)
    if state.role ~= "ownership_pending" then
        return
    end
    state.role = "inert"
    state.baseInterface = base_interface
    state.baseCompatible, state.baseMethods =
        baseIsCompatible(base_interface)
    state.pendingPlayers = {}
    state.pendingHandshakes = {}
    state.pendingResetReason = nil
    if not state.duplicateLogged then
        state.duplicateLogged = true
        log.warn(string.format(
            "Duplicate BeamFX provider is inert compatibleBase=%s",
            tostring(state.baseCompatible)
        ))
    end
end

local public_interface = {
    apiMajor = constants.API_MAJOR,
    apiMinor = constants.API_MINOR,
    version = constants.PACKAGE_VERSION,
    protocolVersion = constants.PROTOCOL_VERSION,
    shaderAbi = constants.SHADER_ABI,
}

function public_interface.capabilities()
    if state.role == "inert" then
        if state.baseCompatible then
            return state.baseMethods.capabilities()
        end
        return nil, "duplicate_provider"
    end
    return capabilities()
end

function public_interface.diagnostics()
    if state.role == "inert" then
        if state.baseCompatible then
            return state.baseMethods.diagnostics()
        end
        return nil, "duplicate_provider"
    end
    local ok, result, err = pcall(providerDiagnostics)
    if not ok then
        internalError("diagnostics", result)
        return nil, "provider_reset"
    end
    return result, err
end

function public_interface.providerEpoch()
    if state.role == "inert" then
        if state.baseCompatible then
            return state.baseMethods.providerEpoch()
        end
        return nil, "duplicate_provider"
    end
    if not state.initialized then
        return nil, "provider_reset"
    end
    return state.providerEpoch
end

function public_interface.registerProducer(spec)
    if state.role == "inert" then
        if state.baseCompatible then
            return state.baseMethods.registerProducer(spec)
        end
        return nil, "duplicate_provider"
    end
    if not state.initialized or state.registry == nil then
        return nil, "provider_reset"
    end
    return state.registry:registerProducer(spec)
end

function public_interface.spaceKeyForCell(cell)
    if state.role == "inert" then
        if state.baseCompatible then
            return state.baseMethods.spaceKeyForCell(cell)
        end
        return nil, "duplicate_provider"
    end
    return space.spaceKeyForCell(cell)
end

return {
    interfaceName = "BeamFX",
    interface = public_interface,
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad = function()
            requestReset("load")
        end,
        onNewGame = function()
            requestReset("new_game")
        end,
        onPlayerAdded = onPlayerAdded,
        onInterfaceOverride = onInterfaceOverride,
    },
    eventHandlers = {
        [protocol.events.VIEWER_READY] = function(payload)
            handleHandshake(payload, false)
        end,
        [protocol.events.VIEWER_RESYNC] = function(payload)
            handleHandshake(payload, true)
        end,
    },
}
