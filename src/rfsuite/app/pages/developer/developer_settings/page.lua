local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Controls = nil
local Common = nil
local Log = nil

local CONFIG_SCHEMA = {
  { key = "debug_level", type = "string", default = "off" },
  { key = "show_header_memory", type = "bool", default = false },
  { key = "enable_serial_debug", type = "bool", default = false },
  { key = "log_to_card", type = "bool", default = false },
  { key = "log_runs", type = "number", default = 10 }
}

-- How many power-ups of the radio keep their files (lib/log_sink.lua clamps to the same range).
local LOG_RUNS_MIN = 1
local LOG_RUNS_MAX = 50

-- Mirrors the ladder in lib/log.lua and is replaced by it in ensureDeps(). It is kept as a
-- literal only so this page still builds if the log module cannot be loaded; log.lua holds the
-- definition, and the values below are the order the selector offers them in.
local DEBUG_LEVEL_VALUES = { "off", "error", "warn", "info", "debug" }

local function isKnownDebugLevel(value)
  for _, name in ipairs(DEBUG_LEVEL_VALUES) do
    if name == value then return true end
  end
  return false
end

local function buildDefaultConfig()
  local cfg = {}
  for _, field in ipairs(CONFIG_SCHEMA) do
    cfg[field.key] = field.default
  end
  return cfg
end

local ui = {
  loaded = false,
  sections = {
    logging = true
  },
  config = buildDefaultConfig()
}

ui.runtime = nil

local t = nil

local function ensureDeps()
  if not Common then
    Common = loadModule("app/pages/settings/common.lua")
  end
  if not Controls then
    Controls = loadModule("ui/controls.lua")
  end
  if Log == nil then
    -- pcall because loadModule asserts, and a missing log module must not take the page down.
    local ok, mod = pcall(loadModule, "lib/log.lua")
    Log = (ok and mod) or false
    if Log and type(Log.LEVELS) == "table" and #Log.LEVELS > 0 then
      DEBUG_LEVEL_VALUES = Log.LEVELS
    end
  end
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
    ui.runtime.valueGetters = {}
    ui.runtime.valueSetters = {}
  end
  if not t then
    t = Common.pageT("settings_developer_settings")
  end
end

local function prefBool(value, default)
  if value == nil then return default end
  return value == true or value == "true" or value == 1 or value == "1"
end

local function copyFromPrefs(prefs)
  local general = (prefs and prefs.general) or {}
  for _, field in ipairs(CONFIG_SCHEMA) do
    local raw = general[field.key]
    if field.type == "number" then
      ui.config[field.key] = tonumber(raw) or field.default
    elseif field.type == "string" then
      local text = tostring(raw or "")
      if text == "" then text = field.default end
      ui.config[field.key] = string.lower(text)
    else
      ui.config[field.key] = prefBool(raw, field.default)
    end
  end

  if not isKnownDebugLevel(ui.config.debug_level) then
    ui.config.debug_level = "off"
  end
end

local function ensureLoaded(prefs)
  if ui.loaded then return end
  copyFromPrefs(prefs)
  ui.loaded = true
end

local function getValueGetter(key)
  local getter = ui.runtime.valueGetters[key]
  if getter then return getter end

  getter = function()
    return ui.config[key]
  end
  ui.runtime.valueGetters[key] = getter
  return getter
end

local function getValueSetter(key)
  local setter = ui.runtime.valueSetters[key]
  if setter then return setter end

  setter = function(value)
    if ui.config[key] == value then return end
    ui.config[key] = value
  end
  ui.runtime.valueSetters[key] = setter
  return setter
end

local function buildDebugLevelOptions(i18n)
  local options = {}
  for _, name in ipairs(DEBUG_LEVEL_VALUES) do
    options[#options + 1] = {
      value = name,
      label = t(i18n, "debug_level_" .. name, string.upper(name))
    }
  end
  return options
end

