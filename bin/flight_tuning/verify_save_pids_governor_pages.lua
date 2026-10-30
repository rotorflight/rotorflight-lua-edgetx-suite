-- Run the real PIDs and Governor pages and save pipeline against scripted MSP replies.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local base = "app/pages/flight_tuning/"
local pipelinePath = "tasks/msp/save_pipeline.lua"
local function newPage(spec)
  -- Module handles, the queue and the pipeline's shared state belong to one scenario.
  _G.rfsuite = { palette = {}, session = {} }
  local ticks = 0
  function getTime() return ticks end
  local pid = assert(loadfile("src/rfsuite/tasks/msp/api/pid_tuning.lua"))()
  local governor = assert(loadfile("src/rfsuite/tasks/msp/api/governor_profile.lua"))()
  local governorConfig = assert(loadfile("src/rfsuite/tasks/msp/api/governor_config.lua"))()
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
    ["lib/governor_fields.lua"] = assert(loadfile("src/rfsuite/lib/governor_fields.lua"))(),
    ["lib/log.lua"] = {},
    ["tasks/msp/runtime.lua"] = { getState = function() return mspState end },
    ["tasks/events/runtime.lua"] = {},
    ["tasks/msp/api/pid_tuning.lua"] = pid,
    ["tasks/msp/api/governor_profile.lua"] = governor,
    ["tasks/msp/api/governor_config.lua"] = governorConfig,
    ["tasks/msp/api/eeprom_write.lua"] = eeprom,
    ["tasks/msp/api/reboot.lua"] = {},
    ["tasks/msp/api/tx_info.lua"] = {}
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
  local page = assert(loadfile("src/rfsuite/" .. base .. spec.name .. "/page.lua"))()
  equal(page.eepromWrite, nil, spec.name .. " leaves EEPROM commit to the pipeline")
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
  local apis = { pid = pid, governor = governor, governorConfig = governorConfig }
  local reads = {}
  for _, name in ipairs(spec.reads) do reads[#reads + 1] = apis[name] end
  return { page = page, ui = ui, api = apis[spec.api], eeprom = eeprom, queue = queue,
    pipeline = pipeline, ctx = ctx, reports = reports, wakeup = wakeup,
    reads = reads, spec = spec, writeIndex = #reads + 1 }
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

local function answerReads(h, offset, label, eq)
  -- Governor reads its global configuration before its profile, on entry and read-back.
  -- PIDs has only the PID tuning read. Each reply must queue at most the next read.
  for i, api in ipairs(h.reads) do
    eq(#h.queue.entries, offset + i, label .. " queues only the next read")
    eq(h.ui.runtime.readPending, true, label .. " is pending")
    eq(h.page.canSave(), false, label .. " blocks save until complete")
    local entry = assert(h.queue.entries[offset + i], label .. " missing")
    eq(entry.command, api.command, label .. " command " .. i)
    answer(h, entry, api.simulatorResponse)
  end
  eq(#h.queue.entries, offset + #h.reads, label .. " queues no further work")
  eq(h.ui.runtime.readPending, false, label .. " completes")
  eq(h.page.canSave(), true, label .. " permits save")
  eq(h.page.hasUnsavedChanges(), false, label .. " is clean")
end

local function expectReadCount(h, expected, label, eq)
  for _, api in ipairs(h.reads) do
    eq(countCommand(h, api.command), expected, label .. " command " .. api.command)
  end
end

local function prepare(h, eq)
  eq(h.pipeline.isActive(), false, "fresh pipeline is idle")
  eq(h.pipeline.hasOutcome(), false, "fresh pipeline has no outcome")
  h.page.wakeup(h.ctx)
  answerReads(h, 0, "initial read", eq)

  -- Both number-field setters store a raw integer in ui.config and set ui.dirty.
  -- These gain fields have step 1 and no alternate field alias.
  local field = h.spec.field
  local value = assert(h.ui.config[field], "initial field missing") + 1
  h.ui.config[field] = value
  h.ui.dirty = true
  h.editedValue = value
  eq(h.page.hasUnsavedChanges(), true, "field edit marks dirty")
  eq(h.page.onSave(h.ctx), true, "save accepted")
  h.wakeup()
  eq(#h.queue.entries, h.writeIndex, "only profile write queued before reply")
  local write = assert(h.queue.entries[h.writeIndex], "profile write missing")
  eq(write.command, h.api.writeCommand, "save queues profile write")
  eq(write.isWrite, true, "profile command classified as write")
  eq(assert(h.api.parse(write.payload))[field], value, "payload carries edited value")
  eq(h.pipeline.isActive(), true, "host sees active page save")
  eq(h.pipeline.hasOutcome(), false, "pending write has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "write", "pipeline is writing")
  eq(progress.label, h.spec.step, "pipeline identifies profile write")
  eq(progress.saved, false, "pending write is not saved")
  eq(h.page.hasUnsavedChanges(), true, "pending write stays dirty")
  eq(#h.reports, 0, "accepted save has no immediate reportSave dialog")
  eq(countCommand(h, h.eeprom.command), 0, "no EEPROM before profile reply")
  expectReadCount(h, 1, "no read-back before profile reply", eq)
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
  answer(h, h.queue.entries[h.writeIndex], {})
  eq(#h.queue.entries, h.writeIndex + 1, "profile reply queues only EEPROM next")
  local commit = assert(h.queue.entries[h.writeIndex + 1], "EEPROM write missing")
  eq(commit.command, h.eeprom.command, "EEPROM follows profile write")
  eq(commit.isWrite, true, "EEPROM classified as write")
  eq(h.page.hasUnsavedChanges(), true, "profile reply alone does not clear dirty")
  eq(h.pipeline.hasOutcome(), false, "profile reply alone has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "commit", "pipeline awaits EEPROM")
  eq(progress.saved, false, "pending EEPROM is not saved")
  eq(#h.reports, 0, "no reportSave success or warning before EEPROM reply")
  expectReadCount(h, 1, "no read-back before EEPROM reply", eq)

  answer(h, commit, {})
  expectOutcome(h, "done", true, eq)
  eq(h.page.hasUnsavedChanges(), false, "EEPROM reply clears dirty")
  eq(countCommand(h, h.api.writeCommand), 1, "exactly one profile write")
  eq(countCommand(h, h.eeprom.command), 1, "exactly one EEPROM write")
  eq(#h.queue.entries, h.writeIndex + 2, "successful save starts read-back")
  answerReads(h, h.writeIndex + 1, "read-back", eq)
  expectReadCount(h, 2, "initial read plus read-back", eq)
  eq(h.ui.config[h.spec.field], assert(h.api.parse(h.api.simulatorResponse))[h.spec.field],
    "read-back refreshes field from controller reply")
  eq(#h.reports, 0, "pipeline outcome needs no reportSave dialog")
end

local scenarios = {
  { "ACCEPT", function(h, eq) accept(h, eq) end },
  { "REFUSE", function(h, eq)
    -- errorHandler is the queue's final refusal callback. Refuse any newly queued
    -- profile retries too, with a bound so a broken retry loop becomes a failure.
    local index, refused = h.writeIndex, 0
    while h.queue.entries[index] and refused < 16 do
      local entry = h.queue.entries[index]
      eq(entry.command, h.api.writeCommand, "refusal path queues only profile writes")
      if entry.command ~= h.api.writeCommand then break end
      entry.errorHandler(entry, "refused")
      refused = refused + 1
      index = index + 1
      h.wakeup()
    end
    eq(refused > 0, true, "profile refusal delivered")
    eq(h.queue.entries[index], nil, "refusal leaves no unanswered work")
    local result = expectOutcome(h, "failed", false, eq)
    eq(result.step, h.spec.step, "failure identifies profile write")
    eq(countCommand(h, h.eeprom.command), 0, "refusal queues no EEPROM")
    expectReadCount(h, 1, "refusal queues no read-back", eq)
    eq(h.page.hasUnsavedChanges(), true, "refusal retains dirty edit")
    eq(h.ui.config[h.spec.field], h.editedValue, "refusal retains edited value")
    eq(h.ui.runtime.readPending, false, "refusal starts no read")
    eq(#h.reports, 0, "refusal has no misleading reportSave dialog")
  end },
  { "BUSY", function(h, eq)
    local before = #h.queue.entries
    local revision = h.pipeline.getRevision()
    eq(h.page.onSave(h.ctx), false, "second save refused while active")
    h.wakeup()
    eq(#h.queue.entries, before, "second save queues nothing")
    eq(countCommand(h, h.api.writeCommand), 1, "second save queues no duplicate profile write")
    eq(h.pipeline.getRevision(), revision, "second save does not replace pipeline run")
    eq(#h.reports, 0, "busy save opens no reportSave dialog")
    accept(h, eq)
  end }
}

-- Each page always writes one profile; Governor's global configuration is read only here.
for _, spec in ipairs({
  { name = "pids", api = "pid", reads = { "pid" },
    field = "pid_0_P", step = "MSP_SET_PID_TUNING" },
  { name = "governor", api = "governor", reads = { "governorConfig", "governor" },
    field = "governor_gain", step = "MSP_SET_GOVERNOR_PROFILE" }
}) do
  for _, scenario in ipairs(scenarios) do
    local label = spec.name .. " " .. scenario[1]
    local function eq(actual, expected, detail)
      equal(actual, expected, label .. " " .. detail)
    end
    -- Missing entry points or callback errors count as failures without aborting other pages.
    local ok, err = pcall(function()
      local h = newPage(spec)
      prepare(h, eq)
      scenario[2](h, eq)
    end)
    eq(ok, true, "scenario completed" .. (ok and "" or ": " .. tostring(err)))
  end
end

print("PIDs and Governor page saves: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
