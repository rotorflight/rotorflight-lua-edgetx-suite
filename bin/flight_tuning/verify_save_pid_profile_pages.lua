-- Run the real PID-profile pages and save pipeline against scripted MSP replies.
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
local function newPage(name)
  -- Module handles, the queue and the pipeline's shared state belong to one scenario.
  _G.rfsuite = { palette = {}, session = {} }
  _G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")
  local ticks = 0
  function getTime() return ticks end
  local api = assert(loadfile("src/rfsuite/tasks/msp/api/pid_profile.lua"))()
  local eeprom = assert(loadfile("src/rfsuite/tasks/msp/api/eeprom_write.lua"))()
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
    ["tasks/msp/api/pid_profile.lua"] = api,
    ["tasks/msp/api/eeprom_write.lua"] = eeprom,
    ["tasks/msp/api/reboot.lua"] = {},
    ["tasks/msp/api/tx_info.lua"] = {}
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
  return { page = page, ui = ui, api = api, eeprom = eeprom, queue = queue,
    pipeline = pipeline, ctx = ctx, reports = reports, wakeup = wakeup }
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

local function prepare(h, field, eq)
  eq(h.pipeline.isActive(), false, "fresh pipeline is idle")
  eq(h.pipeline.hasOutcome(), false, "fresh pipeline has no outcome")
  h.page.wakeup(h.ctx)
  eq(#h.queue.entries, 1, "one initial read")
  local initial = assert(h.queue.entries[1], "initial read missing")
  eq(initial.command, h.api.command, "initial PID read command")
  answer(h, initial, h.api.simulatorResponse)
  eq(h.page.canSave(), true, "initial reply permits save")
  eq(h.page.hasUnsavedChanges(), false, "initial read is clean")

  -- Number-field setters store the raw value in ui.config and set ui.dirty.
  local value = assert(h.ui.config[field], "initial field missing") + 1
  h.ui.config[field] = value
  h.ui.dirty = true
  eq(h.page.hasUnsavedChanges(), true, "field edit marks dirty")
  eq(h.page.onSave(h.ctx), true, "save accepted")
  h.wakeup()
  eq(#h.queue.entries, 2, "only PID write queued before reply")
  local write = assert(h.queue.entries[2], "PID write missing")
  eq(write.command, h.api.writeCommand, "save queues PID write")
  eq(write.isWrite, true, "PID command classified as write")
  eq(assert(h.api.parse(write.payload))[field], value, "PID payload carries edited value")
  eq(h.pipeline.isActive(), true, "host sees active page save")
  eq(h.pipeline.hasOutcome(), false, "pending write has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "write", "pipeline is writing")
  eq(progress.saved, false, "pending write is not saved")
  eq(h.page.hasUnsavedChanges(), true, "pending write stays dirty")
  eq(#h.reports, 0, "accepted save has no immediate reportSave dialog")
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
  return result
end

local function accept(h, eq)
  answer(h, h.queue.entries[2], {})
  eq(#h.queue.entries, 3, "PID reply queues only EEPROM next")
  local commit = assert(h.queue.entries[3], "EEPROM write missing")
  eq(commit.command, h.eeprom.command, "EEPROM follows PID write")
  eq(commit.isWrite, true, "EEPROM classified as write")
  eq(h.page.hasUnsavedChanges(), true, "PID reply alone does not clear dirty")
  eq(h.pipeline.hasOutcome(), false, "PID reply alone has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "commit", "pipeline awaits EEPROM")
  eq(progress.saved, false, "pending EEPROM is not saved")
  eq(countCommand(h, h.api.command), 1, "no read-back before EEPROM reply")

  answer(h, commit, {})
  expectOutcome(h, "done", true, eq)
  eq(h.page.hasUnsavedChanges(), false, "EEPROM reply clears dirty")
  eq(countCommand(h, h.api.writeCommand), 1, "exactly one PID write")
  eq(countCommand(h, h.eeprom.command), 1, "exactly one EEPROM write")
  eq(#h.queue.entries, 4, "successful save queues one read-back")
  eq(countCommand(h, h.api.command), 2, "initial read plus read-back")
  local readback = assert(h.queue.entries[4], "read-back missing")
  eq(readback.command, h.api.command, "read-back reads PID profile")
  eq(h.ui.runtime.readPending, true, "read-back pending")
  answer(h, readback, h.api.simulatorResponse)
  eq(h.ui.runtime.readPending, false, "read-back completes")
  eq(h.page.hasUnsavedChanges(), false, "read-back stays clean")
  eq(#h.queue.entries, 4, "read-back queues no further work")
end

local scenarios = {
  { "ACCEPT", function(h, eq) accept(h, eq) end },
  { "REFUSE", function(h, eq)
    -- errorHandler is the queue's final refusal callback. Refuse any newly queued
    -- PID retries too, with a bound so a broken retry loop becomes an assertion failure.
    local index, refused = 2, 0
    while h.queue.entries[index] and refused < 16 do
      local entry = h.queue.entries[index]
      eq(entry.command, h.api.writeCommand, "refusal path queues only PID writes")
      if entry.command ~= h.api.writeCommand then break end
      entry.errorHandler(entry, "refused")
      refused = refused + 1
      index = index + 1
      h.wakeup()
    end
    eq(refused > 0, true, "PID refusal delivered")
    eq(h.queue.entries[index], nil, "refusal leaves no unanswered work")
    local result = expectOutcome(h, "failed", false, eq)
    eq(result.step, "MSP_SET_PID_PROFILE", "failure identifies PID write")
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
    eq(countCommand(h, h.api.writeCommand), 1, "second save queues no duplicate PID write")
    eq(h.pipeline.getRevision(), revision, "second save does not replace pipeline run")
    eq(#h.reports, 0, "busy save opens no reportSave dialog")
    accept(h, eq)
  end }
}

for _, spec in ipairs({
  { "autolevel", "trainer_gain" },
  { "main_rotor", "pitch_collective_ff_gain" },
  { "pid_bandwidth", "gyro_cutoff_0" },
  { "pid_controller", "error_decay_time_ground" }
}) do
  for _, scenario in ipairs(scenarios) do
    local label = spec[1] .. " " .. scenario[1]
    local function eq(actual, expected, detail)
      equal(actual, expected, label .. " " .. detail)
    end
    -- Missing entry points or callback errors count as failures without aborting other pages.
    local ok, err = pcall(function()
      local h = newPage(spec[1])
      prepare(h, spec[2], eq)
      scenario[2](h, eq)
    end)
    eq(ok, true, "scenario completed" .. (ok and "" or ": " .. tostring(err)))
  end
end

print("PID profile page saves: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
