-- A save that ended on its backstop owes the drop of its queued messages; when an instruction-limit
-- stop interrupted that drop, the dashboard widget finishes it on its next background pass, before
-- its MSP tick could send the ended run's message. Offline:
--
--   lua5.3 bin/dashboard/verify_left_save_owed_drop.lua
--
-- The accounting stubs supply EdgeTX, the flight controller and a temporary SD card. The real
-- dashboard runtime is created and called through widget.background, one host cycle of the stub
-- clock per round; the real save pipeline and MSP queue are reached through the shared state.
-- Exit status: 0 green, 1 failed expectations, 2 invalid arguments.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end
if #arg > 0 then
  io.stderr:write("usage: lua5.3 bin/dashboard/verify_left_save_owed_drop.lua\n")
  os.exit(2)
end

local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()
Stubs.clearCard()
Stubs.install(ROOT)
FC.install(Stubs)
Stubs.reset()
FC.reset()

local failures, checks = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
  end
end

local requireModule = _G.rfsuite.require
local MspRuntime = requireModule("tasks/msp/runtime.lua")
assert(type(MspRuntime) == "table" and type(MspRuntime.getState) == "function", "msp runtime did not load")
local DashboardRuntime = assert(loadfile(ROOT .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
local dashboard = DashboardRuntime.new({ x = 0, y = 0, w = 800, h = 458 }, {})

local function cycle()
  Stubs.tick()
  dashboard.background(dashboard)
end
for _ = 1, 60 do cycle() end

local queue = MspRuntime.getState().queue
assert(type(queue) == "table" and type(queue.add) == "function", "msp queue missing")

-- A message of an ended run: a write nobody may send any more. MSP_SET_NAME, which the stub flight
-- controller would answer -- so a send would show as a reply.
local function endedRunMessage(client)
  local m = { command = 11, payload = { 65 }, isWrite = true, client = client, reasons = {} }
  m.processReply = function() m.answered = true end
  m.errorHandler = function(_, reason) m.reasons[#m.reasons + 1] = reason end
  queue:add(m)
  return m
end

-- Control: with no drop owed, a message of another client is left alone by the drive.
local shared = assert(_G.rfsuite.tasks and _G.rfsuite.tasks.savePipeline or (function()
  _G.rfsuite.tasks = _G.rfsuite.tasks or {}
  _G.rfsuite.tasks.savePipeline = { run = nil, pending = {}, outcome = nil, revision = 0 }
  return _G.rfsuite.tasks.savePipeline
end)(), "shared save state missing")
shared.run, shared.outcome = nil, nil

local owed = endedRunMessage("save:verify_page")
shared.owedClear = "save:verify_page"
cycle()
check(shared.owedClear == nil, "the owed drop is done on the next background pass", shared.owedClear)
check(owed.reasons[1] == "cleared", "the ended run's message is dropped", owed.reasons[1])
check(owed.__sentAt == nil, "the ended run's message was not sent before the drop", owed.__sentAt)
check(owed.answered ~= true, "the ended run's message got no reply")

local other = endedRunMessage("verify:other")
cycle()
check(#other.reasons == 0, "control: with nothing owed, another client's message is not dropped",
  other.reasons[1])
for _ = 1, 20 do cycle() end
check(other.answered == true or other.__sentAt ~= nil, "control: that message is sent as usual",
  tostring(other.__sentAt))

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
