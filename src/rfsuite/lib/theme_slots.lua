-- lib/theme_slots.lua
-- The radio's theme colours, rewritten from the suite's colour scheme while the tool is open, and
-- put back when it closes. Docs: docs/developer/color-schemes.md.
--
-- EdgeTX's own controls (toggle, choice, number edit) and the page header take every colour from the
-- radio's theme slots and have no colour property of their own, so the only way to draw them in the
-- suite's scheme is to write those slots with lcd.setColor. That changes the whole radio's interface,
-- not just the tool's, and EdgeTX puts nothing back when a script ends: the table lives in RAM and is
-- reloaded only by a theme change, a restart or an SD remount. So every way the tool can end has to put
-- the radio's colours back, and there are four:
--
--   * restore(), called on every exit the suite runs itself (the closing sequence, the hosted tool's
--     finish, fullscreen left).
--   * A finaliser. On a colour radio a long RTN closes the tool at once without running any Lua, and an
--     error ends the script, but both close its Lua state, and lua_close runs every pending __gc
--     metamethod before it frees anything (Lua 5.3, lgc.c luaC_freeallobjects). The guard below holds
--     the radio's colours and lcd.setColor as upvalues, since by then the suite's globals may be gone.
--   * A marker file holding the radio's colours and the ones written. Should neither of the above run
--     (memory exhausted, an error inside the finaliser), the next start of the tool or the dashboard
--     widget finds it and puts the radio's colours back -- only while the slots still hold what the
--     suite wrote, since a theme the pilot applied in between is the radio's own and is left alone.
--   * A restart of the radio, which reloads the theme from the card.

local M = {}

-- Theme slot -> scheme role, by the global's name: the one place the mapping is kept. A slot not
-- listed keeps the radio's colour. What EdgeTX paints with each (libui/etx_lv_theme.cpp at 2.12.5):
--   PRIMARY1    text on a checked control                PRIMARY2   control background, header title
--   SECONDARY1  control text, toggle knob, page header    SECONDARY2 control border
--   FOCUS       focused control                          ACTIVE     a checked control, an ON toggle track
--   WARNING     warning text                             DISABLED   disabled text
M.SLOTS = {
  { "COLOR_THEME_PRIMARY1",   "text" },
  { "COLOR_THEME_PRIMARY2",   "card" },
  { "COLOR_THEME_SECONDARY1", "accentInk" },
  { "COLOR_THEME_SECONDARY2", "rule" },
  { "COLOR_THEME_FOCUS",      "accent" },
  { "COLOR_THEME_ACTIVE",     "accent" },
  { "COLOR_THEME_WARNING",    "warning" },
  { "COLOR_THEME_DISABLED",   "disabled" },
}

local MARKER_NAME = "theme_slots.txt"

-- What this Lua state wrote: { flag, original, written } per slot, or nil while the radio's own
-- colours stand. One per state: the tool and the dashboard widget are separate states, and the
-- hosted tool shares the widget's.
local applied = nil
local appliedScheme = nil
-- The finaliser's table, anchored here so that only the end of the Lua state collects it; `armed`
-- is what it reads, so a restore() already done leaves it nothing to do.
local guard = nil -- luacheck: ignore (held, never read: it only has to stay reachable)
local guardState = nil

local function log(level, fmt, ...)
  local root = _G.rfsuite
  local Log = root and root.require and root.require("lib/log.lua") or nil
  if Log and type(Log.emitf) == "function" then
    pcall(Log.emitf, "rfsuite.theme", level, fmt, ...)
  end
end

local function markerPath()
  local root = _G.rfsuite
  local user = root and root.paths and root.paths.user
  if type(user) ~= "string" then return nil end
  return user .. "/" .. MARKER_NAME
end

local function canWrite()
  return lcd ~= nil and type(lcd.setColor) == "function" and type(lcd.getColor) == "function"
end

