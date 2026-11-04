-- Checks that the dashboard's preferences reload reads the radio-wide settings file once, and that
-- the language it leaves behind is the one the locale resolution gives, offline, with desktop
-- Lua 5.3, from the repository root:
--
--   lua5.3 bin/dashboard/verify_reload_locale_once.lua
--   lua5.3 bin/dashboard/verify_reload_locale_once.lua --verbose
--
-- The reload loads the settings through lib/preferences.lua and then drops the language memo of
-- lib/system_locale.lua, and the widget's i18n context built right after it resolved the language
-- again -- step 1 of which reads the same file a second time. The reload now hands the language
-- the settings in hand resolve to over to the memo, so the context is built without that read.
--
-- The real widgets/dashboard/runtime.lua, lib/preferences.lua, lib/config_store.lua and
-- lib/system_locale.lua run against the accounting stubs (bin/accounting/stubs). The settings are
-- written through the suite's own writer, and the reload is the one a widget pass runs: the
-- settings file's stamp moves, a second passes, and the pass finds it. Every open of the settings
-- file for reading during that call is counted, at the path the suite asks for.
--
-- Cases, each a fresh widget on a fresh card:
--   set          English chosen, then German: the reload answers German
--   auto-source  Automatic, run from source with the radio in German: the radio's language
--   auto-pack    Automatic on a packaged German build with the radio in English: the package's
--   cleared      German chosen, then Automatic again with the radio in English: English, and the
--                generation the theme memos watch has moved
--   default      Automatic, from source, with a radio language the suite has no texts for: a
--                caller asking with another default after the reload gets its own default, not the
--                answer handed over for the reload's
-- Each expects one read of the settings file in the reload and the language a fresh resolution
-- gives. Exit status: 0 green, 1 failed expectations, 2 invalid arguments.

-- luacheck: globals io

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end

local verbose = false
for i = 1, #arg do
  if arg[i] == "--verbose" then
    verbose = true
  else
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_reload_locale_once.lua [--verbose]\n")
    os.exit(2)
  end
end

local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()

local LOCALE_PATH = ROOT .. "/src/rfsuite/lib/system_locale.lua"

