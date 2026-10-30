local M = {}

local function loadModule(path)
	local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
	local chunk = loadScript(fullPath, "t")
	if type(chunk) ~= "function" then return nil end
	local ok, mod = pcall(chunk)
	if not ok then return nil end
	return mod
end

local Palette = _G.rfsuite and _G.rfsuite.palette or (_G.rfsuite and _G.rfsuite.require or loadModule)("ui/palette.lua")

local Controls = nil
local Common = nil
local MspRuntime = nil
local GovernorApi = nil
local SavePipeline = nil
local GovernorFields = nil
local GovernorConfigApi = nil
local LoadingOverlay = nil
local Sensors = nil
local Profile = nil
local t = nil

local GROUPS = {
	{
		key = "basic_setup",
		rows = {
			{ labelKey = "full_headspeed", field = "governor_headspeed", reqMode = 3 },
			{ labelKey = "min_throttle", field = "governor_min_throttle", reqMode = 1 },
			{ labelKey = "max_throttle", field = "governor_max_throttle", reqMode = 1 },
			{ labelKey = "gain", field = "governor_gain", reqMode = 3 }
		}
	},
	{
		key = "gains",
		horizontal = true,
		rows = {
			{ labelKey = "p", field = "governor_p_gain", reqMode = 3 },
			{ labelKey = "i", field = "governor_i_gain", reqMode = 3 },
			{ labelKey = "d", field = "governor_d_gain", reqMode = 3 },
			{ labelKey = "f", field = "governor_f_gain", reqMode = 3, flagKey = "tx_precomp_curve", flagInverse = true }
		}
	},
	{
		key = "precomp",
		horizontal = true,
		rows = {
			{ labelKey = "yaw", field = "governor_yaw_weight", reqMode = 3, altField = "governor_yaw_ff_weight", flagKey = "tx_precomp_curve", flagInverse = true },
			{ labelKey = "cyc", field = "governor_cyclic_weight", reqMode = 3, altField = "governor_cyclic_ff_weight", flagKey = "tx_precomp_curve", flagInverse = true },
			{ labelKey = "col", field = "governor_collective_weight", reqMode = 3, altField = "governor_collective_ff_weight", flagKey = "tx_precomp_curve", flagInverse = true }
		}
	},
	{
		key = "tail_torque_assist",
		horizontal = true,
		rows = {
			{ labelKey = "gain", field = "governor_tta_gain", reqMode = 3 },
			{ labelKey = "limit", field = "governor_tta_limit", reqMode = 3, suffix = "%" }
		}
	}
}

local GOV_MODES = {
	[0] = "OFF",
	[1] = "LIMIT",
	[2] = "DIRECT",
	[3] = "ELECTRO",
	[4] = "NITRO"
}

local function newRuntime()
	return {
		readPending = false,
		requestRebuild = nil,
		fieldSetters = {},
		lastSessionSignature = nil
	}
end

local ui = {
	loaded = false,
	dirty = false,
	config = {},
	runtime = newRuntime(),
	loading = false,
	progress = 0,
	baseTitle = nil
}

local function getFieldLimit(key)
	if key == "governor_headspeed" then
		return GovernorFields.headspeed
	end
	-- The firmware's range for both limits (cli/settings.c gov_min_throttle / gov_max_throttle)
	if key == "governor_min_throttle" or key == "governor_max_throttle" then
		return { min = 10, max = 100, step = 1 }
	end
	return { min = 0, max = 255, step = 1 }
end

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

local function getSession()
	local root = _G and _G.rfsuite
	return root and root.session or nil
end

