-- Run the real rate-profile pages and save pipeline against scripted MSP replies.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local base = "app/pages/flight_tuning/"
local advanced = "advanced/rates_advanced/"
local pipelinePath = "tasks/msp/save_pipeline.lua"
local function newContext(reports)
  return {
    children = {}, x = 0, y = 0, w = 800, h = 480,
    requestRebuild = function() end,
    reportSave = function(report) reports[#reports + 1] = report end
  }
end

local function newPage(spec)
  -- Module handles, the queue and the pipeline's shared state belong to one scenario.
  _G.rfsuite = { palette = {}, session = {} }
  local ticks = 0
  function getTime() return ticks end
  local api = assert(loadfile("src/rfsuite/tasks/msp/api/rc_tuning.lua"))()
  local eeprom = assert(loadfile("src/rfsuite/tasks/msp/api/eeprom_write.lua"))()
  local queue = { entries = {} }
  function queue:add(entry) self.entries[#self.entries + 1] = entry end
  local mspState = { queue = queue, lastArmed = false, lastConnected = true }
  local dialogs, controls = {}, {}
  local modules = {
    ["app/pages/settings/common.lua"] = {
      pageT = function() return function(_, _, fallback) return fallback end end,
      createProfileAwareRuntime = function() return { syncHeaderTitle = function() end } end,
      resetPageState = assert(loadfile("src/rfsuite/app/pages/settings/common.lua"))().resetPageState
    },
    ["ui/controls.lua"] = {
      appendRadioSwitch = function() return 0 end,
      appendNumberField = function() return 0 end,
      -- Retain the Rate Table's real type-selection callback.
      appendComboSelect = function(_, _, _, _, _, _, _, setter)
        controls.selectType = setter
      end
    },
    ["ui/confirm_dialog.lua"] = {
      show = function(dialog) dialogs[#dialogs + 1] = dialog; return true end
    },
    ["ui/loading_overlay.lua"] = { append = function() end },
    ["lib/sensors.lua"] = {},
    ["lib/profile.lua"] = { getActiveRateProfile = function() return 1 end },
    ["lib/api_version.lua"] = {},
    ["lib/log.lua"] = {},
    ["tasks/msp/runtime.lua"] = { getState = function() return mspState end },
    ["tasks/events/runtime.lua"] = {},
    ["tasks/msp/api/rc_tuning.lua"] = api,
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
  local page = assert(loadfile("src/rfsuite/" .. base .. spec.path .. "/page.lua"))()
  local ui
  for i = 1, 20 do
    local key, value = debug.getupvalue(page.hasUnsavedChanges, i)
    if key == "ui" then ui = value; break end
    if not key then break end
  end
  assert(ui, "page state not found")
  local reports = {}
  local ctx = newContext(reports)
  local function wakeup()
    -- EdgeTX getTime() counts 10 ms ticks. Keep successful notices visible for inspection.
    ticks = ticks + 1
    pipeline.wakeup()
  end
  -- The board's RC tuning. A rate-type reset starts from a board on Rotorflight rates, so the
  -- selection of Actual is a change.
  local reply = {}
  for i, b in ipairs(api.simulatorResponse) do reply[i] = b end
  if spec.reset then reply[1] = 6 end
  return { page = page, ui = ui, api = api, eeprom = eeprom, queue = queue, reply = reply,
    pipeline = pipeline, ctx = ctx, reports = reports, wakeup = wakeup,
    dialogs = dialogs, controls = controls, spec = spec }
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

local function loadAndEdit(h, eq)
  eq(h.pipeline.isActive(), false, "fresh pipeline is idle")
  eq(h.pipeline.hasOutcome(), false, "fresh pipeline has no outcome")
  h.page.build(h.ctx)
  eq(type(h.ui.runtime.syncHeaderTitle), "function", "first build links runtime methods")
  h.page.wakeup(h.ctx)
  eq(#h.queue.entries, 1, "one initial read")
  local initial = assert(h.queue.entries[1], "initial read missing")
  eq(initial.command, h.api.command, "initial RC tuning read command")
  answer(h, initial, h.reply)
  eq(h.page.canSave(), true, "initial reply permits save")
  eq(h.page.hasUnsavedChanges(), false, "initial read is clean")
  eq(h.ui.runtime.readPending, false, "initial read completes")
  h.expected = assert(h.api.parse(h.reply))
  h.expectedDirty = not h.spec.unchanged

  if h.spec.reset then
    h.page.build(h.ctx)
    eq(h.ui.config.rates_type, 6, "the board starts with Rotorflight rates")
    assert(h.controls.selectType, "rate type setter missing")(4)
    eq(h.ui.config.rates_type, 4, "type selection stores Actual rates")
    eq(h.ui.runtime.resetRates, true, "type selection requests reset")
    h.expected.rates_type = 4
    -- Actual defaults: all four axes reset their rate, shape and expo fields.
    local rcRates, rates = { 18, 18, 18, 50 }, { 24, 24, 40, 50 }
    for axis = 1, 4 do
      h.expected["rcRates_" .. axis] = rcRates[axis]
      h.expected["rates_" .. axis] = rates[axis]
      h.expected["rcExpo_" .. axis] = 0
    end
  elseif not h.spec.unchanged then
    -- Number-field setters store raw values in ui.config and set ui.dirty.
    local field = h.spec.field
    local value = assert(h.ui.config[field], "initial field missing") + 1
    h.ui.config[field] = value
    h.ui.dirty = true
    h.expected[field] = value
  end
  -- A clean Rate Table Save exercises resetRates=false and must preserve the whole record.
  eq(h.page.hasUnsavedChanges(), h.expectedDirty, "edit state before save")
end

local function requestSave(h, eq)
  eq(h.page.onSave(h.ctx), true, "save accepted")
  if h.spec.reset then
    eq(#h.dialogs, 1, "changed rate type asks for confirmation")
    eq(#h.queue.entries, 1, "confirmation queues no write yet")
    eq(h.pipeline.isActive(), false, "confirmation starts no pipeline yet")
    eq(h.pipeline.hasOutcome(), false, "confirmation has no outcome")
    eq(h.page.hasUnsavedChanges(), true, "confirmation keeps edit dirty")
    eq(_G.rfsuite.session.rc_tuning.rates_type, 6, "confirmation leaves session unchanged")
  else
    eq(#h.dialogs, 0, "direct save asks no reset question")
  end
end

local function prepare(h, eq)
  loadAndEdit(h, eq)
  requestSave(h, eq)
  if h.spec.reset then
    assert(h.dialogs[1], "reset confirmation missing").onConfirm()
    eq(h.ui.runtime.resetRates, false, "confirmed reset is consumed")
  end
  h.wakeup()
  -- ui/home.lua adds an EEPROM write when this flag is true. Counting the page's
  -- queue alone would miss that second commit if the old Rates flag returned.
  eq(h.page.eepromWrite == true, false, "page requests no extra host EEPROM write")
  eq(#h.queue.entries, 2, "only RC tuning write queued before reply")
  local write = assert(h.queue.entries[2], "RC tuning write missing")
  eq(write.command, h.api.writeCommand, "save queues RC tuning write")
  eq(write.isWrite, true, "RC tuning command classified as write")
  local payload = assert(h.api.parse(write.payload), "invalid RC tuning payload")
  for field, value in pairs(h.expected) do
    eq(payload[field], value, "RC tuning payload " .. field)
  end
  eq(countCommand(h, h.eeprom.command), 0, "no EEPROM before RC tuning reply")
  eq(h.pipeline.isActive(), true, "host sees active page save")
  eq(h.pipeline.hasOutcome(), false, "pending write has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "write", "pipeline is writing")
  eq(progress.label, "MSP_SET_RC_TUNING", "pipeline identifies RC tuning write")
  eq(progress.total, 2, "one write step plus one commit")
  eq(progress.saved, false, "pending write is not saved")
  eq(h.page.hasUnsavedChanges(), h.expectedDirty, "pending write retains edit state")
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

local function awaitCommit(h, eq)
  answer(h, h.queue.entries[2], {})
  eq(#h.queue.entries, 3, "RC tuning reply queues only EEPROM next")
  local commit = assert(h.queue.entries[3], "EEPROM write missing")
  eq(commit.command, h.eeprom.command, "EEPROM follows RC tuning write")
  eq(commit.isWrite, true, "EEPROM classified as write")
  eq(#commit.payload, 0, "EEPROM payload is empty")
  eq(h.page.hasUnsavedChanges(), h.expectedDirty, "RC tuning reply retains edit state")
  eq(h.pipeline.hasOutcome(), false, "RC tuning reply alone has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "commit", "pipeline awaits EEPROM")
  eq(progress.saved, false, "pending EEPROM is not saved")
  eq(countCommand(h, h.api.command), 1, "no read-back before EEPROM reply")
  return commit
end

local function accept(h, eq)
  local commit = awaitCommit(h, eq)
  answer(h, commit, {})
  expectOutcome(h, "done", true, eq)
  eq(h.page.hasUnsavedChanges(), false, "EEPROM reply clears dirty")
  eq(countCommand(h, h.api.writeCommand), 1, "exactly one RC tuning write")
  eq(countCommand(h, h.eeprom.command), 1, "exactly one EEPROM write")
  eq(#h.queue.entries, 4, "successful save queues one read-back")
  eq(countCommand(h, h.api.command), 2, "initial read plus read-back")
  local readback = assert(h.queue.entries[4], "read-back missing")
  eq(readback.command, h.api.command, "read-back reads RC tuning")
  eq(h.ui.runtime.readPending, true, "read-back pending")
  eq(h.page.canSave(), false, "read-back blocks another save")
  answer(h, readback, h.reply)
  eq(h.ui.runtime.readPending, false, "read-back completes")
  eq(h.page.canSave(), true, "completed read-back permits save")
  eq(h.page.hasUnsavedChanges(), false, "read-back stays clean")
  -- The scripted board reply deliberately differs from the edit/reset payload.
  -- Verify that the page takes the board's values back, not its staged session values.
  for field, value in pairs(assert(h.api.parse(h.reply))) do
    eq(h.ui.config[field], value, "read-back updates " .. field)
  end
  eq(#h.queue.entries, 4, "read-back queues no further work")
  eq(countCommand(h, h.eeprom.command), 1, "read-back adds no second EEPROM write")
end

local function expectRefused(h, step, eq)
  local result = expectOutcome(h, "failed", false, eq)
  eq(result.step, step, "failure identifies refused step")
  eq(countCommand(h, h.api.command), 1, "refusal queues no read-back")
  eq(h.page.hasUnsavedChanges(), h.expectedDirty, "refusal retains edit state")
  eq(h.ui.runtime.readPending, false, "refusal starts no read")
  local field = h.spec.field or "rates_type"
  eq(h.ui.config[field], h.expected[field], "refusal retains edited value")
end

local scenarios = {
  { "ACCEPT", function(h, eq) accept(h, eq) end },
  { "CLOSE", function(h, eq)
    -- Leave the page the way app/pages/init.lua does: the first close hook the module has.
    local close = h.page.onClose or h.page.close or h.page.closePage or h.page.destroy
    assert(close, "page has no close hook")()
    answer(h, h.queue.entries[2], {})
    eq(#h.queue.entries, 3, "RC tuning reply after close queues only EEPROM")
    local commit = assert(h.queue.entries[3], "EEPROM write missing after close")
    eq(commit.command, h.eeprom.command, "EEPROM follows RC tuning write after close")
    answer(h, commit, {})
    expectOutcome(h, "done", true, eq)
    eq(countCommand(h, h.api.writeCommand), 1, "close repeats no RC tuning write")
    eq(countCommand(h, h.eeprom.command), 1, "close repeats no EEPROM write")
    eq(countCommand(h, h.api.command), 1, "closed page queues no read-back")
    eq(#h.queue.entries, 3, "successful save after close queues no further work")
  end },
  { "REOPEN", function(h, eq)
    h.page.build(h.ctx)
    local close = h.page.onClose or h.page.close or h.page.closePage or h.page.destroy
    assert(close, "page has no close hook")()
    eq(h.ui.runtime, nil, "close clears runtime")
    local ctx = newContext(h.reports)
    local ok, err = pcall(h.page.build, ctx)
    eq(ok, true, "build after close completed" .. (ok and "" or ": " .. tostring(err)))
    eq(type(h.ui.runtime), "table", "build after close restores runtime")
    eq(type(h.ui.runtime.syncHeaderTitle), "function", "build after close links runtime methods")
  end },
  { "REFUSE", function(h, eq)
    -- errorHandler is the queue's final refusal callback. Bound any newly queued
    -- RC tuning retries so a broken retry loop becomes an assertion failure.
    local index, refused = 2, 0
    while h.queue.entries[index] and refused < 16 do
      local entry = h.queue.entries[index]
      eq(entry.command, h.api.writeCommand, "refusal path queues only RC tuning writes")
      if entry.command ~= h.api.writeCommand then break end
      entry.errorHandler(entry, "refused")
      refused = refused + 1
      index = index + 1
      h.wakeup()
    end
    eq(refused > 0, true, "RC tuning refusal delivered")
    eq(h.queue.entries[index], nil, "refusal leaves no unanswered work")
    expectRefused(h, "MSP_SET_RC_TUNING", eq)
    eq(countCommand(h, h.eeprom.command), 0, "refusal queues no EEPROM")
  end },
  { "BUSY", function(h, eq)
    local before = #h.queue.entries
    local revision = h.pipeline.getRevision()
    local dialogs = #h.dialogs
    eq(h.page.onSave(h.ctx), false, "second save refused while active")
    h.wakeup()
    eq(#h.queue.entries, before, "second save queues nothing")
    eq(countCommand(h, h.api.writeCommand), 1, "second save queues no duplicate RC tuning write")
    eq(countCommand(h, h.eeprom.command), 0, "second save queues no early EEPROM")
    eq(h.pipeline.getRevision(), revision, "second save does not replace pipeline run")
    eq(#h.dialogs, dialogs, "busy save opens no reset confirmation")
    eq(#h.reports, 0, "busy save opens no reportSave dialog")
    accept(h, eq)
  end },
  { "REFUSE EEPROM", function(h, eq)
    local commit = awaitCommit(h, eq)
    assert(commit.errorHandler, "EEPROM refusal callback missing")(commit, "refused")
    h.wakeup()
    expectRefused(h, "commit", eq)
    eq(#h.queue.entries, 3, "failed commit queues no further work")
    eq(countCommand(h, h.api.writeCommand), 1, "failed commit repeats no RC tuning write")
    eq(countCommand(h, h.eeprom.command), 1, "failed commit repeats no EEPROM write")
  end }
}

local tableSpec = { name = "table reset", path = advanced .. "table", reset = true }
local function runScenario(spec, name, run)
  local label = spec.name .. " " .. name
  local function eq(actual, expected, detail)
    equal(actual, expected, label .. " " .. detail)
  end
  -- Missing entry points or callback errors count as failures without aborting other pages.
  local ok, err = pcall(function() run(newPage(spec), eq) end)
  eq(ok, true, "scenario completed" .. (ok and "" or ": " .. tostring(err)))
end

for _, spec in ipairs({
  { name = "rates", path = "rates", field = "rcRates_1" },
  { name = "advanced", path = advanced .. "advanced", field = "response_time_1" },
  { name = "cyclic_behaviour", path = advanced .. "cyclic_behaviour", field = "cyclic_ring" },
  tableSpec,
  { name = "table unchanged", path = advanced .. "table", unchanged = true }
}) do
  for _, scenario in ipairs(scenarios) do
    runScenario(spec, scenario[1], function(h, eq)
      prepare(h, eq)
      scenario[2](h, eq)
    end)
  end
end

runScenario(tableSpec, "CANCEL", function(h, eq)
  loadAndEdit(h, eq)
  local revision = h.pipeline.getRevision()
  requestSave(h, eq)
  local dialog = assert(h.dialogs[1], "reset confirmation missing")
  -- ConfirmDialog cancellation invokes onCancel only when the page supplies it.
  if type(dialog.onCancel) == "function" then dialog.onCancel() end
  h.wakeup()
  eq(#h.queue.entries, 1, "cancel queues no work beyond the initial read")
  eq(countCommand(h, h.api.writeCommand), 0, "cancel queues no RC tuning write")
  eq(countCommand(h, h.eeprom.command), 0, "cancel queues no EEPROM write")
  eq(h.pipeline.isActive(), false, "cancel leaves pipeline idle")
  eq(h.pipeline.hasOutcome(), false, "cancel reports no save outcome")
  eq(h.pipeline.getRevision(), revision, "cancel starts no pipeline run")
  eq(h.page.hasUnsavedChanges(), true, "cancel retains dirty type selection")
  eq(h.ui.runtime.resetRates, true, "cancel retains reset request")
  eq(h.ui.runtime.readPending, false, "cancel starts no read")
  eq(h.ui.config.rates_type, 4, "cancel retains selected type")
  for field, value in pairs(assert(h.api.parse(h.reply))) do
    eq(_G.rfsuite.session.rc_tuning[field], value, "cancel preserves session " .. field)
  end
  eq(#h.reports, 0, "cancel opens no reportSave dialog")
end)

print("Rates page saves: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
