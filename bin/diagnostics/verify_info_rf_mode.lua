-- Run the real Info page and shared RF rate decoder with stubbed radio APIs and CRSF input.
--
-- The stubbed module answers a device ping only when a scenario says so, the way a radio does:
-- the ping goes out with the first build and the answer arrives on a later pass. Expected rate
-- names are written out from ExpressLRS's tables rather than read from lib/link_rates.lua, so a
-- wrong row there fails here too.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local pagePath = "src/rfsuite/app/pages/tools/diagnostics/info/page.lua"
local prefix = "/SCRIPTS/TOOLS/rfsuite-core/"
local FRAME_DEVICE_PING, FRAME_DEVICE_INFO = 0x28, 0x29

-- What the stubs see: the RFMD reading, whether the sensor is live, the 0x29 answers waiting to
-- be popped, the pings sent, page rebuild requests and how often link_rates.lua was loaded.
local link = {}
local function resetLink(mode)
  link.mode = mode
  link.live = true
  link.answers = {}
  link.pings = 0
  link.rebuilds = 0
  link.rateLoads = 0
end

-- Device-information payload: destination, transmitter origin, name + NUL, serial, hardware
-- version, software version (0, major, minor, revision), parameter count.
local function deviceInfo(generation, serial)
  serial = serial or { 0x45, 0x4C, 0x52, 0x53 }
  return {
    0xEA, 0xEE, 84, 88, 0,
    serial[1], serial[2], serial[3], serial[4],
    0, 0, 0, 0,
    0, generation, 0, 0,
    0
  }
end

