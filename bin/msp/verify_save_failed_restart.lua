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
-- As the real Queue:clear(clientId): that client's waiting messages are dropped and each one's
-- errorHandler is told "cleared". The record keeps them, marked.
function queue:clear(client)
  for _, e in ipairs(self.entries) do
    if not e.cleared and not e.done and e.client == client then
      e.cleared = true
      if e.errorHandler then e.errorHandler(e, "cleared") end
    end
  end
end
local mspState = { queue = queue, lastArmed = false, lastConnected = true }
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
local function ack(entry, bytes) entry.done = true; entry.processReply(entry, bytes or {}) end
local function refuse(entry) entry.done = true; entry.errorHandler(entry, "refused") end
-- The queue's give-up after its retries with no answer at all: the message was sent.
local function silent(entry) entry.done = true; entry.__sentAt = clock / 100; entry.errorHandler(entry, "max_retries") end

local saved
local function begin(reboot)
  Pipeline.reset()
  queue.entries = {}
  mspState.lastArmed = false
  mspState.lastConnected = true
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

-- 10. A late reply of a save that timed out does not drive the restart that follows it: the second
--     write of the ended run answers after the restart started, and nothing is stored.
begin()
ack(last())
local lateWrite = last()                        -- W2, never answered in time
clock = 3200
Pipeline.wakeup()
equal(select(2, outcome()).status, "timeout", "late reply: the save timed out")
ok = Pipeline.restartAfterFailure()
equal(ok, true, "late reply: restart started")
local probe = last()
ack(lateWrite)                                  -- the ended run's write is answered now
equal(countCommand(CMD.eeprom), 0, "late reply: no EEPROM write queued for the restart")
equal(last(), probe, "late reply: nothing queued by the ended run's reply")
local prog10 = Pipeline.getProgress()
equal(prog10 and prog10.phase, "preflight", "late reply: the restart's phase is untouched")
refuse(lateWrite)                               -- nor does its give-up fail the restart
local prog10b = Pipeline.getProgress()
equal(prog10b and prog10b.phase, "preflight", "late give-up: the restart still runs, in its pre-flight")

-- 11. The same for two saves: the commit of a save that timed out is answered while the next save
--     waits on its first write, and the next save is not reported as stored.
begin()
ack(last()); ack(last())
local lateCommit = last()
equal(lateCommit.command, CMD.eeprom, "late commit: commit queued")
clock = clock + 3200
Pipeline.wakeup()
Pipeline.dismiss()
saved = 0
ok = Pipeline.start({ pageId = "next_page", steps = { { label = "W1", command = CMD.write1, payload = { 1 } } },
  onSaved = function() saved = saved + 1 end })
equal(ok, true, "late commit: next save started")
ack(lateCommit)
equal(saved, 0, "late commit: the next save's onSaved not called")
local prog11 = Pipeline.getProgress()
equal(prog11 and prog11.saved, false, "late commit: the next save not marked stored")
equal(prog11 and prog11.phase, "write", "late commit: the next save still waits on its write")

-- 12. A write that was sent and never answered may have been taken: the restart is offered. One the
--     board refused, or one cleared before it was sent, was not.
begin()
silent(last())
p, r = outcome()
equal(r and r.sentAny, true, "silent first write: counts as reached")
equal(Pipeline.offersRestart(r), true, "silent first write: offer")
begin()
last().done = true
last().errorHandler(last(), "cleared")          -- never sent: no __sentAt
p, r = outcome()
equal(r and r.sentAny, false, "first write cleared before sending: not reached")
equal(Pipeline.offersRestart(r), false, "first write cleared before sending: no offer")
equal(Pipeline.restartPossible(), true, "restartPossible with a link, disarmed")

-- 13. No link: the restart is refused and the outcome stays.
begin()
ack(last()); refuse(last())
mspState.lastConnected = false
equal(Pipeline.restartPossible(), false, "no link: restartPossible false")
ok, why = Pipeline.restartAfterFailure()
equal(ok, false, "no link: restart refused")
equal(why, "no_link", "no link: refusal reason")
equal(Pipeline.offersRestart(select(2, outcome())), true, "no link: outcome kept")