local function ensureDeps()
	if not Common then Common = loadModule("app/pages/settings/common.lua") end
	if not Controls then Controls = loadModule("ui/controls.lua") end
	if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
	if not GovernorApi then GovernorApi = loadModule("tasks/msp/api/governor_profile.lua") end
	if not GovernorConfigApi then GovernorConfigApi = loadModule("tasks/msp/api/governor_config.lua") end
	if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
	if not Sensors then Sensors = loadModule("lib/sensors.lua") end
	if not Profile then Profile = loadModule("lib/profile.lua") end
	if not GovernorFields then GovernorFields = loadModule("lib/governor_fields.lua") end
	if not t then t = Common and Common.pageT("flight_tuning_governor") or nil end
	if Common and not ui.runtimeBase then
		ui.runtimeBase = Common.createProfileAwareRuntime({ profileType = "pid" })
		if type(ui.runtime) ~= "table" then
			ui.runtime = newRuntime()
		end
		setmetatable(ui.runtime, { __index = ui.runtimeBase })
	end
end

local function pageText(i18n, key, fallback)
	if t then
		local translated = t(i18n, key)
		if translated ~= nil and translated ~= "" and translated ~= key then
			return translated
		end
	end
	return fallback or key
end

local function getGovConfig(session)
	if type(session) ~= "table" then return nil end
	session.governor_profile = session.governor_profile or {}
	return session.governor_profile
end

local function markDirty()
	ui.dirty = true
end

local function getFieldSetter(fieldName, altFieldName)
	local setter = ui.runtime.fieldSetters[fieldName]
	if setter then return setter end
	local limits = getFieldLimit(fieldName)
	setter = function(value)
		local nextValue = clampInt(value, limits.min, limits.max, 0)
		-- Check step size rounding
		if limits.step and limits.step > 1 then
			nextValue = math.floor((nextValue + (limits.step / 2)) / limits.step) * limits.step
		end
		if ui.config[fieldName] == nextValue then return end
		ui.config[fieldName] = nextValue
		if altFieldName then ui.config[altFieldName] = nextValue end
		markDirty()
	end
	ui.runtime.fieldSetters[fieldName] = setter
	return setter
end

local function getLiveProfile()
	return Profile and Profile.getActivePidProfile(1) or 1
end

local function buildSessionSignature()
	local session = getSession()
	return tostring(getLiveProfile()) .. "_" .. tostring(session and session.governorMode or 0)
end

local function decodeGovernorFlags(flags)
	local governor_flags_bitmap = {
		"fc_throttle_curve",
		"tx_precomp_curve",
		"fallback_precomp",
		"voltage_comp",
		"pid_spoolup",
		"hs_adjustment",
		"dyn_min_throttle",
		"autorotation",
		"suspend",
		"bypass"
	}
	local decoded = {}
	flags = tonumber(flags) or 0
	for i, name in ipairs(governor_flags_bitmap) do
		local mask = 2 ^ (i - 1)
		decoded[name] = (flags & mask) ~= 0
	end
	return decoded
end

local function loadFromSession()
	local session = getSession()
	local govConfig = getGovConfig(session)
	if not govConfig then return end
	ui.flags = decodeGovernorFlags(govConfig.governor_flags or 0)
	for i = 1, #GROUPS do
		local rows = GROUPS[i].rows
		for j = 1, #rows do
			local field = rows[j].field
			local alt = rows[j].altField
			local val = govConfig[field]
			if val == nil and alt then val = govConfig[alt] end
			local limits = getFieldLimit(field)
			ui.config[field] = clampInt(val, limits.min, limits.max, 0)
			if alt then ui.config[alt] = ui.config[field] end
		end
	end
end

local function getBaseTitle()
	local root = _G and _G.rfsuite
	local app = root and root.app or nil
	local title = nil
	if app and type(app.lastTitle) == "string" and app.lastTitle ~= "" then
		title = app.lastTitle
	elseif app and app.Page and type(app.Page.title) == "string" and app.Page.title ~= "" then
		title = app.Page.title
	else
		title = "Governor"
	end
	return title
end

