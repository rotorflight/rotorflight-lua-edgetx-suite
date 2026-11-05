-- What the rotary style shows: the descriptions menu_roll.lua draws, one for each menu that uses it.
-- Loaded with it, so a pilot on the card style carries neither.
--
-- A description is a table; menu_roll.lua knows nothing else about the menu it draws:
--
--   id        the view it is drawn in
--   title     the header's text
--   rows()    the first list, made afresh: { id or none, title or label, detail, current, ... }
--   preview(row)  the list that row leads to, shown beside it before the focus goes there; or nil
--   enter(row)    the list a press on that row moves the focus into, and the question it answers if
--                 it is one, as { message, detail }; or nil where a press acts at once
--   act(path, roll)  a press that acts. `path` holds the rows from the first list down to the one
--                 pressed. Answering "back" returns the focus to the first list
--   details(row)  lines beside the row that take no focus, where it leads to no list; or nil
--   off(row)      true where the row is shown and cannot be pressed
--   opens(row)    true where the row is marked as leading somewhere
--   sub(row)      the line under a row's name; else its `detail`
--   marks         the current row is marked in the first list too, not only in the second
--   status()      the header's line about the work a press started; or nil
--   close()       the close box
--   back()        RTN with the focus in the first list

local M = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require) or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or (_G.rfsuite.paths.core .. "/" .. path)
  local chunk = loadScript(fullPath, "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Menu = requireModule("widgets/dashboard/fullscreen_menu.lua")
local Views = requireModule("widgets/dashboard/views.lua")
local Log = requireModule("lib/log.lua")

local TAG = "rfsuite.widget.roll"

local function trace(msg)
  if Log and type(Log.wanted) == "function" and Log.wanted("trace") then
    Log.emit(TAG, msg, "trace")
  end
end

-- How the work of entry `id` is going, in the words for the header; nil while there is nothing to say.
local function statusWord(widget, t, id)
  local status = Views.status(widget, id)
  if status == "busy" then return t("widgets.dashboard.battery_profile_busy", "SENDING...") end
  if status == "failed" then return t("widgets.dashboard.battery_profile_failed", "NOT SAVED") end
  return nil
end

-- The options a row leads to, or nil where it runs at once.
local function optionsOf(widget, entry)
  if entry == nil or entry.view == nil or type(entry.options) ~= "function" then return nil end
  local options = entry.options(widget)
  if type(options) ~= "table" or #options == 0 then return nil end
  return options
end

-- The question's two answers, in the order the wheel meets them, the safe one first: the focus
-- starts on it, so a double press on the row cannot answer for the pilot.
local function answers(confirm)
  return {
    { id = "cancel", label = confirm.cancelLabel or "CANCEL", cancel = true },
    { id = "agree", label = confirm.confirmLabel or "OK", agree = true },
  }
end

-- BATTERY PROFILE stays up until the write has been answered: a failed write must not pass unseen.
local function writeProfile(widget, entry, choice, roll)
  local base = Views.reporter(widget, entry.id)
  local session = Views.session(widget)
  local function report(value)
    base(value)
    trace("profile write " .. tostring(value))
    -- A chain with a failed message stays failed whatever the last answer says, and a reply to a
    -- write from before the menu was closed says nothing about this menu.
    if value == "ok" and widget._viewStack == session and session.roll == roll
      and Views.status(widget, entry.id) == "ok" then
      Views.navigate(widget, "done")
    end
  end
  Menu.run(widget, entry, choice, "none", report)
end

--- The quick menu: the entries offered now, BATTERY PROFILE last where it is.
function M.quick(widget, entries, t)
  return {
    id = Views.DEFAULT_VIEW,
    title = t("widgets.dashboard.quick_settings", "QUICK SETTINGS"),
    rows = function()
      local out = {}
      for i = 1, #entries do
        local entry = entries[i]
        if entry.id ~= "battery_profile" and Menu.visible(widget, entry) then out[#out + 1] = entry end
      end
      local profile = Menu.entry(widget, "battery_profile")
      if profile ~= nil and Menu.visible(widget, profile) then out[#out + 1] = profile end
      return out
    end,
    preview = function(entry) return optionsOf(widget, entry) end,
    enter = function(entry)
      if type(entry.confirm) == "table" then return answers(entry.confirm), entry.confirm end
      return optionsOf(widget, entry), nil
    end,
    act = function(path, roll)
      local entry, choice = path[1], path[2]
      if choice == nil then
        trace("run " .. tostring(entry.id))
        Menu.run(widget, entry)
        return nil
      end
      if choice.cancel then return "back" end
      if choice.agree then
        trace("question answered " .. tostring(entry.id))
        Menu.perform(widget, entry, nil, entry.after)
        return nil
      end
      if entry.id == "battery_profile" then
        writeProfile(widget, entry, choice, roll)
        return nil
      end
      Menu.run(widget, entry, choice)
      return nil
    end,
    off = function(row) return row.selectable == false end,
    opens = function(entry) return entry.view ~= nil end,
    sub = function(row)
      if row.detail ~= nil then return row.detail end
      if type(row.info) ~= "function" then return nil end
      local percent = Menu.fillPercent(row)
      if percent == nil then return nil end
      return string.format(t("widgets.dashboard.erase_blackbox_confirm_used", "%d%% used"), percent)
    end,
    status = function()
      return statusWord(widget, t, "battery_profile") or statusWord(widget, t, "battery_pick")
    end,
    close = function() Views.navigate(widget, "done") end,
    back = function()
      if Views.top(widget) == nil then
        Views.navigate(widget, "done")
      else
        Views.navigate(widget, "closeView")
      end
    end,
  }
end

--- The battery picker on its own: the packs and NO BATTERY roll on the left, what is known about the
--- pack on the right.
function M.pick(widget, t)
  local entry = Menu.entry(widget, "battery_pick")
  local function close()
    if entry ~= nil then Menu.run(widget, entry, entry.close) end
  end
  return {
    id = "battery_pick",
    title = t("widgets.dashboard.battery_pick_title", "WHICH BATTERY?"),
    marks = true,
    rows = function() return entry and entry.options() or {} end,
    details = function(row) return row.facts end,
    off = function(row) return row.selectable == false end,
    sub = function() return nil end,
    act = function(path)
      trace("pick " .. tostring(path[1].id))
      if entry ~= nil then Menu.run(widget, entry, path[1]) end
      return nil
    end,
    status = function() return statusWord(widget, t, "battery_pick") end,
    close = close,
    back = close,
  }
end

return M
