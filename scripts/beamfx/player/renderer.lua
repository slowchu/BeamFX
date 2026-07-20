---@omw-context player

local camera = require("openmw.camera")
local core = require("openmw.core")
local self = require("openmw.self")
local util = require("openmw.util")

local constants = require("scripts.beamfx.shared.constants")
local beam_styles = require("scripts.beamfx.shared.styles")
local log = require("scripts.beamfx.shared.log").new("player.renderer")
local protocol = require("scripts.beamfx.shared.protocol")
local space = require("scripts.beamfx.shared.space")
local protocol_state = require("scripts.beamfx.player.protocol_state")
local scheduler = require("scripts.beamfx.player.scheduler")

local beam_renderer = {}

local SHADER_NAME = constants.SHADER_RESOURCE
local MAX_SHADER_SEGMENTS = beam_styles.SEGMENT_CAPACITY
local MAX_SHADER_PALETTES = beam_styles.PALETTE_CAPACITY
local SHADER_RETRY_SECONDS = 5
local VIEWPORT_MARGIN = 0.20
local UINT8_MAX = 255
local UINT10_MAX = 1023
local UINT12_MAX = 4095
local UINT16_MAX = 65535
local FEATURE_DISTANCE_MIN = 0.01
local FEATURE_DISTANCE_MAX = 1000000
local FEATURE_DISTANCE_LOG_MIN = math.log(FEATURE_DISTANCE_MIN) / math.log(2)
local FEATURE_DISTANCE_LOG_SPAN =
    math.log(FEATURE_DISTANCE_MAX / FEATURE_DISTANCE_MIN) / math.log(2)
local LONGITUDINAL_MODE_ID = {
    solid = 0,
    travel = 1,
    pulse = 2,
    dash = 3,
}
local ZERO_VECTOR4 = util.vector4(0, 0, 0, 0)

local ok_postprocessing, postprocessing = pcall(require, "openmw.postprocessing")
if not ok_postprocessing then
    postprocessing = nil
end

local state = {
    beams = {},
    protocol = protocol_state.new({
        tombstoneLimit = constants.MAX_RENDERER_TOMBSTONES,
    }),
    scheduler = scheduler.new(),
    resyncHandler = nil,
    shader = nil,
    shaderLoadFailed = false,
    shaderFailureLogged = false,
    uploadFailureLogged = false,
    shaderRequested = false,
    shaderRequestedAt = nil,
    lastShaderEnableAttemptAt = nil,
    nextShaderRetryAt = 0,
    nextUploadRetryAt = 0,
    lastUploadedCount = 0,
    paletteSignature = nil,
    overflowLogged = false,
    paletteOverflowLogged = false,
    diagnostics = {
        retainedBeams = 0,
        retainedSegments = 0,
        eligibleSegments = 0,
        renderedSegments = 0,
        culledBySpace = 0,
        culledByCapacity = 0,
        paletteCount = 0,
        paletteOverflow = false,
        uploadHealthy = true,
    },
    uniforms = {
        starts = {},
        ends = {},
        featureState = {},
        paletteOuter = {},
        paletteCore = {},
        paletteBaseShape = {},
        paletteLongitudinal = {},
    },
}

for index = 1, MAX_SHADER_SEGMENTS do
    state.uniforms.starts[index] = ZERO_VECTOR4
    state.uniforms.ends[index] = ZERO_VECTOR4
end
for index = 1, MAX_SHADER_PALETTES do
    state.uniforms.featureState[index] = ZERO_VECTOR4
    state.uniforms.paletteOuter[index] = ZERO_VECTOR4
    state.uniforms.paletteCore[index] = ZERO_VECTOR4
    state.uniforms.paletteBaseShape[index] = ZERO_VECTOR4
    state.uniforms.paletteLongitudinal[index] = ZERO_VECTOR4
end

local function now()
    local ok, value = pcall(core.getSimulationTime)
    value = ok and tonumber(value) or nil
    if value ~= nil
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
    then
        return value
    end
    -- Lifecycle state is simulation-time based. If the engine clock is
    -- temporarily unavailable, fail closed instead of advancing on wall time.
    return 0
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

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, tonumber(value) or minimum))
end

local function quantizeUnit(value, maximum)
    return math.floor(clamp(value, 0, 1) * maximum + 0.5)
end

local function positiveModulo(value, modulus)
    if modulus <= 0 then
        return 0
    end
    local result = value % modulus
    if result < 0 then
        result = result + modulus
    end
    return result
end

local function encodeFeatureDistance(value)
    value = tonumber(value) or 0
    if value <= 0 then
        return 0
    end
    local exponent = math.log(clamp(
        value,
        FEATURE_DISTANCE_MIN,
        FEATURE_DISTANCE_MAX
    )) / math.log(2)
    local normalized = (exponent - FEATURE_DISTANCE_LOG_MIN)
        / FEATURE_DISTANCE_LOG_SPAN
    return 1 + math.floor(clamp(normalized, 0, 1) * (UINT10_MAX - 1) + 0.5)
end

local function packRgb888(color)
    local red = quantizeUnit(color and color[1] or 0, UINT8_MAX)
    local green = quantizeUnit(color and color[2] or 0, UINT8_MAX)
    local blue = quantizeUnit(color and color[3] or 0, UINT8_MAX)
    return red + green * 256 + blue * 65536
