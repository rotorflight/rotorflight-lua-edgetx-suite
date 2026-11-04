-- Checks Reset rollback and value formatting through the real page and dashboard library.
-- Desktop Lua 5.3, from the repository root:
--   lua5.3 bin/dashboard/verify_overrides_reset.lua
--   lua5.3 bin/dashboard/verify_overrides_reset.lua --page <pre-fix-page.lua>
-- UI controls and the model store are stubbed; button callbacks and override removal are real.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end

local pagePath = ROOT .. "/src/rfsuite/app/pages/settings/dashboard/overrides/page.lua"
if #arg == 2 and arg[1] == "--page" then
  pagePath = arg[2]
elseif #arg ~= 0 then
  io.stderr:write("usage: lua5.3 bin/dashboard/verify_overrides_reset.lua [--page <file>]\n")
  os.exit(2)
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

local function deepEqual(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, value in pairs(a) do
    if not deepEqual(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

local assertions, failures = 0, 0
local function check(condition, name)
  assertions = assertions + 1
  if not condition then
    failures = failures + 1
    print("FAIL: " .. name)
  end
end

local CORE = "/SCRIPTS/TOOLS/rfsuite-core/"
local KEY = "cfg_system_default_colors"
local OTHER = "cfg_system_default_enabled"
local themes = { { path = "system/default", name = "Default" } }
local preferences = { dashboard = { [KEY] = "standard", [OTHER] = true } }
local cases = {
  { name = "single-row inferred", explicit = false, all = false },
  { name = "single-row explicit", explicit = true, all = false },
  { name = "reset all", explicit = false, all = true },
}

for _, case in ipairs(cases) do
  for _, saveOk in ipairs({ false, true }) do
    local name = case.name .. (saveOk and " / successful save / " or " / failed save / ")
    local value = { colors = { 12, 34 }, enabled = false }
    local dashboard = { [KEY] = value, model_theme_preflight = "system/default", retained = "keep", [7] = "keep" }
    if case.explicit then dashboard.overrides = true end
    if case.all or case.explicit then dashboard[OTHER] = false end
    local modelPrefs = { dashboard = dashboard, craft = { name = "Test model" }, audio = { enabled = false } }
    local before = copy(modelPrefs)
    local saves, confirmations, dirty = 0, 0, 0
    local saved, savedId, savedTable
    _G.rfsuite = {
      palette = { text = 1, border = 2 }, preferences = preferences,
      session = { mcu_id = "0123456789ABCDEF01234567", modelPreferences = modelPrefs },
    }
    _G.rfsuite.paths = dofile(ROOT .. "/src/rfsuite/lib/paths.lua")
    _G.SMLSIZE = 0
    _G.lvgl = { UI_ELEMENT_HEIGHT = 32 }

    local Common = {
      pageT = function() return function(_, _, fallback) return fallback end end,
      saveFailureReason = function(_, reason) return reason end,
      createFormRuntime = function()
        return {
          setRequestRebuild = function() end,
          markDirty = function() dirty = dirty + 1 end,
        }
      end,
    }
    local Controls = { SECTION_H = 30, appendSectionHeader = function() end }
    local MP = {
      saveByMcuId = function(id, prefs)
        saves = saves + 1
        savedId, savedTable, saved = id, prefs, copy(prefs)
        if saveOk then return true end
        return false, "write"
      end,
    }
    local DashboardLib
    _G.loadScript = function(path)
      local rel = string.sub(path, #CORE + 1)
      if rel == "lib/log.lua" then return nil end
      if rel == "app/pages/settings/common.lua" then return function() return Common end end
      if rel == "ui/controls.lua" then return function() return Controls end end
      if rel == "lib/model_preferences.lua" then return function() return MP end end
      if rel == "app/pages/settings/dashboard/lib.lua" then return function() return DashboardLib end end
      if rel == "ui/confirm_dialog.lua" then
        return function()
          return { show = function(options)
            confirmations = confirmations + 1
            options.onConfirm()
            return true
          end }
        end
      end
      error("unexpected module: " .. tostring(path))
    end
    DashboardLib = assert(loadfile(ROOT .. "/src/rfsuite/app/pages/settings/dashboard/lib.lua"))()
    DashboardLib.listThemes = function() return themes end
    local page = assert(loadfile(pagePath))()
    local function build()
      local children = {}
      page.build({ children = children, preferences = preferences, x = 0, y = 0, w = 800 })
      return children
    end
    local function buttons(children, text)
      local found = {}
      for _, child in ipairs(children) do
        if child.type == "button" and child.text == text then found[#found + 1] = child end
      end
      return found
    end
    local listBefore = DashboardLib.listModelOverrides(preferences, modelPrefs, themes)
    local children = build()
    check(#buttons(children, "Reset") == #listBefore and #listBefore > 0, name .. "initial reset rows listed")
    local reset = buttons(children, case.all and "Reset all" or "Reset")[1]
    assert(reset, name .. "reset button missing")
    reset.press()
    check(saves == 1, name .. "one save attempted")
    check(savedId == _G.rfsuite.session.mcu_id and savedTable == modelPrefs, name .. "whole model passed to store")
    check(saved.dashboard[KEY] == nil and (not case.all or saved.dashboard[OTHER] == nil), name .. "removed keys passed to store")
    check(saved.dashboard.overrides == true, name .. "enabled switch passed to store")
    check(confirmations == (case.all and 1 or 0), name .. "confirmation only for reset all")
    check(dirty == 1, name .. "notice marked dirty")

    local listed = DashboardLib.listModelOverrides(preferences, modelPrefs, themes)
    children = build()
    local notice = saveOk and "Saved" or "Save failed: write"
    local hasNotice = false
    for _, child in ipairs(children) do
      if child.type == "label" and child.text == notice then hasNotice = true end
    end
    check(hasNotice, name .. "save notice unchanged")
    if saveOk then
      local expected = copy(before)
      expected.dashboard[KEY] = nil
      if case.all then expected.dashboard[OTHER] = nil end
      expected.dashboard.overrides = true
      check(deepEqual(modelPrefs, expected), name .. "only reset keys removed and switch retained")
      check(dashboard[KEY] == nil and (not case.all or dashboard[OTHER] == nil), name .. "reset keys gone")
      check(#listed == (case.explicit and 1 or 0), name .. "removed rows no longer listed")
    else
      check(deepEqual(_G.rfsuite.session.modelPreferences, before), name .. "model preferences unchanged")
      check(dashboard.overrides == (case.explicit and true or nil), name .. "original switch restored")
      check(dashboard[KEY] == value, name .. "table value reference restored")
      check(deepEqual(listed, listBefore), name .. "override rows still listed")
      check(#buttons(children, "Reset") == #listBefore, name .. "reset buttons remain available")
    end
  end
end

-- Check the actual row labels, including the standard value, without pressing Reset.
-- Stock Lua cannot emulate LUA_FLOORN2I mixed numeric equality through a math stub
-- or __eq proxy; these assertions check formatting but cannot reproduce the radio's floor.
local formatCases = {
  { value = 25.2, text = "25.2" },
  { value = 18.1, text = "18.1" },
  { value = 18.0, text = "18" },
  { value = 20, text = "20" },
  { value = 18.5, text = "18.5" },
  { value = 3.14, text = "3.14" },
  { value = true, text = "On" },
  { value = false, text = "Off" },
  { value = "unchanged", text = "unchanged" },
}
do
  local formatPreferences = { dashboard = {} }
  local modelPrefs = { dashboard = {} }
  _G.rfsuite = {
    palette = { text = 1, border = 2 }, preferences = formatPreferences,
    session = { mcu_id = "0123456789ABCDEF01234567", modelPreferences = modelPrefs },
  }
  _G.rfsuite.paths = dofile(ROOT .. "/src/rfsuite/lib/paths.lua")
  _G.SMLSIZE = 0
  _G.lvgl = { UI_ELEMENT_HEIGHT = 32 }
  local Common = {
    pageT = function() return function(_, _, fallback) return fallback end end,
    createFormRuntime = function()
      return { setRequestRebuild = function() end }
    end,
  }
  local Controls = { SECTION_H = 30, appendSectionHeader = function() end }
  local DashboardLib
  _G.loadScript = function(path)
    local rel = string.sub(path, #CORE + 1)
    if rel == "lib/log.lua" then return nil end
    if rel == "app/pages/settings/common.lua" then return function() return Common end end
    if rel == "ui/controls.lua" then return function() return Controls end end
    if rel == "app/pages/settings/dashboard/lib.lua" then return function() return DashboardLib end end
    error("unexpected module: " .. tostring(path))
  end
  DashboardLib = assert(loadfile(ROOT .. "/src/rfsuite/app/pages/settings/dashboard/lib.lua"))()
  DashboardLib.listThemes = function() return themes end
  local page = assert(loadfile(pagePath))()
  for _, case in ipairs(formatCases) do
    modelPrefs.dashboard[KEY] = case.value
    formatPreferences.dashboard[KEY] = case.value
    local children = {}
    page.build({ children = children, preferences = formatPreferences, x = 0, y = 0, w = 800 })
    local expected = "Default / colors = " .. case.text .. "  (standard " .. case.text .. ")"
    local found = false
    for _, child in ipairs(children) do
      if child.type == "label" and child.text == expected then found = true end
    end
    check(found, "drawn model and standard row: " .. expected)
  end
end

print(string.format("6 reset scenarios, %d format rows, %d assertions, %d failures", #formatCases, assertions, failures))
os.exit(failures == 0 and 0 or 1)