-- { flag, original, written } per line, as writeMarker wrote them; nil when there is none.
local function readMarker(path)
  if not path or (type(fstat) == "function" and fstat(path) == nil) then return nil end
  local f = io.open(path, "r")
  if not f then return nil end
  local text = io.read(f, 512) or ""
  io.close(f)
  local rows = {}
  -- EdgeTX's Lua integers are 32 bits and a colour sits in the upper half of its flag, so a light colour
  -- is a negative number (white is -32768): the sign is part of every value.
  for flag, original, written in string.gmatch(text, "(%-?%d+) (%-?%d+) (%-?%d+)") do
    rows[#rows + 1] = { tonumber(flag), tonumber(original), tonumber(written) }
  end
  if #rows == 0 then return nil end
  return rows
end

local function writeMarker(path, rows)
  if not path then return false end
  local f = io.open(path, "w")
  if not f then return false end
  for i = 1, #rows do
    local row = rows[i]
    io.write(f, string.format("%d %d %d\n", row[1], row[2], row[3]))
  end
  io.close(f)
  return true
end

local function dropMarker(path)
  if path and type(del) == "function" and (type(fstat) ~= "function" or fstat(path) ~= nil) then
    del(path)
  end
end

-- True when every slot still holds either what the marker says was written or the radio's own colour
-- (a restore that stopped half way): nothing else has touched them since. A theme the pilot applied in
-- between puts other colours there.
local function stillOurs(rows)
  for i = 1, #rows do
    local now = lcd.getColor(rows[i][1])
    if now ~= rows[i][3] and now ~= rows[i][2] then return false end
  end
  return true
end

local function putBack(rows)
  for i = 1, #rows do
    lcd.setColor(rows[i][1], rows[i][2])
  end
end

--- A marker left by a tool that ended without putting the radio's colours back: put them back if the
--- slots still hold what it wrote (or the radio's own colour), and drop it either way. Not while this state has its own colours
--- written (the marker is then its own). Returns true when colours were put back.
function M.recover()
  if applied ~= nil or not canWrite() then return false end
  local path = markerPath()
  local rows = readMarker(path)
  if rows == nil then return false end
  local ours = stillOurs(rows)
  if ours then putBack(rows) end
  dropMarker(path)
  log("info", "marker found: %s", ours and "radio colours put back" or "slots changed since, left alone")
  return ours
end

local function arm(rows, path)
  local setColor = lcd.setColor
  local remove = del
  local state = { armed = true }
  -- The finaliser must be in the metatable before setmetatable is called, or Lua never runs it.
  guard = setmetatable({}, {
    __gc = function()
      if not state.armed then return end
      state.armed = false
      local all = true
      for i = 1, #rows do
        if not pcall(setColor, rows[i][1], rows[i][2]) then all = false end
      end
      -- The marker goes only with every colour back: otherwise it is what the next start restores from.
      if all and path and type(remove) == "function" then pcall(remove, path) end
    end
  })
  guardState = state
end

local function disarm()
  if guardState then guardState.armed = false end
  guard = nil
  guardState = nil
end

--- Write the slots from scheme `name` (lib/color_schemes.lua; anything else is the default). The
--- radio's colours are read before the first write, or taken from a marker an earlier run left
--- while the slots still hold what it wrote. Calling it again with another scheme rewrites the slots
--- and keeps the radio's colours. Returns true when the slots carry the scheme.
function M.apply(name)
  if not canWrite() then return false end
  local root = _G.rfsuite
  local Schemes = root.require("lib/color_schemes.lua")
  local scheme = Schemes.name(name)
  local colors = Schemes.colors(scheme)
  local path = markerPath()

  local rows = applied
  if rows == nil then
    -- An earlier run's radio colours, if it never put them back and nothing has changed them since.
    local left = readMarker(path)
    local originals = {}
    if left and stillOurs(left) then
      for i = 1, #left do originals[left[i][1]] = left[i][2] end
      log("info", "marker found: the radio colours it holds are the ones to put back")
    end
    rows = {}
    for i = 1, #M.SLOTS do
      local flag = _G[M.SLOTS[i][1]]
      if flag ~= nil then
        local original = originals[flag] or lcd.getColor(flag)
        rows[#rows + 1] = { flag, original, 0 }
      end
    end
  end

  local byFlag = {}
  for i = 1, #M.SLOTS do
    local flag = _G[M.SLOTS[i][1]]
    if flag ~= nil then byFlag[flag] = colors[M.SLOTS[i][2]] end
  end
  for i = 1, #rows do
    rows[i][3] = lcd.getColor(byFlag[rows[i][1]])
  end

  -- The net first, then the colours: whatever stops the tool after the first write finds both.
  writeMarker(path, rows)
  if applied == nil then arm(rows, path) end
  applied = rows
  appliedScheme = scheme
  for i = 1, #rows do
    lcd.setColor(rows[i][1], rows[i][3])
  end
  log("info", "theme slots written: scheme %s, %d slots", scheme, #rows)
  return true
end

--- Put the radio's colours back, drop the marker and disarm the finaliser. Safe to call when nothing
--- was written. The colours go back first: a call stopped half way (the instruction limit, hosted)
--- leaves this state, the finaliser and the marker as they were, so a later restore or the end of
--- the Lua state finishes the job.
function M.restore(why)
  local rows = applied
  if rows == nil then return false end
  if canWrite() then putBack(rows) end
  applied = nil
  appliedScheme = nil
  disarm()
  dropMarker(markerPath())
  log("info", "theme slots restored (%s)", tostring(why or "-"))
  return true
end

--- The scheme the slots carry in this Lua state, or nil while the radio's own colours stand.
function M.current()
  return appliedScheme
end

return M
