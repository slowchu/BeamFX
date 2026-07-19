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

local SHADER_NAME = "beamfx_core"
local MAX_SHADER_SEGMENTS = beam_styles.SEGMENT_CAPACITY
local MAX_SHADER_PALETTES = beam_styles.PALETTE_CAPACITY
local SHADER_RETRY_SECONDS = 5
local VIEWPORT_MARGIN = 0.20
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
        paletteOuter = {},
        paletteCore = {},
    },
}

for index = 1, MAX_SHADER_SEGMENTS do
    state.uniforms.starts[index] = ZERO_VECTOR4
    state.uniforms.ends[index] = ZERO_VECTOR4
end
for index = 1, MAX_SHADER_PALETTES do
    state.uniforms.paletteOuter[index] = ZERO_VECTOR4
    state.uniforms.paletteCore[index] = ZERO_VECTOR4
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
        width = segment.radius,
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
        intensity = segment.intensity,
        opacity = segment.opacity,
        style = segment.style,
        styleScale = segment.styleScale,
        seed = segment.seed,
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

local function segmentOpacity(segment, beam, current_time)
    local expires_at = tonumber(segment.expiresAt)
    local opacity = clamp(segment.opacity or 1, 0, 1)
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
    return opacity * segment_factor * beam_factor
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
                    local opacity = segmentOpacity(
                        segment,
                        beam,
                        current_time
                    )
                    if opacity > 0 then
                        local viewport_priority = segmentViewportPriority(segment)
                        packed[#packed + 1] = {
                            segment = segment,
                            opacity = opacity,
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

local function paletteEntry(segment)
    if segment.paletteEntry ~= nil then
        return segment.paletteEntry
    end
    local entry = {
        color = segment.color,
        coreColor = segment.coreColor,
        coreRatio = segment.coreRatio,
        styleScale = segment.styleScale,
    }
    entry.key = string.format(
        "%d:%d:%d:%d:%d:%d:%d:%d",
        quantized(entry.color[1], 1024),
        quantized(entry.color[2], 1024),
        quantized(entry.color[3], 1024),
        quantized(entry.coreColor[1], 1024),
        quantized(entry.coreColor[2], 1024),
        quantized(entry.coreColor[3], 1024),
        quantized(entry.coreRatio, 1024),
        quantized(entry.styleScale, 16)
    )
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
    return distance + ratio_delta * ratio_delta + scale_delta * scale_delta
end

local function nearestPaletteIndex(entry, palettes)
    local best_index = 1
    local best_distance = math.huge
    for index, candidate in ipairs(palettes) do
        local distance = paletteDistance(entry, candidate)
        if distance < best_distance then
            best_index = index
            best_distance = distance
        end
    end
    return best_index
end

local function buildPalettes(segments, count)
    local palettes = {}
    local by_key = {}
    local overflow = false
    for index = 1, count do
        local packed = segments[index]
        local entry = paletteEntry(packed.segment)
        local key = entry.key
        local palette_index = by_key[key]
        if palette_index == nil then
            if #palettes < MAX_SHADER_PALETTES then
                palette_index = #palettes + 1
                entry.key = key
                palettes[palette_index] = entry
                by_key[key] = palette_index
            else
                overflow = true
                palette_index = nearestPaletteIndex(entry, palettes)
                by_key[key] = palette_index
            end
        end
        packed.paletteIndex = palette_index - 1
    end
    return palettes, overflow
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
    end
    for index = #palettes + 1, MAX_SHADER_PALETTES do
        outer[index] = ZERO_VECTOR4
        core[index] = ZERO_VECTOR4
    end
end

local function upload(
    shader,
    camera_pos,
    segments,
    active_count,
    eligible_count
)
    local count = math.min(#segments, MAX_SHADER_SEGMENTS)
    local palettes, palette_overflow = buildPalettes(segments, count)
    local new_palette_signature = paletteSignature(palettes)
    local palette_changed = new_palette_signature ~= state.paletteSignature
    if palette_changed then
        writePaletteArrays(palettes)
    end

    local starts = state.uniforms.starts
    local ends = state.uniforms.ends
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
            segment.width
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
        end
        shader:setVector4Array("bfxSegmentStartRadius", starts)
        shader:setVector4Array("bfxSegmentEndMetadata", ends)
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

    state.lastUploadedCount = count
    if palette_changed then
        state.paletteSignature = new_palette_signature
    end

    eligible_count = tonumber(eligible_count) or #segments
    if eligible_count > MAX_SHADER_SEGMENTS
        and not state.overflowLogged
    then
        state.overflowLogged = true
        log.warn(string.format(
            "Beam visual capacity reached eligible=%d rendered=%d active=%d; gameplay remains active",
            eligible_count,
            MAX_SHADER_SEGMENTS,
            active_count
        ))
    elseif eligible_count <= MAX_SHADER_SEGMENTS then
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
        state.diagnostics.eligibleSegments
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
