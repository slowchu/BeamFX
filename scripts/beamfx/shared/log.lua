---@omw-context none

local log = {}

local LEVEL_NAMES = {
    trace = "TRACE",
    debug = "DEBUG",
    info = "INFO",
    warn = "WARN",
    error = "ERROR",
}

local LEVEL_VALUES = {
    trace = 10,
    debug = 20,
    info = 30,
    warn = 40,
    error = 50,
}

local current_level = LEVEL_VALUES.info

local function normalizeLevel(level)
    local key = string.lower(tostring(level or "info"))
    return LEVEL_VALUES[key] and key or "info"
end

local function messageFrom(...)
    local count = select("#", ...)
    if count == 0 then
        return ""
    end
    if count == 1 then
        return tostring(select(1, ...))
    end
    local parts = {}
    for i = 1, count do
        parts[i] = tostring(select(i, ...))
    end
    return table.concat(parts, " ")
end

local function emit(level, module_name, ...)
    local normalized = normalizeLevel(level)
    if LEVEL_VALUES[normalized] < current_level then
        return
    end
    local name = module_name or "unknown"
    local level_name = LEVEL_NAMES[normalized] or string.upper(tostring(normalized))
    print(string.format("[beamfx][%s][%s] %s", name, level_name, messageFrom(...)))
end

function log.setLevel(level)
    current_level = LEVEL_VALUES[normalizeLevel(level)]
end

function log.getLevel()
    for name, value in pairs(LEVEL_VALUES) do
        if value == current_level then
            return name
        end
    end
    return "info"
end

function log.isEnabled(level)
    return LEVEL_VALUES[normalizeLevel(level)] >= current_level
end

function log.new(module_name)
    local logger = {}
    logger.trace = function(...) emit("trace", module_name, ...) end
    logger.debug = function(...) emit("debug", module_name, ...) end
    logger.info = function(...) emit("info", module_name, ...) end
    logger.warn = function(...) emit("warn", module_name, ...) end
    logger.error = function(...) emit("error", module_name, ...) end
    return logger
end

return log
