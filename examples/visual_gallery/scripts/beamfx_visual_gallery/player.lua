---@omw-context player

local async = require("openmw.async")
local core = require("openmw.core")
local I = require("openmw.interfaces")
local input = require("openmw.input")
local ui = require("openmw.ui")
local self = require("openmw.self")
local util = require("openmw.util")

local shared = require("scripts.beamfx_visual_gallery.shared")

local v2 = util.vector2
local PANEL_SIZE = v2(650, 650)
local BUTTON_HEIGHT = 30
local LAYER = "Windows"

local white = ui.texture({ path = "white" })

local function color(r, g, b, a)
    if util.color and util.color.rgba then
        return util.color.rgba(r, g, b, a or 1)
    end
    if util.color and util.color.rgb then
        return util.color.rgb(r, g, b)
    end
    return nil
end

local COLORS = {
    background = color(0.018, 0.025, 0.040, 0.96),
    panel = color(0.035, 0.055, 0.085, 0.96),
    button = color(0.055, 0.095, 0.145, 0.98),
    border = color(0.20, 0.68, 1.00, 1),
    title = color(0.72, 0.92, 1.00, 1),
    text = color(0.88, 0.94, 1.00, 1),
    muted = color(0.58, 0.72, 0.82, 1),
    good = color(0.48, 1.00, 0.62, 1),
    warning = color(1.00, 0.66, 0.34, 1),
}

local state = {
    root = nil,
    active = false,
    started = false,
    paused = false,
    config = shared.defaultConfig(),
    categoryIndex = 1,
    recipeMode = "concise",
    status = "Starting BeamFX API 1.3 gallery...",
    statusOk = true,
    inputRegistered = false,
}

local function template(name)
    return I.MWUI and I.MWUI.templates and I.MWUI.templates[name] or nil
end

local function destroyRoot()
    local root = state.root
    state.root = nil
    local destroy = root and root.destroy
    if type(destroy) == "function" then
        pcall(destroy, root)
    end
end

local function rectangle(size, value)
    return {
        type = ui.TYPE.Image,
        props = {
            resource = white,
            size = size,
            color = value,
        },
    }
end

local function textNode(value, size, value_color, position, bounds)
    local props = {
        text = tostring(value or ""),
        textSize = size or 13,
        position = position or v2(0, 0),
    }
    if bounds ~= nil then
        props.size = bounds
    end
    if value_color ~= nil then
        props.textColor = value_color
    end
    return {
        template = template("textNormal"),
        type = ui.TYPE.Text,
        props = props,
    }
end

local function border(size)
    return {
        rectangle(v2(size.x, 1), COLORS.border),
        {
            type = ui.TYPE.Container,
            props = {
                position = v2(0, size.y - 1),
                size = v2(size.x, 1),
            },
            content = ui.content({
                rectangle(v2(size.x, 1), COLORS.border),
            }),
        },
        {
            type = ui.TYPE.Container,
            props = { position = v2(0, 0), size = v2(1, size.y) },
            content = ui.content({
                rectangle(v2(1, size.y), COLORS.border),
            }),
        },
        {
            type = ui.TYPE.Container,
            props = {
                position = v2(size.x - 1, 0),
                size = v2(1, size.y),
            },
            content = ui.content({
                rectangle(v2(1, size.y), COLORS.border),
            }),
        },
    }
end

