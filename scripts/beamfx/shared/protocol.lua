---@omw-context global | player | none

local constants = require("scripts.beamfx.shared.constants")
local space = require("scripts.beamfx.shared.space")

local protocol = {}

protocol.VERSION = constants.PROTOCOL_VERSION

protocol.events = {
    RENDER_SNAPSHOT = "BeamFX_Internal_RenderSnapshot_v3",
    RENDER_REMOVE = "BeamFX_Internal_RenderRemove_v3",
    PROVIDER_RESET = "BeamFX_Internal_ProviderReset_v3",
    VIEWER_RECONCILE_RESET = "BeamFX_Internal_ViewerReconcileReset_v3",
    VIEWER_READY = "BeamFX_Internal_ViewerReady_v3",
    VIEWER_RESYNC = "BeamFX_Internal_ViewerResync_v3",
}

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_EPOCH_LENGTH = tonumber(constants.MAX_EPOCH_LENGTH) or 192
local MAX_RENDERER_SESSION_LENGTH = tonumber(constants.MAX_RENDERER_SESSION_LENGTH) or 192
local MAX_PRODUCER_ID_LENGTH = tonumber(constants.MAX_PRODUCER_ID_LENGTH) or 96
local MAX_BEAM_ID_LENGTH = tonumber(constants.MAX_BEAM_ID_LENGTH) or 128
local MAX_SPACE_KEY_LENGTH = tonumber(constants.MAX_SPACE_KEY_LENGTH) or 384
local MAX_REASON_LENGTH = tonumber(constants.MAX_REASON_LENGTH) or 160
local MAX_PACKET_DEPTH = 12
local MAX_PACKET_VALUES = tonumber(constants.MAX_PACKET_VALUES) or 16384
local MAX_PACKET_SEGMENTS = tonumber(constants.MAX_INPUT_SEGMENTS)
    or tonumber(constants.MAX_SEGMENTS_PER_BEAM)
    or constants.SEGMENT_CAPACITY

local PRIORITIES = {
    low = true,
    normal = true,
    high = true,
}

local STYLES = {
    smooth = true,
    electric = true,
    plasma = true,
    trail = true,
    filament = true,
}

local SEGMENT_KEYS = {
    startPos = true,
    endPos = true,
    startRadius = true,
    endRadius = true,
    minPixelWidth = true,
    outerColor = true,
    coreColor = true,
    coreRatio = true,
    intensity = true,
    opacity = true,
    baseColor = true,
    baseOpacity = true,
    startFadeLength = true,
    endFadeLength = true,
    depthSoftness = true,
    fogInfluence = true,
    style = true,
    styleScale = true,
    seed = true,
    originGlow = true,
    longitudinal = true,
    createdAt = true,
    fadeStartAt = true,
    expiresAt = true,
}

local LONGITUDINAL_MODE_KEYS = {
    solid = {
        mode = true,
        pathOffset = true,
    },
    travel = {
        mode = true,
        pathOffset = true,
        visibleLength = true,
        speed = true,
        headFadeLength = true,
        tailFadeLength = true,
        loop = true,
        loopLength = true,
        loopDelay = true,
    },
    pulse = {
        mode = true,
        pathOffset = true,
        period = true,
        pulseLength = true,
        speed = true,
        carrierLevel = true,
        fadeLength = true,
    },
    dash = {
        mode = true,
        pathOffset = true,
        dashLength = true,
        gapLength = true,
        speed = true,
        fadeLength = true,
    },
}

local LIFECYCLE_MODES = {
    transient = true,
    persistent = true,
}

local LIFECYCLE_STATES = {
    active = true,
    finishing = true,
}

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

local function serializableValue(value, seen, depth, budget)
    local value_type = type(value)
    if value_type == "nil" or value_type == "boolean" or value_type == "string" then
        return true
    end
    if value_type == "number" then
        return finiteNumber(value)
    end
    if value_type ~= "table" or depth > MAX_PACKET_DEPTH or seen[value] then
        return false
    end

    seen[value] = true
    for key, child in next, value do
        budget.count = budget.count + 1
        if budget.count > MAX_PACKET_VALUES then
            seen[value] = nil
            return false
        end
        local key_type = type(key)
        if (key_type ~= "string" and key_type ~= "number")
            or (key_type == "number" and not finiteNumber(key))
            or not serializableValue(child, seen, depth + 1, budget)
        then
            seen[value] = nil
            return false
        end
    end
    seen[value] = nil
    return true
