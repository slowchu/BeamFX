---@omw-context global | none

local default_constants = require("scripts.beamfx.shared.constants")
local default_protocol = require("scripts.beamfx.shared.protocol")
local default_space = require("scripts.beamfx.shared.space")

local viewer_sync = {}

local MAX_SAFE_INTEGER = 9007199254740991
local DEFAULT_RETRY_SECONDS = 0.25

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function safeInteger(value, minimum)
    return finiteNumber(value)
        and value == math.floor(value)
        and value >= (minimum or 0)
        and value <= MAX_SAFE_INTEGER
end

local function boundedString(value, maximum, allow_empty)
    return type(value) == "string"
        and (allow_empty == true or value ~= "")
        and #value <= maximum
        and value:find("[%z\1-\31\127]") == nil
end

local function nextInteger(value)
    if not safeInteger(value, 0) or value >= MAX_SAFE_INTEGER then
        return nil
    end
    return value + 1
end

local function guardedField(object, key)
    if object == nil then
        return nil
    end
    local ok, value = pcall(function()
        return object[key]
    end)
    return ok and value or nil
end

local function defaultViewerId(viewer)
    local id = guardedField(viewer, "id")
    if id ~= nil then
        local ok, text = pcall(tostring, id)
        if ok and text ~= "" then
            return text
        end
    end
    local ok, text = pcall(tostring, viewer)
    if ok and text ~= "" and text ~= "nil" then
        return text
    end
    return nil
end

local function copyIdentity(source)
    return {
        providerEpoch = source.providerEpoch,
        producerId = source.producerId,
        producerGeneration = source.producerGeneration,
        localBeamId = source.localBeamId,
        beamGeneration = source.beamGeneration,
        compositeRenderKey = source.compositeRenderKey,
    }
end

