-- Setup > Servos > PWM Output and BUS Output: the servo override (app/pages/lib/live_override.lua)
-- driven through the real pages and the real MSP API modules, with the queue, the controls and the
-- dialogs stubbed. Every read is answered with the API module's own simulator response.
-- Run from the repository root: lua5.3 bin/servos/verify_live_override.lua

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
system = { getVersion = function() return { simulation = false } end }

local queue = { messages = {}, busy = false }
function queue:isProcessed() return not self.busy end
function queue:add(message) self.messages[#self.messages + 1] = message; return true end
local function clearQueue() queue.messages = {}; queue.busy = false end
local function commands()
  local out = {}
  for i, m in ipairs(queue.messages) do out[i] = m.command end
  return table.concat(out, ",")
end
-- Answers queued reads with their own simulator response until none is left, writes stay queued.
local function answerReads()
  local i = 1
  while i <= #queue.messages do
    local m = queue.messages[i]
    if m.isWrite then
      i = i + 1
    else
      table.remove(queue.messages, i)
      m.processReply(m, m.simulatorResponse or {})
      i = 1
    end
  end
end
local function u16(m, at)
  local p = m and m.payload
  if not p or p[at] == nil or p[at + 1] == nil then return nil end
  return p[at + 1] * 256 + p[at]
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
  ROW_H = 40,
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

local saveRequest = nil
local savePhase = nil
local SavePipeline = {
  PHASE = { WRITE = "write", COMMIT = "commit" },
  takeResult = function() end,
  start = function(request) saveRequest = request; savePhase = "write"; return true end,
  getProgress = function() return savePhase and { phase = savePhase } or nil end
}
local function finishSave(status)
  savePhase = nil
  if not saveRequest then return end
  if status == "done" and saveRequest.onSaved then saveRequest.onSaved() end
  saveRequest.onDone({ status = status, saved = status == "done" })
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

local logged = {}
local Log = {
  emitf = function(tag, level, fmt, ...) logged[#logged + 1] = level .. " " .. tag .. ": " .. string.format(fmt, ...) end
}

local function loggedLine(pattern)
  for _, line in ipairs(logged) do
    if string.find(line, pattern, 1, true) then return line end
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
  ["ui/palette.lua"] = { muted = 1, border = 2, text = 3 }
}
local loads = {}
function loadScript(path)
  local relative = string.match(path, "/SCRIPTS/RFSUITE/core/(.+)$")
  if relative then loads[relative] = (loads[relative] or 0) + 1 end
  if stubs[relative] then return function() return stubs[relative] end end
  if relative and (string.sub(relative, 1, 14) == "tasks/msp/api/" or relative == "lib/api_version.lua"
      or relative == "app/pages/lib/live_override.lua") then
    return assert(loadfile("src/rfsuite/" .. relative))
  end
  error("unexpected loadScript path: " .. tostring(path))
end

_G.rfsuite = {
  session = { apiVersion = "12.10", fblConnected = true, signature = "s" },
  paths = dofile("src/rfsuite/lib/paths.lua"),
  Log = Log
}

local asked = nil
local ctx = {
  requestRebuild = function() end,
  askUnsavedChanges = function(answers) asked = answers; return true end,
  children = {}, x = 0, y = 0, w = 800, h = 416
}
local function build(page)
  fields = {}
  ctx.children = {}
  page.build(ctx)
end
local function shownText()
  local shown = {}
  for _, child in ipairs(ctx.children) do
    if child.type == "label" and type(child.text) == "string" then shown[child.text] = true end
  end
  return shown
end

local function revisit(page)
  clearQueue()
  saveRequest = nil
  savePhase = nil
  page.wakeup(ctx)
  answerReads()
  clearQueue()
  page.wakeup(ctx)
  build(page)
  return page
end

local function open(name)
  clearQueue()
  saveRequest = nil
  savePhase = nil
  asked = nil
  local page = assert(loadfile("src/rfsuite/app/pages/setup/servos/" .. name .. "/page.lua"))()
  page.wakeup(ctx)
  answerReads()
  clearQueue()
  page.wakeup(ctx)
  build(page)
  return page
end

for _, name in ipairs({ "pwm", "bus" }) do
  -- The raw servoParams index of the page's first servo: PWM servo 1 is 0, bus servo 1 is 8.
  local raw0 = name == "pwm" and 0 or 8

  do
    loads["app/pages/lib/live_override.lua"] = nil
    local page = open(name)
    equal(page.canSave(), true, name .. ": the read completes")
    equal(page.getHeaderActions().help, true, name .. ": the header offers ?")
    equal(loads["app/pages/lib/live_override.lua"], nil, name .. ": the override helper is not loaded before *")
    check(fields["Center"] and fields["Center"].opts.helpText ~= nil, name .. ": rows carry an inline help text")
    check(fields["Servo"] ~= nil and fields["Minimum"] ~= nil, name .. ": selector and settings are controls with the override off")
    local orig = fields["Center"].opts.get()

    lastDialog = nil
    uncertain = true
    page.onStar({})
    uncertain = false
    check(loads["app/pages/lib/live_override.lua"] ~= nil, name .. ": * loads the override helper")
    check(lastDialog ~= nil and string.find(lastDialog.message, "The flight controller does not report whether it is armed", 1, true) == 1,
      name .. ": the confirm says so first when the armed state is unknown")
    equal(commands(), "196", name .. ": the override is one MSP_SET_SERVO_OVERRIDE_ALL")
    equal(queue.messages[1] and #queue.messages[1].payload, 2, name .. ": the override write carries no index")
    equal(u16(queue.messages[1], 1), 0, name .. ": the override holds the servos at centre")
    clearQueue()

    build(page)
    -- Only Center is a control: a disabled control that holds the focus keeps EXIT from the tool.
    check(fields["Center"] ~= nil, name .. ": Center stays a control")
    for _, label in ipairs({ "Servo", "Minimum", "Maximum", "Scale Negative", "Scale Positive", "Speed", "Reverse", "Geometry" }) do
      equal(fields[label], nil, name .. ": " .. label .. " is no control while the override is on")
    end
    local shown = shownText()
    check(shown["Servo"] and shown["Minimum"] and shown["Reverse"] and shown["Geometry"],
      name .. ": the locked settings are still shown, as text")
    if name == "pwm" then
      equal(fields["Rate"], nil, name .. ": Rate is no control while the override is on")
      check(shown["Rate"], name .. ": Rate still shown, as text")
    end

    fields["Center"].opts.set(orig + 20)
    page.wakeup(ctx)
    equal(commands(), "213", name .. ": a changed centre goes out as MSP_SET_SERVO_CENTER")
    local m = queue.messages[1]
    equal(m and m.payload[1], raw0, name .. ": the centre write takes the raw servo index")
    equal(u16(m, 2), orig + 20, name .. ": the centre write carries the centre")
    clearQueue()
    advance(1)
    page.wakeup(ctx)
    equal(#queue.messages, 0, name .. ": an unchanged centre is not sent again")

    fields["Center"].opts.set(orig + 25)
    page.wakeup(ctx)
    equal(commands(), "213", name .. ": a change after a quiet second goes out at once")
    clearQueue()
    fields["Center"].opts.set(orig + 30)
    advance(0.1)
    page.wakeup(ctx)
    equal(#queue.messages, 0, name .. ": at most one write per 200 ms")
    advance(0.15)
    page.wakeup(ctx)
    equal(commands(), "213", name .. ": the next change goes out after 200 ms")
    clearQueue()

    page.onClose()
    equal(commands(), "213,196", name .. ": leaving without Save puts the centre back, then releases the servos")
    equal(u16(queue.messages[1], 2), orig, name .. ": the rollback carries the centre read")
    equal(u16(queue.messages[2], 1), 2001, name .. ": the release value is 2001")
  end

  -- After a Save that reached EEPROM, leaving only releases.
  do
    local page = open(name)
    page.onStar({})
    clearQueue()
    build(page)
    fields["Center"].opts.set(fields["Center"].opts.get() + 15)
    page.wakeup(ctx)
    clearQueue()
    page.onSave({})
    check(saveRequest ~= nil and saveRequest.steps[1].command == 212, name .. ": Save writes the servo configuration")
    finishSave("done")
    clearQueue()
    page.onClose()
    equal(commands(), "196", name .. ": after Save, leaving only releases the servos")
  end

  -- Leaving while a save is still writing: no rollback between the save's steps.
  do
    local page = open(name)
    page.onStar({})
    clearQueue()
    build(page)
    fields["Center"].opts.set(fields["Center"].opts.get() + 15)
    page.wakeup(ctx)
    clearQueue()
    page.onSave({})
    fields["Center"].opts.set(fields["Center"].opts.get() + 5)
    page.onClose()
    equal(commands(), "196", name .. ": leaving during a save queues no rollback, only the release")
    finishSave("done")
  end

  -- A save that fails may have left its write in the board's RAM: leaving puts the centre back.
  do
    local page = open(name)
    local orig = fields["Center"].opts.get()
    page.onStar({})
    clearQueue()
    build(page)
    fields["Center"].opts.set(orig + 15)
    page.onSave({}) -- before the live write was due
    logged = {}
    finishSave("failed")
    clearQueue()
    page.onClose()
    equal(commands(), "213,196", name .. ": after a failed save, leaving puts the centre back, then releases")
    equal(u16(queue.messages[1], 2), orig, name .. ": that rollback carries the centre read")
    check(loggedLine("info rfsuite.servos." .. name .. ": save not stored") ~= nil, name .. ": the failed save is logged")
    check(loggedLine("info rfsuite.override: rollback: the board's record queued") ~= nil, name .. ": the rollback is logged")
  end

  -- Reload without Save puts the centre back before it reads again.
  do
    local page = open(name)
    local orig = fields["Center"].opts.get()
    page.onStar({})
    clearQueue()
    build(page)
    fields["Center"].opts.set(orig + 15)
    page.wakeup(ctx)
    clearQueue()
    page.onReload({})
    local first = queue.messages[1]
    equal(first and first.command, 213, name .. ": Reload puts the centre back first")
    equal(u16(first, 2), orig, name .. ": the Reload rollback carries the centre read")
    if name == "pwm" then
      equal(queue.messages[2] and queue.messages[2].command, 196, name .. ": then Reload switches the override off")
    end
    page.onClose()
  end

  -- Discard on the question before another servo is picked: a centre sent live goes back, and the
  -- override then follows the servo that was picked.
  do
    local page = open(name)
    local orig = fields["Center"].opts.get()
    page.onStar({})
    clearQueue()
    build(page)
    fields["Center"].opts.set(orig + 25)
    page.wakeup(ctx)
    clearQueue()
    page.onStar({}) -- off again, so the selector is a control
    equal(commands(), "196", name .. ": * again releases the servos")
    clearQueue()
    build(page)
    check(fields["Servo"] ~= nil, name .. ": the selector is a control again with the override off")
    fields["Servo"].onSelect(1)
    check(asked ~= nil, name .. ": picking another servo with an unsaved centre asks first")
    if asked then asked.discard() end
    equal(queue.messages[1] and queue.messages[1].command, 213, name .. ": Discard puts the centre sent live back")
    equal(queue.messages[1] and queue.messages[1].payload[1], raw0, name .. ": for the servo it was sent for")
    equal(u16(queue.messages[1], 2), orig, name .. ": with the centre read")
    table.remove(queue.messages, 1)
    answerReads()
    clearQueue()
    build(page)
    page.onStar({})
    clearQueue()
    build(page)
    fields["Center"].opts.set(fields["Center"].opts.get() + 10)
    advance(0.25)
    page.wakeup(ctx)
    equal(queue.messages[1] and queue.messages[1].payload[1], raw0 + 1, name .. ": the override then sends the servo picked")
    clearQueue()
    page.onClose()
    equal(commands(), "213,196", name .. ": leaving puts that servo's centre back, then releases")
    equal(queue.messages[1] and queue.messages[1].payload[1], raw0 + 1, name .. ": the rollback is for the servo picked")
  end
  -- The page module is kept between visits: a second visit of the same module starts clean.
  do
    local page = open(name)
    page.onStar({})
    clearQueue()
    build(page)
    fields["Center"].opts.set(fields["Center"].opts.get() + 15)
    page.wakeup(ctx)
    clearQueue()
    page.onClose()
    revisit(page)
    equal(page.canSave(), true, name .. ": a second visit of the same module reads again")
    check(fields["Servo"] ~= nil, name .. ": a second visit starts with the override off")
    page.onStar({})
    equal(commands(), "196", name .. ": a second visit switches the override on again")
    clearQueue()
    page.onClose()
    equal(commands(), "196", name .. ": a second visit with nothing edited only releases")
  end

  -- An override made earlier for another servo: a save of the servo picked since, which fails,
  -- still puts that servo's centre back when the page is left.
  do
    local page = open(name)
    page.onStar({})
    page.onStar({})
    clearQueue()
    build(page)
    fields["Servo"].onSelect(1)
    answerReads()
    clearQueue()
    build(page)
    local orig = fields["Center"].opts.get()
    fields["Center"].opts.set(orig + 12)
    page.onSave({})
    finishSave("failed")
    clearQueue()
    page.onClose()
    equal(commands(), "213", name .. ": after a failed save of the servo picked since *, leaving puts its centre back")
    equal(queue.messages[1] and queue.messages[1].payload[1], raw0 + 1, name .. ": for the servo picked")
    equal(u16(queue.messages[1], 2), orig, name .. ": with its centre read")
  end
end

print(string.format("%d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end
