---@omw-context global | player | none

local constants = require("scripts.beamfx.shared.constants")
local styles = require("scripts.beamfx.shared.styles")

local metadata = {
    MAX_PACKED_VALUE = 16777215,
    MIN_PACKED_VALUE = -16777216,
    PALETTE_MULTIPLIER = 1,
    STYLE_MULTIPLIER = 16,
    OPACITY_MULTIPLIER = 64,
    INTENSITY_MULTIPLIER = 16384,
    SEED_MULTIPLIER = 1048576,
    EXTENDED_STYLE_OFFSET = 4,
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
    local extended_style = style_id >= metadata.EXTENDED_STYLE_OFFSET
    local packed_style_id = style_id % metadata.EXTENDED_STYLE_OFFSET
    local opacity_byte = math.floor(clamp(opacity, 0, 1) * 255 + 0.5)
    local intensity_byte = math.floor(clamp(intensity, 0, 8) * (63 / 8) + 0.5)
    local seed_nibble = math.floor(tonumber(seed) or 0) % 16

    local packed = palette * metadata.PALETTE_MULTIPLIER
        + packed_style_id * metadata.STYLE_MULTIPLIER
        + opacity_byte * metadata.OPACITY_MULTIPLIER
        + intensity_byte * metadata.INTENSITY_MULTIPLIER
        + seed_nibble * metadata.SEED_MULTIPLIER
    if extended_style then
        -- Positive values retain the exact Shader ABI 1 layout. The negative
        -- half of the exactly representable 24-bit integer range extends the
        -- style field from IDs 0..3 to IDs 4..7 without changing any legacy
        -- packed value or reducing opacity precision.
        return -(packed + 1)
    end
    return packed
end

function metadata.decode(value)
    local signed = tonumber(value) or 0
    local extended_style = signed < 0
    local magnitude = extended_style and (-signed - 1) or signed
    local packed = math.floor(math.max(0, magnitude) + 0.5)
    local style_id = math.floor(packed / metadata.STYLE_MULTIPLIER) % 4
    if extended_style then
        style_id = style_id + metadata.EXTENDED_STYLE_OFFSET
    end
    return {
        paletteIndex = packed % 16,
        styleId = style_id,
        opacity = (math.floor(packed / metadata.OPACITY_MULTIPLIER) % 256) / 255,
        intensity = (math.floor(packed / metadata.INTENSITY_MULTIPLIER) % 64) * (8 / 63),
        seed = math.floor(packed / metadata.SEED_MULTIPLIER) % 16,
    }
end

metadata.encodeMetadata = metadata.encode
metadata.decodeMetadata = metadata.decode

return metadata
