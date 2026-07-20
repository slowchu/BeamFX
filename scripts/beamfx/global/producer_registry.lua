---@omw-context global

local constants = require("scripts.beamfx.shared.constants")
local authoring = require("scripts.beamfx.shared.authoring")
local validation = require("scripts.beamfx.shared.validation")

local producer_registry = {}

local MAX_SAFE_INTEGER = 9007199254740991

local FACADE_METHODS = {
    "upsert",
    "emit",
    "upsertPath",
    "replaceSegments",
    "appendSegments",
    "renew",
    "finish",
    "remove",
    "clear",
    "release",
    "stats",
}

local function newDiagnostics()
    return {
        registrationAttempts = 0,
        successfulRegistrations = 0,
        boundaryInvalidRequests = 0,
        staleProducerRequests = 0,
        releasedProducers = 0,
    }
end

local function boundedEpoch(value)
    return type(value) == "string"
        and value ~= ""
        and #value <= constants.MAX_EPOCH_LENGTH
        and value:find("[%z\1-\31\127]") == nil
end

local function guardedField(object, key)
    if object == nil then
        return nil, false
    end
    local ok, value = pcall(function()
        return object[key]
    end)
    if not ok then
        return nil, false
    end
    return value, true
end

local function defensiveCopy(value, seen, depth, budget)
    local value_type = type(value)
    if value_type == "nil" or value_type == "boolean" or value_type == "string" then
        return value, true
    end
    if value_type == "number" then
        if not validation.isFinite(value) then
            return nil, false
        end
        return value, true
    end
    if value_type ~= "table" or depth > 12 or seen[value] then
        return nil, false
    end

    local copy = {}
    seen[value] = true
    for key, child in next, value do
        budget.count = budget.count + 1
        if budget.count > 8192 then
            seen[value] = nil
            return nil, false
        end
        local key_type = type(key)
        if key_type ~= "string"
            and (key_type ~= "number" or not validation.isFinite(key))
        then
            seen[value] = nil
            return nil, false
        end
        local child_copy, ok = defensiveCopy(child, seen, depth + 1, budget)
        if not ok then
            seen[value] = nil
            return nil, false
        end
        copy[key] = child_copy
    end
    seen[value] = nil
    return copy, true
end

local function copyResult(value)
    return defensiveCopy(value, {}, 0, { count = 0 })
end

local function safeCount(value)
    if not validation.isFinite(value) or value < 0 then
        return 0
    end
    return math.floor(value)
end

local function safeInteger(value, minimum)
    return validation.isFinite(value)
        and value == math.floor(value)
        and value >= (minimum or 0)
        and value <= MAX_SAFE_INTEGER
end

local function nextInteger(value)
    if not safeInteger(value, 0) or value >= MAX_SAFE_INTEGER then
        return nil
    end
    return value + 1
end

local function stateSnapshot(state)
    return {
        providerEpoch = state.providerEpoch,
        producerId = state.producerId,
        producerGeneration = state.producerGeneration,
        displayName = state.displayName,
        apiMajor = state.apiMajor,
        apiMinor = state.apiMinor,
        beamCount = safeCount(state.beamCount),
        segmentCount = safeCount(state.segmentCount),
        boundaryInvalidRequests =
            safeCount(state.boundaryInvalidRequests),
        staleProducerRequests =
            safeCount(state.staleProducerRequests),
    }
end

local function reportInternalError(on_error, operation, state, detail)
    if type(on_error) ~= "function" then
        return
    end
    pcall(on_error, operation, stateSnapshot(state), tostring(detail))
end

local function stableCallbackError(value)
    if type(value) == "string"
        and value ~= ""
        and #value <= constants.MAX_REASON_LENGTH
        and value:find("[%z\1-\31\127]") == nil
    then
        return value
    end
    return "provider_reset"
end

