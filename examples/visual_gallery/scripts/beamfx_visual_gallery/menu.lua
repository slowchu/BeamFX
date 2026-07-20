---@omw-context menu

local I = require("openmw.interfaces")
local input = require("openmw.input")
local storage = require("openmw.storage")

local shared = require("scripts.beamfx_visual_gallery.shared")

local registered = false

local function safe(label, callback)
    local ok, err = pcall(callback)
    if not ok then
        print(
            "[BeamFX visual gallery] "
                .. tostring(label)
                .. " failed: "
                .. tostring(err)
        )
    end
    return ok
end

local function registerTrigger(key, name, description)
    if input.triggers and input.triggers[key] ~= nil then
        return
    end
    if type(input.registerTrigger) ~= "function" then
        return
    end
    input.registerTrigger({
        key = key,
        l10n = "BeamFXVisualGallery",
        name = name,
        description = description,
    })
end

local function registerSettings()
    if not (I.Settings and I.Settings.registerPage and I.Settings.registerGroup) then
        return
    end
    pcall(I.Settings.registerPage, {
        key = shared.SETTINGS_PAGE,
        l10n = "BeamFXVisualGallery",
        name = "SettingsPage",
        description = "SettingsPageDescription",
    })
    pcall(I.Settings.registerGroup, {
        key = shared.SETTINGS_GROUP,
        page = shared.SETTINGS_PAGE,
        l10n = "BeamFXVisualGallery",
        name = "ControlsGroup",
        description = "ControlsGroupDescription",
        permanentStorage = true,
        order = 1,
        settings = {
            {
                key = "toggleBinding",
                name = "ToggleBinding",
                description = "ToggleBindingDescription",
                renderer = "inputBinding",
                default = shared.BINDING_TOGGLE,
                argument = {
                    type = "trigger",
                    key = shared.TRIGGER_TOGGLE,
                },
            },
            {
                key = "repositionBinding",
                name = "RepositionBinding",
                description = "RepositionBindingDescription",
                renderer = "inputBinding",
                default = shared.BINDING_REPOSITION,
                argument = {
                    type = "trigger",
                    key = shared.TRIGGER_REPOSITION,
                },
            },
        },
    })
end

local function createDefaultBinding(section, id, trigger, key)
    if section:get(id) ~= nil or key == nil then
        return
    end
    section:set(id, {
        type = "trigger",
        key = trigger,
        device = "keyboard",
        button = key,
    })
end

local function registerDefaults()
    if not (storage and storage.playerSection) then
        return
    end
    local ok, section = pcall(
        storage.playerSection,
        shared.OMW_BINDINGS_SECTION
    )
    if not ok or section == nil then
        return
    end
    local keys = input.KEY or {}
    createDefaultBinding(
        section,
        shared.BINDING_TOGGLE,
        shared.TRIGGER_TOGGLE,
        keys.F8
    )
    createDefaultBinding(
        section,
        shared.BINDING_REPOSITION,
        shared.TRIGGER_REPOSITION,
        keys.F7
    )
end

local function registerAll()
    if registered then
        return
    end
    safe("trigger registration", function()
        registerTrigger(
            shared.TRIGGER_TOGGLE,
            "InputBindingDisplayName",
            "InputBindingDisplayDescription"
        )
        registerTrigger(
            shared.TRIGGER_REPOSITION,
            "InputBindingDisplayName",
            "InputBindingDisplayDescription"
        )
    end)
    safe("settings registration", registerSettings)
    safe("default binding registration", registerDefaults)
    registered = true
end

registerAll()

return {
    engineHandlers = {
        onFrame = registerAll,
    },
}