end

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function vector3(value)
    if value == nil then
        return nil
    end
    local x = tonumber(value.x or value[1])
    local y = tonumber(value.y or value[2])
    local z = tonumber(value.z or value[3])
    if not finiteNumber(x) or not finiteNumber(y) or not finiteNumber(z)
        or math.abs(x) > constants.MAX_ABS_COORDINATE
        or math.abs(y) > constants.MAX_ABS_COORDINATE
        or math.abs(z) > constants.MAX_ABS_COORDINATE
    then
        return nil
    end
    return util.vector3(x, y, z)
end

local function copyProtocolSegment(segment, beam, index)
    local start_pos = vector3(segment and segment.startPos)
    local end_pos = vector3(segment and segment.endPos)
    if start_pos == nil or end_pos == nil then
        return nil
    end
    return {
        id = tostring(index),
        startPos = start_pos,
        endPos = end_pos,
        width = segment.startRadius,
        startRadius = segment.startRadius,
        endRadius = segment.endRadius,
        minPixelWidth = segment.minPixelWidth,
        startFadeLength = segment.startFadeLength,
        endFadeLength = segment.endFadeLength,
        depthSoftness = segment.depthSoftness,
        fogInfluence = segment.fogInfluence,
        coreRatio = segment.coreRatio,
        color = {
            segment.outerColor[1],
            segment.outerColor[2],
            segment.outerColor[3],
        },
        coreColor = {
            segment.coreColor[1],
            segment.coreColor[2],
            segment.coreColor[3],
        },
        baseColor = {
            segment.baseColor[1],
            segment.baseColor[2],
            segment.baseColor[3],
        },
        baseOpacity = segment.baseOpacity,
        intensity = segment.intensity,
        opacity = segment.opacity,
        style = segment.style,
        styleScale = segment.styleScale,
        seed = segment.seed,
        longitudinal = segment.longitudinal,
        animationStartedAt = beam.animationStartedAt,
        createdAt = segment.createdAt or beam.createdAt,
        fadeStartAt = segment.fadeStartAt,
        expiresAt = segment.expiresAt,
    }
end

local function shaderEnabled()
    if state.shader == nil or type(state.shader.isEnabled) ~= "function" then
        return false
    end
    local ok, enabled = pcall(function() return state.shader:isEnabled() end)
    return ok and enabled == true
end

local function postprocessingAvailable()
    return postprocessing ~= nil
        and type(postprocessing.load) == "function"
end

local function ensureShader(current_time)
    if state.shader ~= nil then
        return state.shader
    end
    if not postprocessingAvailable() then
        if not state.shaderFailureLogged then
            state.shaderFailureLogged = true
            log.warn("Beam shader unavailable: openmw.postprocessing is not available")
        end
        return nil
    end
    if current_time < state.nextShaderRetryAt then
        return nil
    end

    local ok, shader_or_err = pcall(postprocessing.load, SHADER_NAME)
    if not ok or shader_or_err == nil then
        state.shaderLoadFailed = true
        state.nextShaderRetryAt = current_time + SHADER_RETRY_SECONDS
        if not state.shaderFailureLogged then
            state.shaderFailureLogged = true
            log.warn(string.format("Beam shader load failed name=%s err=%s", SHADER_NAME, tostring(shader_or_err)))
        end
        return nil
    end

    state.shader = shader_or_err
    state.shaderLoadFailed = false
    state.shaderFailureLogged = false
    state.paletteSignature = nil
    log.info(string.format(
        "Beam shader loaded name=%s capacity=%d palettes=%d",
        SHADER_NAME,
        MAX_SHADER_SEGMENTS,
        MAX_SHADER_PALETTES
    ))
    return state.shader
end

local function requestShaderEnable(shader, current_time)
    if shaderEnabled() then
        state.shaderRequested = true
        return true
    end
    if state.lastShaderEnableAttemptAt == nil
        or current_time - state.lastShaderEnableAttemptAt
            >= SHADER_RETRY_SECONDS
    then
        local ok, err = pcall(function() shader:enable() end)
        if ok and state.shaderRequestedAt == nil then
            state.shaderRequestedAt = current_time
        end
        state.shaderRequested = ok
        state.lastShaderEnableAttemptAt = current_time
        if ok then
            state.shaderFailureLogged = false
        elseif not state.shaderFailureLogged then
            state.shaderFailureLogged = true
            log.warn(string.format(
                "Beam shader enable failed err=%s",
                tostring(err)
            ))
        end
    end
    if state.shaderRequested
        and current_time - (state.shaderRequestedAt or current_time) >= 1
        and not shaderEnabled()
        and not state.shaderFailureLogged
    then
        state.shaderFailureLogged = true
        log.warn("Beam shader did not enable; postprocessing may be disabled or the shader may have failed to compile")
    end
    return state.shaderRequested
end

local function disableShader(preserve_upload_failure)
    if state.shader == nil then
        return
    end
    pcall(function()
        state.shader:setInt("bfxSegmentCount", 0)
    end)
    -- A failed zero-count upload must not prevent the independent disable
    -- attempt; either operation can fail on a broken postprocessor.
    pcall(function()
        state.shader:disable()
    end)
    state.shaderRequested = false
    state.shaderRequestedAt = nil
    state.lastShaderEnableAttemptAt = nil
    state.lastUploadedCount = 0
    state.paletteSignature = nil
    state.diagnostics.renderedSegments = 0
    state.diagnostics.paletteCount = 0
    state.diagnostics.paletteOverflow = false
    if preserve_upload_failure ~= true then
        state.uploadFailureLogged = false
        state.nextUploadRetryAt = 0
    end
