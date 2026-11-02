local M = {}

local function loadModule(path)
	local fullPath = _G.rfsuite.paths.core .. "/" .. path
	local chunk = loadScript(fullPath, "t")
	if type(chunk) ~= "function" then return nil end
	local ok, mod = pcall(chunk)
	if not ok then return nil end
	return mod
end

local Controls = nil
local Common = nil
local PowerModelPreferences = nil
local EscCurrentLimit = nil
local t = nil

local MODEL_TYPE_MIN = 0
local MODEL_TYPE_MAX = 2
local LOCAL_SOURCE_MIN = 0
local LOCAL_SOURCE_MAX = 2
-- Amps. Zero is not a limit but the absence of one, and it is the default: a controller that
-- reports its own limit fills this in without being asked, and a model whose controller does not
-- simply has no ESC load reading until somebody types the figure in.
local ESC_CURRENT_LIMIT_MIN = 0
-- Well above the largest limit any of the three reporting families can express, so that a value
-- a controller reported is never clamped on its way onto this row.
local ESC_CURRENT_LIMIT_MAX = 700

local function newRuntime()
	return {
		modelTypeSet = nil,
		localSourceSet = nil,
		escCurrentLimitSet = nil,
		requestRebuild = nil,
		openHelp = nil,
		inlineHelpHandler = nil,
		lastSessionSignature = nil
	}
end

local ui = {
	loaded = false,
	dirty = false,
	config = {
		smartfuel_model_type = 0,
		smartfuel_source = 0,
		esc_current_limit = 0
	},
	-- The limit as the store had it when the page loaded, and where it came from. A save marks the
	-- figure as typed in by hand only where it differs from this one: every save writes the row
	-- back, and an unchanged figure must keep the family that reported it.
	loadedEscCurrentLimit = 0,
	escCurrentLimitOrigin = nil,
	runtime = newRuntime()
}

local function clampInt(value, minValue, maxValue, fallback)
	local n = tonumber(value)
	if n == nil then n = fallback end
	n = math.floor((n or fallback or minValue) + 0.5)
	if n < minValue then n = minValue end
	if n > maxValue then n = maxValue end
	return n
end

local function ensureRuntime()
	if type(ui.runtime) ~= "table" then
		ui.runtime = newRuntime()
	end
end

local function ensureDeps()
	if not Common then Common = loadModule("app/pages/settings/common.lua") end
	if not Controls then Controls = loadModule("ui/controls.lua") end
	if not PowerModelPreferences then PowerModelPreferences = loadModule("app/pages/setup/power/model_preferences.lua") end
	if not EscCurrentLimit then EscCurrentLimit = loadModule("app/pages/setup/esc_motors/esc_tools/esc_current_limit.lua") end
	if not t then t = Common and Common.pageT("setup_power_preferences") or nil end
end

local function pageText(i18n, key, fallback)
	if t then
		return t(i18n, key, fallback)
	end
	return fallback
end

-- The reason after a failed write of the model's file, in words (settings/common.lua). The page
-- also runs without common.lua when that does not load, and the store's own answer stands in then.
local function modelSaveReason(i18n, err)
	if Common and Common.saveFailureReason then return Common.saveFailureReason(i18n, err, true) end
	return tostring(err or "io")
end

local function getSession()
	local root = _G and _G.rfsuite
	return root and root.session or nil
end

local function getBatteryPrefs(session)
	if type(session) ~= "table" then return nil end
	if type(session.modelPreferences) ~= "table" then
		session.modelPreferences = {}
	end
	if type(session.modelPreferences.battery) ~= "table" then
		session.modelPreferences.battery = {}
	end
	return session.modelPreferences.battery
end

local function buildSessionSignature()
	local session = getSession()
	local batteryPrefs = getBatteryPrefs(session)
	if not batteryPrefs then return "nil" end
	return tostring(batteryPrefs.smartfuel_model_type or "") .. "|" .. tostring(batteryPrefs.smartfuel_source or batteryPrefs.calc_local or "")
		.. "|" .. tostring(batteryPrefs.smartfuel_publish == true)
		.. "|" .. tostring(batteryPrefs.esc_current_limit or "")
		.. "|" .. tostring(batteryPrefs.esc_current_limit_origin or "")
end

local function markDirty()
	ui.dirty = true
end

