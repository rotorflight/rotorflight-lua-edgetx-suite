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

local CMD = { write1 = 201, write2 = 202, eeprom = 250, reboot = 68, txinfo = 186, status = 101 }

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
local mspState = { queue = queue, lastArmed = false, lastConnected = true, values = { mcuId = "board-a" } }
local onconnectActive = false
local armedNow, armedUnknown = false, false

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
  ["tasks/msp/api/status.lua"] = assert(loadfile("src/rfsuite/tasks/msp/api/status.lua"))(),
  ["lib/armed.lua"] = {
    isArmed = function() return armedNow end,
    isUncertain = function() return armedUnknown end,
  },
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
-- The real queue has sent a message at least once before it reports "refused".
local function refuse(entry) entry.done = true; entry.__sentAt = clock / 100; entry.errorHandler(entry, "refused") end
-- MSP_STATUS replies: 22 bytes, byte 16 (extra flight-mode flag count) 0, flight-mode bit 0 = armed.
local function statusReply(armed)
  local b = {}
  for i = 1, 22 do b[i] = 0 end
  b[7] = armed and 1 or 0
  b[17] = 24
  return b
end
-- The restart's pre-flight: the clock flag read, then the flight controller's own disarmed answer.
local function preflight(statusArmed)
  ack(queue.entries[#queue.entries], { 1 })
  local e = queue.entries[#queue.entries]
  if e.command == CMD.status then e.__sentAt = clock / 100; ack(e, statusReply(statusArmed)) end
end
-- The queue's give-up after its retries with no answer at all: the message was sent.
local function silent(entry) entry.done = true; entry.__sentAt = clock / 100; entry.errorHandler(entry, "max_retries") end

local saved
local function begin(reboot)
  Pipeline.reset()
  queue.entries = {}
  mspState.lastArmed = false
  mspState.lastConnected = true
  mspState.values = { mcuId = "board-a" }
  armedNow, armedUnknown = false, false
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
preflight()
equal(last().command, CMD.reboot, "restart: MSP_REBOOT queued")
ack(last())
clock = clock + 100
Pipeline.wakeup()
equal(last().command, CMD.txinfo, "restart: probing for the board")
ack(last(), { 0 })                              -- the clock flag cleared: the board did restart
Pipeline.wakeup()                               -- onconnect ends -> verify probe
preflight()
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
preflight()
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
preflight()
local reboot15 = last()
equal(reboot15.command, CMD.reboot, "reboot stuck: reboot queued")
equal(reboot15.completeAfterAttempt, 1, "reboot stuck: the restart's reboot completes on silence after one send")
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
preflight(); ack(last())
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
preflight(); ack(last())
clock = clock + 2200
Pipeline.wakeup()
p, r = outcome()
equal(p and p.terminal, true, "tool closes: the restart's outcome stands in the notice")
equal(r and r.restart, true, "tool closes: it is the restart's")

-- 22. The arming reading goes away between the press and the pre-flight answer: no reboot.
begin()
ack(last()); refuse(last())
equal(Pipeline.restartAfterFailure(), true, "unknown arming: restart started")
armedUnknown = true
ack(last(), { 1 })
equal(countCommand(CMD.reboot), 0, "unknown arming: no reboot queued")
equal(select(2, outcome()).restart, true, "unknown arming: the restart reports")

-- 23. The backstop ends a write step before the queue gave up its sent message: it counts as reached.
begin()
last().__sentAt = 0                             -- the queue stamps a message when it is sent
clock = 3200
Pipeline.wakeup()
p, r = outcome()
equal(p and p.status, "timeout", "backstop on a sent write: timeout")
equal(r and r.sentAny, true, "backstop on a sent write: counts as reached")
equal(Pipeline.offersRestart(r), true, "backstop on a sent write: offer")
begin()
clock = 3200
Pipeline.wakeup()
equal(select(2, outcome()).sentAny, false, "backstop on a write never sent: not reached")

-- 24. The restart's reboot asks again at every send (sendIf); a normal save's reboot asks only
-- whether its run is still the active one.
begin(true)
ack(last()); ack(last()); ack(last())
ack(last(), { 1 })
equal(last().command, CMD.reboot, "normal reboot save: reboot queued")
equal(last().sendIf and last().sendIf(last()), true, "normal reboot save: sent while its run is active")
equal(last().completeAfterAttempt, 2, "normal reboot save: completes after two sends, as before")
begin()
ack(last()); refuse(last())
Pipeline.restartAfterFailure()
preflight()
local reboot24 = last()
equal(type(reboot24.sendIf), "function", "restart: the reboot carries sendIf")
equal(reboot24.sendIf(reboot24), true, "restart: sendIf true with a link, disarmed and known")
armedUnknown = true
equal(reboot24.sendIf(reboot24), false, "restart: sendIf false once the arming state is unknown")
armedUnknown, armedNow = false, true
equal(reboot24.sendIf(reboot24), false, "restart: sendIf false once armed")
armedNow = false
mspState.lastConnected = false
equal(reboot24.sendIf(reboot24), false, "restart: sendIf false without a link")
mspState.lastConnected = true
reboot24.done = true
reboot24.errorHandler(reboot24, "withheld")     -- the real queue's answer to a false sendIf
p, r = outcome()
equal(r and r.restart, true, "restart withheld: it reports as a restart")
equal(Pipeline.blocksNavigation(), false, "restart withheld: the page is free again")

-- 25. Fail closed: a pipeline copy that cannot load lib/armed.lua sends no restart.
modules["lib/armed.lua"] = false
local Fresh = assert(loadfile("src/rfsuite/tasks/msp/save_pipeline.lua"))()
begin()
ack(last()); refuse(last())
equal(Fresh.restartAfterFailure(), true, "no arming module: restart started")
ack(last(), { 1 })
equal(countCommand(CMD.reboot), 0, "no arming module: no reboot queued")
equal(select(2, outcome()).restart, true, "no arming module: the restart reports")

-- 26. The radio's arming sensor says disarmed (it can be stale); the flight controller says armed: no reboot.
begin()
ack(last()); refuse(last())
Pipeline.restartAfterFailure()
ack(last(), { 1 })
equal(last().command, CMD.status, "fc check: MSP_STATUS asked after the pre-flight")
ack(last(), statusReply(true))
equal(countCommand(CMD.reboot), 0, "fc armed: no reboot queued")
equal(select(2, outcome()).restart, true, "fc armed: the restart reports")

-- 27. MSP_STATUS unanswered, or in a layout that cannot prove disarmed: no reboot.
begin()
ack(last()); refuse(last())
Pipeline.restartAfterFailure()
ack(last(), { 1 })
refuse(last())
equal(countCommand(CMD.reboot), 0, "fc status unanswered: no reboot queued")
begin()
ack(last()); refuse(last())
Pipeline.restartAfterFailure()
ack(last(), { 1 })
ack(last(), { 0, 0, 0 })
equal(countCommand(CMD.reboot), 0, "fc status short: no reboot queued")

-- 28. The flight controller's disarmed answer is old by the time the reboot would go out: withheld.
begin()
ack(last()); refuse(last())
Pipeline.restartAfterFailure()
preflight()
local reboot28 = last()
equal(reboot28.command, CMD.reboot, "fc evidence: reboot queued on a fresh disarmed answer")
equal(reboot28.sendIf(reboot28), true, "fc evidence: fresh, the send is allowed")
clock = clock + 300
equal(reboot28.sendIf(reboot28), false, "fc evidence: 3 s old, the send is withheld")

-- 29. The disarmed answer is dated by the request's send, not by the reply's arrival: a reply read
-- 3 s after its request was sent (a pass stopped by the instruction limit, a slow link) is old.
begin()
ack(last()); refuse(last())
Pipeline.restartAfterFailure()
ack(last(), { 1 })                              -- the clock-flag pre-flight
local status29 = last()
equal(status29.command, CMD.status, "late status reply: MSP_STATUS asked")
equal(status29.maxRetries, 0, "late status reply: asked once, so the reply answers that one send")
status29.__sentAt = clock / 100
clock = clock + 300
ack(status29, statusReply(false))
local reboot29 = last()
local allowed29 = reboot29.command == CMD.reboot and reboot29.sendIf(reboot29) or false
equal(allowed29, false, "late status reply: the reboot is not sent on a 3 s old answer")
-- A status request the queue never sent proves nothing.
begin()
ack(last()); refuse(last())
Pipeline.restartAfterFailure()
ack(last(), { 1 })
ack(last(), statusReply(false))                 -- no __sentAt
equal(countCommand(CMD.reboot), 0, "status reply without a send: no reboot queued")

-- 30. The restart reaches only the board the failed save wrote to.
begin()
ack(last()); refuse(last())
equal(select(2, outcome()).mcuId, "board-a", "board: the outcome names the board written to")
mspState.values = { mcuId = "board-b" }
equal(Pipeline.restartPossible(), false, "board: another board on the link, restartPossible false")
ok, why = Pipeline.restartAfterFailure()
equal(ok, false, "board: another board, restart refused")
equal(why, "other_board", "board: refusal reason")
mspState.values = { mcuId = nil }
equal(Pipeline.restartPossible(), false, "board: no board identified yet, restartPossible false")
equal(select(2, Pipeline.restartAfterFailure()), "other_board", "board: not identified, refused")
mspState.values = { mcuId = "board-a" }
equal(Pipeline.restartPossible(), true, "board: the same board again, restartPossible (control)")
-- The board changes between the press and the reboot's send: withheld.
equal(Pipeline.restartAfterFailure(), true, "board: restart started on the same board")
preflight()
local reboot30 = last()
equal(reboot30.command, CMD.reboot, "board: reboot queued")
mspState.values = { mcuId = "board-b" }
equal(reboot30.sendIf(reboot30), false, "board: another board at the send, withheld")
-- A save started before any board identified itself offers no restart that could reach one.
Pipeline.reset()
queue.entries = {}
mspState.values = { mcuId = nil }
Pipeline.start({ pageId = "test_page", steps = {
  { label = "W1", command = CMD.write1, payload = { 1 } },
  { label = "W2", command = CMD.write2, payload = { 2 } } } })
ack(last()); refuse(last())
mspState.values = { mcuId = "board-a" }
equal(Pipeline.restartPossible(), false, "board: save without a known board, restartPossible false")
equal(select(2, Pipeline.restartAfterFailure()), "other_board", "board: save without a known board, refused")

-- 31. The backstop's drop of the ended run's messages is stopped by the instruction limit: it stays
-- owed, and the next wakeup (or the next run, before it queues anything) does it.
begin()
ack(last())
local write31 = last()                          -- the second write, never answered
local realClear = queue.clear
local clearCalls = 0
queue.clear = function(self, client)
  clearCalls = clearCalls + 1
  if clearCalls == 1 then error("CPU limit", 0) end
  return realClear(self, client)
end
clock = 3200
local ok31, err31 = pcall(Pipeline.wakeup)
equal(ok31, false, "owed drop: the instruction limit is raised on")
equal(type(err31) == "string" and string.find(err31, "CPU limit", 1, true) ~= nil, true,
  "owed drop: the limit error itself")
equal(select(2, outcome()).status, "timeout", "owed drop: the save ended on its backstop")
equal(write31.cleared, nil, "owed drop: the message is not dropped yet")
Pipeline.wakeup()
equal(clearCalls, 2, "owed drop: the next wakeup drops again")
equal(write31.cleared, true, "owed drop: the ended run's message is dropped")
Pipeline.wakeup()
equal(clearCalls, 2, "owed drop: once done, not again")
-- Owed when the next save starts: done before that save queues its first write.
begin()
ack(last())
clearCalls = 0
clock = 3200
pcall(Pipeline.wakeup)
local owed31 = last()
local started31 = Pipeline.start({ pageId = "other_page", steps = { { label = "W", command = CMD.write1, payload = { 1 } } } })
equal(started31, true, "owed drop: the next save starts")
equal(owed31.cleared, true, "owed drop: done before the next save queued anything")
queue.clear = realClear
-- The mark goes only with a clear that ran through: no queue reachable, or a clear that raised
-- something else, leaves it owed, and a save or restart that would share the client is refused.
begin()
ack(last())
local write31b = last()
clock = 3200
mspState.queue = nil
Pipeline.wakeup()                               -- the save ends; no queue to drop from
equal(select(2, outcome()).status, "timeout", "owed without a queue: the save ended")
local sharedState = _G.rfsuite.tasks.savePipeline
equal(sharedState.owedClear, "save:test_page", "owed without a queue: still owed")
mspState.queue = queue
queue.clear = function() error("broken", 0) end
Pipeline.wakeup()
equal(sharedState.owedClear, "save:test_page", "owed after a raising clear: still owed")
queue.clear = realClear
Pipeline.wakeup()
equal(sharedState.owedClear, nil, "owed: done once the clear runs through")
equal(write31b.cleared, true, "owed: the ended run's message is dropped")

-- 33. What keeps an ended run's message off the board is its sendIf, not the drop: every message
-- that acts on the board asks whether its run is still the active one, at every send.
begin()
local w33 = last()
equal(w33.sendIf and w33.sendIf(w33), true, "sendIf: the first write goes out while its run is active")
ack(w33)
local w33b = last()
clock = 3200
queue.clear = function() error("CPU limit", 0) end
pcall(Pipeline.wakeup)                          -- the save ends; its drop is stopped
queue.clear = realClear
equal(w33b.cleared, nil, "sendIf: the ended run's write is still queued")
equal(w33b.sendIf(w33b), false, "sendIf: and is withheld at the send")
begin()
ack(last()); ack(last())
local commit33 = last()
equal(commit33.command, CMD.eeprom, "sendIf: the commit is queued")
equal(commit33.sendIf(commit33), true, "sendIf: the commit goes out while its run is active")
clock = 3200
Pipeline.wakeup()
equal(commit33.sendIf(commit33), false, "sendIf: an ended run's EEPROM write is withheld")
begin(true)
ack(last()); ack(last()); ack(last())
ack(last(), { 1 })
local reboot33 = last()
clock = clock + 3200
Pipeline.wakeup()
equal(reboot33.sendIf(reboot33), false, "sendIf: an ended save's reboot is withheld")
reboot33.errorHandler(reboot33, "withheld")     -- the real queue's answer: changes nothing
equal(select(2, outcome()).status, "timeout", "sendIf: the withheld give-up leaves the outcome as it was")

-- 32. Late reboot and probe replies of an ended restart do not drive the save that runs next.
begin()
ack(last()); refuse(last())
Pipeline.restartAfterFailure()
preflight()
local reboot32 = last()
local probes32 = {}
for _, e in ipairs(queue.entries) do if e.command == CMD.txinfo then probes32[#probes32 + 1] = e end end
clock = clock + 3200
Pipeline.wakeup()                               -- the restart ends on its backstop
equal(select(2, outcome()).restart, true, "late restart replies: the restart ended")
Pipeline.start({ pageId = "next_page", steps = { { label = "W", command = CMD.write1, payload = { 1 } } } })
local phase32 = Pipeline.getProgress().phase
local entries32 = #queue.entries
reboot32.processReply(reboot32, {})
reboot32.errorHandler(reboot32, "max_retries")
for _, e in ipairs(probes32) do e.processReply(e, { 0 }); e.errorHandler(e, "max_retries") end
local p32 = Pipeline.getProgress()
equal(p32 and p32.phase, phase32, "late restart replies: the next save's phase unchanged")
equal(p32 and p32.terminal, nil, "late restart replies: the next save has not ended")
equal(#queue.entries, entries32, "late restart replies: nothing queued for the next save")

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
