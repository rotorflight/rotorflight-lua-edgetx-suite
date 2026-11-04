-- Run the real Telemetry page and API to verify saved sensor slots in the ELRS sync buffer.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function copyBuffer(buf)
  local out = {}
  for i = 1, #buf do out[i] = buf[i] end
  return out
end

local function runCase(closeBeforeSaved, eq)
  local TelemetryApi = assert(loadfile("src/rfsuite/tasks/msp/api/telemetry_config.lua"))()
  local connectBuffer = {}
  for i = 1, 52 do connectBuffer[i] = 0 end
  connectBuffer[2] = 1
  connectBuffer[8] = 1
  connectBuffer[9] = 250
  connectBuffer[11] = 8
  connectBuffer[13], connectBuffer[14], connectBuffer[15] = 1, 2, 3

  local session = {
    telemetryConfigBuffer = copyBuffer(connectBuffer),
    telemetry_config = TelemetryApi.parse(connectBuffer),
    rx_config = { serialrx_provider = 9 }
  }
  local ui, descriptor
  local reads = {}
  local modules = {
    ["app/pages/settings/common.lua"] = {
      createFormRuntime = function(state)
        ui = state
        return {}
      end,
      pageT = function()
        return function(_, _, fallback) return fallback end
      end,
      -- Match the shared helper's teardown of the fields used by this page.
      resetPageState = function(state)
        state.loaded = false
        state.dirty = false
        state.runtime = nil
      end
    },
    ["ui/controls.lua"] = {},
    ["tasks/msp/runtime.lua"] = {
      getState = function()
        return {
          queue = {
            add = function(_, request)
              reads[#reads + 1] = request
            end
          }
        }
      end
    },
    ["tasks/msp/api/telemetry_config.lua"] = TelemetryApi,
    ["tasks/msp/api/rx_config.lua"] = {
      command = 44,
      parse = function() return { serialrx_provider = 9 } end
    },
    ["tasks/msp/save_pipeline.lua"] = {
      -- Each scenario starts idle and explicitly delivers storage success below.
      isActive = function() return descriptor ~= nil end,
      start = function(desc)
        assert(not descriptor, "more than one save was started")
        descriptor = desc
        return true
      end
    },
    ["ui/confirm_dialog.lua"] = {},
    ["ui/loading_overlay.lua"] = {},
    ["lib/api_version.lua"] = {}
  }
  _G.rfsuite = { session = session, palette = {} }
  _G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")
  function loadScript(path)
    local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
    local mod = assert(modules[relative], "unexpected module: " .. tostring(path))
    return function() return mod end
  end

  local page = assert(loadfile("src/rfsuite/app/pages/setup/telemetry/page.lua"))()
  page.onReload()
  eq(#reads, 2, "telemetry and receiver reads queued")
  eq(reads[1].command, 73, "telemetry read command")
  eq(reads[2].command, 44, "receiver read command")
  reads[1].processReply(nil, copyBuffer(connectBuffer))
  reads[2].processReply(nil, { 9 })
  eq(page.canSave(), true, "page ready to save")

  -- Sensor 2 is unmanaged and preserved; enable catalog sensor 4 alongside 1 and 3.
  eq(ui.config[1], true, "sensor 1 initially selected")
  eq(ui.config[3], true, "sensor 3 initially selected")
  eq(ui.config[4], false, "sensor 4 initially unselected")
  ui.config[4] = true
  ui.dirty = true
  eq(page.onSave({}), true, "save accepted")
  assert(descriptor, "save did not start the save pipeline")
  eq(#descriptor.steps, 1, "single telemetry save step")
  eq(descriptor.steps[1].command, 74, "save queues MSP_SET_TELEMETRY_CONFIG")
  eq(descriptor.reboot, true, "telemetry save restarts the flight controller")
  local payload = descriptor.steps[1].payload
  for i = 1, 40 do
    eq(payload[12 + i], i <= 4 and i or 0, "saved sensor slot " .. i)
  end
  eq(session.telemetryConfigBuffer[16], 0, "session buffer unchanged before storage success")
  if closeBeforeSaved then
    page.onClose()
    eq(ui.runtime, nil, "close clears page runtime")
  end

  -- Deliver the real page's completion callback even after its module handles are released.
  descriptor.onSaved()
  local saved = session.telemetryConfigBuffer
  for i = 1, 40 do
    eq(saved[12 + i], i <= 4 and i or 0, "session sensor slot " .. i)
  end
  eq(#saved, #payload, "session buffer length matches payload")
  for i = 1, #payload do
    eq(saved[i], payload[i], "session buffer matches payload byte " .. i)
  end
  eq(session.telemetry_config.telem_sensor_slot_4, 4, "parsed session configuration updated")
  eq(saved ~= payload, true, "session buffer independent of payload")
  eq(saved ~= session.telemetry_config.buffer, true, "session buffer independent of parsed buffer")
  if not closeBeforeSaved then
    eq(ui.telemetryBuffer ~= saved, true, "page buffer independent of session buffer")
    eq(ui.telemetryBuffer[16], 4, "open page buffer updated")
    eq(ui.dirty, false, "open page marked clean")
    page.onClose()
  end
  payload[16] = 99
  eq(saved[16], 4, "payload mutation leaves session buffer unchanged")
end

for _, closeBeforeSaved in ipairs({ false, true }) do
  local name = closeBeforeSaved and "closed page" or "open page"
  local function eq(actual, expected, label)
    equal(actual, expected, name .. " " .. label)
  end
  -- Missing entry points and callback errors fail this scenario without aborting the next.
  local ok, err = pcall(runCase, closeBeforeSaved, eq)
  eq(ok, true, "scenario completed" .. (ok and "" or ": " .. tostring(err)))
end

print("Telemetry sync slots: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
