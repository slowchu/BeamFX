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
local MODE = (I.UI and I.UI.MODE and I.UI.MODE.Interface) or "Interface"
local PREFERRED_PANEL_SIZE = v2(650, 650)
local MAX_PANEL_SIZE = v2(760, 700)
local BUTTON_HEIGHT = 30
local LAYER = "Windows"
local SCREEN_MARGIN = 12

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
    hit = color(0, 0, 0, 0.001),
}

local state = {
    root = nil,
    active = false,
    previewActive = false,
    started = false,
    paused = false,
    config = shared.defaultConfig(),
    categoryIndex = 1,
    recipeMode = "concise",
    status = "Starting BeamFX API 1.3 gallery...",
    statusOk = true,
    inputRegistered = false,
    position = nil,
    dragging = false,
    dragMouse = nil,
    dragPosition = nil,
    dragUpdatedFromMouseEvent = false,
    modeAdded = false,
    activeMode = nil,
    restorePauseOnClose = false,
    lastLayerSize = nil,
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

local function hasMode(mode_name)
    for _, mode in ipairs((I.UI and I.UI.modes) or {}) do
        if mode == mode_name then
            return true
        end
    end
    return false
end

local function currentUiMode()
    if not (I.UI and I.UI.getMode) then
        return nil
    end
    local ok, mode = pcall(I.UI.getMode)
    if ok then
        return mode
    end
    return nil
end

local function addUiMode()
    if state.modeAdded and state.activeMode and hasMode(state.activeMode) then
        return true
    end
    local ui_interface = I.UI
    if not (ui_interface and ui_interface.addMode) then
        state.modeAdded = false
        state.activeMode = nil
        return false, "ui_add_mode_unavailable"
    end

    -- An existing OpenMW mode already supplies a visible cursor and makes the
    -- Windows layer interactive. Do not disturb its windows or claim ownership.
    if currentUiMode() ~= nil then
        state.modeAdded = false
        state.activeMode = nil
        return true
    end

    -- OpenMW exposes no scoped "show cursor" operation. The supported route is
    -- an empty Interface mode. Beam animation is simulation-time based, so the
    -- gallery temporarily makes that mode non-pausing and restores OpenMW's
    -- default pause policy when it releases the mode.
    if ui_interface.setPauseOnMode then
        local pause_ok = pcall(ui_interface.setPauseOnMode, MODE, false)
        state.restorePauseOnClose = pause_ok
    end
    local ok, err = pcall(ui_interface.addMode, MODE, { windows = {} })
    if not ok or not hasMode(MODE) then
        if state.restorePauseOnClose and ui_interface.setPauseOnMode then
            pcall(ui_interface.setPauseOnMode, MODE, true)
        end
        state.restorePauseOnClose = false
        state.modeAdded = false
        state.activeMode = nil
        return false, tostring(err or "mode_not_present_after_add")
    end

    state.modeAdded = true
    state.activeMode = MODE
    return true
end

local function removeUiMode()
    local ui_interface = I.UI
    local active_mode = state.activeMode
    if ui_interface
        and ui_interface.removeMode
        and active_mode
        and hasMode(active_mode)
    then
        pcall(ui_interface.removeMode, active_mode)
    end
    if state.restorePauseOnClose
        and ui_interface
        and ui_interface.setPauseOnMode
    then
        pcall(ui_interface.setPauseOnMode, MODE, true)
    end
    state.modeAdded = false
    state.activeMode = nil
    state.restorePauseOnClose = false
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
        props.autoSize = false
        props.multiline = true
        props.wordWrap = true
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

local function paragraphNode(value, size, text_size, value_color, position)
    return {
        template = template("textParagraph"),
        type = ui.TYPE.TextEdit,
        props = {
            text = tostring(value or ""),
            textSize = text_size or 10,
            textColor = value_color,
            position = position or v2(0, 0),
            size = size,
            readOnly = true,
            multiline = true,
            wordWrap = true,
            autoSize = false,
        },
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

local function button(label, position, size, callback, text_size)
    local contents = {
        rectangle(size, COLORS.button),
        centeredText(label, size, text_size or 12),
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

local function layerSize()
    local layers = ui.layers
    local index = layers and layers.indexOf and layers.indexOf(LAYER) or nil
    local layer = index and layers[index] or nil
    local size = layer and layer.size or ui.screenSize()
    return v2(
        math.max(1, tonumber(size and size.x) or 1),
        math.max(1, tonumber(size and size.y) or 1)
    )
end

local function fittedDimension(available, preferred, maximum, ratio, total)
    if available < preferred then
        return math.max(1, math.floor(available))
    end
    return math.max(1, math.min(
        math.floor(available),
        maximum,
        math.max(preferred, math.floor(total * ratio))
    ))
end

local function layoutMetrics()
    local layer = layerSize()
    local available_width = math.max(1, layer.x - SCREEN_MARGIN * 2)
    local available_height = math.max(1, layer.y - SCREEN_MARGIN * 2)
    local panel = v2(
        fittedDimension(
            available_width,
            PREFERRED_PANEL_SIZE.x,
            MAX_PANEL_SIZE.x,
            0.52,
            layer.x
        ),
        fittedDimension(
            available_height,
            PREFERRED_PANEL_SIZE.y,
            MAX_PANEL_SIZE.y,
            0.86,
            layer.y
        )
    )
    local compact = panel.x < 620 or panel.y < 600
    local margin = compact and 10 or 14
    local button_height = compact and 26 or BUTTON_HEIGHT
    local first_control_y = compact and 73 or 91
    local second_control_y = first_control_y + button_height + (compact and 6 or 8)
    local summary_y = second_control_y + button_height + (compact and 7 or 10)
    local summary_height = compact and 34 or 38
    local actions_y = summary_y + summary_height + (compact and 6 or 8)
    local recipe_label_y = actions_y + button_height + (compact and 7 or 12)
    local recipe_y = recipe_label_y + (compact and 22 or 25)
    local recipe_height = math.max(1, panel.y - recipe_y - margin)
    return {
        layer = layer,
        panel = panel,
        compact = compact,
        margin = margin,
        innerWidth = math.max(1, panel.x - margin * 2),
        buttonHeight = button_height,
        firstControlY = first_control_y,
        secondControlY = second_control_y,
        summaryY = summary_y,
        summaryHeight = summary_height,
        actionsY = actions_y,
        recipeLabelY = recipe_label_y,
        recipeY = recipe_y,
        recipeHeight = recipe_height,
        headerDragHeight = math.max(1, first_control_y - 4),
    }
end

local function clamp(value, minimum, maximum)
    local number = tonumber(value) or 0
    return math.max(minimum, math.min(maximum, number))
end

local function safePosition(position)
    local metrics = layoutMetrics()
    local current = position or v2(0, 0)
    local max_x = math.max(
        0,
        math.floor((metrics.layer.x - metrics.panel.x) / 2) - SCREEN_MARGIN
    )
    local max_y = math.max(
        0,
        math.floor((metrics.layer.y - metrics.panel.y) / 2) - SCREEN_MARGIN
    )
    return v2(
        clamp(current.x, -max_x, max_x),
        clamp(current.y, -max_y, max_y)
    )
end

local function ensurePosition()
    state.position = safePosition(state.position)
end

local function mouseEvent(first, second)
    if type(first) == "table" and first.position then
        return first
    end
    if type(second) == "table" and second.position then
        return second
    end
    return nil
end

local function isPrimaryMouse(event)
    local button = event and event.button
    return button == nil or button == 0 or button == 1
end

local function updateRootPosition()
    local root = state.root
    local layout = root and root.layout
    if layout and layout.props and type(root.update) == "function" then
        layout.props.position = state.position
        local ok = pcall(function()
            root:update()
        end)
        if ok then
            return
        end
    end
    render()
end

local function moveWindow(position)
    state.position = safePosition(position)
    updateRootPosition()
end

local function windowDragEvents()
    return {
        mousePress = async:callback(function(first, second)
            local event = mouseEvent(first, second)
            if not isPrimaryMouse(event) then
                return
            end
            state.dragging = true
            state.dragMouse = event and event.position or nil
            state.dragPosition = state.position or v2(0, 0)
            state.dragUpdatedFromMouseEvent = false
        end),
        mouseMove = async:callback(function(first, second)
            if not state.dragging then
                return
            end
            local event = mouseEvent(first, second)
            if event and event.position and state.dragMouse and state.dragPosition then
                state.dragUpdatedFromMouseEvent = true
                moveWindow(
                    state.dragPosition + (event.position - state.dragMouse)
                )
            end
        end),
        mouseRelease = async:callback(function()
            state.dragging = false
            state.dragMouse = nil
            state.dragPosition = nil
            state.dragUpdatedFromMouseEvent = false
        end),
    }
end

local function updateConfig(next_config)
    state.config = shared.normalizeConfig(next_config)
    if state.previewActive then
        state.status = "Applying preview values..."
        command("update", { config = serializableConfig() })
    else
        state.status = "Values updated. Use Preview to recreate the beam."
    end
    state.statusOk = true
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

local function startPreview()
    state.previewActive = true
    state.paused = false
    state.status = "Positioning preview in front of the player..."
    state.statusOk = true
    command("start", { config = serializableConfig() })
end

local function openGallery()
    state.active = true
    state.started = true
    ensurePosition()
    local mode_ok, mode_error = addUiMode()

    if not state.previewActive then
        startPreview()
    elseif mode_ok then
        state.status = "Preview remains active; Hide leaves it visible in the world."
        state.statusOk = true
    end

    if not mode_ok then
        state.status = "Preview active, but cursor mode failed: "
            .. tostring(mode_error)
        state.statusOk = false
    end
    render()
end

local function hideGallery()
    state.active = false
    state.dragging = false
    state.dragMouse = nil
    state.dragPosition = nil
    state.dragUpdatedFromMouseEvent = false
    destroyRoot()
    removeUiMode()
end

local function clearPreview()
    if state.previewActive then
        command("stop")
    end
    state.previewActive = false
    state.paused = false
    state.status = "Preview cleared. Use Preview to recreate it."
    state.statusOk = true
    render()
end

local function togglePreview()
    if state.previewActive then
        clearPreview()
    else
        startPreview()
        render()
    end
end

local function toggleGallery()
    if state.active then
        hideGallery()
    else
        openGallery()
    end
end

local function reposition()
    if not state.previewActive then
        state.status = "Preview is cleared. Use Preview to recreate it."
        state.statusOk = false
        render()
        return
    end
    state.status = "Repositioning preview..."
    state.statusOk = true
    command("reposition")
    render()
end

local function togglePause()
    if not state.previewActive then
        state.status = "Preview is cleared. Use Preview before pausing it."
        state.statusOk = false
        render()
        return
    end
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
    if state.previewActive then
        state.status = "Resetting preview..."
        command("reset", { config = serializableConfig() })
    else
        state.status = "Defaults restored. Use Preview to recreate the beam."
    end
    state.statusOk = true
    render()
end

local function printRecipe()
    state.status = "Writing both recipes to openmw.log..."
    state.statusOk = true
    print(
        "[BeamFX visual gallery] Copy-ready concise recipe:\n"
            .. shared.conciseRecipe(state.config)
    )
    print(
        "[BeamFX visual gallery] Resolved appearance:\n"
            .. shared.expandedRecipe(state.config)
    )
    render()
end

local function toggleRecipe()
    state.recipeMode = state.recipeMode == "concise"
        and "expanded"
        or "concise"
    render()
end

local function statusText(maximum_characters)
    local value = state.status
    local maximum = math.max(24, tonumber(maximum_characters) or 92)
    if #value > maximum then
        value = string.sub(value, 1, maximum - 3) .. "..."
    end
    return value
end

local function summaryText(config, compact)
    if compact then
        return string.format(
            "%s / %s    R %.2f    I %.2f\n"
                .. "Fade %.1f / %.1f    %s    %s    Px %.2f",
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
    local metrics = layoutMetrics()
    ensurePosition()
    state.lastLayerSize = metrics.layer
    local config = shared.normalizeConfig(state.config)
    local selected = category()
    local recipe = state.recipeMode == "expanded"
        and shared.expandedRecipe(config)
        or shared.conciseRecipe(config)
    local panel = metrics.panel
    local margin = metrics.margin
    local inner_width = metrics.innerWidth
    local control_gap = metrics.compact and 6 or 8
    local arrow_width = metrics.compact and 38 or 48
    local center_width = math.max(
        1,
        inner_width - arrow_width * 2 - control_gap * 2
    )
    local center_x = margin + arrow_width + control_gap
    local right_x = center_x + center_width + control_gap
    local button_size = v2(arrow_width, metrics.buttonHeight)
    local center_size = v2(center_width, metrics.buttonHeight)
    local action_gap = metrics.compact and 4 or 6
    local action_count = 7
    local action_width = math.max(
        1,
        math.floor(
            (inner_width - action_gap * (action_count - 1)) / action_count
        )
    )
    local action_remainder = math.max(
        1,
        inner_width
            - (action_width + action_gap) * (action_count - 1)
    )
    local action_text_size = metrics.compact and 9 or 10
    local recipe_outer_size = v2(inner_width, metrics.recipeHeight)
    local recipe_padding = metrics.compact and 6 or 8
    local recipe_inner_size = v2(
        math.max(1, recipe_outer_size.x - recipe_padding * 2),
        math.max(1, recipe_outer_size.y - recipe_padding * 2)
    )
    local header_width = math.max(1, panel.x - margin * 2)
    local title_y = metrics.compact and 7 or 10
    local subtitle_y = metrics.compact and 30 or 38
    local status_y = metrics.compact and 50 or 62
    local title_size = metrics.compact and 17 or 20
    local subtitle_size = metrics.compact and 9 or 11
    local status_size = metrics.compact and 10 or 12
    local status_characters = math.floor(
        header_width / math.max(1, status_size * 0.54)
    )
    local contents = {
        rectangle(panel, COLORS.background),
        textNode(
            "BeamFX Visual Gallery",
            title_size,
            COLORS.title,
            v2(margin, title_y),
            v2(header_width, title_size + 5)
        ),
        textNode(
            metrics.compact
                    and "API 1.3 | drag header | F7 preview | F8 toggle"
                or "API 1.3 effect-design tool | drag header | F7 preview | F8 toggle",
            subtitle_size,
            COLORS.muted,
            v2(margin, subtitle_y),
            v2(header_width, subtitle_size + 5)
        ),
        textNode(
            statusText(status_characters),
            status_size,
            state.statusOk and COLORS.good or COLORS.warning,
            v2(margin, status_y),
            v2(header_width, status_size + 5)
        ),
        button("<", v2(margin, metrics.firstControlY), button_size, function()
            cycleCategory(-1)
        end),
        button(
            selected.label,
            v2(center_x, metrics.firstControlY),
            center_size,
            function()
                cycleCategory(1)
            end
        ),
        button(">", v2(right_x, metrics.firstControlY), button_size, function()
            cycleCategory(1)
        end),
        button("-", v2(margin, metrics.secondControlY), button_size, function()
            adjustCurrent(-1)
        end),
        button(
            shared.displayValue(config, selected.key),
            v2(center_x, metrics.secondControlY),
            center_size,
            function()
                adjustCurrent(1)
            end
        ),
        button("+", v2(right_x, metrics.secondControlY), button_size, function()
            adjustCurrent(1)
        end),
        textNode(
            summaryText(config, metrics.compact),
            metrics.compact and 9 or 11,
            COLORS.text,
            v2(margin, metrics.summaryY),
            v2(inner_width, metrics.summaryHeight)
        ),
        textNode(
            state.recipeMode == "concise"
                and "Copy-ready public input"
                or "Resolved canonical appearance",
            metrics.compact and 11 or 13,
            COLORS.title,
            v2(margin, metrics.recipeLabelY),
            v2(inner_width, metrics.compact and 17 or 20)
        ),
        {
            type = ui.TYPE.Container,
            props = {
                position = v2(margin, metrics.recipeY),
                size = recipe_outer_size,
            },
            content = ui.content({
                rectangle(recipe_outer_size, COLORS.panel),
                paragraphNode(
                    recipe,
                    recipe_inner_size,
                    metrics.compact
                            and (state.recipeMode == "concise" and 9 or 8)
                        or (state.recipeMode == "concise" and 11 or 10),
                    COLORS.text,
                    v2(recipe_padding, recipe_padding)
                ),
            }),
        },
    }

    local action_labels = {
        "Reposition",
        state.paused and "Resume" or "Pause",
        "Reset",
        "Print",
        state.recipeMode == "concise" and "Expanded" or "Concise",
        "Hide",
        state.previewActive and "Clear" or "Preview",
    }
    local action_callbacks = {
        reposition,
        togglePause,
        reset,
        printRecipe,
        toggleRecipe,
        hideGallery,
        togglePreview,
    }
    for index = 1, action_count do
        local x = margin + (index - 1) * (action_width + action_gap)
        local width = index == action_count
                and action_remainder
            or action_width
        contents[#contents + 1] = button(
            action_labels[index],
            v2(x, metrics.actionsY),
            v2(width, metrics.buttonHeight),
            action_callbacks[index],
            action_text_size
        )
    end

    contents[#contents + 1] = {
        type = ui.TYPE.Container,
        props = {
            position = v2(0, 0),
            size = v2(panel.x, metrics.headerDragHeight),
        },
        events = windowDragEvents(),
        content = ui.content({
            rectangle(
                v2(panel.x, metrics.headerDragHeight),
                COLORS.hit
            ),
        }),
    }
    for _, line in ipairs(border(panel)) do
        contents[#contents + 1] = line
    end
    return {
        layer = LAYER,
        type = ui.TYPE.Container,
        props = {
            relativePosition = v2(0.5, 0.5),
            anchor = v2(0.5, 0.5),
            position = state.position,
            size = panel,
        },
        content = ui.content(contents),
    }
end

function render()
    destroyRoot()
    if not state.active then
        return
    end
    ensurePosition()
    local ok, root_or_error = pcall(function()
        return ui.create(buildLayout(), { noWarnUnused = true })
    end)
    if ok then
        state.root = root_or_error
    else
        state.statusOk = false
        state.status = "UI creation failed; use F8 to hide it: "
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
    if type(payload.active) == "boolean" then
        state.previewActive = payload.active
    end
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
                if state.previewActive then
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
        openGallery()
    end
end

local function onFrame()
    if not state.active then
        return
    end

    local current_size = layerSize()
    local previous_size = state.lastLayerSize
    if previous_size == nil
        or current_size.x ~= previous_size.x
        or current_size.y ~= previous_size.y
    then
        state.lastLayerSize = current_size
        state.position = safePosition(state.position)
        render()
    end

    if not state.dragging then
        return
    end
    if not input.isMouseButtonPressed(1) then
        state.dragging = false
        state.dragMouse = nil
        state.dragPosition = nil
        state.dragUpdatedFromMouseEvent = false
        return
    end
    if state.dragUpdatedFromMouseEvent then
        state.dragUpdatedFromMouseEvent = false
        return
    end

    local dx = input.getMouseMoveX() or 0
    local dy = input.getMouseMoveY() or 0
    if dx ~= 0 or dy ~= 0 then
        moveWindow((state.position or v2(0, 0)) + v2(dx, dy))
    end
end

local function onUiModeChanged()
    if not state.active then
        return
    end

    if state.modeAdded
        and state.activeMode
        and not hasMode(state.activeMode)
    then
        removeUiMode()
    end
    if currentUiMode() == nil then
        local ok, err = addUiMode()
        if not ok then
            state.statusOk = false
            state.status = "Cursor mode could not be restored: " .. tostring(err)
            render()
        end
    end
end

local function onKeyPress(key)
    if not state.active
        or not state.modeAdded
        or currentUiMode() ~= state.activeMode
    then
        return true
    end
    local symbol = key and key.symbol and string.lower(key.symbol) or ""
    local escape_key = input.KEY and input.KEY.Escape
    if symbol == "escape"
        or symbol == "esc"
        or (escape_key and key and key.code == input.KEY.Escape)
    then
        hideGallery()
        return false
    end
    return true
end

local function resetRuntime()
    state.active = false
    state.previewActive = false
    destroyRoot()
    removeUiMode()
    state.started = false
    state.paused = false
    state.config = shared.defaultConfig()
    state.categoryIndex = 1
    state.recipeMode = "concise"
    state.status = "Starting BeamFX API 1.3 gallery..."
    state.statusOk = true
    state.position = nil
    state.dragging = false
    state.dragMouse = nil
    state.dragPosition = nil
    state.dragUpdatedFromMouseEvent = false
    state.lastLayerSize = nil
end

return {
    eventHandlers = {
        [shared.EVENT_STATUS] = handleStatus,
        UiModeChanged = onUiModeChanged,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onFrame = onFrame,
        onKeyPress = onKeyPress,
        onLoad = resetRuntime,
    },
}
