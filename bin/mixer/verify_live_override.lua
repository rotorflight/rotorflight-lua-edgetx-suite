-- Setup > Mixer > Tail and Trims: the live override (app/pages/lib/live_override.lua) driven through
-- the real pages and the real MSP API modules, with the queue, the controls and the dialogs stubbed.
-- Run from the repository root: lua5.3 bin/mixer/verify_live_override.lua

local failures = 0
local checks = 0
local function check(cond, label)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL " .. label)
  end
end
local function equal(actual, expected, label)
  check(actual == expected, string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
end

local ticks = 1000
function getTime() return ticks end
local function advance(seconds) ticks = ticks + math.floor(seconds * 100 + 0.5) end

local queue = { messages = {}, busy = false }
function queue:isProcessed() return not self.busy end
function queue:add(message) self.messages[#self.messages + 1] = message; return true end
local function clearQueue() queue.messages = {}; queue.busy = false end
local function commands()
  local out = {}
  for i, m in ipairs(queue.messages) do out[i] = m.command end
  return table.concat(out, ",")
end
local function reply(bytes)
  local message = table.remove(queue.messages, 1)
  if not message then return nil end
  message.processReply(message, bytes)
  return message
end

local uncertain = false
local Armed = {
  isArmed = function() return false end,
  isUncertain = function() return uncertain end,
  changeCount = function() return 0 end
}

local fields = {}
local function capture(label, opts, onSelect)
  fields[label] = { opts = opts or {}, onSelect = onSelect }
  return 40
end
local Controls = {
  STATIC_SECTION_H = 50,
  appendStaticSectionHeader = function() return 50 end,
  appendNumberField = function(_, _, _, _, label, opts) return capture(label, opts) end,
  appendComboSelect = function(_, _, _, _, label, _, _, onSelect, opts) return capture(label, opts, onSelect) end
}

local lastDialog = nil
local ConfirmDialog = {
  show = function(definition)
    lastDialog = definition
    if definition.onConfirm then definition.onConfirm() end
    return true
  end
}

-- The save pipeline is stubbed with its phase: "write" from start until finishSave() ends it, as
-- the real one reports through getProgress() while a step or the EEPROM commit is ahead.
local saveRequest = nil
local savePhase = nil
local SavePipeline = {
  PHASE = { WRITE = "write", COMMIT = "commit" },
  takeResult = function() end,
  start = function(request) saveRequest = request; savePhase = "write"; return true end,
  getProgress = function() return savePhase and { phase = savePhase } or nil end
}
-- The pipeline's own order: onSaved after the EEPROM commit, then onDone. `held` is a run whose
-- overlay was dismissed: its onDone waits until the page claims the outcome, possibly much later.
local function finishSave(status, held)
  savePhase = nil
  if not saveRequest then return end
  if status == "done" and saveRequest.onSaved then saveRequest.onSaved() end
  if not held then saveRequest.onDone({ status = status }) end
end

local Common = {
  pageT = function() return function(_, _, fallback) return fallback end end,
  failPageRead = function() error("page read failed") end,
  resetPageState = function(ui)
    ui.loaded = false
    ui.dirty = false
    ui.runtime = nil
  end
}

-- The helper logs through lib/log.lua; every line is kept, so a check can ask for one.
local logged = {}
local Log = {
  emitf = function(tag, level, fmt, ...) logged[#logged + 1] = level .. " " .. tag .. ": " .. string.format(fmt, ...) end
}
local function loggedLine(pattern)
  for _, line in ipairs(logged) do
    if string.find(line, pattern) then return line end
  end
  return nil
end

local stubs = {
  ["app/pages/settings/common.lua"] = Common,
  ["ui/controls.lua"] = Controls,
  ["tasks/msp/runtime.lua"] = { getState = function() return { queue = queue } end },
  ["ui/loading_overlay.lua"] = { append = function() end },
  ["ui/confirm_dialog.lua"] = ConfirmDialog,
  ["tasks/msp/save_pipeline.lua"] = SavePipeline,
  ["lib/armed.lua"] = Armed,
  ["lib/log.lua"] = Log,
  ["ui/palette.lua"] = { muted = 1, border = 2, text = 3 }
}
local real = {
  ["tasks/msp/api/mixer_config.lua"] = true,
  ["tasks/msp/api/get_mixer_input_yaw.lua"] = true,
  ["app/pages/lib/live_override.lua"] = true
}
function loadScript(path)
  local relative = string.match(path, "/SCRIPTS/RFSUITE/core/(.+)$")
  if stubs[relative] then return function() return stubs[relative] end end
  if real[relative] then return assert(loadfile("src/rfsuite/" .. relative)) end
  error("unexpected loadScript path: " .. tostring(path))
end

-- The card roots, as lib/require.lua publishes them before any page is loaded.
_G.rfsuite = {
  session = { apiVersion = "12.10", fblConnected = true },
  paths = dofile("src/rfsuite/lib/paths.lua")
}

-- MIXER_CONFIG: main_rotor_dir, tail_rotor_mode, tail_motor_idle, tail_center_trim (S16), ...
local function mixerConfig(tailMode, trimRaw)
  local lo = trimRaw % 256
  local hi = math.floor(trimRaw / 256) % 256
  return { 0, tailMode, 0, lo, hi, 1, 0, 17, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
end
local YAW_INPUT = { 250, 0, 30, 251, 226, 4 }

local function payloadTrim(message)
  if message.command ~= 43 then return nil end
  local lo, hi = message.payload[4], message.payload[5]
  local v = hi * 256 + lo
  if v >= 0x8000 then v = v - 0x10000 end
  return v
end

local function freshPage(name)
  local page = assert(loadfile("src/rfsuite/app/pages/setup/mixer/" .. name .. "/page.lua"))()
  return page
end

local ctx = { requestRebuild = function() end, children = {}, x = 0, y = 0, w = 800, h = 416 }
local function build(page)
  fields = {}
  ctx.children = {}
  page.build(ctx)
end

------------------------------------------------------------------------------------------------
-- Tail
------------------------------------------------------------------------------------------------
local function openTail(tailMode, trimRaw)
  clearQueue()
  saveRequest = nil
  savePhase = nil
  local page = freshPage("tail")
  page.wakeup(ctx)
  reply(mixerConfig(tailMode, trimRaw))
  reply(YAW_INPUT)
  clearQueue()
  build(page)
  return page
end

do
  local page = openTail(1, 0)
  check(type(page.onStar) == "function", "tail: the page has a * action")
  equal(page.getHeaderActions().star, false, "tail: * not offered for a motorised tail")
  page.onClose()
end

do
  local page = openTail(0, 0)
  equal(page.getHeaderActions().star, true, "tail: * offered for variable pitch, nothing edited")
  fields["Yaw Calibration"].opts.set(260)
  equal(page.getHeaderActions().star, false, "tail: * not offered once another field is edited")
  equal(page.onStar and page.onStar({}) or false, false, "tail: * refuses with an unsaved edit")
  equal(#queue.messages, 0, "tail: nothing sent by a refused *")
  page.onClose()
end

do
  local page = openTail(0, 120)
  lastDialog = nil
  uncertain = true
  page.onStar({})
  uncertain = false
  check(lastDialog ~= nil and string.find(lastDialog.message, "The flight controller does not report whether it is armed", 1, true) == 1,
    "tail: the confirm says so first when the armed state is unknown")
  equal(commands(), "191", "tail: override on is one MSP_SET_MIXER_OVERRIDE")
  local m = queue.messages[1]
  equal(m and m.payload[1], 3, "tail: override index is the stabilized yaw input")
  equal(m and m.payload[2], 0, "tail: override value lo is 0 (hold at centre)")
  equal(m and m.payload[3], 0, "tail: override value hi is 0")
  clearQueue()

  build(page)
  -- The other settings are shown as text, not as controls: a disabled control that holds the
  -- focus keeps EXIT from the tool. The trim is the one control.
  equal(fields["Tail Mode"], nil, "tail: Tail Mode is no control while the override is on")
  equal(fields["Yaw Direction"], nil, "tail: Yaw Direction is no control")
  equal(fields["Yaw Calibration"], nil, "tail: Yaw Calibration is no control")
  equal(fields["Yaw CW Limit"], nil, "tail: Yaw CW Limit is no control")
  equal(fields["Yaw CCW Limit"], nil, "tail: Yaw CCW Limit is no control")
  check(fields["Yaw Center Trim"] ~= nil and fields["Yaw Center Trim"].opts.enabled ~= false,
    "tail: Yaw Center Trim drawn and editable")
  local shown = {}
  for _, child in ipairs(ctx.children) do
    if child.type == "label" and type(child.text) == "string" then shown[child.text] = true end
    check(child.type ~= "choice" and child.type ~= "numberEdit" and child.type ~= "button",
      "tail: nothing focusable besides the trim is built while the override is on")
  end
  check(shown["Tail Mode"] and shown["Variable Pitch"], "tail: Tail Mode still shown, as text")
  check(shown["Yaw Direction"] and shown["Yaw Calibration"] and shown["Yaw CW Limit"]
    and shown["Yaw CCW Limit"], "tail: the other settings still shown, as text")

  -- 12 = 1.2 degrees -> raw round(12 * 100 / 24) = 50
  fields["Yaw Center Trim"].opts.set(12)
  page.wakeup(ctx)
  equal(#queue.messages, 0, "tail: no write right after the change")
  advance(0.3)
  page.wakeup(ctx)
  equal(#queue.messages, 0, "tail: no write before 0.5 s without change")
  advance(0.25)
  page.wakeup(ctx)
  equal(commands(), "43", "tail: one MSP_SET_MIXER_CONFIG once the trim settled")
  equal(queue.messages[1] and payloadTrim(queue.messages[1]), 50, "tail: the live write carries the trim")
  equal(queue.messages[1] and queue.messages[1].payload[2], 0, "tail: the live write keeps the tail mode read")
  clearQueue()
  advance(1)
  page.wakeup(ctx)
  equal(#queue.messages, 0, "tail: an unchanged trim is not sent again")

  -- a busy queue holds the write back until it is free
  fields["Yaw Center Trim"].opts.set(24)
  page.wakeup(ctx)
  advance(0.6)
  queue.busy = true
  page.wakeup(ctx)
  equal(#queue.messages, 0, "tail: no live write while the queue is busy")
  queue.busy = false
  page.wakeup(ctx)
  equal(commands(), "43", "tail: the held write goes out once the queue is free")
  clearQueue()

  page.onClose()
  equal(commands(), "43,191", "tail: leaving without Save puts the trim back, then releases the override")
  equal(queue.messages[1] and payloadTrim(queue.messages[1]), 120, "tail: the rollback carries the trim read")
  local off = queue.messages[2]
  equal(off and off.payload[1], 3, "tail: release is for the yaw input")
  equal(off and (off.payload[3] * 256 + off.payload[2]), 2501, "tail: release value is 2501")
end

do
  local page = openTail(0, 0)
  page.onStar({})
  clearQueue()
  build(page)
  fields["Yaw Center Trim"].opts.set(-10)
  page.onSave({})
  check(saveRequest ~= nil, "tail: Save goes through the save pipeline")
  equal(saveRequest and #saveRequest.steps, 2, "tail: Save writes MIXER_CONFIG and the yaw input")
  equal(saveRequest and saveRequest.reboot, false, "tail: Save with the override on does not restart")
  finishSave("done")
  clearQueue()
  page.onClose()
  equal(commands(), "191", "tail: after Save, leaving only releases the override")
end

-- Leaving while a save is still on its way: no rollback between the save's steps.
do
  local page = openTail(0, 120)
  page.onStar({})
  clearQueue()
  build(page)
  fields["Yaw Center Trim"].opts.set(12)
  page.wakeup(ctx)
  advance(0.6)
  page.wakeup(ctx)
  clearQueue()
  page.onSave({})
  page.onClose()
  equal(commands(), "191", "tail: leaving during a save queues no rollback, only the release")
  finishSave("done")
end

-- The page module is kept between visits: once that save has ended, the next visit rolls back again.
do
  local page = openTail(0, 120)
  page.onStar({})
  clearQueue()
  build(page)
  fields["Yaw Center Trim"].opts.set(12)
  page.onSave({})
  page.onClose()
  finishSave("done", true)
  clearQueue()
  page.wakeup(ctx)
  reply(mixerConfig(0, 50))
  reply(YAW_INPUT)
  clearQueue()
  build(page)
  page.onStar({})
  clearQueue()
  build(page)
  fields["Yaw Center Trim"].opts.set(24)
  page.wakeup(ctx)
  advance(0.6)
  page.wakeup(ctx)
  clearQueue()
  page.onClose()
  equal(commands(), "43,191", "tail: a later visit of the same page rolls back after an earlier save ended")
  equal(queue.messages[1] and payloadTrim(queue.messages[1]), 50, "tail: that rollback carries this visit's read")
end

-- A save that fails after its configuration write: leaving still puts the record read back.
do
  local page = openTail(0, 120)
  page.onStar({})
  clearQueue()
  build(page)
  fields["Yaw Center Trim"].opts.set(12)
  page.onSave({}) -- before the live write was due
  finishSave("failed")
  clearQueue()
  page.onClose()
  equal(commands(), "43,191", "tail: after a failed save, leaving puts the trim back, then releases")
  equal(queue.messages[1] and payloadTrim(queue.messages[1]), 120, "tail: the rollback after a failed save carries the trim read")
end

------------------------------------------------------------------------------------------------
-- Trims
------------------------------------------------------------------------------------------------
local function openTrims(trimRaw)
  clearQueue()
  saveRequest = nil
  savePhase = nil
  local page = freshPage("trims")
  page.wakeup(ctx)
  reply(mixerConfig(0, trimRaw))
  clearQueue()
  build(page)
  return page
end

do
  local page = openTrims(165)
  local yaw = fields["Yaw. trim"]
  check(yaw ~= nil, "trims: yaw trim shown for a variable-pitch tail")
  equal(yaw and yaw.opts.get(), 40, "trims: yaw trim reads in 0.1 degree (165 raw -> 4.0)")
  equal(yaw and yaw.opts.display(40), "4.0°", "trims: yaw trim displayed in degrees")
  equal(yaw and yaw.opts.max, 250, "trims: yaw trim range is +-25.0 degrees")

  page.onStar({})
  equal(commands(), "191,191,191,191", "trims: override on holds all four inputs")
  for i = 1, 4 do
    equal(queue.messages[i] and queue.messages[i].payload[1], i, "trims: override input " .. i)
  end
  clearQueue()

  yaw.opts.set(25) -- 2.5 degrees -> raw round(2500 / 24) = 104
  page.wakeup(ctx)
  equal(commands(), "43", "trims: the first change goes out at once (periodic)")
  equal(queue.messages[1] and payloadTrim(queue.messages[1]), 104, "trims: degrees are written back as raw")
  clearQueue()
  fields["Roll trim"].opts.set(10)
  advance(0.1)
  page.wakeup(ctx)
  equal(#queue.messages, 0, "trims: at most one write per 200 ms")
  advance(0.15)
  page.wakeup(ctx)
  equal(commands(), "43", "trims: the next change goes out after 200 ms")
  clearQueue()

  page.onClose()
  equal(commands(), "43,191,191,191,191", "trims: leaving puts the trims back, then releases the four inputs")
  for i = 1, 4 do
    local release = queue.messages[i + 1]
    equal(release and release.payload[1], i, "trims: release " .. i .. " is for input " .. i)
    equal(release and (release.payload[3] * 256 + release.payload[2]), 2501, "trims: release " .. i .. " value is 2501")
  end
  equal(queue.messages[1] and payloadTrim(queue.messages[1]), 165, "trims: the rollback carries the yaw trim read")
end

do
  local page = openTrims(0)
  fields["Pitch trim"].opts.set(-20)
  page.onSave({})
  check(saveRequest ~= nil, "trims: Save goes through the save pipeline")
  equal(saveRequest and #saveRequest.steps, 1, "trims: Save writes MIXER_CONFIG once")
  equal(saveRequest and saveRequest.steps[1].command, 43, "trims: the save step is MSP_SET_MIXER_CONFIG")
  equal(saveRequest and saveRequest.reboot, false, "trims: Save does not restart")
  equal(#queue.messages, 0, "trims: Save queues nothing of its own beside the pipeline")
  page.onClose()
end

do
  local page = openTrims(165)
  page.onStar({})
  clearQueue()
  fields["Pitch trim"].opts.set(30)
  page.onSave({})
  page.onClose()
  equal(commands(), "191,191,191,191", "trims: leaving during a save queues no rollback, only the release")
  finishSave("done")
end

do
  local page = openTrims(165)
  page.onStar({})
  clearQueue()
  fields["Pitch trim"].opts.set(30)
  page.onSave({})
  finishSave("failed")
  clearQueue()
  page.onClose()
  equal(commands(), "43,191,191,191,191", "trims: after a failed save, leaving puts the trims back, then releases")
end

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
