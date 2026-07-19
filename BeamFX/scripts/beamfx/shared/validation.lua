---@omw-context global | player | none

local constants = require("scripts.beamfx.shared.constants")
local space = require("scripts.beamfx.shared.space")
local styles = require("scripts.beamfx.shared.styles")

local validation = {}

local PRODUCER_KEYS = {
    id = true,
    displayName = true,
    apiMajor = true,
    apiMinor = true,
}

local BEAM_KEYS = {
    spaceKey = true,
    lifecycle = true,
    audience = true,
    priority = true,
    maxSegments = true,
    segments = true,
}

local LIFECYCLE_KEYS = {
    mode = true,
    duration = true,
    fadeDuration = true,
    leaseSeconds = true,
}

local AUDIENCE_KEYS = {
    mode = true,
}

local SEGMENT_KEYS = {
    startPos = true,
    endPos = true,
    radius = true,
    outerColor = true,
    coreColor = true,
    coreRatio = true,
    intensity = true,
    opacity = true,
    style = true,
    styleScale = true,
    seed = true,
    originGlow = true,
    duration = true,
    fadeDuration = true,
}

local SEGMENT_OPTIONS_KEYS = {
    duration = true,
    fadeDuration = true,
}

local FINISH_OPTIONS_KEYS = {
    holdDuration = true,
    fadeDuration = true,
}

local PRIORITIES = {
    low = true,
    normal = true,
    high = true,
}

local function isFinite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function hasOnlyKeys(value, allowed)
    if type(value) ~= "table" then
        return false
    end
    for key in next, value do
        if type(key) ~= "string" or not allowed[key] then
            return false
        end
    end
    return true
end

local function boundedString(value, maximum, allow_empty)
    return type(value) == "string"
        and (allow_empty == true or value ~= "")
        and #value <= maximum
        and value:find("[%z\1-\31\127]") == nil
end

local function guardedComponent(value, named_key, numeric_key)
    if type(value) == "table" then
        local named = rawget(value, named_key)
        if named ~= nil then
            return named
        end
        return rawget(value, numeric_key)
    end
    if type(value) ~= "userdata" then
        return nil
    end
    local ok, component = pcall(function()
        return value[named_key]
    end)
    if ok and component ~= nil then
        return component
    end
    ok, component = pcall(function()
        return value[numeric_key]
    end)
    if ok then
        return component
    end
    return nil
end

local function normalizeVector(value)
    if type(value) ~= "table" and type(value) ~= "userdata" then
        return nil, "invalid_spec"
    end
    local x = guardedComponent(value, "x", 1)
    local y = guardedComponent(value, "y", 2)
    local z = guardedComponent(value, "z", 3)
    if not isFinite(x) or not isFinite(y) or not isFinite(z)
        or math.abs(x) > constants.MAX_ABS_COORDINATE
        or math.abs(y) > constants.MAX_ABS_COORDINATE
        or math.abs(z) > constants.MAX_ABS_COORDINATE
    then
        return nil, "invalid_spec"
    end
    return { x = x, y = y, z = z }
end

local function normalizeColor(value, fallback)
    if value == nil then
        fallback = fallback or constants.DEFAULT_OUTER_COLOR
        return { fallback[1], fallback[2], fallback[3] }
    end
    if type(value) ~= "table" and type(value) ~= "userdata" then
        return nil, "invalid_spec"
    end

    local red = guardedComponent(value, "r", 1)
    local green = guardedComponent(value, "g", 2)
    local blue = guardedComponent(value, "b", 3)
    if red == nil then
        red = guardedComponent(value, "x", 1)
    end
    if green == nil then
        green = guardedComponent(value, "y", 2)
    end
    if blue == nil then
        blue = guardedComponent(value, "z", 3)
    end
    if not isFinite(red) or not isFinite(green) or not isFinite(blue) then
        return nil, "invalid_spec"
    end
    return {
        clamp(red, 0, 4),
        clamp(green, 0, 4),
        clamp(blue, 0, 4),
    }
end

local function normalizeFinite(value, fallback, minimum, maximum)
    if value == nil then
        value = fallback
    end
    if not isFinite(value) then
        return nil, "invalid_spec"
    end
    return clamp(value, minimum, maximum)
end

local function arrayLength(value, hard_maximum)
    if type(value) ~= "table" then
        return nil, "invalid_spec"
    end
    local count = 0
    local highest = 0
    for key in next, value do
        if type(key) ~= "number"
            or not isFinite(key)
            or key < 1
            or key ~= math.floor(key)
        then
            return nil, "invalid_spec"
        end
        count = count + 1
        highest = math.max(highest, key)
        if count > hard_maximum or highest > hard_maximum then
            return nil, "segment_quota_exceeded"
        end
    end
    if count == 0 then
        return 0
    end
    if highest ~= count then
        return nil, "invalid_spec"
    end
    for index = 1, count do
        if rawget(value, index) == nil then
            return nil, "invalid_spec"
        end
    end
    return count
