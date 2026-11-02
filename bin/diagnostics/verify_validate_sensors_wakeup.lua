-- Run the real Validate Sensors page with stubbed radio APIs and a scripted clock.
--
-- The page compares the flight controller's telemetry slot list against what the radio
-- receives. Its wakeup runs on every pass the page is open, and inside the tool opened from
-- the dashboard every pass is counted against the widget's instruction limit. What this
-- checks:
--   * a wakeup that sees no new slot configuration and is not the 0.8 s row refresh does not
--     walk the 40 telemetry slots;
--   * a slot configuration that changes still shows on the next wakeup, and a sensor that
--     stops arriving still shows within the 0.8 s refresh;
--   * RF Status, which loads its own copy of the page and asks it for a passive summary, still
--     sees the current configuration;
--   * a page that was closed and opened again keeps doing all of this.
-- The slot reads are counted on the configuration table itself, so the check does not depend
-- on how the page arranges its work.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local pagePath = "src/rfsuite/app/pages/tools/diagnostics/validate_sensors/page.lua"
local prefix = "/SCRIPTS/TOOLS/rfsuite-core/"

-- Forty distinct sensors the page's catalogue knows, one per slot: the most work a slot list
-- can ask for.
local FULL = {
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
  13, 14, 15, 17, 18, 19, 20, 21, 22, 23,
  24, 25, 26, 27, 28, 30, 31, 32, 33, 36,
  41, 42, 43, 44, 45, 46, 47, 48, 49, 50
}
local SOURCES = {
  [3] = "Vbat", [4] = "Curr", [5] = "Capa", [6] = "Bat%", [7] = "Cel#", [8] = "Vcel",
  [9] = "Cels", [10] = "Ctrl", [11] = "CPtc", [12] = "CRol", [13] = "CYaw", [14] = "CCol",
  [15] = "Thr", [17] = "EscV", [18] = "EscI", [19] = "EscC", [20] = "EscR", [21] = "EscP",
  [22] = "Esc%", [23] = "EscT", [24] = "BecT", [25] = "BecV", [26] = "BecI", [27] = "EscF",
  [28] = "Esc#", [30] = "Es2V", [31] = "Es2I", [32] = "Es2C", [33] = "Es2R", [36] = "Es2T",
  [41] = "Es2#", [42] = "Vesc", [43] = "Vbec", [44] = "Vbus", [45] = "Vmcu", [46] = "Iesc",
  [47] = "Ibec", [48] = "Ibus", [49] = "Imcu", [50] = "Tesc"
}

local radio = {}       -- what the radio has: sensor name -> { live = bool }
local slotReads = 0    -- reads of a telem_sensor_slot_N field, on any configuration table
local rebuilds = 0
local clock = 1000     -- getTime() ticks, 10 ms each

local function makeConfig(ids)
  local slots = {}
  for i = 1, 40 do
    slots["telem_sensor_slot_" .. tostring(i)] = ids[i] or 0
  end
  return setmetatable({}, {
    __index = function(_, key)
      if type(key) == "string" and string.sub(key, 1, 18) == "telem_sensor_slot_" then
        slotReads = slotReads + 1
      end
      return slots[key]
    end
  })
end

local function radioHas(ids)
  radio = {}
  for i = 1, #ids do
    radio[SOURCES[ids[i]]] = { live = true }
  end
end

local session = {}
-- The card roots, as lib/require.lua publishes them before any page is loaded.
_G.rfsuite = {
  palette = { ok = 1, caution = 2, error = 3, text = 4, accent = 5 },
  session = session,
  paths = dofile("src/rfsuite/lib/paths.lua")
}
_G.SMLSIZE = 0
_G.RIGHT = 0
_G.getTime = function() return clock end
_G.getFieldInfo = function(name)
  if radio[name] then return { id = 1 } end
  return nil
end
_G.getSourceValue = function(name)
  local sensor = radio[name]
  if not sensor then return nil end
  return 1, sensor.live
end