function viewer_sync.new(options)
    if type(options) ~= "table" then
        return nil, "invalid_spec"
    end

    local constants = options.constants or default_constants
    local protocol = options.protocol or default_protocol
    local space = options.space or default_space
    local broker = options.broker
    local send_to_viewer = options.sendToViewer
    local list_players = options.listPlayers
    local is_valid_viewer = options.isValidViewer
    local viewer_id = options.viewerId or defaultViewerId
    local retry_now = options.retryNow
    local on_error = options.onError
    local retry_seconds = tonumber(options.retrySeconds)
        or DEFAULT_RETRY_SECONDS
    local max_renderer_session_length =
        tonumber(constants.MAX_RENDERER_SESSION_LENGTH) or 192

    if not boundedString(
            options.providerEpoch,
            constants.MAX_EPOCH_LENGTH
        )
        or type(broker) ~= "table"
        or type(broker.listRenderable) ~= "function"
        or type(broker.drainChanges) ~= "function"
        or type(send_to_viewer) ~= "function"
        or (list_players ~= nil and type(list_players) ~= "function")
        or (is_valid_viewer ~= nil
            and type(is_valid_viewer) ~= "function")
        or type(viewer_id) ~= "function"
        or (retry_now ~= nil and type(retry_now) ~= "function")
        or (on_error ~= nil and type(on_error) ~= "function")
        or not finiteNumber(retry_seconds)
        or retry_seconds < 0
    then
        return nil, "invalid_spec"
    end

    local state = {
        providerEpoch = options.providerEpoch,
        nextViewerSyncGeneration = 0,
        viewersById = {},
    }
    local instance = {}

    local function retryTime(fallback)
        if retry_now ~= nil then
            local ok, value = pcall(retry_now)
            if ok and finiteNumber(value) then
                return value
            end
        end
        return finiteNumber(fallback) and fallback or 0
    end

    local function report(operation, detail)
        if on_error ~= nil then
            pcall(on_error, operation, tostring(detail))
        end
    end

    local function validViewer(viewer)
        if viewer == nil then
            return false
        end
        if is_valid_viewer == nil then
            return true
        end
        local ok, result = pcall(is_valid_viewer, viewer)
        return ok and result == true
    end

    local function identify(viewer)
        if not validViewer(viewer) then
            return nil
        end
        local ok, value = pcall(viewer_id, viewer)
        if not ok or value == nil then
            return nil
        end
        local text = tostring(value)
        if text == "" or #text > 384 then
            return nil
        end
        return text
    end

    local function currentSpaceKey(viewer)
        if not validViewer(viewer) then
            return nil
        end
        local cell = guardedField(viewer, "cell")
        if cell == nil then
            return nil
        end
        local ok, key = pcall(space.spaceKeyForCell, cell)
        if not ok or not space.isValidKey(key) then
            return nil
        end
        return key
    end

    local function send(record, event_name, payload)
        if record == nil or not validViewer(record.object) then
            return false
        end
        local ok, result = pcall(
            send_to_viewer,
            record.object,
            event_name,
            payload
        )
        if not ok or result == false then
            return false
        end
        return true
    end

    local function markForReconcile(record, reason, now)
        if record.needsReconcile then
            return
        end
        record.needsReconcile = true
        record.reconcileReason = reason or "delivery_retry"
        record.retryAt = retryTime(now) + retry_seconds
        if not record.deliveryFailureLogged then
            record.deliveryFailureLogged = true
            report(
                "viewer_delivery",
                tostring(record.id)
                    .. ":"
                    .. tostring(record.reconcileReason)
            )
        end
    end

    local function discover(viewer)
        local id = identify(viewer)
        if id == nil then
            return nil, "invalid_viewer"
        end
        local record = state.viewersById[id]
        if record == nil then
            record = {
                id = id,
                object = viewer,
                ready = false,
                rendererSession = nil,
                lastReadySerial = 0,
                viewerSyncGeneration = 0,
                spaceKey = nil,
                delivered = {},
                tombstoneCount = 0,
                needsReconcile = false,
                deliveryFailureLogged = false,
                reconcileReason = nil,
                retryAt = 0,
            }
            state.viewersById[id] = record
        else
            record.object = viewer
        end
        return record
    end

    local function snapshotPacket(record, beam)
        local identity = copyIdentity(beam)
        identity.source = "beamfx"
        identity.protocolVersion = protocol.VERSION
        identity.rendererSession = record.rendererSession
        identity.viewerSyncGeneration = record.viewerSyncGeneration
        identity.revision = beam.revision
        identity.spaceKey = beam.spaceKey
        identity.priority = beam.priority
        identity.lifecycle = beam.lifecycle
        identity.segments = beam.segments
        return identity
    end

    local function removePacket(record, change)
        local identity = copyIdentity(change)
        identity.source = "beamfx"
        identity.protocolVersion = protocol.VERSION
        identity.rendererSession = record.rendererSession
        identity.viewerSyncGeneration = record.viewerSyncGeneration
        identity.terminalRevision = change.terminalRevision
        identity.reason = change.reason
        return identity
    end

    local function eligible(record, beam)
        return record.ready == true
            and record.rendererSession ~= nil
            and record.spaceKey ~= nil
            and beam.spaceKey == record.spaceKey
            and type(beam.audience) == "table"
            and beam.audience.mode == "same_space"
    end

    local function sendSnapshot(record, beam, now)
        if not eligible(record, beam) then
            return true
        end
        local delivered_revision =
            record.delivered[beam.compositeRenderKey]
        if safeInteger(delivered_revision, 1)
            and delivered_revision >= beam.revision
        then
            return true
        end
        if not send(
            record,
            protocol.events.RENDER_SNAPSHOT,
            snapshotPacket(record, beam)
        ) then
            markForReconcile(record, "snapshot_delivery_failed", now)
            return false
        end
        record.delivered[beam.compositeRenderKey] = beam.revision
        return true
    end

    local function allocateSyncGeneration()
        local generation = nextInteger(state.nextViewerSyncGeneration)
        if generation == nil then
            return nil
        end
        state.nextViewerSyncGeneration = generation
        return generation
    end

    local reconcile
    reconcile = function(record, reason, now)
        if record == nil
            or record.ready ~= true
            or not boundedString(
                record.rendererSession,
                max_renderer_session_length
            )
            or not validViewer(record.object)
        then
            return nil, "viewer_not_ready"
        end

        local generation = allocateSyncGeneration()
        if generation == nil then
            markForReconcile(record, "sync_generation_exhausted", now)
            return nil, "provider_reset"
        end
        local reset_packet = {
            source = "beamfx",
            protocolVersion = protocol.VERSION,
            providerEpoch = state.providerEpoch,
            rendererSession = record.rendererSession,
            newViewerSyncGeneration = generation,
            reason = reason or "viewer_reconcile",
        }
        if not send(
            record,
            protocol.events.VIEWER_RECONCILE_RESET,
            reset_packet
        ) then
            markForReconcile(record, "reconcile_reset_failed", now)
            return nil, "renderer_unavailable"
        end

        record.viewerSyncGeneration = generation
        record.spaceKey = currentSpaceKey(record.object)
        record.delivered = {}
        record.tombstoneCount = 0
        record.needsReconcile = false
        record.deliveryFailureLogged = false
        record.reconcileReason = nil
        record.retryAt = 0

        local beams, err = broker:listRenderable(now)
        if beams == nil then
            markForReconcile(record, "authoritative_state_failed", now)
            return nil, err or "provider_reset"
        end
        for _, beam in ipairs(beams) do
            if eligible(record, beam)
                and not sendSnapshot(record, beam, now)
            then
                return nil, "renderer_unavailable"
            end
        end
        return {
            viewerSyncGeneration = generation,
            deliveredBeams = (function()
                local count = 0
                for _ in pairs(record.delivered) do
                    count = count + 1
                end
                return count
            end)(),
        }
    end

    local function validateHandshake(payload)
        if type(payload) ~= "table"
            or payload.source ~= "beamfx"
            or payload.protocolVersion ~= protocol.VERSION
            or not boundedString(
                payload.rendererSession,
                max_renderer_session_length
            )
            or not safeInteger(payload.readySerial, 1)
            or not safeInteger(
                payload.observedViewerSyncGeneration,
                0
            )
            or (payload.observedProviderEpoch ~= nil
                and not boundedString(
                    payload.observedProviderEpoch,
                    constants.MAX_EPOCH_LENGTH
                ))
            or (payload.spaceKey ~= nil
                and not space.isValidKey(payload.spaceKey))
            or (payload.reason ~= nil
                and not boundedString(
                    payload.reason,
                    constants.MAX_REASON_LENGTH
                ))
            or not validViewer(payload.viewer)
        then
            return nil, "invalid_packet"
        end
        return payload
    end

    local function handleHandshake(payload, force_resync, now)
        local normalized, err = validateHandshake(payload)
        if normalized == nil then
            return nil, err
        end
        local record
        record, err = discover(normalized.viewer)
        if record == nil then
            return nil, err
        end

        local same_session =
            record.rendererSession == normalized.rendererSession
        if same_session
            and normalized.readySerial <= record.lastReadySerial
        then
            return {
                accepted = true,
                idempotent = true,
                stale = normalized.readySerial
                    < record.lastReadySerial,
                viewerSyncGeneration =
                    record.viewerSyncGeneration,
            }
        end

        if not same_session then
            record.rendererSession = normalized.rendererSession
            record.lastReadySerial = 0
            record.viewerSyncGeneration = 0
            record.delivered = {}
            record.tombstoneCount = 0
            record.needsReconcile = false
            record.deliveryFailureLogged = false
        end
        record.lastReadySerial = normalized.readySerial
        record.ready = true
        local actual_space = currentSpaceKey(record.object)
        local already_current = not force_resync
            and same_session
            and record.viewerSyncGeneration >= 1
            and normalized.observedProviderEpoch
                == state.providerEpoch
            and normalized.observedViewerSyncGeneration
                == record.viewerSyncGeneration
            and actual_space == record.spaceKey
            and record.needsReconcile ~= true

        -- The transmitted key is a diagnostic hint only. Player and global
        -- contexts can sample a cell transition on adjacent frames, so a
        -- mismatch is expected and is not an internal error. The routing
        -- decision always uses the live global player object.

        if already_current then
            return {
                accepted = true,
                idempotent = true,
                viewerSyncGeneration =
                    record.viewerSyncGeneration,
            }
        end

        if normalized.observedProviderEpoch ~= state.providerEpoch then
            local reset_packet = {
                source = "beamfx",
                protocolVersion = protocol.VERSION,
                oldProviderEpoch =
                    normalized.observedProviderEpoch,
                newProviderEpoch = state.providerEpoch,
                reason = "viewer_epoch_recovery",
            }
            if not send(
                record,
                protocol.events.PROVIDER_RESET,
                reset_packet
            ) then
                markForReconcile(
                    record,
                    "provider_reset_delivery_failed",
                    now
                )
                return nil, "renderer_unavailable"
            end
        end

        local result
        result, err = reconcile(
            record,
            force_resync
                    and (normalized.reason or "viewer_resync")
                or (normalized.reason or "viewer_ready"),
            now
        )
        if result == nil then
            return nil, err
        end
        result.accepted = true
        result.idempotent = false
        return result
    end

    local function collectPlayers()
        if list_players == nil then
            return {}, false
        end
        local ok, players = pcall(list_players)
        if not ok or players == nil then
            report("world_player_sweep", players)
            return {}, false
        end
        local result = {}
        local iter_ok, iter_err = pcall(function()
            for _, viewer in ipairs(players) do
                result[#result + 1] = viewer
            end
        end)
        if not iter_ok then
            report("world_player_sweep", iter_err)
            return {}, false
        end
        return result, true
    end

    local function sweep(now)
        local players, complete = collectPlayers()
        local seen = {}
        for _, viewer in ipairs(players) do
            local record = discover(viewer)
            if record ~= nil then
                seen[record.id] = true
                if record.ready then
                    local actual_space = currentSpaceKey(record.object)
                    if actual_space ~= record.spaceKey then
                        reconcile(
                            record,
                            "viewer_space_changed",
                            now
                        )
                    elseif record.needsReconcile
                        and retryTime(now) >= record.retryAt
                    then
                        reconcile(
                            record,
                            record.reconcileReason
                                or "delivery_retry",
                            now
                        )
                    end
                end
            end
        end
        if complete then
            for id in pairs(state.viewersById) do
                if not seen[id] then
                    state.viewersById[id] = nil
                end
            end
        end
    end

    local function processSnapshot(change, now)
        local beam = change.beam
        for _, record in pairs(state.viewersById) do
            if record.ready
                and not record.needsReconcile
                and eligible(record, beam)
            then
                sendSnapshot(record, beam, now)
            end
        end
    end

    local function processRemove(change, now)
        for _, record in pairs(state.viewersById) do
            if record.ready
                and not record.needsReconcile
                and record.delivered[change.compositeRenderKey] ~= nil
            then
                if record.tombstoneCount + 1
                    >= constants.MAX_TOMBSTONES_PER_VIEWER
                then
                    reconcile(
                        record,
                        "renderer_tombstone_pressure",
                        now
                    )
                elseif send(
                    record,
                    protocol.events.RENDER_REMOVE,
                    removePacket(record, change)
                ) then
                    record.delivered[change.compositeRenderKey] = nil
                    record.tombstoneCount =
                        record.tombstoneCount + 1
                else
                    markForReconcile(
                        record,
                        "remove_delivery_failed",
                        now
                    )
                end
            end
        end
    end

    instance.discover = function(first, second)
        return discover(first == instance and second or first)
    end
    instance.onPlayerAdded = instance.discover

    instance.handleReady = function(first, second, third)
        local payload
        local now
        if first == instance then
            payload = second
            now = third
        else
            payload = first
            now = second
        end
        return handleHandshake(payload, false, now)
    end

    instance.handleResync = function(first, second, third)
        local payload
        local now
        if first == instance then
            payload = second
            now = third
        else
            payload = first
            now = second
        end
        return handleHandshake(payload, true, now)
    end

    instance.reconcile = function(first, second, third, fourth)
        local viewer
        local reason
        local now
        if first == instance then
            viewer = second
            reason = third
            now = fourth
        else
            viewer = first
            reason = second
            now = third
        end
        local record = type(viewer) == "table"
                and viewer.id
                and state.viewersById[tostring(viewer.id)]
            or nil
        if record == nil then
            local id = type(viewer) == "string" and viewer
                or identify(viewer)
            record = id and state.viewersById[id] or nil
        end
        return reconcile(record, reason, now)
    end

    instance.update = function(first, second)
        local now
        if first == instance then
            now = second
        else
            now = first
        end
        if now ~= nil and not finiteNumber(now) then
            return nil, "provider_reset"
        end
        sweep(now)
        local changes, err = broker:drainChanges(now)
        if changes == nil then
            return nil, err or "provider_reset"
        end
        for _, change in ipairs(changes) do
            if change.kind == "remove" then
                processRemove(change, now)
            elseif change.kind == "snapshot"
                and type(change.beam) == "table"
            then
                processSnapshot(change, now)
            end
        end
        return {
            processedChanges = #changes,
        }
    end

    instance.providerReset = function(first, second, third, fourth)
        local old_epoch
        local new_epoch
        local reason
        if first == instance then
            old_epoch = second
            new_epoch = third
            reason = fourth
        else
            old_epoch = first
            new_epoch = second
            reason = third
        end
        if (old_epoch ~= nil
                and not boundedString(
                    old_epoch,
                    constants.MAX_EPOCH_LENGTH
                ))
            or not boundedString(
                new_epoch,
                constants.MAX_EPOCH_LENGTH
            )
            or old_epoch == new_epoch
            or (reason ~= nil
                and not boundedString(
                    reason,
                    constants.MAX_REASON_LENGTH
                ))
        then
            return nil, "invalid_spec"
        end

        local packet = {
            source = "beamfx",
            protocolVersion = protocol.VERSION,
            oldProviderEpoch = old_epoch,
            newProviderEpoch = new_epoch,
            reason = reason or "provider_reset",
        }
        local recipients = {}
        local players = collectPlayers()
        for _, viewer in ipairs(players) do
            local record = discover(viewer)
            if record ~= nil then
                recipients[record.id] = record
            end
        end
        for id, record in pairs(state.viewersById) do
            recipients[id] = record
        end

        local sent = 0
        for _, record in pairs(recipients) do
            if send(record, protocol.events.PROVIDER_RESET, packet) then
                sent = sent + 1
            end
        end

        state.providerEpoch = new_epoch
        state.nextViewerSyncGeneration = 0
        for _, record in pairs(state.viewersById) do
            record.viewerSyncGeneration = 0
            record.delivered = {}
            record.tombstoneCount = 0
            record.needsReconcile = false
            record.deliveryFailureLogged = false
            if record.ready and record.rendererSession ~= nil then
                reconcile(
                    record,
                    reason or "provider_reset",
                    nil
                )
            end
        end
        return {
            recipients = sent,
            providerEpoch = new_epoch,
        }
    end

    instance.status = function()
        local viewers = 0
        local ready = 0
        local delivered = 0
        local tombstones = 0
        for _, record in pairs(state.viewersById) do
            viewers = viewers + 1
            if record.ready then
                ready = ready + 1
            end
            tombstones = tombstones + record.tombstoneCount
            for _ in pairs(record.delivered) do
                delivered = delivered + 1
            end
        end
        return {
            providerEpoch = state.providerEpoch,
            viewers = viewers,
            readyViewers = ready,
            deliveredBeams = delivered,
            tombstones = tombstones,
            nextViewerSyncGeneration =
                state.nextViewerSyncGeneration,
        }
    end

    return instance
end

viewer_sync.create = viewer_sync.new

return viewer_sync
