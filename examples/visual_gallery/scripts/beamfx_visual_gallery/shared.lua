---@omw-context menu | global | player

local shared = {}

shared.API_MAJOR = 1
shared.API_MINOR = 3
shared.PRODUCER_ID = "beamfx.example.visual_gallery"
shared.BEAM_ID = "gallery_preview"

shared.EVENT_COMMAND = "BeamFX_VisualGallery_Command_v1"
shared.EVENT_STATUS = "BeamFX_VisualGallery_Status_v1"

shared.TRIGGER_TOGGLE = "BeamFXVisualGallery_Toggle"
shared.TRIGGER_REPOSITION = "BeamFXVisualGallery_Reposition"
shared.BINDING_TOGGLE = "BeamFXVisualGallery_ToggleBinding_v1"
shared.BINDING_REPOSITION = "BeamFXVisualGallery_RepositionBinding_v1"
shared.SETTINGS_PAGE = "BeamFXVisualGallery"
shared.SETTINGS_GROUP = "SettingsBeamFXVisualGalleryControls"
shared.OMW_BINDINGS_SECTION = "OMWInputBindings"

shared.PRESET_NAMES = {
    "frost",
    "fire",
    "lightning",
    "laser",
    "fishing_line",
    "energy_blade",
}

shared.STYLE_NAMES = {
    "smooth",
    "electric",
    "plasma",
    "trail",
    "filament",
}

shared.STYLE_SCALES = {
    smooth = 0,
    electric = 12,
    plasma = 10,
    trail = 0,
    filament = 0,
}

shared.TAPER_NAMES = {
    "uniform",
    "pointed_end",
    "pointed_start",
    "narrow_end",
}

shared.LONGITUDINAL_NAMES = {
    "solid",
    "travel",
    "pulse",
    "dash",
}

shared.CATEGORY_DEFS = {
    { key = "preset", label = "Preset" },
    { key = "style", label = "Style" },
    { key = "radius", label = "Radius" },
    { key = "intensity", label = "Intensity" },
    { key = "startFadeLength", label = "Start fade" },
    { key = "endFadeLength", label = "End fade" },
    { key = "taper", label = "Taper" },
    { key = "longitudinalMode", label = "Longitudinal" },
    { key = "minPixelWidth", label = "Filament pixel width" },
}

-- Kept in this independent example so the expanded recipe can explain the
-- documented, canonical appearance produced by each friendly preset. The
-- renderer itself is always driven through the public I.BeamFX interface.
-- These values mirror scripts/beamfx/shared/presets.lua for this release.
shared.PRESETS = {
    frost = {
        style = "smooth",
        radius = 6,
        outerColor = { 0.20, 0.65, 1.00 },
        coreColor = { 0.82, 0.96, 1.15 },
        baseColor = { 0.04, 0.13, 0.22 },
        coreRatio = 0.30,
        intensity = 1.25,
        opacity = 0.92,
        baseOpacity = 0.12,
        depthSoftness = 3,
        fogInfluence = 0.70,
    },
    fire = {
        style = "plasma",
        radius = 8,
        outerColor = { 1.00, 0.18, 0.025 },
        coreColor = { 1.35, 0.82, 0.28 },
        baseColor = { 0.28, 0.035, 0.005 },
        coreRatio = 0.22,
        intensity = 1.65,
        opacity = 0.95,
        baseOpacity = 0.12,
        depthSoftness = 3,
        fogInfluence = 0.25,
        styleScale = 10,
    },
    lightning = {
        style = "electric",
        radius = 5,
        outerColor = { 0.26, 0.52, 1.00 },
        coreColor = { 1.05, 1.22, 1.45 },
        baseColor = { 0.04, 0.09, 0.22 },
        coreRatio = 0.18,
        intensity = 1.75,
        opacity = 1.00,
        baseOpacity = 0.06,
        depthSoftness = 2,
        fogInfluence = 0.30,
        styleScale = 12,
    },
    laser = {
        style = "smooth",
        radius = 3,
        outerColor = { 1.00, 0.08, 0.04 },
        coreColor = { 1.40, 0.85, 0.70 },
        baseColor = { 0.24, 0.015, 0.008 },
        coreRatio = 0.22,
        intensity = 1.80,
        opacity = 1.00,
        baseOpacity = 0.08,
        depthSoftness = 1,
        fogInfluence = 0.20,
    },
    fishing_line = {
        style = "filament",
        radius = 0.10,
        minPixelWidth = 0.75,
        outerColor = { 0.36, 0.43, 0.50 },
        coreColor = { 0.78, 0.84, 0.90 },
        baseColor = { 0.11, 0.13, 0.15 },
        coreRatio = 0.35,
        intensity = 0.45,
        opacity = 0.80,
        baseOpacity = 0.35,
        depthSoftness = 1,
        fogInfluence = 1.00,
    },
    energy_blade = {
        style = "smooth",
        radius = 6,
        outerColor = { 0.05, 0.45, 1.00 },
        coreColor = { 1.15, 1.35, 1.60 },
        baseColor = { 0.02, 0.10, 0.22 },
        coreRatio = 0.50,
        intensity = 2.20,
        opacity = 1.00,
        baseOpacity = 0.10,
        depthSoftness = 2,
        fogInfluence = 0.25,
    },
}

