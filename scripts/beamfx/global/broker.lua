---@omw-context global | none

local default_constants = require("scripts.beamfx.shared.constants")
local default_protocol = require("scripts.beamfx.shared.protocol")
local default_validation = require("scripts.beamfx.shared.validation")

local broker = {}

local MAX_SAFE_INTEGER = 9007199254740991

local function newDiagnostics()
    return {
        successfulMutations = 0,
        acceptedSegments = 0,
        invalidRequests = 0,
        createdBeamGenerations = 0,
        removedBeamGenerations = 0,
    }
end

local function boundedEpoch(value, constants)
    return type(value) == "string"
        and value ~= ""
        and #value <= constants.MAX_EPOCH_LENGTH
        and value:find("[%z\1-\31\127]") == nil
end

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function nextInteger(value)
    value = tonumber(value) or 0
    if value < 0
        or value ~= math.floor(value)
        or value >= MAX_SAFE_INTEGER
    then
        return nil
    end
    return value + 1
end

local function sortedKeys(value)
    local result = {}
    for key in pairs(value) do
        result[#result + 1] = key
    end
    table.sort(result)
    return result
end

local function copyVector(value)
    return {
        x = value.x,
        y = value.y,
        z = value.z,
    }
end

local function copyColor(value)
    return { value[1], value[2], value[3] }
end

local function copyLongitudinal(value)
    if value.mode == "solid" then
        return {
            mode = value.mode,
            pathOffset = value.pathOffset,
        }
    end
    if value.mode == "travel" then
        return {
            mode = value.mode,
            pathOffset = value.pathOffset,
            visibleLength = value.visibleLength,
            speed = value.speed,
            headFadeLength = value.headFadeLength,
            tailFadeLength = value.tailFadeLength,
            loop = value.loop == true,
            loopLength = value.loopLength,
            loopDelay = value.loopDelay,
        }
    end
    if value.mode == "pulse" then
        return {
            mode = value.mode,
            pathOffset = value.pathOffset,
            period = value.period,
            pulseLength = value.pulseLength,
            speed = value.speed,
            carrierLevel = value.carrierLevel,
            fadeLength = value.fadeLength,
        }
    end
    return {
        mode = value.mode,
        pathOffset = value.pathOffset,
        dashLength = value.dashLength,
        gapLength = value.gapLength,
        speed = value.speed,
        fadeLength = value.fadeLength,
    }
end

local function copyAudience(value)
    return { mode = value.mode }
end

local function copyLifecycleForPacket(value)
    return {
        mode = value.mode,
        state = value.state,
        createdAt = value.createdAt,
        fadeStartAt = value.fadeStartAt,
        expiresAt = value.expiresAt,
    }
end

local function copySegmentForPacket(value)
    return {
        startPos = copyVector(value.startPos),
        endPos = copyVector(value.endPos),
        startRadius = value.startRadius,
        endRadius = value.endRadius,
        minPixelWidth = value.minPixelWidth,
        outerColor = copyColor(value.outerColor),
        coreColor = copyColor(value.coreColor),
        coreRatio = value.coreRatio,
        intensity = value.intensity,
        opacity = value.opacity,
        baseColor = copyColor(value.baseColor),
        baseOpacity = value.baseOpacity,
        startFadeLength = value.startFadeLength,
        endFadeLength = value.endFadeLength,
        depthSoftness = value.depthSoftness,
        fogInfluence = value.fogInfluence,
        style = value.style,
        styleScale = value.styleScale,
        seed = value.seed,
        originGlow = value.originGlow == true,
        longitudinal = copyLongitudinal(value.longitudinal),
        createdAt = value.createdAt,
        fadeStartAt = value.fadeStartAt,
        expiresAt = value.expiresAt,
    }
end

-- This deliberately avoids bit libraries and multiplications large enough to
-- lose integer precision in Lua numbers. It is deterministic, not secret.
local function stableHash(value)
    local text = tostring(value or "")
    local hash = 5381
    for index = 1, #text do
        hash = (hash * 131 + text:byte(index)) % 2147483647
    end
    return hash
end

local function defaultSeed(beam, segment)
    local hash = stableHash(
        beam.compositeRenderKey .. "|" .. tostring(segment.internalSerial)
    )
    if segment.style == "plasma" then
        return (hash % 15) + 1
    end
    return hash % 16
end

local function sameAudience(left, right)
    return left ~= nil
        and right ~= nil
        and left.mode == right.mode
end

local function identityCopy(beam)
    return {
        providerEpoch = beam.providerEpoch,
        producerId = beam.producerId,
        producerGeneration = beam.producerGeneration,
        localBeamId = beam.localBeamId,
        beamGeneration = beam.beamGeneration,
        compositeRenderKey = beam.compositeRenderKey,
    }
end

function broker.new(options)
    if type(options) ~= "table" then
        return nil, "invalid_spec"
    end

    local constants = options.constants or default_constants
    local protocol = options.protocol or default_protocol
    local validation = options.validation or default_validation
    local now_fn = options.now
    local on_error = options.onError

    if not boundedEpoch(options.providerEpoch, constants)
        or type(now_fn) ~= "function"
        or (on_error ~= nil and type(on_error) ~= "function")
    then
        return nil, "invalid_spec"
    end

    local state = {
        providerEpoch = options.providerEpoch,
        producers = {},
        beamsByKey = {},
        totalBeams = 0,
        totalSegments = 0,
        updateSerial = 0,
        pendingChanges = {},
        diagnostics = newDiagnostics(),
    }
    local instance = {}

    local function report(operation, detail)
        if on_error ~= nil then
            pcall(on_error, operation, tostring(detail))
        end
    end

    local function currentTime()
        local ok, value = pcall(now_fn)
        if not ok or not finiteNumber(value) then
            report("simulation_time", value)
            return nil, "provider_reset"
        end
        return value
    end

    local function producerKey(producer_state)
        return protocol.producerKey({
            producerId = producer_state.producerId,
            producerGeneration = producer_state.producerGeneration,
        })
    end

    local function validProducerState(producer_state)
        return type(producer_state) == "table"
            and producer_state.providerEpoch == state.providerEpoch
            and type(producer_state.producerId) == "string"
            and producer_state.producerId ~= ""
            and type(producer_state.producerGeneration) == "number"
            and producer_state.producerGeneration >= 1
            and producer_state.producerGeneration
                == math.floor(producer_state.producerGeneration)
    end

    local function synchronizeRegistryState(record)
        local registry_state = record.registryState
        if type(registry_state) == "table" then
            registry_state.beamCount = record.beamCount
            registry_state.segmentCount = record.segmentCount
        end
    end

    local function ensureProducer(producer_state)
        if not validProducerState(producer_state) then
            return nil, "stale_producer"
        end
        local key = producerKey(producer_state)
        if key == nil then
            return nil, "stale_producer"
        end
        local record = state.producers[key]
        if record == nil then
            record = {
                key = key,
                providerEpoch = state.providerEpoch,
                producerId = producer_state.producerId,
                producerGeneration = producer_state.producerGeneration,
                displayName = producer_state.displayName,
                beamsById = {},
                nextBeamGeneration = 0,
                beamCount = 0,
                segmentCount = 0,
                diagnostics = newDiagnostics(),
                registryState = producer_state,
            }
            state.producers[key] = record
        else
            record.registryState = producer_state
        end
        synchronizeRegistryState(record)
        return record
    end

    local function queueSnapshot(beam, classification)
        local existing = state.pendingChanges[beam.compositeRenderKey]
        if existing ~= nil and existing.kind == "remove" then
            return
        end
        state.pendingChanges[beam.compositeRenderKey] = {
            kind = "snapshot",
            classification = classification == "finish"
                    and "finish"
                or (existing and existing.classification)
                or "ordinary",
            compositeRenderKey = beam.compositeRenderKey,
        }
    end

    local function queueRemove(beam, terminal_revision, reason)
        local value = identityCopy(beam)
        value.kind = "remove"
        value.terminalRevision = terminal_revision
        value.reason = reason
        state.pendingChanges[beam.compositeRenderKey] = value
    end

    local function checkQuotas(record, beam_delta, segment_delta)
        local producer_beams = record.beamCount + beam_delta
        local global_beams = state.totalBeams + beam_delta
        if producer_beams > constants.MAX_BEAMS_PER_PRODUCER
            or global_beams > constants.MAX_BEAMS_GLOBAL
        then
            return nil, "producer_quota_exceeded"
        end

        local producer_segments = record.segmentCount + segment_delta
        local global_segments = state.totalSegments + segment_delta
        if producer_segments > constants.MAX_RETAINED_SEGMENTS_PER_PRODUCER
            or global_segments > constants.MAX_RETAINED_SEGMENTS_GLOBAL
        then
            return nil, "segment_quota_exceeded"
        end
        if producer_beams < 0
            or global_beams < 0
            or producer_segments < 0
            or global_segments < 0
        then
            report("quota_accounting", "negative_count")
            return nil, "provider_reset"
        end
        return true
    end

    local function addBeam(record, beam)
        record.beamsById[beam.localBeamId] = beam
        state.beamsByKey[beam.compositeRenderKey] = beam
        record.beamCount = record.beamCount + 1
        record.segmentCount = record.segmentCount + #beam.segments
        state.totalBeams = state.totalBeams + 1
        state.totalSegments = state.totalSegments + #beam.segments
        synchronizeRegistryState(record)
    end

    local function removeBeam(record, beam, reason)
        local terminal_revision = nextInteger(beam.revision)
        if terminal_revision == nil then
            return nil, "provider_reset"
        end
        queueRemove(beam, terminal_revision, reason)
        record.beamsById[beam.localBeamId] = nil
        state.beamsByKey[beam.compositeRenderKey] = nil
        record.beamCount = record.beamCount - 1
        record.segmentCount = record.segmentCount - #beam.segments
        state.totalBeams = state.totalBeams - 1
        state.totalSegments = state.totalSegments - #beam.segments
        state.diagnostics.removedBeamGenerations =
            state.diagnostics.removedBeamGenerations + 1
        record.diagnostics.removedBeamGenerations =
            record.diagnostics.removedBeamGenerations + 1
        synchronizeRegistryState(record)
        return terminal_revision
    end

    local function makeLifecycle(normalized, now)
        if normalized.mode == "transient" then
            return {
                mode = "transient",
                state = "active",
                createdAt = now,
                fadeStartAt = now
                    + math.max(0, normalized.duration - normalized.fadeDuration),
                expiresAt = now + normalized.duration,
                leaseSeconds = nil,
                leaseExpiresAt = nil,
            }
        end
        return {
            mode = "persistent",
            state = "active",
            createdAt = now,
            fadeStartAt = nil,
            expiresAt = nil,
            leaseSeconds = normalized.leaseSeconds,
            leaseExpiresAt = normalized.leaseSeconds
                    and (now + normalized.leaseSeconds)
                or nil,
        }
    end

    local function stampSegment(normalized, beam, now, serial)
        local value = {
            startPos = copyVector(normalized.startPos),
            endPos = copyVector(normalized.endPos),
            startRadius = normalized.startRadius,
            endRadius = normalized.endRadius,
            minPixelWidth = normalized.minPixelWidth,
            outerColor = copyColor(normalized.outerColor),
            coreColor = copyColor(normalized.coreColor),
            coreRatio = normalized.coreRatio,
            intensity = normalized.intensity,
            opacity = normalized.opacity,
            baseColor = copyColor(normalized.baseColor),
            baseOpacity = normalized.baseOpacity,
            startFadeLength = normalized.startFadeLength,
            endFadeLength = normalized.endFadeLength,
            depthSoftness = normalized.depthSoftness,
            fogInfluence = normalized.fogInfluence,
            style = normalized.style,
            styleScale = normalized.styleScale,
            seed = normalized.seed,
            originGlow = normalized.originGlow == true,
            longitudinal = copyLongitudinal(normalized.longitudinal),
            internalSerial = serial,
            createdAt = now,
            fadeStartAt = nil,
            expiresAt = nil,
        }
        if normalized.duration ~= nil then
            value.fadeStartAt = now
                + math.max(0, normalized.duration - normalized.fadeDuration)
            value.expiresAt = now + normalized.duration
        end
        if value.seed == nil then
            value.seed = defaultSeed(beam, value)
        end
        return value
    end

    local function stampSegments(normalized, beam, now, starting_serial)
        local result = {}
        local serial = starting_serial
        for index, source in ipairs(normalized) do
            serial = nextInteger(serial)
            if serial == nil then
                return nil, nil, "provider_reset"
            end
            result[index] = stampSegment(source, beam, now, serial)
        end
        return result, serial
    end

    local function newBeam(record, local_beam_id, normalized, now, generation)
        local identity = {
            providerEpoch = state.providerEpoch,
            producerId = record.producerId,
            producerGeneration = record.producerGeneration,
            localBeamId = local_beam_id,
            beamGeneration = generation,
        }
        local composite_key = protocol.compositeRenderKey(identity)
        if composite_key == nil then
            return nil, "provider_reset"
        end
        local value = {
            providerEpoch = identity.providerEpoch,
            producerId = identity.producerId,
            producerGeneration = identity.producerGeneration,
            localBeamId = identity.localBeamId,
            beamGeneration = identity.beamGeneration,
            compositeRenderKey = composite_key,
            revision = 1,
            spaceKey = normalized.spaceKey,
            audience = copyAudience(normalized.audience),
            priority = normalized.priority,
            maxSegments = normalized.maxSegments,
            lifecycle = makeLifecycle(normalized.lifecycle, now),
            animationStartedAt = now,
            segments = {},
            nextSegmentSerial = 0,
            status = "active",
            pendingExpiryUpdate = nil,
        }
        local segments, next_serial, err = stampSegments(
            normalized.segments,
            value,
            now,
            0
        )
        if segments == nil then
            return nil, err
        end
        value.segments = segments
        value.nextSegmentSerial = next_serial
        return value
    end

    local function transientNaturallyExpired(beam, now)
        return beam.lifecycle.mode == "transient"
            and beam.lifecycle.state == "active"
            and beam.lifecycle.expiresAt ~= nil
            and now >= beam.lifecycle.expiresAt
    end

    local function rejectsOrdinaryMutation(beam, now)
        return beam.status ~= "active"
            or beam.lifecycle.state == "finishing"
            or transientNaturallyExpired(beam, now)
    end

    local function renewConfiguredLease(beam, now)
        if beam.lifecycle.mode == "persistent"
            and beam.lifecycle.leaseSeconds ~= nil
        then
            beam.lifecycle.leaseExpiresAt = now + beam.lifecycle.leaseSeconds
        end
    end

    local function normalizeBeamId(value)
        return validation.normalizeBeamId(value)
    end

    local function upsert(record, local_beam_id, spec)
        local normalized_id, err = normalizeBeamId(local_beam_id)
        if normalized_id == nil then
            return nil, err
        end
        local normalized
        local detail
        normalized, err, detail = validation.normalizeBeamSpec(spec)
        if normalized == nil then
            return nil, err, detail
        end
        local now
        now, err = currentTime()
        if now == nil then
            return nil, err
        end

        local current = record.beamsById[normalized_id]
        local starts_new_generation = current == nil
            or current.status ~= "active"
            or current.lifecycle.state == "finishing"
            or transientNaturallyExpired(current, now)

        if current ~= nil and not starts_new_generation then
            if current.spaceKey ~= normalized.spaceKey
                or not sameAudience(current.audience, normalized.audience)
            then
                return nil, "invalid_spec"
            end
            local revision = nextInteger(current.revision)
            if revision == nil then
                return nil, "provider_reset"
            end
            local candidate = {
                compositeRenderKey = current.compositeRenderKey,
            }
            local segments, next_serial
            segments, next_serial, err = stampSegments(
                normalized.segments,
                current,
                now,
                current.nextSegmentSerial
            )
            if segments == nil then
                return nil, err
            end
            local segment_delta = #segments - #current.segments
            local ok
            ok, err = checkQuotas(record, 0, segment_delta)
            if not ok then
                return nil, err
            end

            record.segmentCount = record.segmentCount + segment_delta
            state.totalSegments = state.totalSegments + segment_delta
            current.revision = revision
            current.priority = normalized.priority
            current.maxSegments = normalized.maxSegments
            current.lifecycle = makeLifecycle(normalized.lifecycle, now)
            current.animationStartedAt = now
            current.segments = segments
            current.nextSegmentSerial = next_serial
            current.status = "active"
            current.pendingExpiryUpdate = nil
            synchronizeRegistryState(record)
            queueSnapshot(current, "ordinary")
            return {
                id = normalized_id,
                producerGeneration = record.producerGeneration,
                beamGeneration = current.beamGeneration,
                revision = current.revision,
                acceptedSegments = #segments,
                retainedSegments = #segments,
                created = false,
            }
        end

        local generation = nextInteger(record.nextBeamGeneration)
        if generation == nil then
            return nil, "provider_reset"
        end
        local candidate
        candidate, err = newBeam(
            record,
            normalized_id,
            normalized,
            now,
            generation
        )
        if candidate == nil then
            return nil, err
        end
        local beam_delta = current == nil and 1 or 0
        local segment_delta = #candidate.segments
            - (current and #current.segments or 0)
        local ok
        ok, err = checkQuotas(record, beam_delta, segment_delta)
        if not ok then
            return nil, err
        end

        if current ~= nil then
            local removed
            removed, err = removeBeam(
                record,
                current,
                "superseded_by_upsert"
            )
            if removed == nil then
                return nil, err
            end
        end
        record.nextBeamGeneration = generation
        addBeam(record, candidate)
        queueSnapshot(candidate, "ordinary")
        return {
            id = normalized_id,
            producerGeneration = record.producerGeneration,
            beamGeneration = candidate.beamGeneration,
            revision = candidate.revision,
            acceptedSegments = #candidate.segments,
            retainedSegments = #candidate.segments,
            created = true,
        }
    end

    -- The facade generates emit IDs. Refusing an occupied ID here makes the
    -- uniqueness check atomic with insertion and prevents accidental upsert.
    local function emit(record, local_beam_id, spec)
        local normalized_id, err = normalizeBeamId(local_beam_id)
        if normalized_id == nil then
            return nil, err
        end
        if record.beamsById[normalized_id] ~= nil then
            return nil, "beam_id_in_use", {
                path = "",
                reason = "generated_id_collision",
                message = "The generated emit ID is already in use.",
            }
        end
        return upsert(record, normalized_id, spec)
    end

    local function replaceSegments(record, local_beam_id, segments, options)
        local normalized_id, err = normalizeBeamId(local_beam_id)
        if normalized_id == nil then
            return nil, err
        end
        local beam = record.beamsById[normalized_id]
        if beam == nil then
            return nil, "beam_not_found"
        end
        local now
        now, err = currentTime()
        if now == nil then
            return nil, err
        end
        if rejectsOrdinaryMutation(beam, now) then
            return nil, "beam_finishing"
        end

        local normalized
        local detail
        normalized, err, detail = validation.normalizeSegments(
            segments,
            beam.maxSegments,
            options
        )
        if normalized == nil then
            return nil, err, detail
        end
        local stamped, next_serial
        stamped, next_serial, err = stampSegments(
            normalized,
            beam,
            now,
            beam.nextSegmentSerial
        )
        if stamped == nil then
            return nil, err
        end
        local revision = nextInteger(beam.revision)
        if revision == nil then
            return nil, "provider_reset"
        end
        local segment_delta = #stamped - #beam.segments
        local ok
        ok, err = checkQuotas(record, 0, segment_delta)
        if not ok then
            return nil, err
        end

        record.segmentCount = record.segmentCount + segment_delta
        state.totalSegments = state.totalSegments + segment_delta
        beam.segments = stamped
        beam.nextSegmentSerial = next_serial
        beam.revision = revision
        renewConfiguredLease(beam, now)
        synchronizeRegistryState(record)
        queueSnapshot(beam, "ordinary")
        return {
            id = normalized_id,
            beamGeneration = beam.beamGeneration,
            revision = beam.revision,
            acceptedSegments = #stamped,
            retainedSegments = #stamped,
        }
    end

    local function appendSegments(record, local_beam_id, segments, options)
        local normalized_id, err = normalizeBeamId(local_beam_id)
        if normalized_id == nil then
            return nil, err
        end
        local beam = record.beamsById[normalized_id]
        if beam == nil then
            return nil, "beam_not_found"
        end
        local now
        now, err = currentTime()
        if now == nil then
            return nil, err
        end
        if rejectsOrdinaryMutation(beam, now) then
            return nil, "beam_finishing"
        end

        local normalized
        local detail
        normalized, err, detail = validation.normalizeSegments(
            segments,
            beam.maxSegments,
            options
        )
        if normalized == nil then
            return nil, err, detail
        end
        local stamped, next_serial
        stamped, next_serial, err = stampSegments(
            normalized,
            beam,
            now,
            beam.nextSegmentSerial
        )
        if stamped == nil then
            return nil, err
        end

        local evicted = math.max(
            0,
            #beam.segments + #stamped - beam.maxSegments
        )
        local retained_count = #beam.segments - evicted + #stamped
        local segment_delta = retained_count - #beam.segments
        local ok
        ok, err = checkQuotas(record, 0, segment_delta)
        if not ok then
            return nil, err
        end
        local revision = nextInteger(beam.revision)
        if revision == nil then
            return nil, "provider_reset"
        end

        local retained = {}
        for index = evicted + 1, #beam.segments do
            retained[#retained + 1] = beam.segments[index]
        end
        for _, segment in ipairs(stamped) do
            retained[#retained + 1] = segment
        end

        record.segmentCount = record.segmentCount + segment_delta
        state.totalSegments = state.totalSegments + segment_delta
        beam.segments = retained
        beam.nextSegmentSerial = next_serial
        beam.revision = revision
        renewConfiguredLease(beam, now)
        synchronizeRegistryState(record)
        queueSnapshot(beam, "ordinary")
        return {
            id = normalized_id,
            beamGeneration = beam.beamGeneration,
            revision = beam.revision,
            acceptedSegments = #stamped,
            retainedSegments = #retained,
            evictedSegments = evicted,
        }
    end

    local function renew(record, local_beam_id, lease_seconds)
        local normalized_id, err = normalizeBeamId(local_beam_id)
        if normalized_id == nil then
            return nil, err
        end
        local beam = record.beamsById[normalized_id]
        if beam == nil then
            return nil, "beam_not_found"
        end
        local now
        now, err = currentTime()
        if now == nil then
            return nil, err
        end
        if rejectsOrdinaryMutation(beam, now) then
            return nil, "beam_finishing"
        end
        if beam.lifecycle.mode ~= "persistent"
            or beam.lifecycle.leaseSeconds == nil
        then
            return nil, "lease_not_enabled"
        end
        local normalized
        normalized, err = validation.normalizeLeaseSeconds(lease_seconds)
        if err ~= nil then
            return nil, err
        end
        local revision = nextInteger(beam.revision)
        if revision == nil then
            return nil, "provider_reset"
        end
        beam.lifecycle.leaseExpiresAt = now
            + (normalized or beam.lifecycle.leaseSeconds)
        beam.revision = revision
        return {
            id = normalized_id,
            beamGeneration = beam.beamGeneration,
            revision = beam.revision,
            leaseExpiresAt = beam.lifecycle.leaseExpiresAt,
        }
    end

    local function finish(record, local_beam_id, options)
        local normalized_id, err = normalizeBeamId(local_beam_id)
        if normalized_id == nil then
            return nil, err
        end
        local beam = record.beamsById[normalized_id]
        if beam == nil then
            return nil, "beam_not_found"
        end
        if beam.lifecycle.state == "finishing" then
            return {
                id = normalized_id,
                beamGeneration = beam.beamGeneration,
                revision = beam.revision,
                finishing = true,
                idempotent = true,
            }
        end
        local normalized
        normalized, err = validation.normalizeFinishOptions(options)
        if normalized == nil then
            return nil, err
        end
        local now
        now, err = currentTime()
        if now == nil then
            return nil, err
        end
        local revision = nextInteger(beam.revision)
        if revision == nil then
            return nil, "provider_reset"
        end

        -- A consumer can call finish at the exact natural-expiry boundary or
        -- after a provider-first update observes frame overshoot. The pending
        -- state is the broker's bounded one-update handoff. A segment ending
        -- at the old beam deadline belongs to that terminal handoff and may
        -- be restamped; earlier-expired geometry must never be revived.
        local natural_expiry_handoff = beam.lifecycle.mode == "transient"
            and beam.lifecycle.state == "active"
            and beam.lifecycle.expiresAt ~= nil
            and (
                now == beam.lifecycle.expiresAt
                or beam.status == "pending_natural_expiry"
            )
        local alive_segments = {}
        for _, segment in ipairs(beam.segments) do
            local at_natural_deadline = natural_expiry_handoff
                and segment.expiresAt == beam.lifecycle.expiresAt
            if segment.expiresAt == nil
                or now < segment.expiresAt
                or at_natural_deadline
            then
                alive_segments[#alive_segments + 1] = segment
            end
        end
        local pruned_segments = #beam.segments - #alive_segments
        if pruned_segments > 0 then
            record.segmentCount =
                record.segmentCount - pruned_segments
            state.totalSegments =
                state.totalSegments - pruned_segments
            beam.segments = alive_segments
            synchronizeRegistryState(record)
        end

        local fade_start_at = now + normalized.holdDuration
        local expires_at = fade_start_at + normalized.fadeDuration
        beam.revision = revision
        beam.status = "finishing"
        beam.pendingExpiryUpdate = nil
        beam.lifecycle.state = "finishing"
        beam.lifecycle.createdAt = now
        beam.lifecycle.fadeStartAt = fade_start_at
        beam.lifecycle.expiresAt = expires_at
        beam.lifecycle.leaseExpiresAt = nil
        for _, segment in ipairs(beam.segments) do
            segment.createdAt = now
            segment.fadeStartAt = fade_start_at
            segment.expiresAt = expires_at
        end
        queueSnapshot(beam, "finish")
        return {
            id = normalized_id,
            beamGeneration = beam.beamGeneration,
            revision = beam.revision,
            finishing = true,
            idempotent = false,
        }
    end

    local function remove(record, local_beam_id, reason)
        local normalized_id, err = normalizeBeamId(local_beam_id)
        if normalized_id == nil then
            return nil, err
        end
        local normalized_reason
        normalized_reason, err = validation.normalizeReason(reason, "removed")
        if err ~= nil then
            return nil, err
        end
        local beam = record.beamsById[normalized_id]
        if beam == nil then
            return {
                id = normalized_id,
                removed = false,
                idempotent = true,
                beamGeneration = nil,
                terminalRevision = nil,
            }
        end
        local now
        now, err = currentTime()
        if now == nil then
            return nil, err
        end
        if rejectsOrdinaryMutation(beam, now) then
            return nil, "beam_finishing"
        end
        local generation = beam.beamGeneration
        local terminal_revision
        terminal_revision, err = removeBeam(
            record,
            beam,
            normalized_reason
        )
        if terminal_revision == nil then
            return nil, err
        end
        return {
            id = normalized_id,
            removed = true,
            idempotent = false,
            beamGeneration = generation,
            terminalRevision = terminal_revision,
        }
    end

    local function removeAll(record, reason)
        local removed_beams = 0
        local removed_segments = 0
        local ids = sortedKeys(record.beamsById)
        for _, local_id in ipairs(ids) do
            local beam = record.beamsById[local_id]
            if beam ~= nil then
                local segment_count = #beam.segments
                local terminal_revision, err = removeBeam(
                    record,
                    beam,
                    reason
                )
                if terminal_revision == nil then
                    return nil, err
                end
                removed_beams = removed_beams + 1
                removed_segments = removed_segments + segment_count
            end
        end
        return {
            removedBeams = removed_beams,
            removedSegments = removed_segments,
        }
    end

    local function clear(record, reason)
        local normalized_reason, err = validation.normalizeReason(
            reason,
            "producer_clear"
        )
        if err ~= nil then
            return nil, err
        end
        return removeAll(record, normalized_reason)
    end

    local function release(record, reason)
        local normalized_reason, err = validation.normalizeReason(
            reason,
            "producer_release"
        )
        if err ~= nil then
            return nil, err
        end
        local result
        result, err = removeAll(record, normalized_reason)
        if result == nil then
            return nil, err
        end
        state.producers[record.key] = nil
        return {
            released = true,
            removedBeams = result.removedBeams,
            removedSegments = result.removedSegments,
        }
    end

    local function producerStats(record)
        return {
            producerId = record.producerId,
            producerGeneration = record.producerGeneration,
            activeBeams = record.beamCount,
            retainedSegments = record.segmentCount,
            limits = {
                activeBeams = constants.MAX_BEAMS_PER_PRODUCER,
                retainedSegments = constants.MAX_RETAINED_SEGMENTS_PER_PRODUCER,
            },
            cumulative = {
                successfulMutations =
                    record.diagnostics.successfulMutations,
                acceptedSegments =
                    record.diagnostics.acceptedSegments,
                invalidRequests =
                    record.diagnostics.invalidRequests,
                createdBeamGenerations =
                    record.diagnostics.createdBeamGenerations,
                removedBeamGenerations =
                    record.diagnostics.removedBeamGenerations,
            },
        }
    end

    local operations = {
        upsert = upsert,
        emit = emit,
        replaceSegments = replaceSegments,
        appendSegments = appendSegments,
        renew = renew,
        finish = finish,
        remove = remove,
        clear = clear,
        release = release,
        stats = producerStats,
    }

    local function recordInvalidRequest(record)
        state.diagnostics.invalidRequests =
            state.diagnostics.invalidRequests + 1
        if record ~= nil then
            record.diagnostics.invalidRequests =
                record.diagnostics.invalidRequests + 1
        end
    end

    local function resultMutated(operation, result)
        if operation == "upsert"
            or operation == "emit"
            or operation == "replaceSegments"
            or operation == "appendSegments"
            or operation == "renew"
            or operation == "release"
        then
            return true
        end
        if operation == "finish" then
            return result.idempotent ~= true
        end
        if operation == "remove" then
            return result.removed == true
        end
        if operation == "clear" then
            return (tonumber(result.removedBeams) or 0) > 0
        end
        return false
    end

    local function recordSuccessfulResult(record, operation, result)
        if resultMutated(operation, result) then
            state.diagnostics.successfulMutations =
                state.diagnostics.successfulMutations + 1
            record.diagnostics.successfulMutations =
                record.diagnostics.successfulMutations + 1
        end

        local accepted_segments =
            tonumber(result.acceptedSegments) or 0
        if accepted_segments > 0 then
            state.diagnostics.acceptedSegments =
                state.diagnostics.acceptedSegments
                    + accepted_segments
            record.diagnostics.acceptedSegments =
                record.diagnostics.acceptedSegments
                    + accepted_segments
        end

        if (operation == "upsert" or operation == "emit")
            and result.created == true
        then
            state.diagnostics.createdBeamGenerations =
                state.diagnostics.createdBeamGenerations + 1
            record.diagnostics.createdBeamGenerations =
                record.diagnostics.createdBeamGenerations + 1
        end
    end

    instance.invoke = function(first, second, third, ...)
        local producer_state
        local operation
        local first_argument
        local colon_call = first == instance
        if colon_call then
            producer_state = second
            operation = third
        else
            producer_state = first
            operation = second
            first_argument = third
        end
        local handler = operations[operation]
        if handler == nil then
            recordInvalidRequest(nil)
            return nil, "invalid_spec"
        end
        local record, err = ensureProducer(producer_state)
        if record == nil then
            recordInvalidRequest(nil)
            return nil, err
        end
        local result
        local detail
        if colon_call then
            result, err, detail = handler(record, ...)
        else
            result, err, detail =
                handler(record, first_argument, ...)
        end
        if result == nil then
            recordInvalidRequest(record)
            return nil, err, detail
        end
        recordSuccessfulResult(record, operation, result)
        return result
    end

    local function pruneExpiredSegments(record, beam, now)
        local retained = {}
        for _, segment in ipairs(beam.segments) do
            if segment.expiresAt == nil or now < segment.expiresAt then
                retained[#retained + 1] = segment
            end
        end
        local removed = #beam.segments - #retained
        if removed > 0 then
            beam.segments = retained
            record.segmentCount = record.segmentCount - removed
            state.totalSegments = state.totalSegments - removed
            synchronizeRegistryState(record)
        end
        return removed
    end

    instance.update = function(first, second)
        local supplied_now
        if first == instance then
            supplied_now = second
        else
            supplied_now = first
        end
        local now = supplied_now
        local err
        if now == nil then
            now, err = currentTime()
            if now == nil then
                return nil, err
            end
        elseif not finiteNumber(now) then
            return nil, "provider_reset"
        end

        local update_serial = nextInteger(state.updateSerial)
        if update_serial == nil then
            return nil, "provider_reset"
        end
        state.updateSerial = update_serial
        local summary = {
            expiredBeams = 0,
            expiredLeases = 0,
            finishedBeams = 0,
            prunedSegments = 0,
            pendingNaturalExpiry = 0,
        }

        for _, key in ipairs(sortedKeys(state.beamsByKey)) do
            local beam = state.beamsByKey[key]
            if beam ~= nil then
                local record = state.producers[protocol.producerKey(beam)]
                if record == nil then
                    report("update", "orphan_beam")
                    return nil, "provider_reset"
                end

                if beam.status == "pending_natural_expiry" then
                    if state.updateSerial > beam.pendingExpiryUpdate then
                        local removed
                        removed, err = removeBeam(
                            record,
                            beam,
                            "natural_expiry"
                        )
                        if removed == nil then
                            return nil, err
                        end
                        summary.expiredBeams = summary.expiredBeams + 1
                    end
                elseif beam.lifecycle.state == "finishing"
                    and beam.lifecycle.expiresAt ~= nil
                    and now >= beam.lifecycle.expiresAt
                then
                    local removed
                    removed, err = removeBeam(record, beam, "finished")
                    if removed == nil then
                        return nil, err
                    end
                    summary.finishedBeams = summary.finishedBeams + 1
                elseif transientNaturallyExpired(beam, now) then
                    beam.status = "pending_natural_expiry"
                    beam.pendingExpiryUpdate = state.updateSerial
                    summary.pendingNaturalExpiry
                        = summary.pendingNaturalExpiry + 1
                elseif beam.lifecycle.mode == "persistent"
                    and beam.lifecycle.leaseExpiresAt ~= nil
                    and now >= beam.lifecycle.leaseExpiresAt
                then
                    local removed
                    removed, err = removeBeam(record, beam, "lease_expired")
                    if removed == nil then
                        return nil, err
                    end
                    summary.expiredLeases = summary.expiredLeases + 1
                else
                    summary.prunedSegments = summary.prunedSegments
                        + pruneExpiredSegments(record, beam, now)
                end
            end
        end
        return summary
    end

    local function beamIsRenderable(beam, now)
        if beam.status == "pending_natural_expiry" then
            return false
        end
        if beam.lifecycle.expiresAt ~= nil and now >= beam.lifecycle.expiresAt then
            return false
        end
        if beam.lifecycle.mode == "persistent"
            and beam.lifecycle.leaseExpiresAt ~= nil
            and now >= beam.lifecycle.leaseExpiresAt
        then
            return false
        end
        return true
    end

    local function exportBeam(beam, now)
        if not beamIsRenderable(beam, now) then
            return nil
        end
        local segments = {}
        for _, segment in ipairs(beam.segments) do
            if segment.expiresAt == nil or now < segment.expiresAt then
                segments[#segments + 1] = copySegmentForPacket(segment)
            end
        end
        if #segments == 0 then
            return nil
        end
        local result = identityCopy(beam)
        result.revision = beam.revision
        result.spaceKey = beam.spaceKey
        result.audience = copyAudience(beam.audience)
        result.priority = beam.priority
        result.lifecycle = copyLifecycleForPacket(beam.lifecycle)
        result.animationStartedAt = beam.animationStartedAt
        result.segments = segments
        return result
    end

    instance.listRenderable = function(first, second)
        local supplied_now
        if first == instance then
            supplied_now = second
        else
            supplied_now = first
        end
        local now = supplied_now
        local err
        if now == nil then
            now, err = currentTime()
            if now == nil then
                return nil, err
            end
        elseif not finiteNumber(now) then
            return nil, "provider_reset"
        end
        local result = {}
        for _, key in ipairs(sortedKeys(state.beamsByKey)) do
            local exported = exportBeam(state.beamsByKey[key], now)
            if exported ~= nil then
                result[#result + 1] = exported
            end
        end
        return result
    end

    instance.drainChanges = function(first, second)
        local supplied_now
        if first == instance then
            supplied_now = second
        else
            supplied_now = first
        end
        local now = supplied_now
        local err
        if now == nil then
            now, err = currentTime()
            if now == nil then
                return nil, err
            end
        elseif not finiteNumber(now) then
            return nil, "provider_reset"
        end

        local pending = state.pendingChanges
        state.pendingChanges = {}
        local result = {}
        for _, key in ipairs(sortedKeys(pending)) do
            local change = pending[key]
            if change.kind == "remove" then
                result[#result + 1] = change
            else
                local beam = state.beamsByKey[key]
                local exported = beam and exportBeam(beam, now) or nil
                if exported ~= nil then
                    result[#result + 1] = {
                        kind = "snapshot",
                        classification = change.classification,
                        compositeRenderKey = key,
                        beam = exported,
                    }
                end
            end
        end
        table.sort(result, function(left, right)
            local rank = {
                remove = 1,
                finish = 2,
                ordinary = 3,
            }
            local left_kind = left.kind == "remove"
                    and "remove"
                or left.classification
            local right_kind = right.kind == "remove"
                    and "remove"
                or right.classification
            if rank[left_kind] ~= rank[right_kind] then
                return rank[left_kind] < rank[right_kind]
            end
            return left.compositeRenderKey < right.compositeRenderKey
        end)
        return result
    end

    instance.reset = function(first, second)
        local new_epoch = first == instance and second or first
        if not boundedEpoch(new_epoch, constants)
            or new_epoch == state.providerEpoch
        then
            return nil, "invalid_spec"
        end
        local old_epoch = state.providerEpoch
        for _, record in pairs(state.producers) do
            record.beamCount = 0
            record.segmentCount = 0
            synchronizeRegistryState(record)
        end
        state.providerEpoch = new_epoch
        state.producers = {}
        state.beamsByKey = {}
        state.totalBeams = 0
        state.totalSegments = 0
        state.updateSerial = 0
        state.pendingChanges = {}
        state.diagnostics = newDiagnostics()
        return {
            oldProviderEpoch = old_epoch,
            providerEpoch = new_epoch,
        }
    end

    instance.providerEpoch = function()
        return state.providerEpoch
    end

    instance.stats = function()
        return {
            providerEpoch = state.providerEpoch,
            registeredProducerStates = (function()
                local count = 0
                for _ in pairs(state.producers) do
                    count = count + 1
                end
                return count
            end)(),
            activeBeams = state.totalBeams,
            retainedSegments = state.totalSegments,
            pendingChanges = (function()
                local count = 0
                for _ in pairs(state.pendingChanges) do
                    count = count + 1
                end
                return count
            end)(),
            updateSerial = state.updateSerial,
        }
    end

    instance.diagnostics = function()
        local producers = {}
        for _, record in pairs(state.producers) do
            producers[#producers + 1] = {
                producerId = record.producerId,
                producerGeneration = record.producerGeneration,
                current = {
                    activeBeams = record.beamCount,
                    retainedSegments = record.segmentCount,
                },
                cumulative = {
                    successfulMutations =
                        record.diagnostics.successfulMutations,
                    acceptedSegments =
                        record.diagnostics.acceptedSegments,
                    invalidRequests =
                        record.diagnostics.invalidRequests,
                    createdBeamGenerations =
                        record.diagnostics.createdBeamGenerations,
                    removedBeamGenerations =
                        record.diagnostics.removedBeamGenerations,
                },
            }
        end
        table.sort(producers, function(left, right)
            if left.producerId ~= right.producerId then
                return left.producerId < right.producerId
            end
            return left.producerGeneration
                < right.producerGeneration
        end)

        local current = instance.stats()
        return {
            providerEpoch = state.providerEpoch,
            current = {
                registeredProducerStates =
                    current.registeredProducerStates,
                activeBeams = current.activeBeams,
                retainedSegments = current.retainedSegments,
                pendingChanges = current.pendingChanges,
                updateSerial = current.updateSerial,
            },
            cumulative = {
                successfulMutations =
                    state.diagnostics.successfulMutations,
                acceptedSegments =
                    state.diagnostics.acceptedSegments,
                invalidRequests =
                    state.diagnostics.invalidRequests,
                createdBeamGenerations =
                    state.diagnostics.createdBeamGenerations,
                removedBeamGenerations =
                    state.diagnostics.removedBeamGenerations,
            },
            producers = producers,
        }
    end

    return instance
end

broker.create = broker.new

return broker
