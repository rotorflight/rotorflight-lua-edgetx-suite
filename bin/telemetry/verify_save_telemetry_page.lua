-- Run the real Telemetry page and save pipeline against scripted MSP replies.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function copyBuffer(bytes)
  local copy = {}
  for i = 1, #bytes do copy[i] = bytes[i] end
  return copy
end

local function equalTable(actual, expected, eq, label)
  eq(type(actual), "table", label .. " is a table")
  if type(actual) ~= "table" then return end
  for key, value in pairs(expected) do
    if type(value) == "table" then
      equalTable(actual[key], value, eq, label .. "." .. tostring(key))
    else
      eq(actual[key], value, label .. "." .. tostring(key))
    end
  end
  for key in pairs(actual) do
    eq(expected[key] ~= nil, true, label .. " has no extra key " .. tostring(key))
  end
end

local pipelinePath = "tasks/msp/save_pipeline.lua"
local function newPage()
  -- Module handles, the queue and the pipeline's shared state belong to one scenario.
  _G.rfsuite = { palette = {}, session = {} }
  local ticks = 0
  function getTime() return ticks end
  local api = assert(loadfile("src/rfsuite/tasks/msp/api/telemetry_config.lua"))()
  local rx = assert(loadfile("src/rfsuite/tasks/msp/api/rx_config.lua"))()
  local eeprom = assert(loadfile("src/rfsuite/tasks/msp/api/eeprom_write.lua"))()
  local reboot = assert(loadfile("src/rfsuite/tasks/msp/api/reboot.lua"))()
  local txInfo = assert(loadfile("src/rfsuite/tasks/msp/api/tx_info.lua"))()
  local queue = { entries = {} }
  function queue:add(entry) self.entries[#self.entries + 1] = entry end
  local mspState = { queue = queue, lastArmed = false }
  local modules = {
    ["app/pages/settings/common.lua"] = {
      pageT = function() return function(_, _, fallback) return fallback end end,
      createFormRuntime = function() return {} end,
      -- Match Common.resetPageState's teardown of the fields used by this page.
      resetPageState = function(ui)
        ui.loaded = false
        ui.dirty = false
        ui.runtime = nil
      end
    },
    ["ui/controls.lua"] = {
      appendStaticSectionHeader = function() end,
      appendRadioSwitch = function() return 30 end
    },
    ["ui/loading_overlay.lua"] = { append = function() end },
    ["ui/confirm_dialog.lua"] = {},
    ["lib/api_version.lua"] = assert(loadfile("src/rfsuite/lib/api_version.lua"))(),
    ["lib/log.lua"] = {},
    ["tasks/msp/runtime.lua"] = { getState = function() return mspState end },
    ["tasks/events/runtime.lua"] = {},
    ["tasks/msp/api/telemetry_config.lua"] = api,
    ["tasks/msp/api/rx_config.lua"] = rx,
    ["tasks/msp/api/eeprom_write.lua"] = eeprom,
    ["tasks/msp/api/reboot.lua"] = reboot,
    ["tasks/msp/api/tx_info.lua"] = txInfo
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
  local page = assert(loadfile("src/rfsuite/app/pages/setup/telemetry/page.lua"))()
  local ui
  for i = 1, 20 do
    local key, value = debug.getupvalue(page.hasUnsavedChanges, i)
    if key == "ui" then ui = value; break end
    if not key then break end
  end
  assert(ui, "page state not found")
  local reports = {}
  local ctx = {
    children = {}, x = 0, y = 0, w = 480, h = 272,
    requestRebuild = function() end,
    reportSave = function(report) reports[#reports + 1] = report end
  }
  local function wakeup()
    -- EdgeTX getTime() counts 10 ms ticks. Keep successful notices visible for inspection.
    ticks = ticks + 1
    pipeline.wakeup()
  end
  return { page = page, ui = ui, api = api, rx = rx, eeprom = eeprom, reboot = reboot,
    txInfo = txInfo, queue = queue,
    pipeline = pipeline, ctx = ctx, reports = reports, wakeup = wakeup,
    session = _G.rfsuite.session }
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

local function unchangedSession(h, eq)
  eq(h.session.telemetry_config, h.originalConfig, "session keeps initial config object")
  equalTable(h.session.telemetry_config, h.initialConfig, eq, "session retains initial values")
  equalTable(h.session.rx_config, h.initialRx, eq, "session retains receiver values")
end

local function prepare(h, eq)
  eq(h.pipeline.isActive(), false, "fresh pipeline is idle")
  eq(h.pipeline.hasOutcome(), false, "fresh pipeline has no outcome")
  -- Telemetry has no wakeup hook: build starts both reads and creates the real setters.
  h.ui.group = "battery"
  h.page.build(h.ctx)
  eq(#h.queue.entries, 2, "two initial reads")
  local telemetryRead = assert(h.queue.entries[1], "initial telemetry read missing")
  local rxRead = assert(h.queue.entries[2], "initial receiver read missing")
  eq(telemetryRead.command, h.api.command, "initial telemetry read command")
  eq(rxRead.command, h.rx.command, "initial receiver read command")
  eq(telemetryRead.simulatorResponse, h.api.simulatorResponse, "telemetry read uses API fixture")
  eq(rxRead.simulatorResponse, h.rx.simulatorResponse, "receiver read uses API fixture")
  eq(h.page.canSave(), false, "pending initial reads prevent save")

  -- The telemetry simulator fixture has only 44 bytes; canSave requires all 40 slots
  -- (52 bytes). Complete a private reply copy with empty slots, preserving the fixture.
  h.initial = copyBuffer(h.api.simulatorResponse)
  for i = #h.initial + 1, 52 do h.initial[i] = 0 end
  h.initialConfig = assert(h.api.parse(h.initial))
  h.initialRx = assert(h.rx.parse(h.rx.simulatorResponse))
  answer(h, telemetryRead, h.initial)
  eq(h.page.canSave(), false, "telemetry reply alone does not permit save")
  eq(h.ui.runtime.readPending, true, "receiver reply still pending")
  answer(h, rxRead, h.rx.simulatorResponse)
  eq(h.page.canSave(), true, "both initial replies permit save")
  eq(h.ui.runtime.readPending, false, "initial reads completed")
  eq(h.page.hasUnsavedChanges(), false, "initial read is clean")
  h.originalConfig = h.session.telemetry_config
  unchangedSession(h, eq)

  -- Replace Battery Voltage with Cell Voltage through the page's actual switch setters.
  -- The new sensor fills the freed first slot; every other byte must stay unchanged.
  eq(h.ui.config[3], true, "Battery Voltage initially enabled")
  eq(h.ui.config[8], false, "Cell Voltage initially disabled")
  assert(h.ui.runtime.boolSetters[3], "Battery Voltage setter missing")(false)
  assert(h.ui.runtime.boolSetters[8], "Cell Voltage setter missing")(true)
  eq(h.ui.config[3], false, "switch disables Battery Voltage")
  eq(h.ui.config[8], true, "switch enables Cell Voltage")
  eq(h.page.hasUnsavedChanges(), true, "field edit marks dirty")
  h.expected = copyBuffer(h.initial)
  h.expected[13] = 8
  h.expectedConfig = assert(h.api.parse(h.expected))

  eq(h.page.onSave(h.ctx), true, "save accepted")
  h.wakeup()
  eq(#h.queue.entries, 3, "only telemetry write queued before reply")
  local write = assert(h.queue.entries[3], "telemetry write missing")
  eq(write.command, h.api.writeCommand, "save queues telemetry write")
  eq(write.isWrite, true, "telemetry command classified as write")
  equalTable(write.payload, h.expected, eq, "telemetry payload carries edited slots")
  equalTable(h.api.parse(write.payload), h.expectedConfig, eq, "parsed write values")
  eq(h.pipeline.isActive(), true, "host sees active page save")
  eq(h.pipeline.hasOutcome(), false, "pending write has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "write", "pipeline is writing")
  eq(progress.saved, false, "pending write is not saved")
  eq(h.page.hasUnsavedChanges(), true, "pending write stays dirty")
  eq(#h.reports, 0, "accepted save has no immediate reportSave dialog")
  unchangedSession(h, eq)
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
  eq(result.reboot, true, "a telemetry save restarts the flight controller")
  return result
end

local function expectNoReadback(h, eq)
  eq(countCommand(h, h.api.command), 1, "no telemetry read-back")
  eq(countCommand(h, h.rx.command), 1, "no receiver read-back")
  eq(countCommand(h, h.rx.writeCommand), 0, "save does not write receiver config")
end

local function awaitCommit(h, eq)
  answer(h, h.queue.entries[3], {})
  eq(#h.queue.entries, 4, "telemetry reply queues only EEPROM next")
  local commit = assert(h.queue.entries[4], "EEPROM write missing")
  eq(commit.command, h.eeprom.command, "EEPROM follows telemetry write")
  eq(commit.isWrite, true, "EEPROM classified as write")
  if not h.closed then
    eq(h.page.hasUnsavedChanges(), true, "telemetry reply alone does not clear dirty")
  end
  unchangedSession(h, eq)
  eq(h.pipeline.hasOutcome(), false, "telemetry reply alone has no outcome")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "commit", "pipeline awaits EEPROM")
  eq(progress.saved, false, "pending EEPROM is not saved")
  expectNoReadback(h, eq)
  return commit
end

local function acceptReboot(h, eq)
  -- After the EEPROM write the pipeline checks the RTC flag, restarts the board and waits
  -- for it to answer again; only then is the save done.
  eq(h.pipeline.hasOutcome(), false, "EEPROM reply waits for the restart")
  local progress = h.pipeline.getProgress() or {}
  eq(progress.phase, "preflight", "the restart starts with an RTC check")
  eq(progress.saved, true, "the restart starts only after the settings are stored")
  local preflight = assert(h.queue.entries[5], "preflight read missing")
  eq(preflight.command, h.txInfo.command, "preflight reads TX_INFO")
  answer(h, preflight, { 0, 1 })
  local reboot = assert(h.queue.entries[6], "reboot missing")
  eq(reboot.command, h.reboot.writeCommand, "MSP_REBOOT follows EEPROM and preflight")
  eq(countCommand(h, h.reboot.writeCommand), 1, "exactly one reboot queued")
  answer(h, reboot, {})
  eq((h.pipeline.getProgress() or {}).phase, "probe", "pipeline waits for reconnect")
  local probe = assert(h.queue.entries[7], "reconnect probe missing")
  eq(probe.command, h.txInfo.command, "reconnect reads TX_INFO")
  answer(h, probe, { 0, 0 })
  local verify = assert(h.queue.entries[8], "RTC verification missing")
  eq(verify.command, h.txInfo.command, "connect completion verifies TX_INFO")
  answer(h, verify, { 0, 1 })
end

local function accept(h, eq)
  local commit = awaitCommit(h, eq)
  answer(h, commit, {})
  acceptReboot(h, eq)
  local result = expectOutcome(h, "done", true, eq)
  eq(result.rebootProven, true, "the RTC reset proves the restart")
  eq(h.session.telemetry_config ~= h.originalConfig, true, "EEPROM success replaces session copy")
  equalTable(h.session.telemetry_config, h.expectedConfig, eq, "session holds written values")
  equalTable(h.session.rx_config, h.initialRx, eq, "save preserves receiver config")
  if h.closed then
    eq(h.ui.runtime, nil, "late success does not recreate closed runtime")
    eq(h.ui.telemetryBuffer, nil, "late success does not restore closed page buffer")
  else
    eq(h.page.hasUnsavedChanges(), false, "EEPROM reply clears dirty")
    equalTable(h.ui.telemetryBuffer, h.expected, eq, "page keeps written buffer")
    eq(h.ui.config[3], false, "page retains disabled sensor")
    eq(h.ui.config[8], true, "page retains enabled sensor")
    -- onDone requests a rebuild, but this page deliberately retains the saved values.
    h.ctx.children = {}
    h.page.build(h.ctx)
    eq(h.ui.runtime.readPending, false, "successful rebuild starts no read")
    eq(h.page.hasUnsavedChanges(), false, "successful rebuild stays clean")
  end
  eq(countCommand(h, h.api.writeCommand), 1, "exactly one telemetry write")
  eq(countCommand(h, h.eeprom.command), 1, "exactly one EEPROM write")
  eq(#h.queue.entries, 8, "success queues nothing after the restart's checks")
  eq(#h.reports, 0, "success uses pipeline outcome rather than reportSave")
  expectNoReadback(h, eq)
end

local function refuse(h, index, command, step, eq)
  -- errorHandler is the queue's final refusal callback. Refuse newly queued retries
  -- too, with a bound so a broken retry loop becomes an assertion failure.
  local refused = 0
  while h.queue.entries[index] and refused < 16 do
    local entry = h.queue.entries[index]
    eq(entry.command, command, "refusal path queues only the refused command")
    if entry.command ~= command then break end
    entry.errorHandler(entry, "refused")
    refused = refused + 1
    index = index + 1
    h.wakeup()
  end
  eq(refused > 0, true, "refusal delivered")
  eq(h.queue.entries[index], nil, "refusal leaves no unanswered work")
  local result = expectOutcome(h, "failed", false, eq)
  eq(result.step, step, "failure identifies refused step")
  unchangedSession(h, eq)
  eq(h.page.hasUnsavedChanges(), true, "refusal retains dirty edit")
  eq(h.ui.config[3], false, "refusal retains disabled sensor")
  eq(h.ui.config[8], true, "refusal retains enabled sensor")
  equalTable(h.ui.telemetryBuffer, h.initial, eq, "refusal retains original page buffer")
  eq(h.ui.runtime.readPending, false, "refusal starts no read")
  eq(#h.reports, 0, "refusal uses pipeline outcome rather than reportSave")
  expectNoReadback(h, eq)
end

local scenarios = {
  { "ACCEPT", function(h, eq) accept(h, eq) end },
  { "REFUSE", function(h, eq)
    refuse(h, 3, h.api.writeCommand, "MSP_SET_TELEMETRY_CONFIG", eq)
    eq(countCommand(h, h.eeprom.command), 0, "refusal queues no EEPROM")
  end },
  { "BUSY", function(h, eq)
    local before = #h.queue.entries
    local revision = h.pipeline.getRevision()
    eq(h.page.onSave(h.ctx), false, "second save refused while active")
    h.wakeup()
    eq(#h.queue.entries, before, "second save queues nothing")
    eq(countCommand(h, h.api.writeCommand), 1, "second save queues no duplicate telemetry write")
    eq(h.pipeline.getRevision(), revision, "second save does not replace pipeline run")
    eq(#h.reports, 0, "busy save opens no reportSave dialog")
    unchangedSession(h, eq)
    accept(h, eq)
  end },
  { "ACCEPT_CLOSED", function(h, eq)
    -- Clear page module handles before either write replies, as leaving the page does.
    h.page.onClose()
    h.closed = true
    eq(h.ui.runtime, nil, "close releases page runtime")
    eq(h.ui.telemetryBuffer, nil, "close releases page buffer")
    eq(h.pipeline.isActive(), true, "close does not cancel save")
    unchangedSession(h, eq)
    accept(h, eq)
  end },
  { "REFUSE_COMMIT", function(h, eq)
    awaitCommit(h, eq)
    refuse(h, 4, h.eeprom.command, "commit", eq)
    eq(countCommand(h, h.api.writeCommand), 1, "commit refusal does not repeat telemetry write")
  end }
}

for _, scenario in ipairs(scenarios) do
  local label = "telemetry " .. scenario[1]
  local function eq(actual, expected, detail)
    equal(actual, expected, label .. " " .. detail)
  end
  -- Missing entry points or callback errors count as failures without aborting other scenarios.
  local ok, err = pcall(function()
    local h = newPage()
    prepare(h, eq)
    scenario[2](h, eq)
  end)
  eq(ok, true, "scenario completed" .. (ok and "" or ": " .. tostring(err)))
end

print("Telemetry page saves: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