end

function protocol.isSerializablePacket(value)
    return serializableValue(value, {}, 0, { count = 0 })
end

local function lengthPart(value)
    local text = tostring(value)
    return tostring(#text) .. ":" .. text
end

function protocol.compositeRenderKey(identity)
    if type(identity) ~= "table" then
        return nil
    end
    return table.concat({
        "bfx1",
        lengthPart(identity.providerEpoch),
        lengthPart(identity.producerId),
        lengthPart(identity.producerGeneration),
        lengthPart(identity.localBeamId),
        lengthPart(identity.beamGeneration),
    }, "|")
end

function protocol.producerKey(identity)
    if type(identity) ~= "table" then
        return nil
    end
    return table.concat({
        "bfxp1",
        lengthPart(identity.producerId),
        lengthPart(identity.producerGeneration),
    }, "|")
end

function protocol.logicalBeamKey(identity)
    if type(identity) ~= "table" then
        return nil
    end
    return table.concat({
        "bfxb1",
        lengthPart(identity.producerId),
        lengthPart(identity.producerGeneration),
        lengthPart(identity.localBeamId),
    }, "|")
end

local function copyVector3(value)
    if type(value) ~= "table" then
        return nil
    end
    local x = rawget(value, "x")
    local y = rawget(value, "y")
    local z = rawget(value, "z")
    if x == nil then x = rawget(value, 1) end
    if y == nil then y = rawget(value, 2) end
    if z == nil then z = rawget(value, 3) end
    if not finiteNumber(x) or not finiteNumber(y) or not finiteNumber(z)
        or math.abs(x) > constants.MAX_ABS_COORDINATE
        or math.abs(y) > constants.MAX_ABS_COORDINATE
        or math.abs(z) > constants.MAX_ABS_COORDINATE
    then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function copyColor(value)
    if type(value) ~= "table" then
        return nil
    end
    local red = rawget(value, "r")
    local green = rawget(value, "g")
    local blue = rawget(value, "b")
    if red == nil then red = rawget(value, "x") end
    if green == nil then green = rawget(value, "y") end
    if blue == nil then blue = rawget(value, "z") end
    if red == nil then red = rawget(value, 1) end
    if green == nil then green = rawget(value, 2) end
    if blue == nil then blue = rawget(value, 3) end
    if not finiteNumber(red)
        or not finiteNumber(green)
        or not finiteNumber(blue)
        or red < 0 or red > 4
        or green < 0 or green > 4
        or blue < 0 or blue > 4
    then
        return nil
    end
    return { red, green, blue }
end

local function copyBaseColor(value)
    local result = copyColor(value)
    if result == nil
        or result[1] > 1
        or result[2] > 1
        or result[3] > 1
    then
        return nil
    end
    return result
end

local function hasExactStringKeys(value, allowed)
    if type(value) ~= "table" then
        return false
    end
    local actual = 0
    for key in next, value do
        if type(key) ~= "string" or not allowed[key] then
            return false
        end
        actual = actual + 1
    end
    local expected = 0
    for _ in pairs(allowed) do
        expected = expected + 1
    end
    return actual == expected
end

local function validateLongitudinal(value)
    if type(value) ~= "table" then
        return nil
    end
    local mode = rawget(value, "mode")
    local allowed = LONGITUDINAL_MODE_KEYS[mode]
    if allowed == nil or not hasExactStringKeys(value, allowed) then
        return nil
    end
    local path_offset = rawget(value, "pathOffset")
    if not finiteNumber(path_offset)
        or math.abs(path_offset) > constants.MAX_LONGITUDINAL_DISTANCE
    then
        return nil
    end

    if mode == "solid" then
        return {
            mode = mode,
            pathOffset = path_offset,
        }
    end

    local speed = rawget(value, "speed")
    if not finiteNumber(speed)
        or math.abs(speed) > constants.MAX_LONGITUDINAL_SPEED
    then
        return nil
    end

    if mode == "travel" then
        local visible_length = rawget(value, "visibleLength")
        local head_fade_length = rawget(value, "headFadeLength")
        local tail_fade_length = rawget(value, "tailFadeLength")
        local loop = rawget(value, "loop")
        local loop_length = rawget(value, "loopLength")
        local loop_delay = rawget(value, "loopDelay")
        if not finiteNumber(visible_length)
            or visible_length < constants.MIN_LONGITUDINAL_LENGTH
            or visible_length > constants.MAX_LONGITUDINAL_DISTANCE
            or speed == 0
            or math.abs(speed) < constants.MIN_LONGITUDINAL_LENGTH
            or not finiteNumber(head_fade_length)
            or head_fade_length < 0
            or head_fade_length > visible_length
            or not finiteNumber(tail_fade_length)
            or tail_fade_length < 0
            or tail_fade_length > visible_length
            or type(loop) ~= "boolean"
            or not finiteNumber(loop_length)
            or not finiteNumber(loop_delay)
            or loop_delay < 0
            or loop_delay > constants.MAX_LONGITUDINAL_LOOP_DELAY
            or (not loop and (loop_length ~= 0 or loop_delay ~= 0))
            or (loop and (
                loop_length < constants.MIN_LONGITUDINAL_LENGTH
                or loop_length > constants.MAX_LONGITUDINAL_DISTANCE
            ))
        then
            return nil
        end
        return {
            mode = mode,
            pathOffset = path_offset,
            visibleLength = visible_length,
            speed = speed,
            headFadeLength = head_fade_length,
            tailFadeLength = tail_fade_length,
            loop = loop,
            loopLength = loop_length,
            loopDelay = loop_delay,
        }
    end

    if mode == "pulse" then
        local period = rawget(value, "period")
        local pulse_length = rawget(value, "pulseLength")
        local carrier_level = rawget(value, "carrierLevel")
        local fade_length = rawget(value, "fadeLength")
        if not finiteNumber(period)
            or period < constants.MIN_LONGITUDINAL_LENGTH
            or period > constants.MAX_LONGITUDINAL_DISTANCE
            or not finiteNumber(pulse_length)
            or pulse_length < constants.MIN_LONGITUDINAL_LENGTH
            or pulse_length > period
            or not finiteNumber(carrier_level)
            or carrier_level < 0
            or carrier_level > 1
            or not finiteNumber(fade_length)
            or fade_length < 0
            or fade_length > pulse_length * 0.5
        then
            return nil
        end
        return {
            mode = mode,
            pathOffset = path_offset,
            period = period,
            pulseLength = pulse_length,
            speed = speed,
            carrierLevel = carrier_level,
            fadeLength = fade_length,
        }
    end

    local dash_length = rawget(value, "dashLength")
    local gap_length = rawget(value, "gapLength")
    local fade_length = rawget(value, "fadeLength")
    if not finiteNumber(dash_length)
        or dash_length < constants.MIN_LONGITUDINAL_LENGTH
        or dash_length > constants.MAX_LONGITUDINAL_DISTANCE
        or not finiteNumber(gap_length)
        or gap_length < 0
        or gap_length > constants.MAX_LONGITUDINAL_DISTANCE
        or not finiteNumber(fade_length)
        or fade_length < 0
        or fade_length > dash_length * 0.5
    then
        return nil
    end
    return {
        mode = mode,
        pathOffset = path_offset,
        dashLength = dash_length,
        gapLength = gap_length,
        speed = speed,
        fadeLength = fade_length,
    }
end

local function optionalTimestamp(value)
    if value == nil then
        return nil, true
    end
    if finiteNumber(value) then
        return value, true
    end
    return nil, false
end

local function validateIdentity(payload)
    if not boundedString(payload.providerEpoch, MAX_EPOCH_LENGTH)
        or not boundedString(payload.producerId, MAX_PRODUCER_ID_LENGTH)
        or not safeInteger(payload.producerGeneration, 1)
        or not boundedString(payload.localBeamId, MAX_BEAM_ID_LENGTH)
        or not safeInteger(payload.beamGeneration, 1)
    then
        return nil, "invalid_identity"
    end

    local identity = {
        providerEpoch = payload.providerEpoch,
        producerId = payload.producerId,
        producerGeneration = payload.producerGeneration,
        localBeamId = payload.localBeamId,
        beamGeneration = payload.beamGeneration,
    }
    local expected_key = protocol.compositeRenderKey(identity)
    if payload.compositeRenderKey ~= expected_key then
        return nil, "invalid_composite_key"
    end
    identity.compositeRenderKey = expected_key
    return identity
end

local function validateEnvelope(payload)
    if type(payload) ~= "table" or not protocol.isSerializablePacket(payload) then
        return nil, "invalid_packet"
    end
    if payload.source ~= "beamfx" then
        return nil, "invalid_source"
    end
    if payload.protocolVersion ~= protocol.VERSION then
        return nil, "protocol_mismatch"
    end
    return true
end

local function validateLifecycle(value)
    if type(value) ~= "table"
        or not LIFECYCLE_MODES[value.mode]
        or not LIFECYCLE_STATES[value.state]
        or not finiteNumber(value.createdAt)
    then
        return nil, "invalid_lifecycle"
    end

    local fade_start_at, fade_ok = optionalTimestamp(value.fadeStartAt)
    local expires_at, expires_ok = optionalTimestamp(value.expiresAt)
    if not fade_ok or not expires_ok then
        return nil, "invalid_lifecycle_timestamp"
    end
    if value.state == "active" then
        if value.mode == "transient"
            and (fade_start_at == nil or expires_at == nil)
        then
            return nil, "missing_lifecycle_expiry"
        end
        if value.mode == "persistent"
            and (fade_start_at ~= nil or expires_at ~= nil)
        then
            return nil, "invalid_lifecycle"
        end
    elseif fade_start_at == nil or expires_at == nil then
        return nil, "missing_lifecycle_expiry"
    end
    if expires_at ~= nil and expires_at < value.createdAt then
        return nil, "invalid_lifecycle_expiry"
    end
    if fade_start_at ~= nil
        and (expires_at == nil
            or fade_start_at < value.createdAt
            or fade_start_at > expires_at)
    then
        return nil, "invalid_lifecycle_fade"
    end

    return {
        mode = value.mode,
        state = value.state,
        createdAt = value.createdAt,
        fadeStartAt = fade_start_at,
        expiresAt = expires_at,
    }
end

local function validateSegment(value)
    if type(value) ~= "table" then
        return nil, "invalid_segment"
    end
    for key in next, value do
        if type(key) ~= "string" or not SEGMENT_KEYS[key] then
            return nil, "invalid_segment"
        end
    end

    local start_pos = copyVector3(value.startPos)
    local end_pos = copyVector3(value.endPos)
    local outer_color = copyColor(value.outerColor)
    local core_color = copyColor(value.coreColor)
    local base_color = copyBaseColor(value.baseColor)
    local start_radius = rawget(value, "startRadius")
    local end_radius = rawget(value, "endRadius")
    local minimum_pixel_width = rawget(value, "minPixelWidth")
    local core_ratio = rawget(value, "coreRatio")
    local intensity = rawget(value, "intensity")
    local opacity = rawget(value, "opacity")
    local base_opacity = rawget(value, "baseOpacity")
    local start_fade_length = rawget(value, "startFadeLength")
    local end_fade_length = rawget(value, "endFadeLength")
    local depth_softness = rawget(value, "depthSoftness")
    local fog_influence = rawget(value, "fogInfluence")
    local style_scale = rawget(value, "styleScale")
    local seed = rawget(value, "seed")
    local origin_glow = rawget(value, "originGlow")
    local longitudinal = validateLongitudinal(value.longitudinal)
    local created_at = rawget(value, "createdAt")
    local fade_start_at, fade_ok = optionalTimestamp(value.fadeStartAt)
    local expires_at, expires_ok = optionalTimestamp(value.expiresAt)

    local minimum_radius = constants.MIN_RADIUS
    if value.style == "filament" then
        minimum_radius = constants.MIN_FILAMENT_RADIUS
    end
    local start_radius_valid = finiteNumber(start_radius)
        and start_radius <= constants.MAX_RADIUS
        and (start_radius == 0 or start_radius >= minimum_radius)
    local end_radius_valid = finiteNumber(end_radius)
        and end_radius <= constants.MAX_RADIUS
        and (end_radius == 0 or end_radius >= minimum_radius)

    if start_pos == nil or end_pos == nil
        or outer_color == nil or core_color == nil or base_color == nil
        or not STYLES[value.style]
        or not start_radius_valid or not end_radius_valid
        or not finiteNumber(minimum_pixel_width)
        or minimum_pixel_width < 0
        or minimum_pixel_width > constants.MAX_MIN_PIXEL_WIDTH
        or (minimum_pixel_width > 0 and value.style ~= "filament")
        or (start_radius == 0 and end_radius == 0
            and minimum_pixel_width == 0)
        or not finiteNumber(core_ratio) or core_ratio < 0.02 or core_ratio > 1
        or not finiteNumber(intensity) or intensity < 0 or intensity > 8
        or not finiteNumber(opacity) or opacity < 0 or opacity > 1
        or not finiteNumber(base_opacity)
        or base_opacity < 0 or base_opacity > 1
        or not finiteNumber(start_fade_length)
        or start_fade_length < 0
        or start_fade_length > constants.MAX_LONGITUDINAL_DISTANCE
        or not finiteNumber(end_fade_length)
        or end_fade_length < 0
        or end_fade_length > constants.MAX_LONGITUDINAL_DISTANCE
        or not finiteNumber(depth_softness)
        or depth_softness < 0
        or depth_softness > constants.MAX_DEPTH_SOFTNESS
        or not finiteNumber(fog_influence)
        or fog_influence < 0 or fog_influence > 1
        or not finiteNumber(style_scale) or style_scale < 0 or style_scale > 512
        or not safeInteger(seed, 0) or seed > 15
        or type(origin_glow) ~= "boolean"
        or longitudinal == nil
        or not finiteNumber(created_at)
        or not fade_ok or not expires_ok
    then
        return nil, "invalid_segment"
    end

    if longitudinal.mode ~= "solid" then
        local x = end_pos.x - start_pos.x
        local y = end_pos.y - start_pos.y
        local z = end_pos.z - start_pos.z
        if x * x + y * y + z * z <= 0 then
            return nil, "invalid_segment"
        end
    end

    if origin_glow then
        if value.style ~= "plasma" or seed ~= 0 then
            return nil, "invalid_segment"
        end
    elseif value.style == "plasma" and seed == 0 then
        return nil, "invalid_segment"
    end
    if expires_at ~= nil and expires_at < created_at then
        return nil, "invalid_segment_expiry"
    end
    if (fade_start_at == nil) ~= (expires_at == nil) then
        return nil, "invalid_segment_fade"
    end
    if fade_start_at ~= nil
        and (expires_at == nil
            or fade_start_at < created_at
            or fade_start_at > expires_at)
    then
        return nil, "invalid_segment_fade"
    end

    return {
        startPos = start_pos,
        endPos = end_pos,
        startRadius = start_radius,
        endRadius = end_radius,
        minPixelWidth = minimum_pixel_width,
        coreRatio = core_ratio,
        outerColor = outer_color,
        coreColor = core_color,
        intensity = intensity,
        opacity = opacity,
        baseColor = base_color,
        baseOpacity = base_opacity,
        startFadeLength = start_fade_length,
        endFadeLength = end_fade_length,
        depthSoftness = depth_softness,
        fogInfluence = fog_influence,
        style = value.style,
        styleScale = style_scale,
        seed = seed,
        originGlow = origin_glow,
        longitudinal = longitudinal,
        createdAt = created_at,
        fadeStartAt = fade_start_at,
        expiresAt = expires_at,
    }
end

local function exactArrayLength(value, maximum)
    if type(value) ~= "table" then
        return nil
    end
    local count = 0
    local highest = 0
    for key in next, value do
        if type(key) ~= "number"
            or not safeInteger(key, 1)
            or key > maximum
        then
            return nil
        end
        count = count + 1
        highest = math.max(highest, key)
        if count > maximum then
            return nil
        end
    end
    if count == 0 or highest ~= count then
        return nil
    end
    for index = 1, count do
        if rawget(value, index) == nil then
            return nil
        end
    end
    return count
end

function protocol.validateSnapshot(payload)
    local ok, err = validateEnvelope(payload)
    if not ok then
        return nil, err
    end
    local identity
    identity, err = validateIdentity(payload)
    if identity == nil then
        return nil, err
    end
    local segment_count = exactArrayLength(
        payload.segments,
        MAX_PACKET_SEGMENTS
    )
    if not safeInteger(payload.viewerSyncGeneration, 1)
        or not safeInteger(payload.revision, 1)
        or not finiteNumber(payload.animationStartedAt)
        or not boundedString(
            payload.rendererSession,
            MAX_RENDERER_SESSION_LENGTH
        )
        or not boundedString(payload.spaceKey, MAX_SPACE_KEY_LENGTH)
        or not space.isValidKey(payload.spaceKey)
        or not PRIORITIES[payload.priority]
        or segment_count == nil
    then
        return nil, "invalid_snapshot"
    end
    local lifecycle
    lifecycle, err = validateLifecycle(payload.lifecycle)
    if lifecycle == nil then
        return nil, err
    end

    local segments = {}
    for index = 1, segment_count do
        local source = rawget(payload.segments, index)
        local segment
        segment, err = validateSegment(source)
        if segment == nil then
            return nil, string.format("%s:%d", err, index)
        end
        segments[index] = segment
    end
    return {
        source = "beamfx",
        protocolVersion = protocol.VERSION,
        providerEpoch = identity.providerEpoch,
        rendererSession = payload.rendererSession,
        viewerSyncGeneration = payload.viewerSyncGeneration,
        compositeRenderKey = identity.compositeRenderKey,
        producerId = identity.producerId,
        producerGeneration = identity.producerGeneration,
        localBeamId = identity.localBeamId,
        beamGeneration = identity.beamGeneration,
        revision = payload.revision,
        animationStartedAt = payload.animationStartedAt,
        spaceKey = payload.spaceKey,
        priority = payload.priority,
        lifecycle = lifecycle,
        segments = segments,
    }
end

function protocol.validateRemove(payload)
    local ok, err = validateEnvelope(payload)
    if not ok then
        return nil, err
    end
    local identity
    identity, err = validateIdentity(payload)
    if identity == nil then
        return nil, err
    end
    if not safeInteger(payload.viewerSyncGeneration, 1)
        or not safeInteger(payload.terminalRevision, 1)
        or not boundedString(
            payload.rendererSession,
            MAX_RENDERER_SESSION_LENGTH
        )
        or (payload.reason ~= nil and not boundedString(payload.reason, MAX_REASON_LENGTH))
    then
        return nil, "invalid_remove"
    end
    identity.source = "beamfx"
    identity.protocolVersion = protocol.VERSION
    identity.rendererSession = payload.rendererSession
    identity.viewerSyncGeneration = payload.viewerSyncGeneration
    identity.terminalRevision = payload.terminalRevision
    identity.reason = payload.reason
    return identity
end

function protocol.validateProviderReset(payload)
    local ok, err = validateEnvelope(payload)
    if not ok then
        return nil, err
    end
    if (payload.oldProviderEpoch ~= nil
            and not boundedString(payload.oldProviderEpoch, MAX_EPOCH_LENGTH))
        or not boundedString(payload.newProviderEpoch, MAX_EPOCH_LENGTH)
        or (payload.reason ~= nil and not boundedString(payload.reason, MAX_REASON_LENGTH))
    then
        return nil, "invalid_provider_reset"
    end
    if payload.oldProviderEpoch ~= nil
        and payload.oldProviderEpoch == payload.newProviderEpoch
    then
        return nil, "unchanged_provider_epoch"
    end
    return {
        source = "beamfx",
        protocolVersion = protocol.VERSION,
        oldProviderEpoch = payload.oldProviderEpoch,
        newProviderEpoch = payload.newProviderEpoch,
        reason = payload.reason,
    }
end

function protocol.validateViewerReconcileReset(payload)
    local ok, err = validateEnvelope(payload)
    if not ok then
        return nil, err
    end
    if not boundedString(payload.providerEpoch, MAX_EPOCH_LENGTH)
        or not boundedString(
            payload.rendererSession,
            MAX_RENDERER_SESSION_LENGTH
        )
        or not safeInteger(payload.newViewerSyncGeneration, 1)
        or (payload.reason ~= nil and not boundedString(payload.reason, MAX_REASON_LENGTH))
    then
        return nil, "invalid_viewer_reconcile_reset"
    end
    return {
        source = "beamfx",
        protocolVersion = protocol.VERSION,
        providerEpoch = payload.providerEpoch,
        rendererSession = payload.rendererSession,
        newViewerSyncGeneration = payload.newViewerSyncGeneration,
        reason = payload.reason,
    }
end

function protocol.isSafeInteger(value, minimum)
    return safeInteger(value, minimum)
end

return protocol