local function getInlineHelpHandler()
	if ui.runtime.inlineHelpHandler then return ui.runtime.inlineHelpHandler end
	ui.runtime.inlineHelpHandler = function(helpText, helpTitle)
		if type(helpText) ~= "string" or helpText == "" then return end
		local openHelp = ui.runtime.openHelp
		if type(openHelp) == "function" then
			openHelp(helpText, helpTitle)
		end
	end
	return ui.runtime.inlineHelpHandler
end

local function loadFromSession()
	local session = getSession()
	local batteryPrefs = getBatteryPrefs(session)

	ui.config.smartfuel_model_type = clampInt(batteryPrefs and batteryPrefs.smartfuel_model_type, MODEL_TYPE_MIN, MODEL_TYPE_MAX, 0)
	ui.config.smartfuel_source = clampInt((batteryPrefs and batteryPrefs.smartfuel_source) or (batteryPrefs and batteryPrefs.calc_local), LOCAL_SOURCE_MIN, LOCAL_SOURCE_MAX, 0)
	-- Absent means on: a store written before this setting existed describes a suite that
	-- published, and only an explicit `false` turns it off.
	ui.config.smartfuel_publish = (batteryPrefs and batteryPrefs.smartfuel_publish) ~= false
	ui.config.esc_current_limit = clampInt(batteryPrefs and batteryPrefs.esc_current_limit, ESC_CURRENT_LIMIT_MIN, ESC_CURRENT_LIMIT_MAX, 0)
	ui.loadedEscCurrentLimit = ui.config.esc_current_limit
	ui.escCurrentLimitOrigin = batteryPrefs and batteryPrefs.esc_current_limit_origin or nil
end

-- Where the figure on the row comes from, as the row shows it: nil where there is no limit, by
-- hand once the pilot has changed it here, and otherwise what the store says -- the family that
-- reported it, by hand, or nothing at all for a file written before the origin was kept, which is
-- shown as unknown rather than guessed.
local function escCurrentLimitOrigin()
	local limit = tonumber(ui.config.esc_current_limit) or 0
	if limit <= 0 then return nil end
	if limit ~= ui.loadedEscCurrentLimit then return "hand" end
	return ui.escCurrentLimitOrigin or "unknown"
end

-- The row's label for one origin. Resolved when an origin is first shown and then kept for the
-- build, so neither the build pays for the five it may never show nor a frame for a lookup.
local function escCurrentLimitLabel(i18n, base, origin)
	local text
	if origin == "hand" then text = pageText(i18n, "origin_hand", "by hand")
	elseif origin == "am32" then text = pageText(i18n, "origin_am32", "AM32")
	elseif origin == "scorpion" then text = pageText(i18n, "origin_scorpion", "Scorpion")
	elseif origin == "yge" then text = pageText(i18n, "origin_yge", "YGE")
	else text = pageText(i18n, "origin_unknown", "unknown") end
	return base .. " (" .. text .. ")"
end

local function ensureLoaded()
	ensureRuntime()
	if ui.loaded then return end
	loadFromSession()
	ui.runtime.lastSessionSignature = buildSessionSignature()
	ui.loaded = true
	ui.dirty = false
end

local function saveModelPreferences(session)
	if not PowerModelPreferences or type(PowerModelPreferences.save) ~= "function" then
		return false, "unavailable"
	end
	return PowerModelPreferences.save(session)
end

local function getModelTypeSetter()
	if ui.runtime.modelTypeSet then return ui.runtime.modelTypeSet end
	ui.runtime.modelTypeSet = function(value)
		local nextValue = clampInt(value, MODEL_TYPE_MIN, MODEL_TYPE_MAX, 0)
		if ui.config.smartfuel_model_type == nextValue then return end
		ui.config.smartfuel_model_type = nextValue
		markDirty()
	end
	return ui.runtime.modelTypeSet
end

local function getLocalSourceSetter()
	if ui.runtime.localSourceSet then return ui.runtime.localSourceSet end
	ui.runtime.localSourceSet = function(value)
		local nextValue = clampInt(value, LOCAL_SOURCE_MIN, LOCAL_SOURCE_MAX, 0)
		if ui.config.smartfuel_source == nextValue then return end
		ui.config.smartfuel_source = nextValue
		markDirty()
	end
	return ui.runtime.localSourceSet
end

