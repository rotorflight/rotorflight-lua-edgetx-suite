-- The ESC's own current limit, kept for the model so that the dashboard can show the current
-- as a share of it.
--
-- The value is not asked for anywhere it can be read. Three of the ten ESC families report a
-- limit in their parameter block, and a manufacturer page that has just read one hands it here;
-- the remaining seven have no such field and are the reason the same key can also be set by
-- hand, under Setup > Power > Preferences. The store is the per-model one, so the figure follows
-- the flight controller rather than the transmitter model.
--
-- Amps, always. The three families spell the limit in three different units -- AM32 in amps,
-- Scorpion and YGE in hundredths of an amp -- so each caller converts on the way in and only
-- one unit is ever written.
--
-- Nothing is read from the flight controller for this and nothing is added to the connect
-- chain: the value is a by-product of a page the pilot opened anyway.
local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local PowerModelPreferences = nil
local Log = nil

local function ensureDeps()
  if not PowerModelPreferences then
    PowerModelPreferences = loadModule("app/pages/setup/power/model_preferences.lua")
  end
  if not Log then Log = loadModule("lib/log.lua") end
end

local function logD(msg)
  if Log and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.esc.currentlimit", tostring(msg), "debug")
  end
end

--- The key one physical fact is stored under, named here so that no reader has to spell it.
M.KEY = "esc_current_limit"

--- Where the figure under M.KEY came from, kept beside it: the family whose page reported it
--- (one of M.ORIGINS' keys), or M.ORIGIN_HAND for a figure typed in under Setup > Power >
--- Preferences. A file written before the origin was kept has no such key, and that reads as
--- unknown -- never as by hand, because the figure in it may just as well have come from a
--- controller. The same store's `battery` section keeps whatever keys it is handed, so the key
--- needs no declaration there.
M.ORIGIN_KEY = "esc_current_limit_origin"
M.ORIGIN_HAND = "hand"
M.ORIGINS = { am32 = true, scorpion = true, yge = true }

--- Whole amps, or nil where the argument is not a limit at all. A limit of zero is how every
--- one of the three families spells "no limit set", so it is not a figure to remember: it would
--- read back as a limit of nought and turn every reading into an overload.
function M.normalize(amps)
  local limit = tonumber(amps)
  if limit == nil then return nil end
  limit = math.floor(limit + 0.5)
  if limit <= 0 then return nil end
  return limit
end

--- Stores the limit for the flight controller that is connected, with the family that reported
--- it, and writes the file only where either is new. A page reads its block on every visit, so
--- writing unconditionally would be a card write per page open for a value that changes when the
--- ESC is reconfigured and never otherwise. The origin counts as new too: a figure typed in by
--- hand that a controller then reports unchanged is the controller's from then on.
---
--- The per-model store is not created here. A save writes the whole table, so saving one that
--- the connect chain has not filled yet would put a nearly empty file on the card in place of
--- the model's settings. Where there is nothing to write into, the limit is simply not kept.
function M.remember(session, amps, origin)
  local limit = M.normalize(amps)
  if limit == nil then return false, "no_limit" end
  if type(session) ~= "table" then return false, "no_session" end
  if type(session.modelPreferences) ~= "table" then return false, "no_model_preferences" end
  if not M.ORIGINS[origin] then origin = nil end

  local battery = session.modelPreferences.battery
  if type(battery) ~= "table" then
    battery = {}
    session.modelPreferences.battery = battery
  end

  if tonumber(battery[M.KEY]) == limit and battery[M.ORIGIN_KEY] == origin then return true, "unchanged" end

  ensureDeps()
  if not PowerModelPreferences or type(PowerModelPreferences.save) ~= "function" then
    return false, "model_preferences_unavailable"
  end

  -- The save writes the whole table, so the limit has to be in it while the file is written. It
  -- stays there only if the write succeeded: kept after a failed one, the next visit would find it
  -- "unchanged" and never write it, and a dashboard in its own Lua state, which reads the file,
  -- would not see it.
  local previous = battery[M.KEY]
  local previousOrigin = battery[M.ORIGIN_KEY]
  battery[M.KEY] = limit
  battery[M.ORIGIN_KEY] = origin
  local ok, err = PowerModelPreferences.save(session)
  if not ok then
    battery[M.KEY] = previous
    battery[M.ORIGIN_KEY] = previousOrigin
  end
  logD("remember " .. tostring(limit) .. " A from " .. tostring(origin) .. ": "
    .. (ok and "saved" or ("failed: " .. tostring(err or "io"))))
  return ok, err
end

return M
