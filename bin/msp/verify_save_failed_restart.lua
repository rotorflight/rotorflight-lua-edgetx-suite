-- Drive the real save pipeline with a recorded MSP queue: a save that fails after one of its writes
-- was acknowledged offers the restart, one that sent nothing does not, and the restart reboots the
-- board without storing anything. Run from the repository root under lua5.3.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local CMD = { write1 = 201, write2 = 202, eeprom = 250, reboot = 68, txinfo = 186 }

local clock = 0
function getTime() return clock end

local queue = { entries = {} }
function queue:add(entry) self.entries[#self.entries + 1] = entry end
local mspState = { queue = queue, lastArmed = false }
local onconnectActive = false

local modules = {
  ["tasks/msp/runtime.lua"] = { getState = function() return mspState end },
  ["tasks/events/runtime.lua"] = {
    rerunOnconnect = function() end,
    isOnconnectActive = function() return onconnectActive end,
  },
  ["tasks/msp/api/eeprom_write.lua"] = { command = CMD.eeprom },
  ["tasks/msp/api/reboot.lua"] = {
    writeCommand = CMD.reboot,
    buildWritePayload = function() return { 0 } end,
  },
  ["tasks/msp/api/tx_info.lua"] = {
    command = CMD.txinfo,
    parse = function(buf) return { rtc_datetime_set = buf and buf[1] } end,
  },
  ["lib/log.lua"] = false,
}

_G.rfsuite = { session = {}, paths = { core = "/SCRIPTS/RFSUITE/core" } }
function loadScript(path)
  local relative = string.match(path, "^/SCRIPTS/RFSUITE/core/(.+)$")
  local mod = modules[relative]
  assert(mod ~= nil, "unexpected module: " .. tostring(path))
  if mod == false then return nil end
  return function() return mod end
end

local Pipeline = assert(loadfile("src/rfsuite/tasks/msp/save_pipeline.lua"))()

local function last() return queue.entries[#queue.entries] end
local function ack(entry, bytes) entry.processReply(entry, bytes or {}) end
local function refuse(entry) entry.errorHandler(entry, "refused") end

local saved
local function begin(reboot)
  Pipeline.reset()
  queue.entries = {}
  mspState.lastArmed = false
  onconnectActive = false
  clock = 0
  saved = 0
  local ok, why = Pipeline.start({
    pageId = "test_page",
    steps = {
      { label = "W1", command = CMD.write1, payload = { 1 } },
      { label = "W2", command = CMD.write2, payload = { 2 } },
    },
    reboot = reboot == true,
    onSaved = function() saved = saved + 1 end,
  })
  equal(ok, true, "start " .. tostring(why))
end

local function outcome()
  local p = Pipeline.getProgress()
  return p and p.terminal and p or nil, p and p.result or nil
end

local function countCommand(command)
  local n = 0
  for _, e in ipairs(queue.entries) do if e.command == command then n = n + 1 end end
  return n
end

-- 1. The first write is refused: nothing reached the board, so no restart is offered.
begin()
refuse(last())
local p, r = outcome()
equal(p and p.status, "failed", "first refused: status")
equal(r and r.sentAny, false, "first refused: sentAny")
equal(Pipeline.offersRestart(r), false, "first refused: no offer")
local ok, why = Pipeline.restartAfterFailure()
equal(ok, false, "first refused: restart refused")
equal(why, "nothing_to_restore", "first refused: refusal reason")
equal(countCommand(CMD.reboot), 0, "first refused: no reboot queued")

-- 2. The second write is refused after the first was acknowledged: the restart is offered.
begin()
ack(last())
refuse(last())
p, r = outcome()
equal(p and p.status, "failed", "second refused: status")
equal(r and r.sentAny, true, "second refused: sentAny")
equal(r and r.saved, false, "second refused: not saved")
equal(Pipeline.offersRestart(r), true, "second refused: offer")

-- 3. Every write acknowledged, the EEPROM commit refused: the restart is offered.
begin()
ack(last()); ack(last())
equal(last().command, CMD.eeprom, "commit refused: commit queued")
refuse(last())
p, r = outcome()
equal(p and p.status, "failed", "commit refused: status")
equal(r and r.step, "commit", "commit refused: step")
equal(Pipeline.offersRestart(r), true, "commit refused: offer")
equal(saved, 0, "commit refused: onSaved not called")

-- 4. The second write is never answered: the step backstop ends it, and the restart is offered.
begin()
ack(last())
clock = 3200
Pipeline.wakeup()
p, r = outcome()
equal(p and p.status, "timeout", "write timeout: status")
equal(r and r.phase, "write", "write timeout: phase")
equal(Pipeline.offersRestart(r), true, "write timeout: offer")

-- 5. A save that worked offers nothing, and still clears itself.
begin()
ack(last()); ack(last()); ack(last())
p, r = outcome()
equal(p and p.status, "done", "success: status")
equal(r and r.saved, true, "success: saved")
equal(Pipeline.offersRestart(r), false, "success: no offer")
clock = clock + 300
Pipeline.wakeup()
equal(Pipeline.getProgress(), nil, "success: notice clears itself")

-- 6. A stored save whose reboot is not seen coming back is not a failure to restart from.
begin(true)
ack(last()); ack(last()); ack(last())
equal(last().command, CMD.txinfo, "reboot save: preflight probe")
ack(last(), { 1 })
ack(last())                                     -- MSP_REBOOT
clock = clock + 2200
Pipeline.wakeup()
p, r = outcome()
equal(p and p.status, "timeout", "reboot save timeout: status")
equal(r and r.saved, true, "reboot save timeout: saved")
equal(Pipeline.offersRestart(r), false, "reboot save timeout: no offer")

-- 7. Armed: the restart is refused and the outcome stays on screen.
begin()
ack(last())
refuse(last())
mspState.lastArmed = true
ok, why = Pipeline.restartAfterFailure()
equal(ok, false, "armed: restart refused")
equal(why, "armed", "armed: refusal reason")
equal(countCommand(CMD.reboot), 0, "armed: no reboot queued")
equal(Pipeline.offersRestart(select(2, outcome())), true, "armed: outcome kept")

-- 8. The restart: MSP_REBOOT and the wait for the board; nothing written, nothing stored.
begin()
ack(last())
refuse(last())
local before = #queue.entries
ok, why = Pipeline.restartAfterFailure()
equal(ok, true, "restart: started " .. tostring(why))
equal(Pipeline.isActive(), true, "restart: run active")
equal(Pipeline.blocksNavigation(), true, "restart: holds the page as a reboot save does")
local prog = Pipeline.getProgress()
equal(prog and prog.restart, true, "restart: progress marked")
equal(prog and prog.saved, false, "restart: progress not saved")
ok, why = Pipeline.restartAfterFailure()
equal(why, "busy", "restart: second press refused")
equal(last().command, CMD.txinfo, "restart: preflight probe first")
ack(last(), { 1 })
equal(last().command, CMD.reboot, "restart: MSP_REBOOT queued")
ack(last())
clock = clock + 100
Pipeline.wakeup()
equal(last().command, CMD.txinfo, "restart: probing for the board")
ack(last(), { 0 })                              -- the clock flag cleared: the board did restart
Pipeline.wakeup()                               -- onconnect ends -> verify probe
ack(last(), { 1 })
local writes, commits = 0, 0
for i = before + 1, #queue.entries do
  local c = queue.entries[i].command
  if c == CMD.write1 or c == CMD.write2 then writes = writes + 1 end
  if c == CMD.eeprom then commits = commits + 1 end
end
equal(writes, 0, "restart: no write sent")
equal(commits, 0, "restart: no EEPROM write sent")
equal(saved, 0, "restart: onSaved not called")
p, r = outcome()
equal(p and p.status, "done", "restart: status")
equal(r and r.restart, true, "restart: outcome marked")
equal(r and r.saved, false, "restart: not saved")
equal(r and r.rebootProven, true, "restart: restart proven")
equal(Pipeline.offersRestart(r), false, "restart: no second offer")
clock = clock + 300
Pipeline.wakeup()
equal(Pipeline.getProgress() ~= nil, true, "restart: outcome stands until read")
equal(Pipeline.dismiss(), true, "restart: dismissed")

-- 9. The board does not come back after the restart: the outcome says so as a restart.
begin()
ack(last())
refuse(last())
Pipeline.restartAfterFailure()
ack(last(), { 1 })
ack(last())
clock = clock + 2200
Pipeline.wakeup()
p, r = outcome()
equal(p and p.status, "timeout", "restart timeout: status")
equal(r and r.restart, true, "restart timeout: outcome marked")
equal(Pipeline.offersRestart(r), false, "restart timeout: no offer")

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