end

local function timelineOpacity(fade_start_at, expires_at, current_time)
    expires_at = tonumber(expires_at)
    if expires_at ~= nil and current_time >= expires_at then
        return 0
    end
    fade_start_at = tonumber(fade_start_at)
    if expires_at ~= nil
        and fade_start_at ~= nil
        and current_time > fade_start_at
    then
        local duration = math.max(0.0001, expires_at - fade_start_at)
        return clamp((expires_at - current_time) / duration, 0, 1)
    end
    return 1
end

local function segmentLifecycle(segment, beam, current_time)
    local expires_at = tonumber(segment.expiresAt)
    local fade_start_at = tonumber(segment.fadeStartAt)
    local segment_factor = timelineOpacity(
        fade_start_at,
        expires_at,
        current_time
    )
    local beam_factor = 1
    local beam_fade_start_at = tonumber(beam and beam.fadeStartAt)
    local beam_expires_at = tonumber(beam and beam.expiresAt)
    if fade_start_at ~= beam_fade_start_at
        or expires_at ~= beam_expires_at
    then
        beam_factor = timelineOpacity(
            beam_fade_start_at,
            beam_expires_at,
            current_time
        )
    end
    return segment_factor * beam_factor
end

local function viewportProjection(position)
    if type(camera.worldToViewportVector) ~= "function" then
        return nil
    end
    local ok, viewport = pcall(camera.worldToViewportVector, position)
    if not ok or viewport == nil then
        return nil
    end
    local x = tonumber(viewport.x)
    local y = tonumber(viewport.y)
    local z = tonumber(viewport.z)
    if x == nil or y == nil or z == nil then
        return nil
    end
    return x, y, z
end

local function insideViewport(x, y)
    return x >= -VIEWPORT_MARGIN
        and x <= 1 + VIEWPORT_MARGIN
        and y >= -VIEWPORT_MARGIN
        and y <= 1 + VIEWPORT_MARGIN
end

local function segmentViewportPriority(segment)
    if type(camera.worldToViewportVector) ~= "function" then
        return 1
    end
    local start_x, start_y = viewportProjection(segment.startPos)
    local end_x, end_y = viewportProjection(segment.endPos)
    if start_x == nil or end_x == nil then
        return 1
    end

    if insideViewport(start_x, start_y)
        or insideViewport(end_x, end_y)
    then
        return 0
    end

    local minimum = -VIEWPORT_MARGIN
    local maximum = 1 + VIEWPORT_MARGIN
    if (start_x < minimum and end_x < minimum)
        or (start_x > maximum and end_x > maximum)
        or (start_y < minimum and end_y < minimum)
        or (start_y > maximum and end_y > maximum)
    then
        return 1
    end
    return 0
end

local function distanceSquaredToSegment(point, start_pos, end_pos)
    local segment = end_pos - start_pos
    local length_squared = segment:dot(segment)
    if not finiteNumber(length_squared) then
        return math.huge
    end
    if length_squared <= 0.000001 then
        local offset = start_pos - point
        return offset:dot(offset)
    end
    local projected = (point - start_pos):dot(segment)
    if not finiteNumber(projected) then
        return math.huge
    end
    local fraction = clamp(projected / length_squared, 0, 1)
    local offset = (start_pos + segment * fraction) - point
    local distance_squared = offset:dot(offset)
    return finiteNumber(distance_squared)
            and distance_squared
        or math.huge
end

local function retainedStateCounts()
    local beam_count = 0
    local segment_count = 0
    for _, beam in pairs(state.beams) do
        beam_count = beam_count + 1
        segment_count = segment_count + #(beam.segments or {})
    end
    return beam_count, segment_count
end

