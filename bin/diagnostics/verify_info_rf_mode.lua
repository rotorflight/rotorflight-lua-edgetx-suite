-- Run the real Info page and shared RF rate decoder with stubbed radio APIs and CRSF input.
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
local rates

local cases = {
  { name = "3.x byte 5", generation = 3, mode = 5, band = "-" },
  { name = "3.x byte 2", generation = 3, mode = 2, band = "-" },
  { name = "4.x byte 101", generation = 4, mode = 101, band = "900MHz/2.4GHz" },
  { name = "4.x byte 10", generation = 4, mode = 10, band = "900MHz" },
  { name = "4.x byte 25", generation = 4, mode = 25, band = "2.4GHz" },
  { name = "generation unknown", mode = 5, band = "-" }
}

local function loadPage(mode, generation)
  -- Device-information payload: destination, transmitter origin, name + NUL,
  -- ELRS serial, hardware version, software version (0, major, minor, revision),
  -- parameter count. No payload is available while the generation is unknown.
  local pending = generation and {
    0xEA, 0xEE, 84, 88, 0,
    0x45, 0x4C, 0x52, 0x53,
    0, 0, 0, 0,
    0, generation, 0, 0,
    0
  } or nil
  local modules = {
    ["lib/version.lua"] = {},
    ["tasks/msp/runtime.lua"] = { getState = function() return {} end },
    ["app/pages/lib/async_load_ui.lua"] = {},
    ["lib/link_rates.lua"] = rates,
    ["lib/crsf.lua"] = {
      popFrame = function(frameType)
        assert(frameType == rates.FRAME_DEVICE_INFO, "unexpected CRSF frame request")
        local answer = pending
        pending = nil
        return answer
      end
    }
  }
  _G.rfsuite = { palette = {} }
  _G.SMLSIZE = 0
  _G.RIGHT = 0
  _G.getSourceValue = function(name)
    if name == "RFMD" then return mode, true end
    return nil, false
  end
  _G.crossfireTelemetryPush = function(frameType, payload)
    assert(frameType == rates.FRAME_DEVICE_PING, "unexpected CRSF frame sent")
    assert(payload[1] == 0xEE and payload[2] == 0xEA, "unexpected ping addresses")
    return true
  end
  _G.loadScript = function(path)
    assert(path:sub(1, #prefix) == prefix, "unexpected module prefix: " .. path)
    local module = assert(modules[path:sub(#prefix + 1)], "unexpected module: " .. path)
    return function() return module end
  end
  return assert(loadfile(pagePath))()
end

local function readRows(page)
  local children = {}
  -- A disconnected MSP runtime prevents unrelated live-load work. RFMD remains live
  -- through the sensor stub, so the public build path still calls readLiveRfInfo.
  page.build({ children = children, x = 0, y = 0, w = 480, h = 800 })
  local mode, band
  for i, child in ipairs(children) do
    if child.text == "RF Mode" then mode = children[i + 1].text end
    if child.text == "RF Band" then band = children[i + 1].text end
  end
  return assert(mode, "RF Mode row missing"), assert(band, "RF Band row missing")
end

for _, case in ipairs(cases) do
  -- Keep module loading and every scenario assertion inside the error boundary so
  -- an older implementation reports a failure and the remaining cases still run.
  local ok, err = pcall(function()
    rates = rates or assert(loadfile("src/rfsuite/lib/link_rates.lua"))()
    -- Rate expectations come from the real shared tables; only 4.x values carry the band.
    local row = rates.forMode(case.mode, case.generation)
    if case.generation then assert(row, "test case missing from shared rate tables") end
    local expectedMode = row and row.rate or "-"
    local mode, band = readRows(loadPage(case.mode, case.generation))
    equal(mode, expectedMode, case.name .. " RF Mode")
    equal(band, case.band, case.name .. " RF Band")
  end)
  if not ok then
    equal("error: " .. tostring(err), "completed", case.name .. " scenario")
  end
end

print("Info RF Mode: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
