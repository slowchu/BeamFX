---@omw-context global | player | none

local presets = {}

local ORDERED_NAMES = {
    "frost",
    "fire",
    "lightning",
    "laser",
    "fishing_line",
    "energy_blade",
}

-- Presets are authoring conveniences. Every value expands to existing public
-- segment fields before broker storage, so adding a preset never creates a
-- shader style or changes the wire protocol.
local VALUES = {
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

local function copyValue(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, child in pairs(value) do
        result[key] = copyValue(child)
    end
    return result
end

function presets.canonical(value)
    if type(value) ~= "string" then
        return nil
    end
    local name = value:lower():gsub("[%s%-]+", "_")
    if VALUES[name] == nil then
        return nil
    end
    return name
end

function presets.get(value)
    local name = presets.canonical(value)
    if name == nil then
        return nil
    end
    return copyValue(VALUES[name]), name
end

function presets.names()
    local result = {}
    for index, name in ipairs(ORDERED_NAMES) do
        result[index] = name
    end
    return result
end

return presets