-- Every row carries its own `?`: ui/controls.lua draws the button and shows `helpText` under
-- `helpTitle` when no handler of the page's own is given.
local function buildLogging(cursorY, children, x, w, i18n)
  local levelLabel = t(i18n, "debug_level", "Log Level")
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    levelLabel,
    buildDebugLevelOptions(i18n),
    getValueGetter("debug_level")(),
    getValueSetter("debug_level"),
    { helpText = t(i18n, "debug_level_help", "How much is logged; errors, warnings and milestones are kept even at OFF, INFO adds in-flight tuning and more, DEBUG the steps between, TRACE every message to and from the flight controller."), helpTitle = levelLabel }
  )

  local headerLabel = t(i18n, "show_header_memory", "Show Header Memory")
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    headerLabel,
    ui.runtime.getBoolGetter("show_header_memory"),
    ui.runtime.getBoolSetter("show_header_memory"),
    { helpText = t(i18n, "show_header_memory_help", "Shows the configuration tool's Lua memory in the page header."), helpTitle = headerLabel }
  )

  local serialLabel = t(i18n, "enable_serial_debug", "Enable Serial Debug")
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    serialLabel,
    ui.runtime.getBoolGetter("enable_serial_debug"),
    ui.runtime.getBoolSetter("enable_serial_debug"),
    { helpText = t(i18n, "enable_serial_debug_help", "Also sends the lines the log level lets through to the radio's serial port; at OFF that is none."), helpTitle = serialLabel }
  )

  local cardLabel = t(i18n, "log_to_card", "Log Session To Card")
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    cardLabel,
    ui.runtime.getBoolGetter("log_to_card"),
    ui.runtime.getBoolSetter("log_to_card"),
    { helpText = t(i18n, "log_to_card_help", "Writes the log to the SD card, one set of files per power-up of the radio; the background decoder writes only from DEBUG up."), helpTitle = cardLabel }
  )

  local runsLabel = t(i18n, "log_runs", "Keep Logs Of")
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    runsLabel,
    {
      min = LOG_RUNS_MIN,
      max = LOG_RUNS_MAX,
      step = 1,
      suffix = t(i18n, "log_runs_suffix", " runs"),
      get = getValueGetter("log_runs"),
      set = getValueSetter("log_runs"),
      helpText = t(i18n, "log_runs_help", "How many power-ups of the radio keep their log files on the card; the oldest are deleted when a new one starts."),
      helpTitle = runsLabel
    }
  )
  return cursorY
end

local SECTIONS = {
  {
    key = "logging",
    titleKey = "section_logging",
    titleFallback = "Logging",
    build = buildLogging
  }
}

function M.getHeaderActions()
  ensureDeps()
  return { save = true, help = true }
end


function M.onReload(ctx)
  ensureDeps()
  copyFromPrefs(ctx.preferences)
end

function M.onSave(ctx)
  ensureDeps()
  if not ctx.preferences.general then ctx.preferences.general = {} end

  for _, field in ipairs(CONFIG_SCHEMA) do
    ctx.preferences.general[field.key] = ui.config[field.key]
  end

  local ok, err = ctx.savePreferences()
  if ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({ ok = true, title = t(ctx.i18n, "saved_title", "Saved"), message = t(ctx.i18n, "saved_message", "Developer settings saved") })
    end
  else
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({ title = t(ctx.i18n, "save_error_title", "Error"), message = t(ctx.i18n, "save_error_message", "Save failed") .. ": " .. Common.saveFailureReason(ctx.i18n, err) })
    end
  end
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded(ctx.preferences)

  local children = ctx.children
  local x, w = ctx.x, ctx.w
  local i18n = ctx.i18n
  ui.runtime.setRequestRebuild(ctx.requestRebuild)
  local cursorY = ctx.y

  for i, section in ipairs(SECTIONS) do
    if i > 1 then cursorY = cursorY + 10 end

    Controls.appendStaticSectionHeader(children, x, cursorY, w,
      t(i18n, section.titleKey, section.titleFallback)
    )

    cursorY = cursorY + Controls.STATIC_SECTION_H
    cursorY = section.build(cursorY, children, x, w, i18n)
  end
end

function M.onClose()
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui)
  else
    ui.runtime = nil
    ui.loaded = false
  end
  Controls = nil
  Common = nil
  t = nil
end

return M