-- The MSP queue keeps what the page asks for, so a scenario can answer it.
local queued = {}
local queue = { add = function(_, request) queued[#queued + 1] = request; return true end }
-- The real TELEMETRY_CONFIG parser: every writer of the configuration stores what it returns.
local TelemetryApi = assert(loadfile("src/rfsuite/tasks/msp/api/telemetry_config.lua"))()
local modules = {
  ["app/pages/settings/common.lua"] = {
    pageT = function() return function(_, _, fallback) return fallback end end
  },
  ["tasks/msp/runtime.lua"] = { getState = function() return { queue = queue } end },
  ["tasks/msp/api/telemetry_config.lua"] = TelemetryApi,
  ["ui/loading_overlay.lua"] = { append = function() end }
}
_G.loadScript = function(path)
  assert(string.sub(path, 1, #prefix) == prefix, "unexpected module prefix: " .. path)
  local name = string.sub(path, #prefix + 1)
  local module = assert(modules[name], "unexpected module: " .. path)
  return function() return module end
end

local function loadPage()
  return assert(loadfile(pagePath))()
end

local ctx = {
  x = 0, y = 0, w = 480, h = 800,
  requestRebuild = function() rebuilds = rebuilds + 1 end
}
local function build(page)
  ctx.children = {}
  page.build(ctx)
  return #ctx.children
end

-- One wakeup `ticks` after the previous one; answers how many slot fields it read.
local function wakeup(page, ticks)
  clock = clock + (ticks or 0)
  local before = slotReads
  page.wakeup()
  return slotReads - before
end

-- Open the page and let it settle: the first wakeup takes the configuration in, the next one
-- runs the first row refresh (the page starts with its refresh due). The rebuild count starts
-- from there. Answers the time of that refresh, in ticks.
local function openSettled(page)
  build(page)
  wakeup(page, 2)
  wakeup(page, 2)
  rebuilds = 0
  return clock
end

local function scenario(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    equal("error: " .. tostring(err), "completed", name .. " scenario")
  end
end

scenario("quiet wakeups", function()
  session.telemetry_config = makeConfig(FULL)
  radioHas(FULL)
  local page = loadPage()
  local refreshedAt = openSettled(page)
  -- Fifteen wakeups inside the 0.8 s window, nothing changed: no slot is read.
  local quiet = 0
  for _ = 1, 15 do quiet = quiet + wakeup(page, 5) end
  equal(clock - refreshedAt, 75, "quiet window ends before the refresh is due")
  equal(quiet, 0, "wakeups between two row refreshes read no slot")
  -- The refresh itself still runs once 0.8 s have passed.
  equal(wakeup(page, 10), 40, "the 0.8 s row refresh walks the slots once")
  equal(rebuilds, 0, "nothing changed, nothing rebuilt")
  page.closePage()
end)

scenario("changed configuration", function()
  rebuilds = 0
  session.telemetry_config = makeConfig(FULL)
  radioHas(FULL)
  local page = loadPage()
  openSettled(page)
  wakeup(page, 5)
  -- The flight controller now sends ten sensors instead of forty (a save on the Telemetry page,
  -- or the read on connect). The page must show that on the very next wakeup, not at the next
  -- refresh.
  local ten = {}
  for i = 1, 10 do ten[i] = FULL[i] end
  session.telemetry_config = makeConfig(ten)
  wakeup(page, 5)
  equal(rebuilds, 1, "a new slot configuration rebuilds on the next wakeup")
  equal(build(page), 30, "the rebuilt page shows the ten configured sensors")
  -- And the configuration going away also shows at once.
  rebuilds = 0
  session.telemetry_config = nil
  wakeup(page, 5)
  equal(rebuilds, 1, "a cleared slot configuration rebuilds on the next wakeup")
  page.closePage()
end)

scenario("same count, different sensors", function()
  rebuilds = 0
  session.telemetry_config = makeConfig(FULL)
  radioHas(FULL)
  local page = loadPage()
  openSettled(page)
  wakeup(page, 5)
  -- Forty slots again, two of them exchanged: the count holds and the slot list changes, so a
  -- check that compared only the count would miss it.
  local swapped = {}
  for i = 1, #FULL do swapped[i] = FULL[i] end
  swapped[1], swapped[2] = FULL[2], FULL[1]
  session.telemetry_config = makeConfig(swapped)
  wakeup(page, 5)
  equal(rebuilds, 1, "a changed slot list with the same count rebuilds on the next wakeup")
  page.closePage()
end)

scenario("the page's own read", function()
  -- The page notices a new configuration by the table being a different one, which holds as
  -- long as every writer stores what the parser returns. Here the parser is the real one, fed
  -- the reply the page itself asked for.
  rebuilds = 0
  queued = {}
  session.telemetry_config = nil
  local ten = {}
  for i = 1, 10 do ten[i] = FULL[i] end
  radioHas(ten)
  local reply = {}
  for i = 1, 12 do reply[i] = 0 end
  for i = 1, 40 do reply[12 + i] = ten[i] or 0 end
  local first, second = TelemetryApi.parse(reply), TelemetryApi.parse(reply)
  equal(type(first) == "table" and type(second) == "table" and first ~= second, true,
    "the parser answers a new table on every reply")
  local page = loadPage()
  build(page)
  equal(#queued, 1, "with no configuration stored, opening the page asks for one")
  wakeup(page, 2)
  queued[1].processReply(nil, reply)
  rebuilds = 0
  wakeup(page, 2)
  equal(rebuilds, 1, "the configuration the page read shows on the next wakeup")
  equal(build(page), 30, "the rebuilt page shows the ten sensors the reply names")
  page.closePage()
end)

scenario("sensor stops arriving", function()
  rebuilds = 0
  session.telemetry_config = makeConfig(FULL)
  radioHas(FULL)
  local page = loadPage()
  openSettled(page)
  radio.Vbat.live = false
  for _ = 1, 15 do wakeup(page, 5) end
  equal(rebuilds, 0, "a sensor gone quiet is not shown before the 0.8 s refresh")
  for _ = 1, 2 do wakeup(page, 5) end
  equal(rebuilds, 1, "a sensor gone quiet shows at the first wakeup after 0.8 s")
  page.closePage()
end)

scenario("RF Status summary", function()
  -- RF Status loads its own copy of the page and only ever asks it for a passive summary.
  session.telemetry_config = makeConfig(FULL)
  radioHas(FULL)
  local page = loadPage()
  local summary = page.getValidationSummary({ passive = true })
  equal(summary.total, 40, "passive summary counts the configured sensors")
  equal(summary.ok, 40, "passive summary counts the live sensors")
  local ten = {}
  for i = 1, 10 do ten[i] = FULL[i] end
  session.telemetry_config = makeConfig(ten)
  radio.Vbat.live = false
  summary = page.getValidationSummary({ passive = true })
  equal(summary.total, 10, "passive summary follows a new slot configuration")
  equal(summary.ok, 9, "passive summary follows a sensor gone quiet")
end)

scenario("closed and opened again", function()
  rebuilds = 0
  session.telemetry_config = makeConfig(FULL)
  radioHas(FULL)
  local page = loadPage()
  openSettled(page)
  page.closePage()
  -- The module stays cached when the page is left; the next open uses the same instance.
  local ten = {}
  for i = 1, 10 do ten[i] = FULL[i] end
  session.telemetry_config = makeConfig(ten)
  equal(build(page), 30, "reopened page shows the configuration it opens with")
  wakeup(page, 2)
  local quiet = 0
  wakeup(page, 2)
  for _ = 1, 15 do quiet = quiet + wakeup(page, 5) end
  equal(quiet, 0, "reopened page: wakeups between refreshes read no slot")
  rebuilds = 0
  session.telemetry_config = makeConfig(FULL)
  wakeup(page, 5)
  equal(rebuilds, 1, "reopened page: a new slot configuration rebuilds on the next wakeup")
  page.closePage()
end)

if failures > 0 then
  print(string.format("validate sensors wakeup: %d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("validate sensors wakeup: %d checks passed", checks))