local function collectSegments(camera_pos, current_time, current_space_key)
    local packed = {}
    local expired_beams = {}
    local active_count = 0
    local culled_by_space = 0
    if current_space_key == nil then
        local retained_beams, retained_segments = retainedStateCounts()
        culled_by_space = retained_segments
        state.diagnostics.retainedBeams = retained_beams
        state.diagnostics.retainedSegments = retained_segments
        state.diagnostics.eligibleSegments = 0
        state.diagnostics.renderedSegments = 0
        state.diagnostics.culledBySpace = culled_by_space
        state.diagnostics.culledByCapacity = 0
        return packed, active_count
    end
    for id, beam in pairs(state.beams) do
        if beam.expiresAt ~= nil and current_time >= beam.expiresAt then
            expired_beams[#expired_beams + 1] = id
        elseif beam.spaceKey ~= current_space_key then
            -- State is retained for later space re-entry, but the player
            -- independently fails closed every frame.
            culled_by_space =
                culled_by_space + #(beam.segments or {})
        else
            local segments = beam.segments or {}
            local index = 1
            while index <= #segments do
                local segment = segments[index]
                if segment.expiresAt ~= nil and current_time >= segment.expiresAt then
                    table.remove(segments, index)
                else
                    active_count = active_count + 1
                    local lifecycle = segmentLifecycle(
                        segment,
                        beam,
                        current_time
                    )
                    local opacity = clamp(segment.opacity or 1, 0, 1)
                        * lifecycle
                    local base_opacity = clamp(segment.baseOpacity or 0, 0, 1)
                    if lifecycle > 0 and (opacity > 0 or base_opacity > 0) then
                        local viewport_priority = segmentViewportPriority(segment)
                        packed[#packed + 1] = {
                            segment = segment,
                            opacity = opacity,
                            lifecycle = lifecycle,
                            viewportPriority = viewport_priority,
                            distanceSquared = distanceSquaredToSegment(
                                camera_pos,
                                segment.startPos,
                             segment.endPos
                            ),
                            beamId = beam.sortKey or tostring(id),
                            producerKey = beam.producerKey,
                            priority = beam.priority or "normal",
                            freshness = tonumber(segment.createdAt)
                                or tonumber(beam.createdAt)
                                or 0,
                            compositeKey = beam.compositeRenderKey
                                or beam.sortKey
                                or tostring(id),
                            order = index,
                        }
                    end
                    index = index + 1
                end
            end
            if #segments == 0 then
                expired_beams[#expired_beams + 1] = id
            end
        end
    end
    for _, id in ipairs(expired_beams) do
        state.beams[id] = nil
    end

    local selected, schedule_stats = scheduler.select(
        packed,
        MAX_SHADER_SEGMENTS,
        state.scheduler
    )
    table.sort(selected, function(left, right)
        if left.viewportPriority ~= right.viewportPriority then
            return left.viewportPriority < right.viewportPriority
        end
        if left.distanceSquared ~= right.distanceSquared then
            return left.distanceSquared < right.distanceSquared
        end
        if left.beamId ~= right.beamId then
            return left.beamId < right.beamId
        end
        return left.order < right.order
    end)
    local retained_beams, retained_segments = retainedStateCounts()
    state.diagnostics.retainedBeams = retained_beams
    state.diagnostics.retainedSegments = retained_segments
    state.diagnostics.eligibleSegments = #packed
    state.diagnostics.renderedSegments = #selected
    state.diagnostics.culledBySpace = culled_by_space
    state.diagnostics.culledByCapacity =
        math.max(0, #packed - #selected)
    return selected, active_count, schedule_stats
end

local function quantized(value, scale)
    return math.floor((tonumber(value) or 0) * scale + 0.5)
end

local function segmentLength(segment)
    local direction = segment.endPos - segment.startPos
    return math.sqrt(math.max(0, direction:dot(direction)))
end

local function longitudinalProfile(segment)
    local longitudinal = segment.longitudinal or {
        mode = "solid",
        pathOffset = 0,
    }
    local mode = longitudinal.mode or "solid"
    local mode_id = LONGITUDINAL_MODE_ID[mode] or 0
    local taper = segment.endRadius ~= segment.startRadius
    local reverse_travel = mode == "travel"
        and (tonumber(longitudinal.speed) or 0) < 0
    local shape = encodeFeatureDistance(segment.startFadeLength)
        + encodeFeatureDistance(segment.endFadeLength) * 1024
        + mode_id * 1048576
        + (taper and 4194304 or 0)
        + (reverse_travel and 8388608 or 0)
    local end_radius = taper and segment.endRadius or 0
    local primary = 0
    local secondary = 0

    if mode == "travel" then
        -- Travel phase uses the high bit as an off-path discriminator:
        -- 0 is before the segment, 1..32767 is an active local head, and
        -- 32768..65535 is after the segment or in loop delay. The ignored
        -- low payload in the latter range still advances diagnostically.
        local visible_length = math.max(
            FEATURE_DISTANCE_MIN,
            tonumber(longitudinal.visibleLength) or FEATURE_DISTANCE_MIN
        )
        primary = visible_length
        local head_ratio = clamp(
            (tonumber(longitudinal.headFadeLength) or 0) / visible_length,
            0,
            1
        )
        local tail_ratio = clamp(
            (tonumber(longitudinal.tailFadeLength) or 0) / visible_length,
            0,
            1
        )
        secondary = quantizeUnit(head_ratio, UINT12_MAX)
            + quantizeUnit(tail_ratio, UINT12_MAX) * 4096
    elseif mode == "pulse" then
        local period = math.max(
            FEATURE_DISTANCE_MIN,
            tonumber(longitudinal.period) or FEATURE_DISTANCE_MIN
        )
        local pulse_length = clamp(
            longitudinal.pulseLength,
            FEATURE_DISTANCE_MIN,
            period
        )
        local fade_ratio = clamp(
            (tonumber(longitudinal.fadeLength) or 0)
                / math.max(pulse_length, FEATURE_DISTANCE_MIN),
            0,
            0.5
        )
        primary = period
        secondary = quantizeUnit(pulse_length / period, UINT10_MAX)
            + quantizeUnit(fade_ratio * 2, 127) * 1024
            + quantizeUnit(longitudinal.carrierLevel or 0, 127) * 131072
    elseif mode == "dash" then
        local dash_length = math.max(
            FEATURE_DISTANCE_MIN,
            tonumber(longitudinal.dashLength) or FEATURE_DISTANCE_MIN
        )
        local cycle_length = dash_length
            + math.max(0, tonumber(longitudinal.gapLength) or 0)
        local fade_ratio = clamp(
            (tonumber(longitudinal.fadeLength) or 0) / dash_length,
            0,
            0.5
        )
        primary = cycle_length
        secondary = quantizeUnit(dash_length / cycle_length, UINT12_MAX)
            + quantizeUnit(fade_ratio * 2, UINT12_MAX) * 4096
    end

    return {
        mode = mode,
        modeId = mode_id,
        taper = taper,
        reverseTravel = reverse_travel,
        shape = shape,
        endRadius = end_radius,
        primary = primary,
        secondary = secondary,
    }
end

local function paletteEntry(segment)
    if segment.paletteEntry ~= nil then
        return segment.paletteEntry
    end
    local longitudinal = longitudinalProfile(segment)
    local base_opacity = clamp(segment.baseOpacity or 0, 0, 1)
    local fog_influence = clamp(segment.fogInfluence or 0, 0, 1)
    local base_opacity_byte = base_opacity > 0
        and math.max(1, quantizeUnit(base_opacity, UINT8_MAX))
        or 0
    local fog_influence_byte = fog_influence > 0
        and math.max(1, quantizeUnit(fog_influence, UINT8_MAX))
        or 0
    local base_shape = {
        packRgb888(segment.baseColor),
        base_opacity_byte + fog_influence_byte * 256,
        math.max(0, tonumber(segment.minPixelWidth) or 0),
        math.max(0, tonumber(segment.depthSoftness) or 0),
    }
    local entry = {
        color = segment.color,
        coreColor = segment.coreColor,
        coreRatio = segment.coreRatio,
        styleScale = segment.styleScale,
        baseColor = segment.baseColor,
        baseOpacity = base_opacity,
        fogInfluence = fog_influence,
        minPixelWidth = segment.minPixelWidth,
        depthSoftness = segment.depthSoftness,
        startFadeLength = segment.startFadeLength,
        endFadeLength = segment.endFadeLength,
        endRadius = segment.endRadius,
        baseShape = base_shape,
        longitudinal = longitudinal,
    }
    entry.classKey = table.concat({
        longitudinal.mode,
        base_opacity > 0 and "base" or "nobase",
        fog_influence > 0 and "fog" or "nofog",
        entry.minPixelWidth > 0 and "pixel" or "nopixel",
        entry.depthSoftness > 0 and "soft" or "hard",
        entry.startFadeLength > 0 and "startfade" or "nostartfade",
        entry.endFadeLength > 0 and "endfade" or "noendfade",
        longitudinal.taper and "taper" or "notaper",
        longitudinal.reverseTravel and "reverse" or "forward",
    }, ":")
    entry.key = string.format(
        "%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d",
        quantized(entry.color[1], 1024),
        quantized(entry.color[2], 1024),
        quantized(entry.color[3], 1024),
        quantized(entry.coreColor[1], 1024),
        quantized(entry.coreColor[2], 1024),
        quantized(entry.coreColor[3], 1024),
        quantized(entry.coreRatio, 1024),
        quantized(entry.styleScale, 16),
        base_opacity > 0 and base_shape[1] or 0,
        base_shape[2],
        quantized(base_shape[3], 1024),
        quantized(base_shape[4], 1024),
        longitudinal.shape,
        quantized(longitudinal.endRadius, 1024),
        quantized(longitudinal.primary, 1024)
    )
    entry.key = entry.key .. ":" .. tostring(longitudinal.secondary)
    segment.paletteEntry = entry
    return entry
end

local function paletteDistance(left, right)
    local distance = 0
    for channel = 1, 3 do
        local outer_delta = left.color[channel] - right.color[channel]
        local core_delta = left.coreColor[channel] - right.coreColor[channel]
        distance = distance + outer_delta * outer_delta + core_delta * core_delta
    end
    local ratio_delta = (left.coreRatio - right.coreRatio) * 4
    local scale_delta = (left.styleScale - right.styleScale) / 64
    local feature_distance = 0
    if left.baseOpacity > 0 then
        local base_opacity_delta = left.baseOpacity - right.baseOpacity
        feature_distance = feature_distance
            + base_opacity_delta * base_opacity_delta
        for channel = 1, 3 do
            local base_delta =
                left.baseColor[channel] - right.baseColor[channel]
            feature_distance = feature_distance + base_delta * base_delta
        end
    end
    if left.fogInfluence > 0 then
        local fog_delta = left.fogInfluence - right.fogInfluence
        feature_distance = feature_distance + fog_delta * fog_delta
    end
    if left.minPixelWidth > 0 then
        local pixel_delta =
            (left.minPixelWidth - right.minPixelWidth) / 32
        feature_distance = feature_distance + pixel_delta * pixel_delta
    end
    if left.depthSoftness > 0 then
        local depth_delta =
            (left.depthSoftness - right.depthSoftness) / 512
        feature_distance = feature_distance + depth_delta * depth_delta
    end
    if left.startFadeLength > 0 then
        local start_fade_delta = (
            left.startFadeLength - right.startFadeLength
        ) / FEATURE_DISTANCE_MAX
        feature_distance = feature_distance
            + start_fade_delta * start_fade_delta
    end
    if left.endFadeLength > 0 then
        local end_fade_delta = (
            left.endFadeLength - right.endFadeLength
        ) / FEATURE_DISTANCE_MAX
        feature_distance = feature_distance
            + end_fade_delta * end_fade_delta
    end
    if left.longitudinal.taper then
        local end_radius_delta =
            (left.endRadius - right.endRadius) / 512
        feature_distance = feature_distance
            + end_radius_delta * end_radius_delta
    end
    if left.longitudinal.mode ~= "solid" then
        local logarithmic_scale = math.log(1 + FEATURE_DISTANCE_MAX)
        local primary_delta = (
            math.log(1 + math.max(0, left.longitudinal.primary))
                - math.log(1 + math.max(0, right.longitudinal.primary))
        ) / logarithmic_scale
        local secondary_delta = (
            left.longitudinal.secondary - right.longitudinal.secondary
        ) / 16777215
        feature_distance = feature_distance
            + primary_delta * primary_delta
            + secondary_delta * secondary_delta
    end
    return distance
        + ratio_delta * ratio_delta
        + scale_delta * scale_delta
        + feature_distance
end

local function nearestPaletteIndex(entry, palettes)
    local best_index = nil
    local best_distance = math.huge
    for index, candidate in ipairs(palettes) do
        if candidate.classKey == entry.classKey then
            local distance = paletteDistance(entry, candidate)
            if distance < best_distance then
                best_index = index
                best_distance = distance
            end
        end
    end
    return best_index
end

local function buildPalettes(segments, count)
    local palettes = {}
    local by_key = {}
    local by_class = {}
    local overflow = false

    local function add(entry)
        local existing = by_key[entry.key]
        if existing ~= nil then
            return existing
        end
        if #palettes >= MAX_SHADER_PALETTES then
            return nil
        end
        local palette_index = #palettes + 1
        palettes[palette_index] = entry
        by_key[entry.key] = palette_index
        by_class[entry.classKey] = true
        return palette_index
    end

    -- Reserve one profile for every discrete behavior class before spending
    -- spare entries on closer color/shape matches. Overflow may approximate
    -- continuous values, but can never turn a mode or opt-in feature into
    -- another behavior.
    for index = 1, count do
        local packed = segments[index]
        local entry = paletteEntry(packed.segment)
        if not by_class[entry.classKey] and add(entry) == nil then
            overflow = true
        end
    end
    for index = 1, count do
        local entry = paletteEntry(segments[index].segment)
        if by_key[entry.key] == nil and add(entry) == nil then
            overflow = true
        end
    end

    local renderable = {}
    for index = 1, count do
        local packed = segments[index]
        local entry = paletteEntry(packed.segment)
        local palette_index = by_key[entry.key]
            or nearestPaletteIndex(entry, palettes)
        if palette_index ~= nil then
            packed.paletteIndex = palette_index - 1
            renderable[#renderable + 1] = packed
        else
            overflow = true
        end
    end
    return palettes, overflow, renderable
end

local function paletteSignature(palettes)
    local keys = {}
    for index, entry in ipairs(palettes) do
        keys[index] = entry.key
    end
    return table.concat(keys, "|")
end

local function writePaletteArrays(palettes)
    local outer = state.uniforms.paletteOuter
    local core = state.uniforms.paletteCore
    local base_shape = state.uniforms.paletteBaseShape
    local longitudinal = state.uniforms.paletteLongitudinal
    for index, entry in ipairs(palettes) do
        outer[index] = util.vector4(
            entry.color[1],
            entry.color[2],
            entry.color[3],
            entry.coreRatio
        )
        core[index] = util.vector4(
            entry.coreColor[1],
            entry.coreColor[2],
            entry.coreColor[3],
            entry.styleScale
        )
        base_shape[index] = util.vector4(
            entry.baseShape[1],
            entry.baseShape[2],
            entry.baseShape[3],
            entry.baseShape[4]
        )
        longitudinal[index] = util.vector4(
            entry.longitudinal.shape,
            entry.longitudinal.endRadius,
            entry.longitudinal.primary,
            entry.longitudinal.secondary
        )
    end
    for index = #palettes + 1, MAX_SHADER_PALETTES do
        outer[index] = ZERO_VECTOR4
        core[index] = ZERO_VECTOR4
        base_shape[index] = ZERO_VECTOR4
        longitudinal[index] = ZERO_VECTOR4
    end
end

local function longitudinalPhase(segment, current_time)
    local longitudinal = segment.longitudinal or { mode = "solid" }
    local mode = longitudinal.mode or "solid"
    if mode == "solid" then
        return 0
    end

    local animation_started_at = tonumber(segment.animationStartedAt) or current_time
    local age = math.max(0, current_time - animation_started_at)
    local speed = tonumber(longitudinal.speed) or 0
    local path_offset = tonumber(longitudinal.pathOffset) or 0

    if mode == "travel" then
        local visible_length = math.max(
            FEATURE_DISTANCE_MIN,
            tonumber(longitudinal.visibleLength) or FEATURE_DISTANCE_MIN
        )
        local travel_distance = math.abs(speed) * age
        local loop_length = 0
        if longitudinal.loop == true then
            loop_length = math.max(
                FEATURE_DISTANCE_MIN,
                tonumber(longitudinal.loopLength) or segmentLength(segment)
            )
            local active_distance = loop_length + visible_length
            local delay_distance = math.abs(speed)
                * math.max(0, tonumber(longitudinal.loopDelay) or 0)
            local cycle_distance = active_distance + delay_distance
            travel_distance = positiveModulo(travel_distance, cycle_distance)
            if travel_distance >= active_distance then
                return 32768 + (
                    math.floor(travel_distance * 257 + 0.5) % 32768
                )
            end
        end

        local current_segment_length = segmentLength(segment)
        local oriented_path_offset = path_offset
        if speed < 0 and longitudinal.loop == true then
            -- Reverse travel begins at loopLength and visits connected
            -- segments in decreasing path-coordinate order. The shader flips
            -- local segment T; this offset supplies the matching global order.
            oriented_path_offset = loop_length
                - (path_offset + current_segment_length)
        end
        local local_head = travel_distance - oriented_path_offset
        local active_local_length = current_segment_length + visible_length
        if local_head <= 0 then
            return 0
        end
        if local_head >= active_local_length then
            return 32768 + (
                math.floor(math.abs(local_head) * 257 + 0.5) % 32768
            )
        end
        return math.max(
            1,
            math.min(
                32767,
                math.floor(
                    local_head / active_local_length * 32767 + 0.5
                )
            )
        )
    end

    local period
    if mode == "pulse" then
        period = tonumber(longitudinal.period) or FEATURE_DISTANCE_MIN
    else
        period = (tonumber(longitudinal.dashLength) or FEATURE_DISTANCE_MIN)
            + math.max(0, tonumber(longitudinal.gapLength) or 0)
    end
    period = math.max(FEATURE_DISTANCE_MIN, period)
    -- The shader adds this offset to distance along the segment. Subtracting
    -- speed*time makes a positive speed move the visible pattern toward the
    -- segment end while pathOffset keeps adjacent segments continuous.
    local phase_distance = positiveModulo(
        path_offset - speed * age,
        period
    )
    return math.floor(phase_distance / period * UINT16_MAX + 0.5)
end

local function writeFeatureState(segments, count, current_time)
    local packed_values = {}
    for index = 1, count do
        local packed = segments[index]
        local lifecycle = quantizeUnit(packed.lifecycle or 1, UINT8_MAX)
        local phase = longitudinalPhase(packed.segment, current_time)
        packed_values[index] = lifecycle + phase * 256
    end
    for index = count + 1, MAX_SHADER_SEGMENTS do
        packed_values[index] = 0
    end

    local feature_state = state.uniforms.featureState
    for block = 1, MAX_SHADER_PALETTES do
        local offset = (block - 1) * 4
        feature_state[block] = util.vector4(
            packed_values[offset + 1],
            packed_values[offset + 2],
            packed_values[offset + 3],
            packed_values[offset + 4]
        )
    end
end

local function upload(
    shader,
    camera_pos,
    segments,
    active_count,
    eligible_count,
    current_time
)
    local candidate_count = math.min(#segments, MAX_SHADER_SEGMENTS)
    local palettes, palette_overflow, renderable = buildPalettes(
        segments,
        candidate_count
    )
    segments = renderable
    local count = #segments
    local new_palette_signature = paletteSignature(palettes)
    local palette_changed = new_palette_signature ~= state.paletteSignature
    if palette_changed then
        writePaletteArrays(palettes)
    end

    local starts = state.uniforms.starts
    local ends = state.uniforms.ends
    writeFeatureState(segments, count, current_time)
    for index = 1, count do
        local packed = segments[index]
        local segment = packed.segment
        local start_relative = segment.startPos - camera_pos
        local end_relative = segment.endPos - camera_pos
        local metadata = beam_styles.encodeMetadata(
            segment.style,
            packed.paletteIndex,
            packed.opacity,
            segment.intensity,
            segment.seed
        )
        starts[index] = util.vector4(
            start_relative.x,
            start_relative.y,
            start_relative.z,
            segment.startRadius
        )
        ends[index] = util.vector4(
            end_relative.x,
            end_relative.y,
            end_relative.z,
            metadata
        )
    end
    for index = count + 1, state.lastUploadedCount do
        starts[index] = ZERO_VECTOR4
        ends[index] = ZERO_VECTOR4
    end

    local ok, err = pcall(function()
        if palette_changed then
            shader:setVector4Array("bfxPaletteOuterCore", state.uniforms.paletteOuter)
            shader:setVector4Array("bfxPaletteCoreGeometry", state.uniforms.paletteCore)
            shader:setVector4Array(
                "bfxPaletteBaseShape",
                state.uniforms.paletteBaseShape
            )
            shader:setVector4Array(
                "bfxPaletteLongitudinal",
                state.uniforms.paletteLongitudinal
            )
        end
        shader:setVector4Array("bfxSegmentStartRadius", starts)
        shader:setVector4Array("bfxSegmentEndMetadata", ends)
        shader:setVector4Array(
            "bfxSegmentFeatureState",
            state.uniforms.featureState
        )
        shader:setInt("bfxSegmentCount", count)
    end)
    if not ok then
        state.diagnostics.uploadHealthy = false
        if not state.uploadFailureLogged then
            state.uploadFailureLogged = true
            log.warn(string.format(
                "Beam shader uniform upload failed err=%s",
                tostring(err)
            ))
        end
        return false
    end
    state.uploadFailureLogged = false
    state.nextUploadRetryAt = 0
    state.diagnostics.uploadHealthy = true
    state.diagnostics.paletteCount = #palettes
    state.diagnostics.paletteOverflow = palette_overflow
    state.diagnostics.renderedSegments = count

    state.lastUploadedCount = count
    if palette_changed then
        state.paletteSignature = new_palette_signature
    end

    eligible_count = tonumber(eligible_count) or #segments
    state.diagnostics.culledByCapacity = math.max(0, eligible_count - count)
    if eligible_count > count
        and not state.overflowLogged
    then
        state.overflowLogged = true
        log.warn(string.format(
            "Beam visual capacity reached eligible=%d rendered=%d active=%d; gameplay remains active",
            eligible_count,
            count,
            active_count
        ))
    elseif eligible_count <= count then
        state.overflowLogged = false
    end

    if palette_overflow and not state.paletteOverflowLogged then
        state.paletteOverflowLogged = true
        log.warn(string.format(
            "Beam palette capacity reached renderedPalettes=%d; closest appearances are reused",
            MAX_SHADER_PALETTES
        ))
    elseif not palette_overflow then
        state.paletteOverflowLogged = false
    end
    return true
end

local function hasAnyBeams()
    return next(state.beams) ~= nil
end

local function disableWhenEmpty()
    if not hasAnyBeams()
        and (state.shaderRequested or shaderEnabled() or state.lastUploadedCount > 0)
    then
        disableShader()
    end
end

local function removeRenderKeys(keys)
    for _, key in ipairs(keys or {}) do
        state.beams[key] = nil
    end
end

local function clearFrameworkBeams()
    state.beams = {}
    scheduler.reset(state.scheduler)
    disableWhenEmpty()
end

function beam_renderer.beginRendererSession(renderer_session)
    local accepted, err = protocol_state.beginRendererSession(
        state.protocol,
        renderer_session
    )
    if not accepted then
        return false, err
    end
    clearFrameworkBeams()
    return true
end

local function handleProtocolResult(result)
    removeRenderKeys(result and result.removedKeys)
    if result and result.clear then
        clearFrameworkBeams()
    end
    if result and result.requestResync and type(state.resyncHandler) == "function" then
        pcall(state.resyncHandler, result.resyncReason or "renderer_resync")
    end
end

local function renderBeamFromPacket(packet)
    local lifecycle = packet.lifecycle
    local beam = {
        id = packet.compositeRenderKey,
        sortKey = packet.compositeRenderKey,
        compositeRenderKey = packet.compositeRenderKey,
        producerKey = protocol.producerKey(packet),
        revision = packet.revision,
        animationStartedAt = packet.animationStartedAt,
        createdAt = lifecycle.createdAt,
        fadeStartAt = lifecycle.fadeStartAt,
        expiresAt = lifecycle.expiresAt,
        spaceKey = packet.spaceKey,
        priority = packet.priority,
        style = "smooth",
        segments = {},
    }
    for index, segment in ipairs(packet.segments) do
        local copied = copyProtocolSegment(segment, beam, index)
        if copied ~= nil then
            beam.segments[#beam.segments + 1] = copied
        end
    end
    if #beam.segments == #packet.segments and #beam.segments > 0 then
        return beam
    end
    return nil
end

function beam_renderer.setResyncHandler(handler)
    state.resyncHandler = type(handler) == "function" and handler or nil
end

function beam_renderer.protocolStatus()
    local status = protocol_state.status(state.protocol)
    for name, value in pairs(state.diagnostics) do
        status[name] = value
    end
    status.rendererAvailable = postprocessingAvailable()
    status.shaderLoaded = state.shader ~= nil
    status.shaderEnabled = shaderEnabled()
    return status
end

function beam_renderer.onSnapshot(payload)
    local result = protocol_state.applySnapshot(state.protocol, payload)
    handleProtocolResult(result)
    if not result.accepted then
        return false, result.error
    end
    local beam = renderBeamFromPacket(result.packet)
    if beam == nil then
        return false, "invalid_render_packet"
    end
    state.beams[result.packet.compositeRenderKey] = beam
    return true
end

function beam_renderer.onProtocolRemove(payload)
    local result = protocol_state.applyRemove(state.protocol, payload)
    handleProtocolResult(result)
    if not result.accepted then
        return false, result.error
    end
    state.beams[result.packet.compositeRenderKey] = nil
    disableWhenEmpty()
    return true
end

function beam_renderer.onProviderReset(payload)
    local result = protocol_state.applyProviderReset(state.protocol, payload)
    handleProtocolResult(result)
    if result.accepted and result.clear then
        scheduler.reset(state.scheduler)
    end
    return result.accepted, result.error
end

function beam_renderer.onViewerReconcileReset(payload)
    local result = protocol_state.applyViewerReconcileReset(state.protocol, payload)
    handleProtocolResult(result)
    return result.accepted, result.error
end

function beam_renderer.onFrame()
    local current_time = now()
    local ok_camera, camera_pos = pcall(camera.getPosition)
    if not ok_camera or camera_pos == nil then
        state.diagnostics.eligibleSegments = 0
        state.diagnostics.renderedSegments = 0
        if state.shaderRequested
            or shaderEnabled()
            or state.lastUploadedCount > 0
        then
            disableShader()
        end
        return
    end
    local segments, active_count = collectSegments(
        camera_pos,
        current_time,
        currentSpaceKey()
    )
    if #segments == 0 then
        if state.shaderRequested or shaderEnabled() or state.lastUploadedCount > 0 then
            disableShader()
        end
        return
    end

    local shader = ensureShader(current_time)
    if shader == nil then
        return
    end
    if current_time < state.nextUploadRetryAt then
        return
    end
    if not requestShaderEnable(shader, current_time) then
        return
    end
    if not upload(
        shader,
        camera_pos,
        segments,
        active_count,
        state.diagnostics.eligibleSegments,
        current_time
    ) then
        disableShader(true)
        state.nextUploadRetryAt =
            current_time + SHADER_RETRY_SECONDS
    end
end

function beam_renderer.capacity()
    return MAX_SHADER_SEGMENTS
end

return beam_renderer
