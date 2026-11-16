-- A setup page's live override: the flight controller holds some inputs still while the pilot edits
-- a value, and every edit is sent to the board's RAM before Save writes it to EEPROM.
--
-- One instance per page visit, created when the page loads and dropped when it closes. It owns:
--   * the override itself -- one write per input, `on` to hold it, `off` to release it;
--   * the confirm dialog, which also says so when the armed state cannot be read;
--   * the live-write cadence -- "periodic" sends a changed value at most every `interval` seconds,
--     "settle" sends it once it has been left unchanged for `interval` seconds;
--   * the record the board holds as far as the page knows (the read, or the last save that reached
--     EEPROM), and the rollback to it when the page is left or reloaded without Save.
-- What a value is and how it reaches the board stays with the page: it passes the editable values
-- as a flat table and a `send` function that queues the write and returns true once it is queued.
--
-- While the model is armed, nothing here reaches the board: tasks/msp/runtime.lua clears the queue
-- on every pass and the tool does not wake a page. The firmware also ignores mixer overrides while
-- armed, but it would still apply a configuration write.

local M = {}

local function loadModule(path)
  local chunk = loadScript(_G.rfsuite.paths.core .. "/" .. path, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local function copyFlat(src)
  if type(src) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(src) do out[k] = v end
  return out
end

local function sameFlat(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if b[k] ~= v then return false end
  end
  for k, v in pairs(b) do
    if a[k] ~= v then return false end
  end
  return true
end

M.copyFlat = copyFlat
M.sameFlat = sameFlat

-- Seconds on EdgeTX's 10 ms clock, the only clock a radio script has.
function M.now()
  if type(getTime) == "function" then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then return value / 100 end
  end
  return 0
end

local Override = {}
Override.__index = Override

-- Reached through the global lib/log.lua publishes rather than loaded here, so a page that uses
-- the override pays for no second copy of the logger. Absent logger, absent lines.
local function log(level, fmt, ...)
  local Log = type(_G) == "table" and _G.rfsuite and _G.rfsuite.Log
  if type(Log) == "table" and type(Log.emitf) == "function" then
    pcall(Log.emitf, "rfsuite.override", level, fmt, ...)
  end
end

-- A save is still writing: a step or the EEPROM commit is ahead. The pipeline queues each step
-- from the previous reply, so a write queued now would land between them and EEPROM could keep
-- the old value while the save reports the new one. A save that needs no restart lets the page
-- be left meanwhile (SavePipeline.blocksNavigation()). Asked of the pipeline rather than kept in
-- a flag: a dismissed save's outcome is delivered late, and a flag cleared there could stay set.
-- The restart a failed save offers (PREFLIGHT .. VERIFY) is not counted: whatever a rollback
-- writes then is the stored record, which is what the board boots with anyway.
function M.saveWriting()
  local SavePipeline = loadModule("tasks/msp/save_pipeline.lua")
  if not SavePipeline or type(SavePipeline.getProgress) ~= "function" then return false end
  local progress = SavePipeline.getProgress()
  local phases = SavePipeline.PHASE or {}
  return type(progress) == "table"
    and (progress.phase == (phases.WRITE or "write") or progress.phase == (phases.COMMIT or "commit"))
end

--- opts: command (MSP id), inputs, on, off (values), cadence ("periodic" or "settle"), interval
--- (seconds). `inputs` is the list of indices the command takes one write each for, with the
--- payload { index, lo, hi } (MSP_SET_MIXER_OVERRIDE). Left out, the command sets every output in
--- one write with the payload { lo, hi } (MSP_SET_SERVO_OVERRIDE_ALL).
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    command = opts.command,
    inputs = opts.inputs,
    onValue = opts.on,
    offValue = opts.off,
    cadence = opts.cadence == "settle" and "settle" or "periodic",
    interval = tonumber(opts.interval) or 0.2,
    active = false,
    original = nil,   -- what the board holds as far as the page knows
    sent = nil,       -- the values the last queued live write carried
    sentAny = false,  -- a live write went out since `original` was taken
    seen = nil,       -- settle: the values last seen, and since when
    seenAt = 0,
    lastSentAt = nil, -- periodic: when the last live write went out
  }, Override)
end

local function queueValue(self, queue, value)
  if not queue or type(queue.add) ~= "function" then return false end
  local lo = value % 256
  local hi = math.floor(value / 256) % 256
  if type(self.inputs) ~= "table" then
    queue:add({
      command = self.command,
      payload = { lo, hi },
      isWrite = true,
      processReply = function() end
    })
    return true
  end
  for _, index in ipairs(self.inputs) do
    queue:add({
      command = self.command,
      payload = { index, lo, hi },
      isWrite = true,
      processReply = function() end
    })
  end
  return true
