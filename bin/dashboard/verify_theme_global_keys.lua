-- Checks the Keys pages of Urban, Grid and Deck against the radio-wide fullscreen keys, with the
-- real theme modules. Desktop Lua 5.3, from the repository root:
--
--   lua5.3 bin/dashboard/verify_theme_global_keys.lua
--   lua5.3 bin/dashboard/verify_theme_global_keys.lua --verbose
--   lua5.3 bin/dashboard/verify_theme_global_keys.lua --self-test
--
-- Per theme: the real configure module builds its Keys page and saves it in radio and model
-- scope; the real layout binds the keys; the real widgets/dashboard/keys.lua resolves them; the
-- real view registry is inspected. The choice control records its rows instead of drawing them,
-- and the model store's card write is stubbed; no theme logic is copied here.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end

local verbose, selfTest = false, false
for i = 1, #arg do
  if arg[i] == "--verbose" then verbose = true
  elseif arg[i] == "--self-test" then selfTest = true
  else
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_theme_global_keys.lua [--verbose] [--self-test]\n")
    os.exit(2)
  end
end

local SRC = ROOT .. "/src/rfsuite/"
local CORE = "/SCRIPTS/TOOLS/rfsuite-core/"
local THEMES = { "urban", "grid", "deck" }
-- The fields an earlier build of the theme Keys pages stored; they must stay as they are and be
-- read by nothing.
local OLD_FIELDS = { "key_page_down", "key_page_up", "key_mdl", "key_sys", "key_tele" }
local NEW_FIELD = { pageDown = "theme_key_page_down", pageUp = "theme_key_page_up", mdl = "theme_key_mdl",
  sys = "theme_key_sys" }
local GLOBAL_TAG = "@i18n(app.pages.settings_dashboard_settings.urban_key_global)@"

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

-- A source change applied to a module as it is loaded, for the self-test: { [rel] = { from, to } }
-- with `rel` holding `%s` for the theme folder. Nil for the real tree.
local mutation = nil

local function sourceOf(rel)
  local text = readFile(SRC .. rel)
  if text == nil or mutation == nil then return text end
  for pattern, change in pairs(mutation) do
    for _, theme in ipairs(THEMES) do
      if rel == string.format(pattern, theme) then
        local first, last = string.find(text, change[1], 1, true)
        if first == nil or string.find(text, change[1], last + 1, true) ~= nil then
          error("mutation anchor not found exactly once in " .. rel)
        end
        text = string.sub(text, 1, first - 1) .. change[2] .. string.sub(text, last + 1)
      end
    end
  end
  return text
end

local function loadRel(rel)
  local text = sourceOf(rel)
  if text == nil then return nil end
  return assert(load(text, "@" .. rel))
end

