---@omw-context global | player | none

local constants = {
    PACKAGE_VERSION = "0.1.0-alpha.1",
    API_MAJOR = 1,
    API_MINOR = 0,
    PROTOCOL_VERSION = 1,
    SHADER_ABI = 1,
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
    DEFAULT_CORE_RATIO = 0.24,
    DEFAULT_OUTER_COLOR = { 0.08, 0.45, 1.0 },
    DEFAULT_CORE_COLOR = { 0.75, 0.96, 1.0 },
    DEFAULT_INTENSITY = 1,
    DEFAULT_OPACITY = 1,
    DEFAULT_STYLE = "smooth",
    DEFAULT_STYLE_SCALE = 0,
    DEFAULT_PRIORITY = "normal",
    DEFAULT_AUDIENCE_MODE = "same_space",
    DEFAULT_FINISH_HOLD_DURATION = 0,
    DEFAULT_FINISH_FADE_DURATION = 0.14,
}

-- Lower-camel aliases make the version fields convenient to expose verbatim
-- through I.BeamFX without weakening the single source of truth above.
constants.packageVersion = constants.PACKAGE_VERSION
constants.apiMajor = constants.API_MAJOR
constants.apiMinor = constants.API_MINOR
constants.protocolVersion = constants.PROTOCOL_VERSION
constants.shaderAbi = constants.SHADER_ABI
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
