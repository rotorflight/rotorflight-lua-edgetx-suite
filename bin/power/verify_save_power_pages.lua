-- Run the real Power pages and save pipeline against scripted MSP replies.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local base = "app/pages/setup/power/"
local pipelinePath = "tasks/msp/save_pipeline.lua"
local function newPage(name)
  -- Module handles, the queue and the pipeline's shared state belong to one scenario.
  _G.rfsuite = { palette = {}, session = {} }
  local ticks = 0
  function getTime() return ticks end
  local function apiModule(module)
    return assert(loadfile("src/rfsuite/tasks/msp/api/" .. module .. ".lua"))()
  end
  local battery = apiModule("battery_config")
  local profile = apiModule("battery_profile")
  local smartfuel = apiModule("smartfuel_config")
  local eeprom = apiModule("eeprom_write")
  local reboot = apiModule("reboot")
  local queue = { entries = {} }
  function queue:add(entry) self.entries[#self.entries + 1] = entry end
  local mspState = { queue = queue, lastArmed = false }
  local preferences = {}
  local modules = {
    ["app/pages/settings/common.lua"] = {
      pageT = function() return function(_, _, fallback) return fallback end end
    },
    [base .. "model_preferences.lua"] = {
      -- Pretend the radio file write succeeds; capture the preferences supplied by the page.
      save = function(session)
        local saved = {}
        for key, value in pairs(session.modelPreferences.battery) do saved[key] = value end
        preferences[#preferences + 1] = saved
        return true
      end
    },
    ["ui/controls.lua"] = {},
    ["ui/loading_overlay.lua"] = {},
    -- No active-profile sensor: an untouched Battery combo must not select a profile.
    ["lib/sensors.lua"] = {},
    ["lib/power_fields.lua"] = assert(loadfile("src/rfsuite/lib/power_fields.lua"))(),
    ["lib/smartfuel_reserve.lua"] = assert(loadfile("src/rfsuite/lib/smartfuel_reserve.lua"))(),
    ["lib/api_version.lua"] = assert(loadfile("src/rfsuite/lib/api_version.lua"))(),
    ["lib/log.lua"] = {},
    ["tasks/msp/runtime.lua"] = { getState = function() return mspState end },
    ["tasks/events/runtime.lua"] = {},
    ["tasks/msp/api/battery_config.lua"] = battery,
    ["tasks/msp/api/battery_profile.lua"] = profile,
    ["tasks/msp/api/smartfuel_config.lua"] = smartfuel,
    ["tasks/msp/api/eeprom_write.lua"] = eeprom,
    ["tasks/msp/api/reboot.lua"] = reboot,
    ["tasks/msp/api/tx_info.lua"] = apiModule("tx_info")
  }
  function loadScript(path)
    local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
    if relative == pipelinePath then
      return assert(loadfile("src/rfsuite/" .. relative))
    end
    assert(modules[relative], "unexpected module: " .. tostring(path))
    return function() return modules[relative] end
  end
  -- The host and page load separate instances; their public views must share the run.
  local pipeline = assert(loadfile("src/rfsuite/" .. pipelinePath))()
  local page = assert(loadfile("src/rfsuite/" .. base .. name .. "/page.lua"))()
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
  return { page = page, ui = ui, api = name == "smartfuel" and smartfuel or battery,
    profile = profile, smartfuel = smartfuel, eeprom = eeprom, reboot = reboot, queue = queue,
    pipeline = pipeline, ctx = ctx, reports = reports, preferences = preferences, wakeup = wakeup }
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

local function expectDirty(h, dirty, eq)
  eq(h.page.hasUnsavedChanges(), dirty, "page dirty state")
  if h.spec.name == "battery" then
    eq(h.ui.profileDirty, dirty and h.spec.profile, "profile dirty state")
    eq(h.ui.reserveDirty, dirty and h.spec.profile, "reserve dirty state")
  end
end

local function expectWrite(h, index, eq)
  local step = h.steps[index]
  local entry = assert(h.queue.entries[index + 1], step.label .. " missing")
  eq(entry.command, step.api.writeCommand, "write order: " .. step.label)
  eq(entry.isWrite, true, step.label .. " classified as write")
  local parsed = assert(step.api.parse(entry.payload), step.label .. " payload invalid")
  for key, value in pairs(step.values) do
    eq(parsed[key], value, step.label .. " payload " .. key)
  end
  return entry
end

local function prepare(h, spec, eq)
  h.spec = spec
  eq(h.pipeline.isActive(), false, "fresh pipeline is idle")
  eq(h.pipeline.hasOutcome(), false, "fresh pipeline has no outcome")
  h.page.wakeup(h.ctx)
  eq(h.page.canSave(), false, "save waits for initial read")
  eq(#h.queue.entries, 1, "one initial read")
  local initial = assert(h.queue.entries[1], "initial read missing")
  eq(initial.command, h.api.command, "initial configuration read command")
  answer(h, initial, h.api.simulatorResponse)
  eq(h.page.canSave(), true, "initial reply permits save")
  eq(h.ui.runtime.readPending, false, "initial read completes")
  eq(h.page.hasUnsavedChanges(), false, "initial read is clean")
  if spec.name == "battery" then
    -- After its own load Battery reads the SmartFuel configuration, to send it back with the save.
    local sf = h.queue.entries[2]
    if spec.smartfuel == "unsupported" then
      eq(sf, nil, "no SmartFuel read below MSP API 12.09")
    else
      eq(sf and sf.command, h.smartfuel.command, "SmartFuel read follows the battery load")
      table.remove(h.queue.entries, 2)
      if spec.smartfuel == "refused" then sf.errorHandler(sf, "refused") else
        sf.processReply(sf, h.smartfuel.simulatorResponse) end
      h.wakeup()
    end
    eq(#h.queue.entries, 1, "the SmartFuel read is the only follow-up of the load")
  end

  -- Mirror the setters' raw config changes and dirty flags without building an LVGL tree.
  -- Parse a separate expected record so onSave's session mutations cannot change the oracle.
  local expected = assert(h.api.parse(h.api.simulatorResponse))
  h.steps = {}
  if spec.name == "battery" then
    h.ui.config.capacities[2] = h.ui.config.capacities[2] + 1
    expected.batteryCapacity_1 = h.ui.config.capacities[2]
    if spec.profile then
      h.ui.config.selectedBatteryProfile = 1
      h.ui.profileDirty = true
      h.ui.config.consumption_warning_percentage = h.ui.config.consumption_warning_percentage + 1
      h.ui.reserveDirty = true
      expected.batteryCapacity = expected.batteryCapacity_1
      expected.consumptionWarningPercentage = h.ui.config.consumption_warning_percentage
      h.steps[#h.steps + 1] = { api = h.profile, label = "MSP_SET_BATTERY_PROFILE",
        values = { batteryProfile = 1 } }
    end
  elseif spec.name == "sources" then
    h.ui.config.voltageMeterSource = h.ui.config.voltageMeterSource + 1
    h.ui.config.currentMeterSource = h.ui.config.currentMeterSource + 2
    expected.voltageMeterSource = h.ui.config.voltageMeterSource
    expected.currentMeterSource = h.ui.config.currentMeterSource
  else
    h.ui.config.firmware_mode = 1
    h.ui.config.voltage_drop_rate = h.ui.config.voltage_drop_rate + 1
    expected.smartfuel_mode = h.ui.config.firmware_mode
    expected.voltage_drop_rate = h.ui.config.voltage_drop_rate
  end
  h.steps[#h.steps + 1] = { api = h.api, values = expected,
    label = spec.name == "smartfuel" and "MSP_SET_SMARTFUEL_CONFIG" or "MSP_SET_BATTERY_CONFIG" }
  if spec.name == "battery" and spec.smartfuel == nil then
    -- Sent back unchanged so the flight controller re-initialises SmartFuel with the new cells.
    h.steps[#h.steps + 1] = { api = h.smartfuel, label = "MSP2_SET_SMARTFUEL_CONFIG",
      values = assert(h.smartfuel.parse(h.smartfuel.simulatorResponse)) }
  end
  h.ui.dirty = true
  expectDirty(h, true, eq)
  eq(h.page.onSave(h.ctx), true, "save accepted")
  h.wakeup()
  eq(#h.queue.entries, 2, "only first write queued before reply")
  expectWrite(h, 1, eq)
  eq(h.pipeline.isActive(), true, "host sees active page save")
  eq(h.pipeline.hasOutcome(), false, "pending write has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "write", "pipeline is writing")
  eq(progress.saved, false, "pending write is not saved")
  expectDirty(h, true, eq)
  eq(#h.reports, 0, "accepted save has no immediate reportSave dialog")
  eq(#h.preferences, spec.name == "sources" and 0 or 1, "local preference save count")
  if spec.name == "smartfuel" then
    local prefs = assert(h.preferences[1], "local preferences missing")
    eq(prefs.voltage_drop_rate, expected.voltage_drop_rate, "local copy has edited voltage drop rate")
    eq(prefs.charge_drop_rate, expected.charge_drop_rate, "local copy keeps charge drop rate")
    eq(prefs.sag_gain, expected.sag_gain, "local copy keeps sag gain")
  elseif spec.name == "battery" then
    local prefs = assert(h.preferences[1], "local preferences missing")
    eq(prefs.consumption_warning_percentage, spec.profile and expected.consumptionWarningPercentage or nil,
      "local reserve stored only when edited")
  end
end

local function expectOutcome(h, status, saved, eq)
  eq(h.pipeline.hasOutcome(), true, "pipeline exposes outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "outcome", "pipeline run ended")
  eq(progress.terminal, true, "outcome is terminal")
  eq(progress.status, status, "outcome status")
  eq(progress.saved, saved, "outcome saved flag")
  local result = progress.result or {}
  eq(result.status, status, "result status")
  eq(result.saved, saved, "result saved flag")
  eq(result.reboot, false, "save requires no reboot")
  eq(countCommand(h, h.reboot.command), 0, "no reboot queued")
  return result
end

local function acceptWrite(h, index, eq)
  answer(h, expectWrite(h, index, eq), {})
  eq(#h.queue.entries, index + 2, "write reply queues exactly one next command")
  expectDirty(h, true, eq)
  eq(h.pipeline.hasOutcome(), false, "write reply alone has no outcome")
  eq(countCommand(h, h.api.command), 1, "no read-back before EEPROM reply")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, index == #h.steps and "commit" or "write", "phase after write reply")
  eq(progress.saved, false, "write reply alone is not saved")
end

local function expectCommit(h, eq)
  local commit = assert(h.queue.entries[#h.steps + 2], "EEPROM write missing")
  eq(commit.command, h.eeprom.command, "EEPROM follows every write step")
  eq(commit.isWrite, true, "EEPROM classified as write")
  return commit
end

local function accept(h, eq)
  for index = 1, #h.steps do acceptWrite(h, index, eq) end
  answer(h, expectCommit(h, eq), {})
  expectOutcome(h, "done", true, eq)
  expectDirty(h, false, eq)
  for _, step in ipairs(h.steps) do
    eq(countCommand(h, step.api.writeCommand), 1, "exactly one " .. step.label)
  end
  eq(countCommand(h, h.profile.writeCommand), h.spec.profile and 1 or 0,
    "profile written only after an explicit selection")
  eq(countCommand(h, h.eeprom.command), 1, "exactly one EEPROM write")
  eq(#h.queue.entries, #h.steps + 3, "successful save queues one read-back")
  eq(countCommand(h, h.api.command), 2, "initial read plus read-back")
  local readback = assert(h.queue.entries[#h.steps + 3], "read-back missing")
  eq(readback.command, h.api.command, "read-back reads page configuration")
  eq(h.ui.runtime.readPending, true, "read-back pending")
  eq(h.page.canSave(), false, "save waits for read-back")
  answer(h, readback, h.api.simulatorResponse)
  eq(h.ui.runtime.readPending, false, "read-back completes")
  eq(h.page.canSave(), true, "read-back permits save")
  expectDirty(h, false, eq)
  local followUp = (h.spec.name == "battery" and h.spec.smartfuel ~= "unsupported") and 1 or 0
  eq(#h.queue.entries, #h.steps + 3 + followUp, "read-back queues no further work but the SmartFuel read")
  if followUp == 1 then
    eq(h.queue.entries[#h.steps + 4].command, h.smartfuel.command, "read-back reads SmartFuel again")
  end
  eq(countCommand(h, h.smartfuel.writeCommand), (h.spec.name == "smartfuel" or
    (h.spec.name == "battery" and h.spec.smartfuel == nil)) and 1 or 0, "SmartFuel written only with a read")
  eq(#h.reports, 0, "success is reported through the pipeline")
end

local function refuse(h, stepIndex, eq)
  -- Accept earlier steps so Battery's second write and the EEPROM are refused independently.
  for index = 1, stepIndex - 1 do acceptWrite(h, index, eq) end
  local committing = stepIndex > #h.steps
  local step = committing and { api = h.eeprom, label = "commit" } or h.steps[stepIndex]
  if committing then expectCommit(h, eq) else expectWrite(h, stepIndex, eq) end
  -- errorHandler is the queue's final refusal callback. Bound any newly queued retries.
  local index, refused = stepIndex + 1, 0
  while h.queue.entries[index] and refused < 16 do
    local entry = h.queue.entries[index]
    eq(entry.command, step.api.writeCommand, "refusal path queues only the refused command")
    if entry.command ~= step.api.writeCommand then break end
    entry.errorHandler(entry, "refused")
    refused = refused + 1
    index = index + 1
    h.wakeup()
  end
  eq(refused > 0, true, "refusal delivered")
  eq(h.queue.entries[index], nil, "refusal leaves no unanswered work")
  local result = expectOutcome(h, "failed", false, eq)
  eq(result.step, step.label, "failure identifies refused step")
  for later = stepIndex + 1, #h.steps do
    eq(countCommand(h, h.steps[later].api.writeCommand), 0, "refusal skips later write")
  end
  eq(countCommand(h, h.eeprom.command), committing and refused or 0, "no commit after a refused write")
  eq(countCommand(h, h.api.command), 1, "refusal queues no read-back")
  expectDirty(h, true, eq)
  eq(h.ui.runtime.readPending, false, "refusal starts no read")
  -- In particular, a successful local SmartFuel preference save is not FC success.
  eq(#h.reports, 0, "refused FC save has no reportSave success dialog")
  eq(#h.preferences, h.spec.name == "sources" and 0 or 1, "refusal does not repeat local persistence")
end

local scenarios = {
  { "ACCEPT", function(h, eq) accept(h, eq) end },
  { "REFUSE", function(h, eq) refuse(h, 1, eq) end },
  { "BUSY", function(h, eq)
    local before = #h.queue.entries
    local revision = h.pipeline.getRevision()
    local preferences = #h.preferences
    eq(h.page.onSave(h.ctx), false, "second save refused while active")
    h.wakeup()
    eq(#h.queue.entries, before, "second save queues nothing")
    eq(countCommand(h, h.steps[1].api.writeCommand), 1, "second save queues no duplicate write")
    eq(h.pipeline.getRevision(), revision, "second save does not replace pipeline run")
    eq(#h.preferences, preferences, "busy save does not repeat local persistence")
    eq(#h.reports, 0, "busy save opens no reportSave dialog")
    accept(h, eq)
  end },
  { "REFUSE EEPROM", function(h, eq) refuse(h, #h.steps + 1, eq) end }
}

local function run(spec, scenario)
  local label = spec.label .. " " .. scenario[1]
  local function eq(actual, expected, detail)
    equal(actual, expected, label .. " " .. detail)
  end
  -- Missing entry points or callback errors count as failures without aborting other pages.
  local ok, err = pcall(function()
    local h = newPage(spec.name)
    if spec.apiVersion then _G.rfsuite.session.apiVersion = spec.apiVersion end
    prepare(h, spec, eq)
    scenario[2](h, eq)
  end)
  eq(ok, true, "scenario completed" .. (ok and "" or ": " .. tostring(err)))
end

for _, spec in ipairs({
  { name = "battery", label = "battery unchanged profile", profile = false },
  { name = "battery", label = "battery changed profile", profile = true },
  { name = "battery", label = "battery SmartFuel read refused", profile = false, smartfuel = "refused" },
  { name = "battery", label = "battery MSP API 12.08", profile = false, smartfuel = "unsupported",
    apiVersion = "12.08" },
  { name = "sources", label = "sources changed meters" },
  { name = "smartfuel", label = "smartfuel" }
}) do
  for _, scenario in ipairs(scenarios) do run(spec, scenario) end
  if spec.profile then
    run(spec, { "REFUSE CONFIG", function(h, eq) refuse(h, 2, eq) end })
  end
end

print("Power page saves: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