local function answer(generation, serial)
  link.answers[#link.answers + 1] = deviceInfo(generation, serial)
end

local rates = assert(loadfile("src/rfsuite/lib/link_rates.lua"))()
local crsf = {
  popFrame = function(frameType)
    assert(frameType == FRAME_DEVICE_INFO, "unexpected CRSF frame request")
    return table.remove(link.answers, 1)
  end
}
local modules = {
  ["lib/version.lua"] = {},
  ["tasks/msp/runtime.lua"] = { getState = function() return {} end },
  ["app/pages/lib/async_load_ui.lua"] = {},
  ["lib/link_rates.lua"] = rates,
  ["lib/crsf.lua"] = crsf
}

_G.rfsuite = { palette = {} }
_G.SMLSIZE = 0
_G.RIGHT = 0
_G.getSourceValue = function(name)
  if name == "RFMD" and link.mode ~= nil then return link.mode, link.live end
  return nil, false
end
_G.crossfireTelemetryPush = function(frameType, payload)
  assert(frameType == FRAME_DEVICE_PING, "unexpected CRSF frame sent")
  assert(payload[1] == 0xEE and payload[2] == 0xEA, "unexpected ping addresses")
  link.pings = link.pings + 1
  return true
end
_G.loadScript = function(path)
  assert(string.sub(path, 1, #prefix) == prefix, "unexpected module prefix: " .. path)
  local name = string.sub(path, #prefix + 1)
  local module = assert(modules[name], "unexpected module: " .. path)
  if name == "lib/link_rates.lua" then link.rateLoads = link.rateLoads + 1 end
  return function() return module end
end

local function loadPage()
  return assert(loadfile(pagePath))()
end

local function readRows(page)
  local children = {}
  -- A disconnected MSP runtime prevents unrelated live-load work. RFMD remains live
  -- through the sensor stub, so the public build path still calls readLiveRfInfo.
  page.build({
    children = children, x = 0, y = 0, w = 480, h = 800,
    requestRebuild = function() link.rebuilds = link.rebuilds + 1 end
  })
  local mode, band
  for i, child in ipairs(children) do
    if child.text == "RF Mode" then mode = children[i + 1].text end
    if child.text == "RF Band" then band = children[i + 1].text end
  end
  return assert(mode, "RF Mode row missing"), assert(band, "RF Band row missing")
end

-- Keep every scenario inside the error boundary so an older implementation reports a failure
-- and the remaining scenarios still run.
local function scenario(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    equal("error: " .. tostring(err), "completed", name .. " scenario")
  end
end

-- The first build pings and shows dashes; the answer arrives afterwards; the next wakeup must
-- ask for one rebuild, and that build shows the decoded rows.
local function lateAnswer(page, name, generation, expectedMode, expectedBand)
  local m, b = readRows(page)
  equal(m, "-", name .. " RF Mode before the answer")
  equal(b, "-", name .. " RF Band before the answer")
  equal(link.pings, 1, name .. " ping sent by the first build")
  page.wakeup()
  equal(link.rebuilds, 0, name .. " no rebuild before the answer")
  answer(generation)
  page.wakeup()
  equal(link.rebuilds, 1, name .. " wakeup requests a rebuild once answered")
  page.wakeup()
  equal(link.rebuilds, 1, name .. " the rebuild is requested once")
  m, b = readRows(page)
  equal(m, expectedMode, name .. " RF Mode")
  equal(b, expectedBand, name .. " RF Band")
  equal(link.pings, 1, name .. " no second ping")
end

-- Each expected name is the one ExpressLRS gives that enumeration value in that generation.
local decodeCases = {
  { name = "3.x byte 5", generation = 3, mode = 5, rate = "150Hz", band = "-" },
  { name = "3.x byte 2", generation = 3, mode = 2, rate = "50Hz", band = "-" },
  { name = "3.x byte 10", generation = 3, mode = 10, rate = "D250", band = "-" },
  { name = "4.x byte 101", generation = 4, mode = 101, rate = "150Hz", band = "900MHz/2.4GHz" },
  { name = "4.x byte 10", generation = 4, mode = 10, rate = "D50Hz", band = "900MHz" },
  { name = "4.x byte 27", generation = 4, mode = 27, rate = "250Hz", band = "2.4GHz" }
}

for _, case in ipairs(decodeCases) do
  scenario(case.name, function()
    resetLink(case.mode)
    lateAnswer(loadPage(), case.name, case.generation, case.rate, case.band)
  end)
end

scenario("no answer", function()
  resetLink(5)
  local page = loadPage()
  local m, b = readRows(page)
  equal(m, "-", "no answer RF Mode")
  equal(b, "-", "no answer RF Band")
  for _ = 1, 5 do page.wakeup() end
  equal(link.rebuilds, 0, "no answer requests no rebuild")
  m = readRows(page)
  equal(m, "-", "no answer RF Mode on a later build")
  equal(link.pings, 1, "no answer pings once")
end)

scenario("not ExpressLRS", function()
  resetLink(5)
  local page = loadPage()
  readRows(page)
  answer(3, { 0x41, 0x42, 0x43, 0x44 })
  page.wakeup()
  equal(link.rebuilds, 1, "not ExpressLRS rebuilds once identified")
  local m, b = readRows(page)
  equal(m, "-", "not ExpressLRS RF Mode")
  equal(b, "-", "not ExpressLRS RF Band")
end)

scenario("stale sensor", function()
  resetLink(5)
  link.live = false
  local m, b = readRows(loadPage())
  equal(m, "-", "stale sensor RF Mode")
  equal(b, "-", "stale sensor RF Band")
  equal(link.pings, 0, "stale sensor sends no ping")
end)

-- An answer left queued from an earlier visit names a 4.x module; the module now fitted runs
-- 3.x. Byte 10 is D50Hz on 4.x and D250 on 3.x, so a stale answer shows as the wrong rate.
scenario("stale answer", function()
  resetLink(10)
  answer(4)
  lateAnswer(loadPage(), "stale answer", 3, "D250", "-")
end)

-- The page module survives being left. Closing drops the generation and the modules, and the
-- next visit must load them again, ping again and decode for the module now fitted.
scenario("close and reopen", function()
  resetLink(10)
  local page = loadPage()
  lateAnswer(page, "first visit", 4, "D50Hz", "900MHz")
  page.closePage()
  link.pings, link.rebuilds = 0, 0
  lateAnswer(page, "second visit", 3, "D250", "-")
  equal(link.rateLoads, 2, "close and reopen loads link_rates.lua again")
end)

print("Info RF Mode: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
