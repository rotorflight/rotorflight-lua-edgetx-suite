-- Checks the radio-wide dashboard shortcut resolver and its integration with Views.key, offline,
-- with desktop Lua 5.3, from the repository root:
--
--   lua5.3 bin/dashboard/verify_fullscreen_keys.lua
--   lua5.3 bin/dashboard/verify_fullscreen_keys.lua --verbose
--   lua5.3 bin/dashboard/verify_fullscreen_keys.lua --self-test
--
-- The resolver and Views cases load the real widgets/dashboard/keys.lua and
-- widgets/dashboard/views.lua from the tree; only firmware key constants, logging and
-- lcd.exitFullScreen are stubbed there. The Keys page case loads the real page and
-- app/pages/settings/common.lua, with the choice control recorded instead of drawn. The Runtime
-- exit case uses accounting firmware and flight-controller stubs around the real
-- widgets/dashboard/runtime.lua.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end

local verbose, selfTest = false, false
for i = 1, #arg do
  if arg[i] == "--verbose" then
    verbose = true
  elseif arg[i] == "--self-test" then
    selfTest = true
  else
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_fullscreen_keys.lua [--verbose] [--self-test]\n")
    os.exit(2)
  end
end

local SRC = ROOT .. "/src/rfsuite/"
local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local keysSource = readFile(SRC .. "widgets/dashboard/keys.lua")
local viewsSource = readFile(SRC .. "widgets/dashboard/views.lua")
local runtimeSource = readFile(SRC .. "widgets/dashboard/runtime.lua")
local pageSource = readFile(SRC .. "app/pages/settings/dashboard/keys/page.lua")
local commonSource = readFile(SRC .. "app/pages/settings/common.lua")
if keysSource == nil or viewsSource == nil or runtimeSource == nil or pageSource == nil or commonSource == nil then
  io.stderr:write("cannot read dashboard key modules\n")
  os.exit(2)
end

local function loadModule(source, name)
  local chunk, err = load(source, "@" .. name)
  if not chunk then return nil, err end
  local ok, result = pcall(chunk)
  if not ok or type(result) ~= "table" then return nil, result end
  return result
end

local function loadPair(source)
  local Keys, err = loadModule(source, "widgets/dashboard/keys.lua")
  if Keys == nil then return nil, nil, err end
  _G.rfsuite = {
    require = function(path)
      if path == "widgets/dashboard/keys.lua" then return Keys end
      if path == "lib/log.lua" then return { emit = function() end } end
      return nil
    end,
  }
  _G.rfsuite.paths = dofile(SRC .. "lib/paths.lua")
  local Views, viewErr = loadModule(viewsSource, "widgets/dashboard/views.lua")
  if Views == nil then return nil, nil, viewErr end
  return Keys, Views
end

_G.EVT_VIRTUAL_NEXT_PAGE = 101
_G.EVT_VIRTUAL_PREV_PAGE = 102
_G.EVT_VIRTUAL_EXIT = 103
_G.EVT_MODEL_BREAK = 104
_G.EVT_SYS_BREAK = 105
_G.EVT_TELEM_BREAK = 106
_G.lcd = { exitFullScreen = function() end }

local function newWidget(Views, base)
  local widget = {
    zone = { w = 800, h = 480 }, state = {}, preferences = { dashboard = {} },
    built = true, renderKey = "test",
  }
  if base ~= false then widget._viewBase = {} end
  widget._viewCtx = Views.bind(widget)
  return widget
end

local function runtimeCancellationCaseIn(source)
  local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
  _G.__keysTestStubs = Stubs
  local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  local Runtime, loadErr = loadModule(source, "widgets/dashboard/runtime.lua")
  if Runtime == nil then return "runtime did not load: " .. tostring(loadErr) end
  for _, pendingSpec in ipairs({
    { kind = "fs_theme", flag = "fullscreen" },
    { kind = "splash", flag = "fullscreenSplash" },
  }) do
    local w = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
    local ran = 0
    w.connectionReady = true
    w.inflightFullscreen = true
    w._viewStack = { { id = "menu" } }
    w._cachedFullscreenKey = "old"
    local pending = { kind = pendingSpec.kind, step = function() ran = ran + 1 end }
    pending[pendingSpec.flag] = true
    w._job = pending
    w.built = true
    w.renderKey = "fullscreen"
    w:refresh(nil)
    if ran ~= 0 then return "the pending " .. pendingSpec.kind .. " job ran after exit" end
    if w._job == pending then return "the pending " .. pendingSpec.kind .. " job was retained" end
    if w.inflightFullscreen ~= nil or w._viewStack ~= nil or w._cachedFullscreenKey ~= nil then
      return "fullscreen visit state survived the " .. pendingSpec.kind .. " exit"
    end
    if w.built ~= false or w.renderKey ~= nil then return "the cancelled " .. pendingSpec.kind .. " surface stayed built" end
  end
  Stubs.releaseCard()
end