function producer_registry.new(options)
    if type(options) ~= "table"
        or not boundedEpoch(options.providerEpoch)
        or type(options.invoke) ~= "function"
        or (options.onError ~= nil and type(options.onError) ~= "function")
        or (
            options.initialProducerGeneration ~= nil
            and not safeInteger(options.initialProducerGeneration, 0)
        )
    then
        return nil, "invalid_spec"
    end

    local current_epoch = options.providerEpoch
    local invoke = options.invoke
    local on_error = options.onError
    local make_read_only = options.makeStrictReadOnly
    if make_read_only == nil then
        local candidate, ok =
            guardedField(options.util, "makeStrictReadOnly")
        if ok and type(candidate) == "function" then
            make_read_only = candidate
        end
    end
    if make_read_only ~= nil and type(make_read_only) ~= "function" then
        return nil, "invalid_spec"
    end
    local by_id = {}
    -- One session-wide scalar gives every successful registration a distinct
    -- generation without retaining an unbounded tombstone per released ID.
    local producer_generation = options.initialProducerGeneration or 0
    local active_count = 0
    local diagnostics = newDiagnostics()
    local instance = {}

    local function rejectBoundary(state, stale)
        diagnostics.boundaryInvalidRequests =
            diagnostics.boundaryInvalidRequests + 1
        if stale then
            diagnostics.staleProducerRequests =
                diagnostics.staleProducerRequests + 1
        end
        if type(state) == "table" then
            state.boundaryInvalidRequests =
                safeCount(state.boundaryInvalidRequests) + 1
            if stale then
                state.staleProducerRequests =
                    safeCount(state.staleProducerRequests) + 1
            end
        end
    end

    local function isLive(state)
        return state.live == true
            and state.providerEpoch == current_epoch
            and by_id[state.producerId] == state
    end

    local function invalidate(state)
        if not isLive(state) then
            state.live = false
            return
        end
        by_id[state.producerId] = nil
        state.live = false
        active_count = math.max(0, active_count - 1)
    end

    local function callBroker(state, method_name, ...)
        if not isLive(state) then
            rejectBoundary(state, true)
            return nil, "stale_producer"
        end

        local call_ok, result, err, detail =
            pcall(invoke, state, method_name, ...)
        if not call_ok then
            rejectBoundary(state, false)
            reportInternalError(on_error, method_name, state, result)
            return nil, "provider_reset"
        end
        if result == nil or result == false or err ~= nil then
            local detail_copy = nil
            if detail ~= nil then
                detail_copy = copyResult(detail)
            end
            return nil, stableCallbackError(err), detail_copy
        end

        local result_copy, copy_ok = copyResult(result)
        if not copy_ok then
            rejectBoundary(state, false)
            reportInternalError(on_error, method_name, state, "non_serializable_result")
            return nil, "provider_reset"
        end
        return result_copy
    end

    local function expandForFacade(state, expander, ...)
        if not isLive(state) then
            rejectBoundary(state, true)
            return nil, "stale_producer"
        end
        local value, err, detail = expander(...)
        if value == nil then
            rejectBoundary(state, false)
            return nil, err, detail
        end
        return value
    end

    local function makeFacade(state)
        local facade = {}

        -- The first argument is deliberately ignored. OpenMW may proxy the
        -- facade table across sandboxes, so identity-checking colon-call self
        -- would reject a legitimate capability.
        facade.upsert = function(_, local_beam_id, spec)
            local expanded, err, detail = expandForFacade(
                state,
                authoring.expandBeamSpec,
                spec
            )
            if expanded == nil then
                return nil, err, detail
            end
            return callBroker(
                state,
                "upsert",
                local_beam_id,
                expanded
            )
        end
        facade.emit = function(_, spec)
            local expanded, err, detail = expandForFacade(
                state,
                authoring.expandEmitSpec,
                spec
            )
            if expanded == nil then
                return nil, err, detail
            end
            for _ = 1, constants.MAX_BEAMS_PER_PRODUCER + 1 do
                local serial = nextInteger(state.nextEmitSerial)
                if serial == nil then
                    return nil, "provider_reset"
                end
                state.nextEmitSerial = serial
                local generated_id = string.format(
                    "@beamfx/emit/%d/%d",
                    state.producerGeneration,
                    serial
                )
                local result
                result, err, detail = callBroker(
                    state,
                    "emit",
                    generated_id,
                    expanded
                )
                if result ~= nil then
                    return result.id
                end
                if err ~= "beam_id_in_use" then
                    return nil, err, detail
                end
            end
            return nil, "provider_reset", {
                path = "",
                reason = "generated_id_exhausted",
                message = "BeamFX could not allocate a unique emit ID.",
            }
        end
        facade.upsertPath = function(_, local_beam_id, spec)
            local expanded, err, detail = expandForFacade(
                state,
                authoring.expandPathSpec,
                spec
            )
            if expanded == nil then
                return nil, err, detail
            end
            return callBroker(
                state,
                "upsert",
                local_beam_id,
                expanded
            )
        end
        facade.replaceSegments = function(
            _,
            local_beam_id,
            segments,
            options
        )
            local expanded, err, detail = expandForFacade(
                state,
                authoring.expandSegmentList,
                segments,
                "segments"
            )
            if expanded == nil then
                return nil, err, detail
            end
            return callBroker(
                state,
                "replaceSegments",
                local_beam_id,
                expanded,
                options
            )
        end
        facade.appendSegments = function(
            _,
            local_beam_id,
            segments,
            options
        )
            local expanded, err, detail = expandForFacade(
                state,
                authoring.expandSegmentList,
                segments,
                "segments"
            )
            if expanded == nil then
                return nil, err, detail
            end
            return callBroker(
                state,
                "appendSegments",
                local_beam_id,
                expanded,
                options
            )
        end
        facade.renew = function(_, ...)
            return callBroker(state, "renew", ...)
        end
        facade.finish = function(_, ...)
            return callBroker(state, "finish", ...)
        end
        facade.remove = function(_, ...)
            return callBroker(state, "remove", ...)
        end
        facade.clear = function(_, ...)
            return callBroker(state, "clear", ...)
        end
        facade.release = function(_, ...)
            local result, err, detail =
                callBroker(state, "release", ...)
            if result == nil then
                return nil, err, detail
            end
            diagnostics.releasedProducers =
                diagnostics.releasedProducers + 1
            invalidate(state)
            return result
        end
        facade.stats = function(_)
            local result, err = callBroker(state, "stats")
            if result == nil then
                return nil, err
            end
            result.cumulative = result.cumulative or {}
            local boundary_invalid =
                safeCount(state.boundaryInvalidRequests)
            result.cumulative.invalidRequests =
                safeCount(result.cumulative.invalidRequests)
                    + boundary_invalid
            result.cumulative.boundaryInvalidRequests =
                boundary_invalid
            result.cumulative.staleProducerRequests =
                safeCount(state.staleProducerRequests)
            return result
        end

        if make_read_only ~= nil then
            local ok, wrapped = pcall(make_read_only, facade)
            if not ok or wrapped == nil then
                reportInternalError(on_error, "registerProducer", state, wrapped)
                return nil, "provider_reset"
            end
            return wrapped
        end
        return facade
    end

    local function register(spec)
        diagnostics.registrationAttempts =
            diagnostics.registrationAttempts + 1
        local normalized, err = validation.normalizeProducerSpec(spec)
        if normalized == nil then
            rejectBoundary(nil, false)
            return nil, err
        end
        if by_id[normalized.id] ~= nil then
            rejectBoundary(by_id[normalized.id], false)
            return nil, "producer_id_in_use"
        end
        if active_count >= constants.MAX_REGISTERED_PRODUCERS then
            rejectBoundary(nil, false)
            return nil, "producer_quota_exceeded"
        end

        local generation = nextInteger(producer_generation)
        if generation == nil then
            rejectBoundary(nil, false)
            return nil, "provider_reset"
        end
        local state = {
            providerEpoch = current_epoch,
            producerId = normalized.id,
            producerGeneration = generation,
            displayName = normalized.displayName,
            apiMajor = normalized.apiMajor,
            apiMinor = normalized.apiMinor,
            beamCount = 0,
            segmentCount = 0,
            boundaryInvalidRequests = 0,
            staleProducerRequests = 0,
            nextEmitSerial = 0,
            live = true,
        }
        local facade, facade_err = makeFacade(state)
        if facade == nil then
            state.live = false
            rejectBoundary(state, false)
            return nil, facade_err
        end
        producer_generation = generation
        by_id[normalized.id] = state
        active_count = active_count + 1
        diagnostics.successfulRegistrations =
            diagnostics.successfulRegistrations + 1
        return facade
    end

    -- Accept both internal colon calls and direct function exposure through
    -- I.BeamFX.registerProducer.
    instance.register = function(first, second)
        return register(first == instance and second or first)
    end
    instance.registerProducer = instance.register

    instance.reset = function(first, second)
        local new_epoch = first == instance and second or first
        if not boundedEpoch(new_epoch) or new_epoch == current_epoch then
            return nil, "invalid_spec"
        end

        local old_epoch = current_epoch
        local invalidated = active_count
        for _, state in next, by_id do
            state.live = false
        end
        by_id = {}
        producer_generation = 0
        active_count = 0
        current_epoch = new_epoch
        diagnostics = newDiagnostics()
        return {
            oldProviderEpoch = old_epoch,
            providerEpoch = new_epoch,
            invalidatedProducers = invalidated,
        }
    end

    instance.providerEpoch = function(_)
        return current_epoch
    end

    instance.count = function(_)
        return active_count
    end
    instance.activeCount = instance.count

    instance.getById = function(first, second)
        local producer_id = first == instance and second or first
        producer_id = validation.normalizeProducerId(producer_id)
        if producer_id == nil then
            return nil
        end
        local state = by_id[producer_id]
        if state == nil or not isLive(state) then
            return nil
        end
        return stateSnapshot(state)
    end

    instance.liveStates = function(_)
        local result = {}
        for _, state in next, by_id do
            if isLive(state) then
                result[#result + 1] = stateSnapshot(state)
            end
        end
        table.sort(result, function(left, right)
            return left.producerId < right.producerId
        end)
        return result
    end

    instance.diagnostics = function(_)
        return {
            providerEpoch = current_epoch,
            current = {
                activeProducers = active_count,
            },
            cumulative = {
                registrationAttempts =
                    diagnostics.registrationAttempts,
                successfulRegistrations =
                    diagnostics.successfulRegistrations,
                boundaryInvalidRequests =
                    diagnostics.boundaryInvalidRequests,
                staleProducerRequests =
                    diagnostics.staleProducerRequests,
                releasedProducers =
                    diagnostics.releasedProducers,
            },
            producers = instance:liveStates(),
        }
    end

    return instance
end

producer_registry.create = producer_registry.new
producer_registry.FACADE_METHODS = FACADE_METHODS

return producer_registry
