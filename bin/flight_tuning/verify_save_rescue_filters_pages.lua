-- Run the real Rescue and Filters pages and save pipeline against scripted MSP replies.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local base = "app/pages/flight_tuning/advanced/"
local pipelinePath = "tasks/msp/save_pipeline.lua"
local function newPage(spec)
  -- Module handles, the queue and the pipeline's shared state belong to one scenario.
  _G.rfsuite = { palette = {}, session = {} }
  _G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")
  local ticks = 0
  function getTime() return ticks end
  local apiPath = "tasks/msp/api/" .. spec.api .. ".lua"
  local api = assert(loadfile("src/rfsuite/" .. apiPath))()
  local eeprom = assert(loadfile("src/rfsuite/tasks/msp/api/eeprom_write.lua"))()
  local reboot = assert(loadfile("src/rfsuite/tasks/msp/api/reboot.lua"))()
  local txInfo = assert(loadfile("src/rfsuite/tasks/msp/api/tx_info.lua"))()
  local queue = { entries = {} }
  function queue:add(entry) self.entries[#self.entries + 1] = entry end
  local mspState = { queue = queue, lastArmed = false }
  local modules = {
    ["app/pages/settings/common.lua"] = {
      pageT = function() return function(_, _, fallback) return fallback end end,
      createProfileAwareRuntime = function() return {} end
    },
    ["ui/controls.lua"] = {},
    ["ui/loading_overlay.lua"] = {},
    ["lib/sensors.lua"] = {},
    ["lib/profile.lua"] = { getActivePidProfile = function() return 1 end },
    ["lib/api_version.lua"] = {},
    ["lib/log.lua"] = {},
    ["tasks/msp/runtime.lua"] = { getState = function() return mspState end },
    ["tasks/events/runtime.lua"] = {},
    [apiPath] = api,
    ["tasks/msp/api/eeprom_write.lua"] = eeprom,
    ["tasks/msp/api/reboot.lua"] = reboot,
    ["tasks/msp/api/tx_info.lua"] = txInfo
  }
  function loadScript(path)
    local relative = string.match(path, "^/SCRIPTS/RFSUITE/core/(.+)$")
    if relative == pipelinePath then
      return assert(loadfile("src/rfsuite/" .. relative))
    end
    assert(modules[relative], "unexpected module: " .. tostring(path))
    return function() return modules[relative] end
  end
  -- The host and page load separate instances; their public views must share the run.
  local pipeline = assert(loadfile("src/rfsuite/" .. pipelinePath))()
  local page = assert(loadfile("src/rfsuite/" .. base .. spec.name .. "/page.lua"))()
  local ui
  for i = 1, 20 do
    local key, value = debug.getupvalue(page.hasUnsavedChanges, i)
    if key == "ui" then ui = value; break end
    if not key then break end
  end
  assert(ui, "page state not found")
  local reports = {}
  local ctx = {
    requestRebuild = function() end,
    reportSave = function(report) reports[#reports + 1] = report end
  }
  local function wakeup()
    -- EdgeTX getTime() counts 10 ms ticks. Keep successful notices visible for inspection.
    ticks = ticks + 1
    pipeline.wakeup()
  end
  return { page = page, ui = ui, api = api, eeprom = eeprom, queue = queue,
    reboot = reboot, txInfo = txInfo,
    pipeline = pipeline, ctx = ctx, reports = reports, wakeup = wakeup, spec = spec }
end

local function answer(h, entry, bytes)
  assert(entry, "reply entry missing").processReply(entry, bytes)
  h.wakeup()
end

local function countCommand(h, command)
  local count = 0
  for _, entry in ipairs(h.queue.entries) do
    if entry.command == command then count = count + 1 end
  end
  return count
end

local function prepare(h, eq, field)
  eq(h.pipeline.isActive(), false, "fresh pipeline is idle")
  eq(h.pipeline.hasOutcome(), false, "fresh pipeline has no outcome")
  h.page.wakeup(h.ctx)
  eq(#h.queue.entries, 1, "one initial read")
  local initial = assert(h.queue.entries[1], "initial read missing")
  eq(initial.command, h.api.command, "initial read command")
  answer(h, initial, h.api.simulatorResponse)
  eq(h.page.canSave(), true, "initial reply permits save")
  eq(h.page.hasUnsavedChanges(), false, "initial read is clean")

  -- Both pages' number-field setters store the raw value in ui.config and set ui.dirty.
  -- These fields have unit steps; no display scaling or switch state needs to be emulated.
  field = field or h.spec.field
  local value = assert(h.ui.config[field], "initial field missing") + 1
  h.ui.config[field] = value
  h.ui.dirty = true
  eq(h.page.hasUnsavedChanges(), true, "field edit marks dirty")
  eq(h.page.onSave(h.ctx), true, "save accepted")
  h.wakeup()
  eq(#h.queue.entries, 2, "only configuration write queued before reply")
  local write = assert(h.queue.entries[2], "configuration write missing")
  eq(write.command, h.api.writeCommand, "save queues configuration write")
  eq(write.isWrite, true, "configuration command classified as write")
  eq(assert(h.api.parse(write.payload))[field], value, "payload carries edited value")
  eq(h.pipeline.isActive(), true, "host sees active page save")
  eq(h.pipeline.hasOutcome(), false, "pending write has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "write", "pipeline is writing")
  eq(progress.label, h.spec.step, "pipeline identifies configuration write")
  eq(progress.saved, false, "pending write is not saved")
  eq(h.page.hasUnsavedChanges(), true, "pending write stays dirty")
  eq(#h.reports, 0, "accepted save has no immediate reportSave dialog")
end

local function expectOutcome(h, status, saved, eq, reboot)
  eq(h.pipeline.hasOutcome(), true, "pipeline exposes outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "outcome", "pipeline run ended")
  eq(progress.terminal, true, "outcome is terminal")
  eq(progress.status, status, "outcome status")
  eq(progress.saved, saved, "outcome saved flag")
  local result = progress.result or {}
  eq(result.status, status, "result status")
  eq(result.saved, saved, "result saved flag")
  eq(result.reboot, reboot == true, "result reboot flag")
  return result
end

local function commit(h, eq)
  answer(h, h.queue.entries[2], {})
  eq(#h.queue.entries, 3, "configuration reply queues only EEPROM next")
  local commit = assert(h.queue.entries[3], "EEPROM write missing")
  eq(commit.command, h.eeprom.command, "EEPROM follows configuration write")
  eq(commit.isWrite, true, "EEPROM classified as write")
  eq(h.page.hasUnsavedChanges(), true, "configuration reply alone does not clear dirty")
  eq(h.pipeline.hasOutcome(), false, "configuration reply alone has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "commit", "pipeline awaits EEPROM")
  eq(progress.saved, false, "pending EEPROM is not saved")
  eq(countCommand(h, h.api.command), 1, "no read-back before EEPROM reply")
  eq(countCommand(h, h.reboot.writeCommand), 0, "no reboot before EEPROM reply")

  answer(h, commit, {})
  eq(h.page.hasUnsavedChanges(), false, "EEPROM reply clears dirty")
  eq(countCommand(h, h.api.writeCommand), 1, "exactly one configuration write")
  eq(countCommand(h, h.eeprom.command), 1, "exactly one EEPROM write")
end

local function accept(h, eq)
  commit(h, eq)
  expectOutcome(h, "done", true, eq)
  eq(countCommand(h, h.reboot.writeCommand), 0, "no reboot queued")
  eq(#h.queue.entries, 4, "successful save queues one read-back")
  eq(countCommand(h, h.api.command), 2, "initial read plus read-back")
  local readback = assert(h.queue.entries[4], "read-back missing")
  eq(readback.command, h.api.command, "read-back reads the same configuration")
  eq(h.ui.runtime.readPending, true, "read-back pending")
  answer(h, readback, h.api.simulatorResponse)
  eq(h.ui.runtime.readPending, false, "read-back completes")
  eq(h.ui.config[h.spec.field], assert(h.api.parse(h.api.simulatorResponse))[h.spec.field],
    "read-back replaces the edited value with the board reply")
  eq(h.page.canSave(), true, "read-back permits save")
  eq(h.page.hasUnsavedChanges(), false, "read-back stays clean")
  eq(#h.queue.entries, 4, "read-back queues no further work")
end

local function acceptReboot(h, eq)
  commit(h, eq)
  eq(h.pipeline.hasOutcome(), false, "EEPROM reply waits for reboot")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "preflight", "reboot save checks RTC before restarting")
  eq(progress.saved, true, "reboot starts only after settings are stored")
  eq(countCommand(h, h.api.command), 1, "no read-back before reconnect")
  local preflight = assert(h.queue.entries[4], "preflight read missing")
  eq(preflight.command, h.txInfo.command, "preflight reads TX_INFO")
  answer(h, preflight, { 0, 1 })

  local reboot = assert(h.queue.entries[5], "reboot missing")
  eq(reboot.command, h.reboot.writeCommand, "MSP_REBOOT follows EEPROM and preflight")
  eq(reboot.isWrite, true, "reboot classified as write")
  eq(countCommand(h, h.reboot.writeCommand), 1, "exactly one reboot queued")
  eq((h.pipeline.getProgress() or {}).phase, "reboot", "pipeline is restarting")
  answer(h, reboot, {})
  eq((h.pipeline.getProgress() or {}).phase, "probe", "pipeline waits for reconnect")
  eq(countCommand(h, h.api.command), 1, "page does not read during reconnect")

  local probe = assert(h.queue.entries[6], "reconnect probe missing")
  eq(probe.command, h.txInfo.command, "reconnect reads TX_INFO")
  answer(h, probe, { 0, 0 })
  local verify = assert(h.queue.entries[7], "RTC verification missing")
  eq(verify.command, h.txInfo.command, "connect completion verifies TX_INFO")
  eq((h.pipeline.getProgress() or {}).phase, "verify", "pipeline verifies reconnect")
  answer(h, verify, { 0, 1 })

  local result = expectOutcome(h, "done", true, eq, true)
  eq(result.rebootProven, true, "RTC reset proves restart")
  eq(result.rtcVerified, true, "RTC restored after reconnect")
  eq(h.page.hasUnsavedChanges(), false, "reboot completion stays clean")
  eq(countCommand(h, h.api.command), 1, "onDone leaves reload to the pipeline")
  eq(#h.queue.entries, 7, "reboot completion queues no page read-back")
  eq(#h.reports, 0, "reboot completion opens no reportSave dialog")
end

local scenarios = {
  { "ACCEPT", function(h, eq) accept(h, eq) end },
  { "REFUSE", function(h, eq)
    -- errorHandler is the queue's final refusal callback. Refuse any newly queued
    -- retries too, with a bound so a broken retry loop becomes an assertion failure.
    local index, refused = 2, 0
    while h.queue.entries[index] and refused < 16 do
      local entry = h.queue.entries[index]
      eq(entry.command, h.api.writeCommand, "refusal path queues only configuration writes")
      if entry.command ~= h.api.writeCommand then break end
      entry.errorHandler(entry, "refused")
      refused = refused + 1
      index = index + 1
      h.wakeup()
    end
    eq(refused > 0, true, "configuration refusal delivered")
    eq(h.queue.entries[index], nil, "refusal leaves no unanswered work")
    local result = expectOutcome(h, "failed", false, eq)
    eq(result.step, h.spec.step, "failure identifies configuration write")
    eq(countCommand(h, h.eeprom.command), 0, "refusal queues no EEPROM")
    eq(countCommand(h, h.api.command), 1, "refusal queues no read-back")
    eq(h.page.hasUnsavedChanges(), true, "refusal retains dirty edit")
    eq(h.ui.runtime.readPending, false, "refusal starts no read")
  end },
  { "BUSY", function(h, eq)
    local before = #h.queue.entries
    local revision = h.pipeline.getRevision()
    eq(h.page.onSave(h.ctx), false, "second save refused while active")
    h.wakeup()
    eq(#h.queue.entries, before, "second save queues nothing")
    eq(countCommand(h, h.api.writeCommand), 1, "second save queues no duplicate configuration write")
    eq(h.pipeline.getRevision(), revision, "second save does not replace pipeline run")
    eq(#h.reports, 0, "busy save opens no reportSave dialog")
    accept(h, eq)
  end }
}

local function runScenario(spec, scenario)
  local label = spec.name .. " " .. scenario[1]
  local function eq(actual, expected, detail)
    equal(actual, expected, label .. " " .. detail)
  end
  -- Missing entry points or callback errors count as failures without aborting other pages.
  local ok, err = pcall(function()
    local h = newPage(spec)
    prepare(h, eq, scenario.field)
    scenario[2](h, eq)
  end)
  eq(ok, true, "scenario completed" .. (ok and "" or ": " .. tostring(err)))
end

-- Each page writes one complete record followed by EEPROM; dynamic notch edits also reboot.
-- Rescue's mode/altitude-hold rows and Filters' version-gated RPM rows do not add write steps.
for _, spec in ipairs({
  { name = "rescue", api = "rescue_profile", field = "rescue_level_gain", step = "MSP_SET_RESCUE_PROFILE" },
  { name = "filters", api = "filter_config", field = "gyro_lpf1_static_hz", step = "MSP_SET_FILTER_CONFIG" }
}) do
  for _, scenario in ipairs(scenarios) do
    runScenario(spec, scenario)
  end
  if spec.name == "filters" then
    runScenario(spec, { "REBOOT", acceptReboot, field = "dyn_notch_count" })
    runScenario(spec, { "NO-REBOOT", accept })
  end
end

print("Rescue and Filters page saves: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
