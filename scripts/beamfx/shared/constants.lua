---@omw-context global | player | none

local constants = {
    PACKAGE_VERSION = "0.1.0-alpha.4",
    API_MAJOR = 1,
    API_MINOR = 3,
    PROTOCOL_VERSION = 3,
    SHADER_ABI = 3,
    SHADER_RESOURCE = "beamfx_core_v3",
    PRODUCER_API_SHAPE = "facade",

    SEGMENT_CAPACITY = 64,
    PALETTE_CAPACITY = 16,

    MAX_PRODUCER_ID_LENGTH = 96,
    MAX_PRODUCER_DISPLAY_NAME_LENGTH = 128,
    MAX_BEAM_ID_LENGTH = 128,
    MAX_EPOCH_LENGTH = 192,
    MAX_RENDERER_SESSION_LENGTH = 192,
    MAX_SPACE_KEY_LENGTH = 256,
    MAX_REASON_LENGTH = 128,
    MAX_PACKET_VALUES = 16384,
    -- OpenMW ultimately uploads positions through float uniforms. This bound
    -- is far beyond normal TES3 world coordinates while keeping subtraction,
    -- distance ranking, and float conversion well-defined.
    MAX_ABS_COORDINATE = 1000000000000,

    MAX_REGISTERED_PRODUCERS = 128,
    MAX_BEAMS_PER_PRODUCER = 128,
    MAX_BEAMS_GLOBAL = 1024,
    MAX_RETAINED_SEGMENTS_PER_PRODUCER = 2048,
    MAX_RETAINED_SEGMENTS_GLOBAL = 16384,
    DEFAULT_MAX_SEGMENTS = 24,
    MAX_SEGMENTS_PER_BEAM = 256,
    MAX_INPUT_SEGMENTS = 256,
    MAX_TOMBSTONES_PER_VIEWER = 1024,
    MAX_RENDERER_TOMBSTONES = 1024,

    FAIRNESS_CAPACITY = 64,
    -- At the public registration limit, ceil(128 / 64) is exactly two frames.
    FAIRNESS_MAX_SERVICE_WINDOW_FRAMES = 2,

    DEFAULT_RADIUS = 12,
    MIN_RADIUS = 0.25,
    MIN_FILAMENT_RADIUS = 0.10,
    MAX_RADIUS = 512,
    DEFAULT_MIN_PIXEL_WIDTH = 0,
    MAX_MIN_PIXEL_WIDTH = 32,
    DEFAULT_CORE_RATIO = 0.24,
    DEFAULT_OUTER_COLOR = { 0.08, 0.45, 1.0 },
    DEFAULT_CORE_COLOR = { 0.75, 0.96, 1.0 },
    DEFAULT_INTENSITY = 1,
    DEFAULT_OPACITY = 1,
    DEFAULT_BASE_OPACITY = 0,
    DEFAULT_SPATIAL_FADE_LENGTH = 0,
    DEFAULT_DEPTH_SOFTNESS = 0,
    MAX_DEPTH_SOFTNESS = 512,
    DEFAULT_FOG_INFLUENCE = 0,
    DEFAULT_STYLE = "smooth",
    DEFAULT_STYLE_SCALE = 0,
    DEFAULT_LONGITUDINAL_MODE = "solid",
    DEFAULT_LONGITUDINAL_PATH_OFFSET = 0,
    DEFAULT_LONGITUDINAL_SPEED = 0,
    DEFAULT_PULSE_CARRIER_LEVEL = 0.25,
    MIN_LONGITUDINAL_LENGTH = 0.01,
    MAX_LONGITUDINAL_DISTANCE = 1000000,
    MAX_LONGITUDINAL_SPEED = 1000000,
    MAX_LONGITUDINAL_LOOP_DELAY = 3600,
    DEFAULT_PRIORITY = "normal",
    DEFAULT_AUDIENCE_MODE = "same_space",
    DEFAULT_FINISH_HOLD_DURATION = 0,
    DEFAULT_FINISH_FADE_DURATION = 0.14,
    DEFAULT_EMIT_DURATION = 0.25,
    DEFAULT_EMIT_FADE_DURATION = 0.10,
}

-- Lower-camel aliases make the version fields convenient to expose verbatim
-- through I.BeamFX without weakening the single source of truth above.
constants.packageVersion = constants.PACKAGE_VERSION
constants.apiMajor = constants.API_MAJOR
constants.apiMinor = constants.API_MINOR
constants.protocolVersion = constants.PROTOCOL_VERSION
constants.shaderAbi = constants.SHADER_ABI
constants.shaderResource = constants.SHADER_RESOURCE
constants.producerApiShape = constants.PRODUCER_API_SHAPE

constants.QUOTAS = {
    maxProducerIdLength = constants.MAX_PRODUCER_ID_LENGTH,
    maxProducerDisplayNameLength = constants.MAX_PRODUCER_DISPLAY_NAME_LENGTH,
    maxBeamIdLength = constants.MAX_BEAM_ID_LENGTH,
    maxEpochLength = constants.MAX_EPOCH_LENGTH,
    maxRendererSessionLength = constants.MAX_RENDERER_SESSION_LENGTH,
    maxSpaceKeyLength = constants.MAX_SPACE_KEY_LENGTH,
    maxReasonLength = constants.MAX_REASON_LENGTH,
    maxAbsCoordinate = constants.MAX_ABS_COORDINATE,
    maxRegisteredProducers = constants.MAX_REGISTERED_PRODUCERS,
    maxBeamsPerProducer = constants.MAX_BEAMS_PER_PRODUCER,
    maxBeamsGlobal = constants.MAX_BEAMS_GLOBAL,
    maxRetainedSegmentsPerProducer = constants.MAX_RETAINED_SEGMENTS_PER_PRODUCER,
    maxRetainedSegmentsGlobal = constants.MAX_RETAINED_SEGMENTS_GLOBAL,
    defaultMaxSegments = constants.DEFAULT_MAX_SEGMENTS,
    maxSegmentsPerBeam = constants.MAX_SEGMENTS_PER_BEAM,
    maxInputSegments = constants.MAX_INPUT_SEGMENTS,
    maxTombstonesPerViewer = constants.MAX_TOMBSTONES_PER_VIEWER,
}

function constants.serviceWindowFrames(producer_count)
    local count = math.max(0, math.floor(tonumber(producer_count) or 0))
    if count == 0 then
        return 0
    end
    return math.ceil(count / constants.FAIRNESS_CAPACITY)
end

return constants