local failures, checks = 0, 0
local function expect(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function upvalue(fn, name)
  for i = 1, 255 do
    local key, value = debug.getupvalue(fn, i)
    if not key then break end
    if key == name then return value end
  end
  error("missing production upvalue: " .. name)
end

-- The settings file for reading, at either spelling the suite uses for it.
local function isSettingsFile(path)
  if type(path) ~= "string" then return false end
  return string.match(path, "rfsuite%.user/preferences%.lua$") ~= nil
end

-- What a packaged build of the given locale carries: the packager writes the locale over the marker
-- (.vscode/scripts/resolve_i18n_tags.py, every occurrence); the one that decides is BAKED's value.
local function loadLocaleModule(packagedAs)
  local f = assert(io.open(LOCALE_PATH, "r"))
  local src = f:read("a")
  f:close()
  if packagedAs then
    local replaced, n = string.gsub(src, 'local BAKED = "@i18n_language@"',
      'local BAKED = "' .. packagedAs .. '"', 1)
    assert(n == 1, "the packaged marker is no longer in lib/system_locale.lua")
    src = replaced
  end
  return assert(load(src, "=system_locale", "t"))()
end

local realOpen = io.open

-- One fresh widget on a fresh card. `radio` is the language getGeneralSettings answers,
-- `packaged` the locale of a packaged build (nil: source / simulator), `language` the choice in
-- the settings when the widget comes up (nil: Automatic).
local function newWorld(case)
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  Stubs.clearCard()

  -- The module registers itself in _G and answers that table on every later load, so a world
  -- that kept it would run every case on the first case's module.
  _G.__rfsuite_system_locale_module = nil
  if case.packaged then loadLocaleModule(case.packaged) end

  _G.getGeneralSettings = function()
    return { battWarn = 6.6, battMin = 6.0, battMax = 8.4, imperial = 0,
      language = case.radio, voice = "en", gtimer = 0 }
  end

  local world = { opens = 0, counting = false, saves = 0, contexts = {} }

  io.open = function(path, mode)
    if world.counting and (mode == nil or string.find(mode, "r", 1, true)) and isSettingsFile(path) then
      world.opens = world.opens + 1
    end
    return realOpen(path, mode)
  end

  -- Both preference files answer one stat, and a save moves its time: the reload sees the
  -- radio-wide file change and reads that file (there is no board, so no per-model one).
  Stubs.prefsStat = { size = 100, time = { year = 2026, mon = 1, day = 1, hour = 12, min = 0, sec = 0 } }

  local Preferences = _G.rfsuite.require("lib/preferences.lua")
  function world.save(language)
    local prefs = Preferences.defaults()
    prefs.localizations = prefs.localizations or {}
    prefs.localizations.language = language
    assert(Preferences.save(prefs), "settings write")
    world.saves = world.saves + 1
    Stubs.prefsStat = { size = 100 + world.saves,
      time = { year = 2026, mon = 1, day = 1, hour = 12, min = 0, sec = world.saves } }
  end
  world.save(case.language)

  local Msp = _G.rfsuite.require("tasks/msp/runtime.lua")
  Msp.isFblConnected = function() return false end

  local Runtime = _G.rfsuite.require("widgets/dashboard/runtime.lua")
  local w = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  world.w = w
  world.reloadPrefs = upvalue(w.reload, "reloadPreferencesIfNeeded")
  world.locale = _G.__rfsuite_system_locale_module
  assert(type(world.locale) == "table", "the locale module is not registered")

  -- The language every i18n context is built for, as the widget asks for it, and the last context
  -- built, which the widget has to take.
  local I18n = upvalue(upvalue(world.reloadPrefs, "buildI18nContext"), "I18nModule")
  local new = I18n.new
  I18n.new = function(locale, ...)
    world.contexts[#world.contexts + 1] = locale
    local ctx = new(locale, ...)
    world.lastCtx = ctx
    return ctx
  end
  world.restoreI18n = function() I18n.new = new end

  -- The first look at the stamps is a baseline, never a reload.
  for _ = 1, 30 do Stubs.tick() end
  world.reloadPrefs(w, false, false)
  return world
end

-- A save, the second the widget waits before it looks again, and the pass that finds it.
local function reloadAfterSave(world, language)
  world.save(language)
  for _ = 1, 30 do Stubs.tick() end
  world.opens = 0
  world.contexts = {}
  world.lastCtx = nil
  world.counting = true
  local ran = world.reloadPrefs(world.w, false, false)
  world.counting = false
  return ran
end

local function finish(world)
  world.restoreI18n()
  io.open = realOpen
end

local function runCase(name, case, saveAs, expected, extra)
  local world = newWorld(case)
  local generation = world.locale.localeGeneration
  local ran = reloadAfterSave(world, saveAs)
  -- Read before the fresh resolution below, whose own invalidation moves it as well.
  local moved = world.locale.localeGeneration - generation
  local opens = world.opens
  local built = world.contexts[#world.contexts]
  local adopted = type(world.lastCtx) == "table" and world.w.i18n == world.lastCtx
  local answer = world.locale.resolveSystemLanguage("en")

  -- What the resolution gives with nothing remembered, read on the same card after the reload.
  world.locale.invalidateLanguage()
  local fresh = world.locale.resolveSystemLanguage("en")

  if verbose then
    print(string.format("  %-12s ran=%s opens=%d context=%s answer=%s fresh=%s", name, tostring(ran),
      opens, tostring(built), tostring(answer), tostring(fresh)))
  end
  expect(ran == true, name .. ": the reload ran", tostring(ran))
  expect(opens == 1, name .. ": the settings file is read once in the reload", tostring(opens))
  expect(fresh == expected, name .. ": a fresh resolution gives the expected language",
    tostring(fresh) .. " vs " .. tostring(expected))
  expect(built == expected, name .. ": the context is built for that language", tostring(built))
  expect(adopted, name .. ": the widget takes the context the reload built", tostring(adopted))
  expect(answer == expected, name .. ": the resolution after the reload answers it", tostring(answer))
  expect(moved == 1, name .. ": the reload moved the locale generation once", tostring(moved))
  if extra then extra(world) end
  finish(world)
end

-- English chosen, then German.
runCase("set", { radio = "EN", language = "en" }, "de", "de")

-- Automatic, from source, the radio in German: step 2b.
runCase("auto-source", { radio = "DE" }, nil, "de")

-- Automatic, packaged German, the radio in English: step 2a.
runCase("auto-pack", { radio = "EN", packaged = "de" }, nil, "de")

-- German chosen, then Automatic again with the radio in English.
runCase("cleared", { radio = "EN", language = "de" }, nil, "en")

-- Automatic, from source, a radio language without texts: step 3, the caller's default. The
-- reload asks with "en"; a caller asking with "de" afterwards must get "de".
runCase("default", { radio = "FR" }, nil, "en", function(w)
  -- A second reload leaves its answer in the memo again; a caller with another default asks
  -- inside the memo's window.
  local again = reloadAfterSave(w, nil)
  local other = w.locale.resolveSystemLanguage("de")
  if verbose then print("  default      second reload ran=" .. tostring(again) .. " other default=" .. tostring(other)) end
  expect(again == true, "default: the second reload ran", tostring(again))
  expect(other == "de", "default: a caller with another default gets its own", tostring(other))
end)

Stubs.releaseCard()
print(string.format("verify_reload_locale_once: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