end

function Override:enable(queue)
  if queueValue(self, queue, self.onValue) then
    self.active = true
    log("info", "on: command %s, value %s", tostring(self.command), tostring(self.onValue))
  else
    log("warn", "on: no MSP queue, override not sent")
  end
  return self.active
end

function Override:disable(queue)
  if queueValue(self, queue, self.offValue) then
    log("info", "off: command %s, value %s", tostring(self.command), tostring(self.offValue))
  else
    log("warn", "off: no MSP queue, release not sent")
  end
  self.active = false
end

--- Ask before switching. spec: title, message, uncertainText, onConfirm. The text about an
--- unreadable armed state is added only when switching on.
function Override:confirm(spec)
  local Dialog = loadModule("ui/confirm_dialog.lua")
  if not Dialog or type(Dialog.show) ~= "function" then return false end
  local message = spec.message or ""
  if not self.active and spec.uncertainText then
    local Armed = loadModule("lib/armed.lua")
    if Armed and type(Armed.isUncertain) == "function" and Armed.isUncertain() == true then
      message = spec.uncertainText .. "\n\n" .. message
    end
  end
  Dialog.show({ title = spec.title, message = message, onConfirm = spec.onConfirm })
  return true
end

--- The board holds `record` (a read that parsed); nothing live has been sent against it.
function Override:snapshot(record, values)
  self.original = { record = copyFlat(record), values = copyFlat(values) }
  self.sent = copyFlat(values)
  self.sentAny = false
  self.seen = copyFlat(values)
  self.seenAt = M.now()
  log("debug", "snapshot: the board's record taken")
end

--- A save reached EEPROM: from now on this is what leaving without Save puts back.
function Override:stored(record, values)
  self.original = { record = copyFlat(record), values = copyFlat(values) }
  self.sentAny = false
  log("debug", "stored: a save reached EEPROM, its record is what a rollback puts back")
end

--- A save queued `values`: they need no live write until they change, and until the save is
--- stored (`stored`) they count as sent -- its configuration write reaches the board's RAM even when
--- a later step or the EEPROM commit fails, and leaving then has to put the record back.
function Override:markSent(values)
  self.sent = copyFlat(values)
  self.sentAny = true
  log("debug", "save queued: its values count as sent until stored")
end

--- A live write the board did not answer is sent again on the next due pass; one it refused is not
--- repeated until the value changes.
function Override:writeFailed(reason)
  if reason ~= "refused" then self.sent = nil end
  log("warn", "live write failed (%s); %s", tostring(reason),
    reason == "refused" and "not repeated until the value changes" or "sent again on the next due pass")
end

--- A save that did not reach EEPROM: which of its writes the board took is not known, so what went
--- out last is forgotten. Leaving then always puts the board's record back, and the live loop sends
--- the values on screen again when they are due.
function Override:saveFailed()
  self.sent = nil
  self.sentAny = true
  log("info", "save not stored: the last values sent are unknown, a rollback will put the record back")
end

--- Called from the page's wakeup while the override is on. `send(values)` queues the write and
--- returns true once it is queued; false (queue busy, read not complete) keeps the values due.
function Override:tick(values, send)
  if not self.active or type(values) ~= "table" then return false end
  local now = M.now()
  if self.cadence == "settle" then
    if not sameFlat(self.seen, values) then
      self.seen = copyFlat(values)
      self.seenAt = now
      return false
    end
    if now - self.seenAt < self.interval then return false end
  else
    if self.lastSentAt and now - self.lastSentAt < self.interval then return false end
  end
  if self.sent and sameFlat(self.sent, values) then return false end
  if send(values) ~= true then return false end
  self.sent = copyFlat(values)
  self.sentAny = true
  self.lastSentAt = now
  log("trace", "live write queued (%s)", self.cadence)
  return true
end

--- Leaving or reloading without Save: when a live write went out since the board's record was
--- taken, `send(record)` puts that record back. Returns the original { record, values } it sent,
--- or nil when nothing had to go back.
function Override:rollback(send)
  local orig = self.original
  local wasSent = self.sentAny
  local lastSent = self.sent
  self.sentAny = false
  self.sent = orig and copyFlat(orig.values) or nil
  if not wasSent or type(orig) ~= "table" or type(orig.record) ~= "table" then
    log("trace", "rollback: nothing was sent live, nothing to put back")
    return nil
  end
  -- What went out last is what the board already holds: nothing to put back.
  if lastSent and sameFlat(lastSent, orig.values) then
    log("trace", "rollback: the last write already carried the board's record")
    return nil
  end
  if send(orig.record) ~= true then
    log("warn", "rollback: the board's record could not be queued")
    return nil
  end
  log("info", "rollback: the board's record queued")
  return orig
end

return M