end

local function normalizeRelativeDuration(duration, fade_duration, default_fade)
    if duration == nil then
        if fade_duration ~= nil then
            return nil, nil, "invalid_spec"
        end
        return nil, nil
    end
    if not isFinite(duration) or duration <= 0 then
        return nil, nil, "invalid_spec"
    end
    if fade_duration == nil then
        fade_duration = math.min(default_fade, duration)
    elseif not isFinite(fade_duration) or fade_duration < 0 then
        return nil, nil, "invalid_spec"
    else
        fade_duration = math.min(fade_duration, duration)
    end
    return duration, fade_duration
end

function validation.isFinite(value)
    return isFinite(value)
end

function validation.normalizeProducerId(value)
    if not boundedString(value, constants.MAX_PRODUCER_ID_LENGTH, false) then
        return nil, "invalid_producer_id"
    end
    local normalized = value:lower()
    if normalized:match("^[a-z0-9][a-z0-9._%-]*$") == nil then
        return nil, "invalid_producer_id"
    end
    return normalized
end

function validation.normalizeProducerSpec(value)
    if not hasOnlyKeys(value, PRODUCER_KEYS) then
        return nil, "invalid_spec"
    end

    local producer_id, err = validation.normalizeProducerId(rawget(value, "id"))
    if producer_id == nil then
        return nil, err
    end
    local api_major = rawget(value, "apiMajor")
    if not isFinite(api_major)
        or api_major ~= math.floor(api_major)
        or api_major ~= constants.API_MAJOR
    then
        return nil, "unsupported_api"
    end
    local api_minor = rawget(value, "apiMinor")
    if api_minor == nil then
        api_minor = 0
    end
    if not isFinite(api_minor) or api_minor < 0 or api_minor ~= math.floor(api_minor) then
        return nil, "invalid_spec"
    end

    local display_name = rawget(value, "displayName")
    if display_name == nil then
        display_name = producer_id
    elseif not boundedString(
        display_name,
        constants.MAX_PRODUCER_DISPLAY_NAME_LENGTH,
        false
    ) then
        return nil, "invalid_spec"
    end

    return {
        id = producer_id,
        displayName = display_name,
        apiMajor = api_major,
        apiMinor = api_minor,
    }
end

function validation.normalizeBeamId(value)
    if not boundedString(value, constants.MAX_BEAM_ID_LENGTH, false) then
        return nil, "invalid_beam_id"
    end
    return value
end

function validation.normalizeReason(value, fallback)
    if value == nil then
        value = fallback
    end
    if value == nil then
        return nil
    end
    if not boundedString(value, constants.MAX_REASON_LENGTH, true) then
        return nil, "invalid_spec"
    end
    return value
end

function validation.normalizeSpaceKey(value)
    return space.normalizeKey(value)
end

function validation.normalizeAudience(value)
    if value == nil then
        return { mode = constants.DEFAULT_AUDIENCE_MODE }
    end
    if not hasOnlyKeys(value, AUDIENCE_KEYS)
        or rawget(value, "mode") ~= constants.DEFAULT_AUDIENCE_MODE
    then
        return nil, "invalid_spec"
    end
    return { mode = constants.DEFAULT_AUDIENCE_MODE }
end

function validation.normalizePriority(value)
    if value == nil then
        return constants.DEFAULT_PRIORITY
    end
    if type(value) ~= "string" then
        return nil, "invalid_priority"
    end
    local normalized = value:lower()
    if not PRIORITIES[normalized] then
        return nil, "invalid_priority"
    end
    return normalized
end

function validation.normalizeLifecycle(value)
    if not hasOnlyKeys(value, LIFECYCLE_KEYS) then
        return nil, "invalid_lifecycle"
    end
    local mode = rawget(value, "mode")
    if mode == "transient" then
        if rawget(value, "leaseSeconds") ~= nil then
            return nil, "invalid_lifecycle"
        end
        local duration = rawget(value, "duration")
        local fade_duration = rawget(value, "fadeDuration")
        if not isFinite(duration) or duration <= 0 then
            return nil, "invalid_lifecycle"
        end
        if fade_duration == nil then
            fade_duration = 0
        elseif not isFinite(fade_duration) or fade_duration < 0 then
            return nil, "invalid_lifecycle"
        end
        return {
            mode = mode,
            duration = duration,
            fadeDuration = math.min(fade_duration, duration),
        }
    end
    if mode == "persistent" then
        if rawget(value, "duration") ~= nil
            or rawget(value, "fadeDuration") ~= nil
        then
            return nil, "invalid_lifecycle"
        end
        local lease_seconds = rawget(value, "leaseSeconds")
        if lease_seconds ~= nil
            and (not isFinite(lease_seconds) or lease_seconds <= 0)
        then
            return nil, "invalid_lifecycle"
        end
        return {
            mode = mode,
            leaseSeconds = lease_seconds,
        }
    end
    return nil, "invalid_lifecycle"