local function runtimeDeclaredKeysCaseIn(source)
  local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
  _G.__keysTestStubs = Stubs
  local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  -- MDL, the one key on Theme as the radio comes, so the menu can only be the manifest's doing.
  local declared = { mdl = "openView:menu" }
  local manifest = { name = "Key test", fullscreen = "theme", keys = declared }
  local realLoadScript = _G.loadScript
  _G.loadScript = function(path, mode)
    if path == "/SCRIPTS/TOOLS/rfsuite.user/dashboard/key-test/init.lua" then
      return function() return manifest end
    end
    return realLoadScript(path, mode)
  end
  local Runtime, err = loadModule(source, "widgets/dashboard/runtime.lua")
  if Runtime == nil then return "runtime did not load: " .. tostring(err) end
  local w = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  w.themePath = "user/key-test"
  w.theme = {}
  w:refresh(0)
  if w._viewBase ~= "theme" then return "the manifest's fullscreen mode was not read" end
  if w._declaredKeys ~= declared then return "the manifest's keys table was not retained" end
  local Views = _G.rfsuite.require("widgets/dashboard/views.lua")
  if Views.key(w, _G.EVT_MODEL_BREAK) ~= true or Views.top(w) ~= "menu" then
    return "the manifest's MDL binding did not open the menu before a theme build"
  end
  -- A different manifest must drop the previous theme's declarations.
  manifest = { name = "No keys", fullscreen = "theme" }
  w.theme = {}
  w:refresh(0)
  if w._declaredKeys ~= nil then return "the next theme inherited the previous keys table" end
  Stubs.releaseCard()
end

-- A preference reload clears `theme` and `themePath` and loads the theme again on a later logic
-- tick (reloadPreferencesIfNeeded, then reloadActiveTheme). Fullscreen passes keep arriving in
-- between, and a view of the theme's own that is open must still be open once the theme is back:
-- the registry is not to be made anew, and the stack pruned, without the theme that registers it.
local function runtimeReloadWindowCaseIn(source)
  local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
  _G.__keysTestStubs = Stubs
  local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  local manifest = { name = "Reload test", fullscreen = "theme",
    views = { { id = "extra", module = "extra.lua" } } }
  local realLoadScript = _G.loadScript
  _G.loadScript = function(path, mode)
    if path == "/SCRIPTS/TOOLS/rfsuite.user/dashboard/reload-test/init.lua" then
      return function() return manifest end
    end
    if path == "/SCRIPTS/TOOLS/rfsuite.user/dashboard/reload-test/extra.lua" then
      return function() return { build = function() end } end
    end
    return realLoadScript(path, mode)
  end
  local Runtime, err = loadModule(source, "widgets/dashboard/runtime.lua")
  if Runtime == nil then return "runtime did not load: " .. tostring(err) end
  -- The stub clock stands still, so no logic tick runs: the theme is exactly what is set here.
  local w = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  w.connectionReady = true
  w.themePath = "user/reload-test"
  w.theme = { build = function() end }
  w:refresh(0)
  local Views = _G.rfsuite.require("widgets/dashboard/views.lua")
  if Views.find(w, "extra") == nil then return "the theme's view was not registered" end
  Views.navigate(w, "openView:extra")
  w:refresh(0)
  if Views.top(w) ~= "extra" then return "the theme's view did not open" end
  w.theme, w.themePath, w.built, w.renderKey = nil, nil, false, nil
  w:refresh(0)
  -- A key in the window as well, set to Nothing so that it navigates nowhere itself.
  w.preferences = w.preferences or {}
  w.preferences.dashboard = w.preferences.dashboard or {}
  w.preferences.dashboard.key_page_down = "none"
  w:refresh(_G.EVT_VIRTUAL_NEXT_PAGE)
  w.themePath = "user/reload-test"
  w.theme = { build = function() end }
  w:refresh(0)
  if Views.top(w) ~= "extra" then
    return "the theme's view was taken off the stack in the reload window (top: " .. tostring(Views.top(w)) .. ")"
  end
  Stubs.releaseCard()
end