-- 14. The link drops between the press and the reboot: no MSP_REBOOT is queued.
begin()
ack(last()); refuse(last())
equal(Pipeline.restartAfterFailure(), true, "link drop: restart started")
mspState.lastConnected = false
ack(last(), { 1 })                              -- the pre-flight answer arrives, the link is gone
equal(countCommand(CMD.reboot), 0, "link drop: no reboot queued")
p, r = outcome()
equal(r and r.restart, true, "link drop: the restart reports")
equal(Pipeline.blocksNavigation(), false, "link drop: the page is free again")

-- 15. The reboot itself never completes: the backstop ends the restart, and its queued reboot is dropped.
begin()
ack(last()); refuse(last())
Pipeline.restartAfterFailure()
ack(last(), { 1 })
local reboot15 = last()
equal(reboot15.command, CMD.reboot, "reboot stuck: reboot queued")
equal(reboot15.completeAfterAttempt, 2, "reboot stuck: the reboot completes on silence after two sends")
clock = clock + 3200
Pipeline.wakeup()
p, r = outcome()
equal(p and p.status, "timeout", "reboot stuck: timeout")
equal(r and r.phase, "reboot", "reboot stuck: phase")
equal(reboot15.cleared, true, "reboot stuck: the queued reboot is dropped")
equal(Pipeline.blocksNavigation(), false, "reboot stuck: the page is free again")

-- 16. A save that times out at its commit drops its queued EEPROM write, so the restart offered
--     after it cannot be preceded by a late store.
begin()
ack(last()); ack(last())
local commit16 = last()
clock = clock + 3200
Pipeline.wakeup()
equal(commit16.cleared, true, "commit timeout: the queued EEPROM write is dropped")
equal(Pipeline.offersRestart(select(2, outcome())), true, "commit timeout: offer")

-- 17. Seen restarting, then the connect chain is slow: the outcome keeps rebootProven.
begin()
ack(last()); refuse(last())
Pipeline.restartAfterFailure()
ack(last(), { 1 }); ack(last())
clock = clock + 100
Pipeline.wakeup()
onconnectActive = true
ack(last(), { 0 })                              -- the board did restart
clock = clock + 1600
Pipeline.wakeup()
p, r = outcome()
equal(p and p.status, "timeout", "slow connect: timeout")
equal(r and r.phase, "onconnect", "slow connect: phase")
equal(r and r.rebootProven, true, "slow connect: the restart was seen")

-- 18. A late give-up of an ended save does not fail the next ordinary save.
begin()
ack(last()); ack(last())
local commit18 = last()
clock = clock + 3200
Pipeline.wakeup()
Pipeline.dismiss()
commit18.cleared = nil                          -- as if the give-up came from the wire, not the clear
equal(Pipeline.start({ pageId = "next_page", steps = { { label = "W1", command = CMD.write1, payload = { 1 } } } }),
  true, "late give-up: next save started")
commit18.errorHandler(commit18, "max_retries")
local prog18 = Pipeline.getProgress()
equal(prog18 and prog18.phase, "write", "late give-up: the next save still waits on its write")
equal(prog18 and prog18.terminal, nil, "late give-up: the next save has no outcome")

-- 19. An outcome marked as a restart never offers another, whatever else it says.
equal(Pipeline.offersRestart({ status = "failed", saved = false, sentAny = true, restart = true }), false,
  "restart outcome: never offers a restart")
equal(Pipeline.offersRestart({ status = "failed", saved = false, sentAny = true }), true,
  "the same outcome of a save: offers")

-- 20. While an ordinary save runs, a restart is refused.
begin()
ok, why = Pipeline.restartAfterFailure()
equal(ok, false, "save running: restart refused")
equal(why, "busy", "save running: refusal reason")

-- 21. The tool closing during a restart leaves it standing: its outcome is shown when the tool opens.
begin()
ack(last()); refuse(last())
Pipeline.restartAfterFailure()
equal(Pipeline.dismissWhenStored(), false, "tool closes: the restart is not parked")
ack(last(), { 1 }); ack(last())
clock = clock + 2200
Pipeline.wakeup()
p, r = outcome()
equal(p and p.terminal, true, "tool closes: the restart's outcome stands in the notice")
equal(r and r.restart, true, "tool closes: it is the restart's")

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
