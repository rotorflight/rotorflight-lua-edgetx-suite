local function loadModule(path)
    local chunk = assert(loadScript(_G.rfsuite.paths.core .. "/" .. path, "t"))
    return chunk()
end

local Controls = loadModule("ui/controls.lua")
local DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")
local FieldsForm = loadModule("app/pages/settings/dashboard/fields_form.lua")

-- The settings page loads this file for the theme it is configuring and hands that theme
-- to the factory below, so a copy of this theme under rfsuite.user/dashboard stores its
-- values under its own key prefix instead of this one's. The literal is the fallback for
-- a caller that passes no theme.
local THEME_PATH = "system/@rt-rc"
local THEME_DEFAULTS = {
    v_min = 18.0,
    v_max = 25.2,
}

-- The pages init.lua declares beside Look: what the tiles of each phase show, and the keys.
local PHASES = { preflight = "preflight.lua", inflight = "inflight.lua", postflight = "postflight.lua" }

local ui = {
    loaded = false,
    -- The page the settings page opened, nil for the whole form of a host without pages.
    page = nil,
    form = nil,
    config = {
        v_min_tenths = 180,
        v_max_tenths = 252,
    }
}

local function clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function loadConfig(prefs)
    if ui.loaded then return end

    local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
    -- The per-model store is only addressable once the flight controller's id is known, so
    -- the read is conditioned on it exactly as the save is.
    local modelPrefs = session and session.mcu_id and session.modelPreferences or nil

    local cfg = DashboardLib.getThemeConfig(prefs, THEME_PATH, THEME_DEFAULTS, modelPrefs)
    -- A page of the shared form reads again with its own defaults added, so a model's save of it
    -- can tell a choice that repeats the standard from one that deviates.
    if ui.form and ui.form.owns(ui.page) then
        local defaults = {}
        for k, v in pairs(THEME_DEFAULTS) do defaults[k] = v end
        ui.form.defaults(ui.page, cfg, defaults)
        cfg = DashboardLib.getThemeConfig(prefs, THEME_PATH, defaults, modelPrefs)
        ui.form.load(ui.page, cfg)
    end
    ui.cfg = cfg
    local vMin = tonumber(cfg.v_min) or THEME_DEFAULTS.v_min
    local vMax = tonumber(cfg.v_max) or THEME_DEFAULTS.v_max

    vMin = clamp(vMin, 5.0, 64.9)
    vMax = clamp(vMax, vMin + 0.1, 65.0)

    ui.config.v_min_tenths = math.floor((vMin * 10) + 0.5)
    ui.config.v_max_tenths = math.floor((vMax * 10) + 0.5)
    ui.voltageEdited = false
    ui.loaded = true
end

local function saveConfig(prefs)
    local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
    -- Where the values land is the settings page's scope, not this module's: the library
    -- writes the radio's standard values, or this model's own ones, which need the flight
    -- controller's id -- without it the model scope saves nothing.
    local modelPrefs = session and session.mcu_id and session.modelPreferences or nil

    -- A page saves what it shows and nothing else: the shared form's page its own values, Look
    -- (or the whole form, on a host without pages) the theme's.
    if ui.form and ui.form.owns(ui.page) then
        DashboardLib.setThemeConfig(prefs, THEME_PATH, ui.form.save(), modelPrefs)
    else
        DashboardLib.setThemeConfig(prefs, THEME_PATH, {
            v_min = (tonumber(ui.config.v_min_tenths) or 180) / 10,
            v_max = (tonumber(ui.config.v_max_tenths) or 252) / 10,
        }, modelPrefs, { voltageEdited = ui.voltageEdited == true })
    end

    -- The model's file is written whenever a flight controller is connected, but it carries
    -- this save's values only in the model scope: there its answer is what the save reports.
    -- In the standard scope the values went into the radio's preferences, which the page's own
    -- save writes, so a failure to rewrite the model's file is not a failure of this save.
    local modelScope = type(DashboardLib.getEditScope) == "function" and DashboardLib.getEditScope() == "model"
    if session and session.mcu_id and modelPrefs then
        local loadMod = loadScript(_G.rfsuite.paths.core .. "/lib/model_preferences.lua", "t")
        if type(loadMod) == "function" then
            local ok, MP = pcall(loadMod)
            if ok and type(MP) == "table" and type(MP.saveByMcuId) == "function" then
                local saved, err = MP.saveByMcuId(session.mcu_id, modelPrefs)
                if modelScope then return saved, err end
                return true
            end
        end
        -- saveByMcuId's own word for a store that will not load; onSave turns it into a sentence.
        if modelScope then return false, "unavailable" end
    end
    return true
end

local function getMin()
    local current = tonumber(ui.config.v_min_tenths) or 180
    local maxAllowed = (tonumber(ui.config.v_max_tenths) or 252) - 1
    return clamp(current, 50, maxAllowed)
end