-- The Keys page as the tool runs it: loadScript hands it the keys module under test, the real
-- settings helpers and a choice control that records its rows. Returns the page and the rows.
local function loadKeysPage(keysSrc, pageSrc)
  local rows = {}
  local modules = {
    ["widgets/dashboard/keys.lua"] = keysSrc,
    ["app/pages/settings/common.lua"] = commonSource,
  }
  local controls = {
    appendComboSelect = function(_, _, _, _, label, options, selected, onSelect)
      rows[#rows + 1] = { label = label, options = options, selected = selected, onSelect = onSelect }
      return 1
    end,
  }
  _G.loadScript = function(path)
    local rel = string.match(path, "rfsuite%-core/(.+)$")
    if rel == "ui/controls.lua" then return function() return controls end end
    local src = rel and modules[rel]
    if src == nil then return nil end
    return load(src, "@" .. rel)
  end
  local page, err = loadModule(pageSrc, "app/pages/settings/dashboard/keys/page.lua")
  return page, rows, err
end

-- The shipped themes that bind keys of their own (Urban, Grid, Deck): their real layout binds the
-- keys from a stored theme configuration, and the real resolver answers with what it bound. With
-- no host fallback left for an unbound PAGE key, a choice the theme page offers as the quick menu
-- has to arrive in `ctx.keys` as that binding, and Nothing as no binding at all.
local SHIPPED_KEY_THEMES = { "urban", "grid", "deck" }

-- The real layout of a shipped theme, loaded the way the widget loads it. `transform`, where
-- given, rewrites the layout's source first, `transform(source, theme)` (the self-test's
-- mutants). Returns the layout and a
-- function that puts back every global the load touched.
local function loadThemeLayout(theme, transform)
  local savedRfsuite, savedLoadScript = _G.rfsuite, _G.loadScript
  local function restore()
    _G.rfsuite, _G.loadScript = savedRfsuite, savedLoadScript
    for k in pairs(_G) do
      if type(k) == "string" and string.match(k, "^__rfsuiteTheme") then _G[k] = nil end
    end
  end
  restore()
  _G.rfsuite = {}
  _G.rfsuite.paths = dofile(SRC .. "lib/paths.lua")
  _G.loadScript = function(path)
    local rel = string.match(path, "rfsuite%-core/(.+)$")
    local src = rel and readFile(SRC .. rel)
    if src == nil then return nil end
    return load(src, "@" .. rel)
  end
  local rel = "widgets/dashboard/themes/" .. theme .. "/layout.lua"
  local src = assert(readFile(SRC .. rel))
  if transform then src = transform(src, theme) end
  local ok, layout = pcall(function() return assert(load(src, "@" .. rel))() end)
  if not ok then restore(); error(layout, 0) end
  return layout, restore
end

-- `ctx.keys` as the theme's build leaves it for a stored theme configuration.
local function bindThemeKeys(layout, config)
  local ctx = { keys = {}, action = function() end, entry = function() end }
  layout.bindKeys({ themeConfig = config }, ctx)
  return ctx.keys
end

-- The PAGE keys put on Theme radio-wide: what the theme binds is then what they do.
local PAGE_ON_THEME = { key_page_down = "theme", key_page_up = "theme" }

