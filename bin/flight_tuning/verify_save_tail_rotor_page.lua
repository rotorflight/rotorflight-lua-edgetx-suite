-- Run the real Tail Rotor page and save pipeline against scripted MSP replies.
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
  _G.rfsuite = { palette = {}, session = { apiVersion = spec.version } }
  _G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")
  local ticks = 0
  function getTime() return ticks end
  local api = assert(loadfile("src/rfsuite/tasks/msp/api/pid_profile.lua"))()
  local governor = assert(loadfile("src/rfsuite/tasks/msp/api/governor_profile.lua"))()
  local governorConfig = assert(loadfile("src/rfsuite/tasks/msp/api/governor_config.lua"))()
  local eeprom = assert(loadfile("src/rfsuite/tasks/msp/api/eeprom_write.lua"))()
  local apiVersion = assert(loadfile("src/rfsuite/lib/api_version.lua"))()
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
    ["lib/api_version.lua"] = apiVersion,
    ["lib/log.lua"] = {},
    ["tasks/msp/runtime.lua"] = { getState = function() return mspState end },
    ["tasks/events/runtime.lua"] = {},
    ["tasks/msp/api/pid_profile.lua"] = api,
    ["tasks/msp/api/governor_profile.lua"] = governor,
    ["tasks/msp/api/governor_config.lua"] = governorConfig,
    ["tasks/msp/api/eeprom_write.lua"] = eeprom,
    ["tasks/msp/api/reboot.lua"] = {},
    ["tasks/msp/api/tx_info.lua"] = {}
  }
  function loadScript(path)
    local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
    if relative == pipelinePath or relative == "lib/governor.lua" then
      return assert(loadfile("src/rfsuite/" .. relative))
    end
    assert(modules[relative], "unexpected module: " .. tostring(path))
    return function() return modules[relative] end
  end
  -- The host and page load separate instances; their public views must share the run.
  local pipeline = assert(loadfile("src/rfsuite/" .. pipelinePath))()
  local page = assert(loadfile("src/rfsuite/" .. base .. "tail_rotor/page.lua"))()
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
  local reads = { governorConfig, api }
  if spec.readGovernor then reads[#reads + 1] = governor end
  local steps = { { api = api, label = "MSP_SET_PID_PROFILE", field = "yaw_cw_stop_gain" } }
  if spec.writeGovernor then
    steps[#steps + 1] = { api = governor, label = "MSP_SET_GOVERNOR_PROFILE", field = "governor_tta_gain" }
  end
  return { page = page, ui = ui, api = api, governor = governor, governorConfig = governorConfig,
    eeprom = eeprom, queue = queue, pipeline = pipeline, ctx = ctx, reports = reports,
    wakeup = wakeup, spec = spec, reads = reads, steps = steps }
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

local function finishRead(h, first, eq)
  -- Both initial load and read-back chain Governor Config -> PID -> optional Governor Profile.
  for i, api in ipairs(h.reads) do
    local index = first + i - 1
    eq(#h.queue.entries, index, "read queues only the next request")
    local entry = assert(h.queue.entries[index], "read entry missing")
    eq(entry.command, api.command, "read command " .. i)
    eq(h.ui.runtime.readPending, true, "read remains pending until final reply")
    if api == h.governor and h.spec.refuseGovernorRead then
      entry.errorHandler(entry, "refused")
      h.wakeup()
    else
      answer(h, entry, api.simulatorResponse)
    end
  end
  eq(#h.queue.entries, first + #h.reads - 1, "read chain queues no further work")
  eq(h.ui.runtime.readPending, false, "read completes")
  eq(h.ui.runtime.governorReadComplete, h.spec.writeGovernor, "governor read availability")
  eq(h.page.canSave(), true, "read permits save, including PID-only partial load")
  eq(h.page.hasUnsavedChanges(), false, "read is clean")
end

local function expectWrite(h, stepIndex, eq)
  local step = h.steps[stepIndex]
  local entry = assert(h.queue.entries[#h.reads + stepIndex], "profile write missing")
  eq(entry.command, step.api.writeCommand, "write order: " .. step.label)
  eq(entry.isWrite, true, step.label .. " classified as write")
  eq(assert(step.api.parse(entry.payload))[step.field], step.value, step.label .. " carries edited value")
  eq(h.pipeline.isActive(), true, "host sees active page save")
  eq(h.pipeline.hasOutcome(), false, "pending write has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "write", "pipeline is writing")
  eq(progress.label, step.label, "progress identifies current write")
  eq(progress.saved, false, "pending write is not saved")
  eq(h.page.hasUnsavedChanges(), true, "pending write stays dirty")
  return entry
end

local function prepare(h, eq)
  eq(h.pipeline.isActive(), false, "fresh pipeline is idle")
  eq(h.pipeline.hasOutcome(), false, "fresh pipeline has no outcome")
  h.page.wakeup(h.ctx)
  eq(#h.queue.entries, 1, "one initial read queued")
  finishRead(h, 1, eq)

  -- Number-field setters store the raw value in ui.config and set ui.dirty.
  -- Edit a PID field and, only when available, a Tail Torque Assist field.
  for _, step in ipairs(h.steps) do
    step.value = assert(h.ui.config[step.field], "initial field missing") + 1
    h.ui.config[step.field] = step.value
  end
  h.ui.dirty = true
  eq(h.page.hasUnsavedChanges(), true, "field edit marks dirty")
  eq(h.page.onSave(h.ctx), true, "save accepted")
  h.wakeup()
  eq(#h.queue.entries, #h.reads + 1, "only PID write queued before reply")
  expectWrite(h, 1, eq)
  eq(countCommand(h, h.governor.writeCommand), 0, "no governor write before PID reply")
  eq(countCommand(h, h.eeprom.command), 0, "no EEPROM before profile replies")
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

local function expectReadCounts(h, runs, eq)
  eq(countCommand(h, h.governorConfig.command), runs, "governor config read count")
  eq(countCommand(h, h.api.command), runs, "PID read count")
  eq(countCommand(h, h.governor.command), h.spec.readGovernor and runs or 0, "governor profile read count")
  eq(countCommand(h, h.governorConfig.writeCommand), 0, "governor config is never written")
end

local function acceptWrites(h, eq)
  for i = 1, #h.steps do
    local entry = expectWrite(h, i, eq)
    answer(h, entry, {})
    eq(#h.queue.entries, #h.reads + i + 1, "profile reply queues only the next step")
    eq(h.page.hasUnsavedChanges(), true, "profile reply alone does not clear dirty")
    eq(h.pipeline.hasOutcome(), false, "profile reply alone has no outcome")
    expectReadCounts(h, 1, eq)
  end
  local commit = assert(h.queue.entries[#h.reads + #h.steps + 1], "EEPROM write missing")
  eq(commit.command, h.eeprom.command, "EEPROM follows every profile write")
  eq(commit.isWrite, true, "EEPROM classified as write")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "commit", "pipeline awaits EEPROM")
  eq(progress.saved, false, "pending EEPROM is not saved")
  eq(countCommand(h, h.api.writeCommand), 1, "exactly one PID write")
  eq(countCommand(h, h.governor.writeCommand), h.spec.writeGovernor and 1 or 0, "conditional governor write count")
  eq(countCommand(h, h.eeprom.command), 1, "exactly one EEPROM write")
  return commit
end

local function accept(h, eq)
  local commit = acceptWrites(h, eq)
  local before = #h.queue.entries
  answer(h, commit, {})
  expectOutcome(h, "done", true, eq)
  eq(h.page.hasUnsavedChanges(), false, "EEPROM reply clears dirty")
  eq(#h.queue.entries, before + 1, "successful save starts one read-back chain")
  eq(h.ui.runtime.readPending, true, "read-back pending")
  finishRead(h, before + 1, eq)
  expectReadCounts(h, 2, eq)
  eq(#h.reports, 0, "success opens no reportSave dialog")
end

local function refuse(h, stepIndex, eq)
  -- A second-step refusal first acknowledges PID, proving that Governor failure is terminal too.
  for i = 1, stepIndex - 1 do
    answer(h, expectWrite(h, i, eq), {})
    eq(#h.queue.entries, #h.reads + i + 1, "accepted prefix queues only the next write")
  end
  local step = h.steps[stepIndex]
  expectWrite(h, stepIndex, eq)
  -- errorHandler is the queue's final refusal callback. Bound any newly queued retries.
  local index, refused = #h.reads + stepIndex, 0
  while h.queue.entries[index] and refused < 16 do
    local entry = h.queue.entries[index]
    eq(entry.command, step.api.writeCommand, "refusal path queues only the refused write")
    if entry.command ~= step.api.writeCommand then break end
    entry.errorHandler(entry, "refused")
    refused = refused + 1
    index = index + 1
    h.wakeup()
  end
  eq(refused > 0, true, "write refusal delivered")
  eq(h.queue.entries[index], nil, "refusal leaves no unanswered work")
  local result = expectOutcome(h, "failed", false, eq)
  eq(result.step, step.label, "failure identifies refused write")
  eq(countCommand(h, h.eeprom.command), 0, "refusal queues no EEPROM")
  if stepIndex == 1 then
    eq(countCommand(h, h.governor.writeCommand), 0, "PID refusal queues no governor write")
  end
  expectReadCounts(h, 1, eq)
  eq(h.page.hasUnsavedChanges(), true, "refusal retains dirty edit")
  eq(h.ui.runtime.readPending, false, "refusal starts no read")
  eq(#h.reports, 0, "refusal uses pipeline outcome without a second dialog")
end

local scenarios = {
  { "ACCEPT", function(h, eq) accept(h, eq) end },
  { "REFUSE PID", function(h, eq) refuse(h, 1, eq) end },
  { "REFUSE GOVERNOR", function(h, eq) refuse(h, 2, eq) end, governorOnly = true },
  { "REFUSE EEPROM", function(h, eq)
    local commit = acceptWrites(h, eq)
    local before = #h.queue.entries
    commit.errorHandler(commit, "refused")
    h.wakeup()
    local result = expectOutcome(h, "failed", false, eq)
    eq(result.step, "commit", "failure identifies EEPROM commit")
    eq(#h.queue.entries, before, "EEPROM refusal queues nothing")
    expectReadCounts(h, 1, eq)
    eq(h.page.hasUnsavedChanges(), true, "EEPROM refusal retains dirty edit")
    eq(h.ui.runtime.readPending, false, "EEPROM refusal starts no read")
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

-- Governor writes require API >= 12.09, a successful read and a buildable payload.
-- The real simulator profile builds that payload; both version and read-failure gates are covered.
for _, spec in ipairs({
  { name = "12.09 PID + Governor", version = "12.09", readGovernor = true, writeGovernor = true },
  { name = "12.08 PID only", version = "12.08", readGovernor = false, writeGovernor = false },
  { name = "12.09 Governor read refused", version = "12.09", readGovernor = true,
    writeGovernor = false, refuseGovernorRead = true }
}) do
  for _, scenario in ipairs(scenarios) do
    if not scenario.governorOnly or spec.writeGovernor then
      local label = "tail_rotor " .. spec.name .. " " .. scenario[1]
      local function eq(actual, expected, detail)
        equal(actual, expected, label .. " " .. detail)
      end
      -- Missing entry points or callback errors count as failures without aborting other scenarios.
      local ok, err = pcall(function()
        local h = newPage(spec)
        prepare(h, eq)
        scenario[2](h, eq)
      end)
      eq(ok, true, "scenario completed" .. (ok and "" or ": " .. tostring(err)))
    end
  end
end

print("Tail Rotor page saves: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