local function setMin(value)
    local maxAllowed = (tonumber(ui.config.v_max_tenths) or 252) - 1
    local nextValue = clamp(tonumber(value) or 180, 50, maxAllowed)
    if ui.config.v_min_tenths ~= nextValue then
        ui.config.v_min_tenths = nextValue
        ui.voltageEdited = true
    end
end

local function getMax()
    local current = tonumber(ui.config.v_max_tenths) or 252
    local minAllowed = (tonumber(ui.config.v_min_tenths) or 180) + 1
    return clamp(current, minAllowed, 650)
end

local function setMax(value)
    local minAllowed = (tonumber(ui.config.v_min_tenths) or 180) + 1
    local nextValue = clamp(tonumber(value) or 252, minAllowed, 650)
    if ui.config.v_max_tenths ~= nextValue then
        ui.config.v_max_tenths = nextValue
        ui.voltageEdited = true
    end
end

local M = {}

function M.getHeaderActions()
    return { save = true, help = false }
end


function M.onReload(ctx)
    ui.loaded = false
    loadConfig(ctx.preferences)
    return true
end

function M.onSave(ctx)
    local modelOk, modelErr = saveConfig(ctx.preferences)
    local ok, err = ctx.savePreferences()
    -- Saved only when every store that carries this save's values was written. A store answers a
    -- refused write with a token or with the card's own error text, which names the file's path;
    -- the pilot reads the sentence the library maps either to.
    if not ok then
        err = DashboardLib.saveFailureReason(ctx.i18n, err)
    elseif not modelOk then
        ok, err = false, DashboardLib.saveFailureReason(ctx.i18n, modelErr, true)
    end
    if ok then
        ui.voltageEdited = false
        ui.dirty = false
        if ctx and type(ctx.reportSave) == "function" then
            local i18n = ctx.i18n
            local title = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.saved_title") or "Saved"
            local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.saved_message") or "Theme settings saved"
            ctx.reportSave({ ok = true, title = title, message = message })
        end
    else
        if ctx and type(ctx.reportSave) == "function" then
            local i18n = ctx.i18n
            local title = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.save_error_title") or "Error"
            local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.save_error_message") or "Save failed"
            ctx.reportSave({ title = title, message = message .. ": " .. err })
        end
    end
    return true
end

function M.build(ctx)
    ui.page = ctx and ctx.page and ctx.page.id or nil
    loadConfig(ctx.preferences)
    if ui.form and ui.form.owns(ui.page) then
        local dashboard = type(ctx.preferences) == "table" and ctx.preferences.dashboard or nil
        ui.form.build(ui.page, ctx.children, ctx.x, ctx.y, ctx.w, ui.cfg, dashboard)
        return
    end

    local children = ctx.children
    local x, y, w = ctx.x, ctx.y, ctx.w
    local i18n = ctx.i18n
    local cursorY = y

    local sectionTitle = "@RT-RC Theme Voltage"
    if i18n and i18n.t then
        local translated = i18n.t("app.pages.settings_dashboard_settings.section_default_voltage")
        if translated and translated ~= "app.pages.settings_dashboard_settings.section_default_voltage" and translated ~= "" then
            sectionTitle = translated
        end
    end

    Controls.appendSectionHeader(children, x, cursorY, w, sectionTitle, true, function() end)
    cursorY = cursorY + Controls.SECTION_H

    local minLabel = "Min"
    local maxLabel = "Max"
    if i18n and i18n.t then
        local minTranslated = i18n.t("app.pages.settings_dashboard_settings.min")
        local maxTranslated = i18n.t("app.pages.settings_dashboard_settings.max")
        if minTranslated and minTranslated ~= "app.pages.settings_dashboard_settings.min" and minTranslated ~= "" then
            minLabel = minTranslated
        end
        if maxTranslated and maxTranslated ~= "app.pages.settings_dashboard_settings.max" and maxTranslated ~= "" then
            maxLabel = maxTranslated
        end
    end

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, minLabel, {
        min = 50,
        max = 649,
        get = getMin,
        set = setMin,
        display = function(value)
            return string.format("%.1fV", (tonumber(value) or 180) / 10)
        end
    })

    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, maxLabel, {
        min = 51,
        max = 650,
        get = getMax,
        set = setMax,
        display = function(value)
            return string.format("%.1fV", (tonumber(value) or 252) / 10)
        end
    })
end

return function(ctx)
    local theme = ctx and ctx.theme
    if type(theme) == "table" and type(theme.path) == "string" and theme.path ~= "" then
        THEME_PATH = theme.path
    end
    -- The phase modules are read from where this file was loaded, so a copy of the theme on the
    -- card lists its own tiles.
    local folder = type(theme) == "table" and type(theme.configurePath) == "string"
        and string.match(theme.configurePath, "^(.*/)[^/]*$") or nil
    if folder then ui.form = FieldsForm.new(folder, PHASES) end
    ui.page = ctx and ctx.page and ctx.page.id or nil
    return M
end