end

function validation.normalizeMaxSegments(value)
    if value == nil then
        return constants.DEFAULT_MAX_SEGMENTS
    end
    if not isFinite(value) then
        return nil, "invalid_spec"
    end
    return math.floor(clamp(value, 1, constants.MAX_SEGMENTS_PER_BEAM))
end

function validation.normalizeSegmentOptions(value)
    if value == nil then
        return {}
    end
    if not hasOnlyKeys(value, SEGMENT_OPTIONS_KEYS) then
        return nil, "invalid_spec"
    end
    local duration = rawget(value, "duration")
    local fade_duration = rawget(value, "fadeDuration")
    if duration ~= nil and (not isFinite(duration) or duration <= 0) then
        return nil, "invalid_spec"
    end
    if fade_duration ~= nil and (not isFinite(fade_duration) or fade_duration < 0) then
        return nil, "invalid_spec"
    end
    if duration ~= nil and fade_duration ~= nil then
        fade_duration = math.min(fade_duration, duration)
    end
    return {
        duration = duration,
        fadeDuration = fade_duration,
    }
end

function validation.normalizeSegment(value, operation_options)
    if not hasOnlyKeys(value, SEGMENT_KEYS) then
        return nil, "invalid_spec"
    end
    local err
    operation_options, err = validation.normalizeSegmentOptions(operation_options)
    if operation_options == nil then
        return nil, err
    end

    local start_pos
    start_pos, err = normalizeVector(rawget(value, "startPos"))
    if start_pos == nil then
        return nil, err
    end
    local end_pos
    end_pos, err = normalizeVector(rawget(value, "endPos"))
    if end_pos == nil then
        return nil, err
    end
    local outer_color
    outer_color, err = normalizeColor(
        rawget(value, "outerColor"),
        constants.DEFAULT_OUTER_COLOR
    )
    if outer_color == nil then
        return nil, err
    end
    local core_color
    core_color, err = normalizeColor(
        rawget(value, "coreColor"),
        constants.DEFAULT_CORE_COLOR
    )
    if core_color == nil then
        return nil, err
    end

    local radius
    radius, err = normalizeFinite(rawget(value, "radius"), constants.DEFAULT_RADIUS, 0.25, 512)
    if radius == nil then
        return nil, err
    end
    local core_ratio
    core_ratio, err = normalizeFinite(
        rawget(value, "coreRatio"),
        constants.DEFAULT_CORE_RATIO,
        0.02,
        1
    )
    if core_ratio == nil then
        return nil, err
    end
    local intensity
    intensity, err = normalizeFinite(
        rawget(value, "intensity"),
        constants.DEFAULT_INTENSITY,
        0,
        8
    )
    if intensity == nil then
        return nil, err
    end
    local opacity
    opacity, err = normalizeFinite(
        rawget(value, "opacity"),
        constants.DEFAULT_OPACITY,
        0,
        1
    )
    if opacity == nil then
        return nil, err
    end
    local style_scale
    style_scale, err = normalizeFinite(
        rawget(value, "styleScale"),
        constants.DEFAULT_STYLE_SCALE,
        0,
        512
    )
    if style_scale == nil then
        return nil, err
    end

    local style_value = rawget(value, "style")
    local style = nil
    if style_value == nil then
        style = constants.DEFAULT_STYLE
    else
        style = styles.canonical(style_value)
        if style == nil then
            return nil, "invalid_style"
        end
    end

    local origin_glow = rawget(value, "originGlow")
    if origin_glow == nil then
        origin_glow = false
    elseif type(origin_glow) ~= "boolean" then
        return nil, "invalid_spec"
    end
    local seed = rawget(value, "seed")
    if seed ~= nil
        and (not isFinite(seed)
            or seed ~= math.floor(seed)
            or seed < 0
            or seed > 15)
    then
        return nil, "invalid_spec"
    end
    if origin_glow then
        if style ~= "plasma" or (seed ~= nil and seed ~= 0) then
            return nil, "invalid_spec"
        end
        seed = 0
    elseif style == "plasma" and seed == 0 then
        return nil, "invalid_spec"
    end

    local duration = rawget(value, "duration")
    if duration == nil then
        duration = operation_options.duration
    end
    local fade_duration = rawget(value, "fadeDuration")
    if fade_duration == nil then
        fade_duration = operation_options.fadeDuration
    end
    duration, fade_duration, err = normalizeRelativeDuration(
        duration,
        fade_duration,
        constants.DEFAULT_FINISH_FADE_DURATION
    )
    if err ~= nil then
        return nil, err
    end

    return {
        startPos = start_pos,
        endPos = end_pos,
        radius = radius,
        outerColor = outer_color,
        coreColor = core_color,
        coreRatio = core_ratio,
        intensity = intensity,
        opacity = opacity,
        style = style,
        styleScale = style_scale,
        seed = seed,
        originGlow = origin_glow,
        duration = duration,
        fadeDuration = fade_duration,
    }