local function queueGovRead(isAutoReload)
	ensureRuntime()
	if ui.runtime.readPending then
		return false, "read_pending"
	end
	ui.runtime.readComplete = false
	if not GovernorApi or not GovernorConfigApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
		return false, "msp_runtime_unavailable"
	end

	local session = getSession()
	local mspState = MspRuntime.getState()
	local queue = mspState and mspState.queue
	if not queue or type(queue.add) ~= "function" then
		return false, "msp_queue_unavailable"
	end

	local readValid = type(getSession()) == "table"
	-- The profile this read is for; M.canSave holds the values on screen to it.
	local readProfile = getLiveProfile()
	ui.runtime.readPending = true
	if not isAutoReload then
		ui.loading = true
		ui.progress = 0
		if type(ui.runtime.requestRebuild) == "function" then
			ui.runtime.requestRebuild()
		end
	end

	queue:add({
		command = GovernorConfigApi.command,
		simulatorResponse = GovernorConfigApi.simulatorResponse,
		timeout = 5.0,
		processReply = function(_, buf)
			local parsedConfig = GovernorConfigApi.parse and GovernorConfigApi.parse(buf) or nil
			if type(parsedConfig) ~= "table" then return Common.failPageRead(ui) end
			if type(session) == "table" and type(parsedConfig) == "table" then
				session.governor_config = parsedConfig
				session.governorMode = parsedConfig.gov_mode
			end

			queue:add({
				command = GovernorApi.command,
				simulatorResponse = GovernorApi.simulatorResponse,
				timeout = 5.0,
				processReply = function(_, buf)
					ui.runtime.readPending = false
					ui.loading = false
					ui.progress = 1
					local parsed = GovernorApi.parse and GovernorApi.parse(buf) or nil
					if type(parsed) ~= "table" then return Common.failPageRead(ui) end
					if type(session) == "table" and type(parsed) == "table" then
						session.governor_profile = parsed
					end
					if not ui.dirty then
						loadFromSession()
						ui.runtime.readProfile = readProfile
					end
					ui.runtime.readComplete = readValid
					if type(ui.runtime.requestRebuild) == "function" then
						ui.runtime.requestRebuild()
					end
				end,
				errorHandler = function()
					readValid = false
					ui.runtime.readPending = false
					ui.loading = false
					ui.progress = 1
					if type(ui.runtime.requestRebuild) == "function" then
						ui.runtime.requestRebuild()
					end
				end
			})
		end,
		errorHandler = function()
			readValid = false
			ui.runtime.readPending = false
			ui.loading = false
			ui.progress = 1
			if type(ui.runtime.requestRebuild) == "function" then
				ui.runtime.requestRebuild()
			end
		end
	})

	return true, nil
end

local function ensureLoaded()
	ensureRuntime()
	if ui.loaded then return end
	loadFromSession()
	ui.loaded = true
	ui.dirty = false
	ui.baseTitle = getBaseTitle()
	-- Taken over only with a read sent under it: a Reload while a read is out keeps the old one.
	local signature = buildSessionSignature()
	if queueGovRead(false) then ui.runtime.lastSessionSignature = signature end
end

local function queueGovWrite(session)
	if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
	if not SavePipeline or not GovernorApi then
		return false, "msp_runtime_unavailable"
	end

	local govConfig = getGovConfig(session)
	if not govConfig then
		return false, "config_unavailable"
	end

	local payload = GovernorApi.buildWritePayload(govConfig)
	if not payload then
		return false, "invalid_payload"
	end

	return SavePipeline.start({
		pageId = "flight_tuning_governor",
		steps = {
			{
				label = "MSP_SET_GOVERNOR_PROFILE",
				command = GovernorApi.writeCommand,
				payload = payload
			}
		},
		reboot = false,
		onSaved = function()
			if not ui.runtime then return end
			ui.dirty = false
			ui.runtime.lastSessionSignature = buildSessionSignature()
		end,
		onDone = function(result)
			if not ui.runtime then return end
			if result.saved then queueGovRead(true) end
			if type(ui.runtime.requestRebuild) == "function" then
				ui.runtime.requestRebuild()
			end
		end
	})
end

