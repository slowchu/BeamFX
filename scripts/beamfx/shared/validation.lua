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
    duration = true,
    fadeDuration = true,
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

local function firstUnknownKey(value, allowed)
    if type(value) ~= "table" then
        return nil
    end
    for key in next, value do
        if type(key) ~= "string" or not allowed[key] then
            return key
        end
    end
    return nil
end

local function errorDetail(path, reason, message)
    return {
        path = path or "",
        reason = reason,
        message = message,
    }
end

local function invalid(code, path, reason, message)
    return nil, code, errorDetail(path, reason, message)
end

local function prefixDetail(detail, prefix)
    if type(detail) ~= "table" then
        return detail
    end
    local path = detail.path or ""
    if path == "" then
        path = prefix
    elseif path:sub(1, 1) == "[" then
        path = prefix .. path
    else
        path = prefix .. "." .. path
    end
    return {
        path = path,
        reason = detail.reason,
        message = detail.message,
    }
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

local function normalizeBaseColor(value, fallback)
    local result, err = normalizeColor(value, fallback)
    if result == nil then
        return nil, err
    end
    return {
        clamp(result[1], 0, 1),
        clamp(result[2], 0, 1),
        clamp(result[3], 0, 1),
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

local function normalizeNonzeroSpeed(value)
    if not isFinite(value) or value == 0 then
        return nil, "invalid_spec"
    end
    local magnitude = clamp(
        math.abs(value),
        constants.MIN_LONGITUDINAL_LENGTH,
        constants.MAX_LONGITUDINAL_SPEED
    )
    if value < 0 then
        magnitude = -magnitude
    end
    return magnitude
end

local function vectorDistance(left, right)
    local x = right.x - left.x
    local y = right.y - left.y
    local z = right.z - left.z
    return math.sqrt(x * x + y * y + z * z)
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

function validation.normalizeLongitudinal(value, segment_length)
    if value == nil or value == false then
        return {
            mode = constants.DEFAULT_LONGITUDINAL_MODE,
            pathOffset = constants.DEFAULT_LONGITUDINAL_PATH_OFFSET,
        }
    end
    if type(value) ~= "table" then
        return nil, "invalid_spec"
    end

    local mode = rawget(value, "mode")
    if mode == nil then
        mode = constants.DEFAULT_LONGITUDINAL_MODE
    elseif type(mode) == "string" then
        mode = mode:lower()
    end
    local allowed_keys = LONGITUDINAL_MODE_KEYS[mode]
    if allowed_keys == nil or not hasOnlyKeys(value, allowed_keys) then
        return nil, "invalid_spec"
    end

    local path_offset, err = normalizeFinite(
        rawget(value, "pathOffset"),
        constants.DEFAULT_LONGITUDINAL_PATH_OFFSET,
        -constants.MAX_LONGITUDINAL_DISTANCE,
        constants.MAX_LONGITUDINAL_DISTANCE
    )
    if path_offset == nil then
        return nil, err
    end

    if mode == "solid" then
        return {
            mode = mode,
            pathOffset = path_offset,
        }
    end

    if not isFinite(segment_length) or segment_length <= 0 then
        return nil, "invalid_spec"
    end

    if mode == "travel" then
        local visible_length
        visible_length, err = normalizeFinite(
            rawget(value, "visibleLength"),
            nil,
            constants.MIN_LONGITUDINAL_LENGTH,
            constants.MAX_LONGITUDINAL_DISTANCE
        )
        if visible_length == nil then
            return nil, err
        end
        local speed
        speed, err = normalizeNonzeroSpeed(rawget(value, "speed"))
        if speed == nil then
            return nil, err
        end
        local head_fade_length
        head_fade_length, err = normalizeFinite(
            rawget(value, "headFadeLength"),
            0,
            0,
            visible_length
        )
        if head_fade_length == nil then
            return nil, err
        end
        local tail_fade_length
        tail_fade_length, err = normalizeFinite(
            rawget(value, "tailFadeLength"),
            0,
            0,
            visible_length
        )
        if tail_fade_length == nil then
            return nil, err
        end

        local loop = rawget(value, "loop")
        if loop == nil then
            loop = false
        elseif type(loop) ~= "boolean" then
            return nil, "invalid_spec"
        end
        local supplied_loop_length = rawget(value, "loopLength")
        local supplied_loop_delay = rawget(value, "loopDelay")
        if not loop
            and (supplied_loop_length ~= nil or supplied_loop_delay ~= nil)
        then
            return nil, "invalid_spec"
        end

        local loop_length = 0
        local loop_delay = 0
        if loop then
            loop_length, err = normalizeFinite(
                supplied_loop_length,
                segment_length,
                constants.MIN_LONGITUDINAL_LENGTH,
                constants.MAX_LONGITUDINAL_DISTANCE
            )
            if loop_length == nil then
                return nil, err
            end
            loop_delay, err = normalizeFinite(
                supplied_loop_delay,
                0,
                0,
                constants.MAX_LONGITUDINAL_LOOP_DELAY
            )
            if loop_delay == nil then
                return nil, err
            end
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
        local period
        period, err = normalizeFinite(
            rawget(value, "period"),
            nil,
            constants.MIN_LONGITUDINAL_LENGTH,
            constants.MAX_LONGITUDINAL_DISTANCE
        )
        if period == nil then
            return nil, err
        end
        local pulse_length
        pulse_length, err = normalizeFinite(
            rawget(value, "pulseLength"),
            nil,
            constants.MIN_LONGITUDINAL_LENGTH,
            period
        )
        if pulse_length == nil then
            return nil, err
        end
        local speed
        speed, err = normalizeFinite(
            rawget(value, "speed"),
            constants.DEFAULT_LONGITUDINAL_SPEED,
            -constants.MAX_LONGITUDINAL_SPEED,
            constants.MAX_LONGITUDINAL_SPEED
        )
        if speed == nil then
            return nil, err
        end
        local carrier_level
        carrier_level, err = normalizeFinite(
            rawget(value, "carrierLevel"),
            constants.DEFAULT_PULSE_CARRIER_LEVEL,
            0,
            1
        )
        if carrier_level == nil then
            return nil, err
        end
        local fade_length
        fade_length, err = normalizeFinite(
            rawget(value, "fadeLength"),
            0,
            0,
            pulse_length * 0.5
        )
        if fade_length == nil then
            return nil, err
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

    local dash_length
    dash_length, err = normalizeFinite(
        rawget(value, "dashLength"),
        nil,
        constants.MIN_LONGITUDINAL_LENGTH,
        constants.MAX_LONGITUDINAL_DISTANCE
    )
    if dash_length == nil then
        return nil, err
    end
    local gap_length
    gap_length, err = normalizeFinite(
        rawget(value, "gapLength"),
        nil,
        0,
        constants.MAX_LONGITUDINAL_DISTANCE
    )
    if gap_length == nil then
        return nil, err
    end
    local speed
    speed, err = normalizeFinite(
        rawget(value, "speed"),
        constants.DEFAULT_LONGITUDINAL_SPEED,
        -constants.MAX_LONGITUDINAL_SPEED,
        constants.MAX_LONGITUDINAL_SPEED
    )
    if speed == nil then
        return nil, err
    end
    local fade_length
    fade_length, err = normalizeFinite(
        rawget(value, "fadeLength"),
        0,
        0,
        dash_length * 0.5
    )
    if fade_length == nil then
        return nil, err
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

function validation.normalizeSegmentOptions(value)
    if value == nil then
        return {}
    end
    if not hasOnlyKeys(value, SEGMENT_OPTIONS_KEYS) then
        return invalid(
            "invalid_spec",
            "options",
            "invalid_segment_options",
            "Expected only duration and fadeDuration options."
        )
    end
    local duration = rawget(value, "duration")
    local fade_duration = rawget(value, "fadeDuration")
    if duration ~= nil and (not isFinite(duration) or duration <= 0) then
        return invalid(
            "invalid_spec",
            "options.duration",
            "invalid_duration",
            "duration must be a positive finite number."
        )
    end
    if fade_duration ~= nil and (not isFinite(fade_duration) or fade_duration < 0) then
        return invalid(
            "invalid_spec",
            "options.fadeDuration",
            "invalid_duration",
            "fadeDuration must be a non-negative finite number."
        )
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
        if type(value) ~= "table" then
            return invalid(
                "invalid_spec",
                "",
                "expected_table",
                "Expected a segment table."
            )
        end
        local unknown = firstUnknownKey(value, SEGMENT_KEYS)
        return invalid(
            "invalid_spec",
            tostring(unknown or ""),
            "unknown_field",
            "This field is not supported by a BeamFX segment."
        )
    end
    local err
    local detail
    operation_options, err, detail =
        validation.normalizeSegmentOptions(operation_options)
    if operation_options == nil then
        return nil, err, detail
    end

    local start_pos
    start_pos, err = normalizeVector(rawget(value, "startPos"))
    if start_pos == nil then
        return invalid(
            err,
            "startPos",
            "invalid_vector",
            "Expected a finite world-space 3D position."
        )
    end
    local end_pos
    end_pos, err = normalizeVector(rawget(value, "endPos"))
    if end_pos == nil then
        return invalid(
            err,
            "endPos",
            "invalid_vector",
            "Expected a finite world-space 3D position."
        )
    end

    local style_value = rawget(value, "style")
    local style = nil
    if style_value == nil then
        style = constants.DEFAULT_STYLE
    else
        style = styles.canonical(style_value)
        if style == nil then
            return invalid(
                "invalid_style",
                "style",
                "unknown_style",
                "Unknown BeamFX shader style."
            )
        end
    end

    local outer_color
    outer_color, err = normalizeColor(
        rawget(value, "outerColor"),
        constants.DEFAULT_OUTER_COLOR
    )
    if outer_color == nil then
        return invalid(
            err,
            "outerColor",
            "invalid_color",
            "Expected three finite color components."
        )
    end
    local core_color
    core_color, err = normalizeColor(
        rawget(value, "coreColor"),
        constants.DEFAULT_CORE_COLOR
    )
    if core_color == nil then
        return invalid(
            err,
            "coreColor",
            "invalid_color",
            "Expected three finite color components."
        )
    end

    local minimum_radius = constants.MIN_RADIUS
    if style == "filament" then
        minimum_radius = constants.MIN_FILAMENT_RADIUS
    end
    local radius
    radius, err = normalizeFinite(
        rawget(value, "radius"),
        constants.DEFAULT_RADIUS,
        minimum_radius,
        constants.MAX_RADIUS
    )
    if radius == nil then
        return invalid(
            err,
            "radius",
            "invalid_number",
            "radius must be a finite number."
        )
    end

    local function endpointRadius(name)
        local supplied = rawget(value, name)
        if supplied == nil then
            return radius
        end
        if not isFinite(supplied) then
            return nil, "invalid_spec"
        end
        if supplied == 0 then
            return 0
        end
        return clamp(supplied, minimum_radius, constants.MAX_RADIUS)
    end

    local start_radius
    start_radius, err = endpointRadius("startRadius")
    if start_radius == nil then
        return invalid(
            err,
            "startRadius",
            "invalid_number",
            "startRadius must be a finite number."
        )
    end
    local end_radius
    end_radius, err = endpointRadius("endRadius")
    if end_radius == nil then
        return invalid(
            err,
            "endRadius",
            "invalid_number",
            "endRadius must be a finite number."
        )
    end

    local minimum_pixel_width
    minimum_pixel_width, err = normalizeFinite(
        rawget(value, "minPixelWidth"),
        constants.DEFAULT_MIN_PIXEL_WIDTH,
        0,
        constants.MAX_MIN_PIXEL_WIDTH
    )
    if minimum_pixel_width == nil then
        return invalid(
            err,
            "minPixelWidth",
            "invalid_number",
            "minPixelWidth must be a finite number."
        )
    end
    if minimum_pixel_width > 0 and style ~= "filament" then
        return invalid(
            "invalid_spec",
            "minPixelWidth",
            "requires_filament",
            "minPixelWidth is only supported by the filament style."
        )
    end
    if start_radius == 0
        and end_radius == 0
        and minimum_pixel_width == 0
    then
        return invalid(
            "invalid_spec",
            "startRadius",
            "invisible_segment",
            "Both endpoint radii require a positive filament pixel width."
        )
    end

    local core_ratio
    core_ratio, err = normalizeFinite(
        rawget(value, "coreRatio"),
        constants.DEFAULT_CORE_RATIO,
        0.02,
        1
    )
    if core_ratio == nil then
        return invalid(
            err,
            "coreRatio",
            "invalid_number",
            "coreRatio must be a finite number."
        )
    end
    local intensity
    intensity, err = normalizeFinite(
        rawget(value, "intensity"),
        constants.DEFAULT_INTENSITY,
        0,
        8
    )
    if intensity == nil then
        return invalid(
            err,
            "intensity",
            "invalid_number",
            "intensity must be a finite number."
        )
    end
    local opacity
    opacity, err = normalizeFinite(
        rawget(value, "opacity"),
        constants.DEFAULT_OPACITY,
        0,
        1
    )
    if opacity == nil then
        return invalid(
            err,
            "opacity",
            "invalid_number",
            "opacity must be a finite number."
        )
    end

    local base_color
    base_color, err = normalizeBaseColor(
        rawget(value, "baseColor"),
        outer_color
    )
    if base_color == nil then
        return invalid(
            err,
            "baseColor",
            "invalid_color",
            "Expected three finite color components."
        )
    end
    local base_opacity
    base_opacity, err = normalizeFinite(
        rawget(value, "baseOpacity"),
        constants.DEFAULT_BASE_OPACITY,
        0,
        1
    )
    if base_opacity == nil then
        return invalid(
            err,
            "baseOpacity",
            "invalid_number",
            "baseOpacity must be a finite number."
        )
    end

    local start_fade_length
    start_fade_length, err = normalizeFinite(
        rawget(value, "startFadeLength"),
        constants.DEFAULT_SPATIAL_FADE_LENGTH,
        0,
        constants.MAX_LONGITUDINAL_DISTANCE
    )
    if start_fade_length == nil then
        return invalid(
            err,
            "startFadeLength",
            "invalid_number",
            "startFadeLength must be a finite number."
        )
    end
    local end_fade_length
    end_fade_length, err = normalizeFinite(
        rawget(value, "endFadeLength"),
        constants.DEFAULT_SPATIAL_FADE_LENGTH,
        0,
        constants.MAX_LONGITUDINAL_DISTANCE
    )
    if end_fade_length == nil then
        return invalid(
            err,
            "endFadeLength",
            "invalid_number",
            "endFadeLength must be a finite number."
        )
    end

    local depth_softness
    depth_softness, err = normalizeFinite(
        rawget(value, "depthSoftness"),
        constants.DEFAULT_DEPTH_SOFTNESS,
        0,
        constants.MAX_DEPTH_SOFTNESS
    )
    if depth_softness == nil then
        return invalid(
            err,
            "depthSoftness",
            "invalid_number",
            "depthSoftness must be a finite number."
        )
    end
    local fog_influence
    fog_influence, err = normalizeFinite(
        rawget(value, "fogInfluence"),
        constants.DEFAULT_FOG_INFLUENCE,
        0,
        1
    )
    if fog_influence == nil then
        return invalid(
            err,
            "fogInfluence",
            "invalid_number",
            "fogInfluence must be a finite number."
        )
    end

    local style_scale
    style_scale, err = normalizeFinite(
        rawget(value, "styleScale"),
        constants.DEFAULT_STYLE_SCALE,
        0,
        512
    )
    if style_scale == nil then
        return invalid(
            err,
            "styleScale",
            "invalid_number",
            "styleScale must be a finite number."
        )
    end

    local longitudinal
    longitudinal, err = validation.normalizeLongitudinal(
        rawget(value, "longitudinal"),
        vectorDistance(start_pos, end_pos)
    )
    if longitudinal == nil then
        return invalid(
            err,
            "longitudinal",
            "invalid_longitudinal",
            "The longitudinal settings are not valid for this segment."
        )
    end

    local origin_glow = rawget(value, "originGlow")
    if origin_glow == nil then
        origin_glow = false
    elseif type(origin_glow) ~= "boolean" then
        return invalid(
            "invalid_spec",
            "originGlow",
            "invalid_boolean",
            "originGlow must be true or false."
        )
    end
    local seed = rawget(value, "seed")
    if seed ~= nil
        and (not isFinite(seed)
            or seed ~= math.floor(seed)
            or seed < 0
            or seed > 15)
    then
        return invalid(
            "invalid_spec",
            "seed",
            "invalid_seed",
            "seed must be an integer from 0 through 15."
        )
    end
    if origin_glow then
        if style ~= "plasma" or (seed ~= nil and seed ~= 0) then
            return invalid(
                "invalid_spec",
                "originGlow",
                "invalid_origin_glow",
                "originGlow requires plasma with an omitted or zero seed."
            )
        end
        seed = 0
    elseif style == "plasma" and seed == 0 then
        return invalid(
            "invalid_spec",
            "seed",
            "reserved_plasma_seed",
            "Plasma seed 0 is reserved for originGlow."
        )
    end

    local duration = rawget(value, "duration")
    if duration == nil then
        duration = operation_options.duration
    end
    local fade_duration = rawget(value, "fadeDuration")
    if fade_duration == nil then
        fade_duration = operation_options.fadeDuration
    end
    local duration_error_path = "duration"
    if duration == nil and fade_duration ~= nil then
        duration_error_path = "fadeDuration"
    elseif duration ~= nil
        and isFinite(duration)
        and duration > 0
        and fade_duration ~= nil
        and (not isFinite(fade_duration) or fade_duration < 0)
    then
        duration_error_path = "fadeDuration"
    end
    duration, fade_duration, err = normalizeRelativeDuration(
        duration,
        fade_duration,
        constants.DEFAULT_FINISH_FADE_DURATION
    )
    if err ~= nil then
        return invalid(
            err,
            duration_error_path,
            "invalid_duration",
            "Segment duration and fadeDuration must be non-negative and finite."
        )
    end

    return {
        startPos = start_pos,
        endPos = end_pos,
        radius = radius,
        startRadius = start_radius,
        endRadius = end_radius,
        minPixelWidth = minimum_pixel_width,
        outerColor = outer_color,
        coreColor = core_color,
        coreRatio = core_ratio,
        intensity = intensity,
        opacity = opacity,
        baseColor = base_color,
        baseOpacity = base_opacity,
        startFadeLength = start_fade_length,
        endFadeLength = end_fade_length,
        depthSoftness = depth_softness,
        fogInfluence = fog_influence,
        style = style,
        styleScale = style_scale,
        seed = seed,
        originGlow = origin_glow,
        longitudinal = longitudinal,
        duration = duration,
        fadeDuration = fade_duration,
    }
end

function validation.normalizeSegments(value, max_segments, operation_options)
    max_segments = max_segments or constants.DEFAULT_MAX_SEGMENTS
    if not isFinite(max_segments) then
        return invalid(
            "invalid_spec",
            "maxSegments",
            "invalid_number",
            "maxSegments must be a finite number."
        )
    end
    max_segments = math.floor(clamp(max_segments, 1, constants.MAX_SEGMENTS_PER_BEAM))

    local options, err, detail =
        validation.normalizeSegmentOptions(operation_options)
    if options == nil then
        return nil, err, detail
    end
    local count
    count, err = arrayLength(value, constants.MAX_INPUT_SEGMENTS)
    if count == nil then
        return invalid(
            err,
            "segments",
            err == "segment_quota_exceeded"
                    and "segment_quota_exceeded"
                or "invalid_array",
            err == "segment_quota_exceeded"
                    and "Too many input segments."
                or "Expected a dense array of segment tables."
        )
    end
    if count == 0 then
        return invalid(
            "no_valid_segments",
            "segments",
            "no_valid_segments",
            "At least one segment is required."
        )
    end
    if count > max_segments then
        return invalid(
            "segment_quota_exceeded",
            "segments",
            "segment_quota_exceeded",
            "The segment batch exceeds maxSegments."
        )
    end

    local normalized = {}
    for index = 1, count do
        local segment
        segment, err, detail =
            validation.normalizeSegment(rawget(value, index), options)
        if segment == nil then
            return nil, err, prefixDetail(
                detail,
                "segments[" .. index .. "]"
            )
        end
        normalized[index] = segment
    end
    return normalized
end

function validation.normalizeBeamSpec(value)
    if not hasOnlyKeys(value, BEAM_KEYS) then
        if type(value) ~= "table" then
            return invalid(
                "invalid_spec",
                "",
                "expected_table",
                "Expected a beam specification table."
            )
        end
        local unknown = firstUnknownKey(value, BEAM_KEYS)
        return invalid(
            "invalid_spec",
            tostring(unknown or ""),
            "unknown_field",
            "This field is not supported by a BeamFX beam."
        )
    end
    local space_key, err = validation.normalizeSpaceKey(rawget(value, "spaceKey"))
    if space_key == nil then
        return invalid(
            err,
            "spaceKey",
            "invalid_space_key",
            "Expected a valid BeamFX interior or exterior space key."
        )
    end
    local lifecycle
    lifecycle, err = validation.normalizeLifecycle(rawget(value, "lifecycle"))
    if lifecycle == nil then
        return invalid(
            err,
            "lifecycle",
            "invalid_lifecycle",
            "Expected a valid transient or persistent lifecycle."
        )
    end
    local audience
    audience, err = validation.normalizeAudience(rawget(value, "audience"))
    if audience == nil then
        return invalid(
            err,
            "audience",
            "invalid_audience",
            "Only the same_space audience is supported."
        )
    end
    local priority
    priority, err = validation.normalizePriority(rawget(value, "priority"))
    if priority == nil then
        return invalid(
            err,
            "priority",
            "invalid_priority",
            "Expected low, normal, or high priority."
        )
    end
    local max_segments
    max_segments, err = validation.normalizeMaxSegments(rawget(value, "maxSegments"))
    if max_segments == nil then
        return invalid(
            err,
            "maxSegments",
            "invalid_number",
            "maxSegments must be a finite number."
        )
    end
    local segments
    local detail
    segments, err, detail = validation.normalizeSegments(
        rawget(value, "segments"),
        max_segments
    )
    if segments == nil then
        return nil, err, detail
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
