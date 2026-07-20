---@omw-context global

local constants = require("scripts.beamfx.shared.constants")
local presets = require("scripts.beamfx.shared.presets")
local space = require("scripts.beamfx.shared.space")
local validation = require("scripts.beamfx.shared.validation")

local authoring = {}

local CANONICAL_SEGMENT_KEYS = {
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

local SEGMENT_SUGAR_KEYS = {
    preset = true,
    color = true,
}

local SEGMENT_DEFAULT_KEYS = {}
for key in pairs(CANONICAL_SEGMENT_KEYS) do
    if key ~= "startPos" and key ~= "endPos" then
        SEGMENT_DEFAULT_KEYS[key] = true
    end
end
SEGMENT_DEFAULT_KEYS.preset = true
SEGMENT_DEFAULT_KEYS.color = true

local PATH_KEYS = {
    spaceKey = true,
    cell = true,
    from = true,
    to = true,
    points = true,
    lifecycle = true,
    duration = true,
    fadeDuration = true,
    audience = true,
    priority = true,
    maxSegments = true,
    segmentDefaults = true,
}
for key in pairs(SEGMENT_DEFAULT_KEYS) do
    if key ~= "duration" and key ~= "fadeDuration" then
        PATH_KEYS[key] = true
    end
end

local function errorDetail(path, reason, message)
    return {
        path = path,
        reason = reason,
        message = message,
    }
end

local function invalid(path, reason, message, code)
    return nil, code or "invalid_spec", errorDetail(path, reason, message)
end

local function childPath(prefix, child)
    if prefix == nil or prefix == "" then
        return child
    end
    if child:sub(1, 1) == "[" then
        return prefix .. child
    end
    return prefix .. "." .. child
end

local function copyTable(value)
    local result = {}
    for key, child in next, value do
        result[key] = child
    end
    return result
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

local function arrayLength(value, maximum)
    if type(value) ~= "table" then
        return nil
    end
    local count = 0
    local highest = 0
    for key in next, value do
        if type(key) ~= "number"
            or not validation.isFinite(key)
            or key < 1
            or key ~= math.floor(key)
        then
            return nil
        end
        count = count + 1
        highest = math.max(highest, key)
        if count > maximum or highest > maximum then
            return nil, "segment_quota_exceeded"
        end
    end
    if highest ~= count then
        return nil
    end
    return count
end

local function deriveColors(value, path)
    local color = validation.color(value)
    if color == nil then
        return invalid(
            path,
            "invalid_color",
            "Expected three finite color components."
        )
    end
    local core = {}
    local base = {}
    for index = 1, 3 do
        core[index] = math.min(4, 0.75 + color[index] * 0.45)
        base[index] = math.min(1, color[index] * 0.22)
    end
    return {
        outerColor = color,
        coreColor = core,
        baseColor = base,
    }
end

local function validateDefaults(value, path)
    if value == nil then
        return {}
    end
    if type(value) ~= "table" then
        return invalid(
            path,
            "expected_table",
            "Expected a table of segment defaults."
        )
    end
    local unknown = firstUnknownKey(value, SEGMENT_DEFAULT_KEYS)
    if unknown ~= nil then
        return invalid(
            childPath(path, tostring(unknown)),
            "unknown_field",
            "This field is not supported in segmentDefaults."
        )
    end
    return value
end

local function applyLayer(result, layer, path)
    if layer == nil then
        return result
    end
    local color = rawget(layer, "color")
    if color ~= nil then
        local derived, err, detail = deriveColors(
            color,
            childPath(path, "color")
        )
        if derived == nil then
            return nil, err, detail
        end
        result.outerColor = derived.outerColor
        result.coreColor = derived.coreColor
        result.baseColor = derived.baseColor
    end
    for key in pairs(CANONICAL_SEGMENT_KEYS) do
        local value = rawget(layer, key)
        if value ~= nil then
            result[key] = value
        end
    end
    return result
end

local function expandSegment(value, defaults, path)
    if type(value) ~= "table" then
        return invalid(
            path,
            "expected_table",
            "Expected a segment table."
        )
    end

    local selected_preset = rawget(value, "preset")
    local preset_path = childPath(path, "preset")
    if selected_preset == nil then
        selected_preset = rawget(defaults, "preset")
        preset_path = "segmentDefaults.preset"
    end

    local result = {}
    if selected_preset ~= nil then
        local preset_values = presets.get(selected_preset)
        if preset_values == nil then
            return invalid(
                preset_path,
                "unknown_preset",
                "Unknown BeamFX appearance preset."
            )
        end
        result = preset_values
    end

    local err
    local detail
    result, err, detail = applyLayer(
        result,
        defaults,
        "segmentDefaults"
    )
    if result == nil then
        return nil, err, detail
    end
    result, err, detail = applyLayer(result, value, path)
    if result == nil then
        return nil, err, detail
    end

    for key, child in next, value do
        if not CANONICAL_SEGMENT_KEYS[key]
            and not SEGMENT_SUGAR_KEYS[key]
        then
            -- Preserve unknown canonical input so the authoritative validator
            -- can reject it with the legacy error code.
            result[key] = child
        end
    end
    return result
end

local function expandSegments(value, defaults, path)
    local count, length_err = arrayLength(
        value,
        constants.MAX_INPUT_SEGMENTS
    )
    if count == nil then
        if length_err == "segment_quota_exceeded" then
            return invalid(
                path,
                "segment_quota_exceeded",
                "Too many input segments.",
                length_err
            )
        end
        return invalid(
            path,
            "invalid_array",
            "Expected a dense array of segment tables."
        )
    end
    local result = {}
    for index = 1, count do
        local segment
        local err
        local detail
        segment, err, detail = expandSegment(
            rawget(value, index),
            defaults,
            childPath(path, "[" .. index .. "]")
        )
        if segment == nil then
            return nil, err, detail
        end
        result[index] = segment
    end
    return result
end

function authoring.expandBeamSpec(value)
    if type(value) ~= "table" then
        return invalid(
            "",
            "expected_table",
            "Expected a beam specification table."
        )
    end
    local defaults
    local err
    local detail
    defaults, err, detail = validateDefaults(
        rawget(value, "segmentDefaults"),
        "segmentDefaults"
    )
    if defaults == nil then
        return nil, err, detail
    end

    local result = {}
    for key, child in next, value do
        if key ~= "segmentDefaults" and key ~= "segments" then
            result[key] = child
        end
    end
    local segments = rawget(value, "segments")
    if segments ~= nil then
        result.segments, err, detail = expandSegments(
            segments,
            defaults,
            "segments"
        )
        if result.segments == nil then
            return nil, err, detail
        end
    end
    return result
end

function authoring.expandSegmentList(value, path)
    return expandSegments(value, {}, path or "segments")
end

local function normalizedPoints(value, path)
    local count, length_err = arrayLength(
        value,
        constants.MAX_INPUT_SEGMENTS + 1
    )
    if count == nil then
        if length_err == "segment_quota_exceeded" then
            return invalid(
                path,
                "segment_quota_exceeded",
                "A path can contain at most 257 points.",
                length_err
            )
        end
        return invalid(
            path,
            "invalid_array",
            "Expected a dense array of path points."
        )
    end
    if count < 2 then
        return invalid(
            path,
            "too_few_points",
            "A path requires at least two points."
        )
    end

    local result = {}
    for index = 1, count do
        local point = validation.vector(rawget(value, index))
        if point == nil then
            return invalid(
                childPath(path, "[" .. index .. "]"),
                "invalid_vector",
                "Expected a finite world-space 3D position."
            )
        end
        result[index] = point
    end
    return result
end

local function distance(left, right)
    local x = right.x - left.x
    local y = right.y - left.y
    local z = right.z - left.z
    return math.sqrt(x * x + y * y + z * z)
end

local function resolveSpace(value)
    local supplied_key = rawget(value, "spaceKey")
    local supplied_cell = rawget(value, "cell")
    if supplied_key ~= nil and supplied_cell ~= nil then
        return invalid(
            "cell",
            "conflicting_space",
            "Provide cell or spaceKey, not both."
        )
    end
    if supplied_cell ~= nil then
        local key = space.spaceKeyForCell(supplied_cell)
        if key == nil then
            return invalid(
                "cell",
                "invalid_cell",
                "The Cell could not be converted to a BeamFX space key.",
                "invalid_space_key"
            )
        end
        return key
    end
    if supplied_key == nil then
        return invalid(
            "spaceKey",
            "missing_space",
            "Provide cell or spaceKey.",
            "invalid_space_key"
        )
    end
    return supplied_key
end

local function resolveGeometry(value)
    local supplied_points = rawget(value, "points")
    local supplied_from = rawget(value, "from")
    local supplied_to = rawget(value, "to")
    if supplied_points ~= nil
        and (supplied_from ~= nil or supplied_to ~= nil)
    then
        return invalid(
            "points",
            "conflicting_geometry",
            "Provide points or from/to, not both."
        )
    end
    if supplied_points ~= nil then
        return normalizedPoints(supplied_points, "points")
    end
    if supplied_from == nil and supplied_to == nil then
        return invalid(
            "points",
            "missing_geometry",
            "Provide points or both from and to."
        )
    end
    if supplied_from == nil or supplied_to == nil then
        return invalid(
            supplied_from == nil and "from" or "to",
            "missing_endpoint",
            "Both from and to are required."
        )
    end
    return normalizedPoints(
        { supplied_from, supplied_to },
        "points"
    )
end

local function resolveLifecycle(value, emit)
    local supplied = rawget(value, "lifecycle")
    local duration = rawget(value, "duration")
    local fade_duration = rawget(value, "fadeDuration")
    if supplied ~= nil
        and (duration ~= nil or fade_duration ~= nil)
    then
        return invalid(
            "lifecycle",
            "conflicting_lifecycle",
            "Use lifecycle or duration/fadeDuration, not both."
        )
    end
    if supplied ~= nil then
        if type(supplied) ~= "table" then
            return invalid(
                "lifecycle",
                "expected_table",
                "Expected a lifecycle table."
            )
        end
        local result = copyTable(supplied)
        if emit then
            if result.mode == nil then
                result.mode = "transient"
            elseif result.mode ~= "transient" then
                return invalid(
                    "lifecycle.mode",
                    "emit_requires_transient",
                    "emit only creates transient beams.",
                    "invalid_lifecycle"
                )
            end
            if result.duration == nil then
                result.duration = constants.DEFAULT_EMIT_DURATION
            end
            if result.fadeDuration == nil then
                result.fadeDuration =
                    constants.DEFAULT_EMIT_FADE_DURATION
            end
        end
        return result
    end

    if emit or duration ~= nil or fade_duration ~= nil then
        return {
            mode = "transient",
            duration = duration or constants.DEFAULT_EMIT_DURATION,
            fadeDuration = fade_duration
                or constants.DEFAULT_EMIT_FADE_DURATION,
        }
    end
    return { mode = "persistent" }
end

local function topLevelDefaults(value)
    local result = {}
    for key in pairs(SEGMENT_DEFAULT_KEYS) do
        if key ~= "duration" and key ~= "fadeDuration" then
            local child = rawget(value, key)
            if child ~= nil then
                result[key] = child
            end
        end
    end
    return result
end

local function expandPath(value, emit)
    if type(value) ~= "table" then
        return invalid(
            "",
            "expected_table",
            "Expected a path specification table."
        )
    end
    local unknown = firstUnknownKey(value, PATH_KEYS)
    if unknown ~= nil then
        return invalid(
            tostring(unknown),
            "unknown_field",
            "This field is not supported by this path helper."
        )
    end

    local space_key
    local err
    local detail
    space_key, err, detail = resolveSpace(value)
    if space_key == nil then
        return nil, err, detail
    end
    local points
    points, err, detail = resolveGeometry(value)
    if points == nil then
        return nil, err, detail
    end
    local lifecycle
    lifecycle, err, detail = resolveLifecycle(value, emit)
    if lifecycle == nil then
        return nil, err, detail
    end
    local normalized_lifecycle
    normalized_lifecycle, err =
        validation.normalizeLifecycle(lifecycle)
    if normalized_lifecycle == nil then
        local lifecycle_path = "lifecycle"
        if rawget(value, "lifecycle") == nil then
            local duration = lifecycle.duration
            local fade_duration = lifecycle.fadeDuration
            if not validation.isFinite(duration)
                or duration <= 0
            then
                lifecycle_path = "duration"
            elseif not validation.isFinite(fade_duration)
                or fade_duration < 0
            then
                lifecycle_path = "fadeDuration"
            end
        end
        return invalid(
            lifecycle_path,
            "invalid_lifecycle",
            "Expected a valid transient or persistent lifecycle.",
            err
        )
    end
    lifecycle = normalized_lifecycle

    local defaults = topLevelDefaults(value)
    local supplied_defaults
    supplied_defaults, err, detail = validateDefaults(
        rawget(value, "segmentDefaults"),
        "segmentDefaults"
    )
    if supplied_defaults == nil then
        return nil, err, detail
    end
    for key, child in next, supplied_defaults do
        defaults[key] = child
    end
    local selected_preset = rawget(defaults, "preset")
    if selected_preset ~= nil
        and presets.canonical(selected_preset) == nil
    then
        local preset_path = rawget(supplied_defaults, "preset") ~= nil
                and "segmentDefaults.preset"
            or "preset"
        return invalid(
            preset_path,
            "unknown_preset",
            "Unknown BeamFX appearance preset."
        )
    end
    local shorthand_color = rawget(defaults, "color")
    if shorthand_color ~= nil
        and validation.color(shorthand_color) == nil
    then
        local color_path = rawget(supplied_defaults, "color") ~= nil
                and "segmentDefaults.color"
            or "color"
        return invalid(
            color_path,
            "invalid_color",
            "Expected three finite color components."
        )
    end

    local lengths = {}
    local total_length = 0
    for index = 1, #points - 1 do
        lengths[index] = distance(points[index], points[index + 1])
        total_length = total_length + lengths[index]
    end

    local result = {
        spaceKey = space_key,
        lifecycle = lifecycle,
        audience = rawget(value, "audience"),
        priority = rawget(value, "priority"),
        maxSegments = rawget(value, "maxSegments")
            or math.max(constants.DEFAULT_MAX_SEGMENTS, #points - 1),
        segments = {},
    }

    local cumulative_offset = 0
    for index = 1, #points - 1 do
        local segment
        segment, err, detail = expandSegment({
            startPos = points[index],
            endPos = points[index + 1],
        }, defaults, "segments[" .. index .. "]")
        if segment == nil then
            return nil, err, detail
        end

        local longitudinal = segment.longitudinal
        if longitudinal == nil then
            longitudinal = { mode = "solid" }
        elseif type(longitudinal) ~= "table" then
            return invalid(
                "segmentDefaults.longitudinal",
                "expected_table",
                "Expected a longitudinal settings table."
            )
        else
            longitudinal = copyTable(longitudinal)
        end
        local base_offset = rawget(longitudinal, "pathOffset")
        if base_offset == nil then
            base_offset = 0
        elseif not validation.isFinite(base_offset) then
            return invalid(
                "segmentDefaults.longitudinal.pathOffset",
                "invalid_number",
                "pathOffset must be a finite number."
            )
        end
        longitudinal.pathOffset = base_offset + cumulative_offset
        if longitudinal.mode == "travel"
            and longitudinal.loop == true
            and longitudinal.loopLength == nil
        then
            longitudinal.loopLength = total_length
        end
        segment.longitudinal = longitudinal
        result.segments[index] = segment
        cumulative_offset = cumulative_offset + lengths[index]
    end
    return result
end

function authoring.expandEmitSpec(value)
    return expandPath(value, true)
end

function authoring.expandPathSpec(value)
    return expandPath(value, false)
end

function authoring.presetNames()
    return presets.names()
end

return authoring