local function applyConfigToSession(session)
	local govConfig = getGovConfig(session)
	if not govConfig then return nil end
	for i = 1, #GROUPS do
		local rows = GROUPS[i].rows
		for j = 1, #rows do
			local field = rows[j].field
			local alt = rows[j].altField
			local limits = getFieldLimit(field)
			govConfig[field] = clampInt(ui.config[field], limits.min, limits.max, 0)
			if alt then govConfig[alt] = govConfig[field] end
		end
	end
	session.governor_profile = govConfig
	return govConfig
end

local function appendCompactNumberField(children, x, y, w, labelText, opts)
	local rowH = (Controls and Controls.ROW_H) or 40
	local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
	local itemY = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))
	local fieldW = 172
	local fieldX = x + w - fieldW - 10
	
	local getter = opts.get
	local setter = opts.set
	local minVal = opts.min or 0
	local maxVal = opts.max or 255
	local stepVal = opts.step or 1
	local isActive = opts.enabled ~= false
	local displayFn = opts.display

	children[#children + 1] = {
		type = "label",
		x = x,
		y = labelY,
		w = fieldX - x - 8,
		text = labelText,
		color = Palette.text,
		font = SMLSIZE
	}

	children[#children + 1] = {
		type = "numberEdit",
		x = fieldX,
		y = itemY,
		w = fieldW,
		min = math.floor(minVal / stepVal),
		max = math.floor(maxVal / stepVal),
		active = function() return isActive end,
		get = function()
			local current = tonumber(getter()) or minVal
			return math.floor(current / stepVal)
		end,
		set = function(val)
			setter(val * stepVal)
		end,
		display = function(val)
			local shown = val * stepVal
			if type(displayFn) == "function" then
				return displayFn(shown)
			end
			return tostring(shown)
		end
	}

	-- Divider
	children[#children + 1] = {
		type = "rectangle",
		x = x,
		y = y + rowH,
		w = w,
		h = 1,
		color = Palette.border,
		filled = true
	}

	return rowH + 1
end

local function getGovGroupTitle(i18n, key)
	if key == "basic_setup" then return pageText(i18n, "basic_setup") end
	if key == "gains" then return pageText(i18n, "gains") end
	if key == "precomp" then return pageText(i18n, "precomp") end
	if key == "tail_torque_assist" then return pageText(i18n, "tail_torque_assist") end
	return key
end

local function getGovRowTitle(i18n, key)
	if key == "full_headspeed" then return pageText(i18n, "full_headspeed") end
	if key == "min_throttle" then return pageText(i18n, "min_throttle") end
	if key == "max_throttle" then return pageText(i18n, "max_throttle") end
	if key == "gain" then return pageText(i18n, "gain") end
	if key == "p" then return pageText(i18n, "p") end
	if key == "i" then return pageText(i18n, "i") end
	if key == "d" then return pageText(i18n, "d") end
	if key == "f" then return pageText(i18n, "f") end
	if key == "yaw" then return pageText(i18n, "yaw") end
	if key == "cyc" then return pageText(i18n, "cyc") end
	if key == "col" then return pageText(i18n, "col") end
	if key == "tta_gain" then return pageText(i18n, "tta_gain") end
	if key == "tta_limit" then return pageText(i18n, "tta_limit") end
	if key == "limit" then return pageText(i18n, "limit") end
	return key
end