local function centeredText(label, size, text_size)
    local value = tostring(label or "")
    local font_size = text_size or 13
    local approximate = math.min(size.x, #value * font_size * 0.54)
    return {
        type = ui.TYPE.Container,
        props = {
            position = v2(
                math.max(2, math.floor((size.x - approximate) / 2)),
                math.max(2, math.floor((size.y - font_size - 3) / 2))
            ),
            size = size,
        },
        content = ui.content({
            textNode(value, font_size, COLORS.title),
        }),
    }
end

local function button(label, position, size, callback)
    local contents = {
        rectangle(size, COLORS.button),
        centeredText(label, size, 12),
    }
    for _, line in ipairs(border(size)) do
        contents[#contents + 1] = line
    end
    return {
        type = ui.TYPE.Container,
        props = { position = position, size = size },
        events = {
            mousePress = async:callback(function()
                callback()
            end),
        },
        content = ui.content(contents),
    }
end

local function serializableConfig()
    return shared.normalizeConfig(state.config)
end

local function command(name, extra)
    local payload = {
        actor = self.object,
        command = name,
    }
    for key, value in pairs(extra or {}) do
        payload[key] = value
    end
    core.sendGlobalEvent(shared.EVENT_COMMAND, payload)
end

local render

local function updateConfig(next_config)
    state.config = shared.normalizeConfig(next_config)
    state.status = "Applying preview values..."
    state.statusOk = true
    command("update", { config = serializableConfig() })
    render()
end

local function category()
    return shared.CATEGORY_DEFS[state.categoryIndex]
        or shared.CATEGORY_DEFS[1]
end

local function cycleCategory(delta)
    local count = #shared.CATEGORY_DEFS
    state.categoryIndex = ((state.categoryIndex - 1 + delta) % count) + 1
    render()
end

local function adjustNumber(config, key, delta, minimum, maximum)
    local value = (tonumber(config[key]) or 0) + delta
    config[key] = math.max(minimum, math.min(maximum, value))
end

local function adjustCurrent(delta)
    local config = shared.copyConfig(state.config)
    local key = category().key
    if key == "preset" then
        config.preset = shared.cycle(
            shared.PRESET_NAMES,
            config.preset,
            delta
        )
        config.styleOverride = false
        local preset = shared.PRESETS[config.preset]
        if preset and preset.style then
            config.style = preset.style
            config.radius = preset.radius or config.radius
            config.intensity = preset.intensity or config.intensity
            config.minPixelWidth = preset.minPixelWidth or 0
        end
    elseif key == "style" then
        config.style = shared.cycle(
            shared.STYLE_NAMES,
            config.style,
            delta
        )
        config.styleOverride = true
        if config.style ~= "filament" then
            config.minPixelWidth = 0
        end
    elseif key == "radius" then
        adjustNumber(config, key, 0.5 * delta, 0.1, 64)
    elseif key == "intensity" then
        adjustNumber(config, key, 0.1 * delta, 0, 8)
    elseif key == "startFadeLength" or key == "endFadeLength" then
        adjustNumber(config, key, 2 * delta, 0, 128)
    elseif key == "taper" then
        config.taper = shared.cycle(
            shared.TAPER_NAMES,
            config.taper,
            delta
        )
    elseif key == "longitudinalMode" then
        config.longitudinalMode = shared.cycle(
            shared.LONGITUDINAL_NAMES,
            config.longitudinalMode,
            delta
        )
    elseif key == "minPixelWidth" then
        adjustNumber(config, key, 0.25 * delta, 0, 8)
        if config.minPixelWidth > 0 then
            config.style = "filament"
            config.styleOverride = true
        end
    end
    updateConfig(config)
end

local function startGallery()
    state.active = true
    state.started = true
    state.paused = false
    state.status = "Positioning preview in front of the player..."
    state.statusOk = true
    command("start", { config = serializableConfig() })
    render()
end

local function stopGallery()
    if state.active then
        command("stop")
    end
    state.active = false
    state.paused = false
    destroyRoot()
end

local function toggleGallery()
    if state.active then
        stopGallery()
    else
        startGallery()
    end
end

local function reposition()
    state.status = "Repositioning preview..."
    state.statusOk = true
    command("reposition")
    render()
end

local function togglePause()
    state.paused = not state.paused
    state.status = state.paused
        and "Pausing longitudinal motion..."
        or "Resuming longitudinal motion..."
    state.statusOk = true
    command("pause", { paused = state.paused })
    render()
end

local function reset()
    state.config = shared.defaultConfig()
    state.paused = false
    state.categoryIndex = 1
    state.status = "Resetting preview..."
    state.statusOk = true
    command("reset", { config = serializableConfig() })
    render()
end

local function printRecipe()
    state.status = "Writing both recipes to openmw.log..."
    state.statusOk = true
    command("print")
    render()
end

local function toggleRecipe()
    state.recipeMode = state.recipeMode == "concise"
        and "expanded"
        or "concise"
    render()
end

local function statusText()
    local value = state.status
    if #value > 92 then
        value = string.sub(value, 1, 89) .. "..."
    end
    return value
end

local function summaryText(config)
    return string.format(
        "Preset %s    Style %s    Radius %.2f    Intensity %.2f\n"
            .. "Fades %.1f / %.1f    Taper %s    Pattern %s    Pixel floor %.2f",
        config.preset,
        config.style,
        config.radius,
        config.intensity,
        config.startFadeLength,
        config.endFadeLength,
        config.taper,
        config.longitudinalMode,
        config.minPixelWidth
    )
end

local function buildLayout()
    local config = shared.normalizeConfig(state.config)
    local selected = category()
    local recipe = state.recipeMode == "expanded"
        and shared.expandedRecipe(config)
        or shared.conciseRecipe(config)
    local contents = {
        rectangle(PANEL_SIZE, COLORS.background),
        textNode(
            "BeamFX Visual Gallery",
            20,
            COLORS.title,
            v2(14, 10),
            v2(610, 24)
        ),
        textNode(
            "API 1.3 effect-design tool | F7 reposition | F8 toggle",
            11,
            COLORS.muted,
            v2(14, 38),
            v2(610, 18)
        ),
        textNode(
            statusText(),
            12,
            state.statusOk and COLORS.good or COLORS.warning,
            v2(14, 62),
            v2(610, 20)
        ),
        button("<", v2(14, 91), v2(48, BUTTON_HEIGHT), function()
            cycleCategory(-1)
        end),
        button(
            selected.label,
            v2(70, 91),
            v2(500, BUTTON_HEIGHT),
            function()
                cycleCategory(1)
            end
        ),
        button(">", v2(578, 91), v2(48, BUTTON_HEIGHT), function()
            cycleCategory(1)
        end),
        button("-", v2(14, 129), v2(48, BUTTON_HEIGHT), function()
            adjustCurrent(-1)
        end),
        button(
            shared.displayValue(config, selected.key),
            v2(70, 129),
            v2(500, BUTTON_HEIGHT),
            function()
                adjustCurrent(1)
            end
        ),
        button("+", v2(578, 129), v2(48, BUTTON_HEIGHT), function()
            adjustCurrent(1)
        end),
        textNode(
            summaryText(config),
            11,
            COLORS.text,
            v2(14, 169),
            v2(612, 38)
        ),
        button(
            "Reposition",
            v2(14, 215),
            v2(100, BUTTON_HEIGHT),
            reposition
        ),
        button(
            state.paused and "Resume" or "Pause",
            v2(120, 215),
            v2(82, BUTTON_HEIGHT),
            togglePause
        ),
        button("Reset", v2(208, 215), v2(76, BUTTON_HEIGHT), reset),
        button(
            "Print",
            v2(290, 215),
            v2(76, BUTTON_HEIGHT),
            printRecipe
        ),
        button(
            state.recipeMode == "concise" and "Show expanded" or "Show concise",
            v2(372, 215),
            v2(142, BUTTON_HEIGHT),
            toggleRecipe
        ),
        button(
            "Close + clear",
            v2(520, 215),
            v2(106, BUTTON_HEIGHT),
            stopGallery
        ),
        textNode(
            state.recipeMode == "concise"
                and "Copy-ready public input"
                or "Resolved canonical appearance",
            13,
            COLORS.title,
            v2(14, 257),
            v2(612, 20)
        ),
        {
            type = ui.TYPE.Container,
            props = {
                position = v2(12, 282),
                size = v2(616, 354),
            },
            content = ui.content({
                rectangle(v2(616, 354), COLORS.panel),
                textNode(
                    recipe,
                    state.recipeMode == "concise" and 11 or 10,
                    COLORS.text,
                    v2(9, 8),
                    v2(598, 338)
                ),
            }),
        },
    }
    for _, line in ipairs(border(PANEL_SIZE)) do
        contents[#contents + 1] = line
    end
    return {
        layer = LAYER,
        type = ui.TYPE.Container,
        props = {
            relativePosition = v2(0, 0),
            anchor = v2(0, 0),
            position = v2(14, 14),
            size = PANEL_SIZE,
        },
        content = ui.content(contents),
    }
end

function render()
    destroyRoot()
    if not state.active then
        return
    end
    local ok, root_or_error = pcall(function()
        return ui.create(buildLayout(), { noWarnUnused = true })
    end)
    if ok then
        state.root = root_or_error
    else
        state.statusOk = false
        state.status = "UI creation failed; use F8 to stop: "
            .. tostring(root_or_error)
        print("[BeamFX visual gallery] " .. state.status)
    end
end

local function handleStatus(payload)
    if type(payload) ~= "table" then
        return
    end
    state.statusOk = payload.ok == true
    state.paused = payload.paused == true
    local parts = { tostring(payload.code or "status") }
    if type(payload.path) == "string" and payload.path ~= "" then
        parts[#parts + 1] = "at " .. payload.path
    end
    if type(payload.reason) == "string" and payload.reason ~= "" then
        parts[#parts + 1] = "(" .. payload.reason .. ")"
    end
    if type(payload.message) == "string" and payload.message ~= "" then
        parts[#parts + 1] = payload.message
    end
    state.status = table.concat(parts, " ")
    render()
end

local function registerInput()
    if state.inputRegistered
        or type(input.registerTriggerHandler) ~= "function"
        or input.triggers == nil
        or input.triggers[shared.TRIGGER_TOGGLE] == nil
        or input.triggers[shared.TRIGGER_REPOSITION] == nil
    then
        return
    end
    local ok, err = pcall(function()
        input.registerTriggerHandler(
            shared.TRIGGER_TOGGLE,
            async:callback(toggleGallery)
        )
        input.registerTriggerHandler(
            shared.TRIGGER_REPOSITION,
            async:callback(function()
                if state.active then
                    reposition()
                end
            end)
        )
    end)
    if ok then
        state.inputRegistered = true
    else
        print(
            "[BeamFX visual gallery] named input registration failed: "
                .. tostring(err)
        )
    end
end

local function onUpdate()
    registerInput()
    if not state.started then
        startGallery()
    end
end

local function resetRuntime()
    destroyRoot()
    state.active = false
    state.started = false
    state.paused = false
    state.config = shared.defaultConfig()
    state.categoryIndex = 1
    state.recipeMode = "concise"
    state.status = "Starting BeamFX API 1.3 gallery..."
    state.statusOk = true
end

return {
    eventHandlers = {
        [shared.EVENT_STATUS] = handleStatus,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad = resetRuntime,
    },
}
