local checks = 0
local function equal(actual, expected, label)
  checks = checks + 1
  assert(actual == expected, string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
end

LCD_H = 480
SMLSIZE, DBLSIZE = 1, 2
WHITE, BLACK, YELLOW = 0xFFFFFF, 0, 0xFFFF00
COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_PRIMARY3 = 1, 2, 3
COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2 = 4, 5
lvgl = { PAGE_BODY_HEIGHT = 416 }

local ticks = 100
function getTime() return ticks end

local armedNow, armedLast, armedChanges = false, nil, 0
local Armed = {}
function Armed.isArmed()
  if armedLast ~= nil and armedLast ~= armedNow then armedChanges = armedChanges + 1 end
  armedLast = armedNow
  return armedNow
end
function Armed.changeCount() return armedChanges end
function Armed.isUncertain() return false end

local queue = { messages = {}, busy = false }
function queue:isProcessed() return not self.busy end
function queue:add(message)
  self.messages[#self.messages + 1] = message
  return true
end
local function nextMessage()
  local message = table.remove(queue.messages, 1)
  assert(message, "expected queued MSP message")
  return message
end
local function reply(bytes)
  local message = nextMessage()
  queue.busy = true
  message.processReply(message, bytes)
  queue.busy = false
  return message
end
local function failReply()
  local message = nextMessage()
  queue.busy = true
  message.errorHandler(message)
  queue.busy = false
  return message
end

local rebuilds = 0
local confirmCallback = nil
local saveRequest = nil
local Common = {}
function Common.pageT()
  return function(_, _, fallback) return fallback end
end
function Common.failPageRead() error("page read failed") end
function Common.resetPageState(ui)
  ui.loaded = false
  ui.dirty = false
  ui.runtime = nil
end

local SavePipeline = { takeResult = function() end, start = function(request) saveRequest = request; return true end }
local Controls = {
  ROW_H = 64,
  labelY = function(y) return y + 20 end,
  controlY = function(y) return y + 16 end,
  estimateWrappedTextHeight = function() return 16 end
}
local LoadingOverlay = { append = function(children, definition) children[#children + 1] = definition end }
local ConfirmDialog = {}
local dialogsShown, lastDialog = 0, nil
function ConfirmDialog.show(definition)
  confirmCallback = definition.onConfirm
  dialogsShown = dialogsShown + 1
  lastDialog = definition.message
  return true
end

local actual = {
  ["tasks/msp/api/board_alignment_config.lua"] = true,
  ["tasks/msp/api/sensor_alignment.lua"] = true,
  ["tasks/msp/api/board_auto_align.lua"] = true,
  ["lib/api_version.lua"] = true,
  ["app/pages/setup/alignment/auto_align_lifecycle.lua"] = true,
  ["ui/palette.lua"] = true
}
local stubs = {
  ["app/pages/settings/common.lua"] = Common,
  ["ui/controls.lua"] = Controls,
  ["tasks/msp/runtime.lua"] = { getState = function() return { queue = queue } end },
  ["ui/loading_overlay.lua"] = LoadingOverlay,
  ["ui/confirm_dialog.lua"] = ConfirmDialog,
  ["tasks/msp/save_pipeline.lua"] = SavePipeline,
  ["lib/armed.lua"] = Armed
}

function loadScript(path)
  local relative = string.match(path, "/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
  if stubs[relative] then return function() return stubs[relative] end end
  if actual[relative] then return assert(loadfile("src/rfsuite/" .. relative)) end
  if relative == "app/pages/setup/alignment/help.lua" then return function() return function() end end end
  error("unexpected loadScript path: " .. tostring(path))
end

local function newSession(id, api)
  return { signature = api .. ":" .. id, apiVersion = api, fblConnected = true }
end
_G.rfsuite = { session = newSession("board-a", "12.10") }

local Page = assert(loadfile("src/rfsuite/app/pages/setup/alignment/page.lua"))()
local wakeContext = { requestRebuild = function() rebuilds = rebuilds + 1 end }
local function wake() Page.wakeup(wakeContext) end
local function clearQueue() queue.messages = {}; queue.busy = false end

local function deliverInitialReads()
  wake()
  local board = nextMessage()
  equal(board.command, 38, "board alignment read command")
  queue.busy = true
  board.processReply(board, { 0, 0, 0, 0, 0, 0 })
  queue.busy = false
  local sensor = nextMessage()
  equal(sensor.command, 126, "sensor alignment read command")
  queue.busy = true
  sensor.processReply(sensor, { 0, 0, 0 })
  queue.busy = false
  equal(#queue.messages, 0, "capability deferred after read callback")
  wake()
  equal(#queue.messages, 1, "capability queued on later wakeup")
  equal(queue.messages[1].command, 0x5F13, "capability command")
  equal(queue.messages[1].payload[1], 0, "capability poll action")
  equal(queue.messages[1].isWrite, false, "capability classified read")
end

local function buildChildren()
  local children = {}
  Page.build({ children = children, x = 0, y = 0, w = 800, h = 400, i18n = nil, requestRebuild = wakeContext.requestRebuild })
  return children
end
local function findButton(children, text)
  for i = 1, #children do
    if children[i].type == "button" and children[i].text == text then return children[i] end
  end
end
local function numberFields(children)
  local fields = {}
  for i = 1, #children do if children[i].type == "numberEdit" then fields[#fields + 1] = children[i] end end
  return fields
end
local function reopen(session)
  Page.onClose()
  clearQueue()
  confirmCallback = nil
  _G.rfsuite.session = session
  armedNow, armedLast, armedChanges = false, nil, 0
  deliverInitialReads()
end

-- Supported happy path through the real page callbacks and real controls.
deliverInitialReads()
reply({ 0, 0, 0, 0, 0, 0, 0, 0 })
local children = buildChildren()
local auto = findButton(children, "Auto-align")
equal(type(auto), "table", "supported action visible")
auto.press()
equal(type(confirmCallback), "function", "start confirmation captured")
equal(#queue.messages, 0, "start waits for confirmation")
confirmCallback()
equal(#queue.messages, 1, "confirmed start queued")
equal(queue.messages[1].payload[1], 1, "start action")
equal(queue.messages[1].isWrite, true, "start classified write")
equal(queue.messages[1].maxRetries, 0, "start is not retried")
equal(Page.canSave(), false, "save blocked while start pending")
equal(Page.onReload(), false, "reload blocked while start pending")
reply({ 1, 0, 0, 0, 0, 0, 0, 4 })
equal(Page.canSave(), false, "save blocked while waiting")
children = buildChildren()
equal(type(findButton(children, "Lift Tail")), "table", "waiting guidance visible")
ticks = ticks + 30
wake()
equal(queue.messages[1].payload[1], 0, "waiting status poll")
equal(queue.messages[1].isWrite, false, "status poll classified read")
reply({ 2, 10, 0, 0xEC, 0xFF, 0x0E, 0x01, 12 })
equal(Page.canSave(), true, "save enabled after success")
equal(Page.hasUnsavedChanges(), true, "success marks fields dirty")
local fields = numberFields(buildChildren())
equal(fields[1].get(), 10, "success roll getter")
equal(fields[2].get(), -20, "success pitch getter")
equal(fields[3].get(), 270, "success yaw getter")
equal(Page.onSave({}), true, "successful alignment starts existing Save pipeline")
local boardPayload = saveRequest.steps[1].payload
equal(boardPayload[1], 10, "saved roll low byte")
equal(boardPayload[2], 0, "saved roll high byte")
equal(boardPayload[3], 0xEC, "saved pitch low byte")
equal(boardPayload[4], 0xFF, "saved pitch high byte")
equal(boardPayload[5], 0x0E, "saved yaw low byte")
equal(boardPayload[6], 0x01, "saved yaw high byte")

-- Capability rejection hides the action and does not poison the valid page read.
reopen(newSession("board-b", "12.10"))
failReply()
equal(Page.canSave(), true, "capability error keeps normal read valid")
equal(findButton(buildChildren(), "Auto-align"), nil, "unsupported action hidden")
equal(#queue.messages, 0, "unsupported capability does not loop")

-- A running procedure discovered by the capability poll gets a fresh local observation window.
reopen(newSession("board-running", "12.10"))
reply({ 1, 0, 0, 0, 0, 0, 0, 2 })
equal(Page.canSave(), false, "discovered running procedure blocks save")
ticks = ticks + 30; wake()
equal(queue.messages[1].command, 0x5F13, "discovered running procedure is polled")
clearQueue(); Page.onClose()

-- A lost START reply is polled, while a lost procedure poll forces a normal reload.
reopen(newSession("board-c", "12.10"))
reply({ 0, 0, 0, 0, 0, 0, 0, 0 })
auto = findButton(buildChildren(), "Auto-align"); auto.press(); confirmCallback()
failReply()
equal(Page.canSave(), false, "lost start keeps save blocked")
ticks = ticks + 30; wake()
equal(queue.messages[1].command, 0x5F13, "lost start followed by status poll")
failReply()
equal(Page.canSave(), false, "lost procedure poll keeps save blocked")
wake()
equal(queue.messages[1].command, 38, "lost procedure poll reloads alignment")

-- An unknown terminal state is not treated as safe to save.
Page.onClose(); clearQueue(); _G.rfsuite.session = newSession("board-unknown", "12.10")
deliverInitialReads(); reply({ 0, 0, 0, 0, 0, 0, 0, 0 })
auto = findButton(buildChildren(), "Auto-align"); auto.press(); confirmCallback()
reply({ 1, 0, 0, 0, 0, 0, 0, 1 })
ticks = ticks + 30; wake()
reply({ 99, 0, 0, 0, 0, 0, 0, 0 })
equal(Page.canSave(), false, "unknown procedure state blocks save")
wake()
equal(queue.messages[1].command, 38, "unknown procedure state reloads alignment")

-- A disconnect before the START reply invalidates the request and reloads after reconnect.
Page.onClose(); clearQueue(); _G.rfsuite.session = newSession("board-pending-disconnect", "12.10")
deliverInitialReads(); reply({ 0, 0, 0, 0, 0, 0, 0, 0 })
auto = findButton(buildChildren(), "Auto-align"); auto.press(); confirmCallback()
local disconnectedStart = nextMessage()
_G.rfsuite.session.fblConnected = false
wake()
equal(Page.canSave(), false, "pending start disconnect blocks save")
equal(#queue.messages, 0, "disconnect does not queue a read on a dead link")
_G.rfsuite.session.fblConnected = true
equal(Page.onReload(), true, "reconnect releases stuck Reload")
equal(queue.messages[1].command, 38, "reconnect queues normal alignment read")
disconnectedStart.processReply(disconnectedStart, { 2, 45, 0, 0, 0, 0, 0, 12 })
equal(Page.canSave(), false, "disconnected start reply stays stale")
reply({ 0, 0, 0, 0, 0, 0 })
reply({ 0, 0, 0 })
equal(Page.canSave(), true, "reconnect normal read restores save")

-- An arm/disarm edge before the first START reply invalidates and reloads the form.
Page.onClose(); clearQueue(); _G.rfsuite.session = newSession("board-pending-arm", "12.10")
armedNow, armedLast, armedChanges = false, nil, 0
deliverInitialReads(); reply({ 0, 0, 0, 0, 0, 0, 0, 0 })
auto = findButton(buildChildren(), "Auto-align"); auto.press(); confirmCallback()
local armedPendingStart = nextMessage()
armedNow = true; Armed.isArmed()
armedNow = false; Armed.isArmed()
wake()
equal(Page.canSave(), false, "pending start arm edge blocks save")
equal(queue.messages[1].command, 38, "pending start arm edge queues normal read")
armedPendingStart.processReply(armedPendingStart, { 2, 60, 0, 0, 0, 0, 0, 12 })
equal(Page.canSave(), false, "armed-edge start reply stays stale")
reply({ 0, 0, 0, 0, 0, 0 })
reply({ 0, 0, 0 })
equal(Page.canSave(), true, "arm-edge normal read restores save")

-- A delayed dialog confirmation cannot start after the visit is closed.
Page.onClose(); clearQueue(); _G.rfsuite.session = newSession("board-d", "12.10")
deliverInitialReads(); reply({ 0, 0, 0, 0, 0, 0, 0, 0 })
auto = findButton(buildChildren(), "Auto-align"); auto.press()
local staleConfirm = confirmCallback
Page.onClose(); clearQueue(); _G.rfsuite.session = newSession("board-e", "12.10")
staleConfirm()
equal(#queue.messages, 0, "closed visit confirmation ignored")

-- A response from the previous session and one spanning an armed transition are ignored.
deliverInitialReads(); reply({ 0, 0, 0, 0, 0, 0, 0, 0 })
auto = findButton(buildChildren(), "Auto-align"); auto.press(); confirmCallback()
local staleStart = nextMessage()
_G.rfsuite.session = newSession("board-f", "12.10")
staleStart.processReply(staleStart, { 2, 44, 0, 0, 0, 0, 0, 12 })
equal(#queue.messages, 0, "old session response ignored")
Page.onClose(); clearQueue(); _G.rfsuite.session = newSession("board-g", "12.10")
deliverInitialReads(); reply({ 0, 0, 0, 0, 0, 0, 0, 0 })
auto = findButton(buildChildren(), "Auto-align"); auto.press(); confirmCallback()
local armedStart = nextMessage()
armedNow = true
armedStart.processReply(armedStart, { 1, 0, 0, 0, 0, 0, 0, 1 })
equal(findButton(buildChildren(), "Lift Tail"), nil, "armed-transition response ignored")

-- A locally observed timeout locks Save and queues a normal reload.
Page.onClose(); clearQueue(); _G.rfsuite.session = newSession("board-h", "12.10")
armedNow, armedLast, armedChanges = false, nil, 0
deliverInitialReads(); reply({ 0, 0, 0, 0, 0, 0, 0, 0 })
auto = findButton(buildChildren(), "Auto-align"); auto.press(); confirmCallback()
reply({ 1, 0, 0, 0, 0, 0, 0, 1 })
ticks = ticks + 1700
wake()
equal(Page.canSave(), false, "timeout blocks save")
equal(queue.messages[1].command, 38, "timeout queues normal reload")

-- The firmware keeps SUCCESS, TIMEOUT, NO_MATCH and the REJECTED states until the next START.
-- A page opened (or reloaded) later must not take that left-over result for its own: the
-- capability poll only learns that the command is supported. IDLE is the clean control.
local heldStates = {
  { 2, "SUCCESS" }, { 3, "REJECTED_ARMED" }, { 4, "TIMEOUT" }, { 5, "NO_MATCH" },
  { 6, "REJECTED_UNCALIBRATED" }, { 0, "IDLE" }
}
local heldFailures = {}
for _, held in ipairs(heldStates) do
  local ok, err = pcall(function()
    Page.onClose(); clearQueue(); _G.rfsuite.session = newSession("board-held-" .. held[2], "12.10")
    armedNow, armedLast, armedChanges = false, nil, 0
    deliverInitialReads()
    dialogsShown, lastDialog = 0, nil
    reply({ held[1], 90, 0, 0, 0, 0, 0, 12 })
    equal(dialogsShown, 0, "held " .. held[2] .. " popped a dialog on open (" .. tostring(lastDialog) .. ")")
    equal(Page.hasUnsavedChanges(), false, "held " .. held[2] .. " dirtied the page on open")
    equal(numberFields(buildChildren())[1].get(), 0, "held " .. held[2] .. " replaced the read roll")
    equal(Page.canSave(), true, "held " .. held[2] .. " locked Save on open")
    equal(#queue.messages, 0, "held " .. held[2] .. " queued a request on open")
    equal(type(findButton(buildChildren(), "Auto-align")), "table", "held " .. held[2] .. " hid Auto-align")
    -- Reload polls again; the same left-over state must stay quiet there too.
    equal(Page.onReload(), true, "held " .. held[2] .. " Reload offered")
    reply({ 0, 0, 0, 0, 0, 0 })
    reply({ 0, 0, 0 })
    wake()
    equal(queue.messages[1] and queue.messages[1].command, 0x5F13, "held " .. held[2] .. " re-polled after Reload")
    reply({ held[1], 90, 0, 0, 0, 0, 0, 12 })
    equal(dialogsShown, 0, "held " .. held[2] .. " popped a dialog after Reload (" .. tostring(lastDialog) .. ")")
    equal(Page.canSave(), true, "held " .. held[2] .. " locked Save after Reload")
  end)
  if not ok then heldFailures[#heldFailures + 1] = tostring(err) end
end
equal(#heldFailures, 0, table.concat(heldFailures, "; "))

-- Positive control: a run this visit started still reports its own TIMEOUT.
Page.onClose(); clearQueue(); _G.rfsuite.session = newSession("board-own-timeout", "12.10")
armedNow, armedLast, armedChanges = false, nil, 0
deliverInitialReads(); reply({ 0, 0, 0, 0, 0, 0, 0, 0 })
auto = findButton(buildChildren(), "Auto-align"); auto.press(); confirmCallback()
dialogsShown = 0
reply({ 1, 0, 0, 0, 0, 0, 0, 1 })
ticks = ticks + 30; wake()
reply({ 4, 0, 0, 0, 0, 0, 0, 0 })
equal(dialogsShown, 1, "own TIMEOUT result shown")

-- A confirmed START is queued even while other traffic is in the queue; polls still wait.
Page.onClose(); clearQueue(); _G.rfsuite.session = newSession("board-busy", "12.10")
armedNow, armedLast, armedChanges = false, nil, 0
deliverInitialReads(); reply({ 0, 0, 0, 0, 0, 0, 0, 0 })
auto = findButton(buildChildren(), "Auto-align"); auto.press()
queue.busy = true
confirmCallback()
queue.busy = false
equal(queue.messages[1] and queue.messages[1].payload[1], 1, "confirmed start queued behind busy traffic")
equal(Page.canSave(), false, "busy-queue start locks save")

-- The page asks the tool's shared lib/armed.lua: only that copy sees the arm/disarm changes.
do
  local asked = nil
  Page.onClose(); clearQueue(); _G.rfsuite.session = newSession("board-shared-armed", "12.10")
  _G.rfsuite.require = function(path) asked = path; return Armed end
  wake()
  _G.rfsuite.require = nil
  equal(asked, "lib/armed.lua", "page took the shared lib/armed.lua")
end

print(string.format("board auto-align page: %d checks passed", checks))