local DEFAULT_CONFIG = {
    preset = "frost",
    style = "smooth",
    styleOverride = false,
    radius = 6,
    intensity = 1.25,
    startFadeLength = 0,
    endFadeLength = 8,
    taper = "uniform",
    longitudinalMode = "solid",
    minPixelWidth = 0,
}

local function copyTable(source)
    local result = {}
    for key, value in pairs(source or {}) do
        if type(value) == "table" then
            result[key] = copyTable(value)
        else
            result[key] = value
        end
    end
    return result
end

function shared.defaultConfig()
    return copyTable(DEFAULT_CONFIG)
end

function shared.copyConfig(config)
    local result = shared.defaultConfig()
    for key, value in pairs(config or {}) do
        if result[key] ~= nil then
            result[key] = value
        end
    end
    return result
end

local function finite(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function clamp(value, minimum, maximum, fallback)
    if not finite(value) then
        return fallback
    end
    if value < minimum then
        return minimum
    end
    if value > maximum then
        return maximum
    end
    return value
end

local function inList(value, values, fallback)
    for _, candidate in ipairs(values) do
        if value == candidate then
            return value
        end
    end
    return fallback
end

function shared.normalizeConfig(raw)
    local defaults = shared.defaultConfig()
    local source = type(raw) == "table" and raw or {}
    local preset = inList(source.preset, shared.PRESET_NAMES, defaults.preset)
    local preset_style = shared.PRESETS[preset]
        and shared.PRESETS[preset].style
        or defaults.style
    local style_override = source.styleOverride == true
    local style = inList(source.style, shared.STYLE_NAMES, preset_style)
    if not style_override then
        style = preset_style
    end

    local result = {
        preset = preset,
        style = style,
        styleOverride = style_override,
        radius = clamp(source.radius, 0.1, 64, defaults.radius),
        intensity = clamp(source.intensity, 0, 8, defaults.intensity),
        startFadeLength = clamp(
            source.startFadeLength,
            0,
            128,
            defaults.startFadeLength
        ),
        endFadeLength = clamp(
            source.endFadeLength,
            0,
            128,
            defaults.endFadeLength
        ),
        taper = inList(source.taper, shared.TAPER_NAMES, defaults.taper),
        longitudinalMode = inList(
            source.longitudinalMode,
            shared.LONGITUDINAL_NAMES,
            defaults.longitudinalMode
        ),
        minPixelWidth = clamp(
            source.minPixelWidth,
            0,
            8,
            defaults.minPixelWidth
        ),
    }

    if result.style ~= "filament" then
        result.minPixelWidth = 0
        result.radius = math.max(0.25, result.radius)
    end
    return result
end

local function fmt(value)
    local number = tonumber(value) or 0
    if math.abs(number - math.floor(number + 0.5)) < 0.00001 then
        return string.format("%.1f", number)
    end
    return string.format("%.2f", number)
end

local function colorLiteral(value)
    local color = type(value) == "table" and value or { 0, 0, 0 }
    return string.format(
        "{ %.3f, %.3f, %.3f }",
        tonumber(color[1]) or 0,
        tonumber(color[2]) or 0,
        tonumber(color[3]) or 0
    )
end

local function append(lines, value)
    lines[#lines + 1] = value
end

local function taperFields(config)
    local minimum_radius = config.style == "filament" and 0.1 or 0.25
    if config.taper == "pointed_end" then
        return config.radius, 0
    end
    if config.taper == "pointed_start" then
        return 0, config.radius
    end
    if config.taper == "narrow_end" then
        return config.radius, math.max(
            minimum_radius,
            config.radius * 0.25
        )
    end
    return nil, nil
end

local function longitudinalLines(lines, config, indent, expanded)
    local mode = config.longitudinalMode
    append(lines, indent .. "longitudinal = {")
    append(lines, indent .. '    mode = "' .. mode .. '",')
    if expanded then
        append(lines, indent .. "    pathOffset = 0, -- cumulative per segment")
    end
    if mode == "travel" then
        append(lines, indent .. "    visibleLength = 55,")
        append(lines, indent .. "    speed = 90,")
        append(lines, indent .. "    headFadeLength = 8,")
        append(lines, indent .. "    tailFadeLength = 14,")
        append(lines, indent .. "    loop = true,")
        append(lines, indent .. "    -- loopLength is filled from total path length")
        append(lines, indent .. "    loopDelay = 0.15,")
    elseif mode == "pulse" then
        append(lines, indent .. "    period = 48,")
        append(lines, indent .. "    pulseLength = 18,")
        append(lines, indent .. "    speed = 70,")
        append(lines, indent .. "    carrierLevel = 0.20,")
        append(lines, indent .. "    fadeLength = 3,")
    elseif mode == "dash" then
        append(lines, indent .. "    dashLength = 24,")
        append(lines, indent .. "    gapLength = 12,")
        append(lines, indent .. "    speed = 45,")
        append(lines, indent .. "    fadeLength = 2,")
    end
    append(lines, indent .. "},")
end

function shared.conciseRecipe(raw)
    local config = shared.normalizeConfig(raw)
    local lines = {
        'producer:upsertPath("gallery_preview", {',
        "    cell = player.cell,",
        "    points = { startPos, bendPos1, bendPos2, endPos },",
        '    preset = "' .. config.preset .. '",',
        "    radius = " .. fmt(config.radius) .. ",",
        "    intensity = " .. fmt(config.intensity) .. ",",
    }
    if config.styleOverride then
        append(lines, '    style = "' .. config.style .. '",')
        append(
            lines,
            "    styleScale = "
                .. fmt(shared.STYLE_SCALES[config.style] or 0)
                .. ","
        )
    end
    if config.minPixelWidth > 0 then
        append(lines, "    minPixelWidth = " .. fmt(config.minPixelWidth) .. ",")
    end
    if config.startFadeLength > 0 then
        append(lines, "    startFadeLength = " .. fmt(config.startFadeLength) .. ",")
    end
    if config.endFadeLength > 0 then
        append(lines, "    endFadeLength = " .. fmt(config.endFadeLength) .. ",")
    end
    local start_radius, end_radius = taperFields(config)
    if start_radius ~= nil then
        append(lines, "    startRadius = " .. fmt(start_radius) .. ",")
        append(lines, "    endRadius = " .. fmt(end_radius) .. ",")
    end
    longitudinalLines(lines, config, "    ", false)
    append(lines, "})")
    return table.concat(lines, "\n")
end

local function mergePreset(config)
    local resolved = copyTable(shared.PRESETS[config.preset] or {})
    resolved.style = config.style
    if config.styleOverride then
        resolved.styleScale = shared.STYLE_SCALES[config.style] or 0
    end
    resolved.radius = config.radius
    resolved.intensity = config.intensity
    resolved.minPixelWidth = config.minPixelWidth
    resolved.startFadeLength = config.startFadeLength
    resolved.endFadeLength = config.endFadeLength
    local start_radius, end_radius = taperFields(config)
    resolved.startRadius = start_radius or config.radius
    resolved.endRadius = end_radius or config.radius
    return resolved
end

function shared.expandedRecipe(raw)
    local config = shared.normalizeConfig(raw)
    local resolved = mergePreset(config)
    local lines = {
        "-- Canonical appearance after preset expansion",
        "{",
        "    startRadius = " .. fmt(resolved.startRadius) .. ",",
        "    endRadius = " .. fmt(resolved.endRadius) .. ",",
        "    minPixelWidth = " .. fmt(resolved.minPixelWidth) .. ",",
        "    outerColor = " .. colorLiteral(resolved.outerColor) .. ",",
        "    coreColor = " .. colorLiteral(resolved.coreColor) .. ",",
        "    coreRatio = " .. fmt(resolved.coreRatio or 0.24) .. ",",
        "    intensity = " .. fmt(resolved.intensity) .. ",",
        "    opacity = " .. fmt(resolved.opacity == nil and 1 or resolved.opacity) .. ",",
        "    baseColor = " .. colorLiteral(resolved.baseColor or resolved.outerColor) .. ",",
        "    baseOpacity = " .. fmt(resolved.baseOpacity or 0) .. ",",
        "    startFadeLength = " .. fmt(resolved.startFadeLength) .. ",",
        "    endFadeLength = " .. fmt(resolved.endFadeLength) .. ",",
        "    depthSoftness = " .. fmt(resolved.depthSoftness or 0) .. ",",
        "    fogInfluence = " .. fmt(resolved.fogInfluence or 0) .. ",",
        '    style = "' .. tostring(resolved.style) .. '",',
        "    styleScale = " .. fmt(resolved.styleScale or 0) .. ",",
    }
    longitudinalLines(lines, config, "    ", true)
    append(lines, "}")
    return table.concat(lines, "\n")
end

function shared.categoryIndex(key)
    for index, definition in ipairs(shared.CATEGORY_DEFS) do
        if definition.key == key then
            return index
        end
    end
    return 1
end

function shared.listIndex(values, value)
    for index, candidate in ipairs(values) do
        if candidate == value then
            return index
        end
    end
    return 1
end

function shared.cycle(values, current, delta)
    local index = shared.listIndex(values, current)
    index = ((index - 1 + delta) % #values) + 1
    return values[index]
end

function shared.displayValue(config, category_key)
    if category_key == "radius"
        or category_key == "intensity"
        or category_key == "startFadeLength"
        or category_key == "endFadeLength"
        or category_key == "minPixelWidth"
    then
        return fmt(config[category_key])
    end
    if category_key == "style" and not config.styleOverride then
        return tostring(config.style) .. " (preset)"
    end
    return tostring(config[category_key])
end

return shared
