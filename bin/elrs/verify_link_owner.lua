-- A page that owns the ELRS link sync can stop it: leaving retires the replies still under way and
-- clears its messages, so a late answer commits nothing. Without an owner nothing is cleared and a
-- reply goes on to the commit, as before.
-- Only module loading and the MSP queue are stubbed; nothing about timing is claimed.
--   lua5.3 bin/elrs/verify_link_owner.lua
local NAME = "ELRS link owner"
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local queued, cleared = {}, {}
local queue = {}
function queue:add(item) queued[#queued + 1] = item end
function queue:clear(client) cleared[#cleared + 1] = client end
_G.rfsuite = { session = {}, Log = { emit = function() end } }
_G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")
_G.getTime = function() return 0 end
_G.loadScript = function(path)
  return function()
    if string.match(path, "tasks/msp/runtime.lua$") then
      return { getState = function() return { queue = queue } end }
    elseif string.match(path, "tasks/msp/api/telemetry_config.lua$") then
      return { writeCommand = 0x1234 }
    elseif string.match(path, "tasks/msp/api/eeprom_write.lua$") then
      return { writeCommand = 250 }
    elseif string.match(path, "lib/armed.lua$") then
      return { isArmed = function() return false end, changeCount = function() return 0 end }
    end
  end
end
local task = assert(loadfile("src/rfsuite/app/pages/tools/diagnostics/elrs_link/elrslink_task.lua"))()
local function upvalue(fn, name)
  for i = 1, 100 do
    local key, value = debug.getupvalue(fn, i)
    if not key then break end
    if key == name then return value end
  end
  error("missing production upvalue: " .. name)
end
local sync = upvalue(upvalue(task.wakeup, "finalize"), "syncElrsToRotorflight")
-- The commit is held to the pilot's Yes having been given on this arming count.
local refusal = upvalue(sync, "writeRefusal")
local function pilotSaidYes()
  for i = 1, 100 do
    local key = debug.getupvalue(refusal, i)
    if not key then break end
    if key == "yesArmCount" then debug.setupvalue(refusal, i, 0) end
  end
  local usable = upvalue(refusal, "armedUsable")
  for i = 1, 100 do
    local key = debug.getupvalue(usable, i)
    if not key then break end
    if key == "armedShared" then debug.setupvalue(usable, i, true) end
  end
end

local function start()
  queued, cleared = {}, {}
  _G.rfsuite.session.telemetryConfigBuffer = { 1, 2, 3, 4, 5, 6, 7, 0, 0, 0, 0, 0 }
  sync({ linkRate = 333, linkRatio = 8, mode = 0 }, 500, "1:4", "std", 4)
end

task.setOwner("wizard", function() return true end)
start()
equal(#queued, 1, "owned: the FC write is queued")
equal(queued[1].client, "wizard", "owned: the write carries the owner's client")
equal(queued[1].payload[9], 244, "owned: the rate's low byte is on the wire")
equal(queued[1].payload[11], 4, "owned: the ratio is on the wire")
local write = queued[1]
task.reset()
equal(cleared[1], "wizard", "leaving clears the owner's messages")
write.processReply()
equal(#queued, 1, "a late reply after leaving commits nothing")

-- The owner's rule is asked again when the reply lands.
local allowed = true
task.setOwner("wizard", function() return allowed end)
start()
write = queued[1]
allowed = false
write.processReply()
equal(#queued, 1, "an owner that no longer allows it stops the commit")

-- No owner: the same sync runs to its end.
allowed = true
task.setOwner(nil, nil)
start()
equal(queued[1].client, nil, "no owner: the write has no client")
write = queued[1]
pilotSaidYes()
write.processReply()
equal(#queued, 2, "no owner: the EEPROM commit follows the reply")
equal(queued[2] and queued[2].command, 250, "no owner: the second message is the commit")
task.reset()
equal(#cleared, 0, "no owner: reset clears nothing")

print(string.format("%s: %d checks, %d failures", NAME, checks, failures))
if failures > 0 then os.exit(1) end
