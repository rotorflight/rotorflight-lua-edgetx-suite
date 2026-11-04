-- Which entries the dashboard's quick menu shows, and in which order: the one list both of its
-- readers take it from. The widget draws the menu from it (widgets/dashboard/fullscreen_menu.lua)
-- and Settings > Dashboard > Quick Settings offers it to the pilot
-- (app/pages/settings/dashboard/quick_menu/page.lua). The two run in separate Lua states, so this
-- file loads nothing and holds no state but a one-value memo.
--
-- The pilot's choice is one string in the radio's preferences, `dashboard.quick_menu`: the ids in
-- the pilot's order, separated by commas. The settings store writes booleans, numbers and strings only,
-- so a list has to travel as text.
--
--   absent, or not a string   the default list below, in its order
--   ""                        nothing: the pilot has taken every entry out
--   "tool,erase_blackbox"     those entries, in that order
--
-- A string is read leniently: an id this build does not offer is dropped, and an id that occurs
-- twice counts at its first position only. A string that names something but nothing this build
-- offers -- a hand edit, or a card written by a build with entries this one lacks -- is not a
-- choice this build can honour, and reads as the default rather than as an empty menu.
--
-- BATTERY PROFILE is not one of the entries: the menu draws it as a row of its own under the
-- pilot's entries, whatever they are (fullscreen_menu.lua). A list saved when it was one still
-- reads -- the id is dropped like any other this build does not offer.

local M = {}

-- The preference key, in the `dashboard` section of lib/preferences.lua.
M.KEY = "quick_menu"

-- Every entry the pilot may put in the menu, in the order the settings page lists them. Each one
-- is an entry fullscreen_menu.lua builds under the same id.
M.OFFERED = { "erase_blackbox", "inflight_tuning", "battery_pick", "tool", "flight_log" }

-- What the menu shows until the pilot chooses: what it has always shown, in that order.
M.DEFAULT = { "erase_blackbox", "inflight_tuning", "battery_pick", "tool" }

-- The title of each offered entry, for the settings page: the keys the menu draws its rows with,
-- so the page names an entry exactly as the menu does.
M.TITLES = {
  erase_blackbox = "@i18n(widgets.dashboard.erase_blackbox)@",
  inflight_tuning = "@i18n(widgets.dashboard.inflight_open)@",
  battery_pick = "@i18n(widgets.dashboard.battery_pick_open)@",
  tool = "@i18n(widgets.dashboard.tool_open)@",
  flight_log = "@i18n(widgets.dashboard.flight_log_open)@",
}

local OFFERED_SET = {}
for i = 1, #M.OFFERED do OFFERED_SET[M.OFFERED[i]] = true end

--- Whether `id` is an entry the pilot may put in the menu.
function M.isOffered(id)
  return OFFERED_SET[id] == true
end

-- The last value read and the list it gave. The widget asks on every build of the menu, and the
-- value changes only when the pilot saves the page.
local lastValue, lastIds = nil, nil

--- The ids a stored value stands for, in order (see the head of this file). The list answered is
--- shared between calls and must not be changed by the caller.
function M.ids(value)
  if type(value) ~= "string" then return M.DEFAULT end
  if value == lastValue and lastIds ~= nil then return lastIds end
  local ids, seen, named = {}, {}, false
  for token in string.gmatch(value, "[^,%s]+") do
    named = true
    if OFFERED_SET[token] and not seen[token] then
      seen[token] = true
      ids[#ids + 1] = token
    end
  end
  if named and #ids == 0 then ids = M.DEFAULT end
  lastValue, lastIds = value, ids
  return ids
end

--- The value to store for `ids`, a list in the pilot's order: nil where it is the default list,
--- so a radio whose pilot has not changed the menu carries no key and follows the default.
function M.encode(ids)
  local out, seen = {}, {}
  for i = 1, #ids do
    local id = ids[i]
    if OFFERED_SET[id] and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  if #out == #M.DEFAULT then
    local same = true
    for i = 1, #out do
      if out[i] ~= M.DEFAULT[i] then
        same = false
        break
      end
    end
    if same then return nil end
  end
  return table.concat(out, ",")
end

return M
