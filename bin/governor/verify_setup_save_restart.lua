-- Drive the four Setup > Governor pages and the real save pipeline with a recorded MSP queue: a save
-- that changes a governor value restarts the flight controller after the EEPROM write, a save that
-- changes nothing does not, and Bypass Curve leaves a half-percent point it did not change as read.
-- Run from the repository root under lua5.3.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function scenario(label, run)
  local function eq(actual, expected, detail)
    equal(actual, expected, label .. " " .. detail)
  end
  local ok, err = pcall(function() run(eq) end)
  eq(ok, true, "scenario completed" .. (ok and "" or ": " .. tostring(err)))
end

local CMD = {
  govRead = 142, govWrite = 143, featureRead = 36, featureWrite = 37,
  eeprom = 250, reboot = 68, txinfo = 187,
}

local clock = 0
function getTime() return clock end

local sourceRoot = "src/rfsuite/"
local queue = { entries = {} }
function queue:add(entry) self.entries[#self.entries + 1] = entry end
function queue:clear() end
local mspState = { queue = queue, lastArmed = false, lastConnected = true, values = { mcuId = "board-a" } }

-- The controls a page builds, by label; Bypass Curve builds its point editors by hand.
local controls = {}
local Controls = {
  STATIC_SECTION_H = 50,
  CTRL_H = 32,
  LABEL_H = 21,
  appendStaticSectionHeader = function() end,
  appendNumberField = function(_, _, _, _, label, opts)
    controls[label] = opts
    return 32
  end,
  appendComboSelect = function(_, _, _, _, label, _, _, onChange)
    controls[label] = { set = onChange }
    return 32
  end,
}

local reported = {}
local stubs = {
  ["tasks/msp/runtime.lua"] = { getState = function() return mspState end },
  ["tasks/events/runtime.lua"] = { rerunOnconnect = function() end, isOnconnectActive = function() return false end },
  ["lib/log.lua"] = false,
  ["lib/armed.lua"] = { isArmed = function() return false end, isUncertain = function() return false end },
  ["ui/controls.lua"] = Controls,
  ["ui/loading_overlay.lua"] = { append = function() end },
  ["app/pages/settings/common.lua"] = {
    pageT = function() return function(_, _, fallback) return fallback end end,
    failPageRead = function(ui) ui.loading = false; ui.runtime.readPending = false; ui.runtime.readFailed = true end,
    resetPageState = function(ui) ui.loaded = false; ui.dirty = false end,
    appendReadFailedNotice = function() end,
  },
}
local Pipeline
function loadScript(path)
  local relative = assert(string.match(path, "^/SCRIPTS/RFSUITE/core/(.+)$"), path)
  if relative == "tasks/msp/save_pipeline.lua" and Pipeline then return function() return Pipeline end end
  local stub = stubs[relative]
  if stub == false then return nil end
  if stub then return function() return stub end end
  return loadfile(sourceRoot .. relative)
end
_G.rfsuite = { session = {}, palette = {}, paths = { core = "/SCRIPTS/RFSUITE/core" } }
Pipeline = assert(loadfile(sourceRoot .. "tasks/msp/save_pipeline.lua"))()
local GovernorApi = assert(loadfile(sourceRoot .. "tasks/msp/api/governor_config.lua"))()
local FeatureApi = assert(loadfile(sourceRoot .. "tasks/msp/api/feature_config.lua"))()

local function commands()
  local out = {}
  for _, e in ipairs(queue.entries) do out[#out + 1] = tostring(e.command) end
  return table.concat(out, ",")
end
local function find(command, from)
  for i = from or 1, #queue.entries do
    if queue.entries[i].command == command and not queue.entries[i].done then return queue.entries[i], i end
  end
end
local function ack(entry, bytes) entry.done = true; entry.processReply(entry, bytes or {}) end
-- Was this command queued at any point since the queue was last emptied, answered or not?
local function queued(command)
  for _, e in ipairs(queue.entries) do
    if e.command == command then return true end
  end
  return false
end

-- A governor configuration as the flight controller sends it; `overrides` by byte position.
local function governorReply(overrides)
  local buf = {}
  for i, v in ipairs(GovernorApi.simulatorResponse) do buf[i] = v end
  for i, v in pairs(overrides or {}) do buf[i] = v end
  return buf
end
-- Byte positions in MSP_SET_GOVERNOR_CONFIG / MSP_GOVERNOR_CONFIG.
local BYTE = { mode = 1, spoolup = 4, rpmFilter = 22, throttleType = 29, curve1 = 34 }

local function openPage(name, reply, featureBits)
  queue.entries = {}
  controls = {}
  reported = {}
  Pipeline.reset()
  mspState.lastArmed = false
  _G.rfsuite.session = { signature = "board-a" }
  local page = assert(loadfile(sourceRoot .. "app/pages/setup/governor/" .. name .. "/page.lua"))()
  local ctx = {
    children = {}, x = 0, y = 0, w = 480, h = 320,
    requestRebuild = function() end,
    reportSave = function(r) reported[#reported + 1] = r end,
  }
  page.wakeup(ctx)
  ack(assert(find(CMD.govRead), "governor read queued"), reply or governorReply())
  local feature = find(CMD.featureRead)
  if feature then ack(feature, FeatureApi.buildWritePayload({ enabledFeatures = featureBits or (1 << 26) })) end
  page.build(ctx)
  queue.entries = {}
  return page, ctx
end

-- Save and run the pipeline up to its restart: the writes and the EEPROM write answered, then the
-- clock probe that opens a restart. Returns whether MSP_REBOOT was queued and the governor payload.
local function save(page, ctx)
  local started = page.onSave(ctx)
  if not started then return nil end
  local write = find(CMD.govWrite)
  if not write then return false, nil end
  local payload = write.payload
  ack(write)
  local feature = find(CMD.featureWrite)
  if feature then ack(feature) end
  local eeprom = find(CMD.eeprom)
  if eeprom then ack(eeprom) end
  -- MSP_TX_INFO: RSSI source, then the clock flag the restart's pre-flight reads (1 = set).
  local probe = find(CMD.txinfo)
  if probe then ack(probe, { 0, 1 }) end
  return find(CMD.reboot) ~= nil, payload
end

-- 1. The comparison itself.
scenario("payloadDiffers", function(eq)
  local read = GovernorApi.parse(governorReply())
  local same = {}
  for k, v in pairs(read) do same[k] = v end
  eq(type(GovernorApi.payloadDiffers), "function", "exists")
  eq(GovernorApi.payloadDiffers(read, same), false, "an identical record does not differ")
  same.gov_d_filter = read.gov_d_filter + 1
  eq(GovernorApi.payloadDiffers(read, same), true, "one changed field differs")
end)

-- 2. Every page: a changed value restarts, an unedited save does not.
local PAGES = {
  { name = "general", label = "Throttle type", value = 2, byte = BYTE.throttleType },
  { name = "time", label = "Spoolup time", value = 150, byte = BYTE.spoolup },
  { name = "filters", label = "Headspeed Filter Cutoff", value = 33, byte = BYTE.rpmFilter },
}
for _, spec in ipairs(PAGES) do
  scenario(spec.name .. " changed value", function(eq)
    local page, ctx = openPage(spec.name)
    eq(controls[spec.label] ~= nil, true, "control '" .. spec.label .. "' built")
    controls[spec.label].set(spec.value)
    local rebooted, payload = save(page, ctx)
    eq(payload and payload[spec.byte], spec.value, "the new value is written")
    eq(rebooted, true, "the save restarts the flight controller (" .. commands() .. ")")
    eq(queued(CMD.txinfo), true, "the restart's clock probe is seen in the queue's history")
  end)
  scenario(spec.name .. " unedited save", function(eq)
    local page, ctx = openPage(spec.name)
    local rebooted, payload = save(page, ctx)
    eq(payload ~= nil, true, "the configuration is written")
    eq(rebooted, false, "no restart (" .. commands() .. ")")
    eq(queued(CMD.txinfo) or queued(CMD.reboot), false, "nothing of a restart queued (" .. commands() .. ")")
  end)
end

-- 3. General: a mode change still writes the feature and restarts.
scenario("general mode change", function(eq)
  local page, ctx = openPage("general", governorReply({ [BYTE.mode] = 3 }))
  controls["Mode"].set(0)
  local rebooted, payload = save(page, ctx)
  eq(payload and payload[BYTE.mode], 0, "the new mode is written")
  eq(string.find(commands(), tostring(CMD.featureWrite), 1, true) ~= nil, true, "the feature is written too")
  eq(rebooted, true, "the save restarts the flight controller (" .. commands() .. ")")
end)

-- 4. Bypass Curve: the points are edited by hand-built editors in order.
local function curveEditors(ctx)
  local out = {}
  for _, child in ipairs(ctx.children) do
    if child.type == "numberEdit" then out[#out + 1] = child end
  end
  return out
end
scenario("curves half-percent point left alone", function(eq)
  -- 25 = 12.5 %, shown as 13 %; the Configurator writes such points.
  local page, ctx = openPage("curves", governorReply({ [BYTE.curve1 + 1] = 25 }))
  eq(#curveEditors(ctx), 9, "nine point editors")
  local rebooted, payload = save(page, ctx)
  eq(payload and payload[BYTE.curve1 + 1], 25, "the half-percent point is written as read")
  eq(rebooted, false, "an unedited save does not restart (" .. commands() .. ")")
end)
scenario("curves changed point", function(eq)
  local page, ctx = openPage("curves", governorReply({ [BYTE.curve1 + 1] = 25 }))
  curveEditors(ctx)[5].set(60)
  local rebooted, payload = save(page, ctx)
  eq(payload and payload[BYTE.curve1 + 4], 120, "the changed point is written in half percent")
  eq(payload and payload[BYTE.curve1 + 1], 25, "the point left alone keeps its byte")
  eq(rebooted, true, "the save restarts the flight controller (" .. commands() .. ")")
end)

scenario("curves point edited and set back to its shown value", function(eq)
  -- 25 is shown as 13 %; the pilot sets it to 14 and back to 13: that is the value written.
  local page, ctx = openPage("curves", governorReply({ [BYTE.curve1 + 1] = 25 }))
  curveEditors(ctx)[2].set(14)
  curveEditors(ctx)[2].set(13)
  local rebooted, payload = save(page, ctx)
  eq(payload and payload[BYTE.curve1 + 1], 26, "the edited point is written as shown")
  eq(rebooted, true, "the stored point changed, so the save restarts (" .. commands() .. ")")
end)

-- 5. A failed save leaves the comparison with what was read, so the next Save restarts too.
scenario("time failed save then save again", function(eq)
  local page, ctx = openPage("time")
  controls["Spoolup time"].set(150)
  eq(page.onSave(ctx), true, "the first save starts")
  local write = assert(find(CMD.govWrite), "write queued")
  write.done = true
  write.errorHandler(write, "refused")
  eq(Pipeline.hasOutcome(), true, "the failed save ended with an outcome")
  eq(page.hasUnsavedChanges(), true, "the edit stays unsaved")
  queue.entries = {}
  local rebooted = save(page, ctx)
  eq(rebooted, true, "the second save restarts (" .. commands() .. ")")
end)

-- 6. A restart save whose notice was dismissed while its page stays open: the page claims the result
-- on its next wakeup instead of staying on its Saving overlay.
for _, spec in ipairs(PAGES) do
  scenario(spec.name .. " dismissed notice, page stays open", function(eq)
    local page, ctx = openPage(spec.name)
    controls[spec.label].set(spec.value)
    eq(page.onSave(ctx), true, "the save starts")
    ack(assert(find(CMD.govWrite), "write queued"))
    ack(assert(find(CMD.eeprom), "EEPROM write queued"))
    eq(Pipeline.isDismissible(), true, "stored and holding the page: the notice can be dismissed")
    Pipeline.dismiss()
    -- The restart then fails (no answer to the clock probe, reboot refused): the run ends held.
    local probe = assert(find(CMD.txinfo), "clock probe queued")
    probe.done = true
    probe.errorHandler(probe, "max_retries")
    local reboot = assert(find(CMD.reboot), "reboot queued")
    reboot.done = true
    reboot.errorHandler(reboot, "refused")
    eq(Pipeline.hasOutcome(), false, "the dismissed run reports nothing on screen")
    page.wakeup(ctx)
    eq(page.hasUnsavedChanges(), true, "the failed restart's result reached the page: the edit is unsaved")
    queue.entries = {}
    eq(page.onSave(ctx), true, "the page left its Saving state: Save works again on the same visit")
  end)
end

-- 7. Armed: the three pages that had their own chain refuse like General does.
for _, name in ipairs({ "time", "filters", "curves" }) do
  scenario(name .. " armed", function(eq)
    local page, ctx = openPage(name)
    mspState.lastArmed = true
    eq(page.onSave(ctx), false, "save refused")
    eq(#queue.entries, 0, "nothing queued")
    mspState.lastArmed = false
  end)
end

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