local function getPublishSetter()
	if ui.runtime.publishSet then return ui.runtime.publishSet end
	ui.runtime.publishSet = function(value)
		local nextValue = value == true
		if ui.config.smartfuel_publish == nextValue then return end
		ui.config.smartfuel_publish = nextValue
		markDirty()
	end
	return ui.runtime.publishSet
end

local function getEscCurrentLimitSetter()
	if ui.runtime.escCurrentLimitSet then return ui.runtime.escCurrentLimitSet end
	ui.runtime.escCurrentLimitSet = function(value)
		local nextValue = clampInt(value, ESC_CURRENT_LIMIT_MIN, ESC_CURRENT_LIMIT_MAX, 0)
		if ui.config.esc_current_limit == nextValue then return end
		ui.config.esc_current_limit = nextValue
		markDirty()
	end
	return ui.runtime.escCurrentLimitSet
end

local function buildModelTypeOptions(i18n)
	return {
		{ value = 0, label = pageText(i18n, "value_auto", "AUTO") },
		{ value = 1, label = pageText(i18n, "value_electric", "ELECTRIC") },
		{ value = 2, label = pageText(i18n, "value_nitro", "NITRO") }
	}
end

local function buildLocalSourceOptions(i18n)
	return {
		{ value = 0, label = pageText(i18n, "value_current", "CURRENT") },
		{ value = 1, label = pageText(i18n, "value_voltage", "VOLTAGE") },
		{ value = 2, label = pageText(i18n, "value_combined", "COMBINED") }
	}
end

function M.getHeaderActions()
	ensureDeps()
	return {
		save = true,
		reload = true,
		help = true,
		menu = true
	}
end


function M.onReload()
	ensureDeps()
	ui.loaded = false
	ensureLoaded()
	return false
end

