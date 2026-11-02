-- Tune Advisor capture, the disarm's part: marks the flight that has just ended as owed.
--
-- Last in tasks/events/ondisarm/manifest.lua and widget only. It does nothing but mark, and it
-- reports itself complete in the call that marks, so it never holds the disarm chain. The
-- capture itself -- the paced reads, the save, the clear -- is tasks/events/tune_capture.lua,
-- which tasks/events/runtime.lua loads and drives once the capture is due; that file says why
-- it is not a task that waits here. Kept this small because the runner loads it on one of the
-- passes right after the disarm.
--
-- owe() is also called by tasks/events/runtime.lua for a flight that ended during a link loss.

local M = {}

-- The first read waits this long after the disarm: the pilot is reading the landing numbers,
-- and the flight statistics are read first
local START_SECONDS = 5

local done = false

--- This flight is owed: the capture's state (rfsuite.session.tuneCapture) starts a new capture
--- due START_SECONDS from `now`. What it keeps from the last one: the clear still owed, the
--- flight time last saved per flight controller, the error-reply latch.
function M.owe(s, now)
  if type(s) ~= "table" then return end
  local tc = s.tuneCapture
  if type(tc) ~= "table" then
    tc = { lastSeconds = {}, saved = 0 }
    s.tuneCapture = tc
  end
  -- A saved flight whose settings were still owed is complete as it is: tell the reader now
  if tc.contextPending and type(tc.context) == "table" then
    tc.saved = (tc.saved or 0) + 1
    tc.savedMcu = tc.context.mcuId
  end
  tc.pending = true
  tc.failures = 0
  tc.replies = {}
  tc.saveDue = false
  tc.job = nil
  tc.contextPending = false
  tc.context = nil
  tc.nextAt = now + START_SECONDS
  tc.state = "reading"
end

function M.wakeup()
  if done then return end
  done = true
  local root = _G.rfsuite
  local now = type(getTime) == "function" and getTime() / 100 or 0
  M.owe(type(root) == "table" and root.session or nil, now)
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
end

return M