local rows = {}
local Controls = setmetatable({ SECTION_H = 30, ROW_H = 40 }, {
  __index = function(_, key)
    if key == "appendComboSelect" then
      return function(children, _, _, _, label, options, selected, onSelect, opts)
        rows[#rows + 1] = { label = label, options = options, selected = selected, onSelect = onSelect, opts = opts }
        if type(children) == "table" then children[#children + 1] = key end
        return 41
      end
    end
    if type(key) == "string" and string.sub(key, 1, 6) == "append" then
      return function(children)
        if type(children) == "table" then children[#children + 1] = key end
        return 41
      end
    end
  end,
})
local MP = { saveByMcuId = function() return true end }

_G.loadScript = function(path)
  local rel = string.sub(path, 1, #CORE) == CORE and string.sub(path, #CORE + 1) or nil
  if rel == nil then return nil end
  if rel == "ui/controls.lua" then return function() return Controls end end
  if rel == "lib/model_preferences.lua" then return function() return MP end end
  if rel == "lib/log.lua" then return nil end
  return loadRel(rel)
end

local function configKey(theme, field)
  return "cfg_system_" .. theme .. "_" .. field
end

-- Old choices that would bind something visible if anything still read them.
local function seedOld(theme)
  local dashboard = {}
  for i = 1, #OLD_FIELDS do dashboard[configKey(theme, OLD_FIELDS[i])] = "link" end
  return dashboard
end

local function checkOld(theme, dashboard, where)
  for i = 1, #OLD_FIELDS do
    local key = configKey(theme, OLD_FIELDS[i])
    if dashboard[key] ~= "link" then return where .. " changed " .. key end
  end
end

local function isHeld(row)
  return type(row.opts) == "table" and row.opts.active == false
end

local function hasTag(row)
  return string.find(row.label or "", GLOBAL_TAG, 1, true) ~= nil
end

-- Open the real Keys page over old stored choices in either preference scope. `globalKeys`, where
-- given, are radio-wide key choices stored beside them (Settings > Dashboard > Keys).
local function openPage(theme, scope, globalKeys)
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.paths = dofile(SRC .. "lib/paths.lua")
  local DashboardLib = loadRel("app/pages/settings/dashboard/lib.lua")()
  local radio = seedOld(theme)
  for k, v in pairs(globalKeys or {}) do radio[k] = v end
  local model = seedOld(theme)
  local modelPrefs = { dashboard = model }
  _G.rfsuite = { session = { mcu_id = "0123456789ABCDEF01234567", modelPreferences = modelPrefs } }
  _G.rfsuite.paths = dofile(SRC .. "lib/paths.lua")
  DashboardLib.setEditScope(scope)
  local factory = loadRel("widgets/dashboard/themes/" .. theme .. "/configure.lua")()
  local reports = {}
  local ctx = {
    preferences = { dashboard = radio }, theme = { path = "system/" .. theme }, page = { id = "keys" },
    i18n = { t = function(key) return key end }, x = 0, y = 0, w = 800, h = 400, children = {},
    savePreferences = function() return true end,
    reportSave = function(report) reports[#reports + 1] = report end,
  }
  local page = type(factory) == "function" and factory(ctx) or factory
  rows = {}
  page.onReload(ctx)
  page.build(ctx)
  return page, ctx, radio, model, reports, DashboardLib
end

-- The Keys page in one scope: starts unbound over old choices, marks what the global page holds,
-- and stores a choice in the new field of that scope only.
local function pageCase(theme, scope)
  local page, ctx, radio, model, reports = openPage(theme, scope)
  if #rows ~= 5 then return "the Keys page drew " .. #rows .. " rows, expected 5" end
  local unbound = { "none", "none", "none", "none", "none" }
  for i = 1, 5 do
    if rows[i].selected ~= unbound[i] then
      return "row " .. i .. " starts on " .. tostring(rows[i].selected) .. ", expected " .. unbound[i]
    end
  end
  -- As the radio comes, PAGE > and PAGE < (rows 1 and 2, quick menu), SYS (row 4) and TELE (row 5)
  -- are held; MDL (row 3) is not.
  for i = 1, 5 do
    local want = (i ~= 3)
    if isHeld(rows[i]) ~= want or hasTag(rows[i]) ~= want then
      return "row " .. i .. (want and " is not marked held" or " is marked held") .. " with no global choice"
    end
  end
  rows[3].onSelect("battery")
  page.onSave(ctx)
  if #reports ~= 1 or reports[1].ok ~= true then return "save did not report success" end
  local bad = checkOld(theme, radio, "radio store") or checkOld(theme, model, "model store")
  if bad then return bad end
  local target = scope == "model" and model or radio
  local other = scope == "model" and radio or model
  local newKey = configKey(theme, NEW_FIELD.mdl)
  if target[newKey] ~= "battery" then return "MDL was not stored in " .. newKey end
  if other[newKey] ~= nil then return "MDL leaked into the other scope" end
  if type(page.onClose) == "function" then page.onClose() end

  -- SYS put on Theme radio-wide: its row is the theme's again.
  radio.key_sys = "theme"
  rows = {}
  page.onReload(ctx)
  page.build(ctx)
  if isHeld(rows[4]) or hasTag(rows[4]) then return "SYS on Theme radio-wide is still marked held" end
  if not isHeld(rows[5]) then return "TELE lost its mark when only SYS changed" end
  if type(page.onClose) == "function" then page.onClose() end

  -- A page key held radio-wide (Nothing is a choice there, not Theme) is marked; PAGE < and TELE
  -- put on Theme are the theme's again.
  radio.key_page_down = "none"
  radio.key_page_up = "theme"
  radio.key_tele = "theme"
  rows = {}
  page.onReload(ctx)
  page.build(ctx)
  if not isHeld(rows[1]) or not hasTag(rows[1]) then return "PAGE > held radio-wide is not marked held" end
  if isHeld(rows[2]) or hasTag(rows[2]) then return "PAGE < on Theme is marked held" end
  if isHeld(rows[5]) or hasTag(rows[5]) then return "TELE on Theme radio-wide is still marked held" end
  if type(page.onClose) == "function" then page.onClose() end
end

-- PAGE must distinguish an untouched row from a deliberate Quick menu choice, through the
-- actual page callback, preference store, layout and global resolver in both scopes. The page
-- keys are put on Theme radio-wide first, as a pilot must before the theme's binding acts.
local function pageMenuCase(theme, scope)
  local page, ctx, radio, model, reports, DashboardLib =
    openPage(theme, scope, { key_page_down = "theme", key_page_up = "theme" })
  if #rows ~= 5 then return "the Keys page drew " .. #rows .. " rows, expected 5" end
  local layout = loadRel("widgets/dashboard/themes/" .. theme .. "/layout.lua")()
  local Keys = loadRel("widgets/dashboard/keys.lua")()
  local bound = { keys = {}, action = function() end, entry = function() end }
  local modelPrefs = _G.rfsuite.session.modelPreferences
  local function resolve(name)
    local cfg = DashboardLib.getThemeConfig(ctx.preferences, "system/" .. theme, nil, modelPrefs)
    layout.bindKeys({ themeConfig = cfg }, bound)
    return Keys.resolve(radio, name, bound.keys)
  end
  for _, name in ipairs({ "pageDown", "pageUp" }) do
    local action, global = resolve(name)
    if action ~= nil or global then return "untouched " .. name .. " resolved to " .. tostring(action) end
  end
  local target = scope == "model" and model or radio
  local other = scope == "model" and radio or model
  for i, name in ipairs({ "pageDown", "pageUp" }) do
    rows[i].onSelect("menu")
    page.onSave(ctx)
    if #reports ~= i or reports[i].ok ~= true then return "Quick menu save did not report success" end
    local key = configKey(theme, NEW_FIELD[name])
    if target[key] ~= "menu" then return name .. " Quick menu was not stored in " .. key end
    if other[key] ~= nil then return name .. " Quick menu leaked into the other scope" end
    local action, global = resolve(name)
    if action ~= "openView:menu" or global then
      return name .. " Quick menu resolved to " .. tostring(action) .. ", expected openView:menu"
    end
    if i == 1 then
      action, global = resolve("pageUp")
      if action ~= nil or global then return "untouched pageUp changed when pageDown was bound" end
    end
  end
  local bad = checkOld(theme, radio, "radio store") or checkOld(theme, model, "model store")
  if bad then return bad end
  rows = {}
  page.onReload(ctx)
  page.build(ctx)
  if #rows ~= 5 or rows[1].selected ~= "menu" or rows[2].selected ~= "menu" then
    return "saved PAGE Quick menu choices did not reload"
  end
  -- Clearing a choice must remove the previous build's binding as well.
  for i, name in ipairs({ "pageDown", "pageUp" }) do
    rows[i].onSelect("none")
    page.onSave(ctx)
    local action, global = resolve(name)
    if action ~= nil or global then return "cleared " .. name .. " still resolves to " .. tostring(action) end
  end
  bad = checkOld(theme, radio, "radio store") or checkOld(theme, model, "model store")
  if bad then return bad end
  if type(page.onClose) == "function" then page.onClose() end
end

-- The binding: old fields bind nothing, a new field binds the theme's action, and the global page
-- decides whether that binding acts.
local function bindingCase(theme)
  _G.rfsuite = {}
  _G.rfsuite.paths = dofile(SRC .. "lib/paths.lua")
  local layout = loadRel("widgets/dashboard/themes/" .. theme .. "/layout.lua")()
  local init = loadRel("widgets/dashboard/themes/" .. theme .. "/init.lua")()
  local Keys = loadRel("widgets/dashboard/keys.lua")()
  if type(layout.bindKeys) ~= "function" then return "layout has no bindKeys" end
  local ctx = { keys = { extra = "kept", sys = "stale" }, action = function() end, entry = function() end }
  local old = {}
  for i = 1, #OLD_FIELDS do old[OLD_FIELDS[i]] = "link" end
  layout.bindKeys({ themeConfig = old }, ctx)
  for _, key in ipairs({ "pageDown", "pageUp", "mdl", "sys", "tele" }) do
    if ctx.keys[key] ~= nil then return "with only old choices stored, " .. key .. " is bound to " .. tostring(ctx.keys[key]) end
  end
  if ctx.keys.extra ~= "kept" then return "bindKeys touched a key it does not own" end

  layout.bindKeys({ themeConfig = { [NEW_FIELD.sys] = "link" } }, ctx)
  local own = "openView:" .. theme .. "_link"
  if ctx.keys.sys ~= own then return "a stored SYS choice bound " .. tostring(ctx.keys.sys) .. ", expected " .. own end

  local action, global = Keys.resolve({}, "sys", ctx.keys)
  if action ~= "openTool" or global ~= true then return "the radio-wide SYS default did not hold the key" end
  action, global = Keys.resolve({ key_sys = "theme" }, "sys", ctx.keys)
  if action ~= own or global ~= false then return "SYS on Theme radio-wide did not take the theme's binding" end

  -- The same for a page key: the radio-wide Quick menu holds it until the pilot puts it on Theme.
  layout.bindKeys({ themeConfig = { [NEW_FIELD.pageDown] = "link" } }, ctx)
  if ctx.keys.pageDown ~= own then return "a stored PAGE > choice bound " .. tostring(ctx.keys.pageDown) end
  action, global = Keys.resolve({}, "pageDown", ctx.keys)
  if action ~= "openView:menu" or global ~= true then return "the radio-wide PAGE > default did not hold the key" end
  action, global = Keys.resolve({ key_page_down = "theme" }, "pageDown", ctx.keys)
  if action ~= own or global ~= false then return "PAGE > on Theme radio-wide did not take the theme's binding" end

  local views = {}
  for i = 1, #(init.views or {}) do views[init.views[i].id] = true end
  local actions = {}
  for i = 1, #(layout.KEY_ACTIONS or {}) do actions[layout.KEY_ACTIONS[i].id] = layout.KEY_ACTIONS[i].action end
  for _, id in ipairs({ "tools", "link", "telemetry", "battery", "status" }) do
    local suffix = id == "tools" and "menu" or id
    local route = "openView:" .. theme .. "_" .. suffix
    if actions[id] ~= route or not views[theme .. "_" .. suffix] then return id .. " action or view is missing" end
  end
  local pages = {}
  for i = 1, #(init.pages or {}) do pages[init.pages[i].id] = true end
  if not pages.keys then return "init.lua lists no Keys page" end
end

local CASES = {}
for _, theme in ipairs(THEMES) do
  CASES[#CASES + 1] = { id = theme .. " page, radio scope", fn = function() return pageCase(theme, "standard") end }
  CASES[#CASES + 1] = { id = theme .. " page, model scope", fn = function() return pageCase(theme, "model") end }
  CASES[#CASES + 1] = { id = theme .. " binding", fn = function() return bindingCase(theme) end }
  CASES[#CASES + 1] = { id = theme .. " page menu, radio scope", fn = function() return pageMenuCase(theme, "standard") end }
  CASES[#CASES + 1] = { id = theme .. " page menu, model scope", fn = function() return pageMenuCase(theme, "model") end }
end

-- The theme modules keep themselves in globals (`__rfsuiteTheme<Name>Module`) and hand that copy
-- back on the next load, so every case starts without them: otherwise a case would read the module
-- an earlier one loaded -- and a mutant would be measured against the real file.
local function forgetThemeModules()
  local names = {}
  for k in pairs(_G) do
    if type(k) == "string" and string.match(k, "^__rfsuiteTheme") then names[#names + 1] = k end
  end
  for i = 1, #names do _G[names[i]] = nil end
end

local function run(quiet)
  local failures, passes = {}, 0
  for i = 1, #CASES do
    forgetThemeModules()
    local ok, bad = pcall(CASES[i].fn)
    if not ok then bad = "raised: " .. tostring(bad) end
    if bad then failures[#failures + 1] = { case = CASES[i].id, detail = bad } else passes = passes + 1 end
    if verbose and not quiet then print((bad and "FAIL " or "PASS ") .. CASES[i].id .. (bad and (": " .. bad) or "")) end
  end
  return failures, passes
end

-- Each mutant must turn red only the kinds of case written for it, and at least one in every theme.
local MUTANTS = {
  {
    name = "the binding reads the old fields",
    change = { ["widgets/dashboard/themes/%s/layout.lua"] = { 'pref = "theme_key_sys"', 'pref = "key_sys"' } },
    expect = { "page", "binding" },
  },
  {
    name = "the theme declares a SYS default again",
    change = { ["widgets/dashboard/themes/%s/layout.lua"] = {
      '{ key = "sys",      pref = "theme_key_sys",       default = "none"',
      '{ key = "sys",      pref = "theme_key_sys",       default = "suite_tool"' } },
    expect = { "page", "binding" },
  },
  {
    name = "the theme selects Quick menu by default for PAGE",
    change = { ["widgets/dashboard/themes/%s/layout.lua"] = {
      '{ key = "pageDown", pref = "theme_key_page_down", default = "none"',
      '{ key = "pageDown", pref = "theme_key_page_down", default = "menu"' } },
    expect = { "page", "binding" },
  },
  {
    name = "PAGE Quick menu is left unbound",
    change = { ["widgets/dashboard/themes/%s/layout.lua"] = {
      'if id == entry.host then', 'if id == entry.host or id == "menu" then' } },
    expect = { "page menu" },
  },
  {
    name = "the page marks no key as held",
    change = { ["widgets/dashboard/themes/%s/configure.lua"] = {
      'local held = GlobalKeys.global(dashboard, KEYS[i].key) ~= "theme"', 'local held = false' } },
    expect = { "page" },
  },
}

if selfTest then
  local real = run(true)
  if #real > 0 then print("SELF-TEST FAILED: real modules are red: " .. real[1].case .. ": " .. real[1].detail); os.exit(1) end
  for _, m in ipairs(MUTANTS) do
    mutation = m.change
    local failures = run(true)
    mutation = nil
    if verbose then
      for i = 1, #failures do print("  [" .. m.name .. "] " .. failures[i].case .. ": " .. failures[i].detail) end
    end
    local red = {}
    for i = 1, #failures do
      local f = failures[i]
      if string.find(f.detail, "raised:", 1, true) == 1 then
        print("SELF-TEST FAILED: mutant '" .. m.name .. "' raised instead of failing a check (a stale anchor?): " .. f.case .. ": " .. f.detail)
        os.exit(1)
      end
      local expected = false
      for j = 1, #m.expect do
        if string.find(f.case, m.expect[j], 1, true) then expected = true end
      end
      if not expected then
        print("SELF-TEST FAILED: mutant '" .. m.name .. "' turned an unrelated case red: " .. f.case .. ": " .. f.detail)
        os.exit(1)
      end
      red[string.match(f.case, "^(%a+) ")] = f
    end
    for _, theme in ipairs(THEMES) do
      if red[theme] == nil then
        print("SELF-TEST FAILED: mutant '" .. m.name .. "' stayed green for " .. theme)
        os.exit(1)
      end
      print("(self-test) " .. m.name .. ": " .. red[theme].case .. ": " .. red[theme].detail)
    end
  end
  local again = run(true)
  if #again > 0 then print("SELF-TEST FAILED: a mutant left the next run red: " .. again[1].case); os.exit(1) end
  print("SELF-TEST PASSED: old fields, empty defaults, explicit PAGE menu bindings and the held mark are enforced in all three themes")
  os.exit(0)
end

print(string.format("%d cases on the Urban, Grid and Deck Keys pages", #CASES))
local failures, passes = run(false)
if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f.case .. ": " .. f.detail) end
  print(string.format("%d case(s) failed, %d passed", #failures, passes))
  os.exit(1)
end
print(string.format("%d cases, 0 failures", passes))