local function themePageKeysCase(Keys, transform)
  local restore = function() end
  local ok, bad = pcall(function()
    for _, theme in ipairs(SHIPPED_KEY_THEMES) do
      restore()
      local layout
      layout, restore = loadThemeLayout(theme, transform)
      -- Each half sets the PAGE rows' default to the choice it does NOT store, so a binding that
      -- ignored the stored choice and answered with the row's default cannot pass: Quick menu is
      -- checked over a Nothing default, Nothing over a Quick menu default.
      local pageRows = {}
      for i = 1, #(layout.KEYS or {}) do
        local entry = layout.KEYS[i]
        if entry.key == "pageDown" or entry.key == "pageUp" then pageRows[#pageRows + 1] = entry end
      end
      if #pageRows ~= 2 then return theme .. ": the layout has " .. #pageRows .. " PAGE rows, expected 2" end
      local function storeAll(value, default)
        local config = {}
        for i = 1, #pageRows do
          pageRows[i].default = default
          config[pageRows[i].pref] = value
        end
        return config
      end
      local menuChoice = storeAll("menu", "none")
      local fresh = bindThemeKeys(layout, {})
      if fresh.pageDown ~= nil or fresh.pageUp ~= nil then
        return theme .. ": PAGE rows on Nothing are bound with no stored choice"
      end
      local stored = bindThemeKeys(layout, menuChoice)
      local action = Keys.resolve(PAGE_ON_THEME, "pageDown", stored)
      if action ~= "openView:menu" then
        return theme .. ": PAGE > set to the quick menu on the theme page resolves to " .. tostring(action)
      end
      action = Keys.resolve(PAGE_ON_THEME, "pageUp", stored)
      if action ~= "openView:menu" then
        return theme .. ": PAGE < set to the quick menu on the theme page resolves to " .. tostring(action)
      end
      local unbound = bindThemeKeys(layout, storeAll("none", "menu"))
      if unbound.pageDown ~= nil or unbound.pageUp ~= nil then
        return theme .. ": PAGE set to Nothing on the theme page is still bound"
      end
    end
  end)
  restore()
  if not ok then return "raised: " .. tostring(bad) end
  return bad
end

-- As the radio comes, both page keys open the quick menu over the theme itself: on Urban with its
-- page keys bound to one of its own pages (the real layout binds them), on a base layer that binds
-- nothing (as Default) and without a base layer (as a theme whose full screen is the quick menu).
-- The choice is the radio's, so it holds whatever the theme binds.
local function freshPageKeysCase(Keys, Views)
  local events = { pageDown = _G.EVT_VIRTUAL_NEXT_PAGE, pageUp = _G.EVT_VIRTUAL_PREV_PAGE }
  local layout, restore = loadThemeLayout("urban")
  local linkChoice = {}
  for i = 1, #(layout.KEYS or {}) do
    local entry = layout.KEYS[i]
    if entry.key == "pageDown" or entry.key == "pageUp" then linkChoice[entry.pref] = "link" end
  end
  local urbanKeys = bindThemeKeys(layout, linkChoice)
  restore()
  if urbanKeys.pageDown ~= "openView:urban_link" or urbanKeys.pageUp ~= "openView:urban_link" then
    return "urban: the PAGE keys bound to its link page are not bound (" .. tostring(urbanKeys.pageDown) .. ")"
  end
  local bad = {}
  for _, name in ipairs({ "pageDown", "pageUp" }) do
    for _, spec in ipairs({
      { theme = "urban", base = true, keys = urbanKeys },
      { theme = "default", base = true, keys = {} },
      { theme = "legacy", base = false, keys = {} },
    }) do
      -- Every theme and key is tried, so a failure names all of them rather than the first.
      local action, global = Keys.resolve({}, name, spec.keys)
      local w = newWidget(Views, spec.base)
      for k, v in pairs(spec.keys) do w._viewCtx.keys[k] = v end
      if action ~= "openView:menu" or global ~= true then
        bad[#bad + 1] = spec.theme .. " " .. name .. " resolves to " .. tostring(action)
          .. (global and " (radio-wide)" or " (theme)")
      elseif Views.key(w, events[name]) ~= true or Views.top(w) ~= "menu" then
        bad[#bad + 1] = spec.theme .. " " .. name .. " did not open the quick menu"
      elseif Views.key(w, events[name]) ~= true or Views.top(w) ~= nil then
        bad[#bad + 1] = spec.theme .. " a second " .. name .. " did not close the quick menu"
      end
    end
  end
  if #bad > 0 then
    return "with fresh preferences, expected the radio-wide quick menu: " .. table.concat(bad, "; ")
  end
end

local function keysPageCase(keysSrc, pageSrc)
  local page, rows, err = loadKeysPage(keysSrc, pageSrc)
  if page == nil then return "the Keys page did not load: " .. tostring(err) end
  local prefs = { dashboard = {} }
  local saved = 0
  local ctx = {
    preferences = prefs, x = 0, y = 0, w = 480, children = {},
    requestRebuild = function() end,
    savePreferences = function() saved = saved + 1; return true end,
  }
  page.onReload(ctx)
  page.build(ctx)
  if #rows ~= 5 then return "the page drew " .. #rows .. " key rows, expected 5" end
  local want = { "menu", "menu", "theme", "suite_tool", "menu" }
  for i = 1, 5 do
    if rows[i].selected ~= want[i] then
      return "row " .. i .. " shows " .. tostring(rows[i].selected) .. " with no preference, expected " .. want[i]
    end
  end
  -- SYS to Theme, PAGE > to Nothing; the rest stay on their defaults.
  rows[4].onSelect("theme")
  rows[1].onSelect("none")
  page.onSave(ctx)
  if saved ~= 1 then return "the page did not save" end
  local d = prefs.dashboard
  if d.key_sys ~= "theme" then return "SYS on Theme was stored as " .. tostring(d.key_sys) .. ", expected theme" end
  if d.key_page_down ~= "none" then return "PAGE > Nothing was not stored" end
  if d.key_tele ~= nil or d.key_page_up ~= nil or d.key_mdl ~= nil then
    return "a key left on its default was stored"
  end
  -- A stored default-equal value is dropped on the next save.
  prefs.dashboard.key_tele = "menu"
  page.onReload(ctx)
  page.onSave(ctx)
  if prefs.dashboard.key_tele ~= nil then return "TELE on its default stayed stored" end
  page.onClose()
end

-- The accounting stubs replace globals the other cases read (the event constants among them), so
-- the runtime case puts every global back as it found it; a later run starts from the same state.
local function runtimeCase(source, caseFn)
  local saved = {}
  for k, v in pairs(_G) do saved[k] = v end
  -- The stubs also wrap io/os functions in place and take a temporary card; both are undone here
  -- whatever the case answered, so a failing run leaves nothing behind for the next one.
  local ioOpen, osRemove, osRename = io.open, os.remove, os.rename
  local ok, result = pcall(caseFn, source)
  local stubs = _G.__keysTestStubs
  if stubs and type(stubs.releaseCard) == "function" then pcall(stubs.releaseCard) end
  io.open, os.remove, os.rename = ioOpen, osRemove, osRename
  for k in pairs(_G) do if saved[k] == nil then _G[k] = nil end end
  for k, v in pairs(saved) do _G[k] = v end
  if not ok then return "raised: " .. tostring(result) end
  return result
end

-- `source` with `from` replaced, and how often `from` occurs: a mutant is only built from an
-- anchor that occurs exactly once.
local function mutate(source, from, to)
  local count, at = 0, 1
  while true do
    local first, last = string.find(source, from, at, true)
    if first == nil then break end
    count, at = count + 1, last + 1
  end
  if count ~= 1 then return nil, count end
  local first, last = string.find(source, from, 1, true)
  return string.sub(source, 1, first - 1) .. to .. string.sub(source, last + 1), 1
end

-- A mutant counts as caught only where the case written for it goes red.
local function redIn(failures, caseId)
  for i = 1, #failures do
    if failures[i].case == caseId then return failures[i] end
  end
  return nil
end

local CASES = {
  {
    id = "absent and invalid choices fall back to the key's default",
    fn = function(Keys)
      if Keys.choice("unknown", "mdl") ~= "theme" then
        return "an invalid MDL choice did not resolve to Theme"
      end
      if Keys.choice({}, "pageDown") ~= "menu" or Keys.choice(nil, "pageUp") ~= "menu" then
        return "an invalid or absent PAGE choice did not resolve to the quick menu"
      end
      if Keys.choice(nil, "sys") ~= "suite_tool" or Keys.choice("unknown", "tele") ~= "menu" then
        return "an absent SYS/TELE choice did not resolve to its default"
      end
      if Keys.choice("theme", "sys") ~= "theme" then return "a stored Theme on SYS was not kept" end
    end,
  },
  {
    id = "SYS and TELE default to Main menu and Quick menu over the theme",
    fn = function(Keys)
      local action, global = Keys.resolve({}, "sys", { sys = "openView:x" })
      if action ~= "openTool" or not global then return "SYS default did not open the tool" end
      action, global = Keys.resolve({}, "tele", {})
      if action ~= "openView:menu" or not global then return "TELE default did not open the menu" end
      action, global = Keys.resolve({}, "mdl", { mdl = "openView:x" })
      if action ~= "openView:x" or global then return "MDL is not the theme's by default" end
    end,
  },
  {
    id = "a key on Theme does only what the theme binds",
    fn = function(Keys)
      local dashboard = { key_sys = "theme" }
      local themeKeys = { sys = "none" }
      local action, global = Keys.resolve(dashboard, "sys", themeKeys)
      if action ~= "none" or global then return "the theme's SYS binding did not apply" end
      action, global = Keys.resolve(dashboard, "sys", {})
      if action ~= nil or global then return "an unbound SYS on Theme resolved to " .. tostring(action) end
      if themeKeys.sys ~= "none" then return "resolution mutated a theme binding table" end
    end,
  },
  {
    id = "unbound Theme keys are consumed on the base without host fallback",
    fn = function(Keys, Views)
      local events = { pageDown = _G.EVT_VIRTUAL_NEXT_PAGE, pageUp = _G.EVT_VIRTUAL_PREV_PAGE,
        mdl = _G.EVT_MODEL_BREAK, sys = _G.EVT_SYS_BREAK, tele = _G.EVT_TELEM_BREAK }
      for _, entry in ipairs(Keys.KEYS) do
        local w = newWidget(Views)
        w.preferences.dashboard[entry.pref] = "theme"
        if w._viewBase == nil or Views.top(w) ~= nil then return "the base-layer fixture has a view on top" end
        local action, global = Keys.resolve(w.preferences.dashboard, entry.id, {})
        if action ~= nil or global then return entry.id .. " did not resolve to nothing" end
        local handled = Views.key(w, events[entry.id])
        if handled ~= true or Views.top(w) ~= nil then
          return "unbound " .. entry.id .. " changed the base view or was not consumed"
        end
      end
    end,
  },
  {
    id = "PAGE keys keep host navigation over views",
    fn = function(_, Views)
      for _, spec in ipairs({
        { name = "pageDown", event = _G.EVT_VIRTUAL_NEXT_PAGE },
        { name = "pageUp", event = _G.EVT_VIRTUAL_PREV_PAGE },
      }) do
        for _, binding in ipairs({ false, "none", "openView:menu" }) do
          local w = newWidget(Views)
          w.preferences.dashboard = { key_page_down = "theme", key_page_up = "theme" }
          w._viewCtx.keys[spec.name] = binding or nil
          Views.navigate(w, "openView:menu")
          if Views.top(w) ~= "menu" then return "the quick-menu fixture did not open" end
          if Views.key(w, spec.event) ~= true or Views.top(w) ~= nil then
            return spec.name .. " did not close the quick menu on top"
          end
          Views.navigate(w, "openView:battery_pick")
          if Views.top(w) ~= "battery_pick" then return "the other-view fixture did not open" end
          if Views.key(w, spec.event) ~= true or Views.top(w) ~= "menu" then
            return spec.name .. " did not open the quick menu over another view"
          end
          if Views.key(w, spec.event) ~= true or Views.top(w) ~= "battery_pick" then
            return spec.name .. " did not reveal the underlying view after closing the menu"
          end
          w._viewCtx.keys[spec.name] = "openView:battery_pick"
          if Views.key(w, spec.event) ~= true or Views.top(w) ~= nil then
            return spec.name .. " did not toggle its bound view on top"
          end
        end
      end
    end,
  },
  {
    id = "legacy themes forward all Theme keys to LVGL",
    fn = function(Keys, Views)
      local events = { pageDown = _G.EVT_VIRTUAL_NEXT_PAGE, pageUp = _G.EVT_VIRTUAL_PREV_PAGE,
        mdl = _G.EVT_MODEL_BREAK, sys = _G.EVT_SYS_BREAK, tele = _G.EVT_TELEM_BREAK }
      for _, entry in ipairs(Keys.KEYS) do
        for _, top in ipairs({ false, "menu", "battery_pick" }) do
          for _, binding in ipairs({ false, "none", "openView:menu" }) do
            local w = newWidget(Views, false)
            w.preferences.dashboard[entry.pref] = "theme"
            w._viewCtx.keys[entry.id] = binding or nil
            if top then Views.navigate(w, "openView:" .. top) end
            if w._viewBase ~= nil or Views.top(w) ~= (top or nil) then return "the legacy fixture is invalid" end
            if Views.key(w, events[entry.id]) ~= false or Views.top(w) ~= (top or nil) then
              return entry.id .. " on Theme was consumed or navigated without a base"
            end
          end
        end
      end
    end,
  },
  {
    id = "init keys follow ctx keys and precede nothing",
    fn = function(Keys, Views)
      local declared = { pageDown = "openView:menu", mdl = "none", sys = "none" }
      local ctxKeys = { pageDown = "none" }
      local onTheme = { key_page_down = "theme", key_page_up = "theme" }
      local action, global = Keys.resolve(onTheme, "pageDown", ctxKeys, declared)
      if action ~= "none" or global then return "ctx.keys did not win over init.keys" end
      action, global = Keys.resolve(onTheme, "pageDown", {}, declared)
      if action ~= "openView:menu" or global then return "init.keys did not precede nothing" end
      action, global = Keys.resolve(onTheme, "pageUp", {}, declared)
      if action ~= nil or global then return "a key absent from both tables did not resolve to nothing" end
      action, global = Keys.resolve({}, "sys", {}, declared)
      if action ~= "openTool" or not global then return "the global default did not win over init.keys" end
      action, global = Keys.resolve({ key_page_down = "none" }, "pageDown", {}, declared)
      if action ~= "none" or not global then return "an explicit choice did not win over init.keys" end
      local w = newWidget(Views)
      w.preferences.dashboard = onTheme
      w._declaredKeys = declared
      w._viewCtx.keys.pageDown = "none"
      if Views.key(w, _G.EVT_VIRTUAL_NEXT_PAGE) ~= true or Views.top(w) ~= nil then
        return "Views did not prefer ctx.keys"
      end
      w._viewCtx.keys.pageDown = nil
      if Views.key(w, _G.EVT_VIRTUAL_NEXT_PAGE) ~= true or Views.top(w) ~= "menu" then
        return "Views did not honour init.keys"
      end
      if Views.key(w, _G.EVT_VIRTUAL_NEXT_PAGE) ~= true or Views.top(w) ~= nil then
        return "the declared menu key did not toggle its view"
      end
      if declared.pageDown ~= "openView:menu" or ctxKeys.pageDown ~= "none" then
        return "resolution mutated a theme binding table"
      end
    end,
  },
  {
    id = "a theme view stays open through a theme reload",
    fn = function()
      return runtimeCase(runtimeSource, runtimeReloadWindowCaseIn)
    end,
  },
  {
    id = "Runtime reads and clears the init keys table",
    fn = function()
      return runtimeCase(runtimeSource, runtimeDeclaredKeysCaseIn)
    end,
  },
  {
    id = "default TELE acts before the first build and toggles the menu",
    fn = function(_, Views)
      local w = newWidget(Views)
      w._viewCtx = nil
      local handled = Views.key(w, _G.EVT_TELEM_BREAK)
      if handled ~= true or Views.top(w) ~= "menu" then return "default TELE did not open the menu" end
      handled = Views.key(w, _G.EVT_TELEM_BREAK)
      if handled ~= true or Views.top(w) ~= nil then return "default TELE did not close the menu" end
    end,
  },
  {
    id = "Theme keys yield while another view is on top",
    fn = function(_, Views)
      for _, spec in ipairs({
        { name = "mdl", pref = "key_mdl", event = _G.EVT_MODEL_BREAK },
        { name = "sys", pref = "key_sys", event = _G.EVT_SYS_BREAK },
        { name = "tele", pref = "key_tele", event = _G.EVT_TELEM_BREAK },
      }) do
        for _, binding in ipairs({ false, "none" }) do
          local w = newWidget(Views)
          w.preferences.dashboard[spec.pref] = "theme"
          w._viewCtx.keys[spec.name] = binding or nil
          Views.navigate(w, "openView:menu")
          local handled = Views.key(w, spec.event)
          if handled ~= false or Views.top(w) ~= "menu" then return "Theme " .. spec.name .. " consumed the top view" end
        end
      end
    end,
  },
  {
    id = "explicit Nothing is consumed on top",
    fn = function(_, Views)
      local w = newWidget(Views)
      w.preferences.dashboard.key_sys = "none"
      Views.navigate(w, "openView:menu")
      local handled = Views.key(w, _G.EVT_SYS_BREAK)
      if handled ~= true or Views.top(w) ~= "menu" then return "explicit Nothing was not consumed" end
    end,
  },
  {
    id = "explicit menu toggles the menu",
    fn = function(_, Views)
      local w = newWidget(Views)
      w.preferences.dashboard.key_sys = "menu"
      Views.navigate(w, "openView:menu")
      local handled = Views.key(w, _G.EVT_SYS_BREAK)
      if handled ~= true or Views.top(w) ~= nil then return "explicit menu did not close the menu" end
    end,
  },
  {
    id = "without a theme base only radio-wide choices act",
    fn = function(_, Views)
      local theme = newWidget(Views, false)
      if theme._viewBase ~= nil then return "the no-base fixture has a base" end
      if Views.key(theme, _G.EVT_MODEL_BREAK) ~= false then return "MDL on Theme acted without a base" end
      if Views.key(theme, _G.EVT_TELEM_BREAK) ~= true then return "default TELE did not act without a base" end
      local global = newWidget(Views, false)
      global.preferences.dashboard.key_mdl = "none"
      if Views.key(global, _G.EVT_MODEL_BREAK) ~= true then return "explicit Nothing did not act without a base" end
      global.preferences.dashboard.key_tele = "theme"
      if Views.key(global, _G.EVT_TELEM_BREAK) ~= false then return "TELE on Theme acted without a base" end
    end,
  },
  {
    id = "short RTN closes a view without leaving fullscreen",
    fn = function(_, Views)
      local w = newWidget(Views)
      Views.navigate(w, "openView:menu")
      local handled, exited = Views.key(w, _G.EVT_VIRTUAL_EXIT)
      if handled ~= true or exited == true or Views.top(w) ~= nil then
        return "short RTN did not keep Back/Close ownership"
      end
    end,
  },
  {
    id = "unknown events are left to the host",
    fn = function(_, Views)
      if Views.key(newWidget(Views), 999) ~= false then return "an unknown event was consumed" end
    end,
  },
  {
    id = "the Keys page shows defaults and stores only deviations",
    fn = function(Keys)
      return keysPageCase(Keys.__source, pageSource)
    end,
  },
  {
    id = "a theme's PAGE choice of the quick menu is a binding",
    fn = function(Keys)
      return themePageKeysCase(Keys)
    end,
  },
  {
    id = "fresh PAGE keys open the quick menu on every theme",
    fn = function(Keys, Views)
      return freshPageKeysCase(Keys, Views)
    end,
  },
  {
    id = "fullscreen exit cancels a pending fullscreen job",
    fn = function()
      return runtimeCase(runtimeSource, runtimeCancellationCaseIn)
    end,
  },
}

local function runChecks(source, quiet, pageSrc)
  local Keys, Views, err = loadPair(source)
  if Keys == nil then return { { case = "load modules", detail = tostring(err) } }, 0 end
  Keys.__source = source
  local realPage = pageSource
  if pageSrc then pageSource = pageSrc end
  local failures, passes = {}, 0
  for i = 1, #CASES do
    local case = CASES[i]
    local ok, result = pcall(case.fn, Keys, Views)
    local bad
    if not ok then bad = "raised: " .. tostring(result) else bad = result end
    if bad == nil then passes = passes + 1 else failures[#failures + 1] = { case = case.id, detail = bad } end
    if verbose and not quiet then
      print(string.format("%s %-48s %s", bad == nil and "PASS" or "FAIL", case.id, bad or ""))
    end
  end
  pageSource = realPage
  return failures, passes
end

if selfTest then
  local real = runChecks(keysSource, true)
  local again = runChecks(keysSource, true)
  if #real > 0 or #again > 0 then
    print("SELF-TEST FAILED: the checks are red on the unbroken tree")
    os.exit(1)
  end
  local mutant, count = mutate(keysSource, "return ACTIONS[choice], true", "return ACTIONS[choice], false")
  if count ~= 1 then
    print("SELF-TEST FAILED: the explicit-choice branch was found " .. count .. " times, expected once")
    os.exit(1)
  end
  local failures = runChecks(mutant, true)
  local hit = redIn(failures, "SYS and TELE default to Main menu and Quick menu over the theme")
  if hit == nil or #failures == 0 then
    print("SELF-TEST FAILED: treating explicit choices as Theme stayed green")
    os.exit(1)
  end
  print("(self-test) explicit-choice mutant went red: " .. hit.case .. ": " .. hit.detail)
  local noDefault, defaultCount = mutate(keysSource, 'default = "suite_tool"', 'default = "theme"')
  if defaultCount ~= 1 then
    print("SELF-TEST FAILED: the SYS default was found " .. defaultCount .. " times, expected once")
    os.exit(1)
  end
  failures = runChecks(noDefault, true)
  hit = redIn(failures, "absent and invalid choices fall back to the key's default")
  if hit == nil then
    print("SELF-TEST FAILED: dropping the SYS default stayed green")
    os.exit(1)
  end
  print("(self-test) no-default mutant went red: " .. hit.case .. ": " .. hit.detail)
  local noPageDefault, pageCount = mutate(keysSource, '{ id = "pageDown", pref = "key_page_down", default = "menu" }',
    '{ id = "pageDown", pref = "key_page_down", default = "theme" }')
  if pageCount ~= 1 then
    print("SELF-TEST FAILED: the PAGE > default was found " .. pageCount .. " times, expected once")
    os.exit(1)
  end
  failures = runChecks(noPageDefault, true)
  hit = redIn(failures, "fresh PAGE keys open the quick menu on every theme")
  if hit == nil then
    print("SELF-TEST FAILED: leaving PAGE > on Theme by default stayed green")
    os.exit(1)
  end
  print("(self-test) PAGE-default mutant went red: " .. hit.case .. ": " .. hit.detail)
  -- A theme layout that ignores the stored choice and binds each row's default instead.
  local storedRead = "local id = Common.option(state, entry.pref, KEY_ACTION_IDS, entry.default)"
  for _, theme in ipairs(SHIPPED_KEY_THEMES) do
    local found
    local function ignoreStored(src)
      local out, n = mutate(src, storedRead, "local id = entry.default")
      found = n
      return out or src
    end
    local Keys = loadPair(keysSource)
    local themeBad = themePageKeysCase(Keys, function(src, which)
      if which ~= theme then return src end
      return ignoreStored(src)
    end)
    if found ~= 1 then
      print("SELF-TEST FAILED: the stored-choice read was found " .. tostring(found) .. " times in " .. theme .. ", expected once")
      os.exit(1)
    end
    -- The Quick menu half must go red itself: the Nothing half alone would catch this mutant too,
    -- and would hide a Quick menu assertion that passes whatever is stored.
    if themeBad == nil or not string.find(themeBad, theme .. ": PAGE > set to the quick menu", 1, true) then
      print("SELF-TEST FAILED: a " .. theme .. " layout that ignores stored key choices stayed green")
      os.exit(1)
    end
    print("(self-test) ignore-stored mutant went red for " .. theme .. ": " .. themeBad)
  end
  local oldSave, saveCount = mutate(pageSource, "if value == entry.default then value = nil end",
    'if value == "theme" then value = nil end')
  if saveCount ~= 1 then
    print("SELF-TEST FAILED: the page's default check was found " .. saveCount .. " times, expected once")
    os.exit(1)
  end
  failures = runChecks(keysSource, true, oldSave)
  hit = redIn(failures, "the Keys page shows defaults and stores only deviations")
  if hit == nil or #failures ~= 1 then
    print("SELF-TEST FAILED: storing Theme as absent stayed green, or turned other cases red")
    os.exit(1)
  end
  print("(self-test) Theme-as-absent page mutant went red: " .. hit.case .. ": " .. hit.detail)
  local exitGuard = "    if event == nil then"
  local runtimeMutant, runtimeCount = mutate(runtimeSource, exitGuard, "    if false and event == nil then")
  if runtimeCount ~= 1 then
    print("SELF-TEST FAILED: the fullscreen-exit guard was found " .. runtimeCount .. " times, expected once")
    os.exit(1)
  end
  local runtimeBad = runtimeCase(runtimeMutant, runtimeCancellationCaseIn)
  if runtimeBad == nil then
    print("SELF-TEST FAILED: disabling early fullscreen-exit cleanup stayed green")
    os.exit(1)
  end
  print("(self-test) fullscreen-exit mutant went red: " .. runtimeBad)
  local reloadGuard = "if self.theme ~= nil and (modeOf == nil"
  local reloadMutant, reloadCount = mutate(runtimeSource, reloadGuard, "if (modeOf == nil")
  if reloadCount ~= 1 then
    print("SELF-TEST FAILED: the reload-window guard was found " .. reloadCount .. " times, expected once")
    os.exit(1)
  end
  local reloadBad = runtimeCase(reloadMutant, runtimeReloadWindowCaseIn)
  if reloadBad == nil then
    print("SELF-TEST FAILED: taking the fullscreen mode without a theme stayed green")
    os.exit(1)
  end
  print("(self-test) reload-window mutant went red: " .. reloadBad)
  print("SELF-TEST PASSED: resolver, default, page-storage, early-exit and reload-window regressions are detected")
  os.exit(0)
end

print(string.format("%d cases on fullscreen key bindings", #CASES))
local failures, passes = runChecks(keysSource, false)
if #failures > 0 then
  for _, failure in ipairs(failures) do print("FAIL: " .. failure.case .. ": " .. failure.detail) end
  print(string.format("%d case(s) failed, %d passed", #failures, passes))
  os.exit(1)
end
print(string.format("%d cases, 0 failures", passes))
