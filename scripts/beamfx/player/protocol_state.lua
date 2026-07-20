---@omw-context player | none

local constants = require("scripts.beamfx.shared.constants")
local protocol = require("scripts.beamfx.shared.protocol")

local protocol_state = {}
local MAX_RENDERER_SESSION_LENGTH =
    tonumber(constants.MAX_RENDERER_SESSION_LENGTH)
    or tonumber(constants.MAX_EPOCH_LENGTH)
    or 192
local MAX_RETIRED_PROVIDER_EPOCHS = 16

local function newResult(kind)
    return {
        kind = kind,
        accepted = false,
        removedKeys = {},
    }
end

local function clearVersionedState(state)
    state.liveByKey = {}
    state.tombstonesByKey = {}
    state.tombstoneCount = 0
    state.latestProducerGeneration = {}
    state.latestBeamGeneration = {}
end

function protocol_state.new(options)
    local opts = type(options) == "table" and options or {}
    return {
        rendererSession = opts.rendererSession,
        providerEpoch = nil,
        providerEpochConfirmed = false,
        viewerSyncGeneration = 0,
        liveByKey = {},
        tombstonesByKey = {},
        tombstoneCount = 0,
        latestProducerGeneration = {},
        latestBeamGeneration = {},
        retiredProviderEpochs = {},
        retiredProviderOrder = {},
        blockedSyncGeneration = nil,
        resyncRequested = false,
        tombstoneLimit = math.max(
            1,
            math.floor(tonumber(opts.tombstoneLimit)
                or constants.MAX_RENDERER_TOMBSTONES)
        ),
    }
end

function protocol_state.beginRendererSession(state, renderer_session)
    if type(renderer_session) ~= "string"
        or renderer_session == ""
        or #renderer_session > MAX_RENDERER_SESSION_LENGTH
        or renderer_session:find("[%z\1-\31\127]") ~= nil
    then
        return false, "invalid_renderer_session"
    end
    clearVersionedState(state)
    state.rendererSession = renderer_session
    state.providerEpoch = nil
    state.providerEpochConfirmed = false
    state.viewerSyncGeneration = 0
    state.retiredProviderEpochs = {}
    state.retiredProviderOrder = {}
    state.blockedSyncGeneration = nil
    state.resyncRequested = false
    return true
end

