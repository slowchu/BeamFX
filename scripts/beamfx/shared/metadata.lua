---@omw-context global | player | none

local constants = require("scripts.beamfx.shared.constants")
local styles = require("scripts.beamfx.shared.styles")

local metadata = {
    MAX_PACKED_VALUE = 16777215,
    PALETTE_MULTIPLIER = 1,
    STYLE_MULTIPLIER = 16,
    OPACITY_MULTIPLIER = 64,
    INTENSITY_MULTIPLIER = 16384,
    SEED_MULTIPLIER = 1048576,
}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, tonumber(value) or minimum))
end

function metadata.encode(style, palette_index, opacity, intensity, seed)
    local palette = math.floor(clamp(
        palette_index,
        0,
        constants.PALETTE_CAPACITY - 1
    ))
    local style_id = styles.id(style)
    local opacity_byte = math.floor(clamp(opacity, 0, 1) * 255 + 0.5)
    local intensity_byte = math.floor(clamp(intensity, 0, 8) * (63 / 8) + 0.5)
    local seed_nibble = math.floor(tonumber(seed) or 0) % 16

    return palette * metadata.PALETTE_MULTIPLIER
        + style_id * metadata.STYLE_MULTIPLIER
        + opacity_byte * metadata.OPACITY_MULTIPLIER
        + intensity_byte * metadata.INTENSITY_MULTIPLIER
        + seed_nibble * metadata.SEED_MULTIPLIER
end

function metadata.decode(value)
    local packed = math.floor(math.max(0, tonumber(value) or 0) + 0.5)
    return {
        paletteIndex = packed % 16,
        styleId = math.floor(packed / metadata.STYLE_MULTIPLIER) % 4,
        opacity = (math.floor(packed / metadata.OPACITY_MULTIPLIER) % 256) / 255,
        intensity = (math.floor(packed / metadata.INTENSITY_MULTIPLIER) % 64) * (8 / 63),
        seed = math.floor(packed / metadata.SEED_MULTIPLIER) % 16,
    }
end

metadata.encodeMetadata = metadata.encode
metadata.decodeMetadata = metadata.decode

return metadata