end

function validation.normalizeSegments(value, max_segments, operation_options)
    max_segments = max_segments or constants.DEFAULT_MAX_SEGMENTS
    if not isFinite(max_segments) then
        return nil, "invalid_spec"
    end
    max_segments = math.floor(clamp(max_segments, 1, constants.MAX_SEGMENTS_PER_BEAM))

    local options, err = validation.normalizeSegmentOptions(operation_options)
    if options == nil then
        return nil, err
    end
    local count
    count, err = arrayLength(value, constants.MAX_INPUT_SEGMENTS)
    if count == nil then
        return nil, err
    end
    if count == 0 then
        return nil, "no_valid_segments"
    end
    if count > max_segments then
        return nil, "segment_quota_exceeded"
    end

    local normalized = {}
    for index = 1, count do
        local segment
        segment, err = validation.normalizeSegment(rawget(value, index), options)
        if segment == nil then
            return nil, err
        end
        normalized[index] = segment
    end
    return normalized
end

function validation.normalizeBeamSpec(value)
    if not hasOnlyKeys(value, BEAM_KEYS) then
        return nil, "invalid_spec"
    end
    local space_key, err = validation.normalizeSpaceKey(rawget(value, "spaceKey"))
    if space_key == nil then
        return nil, err
    end
    local lifecycle
    lifecycle, err = validation.normalizeLifecycle(rawget(value, "lifecycle"))
    if lifecycle == nil then
        return nil, err
    end
    local audience
    audience, err = validation.normalizeAudience(rawget(value, "audience"))
    if audience == nil then
        return nil, err
    end
    local priority
    priority, err = validation.normalizePriority(rawget(value, "priority"))
    if priority == nil then
        return nil, err
    end
    local max_segments
    max_segments, err = validation.normalizeMaxSegments(rawget(value, "maxSegments"))
    if max_segments == nil then
        return nil, err
    end
    local segments
    segments, err = validation.normalizeSegments(
        rawget(value, "segments"),
        max_segments
    )
    if segments == nil then
        return nil, err
    end
    return {
        spaceKey = space_key,
        lifecycle = lifecycle,
        audience = audience,
        priority = priority,
        maxSegments = max_segments,
        segments = segments,
    }
end

function validation.normalizeFinishOptions(value)
    if value == nil then
        value = {}
    end
    if not hasOnlyKeys(value, FINISH_OPTIONS_KEYS) then
        return nil, "invalid_spec"
    end
    local hold_duration = rawget(value, "holdDuration")
    if hold_duration == nil then
        hold_duration = constants.DEFAULT_FINISH_HOLD_DURATION
    end
    local fade_duration = rawget(value, "fadeDuration")
    if fade_duration == nil then
        fade_duration = constants.DEFAULT_FINISH_FADE_DURATION
    end
    if not isFinite(hold_duration)
        or hold_duration < 0
        or not isFinite(fade_duration)
        or fade_duration < 0
    then
        return nil, "invalid_lifecycle"
    end
    return {
        holdDuration = hold_duration,
        fadeDuration = fade_duration,
    }
end

-- nil is valid here: it asks the broker to renew by the persistent beam's
-- configured lease length. A positive value overrides only this renewal.
function validation.normalizeLeaseSeconds(value)
    if value == nil then
        return nil
    end
    if not isFinite(value) or value <= 0 then
        return nil, "invalid_lifecycle"
    end
    return value
end

validation.producerSpec = validation.normalizeProducerSpec
validation.beamSpec = validation.normalizeBeamSpec
validation.segment = validation.normalizeSegment
validation.segments = validation.normalizeSegments
validation.segmentOptions = validation.normalizeSegmentOptions
validation.finishOptions = validation.normalizeFinishOptions
validation.leaseSeconds = validation.normalizeLeaseSeconds
validation.vector = normalizeVector
validation.color = normalizeColor

return validation
