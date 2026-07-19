---@omw-context global | player | none

local constants = require("scripts.beamfx.shared.constants")

local styles = {
    SEGMENT_CAPACITY = constants.SEGMENT_CAPACITY,
    PALETTE_CAPACITY = constants.PALETTE_CAPACITY,
}

local STYLE_IDS = {
    smooth = 0,
    electric = 1,
    plasma = 2,
    trail = 3,
}

local STYLE_NAMES = {
    [0] = "smooth",
    [1] = "electric",
    [2] = "plasma",
    [3] = "trail",
}

local STYLE_ALIASES = {
    beam = "smooth",
    straight = "smooth",
    lightning = "electric",
    jagged = "electric",
    noisy = "plasma",
    fading = "trail",
}

local function normalizedKey(value)
    if type(value) ~= "string" then
        return nil
    end
    return value:lower():gsub("[%s%-]+", "_")
end

local function canonical(value)
    local key = normalizedKey(value)
    key = key and (STYLE_ALIASES[key] or key) or nil
    if key ~= nil and STYLE_IDS[key] ~= nil then
        return key
    end
    return nil
end

function styles.canonical(value)
    return canonical(value)
end

function styles.isValid(value)
    return canonical(value) ~= nil
end

function styles.normalize(value, fallback)
    return canonical(value)
        or canonical(fallback)
        or constants.DEFAULT_STYLE
end

-- Retain the three-argument compatibility shape while deliberately removing every
-- consumer-specific visual-kind alias. A visual kind that is itself a public
-- generic style or alias is harmlessly accepted; all other kinds fall back.
function styles.resolve(style, visual_kind, fallback)
    return canonical(style)
        or canonical(visual_kind)
        or canonical(fallback)
        or constants.DEFAULT_STYLE
end

function styles.id(style)
    return STYLE_IDS[styles.normalize(style)] or 0
end

function styles.name(style_id)
    return STYLE_NAMES[math.floor(tonumber(style_id) or 0)] or constants.DEFAULT_STYLE
end

function styles.names()
    return { "smooth", "electric", "plasma", "trail" }
end

function styles.aliases()
    local copy = {}
    for alias, target in pairs(STYLE_ALIASES) do
        copy[alias] = target
    end
    return copy
end

-- The renderer calls these functions through styles.lua. Keep those
-- entry points as lazy compatibility shims while metadata ownership moves to
-- the neutral metadata module.
function styles.encodeMetadata(style, palette_index, opacity, intensity, seed)
    return require("scripts.beamfx.shared.metadata").encode(
        style,
        palette_index,
        opacity,
        intensity,
        seed
    )
end

function styles.decodeMetadata(value)
    return require("scripts.beamfx.shared.metadata").decode(value)
end

return styles