local function appendHorizontalFields(children, x, y, w, labelText, rows, i18n)
	local metrics = Controls.computeGridMetrics(w, #rows, { labelMin = 100, labelRatio = 0.25 })
	local labelW = metrics.labelW
	local gap = metrics.gap
	local cellW = metrics.cellW
	
	local rowH = (Controls and Controls.HORIZONTAL_ROW_H) or 56
	local headerY = y + 2
	local itemY = y + (rowH >= 65 and 24 or 20)
	local groupLabelY = Controls.labelY(itemY, Controls.CTRL_H)

	children[#children + 1] = {
		type = "label",
		x = x,
		y = groupLabelY,
		w = labelW,
		text = labelText,
		color = Palette.text,
		font = SMLSIZE
	}

	for i = 1, #rows do
		local row = rows[i]
		local cellX = x + labelW + ((i - 1) * (cellW + gap))
		local limits = getFieldLimit(row.field)
		local isActive = true
		if row.flagKey and ui.flags then
			local val = ui.flags[row.flagKey]
			if row.flagInverse then val = not val end
			isActive = val
		end

		-- Sub-label centered above box (P, I, D, F etc)
		children[#children + 1] = {
			type = "label",
			x = cellX,
			y = headerY,
			w = cellW,
			text = string.upper(getGovRowTitle(i18n, row.labelKey)),
			color = Palette.text,
			font = SMLSIZE,
			align = CENTER
		}

		children[#children + 1] = {
			type = "numberEdit",
			x = cellX,
			y = itemY,
			w = cellW,
			min = math.floor(limits.min / (limits.step or 1)),
			max = math.floor(limits.max / (limits.step or 1)),
			active = function() return isActive end,
			get = function()
				local val = ui.config[row.field] or limits.min
				return math.floor(val / (limits.step or 1))
			end,
			set = function(val)
				getFieldSetter(row.field, row.altField)(val * (limits.step or 1))
			end,
			display = function(val)
				local shown = val * (limits.step or 1)
				return tostring(shown) .. (row.suffix or "")
			end
		}
	end

	-- Divider
	children[#children + 1] = {
		type = "rectangle",
		x = x,
		y = y + rowH,
		w = w,
		h = 1,
		color = Palette.border,
		filled = true
	}

	return rowH + 1
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
	if SavePipeline and SavePipeline.isActive() then return end
	ensureDeps()
	ui.loaded = false
	ensureLoaded()
	return false
end

-- MSP_SET_GOVERNOR_PROFILE carries no profile index: the board stores the record in whichever PID
-- profile is active when it arrives. A profile switch after the read therefore refuses Save until the
-- page has read the active profile; the second value is the reason the host shows.
function M.canSave()
	if ui.runtime == nil or ui.runtime.readComplete ~= true or ui.runtime.readPending then return false end
	if ui.runtime.readProfile == nil then return false end
	if getLiveProfile() ~= ui.runtime.readProfile then return false, "profile_changed" end
	return true
end

function M.onSave(ctx)
	if not M.canSave() then return false, "loaded_data_missing" end
	if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
	if SavePipeline and SavePipeline.isActive() then return false end
	ensureDeps()
	ensureLoaded()

	local session = getSession()
	if not session then
		return false
	end

	applyConfigToSession(session)
	local ok, err = queueGovWrite(session)
	if not ok then
		if ctx and type(ctx.reportSave) == "function" then
			ctx.reportSave({
				title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
				message = tostring(err or "MSP write failed")
			})
		end
		return false
	end
	return true
end

function M.onHelp(ctx)
	local help = loadModule("app/pages/flight_tuning/governor/help.lua")
	if type(help) == "function" then
		return help(ctx)
	end
	return { title = "Help", message = "No help available" }
end

function M.wakeup(ctx)
	ensureDeps()
	ensureLoaded()
	if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
		ui.runtime.requestRebuild = ctx.requestRebuild
	end
	if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
		ui.runtime.syncHeaderTitle(ui.baseTitle or getBaseTitle(), ctx and ctx.navButtons or nil)
	end
	-- A switch is not read over a pending edit; M.canSave refuses until Reload reads the new profile.
	if ui.dirty then return end

	local signature = buildSessionSignature()
	-- Taken over only with a read sent under it: a read already out belongs to the old profile.
	if signature ~= ui.runtime.lastSessionSignature and queueGovRead(true) then
		ui.runtime.lastSessionSignature = signature
	end
end

function M.handleEvent(eventData)
	return eventData
end

function M.build(ctx)
	ensureDeps()
	ensureLoaded()
	ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

	local children = ctx.children
	local x = ctx.x
	local y = ctx.y
	local w = ctx.w
	local h = ctx.h or 200
	local i18n = ctx.i18n
	-- The profile the values on screen were read from; a pending edit keeps it after a switch.
	local profileDisplay = ui.runtime.readProfile or getLiveProfile()

	if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
		ui.runtime.syncHeaderTitle(ui.baseTitle or getBaseTitle(), ctx and ctx.navButtons or nil)
	end

	local session = getSession()
	local govMode = tonumber(session and session.governorMode or 0) or 0
	local govModeName = GOV_MODES[govMode] or "OFF"

	local sectionHeaderH = (Controls and Controls.STATIC_SECTION_H) or 38
	local cursorY = y
	if Controls and type(Controls.appendStaticSectionHeader) == "function" then
		local headingTitle = string.format("%s #%d - %s", pageText(i18n, "title"), profileDisplay, govModeName)
		Controls.appendStaticSectionHeader(children, x, cursorY, w, headingTitle)
		cursorY = cursorY + sectionHeaderH
	end
	
	if govMode == 0 then
		children[#children + 1] = {
			type = "label",
			x = x,
			y = cursorY + 20,
			w = w,
			text = pageText(i18n, "disabled_message"),
			color = Palette.warning,
			align = CENTER
		}
		if ctx.navButtons and ctx.navButtons.save then ctx.navButtons.save.enabled = false end
		if ctx.navButtons and ctx.navButtons.reload then ctx.navButtons.reload.enabled = false end
	else
		for i = 1, #GROUPS do
			local group = GROUPS[i]
			
			local groupHasVisibleFields = false
			for j = 1, #group.rows do
				if govMode >= group.rows[j].reqMode then
					groupHasVisibleFields = true
					break
				end
			end

			if groupHasVisibleFields then
				if group.key ~= "basic_setup" and not group.horizontal then
					children[#children + 1] = {
						type = "label",
						x = x,
						y = cursorY + 6,
						w = w,
						text = getGovGroupTitle(i18n, group.key),
						color = Palette.headingText,
						font = SMLSIZE
					}
					cursorY = cursorY + 28
				end

				if group.horizontal then
					cursorY = cursorY + appendHorizontalFields(children, x, cursorY, w, getGovGroupTitle(i18n, group.key), group.rows, i18n)
				else
					for j = 1, #group.rows do
						local row = group.rows[j]
						local isModeActive = govMode >= row.reqMode
						local isFlagActive = true
						if row.flagKey and ui.flags then
							local val = ui.flags[row.flagKey]
							if row.flagInverse then val = not val end
							isFlagActive = val
						end

						if isModeActive then
							local isActive = isFlagActive
							local limits = getFieldLimit(row.field)
							
							cursorY = cursorY + appendCompactNumberField(
								children,
								x,
								cursorY,
								w,
								getGovRowTitle(i18n, row.labelKey),
								{
									get = function() return ui.config[row.field] or limits.min end,
									set = getFieldSetter(row.field, row.altField),
									min = limits.min,
									max = limits.max,
									step = limits.step,
									enabled = isActive
								}
							)
						end
					end
				end
				cursorY = cursorY + 4
			end
		end
	end

	if ui.loading and LoadingOverlay then
		LoadingOverlay.append(children, {
			x = ctx.x,
			y = ctx.y,
			w = ctx.w,
			h = ctx.h,
			title = pageText(i18n, "loading_title"),
			message = pageText(i18n, "loading_message"),
			progress = ui.progress
		})
	end
end

function M.onClose()
	if Common and Common.resetPageState then
		Common.resetPageState(ui, {
			tablesToWipe = { "runtime" }
		})
	else
		ui.loaded = false
		ui.dirty = false
	end
	ui.loading = false
	ui.progress = 0
	ui.runtimeBase = nil
	ui.baseTitle = nil
	Controls = nil
	Common = nil
	MspRuntime = nil
	GovernorApi = nil
	SavePipeline = nil
	GovernorFields = nil
	LoadingOverlay = nil
	Sensors = nil
	t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
	return ui.dirty == true
end

return M