function M.onSave(ctx)
	ensureDeps()
	ensureLoaded()

	local session = getSession()
	local batteryPrefs = getBatteryPrefs(session)
	if not batteryPrefs then
		return false
	end

	batteryPrefs.smartfuel_model_type = clampInt(ui.config.smartfuel_model_type, MODEL_TYPE_MIN, MODEL_TYPE_MAX, 0)
	batteryPrefs.smartfuel_source = clampInt(ui.config.smartfuel_source, LOCAL_SOURCE_MIN, LOCAL_SOURCE_MAX, 0)
	batteryPrefs.calc_local = batteryPrefs.smartfuel_source
	batteryPrefs.smartfuel_publish = ui.config.smartfuel_publish == true
	-- The limit and its origin as they stood, put back if the write fails: the tool's audio pass
	-- reads this table on every tick, and a figure that never reached the card must not be the
	-- one it announces against (esc_current_limit.lua's remember() does the same).
	local originKey = (EscCurrentLimit and EscCurrentLimit.ORIGIN_KEY) or "esc_current_limit_origin"
	local previousLimit = batteryPrefs.esc_current_limit
	local previousOrigin = batteryPrefs[originKey]
	batteryPrefs.esc_current_limit = clampInt(ui.config.esc_current_limit, ESC_CURRENT_LIMIT_MIN, ESC_CURRENT_LIMIT_MAX, 0)
	-- Only a figure the pilot changed here becomes one set by hand, and no limit has no origin.
	if batteryPrefs.esc_current_limit <= 0 then
		batteryPrefs[originKey] = nil
	elseif batteryPrefs.esc_current_limit ~= ui.loadedEscCurrentLimit then
		batteryPrefs[originKey] = (EscCurrentLimit and EscCurrentLimit.ORIGIN_HAND) or "hand"
	end

	local okPrefs, errPrefs = saveModelPreferences(session)
	if not okPrefs then
		batteryPrefs.esc_current_limit = previousLimit
		batteryPrefs[originKey] = previousOrigin
		if ctx and type(ctx.reportSave) == "function" then
			ctx.reportSave({
				title = pageText(ctx.i18n, "save_error_title", "Error"),
				message = pageText(ctx.i18n, "save_error_message", "Save failed") .. ": " .. modelSaveReason(ctx.i18n, errPrefs)
			})
		end
		return false
	end

	if ctx and type(ctx.reportSave) == "function" then
		ctx.reportSave({
			ok = true,
			title = pageText(ctx and ctx.i18n, "saved_title", "Saved"),
			message = pageText(ctx and ctx.i18n, "saved_message", "Power preferences saved")
		})
	end

	ui.dirty = false
	ui.loadedEscCurrentLimit = batteryPrefs.esc_current_limit
	ui.escCurrentLimitOrigin = batteryPrefs[originKey]
	ui.runtime.lastSessionSignature = buildSessionSignature()
	return true
end

function M.wakeup(ctx)
	ensureDeps()
	ensureLoaded()
	if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
		ui.runtime.requestRebuild = ctx.requestRebuild
	end
	if ui.dirty then return end

	local signature = buildSessionSignature()
	if signature ~= ui.runtime.lastSessionSignature then
		loadFromSession()
		ui.runtime.lastSessionSignature = signature
		if type(ui.runtime.requestRebuild) == "function" then
			ui.runtime.requestRebuild()
		end
	end
end

function M.build(ctx)
	ensureDeps()
	ensureLoaded()
	ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
	ui.runtime.openHelp = ctx and ctx.openHelp or nil

	local children = ctx.children
	local x = ctx.x
	local y = ctx.y
	local w = ctx.w
	local i18n = ctx.i18n

	local cursorY = y
	Controls.appendStaticSectionHeader(children, x, cursorY, w, pageText(i18n, "section_preferences", "Preferences"))
	cursorY = cursorY + Controls.STATIC_SECTION_H

	cursorY = cursorY + Controls.appendComboSelect(
		children, x, cursorY, w,
		pageText(i18n, "model_type", "Model Type"),
		buildModelTypeOptions(i18n),
		ui.config.smartfuel_model_type,
		getModelTypeSetter(),
		{
			helpText = pageText(i18n, "help_model_type"),
			helpTitle = pageText(i18n, "model_type", "Model Type"),
			onHelp = getInlineHelpHandler()
		}
	)

	cursorY = cursorY + Controls.appendComboSelect(
		children, x, cursorY, w,
		pageText(i18n, "calcfuel_local", "Local SmartFuel Source"),
		buildLocalSourceOptions(i18n),
		ui.config.smartfuel_source,
		getLocalSourceSetter(),
		{
			helpText = pageText(i18n, "help_calcfuel_local"),
			helpTitle = pageText(i18n, "calcfuel_local", "Local SmartFuel Source"),
			onHelp = getInlineHelpHandler()
		}
	)

	cursorY = cursorY + Controls.appendRadioSwitch(
		children, x, cursorY, w,
		pageText(i18n, "publish_sensors", "Publish SmFt / SmCp"),
		ui.config.smartfuel_publish,
		getPublishSetter(),
		{
			helpText = pageText(i18n, "help_publish_sensors"),
			helpTitle = pageText(i18n, "publish_sensors", "Publish SmFt / SmCp"),
			onHelp = getInlineHelpHandler()
		}
	)

	local notSetLabel = pageText(i18n, "value_not_set", "NOT SET")
	local limitLabel = pageText(i18n, "esc_current_limit", "ESC Current Limit")
	local limitLabels = {}
	-- The origin beside the figure, in the row's label: read on every frame, so it turns to "by
	-- hand" as soon as the figure is changed here, before the save that makes it so.
	Controls.appendNumberField(
		children, x, cursorY, w,
		function()
			local origin = escCurrentLimitOrigin()
			if origin == nil then return limitLabel end
			local text = limitLabels[origin]
			if text == nil then
				text = escCurrentLimitLabel(i18n, limitLabel, origin)
				limitLabels[origin] = text
			end
			return text
		end,
		{
			min = ESC_CURRENT_LIMIT_MIN,
			max = ESC_CURRENT_LIMIT_MAX,
			step = 1,
			-- Zero is the absence of a limit rather than a limit of nothing, and it reads as
			-- that rather than as "0A".
			display = function(val)
				local amps = tonumber(val) or 0
				if amps <= 0 then return notSetLabel end
				return string.format("%dA", math.floor(amps))
			end,
			get = function() return ui.config.esc_current_limit end,
			set = getEscCurrentLimitSetter(),
			helpText = pageText(i18n, "help_esc_current_limit"),
			helpTitle = pageText(i18n, "esc_current_limit", "ESC Current Limit"),
			onHelp = getInlineHelpHandler()
		}
	)
end

function M.onClose()
	if Common and Common.resetPageState then
		Common.resetPageState(ui)
	else
		ui.loaded = false
		ui.dirty = false
	end
	Controls = nil
	Common = nil
	PowerModelPreferences = nil
	EscCurrentLimit = nil
	t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
	return ui.dirty == true
end

return M