local function retireProviderEpoch(state, provider_epoch)
    if type(provider_epoch) ~= "string"
        or provider_epoch == ""
        or state.retiredProviderEpochs[provider_epoch]
    then
        return
    end
    state.retiredProviderEpochs[provider_epoch] = true
    state.retiredProviderOrder[#state.retiredProviderOrder + 1] =
        provider_epoch
    if #state.retiredProviderOrder > MAX_RETIRED_PROVIDER_EPOCHS then
        local dropped = table.remove(state.retiredProviderOrder, 1)
        state.retiredProviderEpochs[dropped] = nil
    end
end

local function requestResync(state, result, reason)
    if not state.resyncRequested then
        state.resyncRequested = true
        result.requestResync = true
        result.resyncReason = reason
    end
end

local function packetContext(state, packet, result)
    if state.rendererSession == nil
        or packet.rendererSession ~= state.rendererSession
    then
        return nil, "renderer_session_mismatch"
    end
    if packet.viewerSyncGeneration < state.viewerSyncGeneration then
        return nil, "stale_viewer_sync_generation"
    end
    if state.providerEpoch == nil then
        requestResync(state, result, "provider_epoch_uninitialized")
        return nil, "provider_epoch_uninitialized"
    end
    if packet.providerEpoch ~= state.providerEpoch then
        if state.retiredProviderEpochs[packet.providerEpoch] then
            return nil, "stale_provider_epoch"
        end
        requestResync(state, result, "provider_epoch_mismatch")
        return nil, "provider_epoch_mismatch"
    end
    if packet.viewerSyncGeneration ~= state.viewerSyncGeneration then
        if packet.viewerSyncGeneration > state.viewerSyncGeneration then
            requestResync(state, result, "future_viewer_sync_generation")
            return nil, "future_viewer_sync_generation"
        end
        return nil, "stale_viewer_sync_generation"
    end
    if state.blockedSyncGeneration == packet.viewerSyncGeneration then
        return nil, "viewer_sync_blocked"
    end
    return true
end

local function removeLiveKey(state, result, key)
    if state.liveByKey[key] ~= nil then
        state.liveByKey[key] = nil
        result.removedKeys[#result.removedKeys + 1] = key
    end
end

local function supersedeProducerGeneration(state, result, producer_id, generation)
    local current = state.latestProducerGeneration[producer_id]
    if current ~= nil and generation < current then
        return nil, "stale_producer_generation"
    end
    if current == nil or generation > current then
        for key, entry in pairs(state.liveByKey) do
            if entry.producerId == producer_id
                and entry.producerGeneration ~= generation
            then
                removeLiveKey(state, result, key)
            end
        end
        state.latestProducerGeneration[producer_id] = generation
        state.latestBeamGeneration[producer_id] = {
            producerGeneration = generation,
            byLocalId = {},
        }
    end
    return true
end

local function supersedeBeamGeneration(state, result, packet)
    local producer_beams = state.latestBeamGeneration[packet.producerId]
    if producer_beams == nil
        or producer_beams.producerGeneration ~= packet.producerGeneration
    then
        producer_beams = {
            producerGeneration = packet.producerGeneration,
            byLocalId = {},
        }
        state.latestBeamGeneration[packet.producerId] = producer_beams
    end

    local current = producer_beams.byLocalId[packet.localBeamId]
    if current ~= nil and packet.beamGeneration < current then
        return nil, "stale_beam_generation"
    end
    if current == nil or packet.beamGeneration > current then
        for key, entry in pairs(state.liveByKey) do
            if entry.producerId == packet.producerId
                and entry.producerGeneration == packet.producerGeneration
                and entry.localBeamId == packet.localBeamId
                and entry.beamGeneration ~= packet.beamGeneration
            then
                removeLiveKey(state, result, key)
            end
        end
        producer_beams.byLocalId[packet.localBeamId] = packet.beamGeneration
    end
    return true
end

local function acceptGeneration(state, result, packet)
    local ok, err = supersedeProducerGeneration(
        state,
        result,
        packet.producerId,
        packet.producerGeneration
    )
    if not ok then
        return nil, err
    end
    return supersedeBeamGeneration(state, result, packet)
end

local function quarantineSync(state, result)
    state.blockedSyncGeneration = state.viewerSyncGeneration
    clearVersionedState(state)
    result.clear = true
    result.quarantined = true
    requestResync(state, result, "renderer_tombstone_capacity")
end

function protocol_state.applySnapshot(state, payload)
    local result = newResult("snapshot")
    local packet, err = protocol.validateSnapshot(payload)
    if packet == nil then
        result.error = err
        return result
    end
    local ok
    ok, err = packetContext(state, packet, result)
    if not ok then
        result.error = err
        return result
    end
    ok, err = acceptGeneration(state, result, packet)
    if not ok then
        result.error = err
        return result
    end

    local tombstone = state.tombstonesByKey[packet.compositeRenderKey]
    if tombstone ~= nil then
        result.error = packet.revision > tombstone.terminalRevision
            and "snapshot_after_terminal_revision"
            or "removed_generation"
        return result
    end

    local existing = state.liveByKey[packet.compositeRenderKey]
    if existing ~= nil and packet.revision <= existing.revision then
        result.error = "stale_revision"
        return result
    end

    -- The compositor owns the copied geometry. The protocol reducer needs
    -- only a lean ordering record; retaining the complete packet here would
    -- duplicate segment arrays and outlive renderer-side pruning.
    state.liveByKey[packet.compositeRenderKey] = {
        producerId = packet.producerId,
        producerGeneration = packet.producerGeneration,
        localBeamId = packet.localBeamId,
        beamGeneration = packet.beamGeneration,
        revision = packet.revision,
    }
    result.accepted = true
    result.packet = packet
    return result
end

function protocol_state.applyRemove(state, payload)
    local result = newResult("remove")
    local packet, err = protocol.validateRemove(payload)
    if packet == nil then
        result.error = err
        return result
    end
    local ok
    ok, err = packetContext(state, packet, result)
    if not ok then
        result.error = err
        return result
    end
    ok, err = acceptGeneration(state, result, packet)
    if not ok then
        result.error = err
        return result
    end

    local existing = state.liveByKey[packet.compositeRenderKey]
    if existing ~= nil and packet.terminalRevision < existing.revision then
        result.error = "stale_terminal_revision"
        return result
    end

    local tombstone = state.tombstonesByKey[packet.compositeRenderKey]
    if tombstone ~= nil then
        if packet.terminalRevision > tombstone.terminalRevision then
            tombstone.terminalRevision = packet.terminalRevision
        end
        removeLiveKey(state, result, packet.compositeRenderKey)
        result.accepted = true
        result.idempotent = true
        result.packet = packet
        return result
    end

    if state.tombstoneCount >= state.tombstoneLimit then
        quarantineSync(state, result)
        result.error = "renderer_tombstone_capacity"
        return result
    end

    removeLiveKey(state, result, packet.compositeRenderKey)
    state.tombstonesByKey[packet.compositeRenderKey] = {
        terminalRevision = packet.terminalRevision,
    }
    state.tombstoneCount = state.tombstoneCount + 1
    result.accepted = true
    result.packet = packet
    return result
end

function protocol_state.applyProviderReset(state, payload)
    local result = newResult("provider_reset")
    local packet, err = protocol.validateProviderReset(payload)
    if packet == nil then
        result.error = err
        return result
    end

    if state.providerEpoch == packet.newProviderEpoch then
        retireProviderEpoch(state, packet.oldProviderEpoch)
        result.accepted = true
        result.idempotent = true
        result.packet = packet
        return result
    end
    if state.providerEpoch == nil then
        if packet.oldProviderEpoch ~= nil then
            result.error = "provider_reset_mismatch"
            return result
        end
    elseif state.providerEpoch ~= packet.oldProviderEpoch then
        result.error = "provider_reset_mismatch"
        return result
    end

    clearVersionedState(state)
    retireProviderEpoch(state, state.providerEpoch)
    retireProviderEpoch(state, packet.oldProviderEpoch)
    state.providerEpoch = packet.newProviderEpoch
    -- Provider reset is intentionally sessionless. Treat its epoch as
    -- provisional until a reset carrying this renderer session confirms it.
    state.providerEpochConfirmed = false
    state.viewerSyncGeneration = 0
    state.blockedSyncGeneration = nil
    state.resyncRequested = false
    result.accepted = true
    result.clear = true
    result.packet = packet
    return result
end

function protocol_state.applyViewerReconcileReset(state, payload)
    local result = newResult("viewer_reconcile_reset")
    local packet, err = protocol.validateViewerReconcileReset(payload)
    if packet == nil then
        result.error = err
        return result
    end
    if state.rendererSession == nil
        or packet.rendererSession ~= state.rendererSession
    then
        result.error = "renderer_session_mismatch"
        return result
    end

    if packet.newViewerSyncGeneration < state.viewerSyncGeneration then
        result.error = "stale_viewer_sync_generation"
        return result
    end
    if state.providerEpoch == nil then
        state.providerEpoch = packet.providerEpoch
    elseif state.providerEpoch ~= packet.providerEpoch
        and state.retiredProviderEpochs[packet.providerEpoch]
    then
        result.error = "stale_provider_epoch"
        return result
    elseif not state.providerEpochConfirmed
        and state.providerEpoch ~= packet.providerEpoch
    then
        -- A saved/delayed sessionless reset may have populated a fresh
        -- renderer with an obsolete epoch. The matching-session targeted
        -- reset is authoritative for this renderer lifetime.
        retireProviderEpoch(state, state.providerEpoch)
        clearVersionedState(state)
        state.providerEpoch = packet.providerEpoch
        state.viewerSyncGeneration = 0
    elseif state.providerEpoch ~= packet.providerEpoch then
        requestResync(state, result, "provider_epoch_mismatch")
        result.error = "provider_epoch_mismatch"
        return result
    end

    if packet.newViewerSyncGeneration == state.viewerSyncGeneration then
        state.providerEpochConfirmed = true
        result.accepted = true
        result.idempotent = true
        result.packet = packet
        return result
    end

    clearVersionedState(state)
    state.viewerSyncGeneration = packet.newViewerSyncGeneration
    state.providerEpochConfirmed = true
    state.blockedSyncGeneration = nil
    state.resyncRequested = false
    result.accepted = true
    result.clear = true
    result.packet = packet
    return result
end

function protocol_state.status(state)
    return {
        rendererSession = state.rendererSession,
        providerEpoch = state.providerEpoch,
        providerEpochConfirmed = state.providerEpochConfirmed,
        viewerSyncGeneration = state.viewerSyncGeneration,
        tombstoneCount = state.tombstoneCount,
        blockedSyncGeneration = state.blockedSyncGeneration,
        resyncRequested = state.resyncRequested,
        retiredProviderEpochs = #state.retiredProviderOrder,
    }
end

return protocol_state
