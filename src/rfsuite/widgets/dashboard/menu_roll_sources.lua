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
--                 it is one, as { message, detail }; or nil where a press acts at once. Asked for the
--                 rows of any level: a row of the right list that leads to a list shifts the columns
--   act(path, roll)  a press that acts. `path` holds the rows from the first list down to the one
--                 pressed. Answering "back" returns the focus to the first list
--   details(row)  lines beside the row that take no focus, where it leads to no list; or nil
--   off(row)      true where the row is shown and cannot be pressed
--   reason(row)   the words for why, shown on the right in the place of what it would lead to
--   refresh()     called before the lists are made afresh
--   opens(row)    true where the row is marked as leading somewhere
--   sub(row)      the line under a row's name; else its `detail`
--   marks         the current row is marked in the first list too, not only in the second
--   status(roll)  the header's line: the words, and the name of the colour they take; or nil
--   notice()      the title and the message a tap on that line shows; or nil
--   icon(row)     the picture of a row, a file; or nil
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
local Tree = requireModule("widgets/dashboard/menu_tree.lua")
local Roll = requireModule("widgets/dashboard/menu_roll.lua")
local ConnectionStatus = requireModule("lib/connection_status.lua")
local MspRuntime = requireModule("tasks/msp/runtime.lua")
local Events = requireModule("tasks/events/runtime.lua")
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
    if value == "ok" and widget._viewStack == session and Views.roll(widget, roll.view) == roll
      and Views.status(widget, entry.id) == "ok" then
      Views.navigate(widget, "done")
    end
  end
  Menu.run(widget, entry, choice, "none", report)
end

-- Why a row of the quick menu cannot be pressed now, or nil where it can. These are the passing
-- states: the model armed, and no connection for a row that needs one. `selectable = false` is the
-- row's own word and is not one of them.
local REASON_ARMED, REASON_FC = "armed", "fc"

local function quickWhy(widget, entry)
  if widget.state and widget.state.armed == true then return REASON_ARMED end
  local id = entry.id
  if (id == "erase_blackbox" or id == "battery_profile") and widget.connectionReady ~= true then return REASON_FC end
  return nil
end

-- A row of the suite's menu.
local function treeWhy(widget, row)
  if widget.state and widget.state.armed == true then return REASON_ARMED end
  if row.needsFc == true and not Tree.connected() then return REASON_FC end
  return nil
end

-- Armed, every row of every list is grey, whatever it is; else it depends on the row.
local function whyOf(widget, row)
  if widget.state and widget.state.armed == true then return REASON_ARMED end
  if row.tree == true then return treeWhy(widget, row) end
  if row.id ~= nil and row.kind ~= nil then return quickWhy(widget, row) end
  return nil
end

-- Whether a quick menu row is there at all, given that passing states grey it rather than take it
-- away: BATTERY with no packs for this model and a tuning overlay switched off stay absent. An entry
-- says so with `existsWhen`, and one that does not is always there.
local function quickExists(widget, entry)
  return entry.existsWhen == nil or Views.condition(entry.existsWhen, widget) == true
end

-- The connection as the tool's header reads it, asked for by what the wheel's pass draws; four times a
-- second is more than it changes.
local CONNECTION_TICKS = 25

local function connectionNow()
  local session = _G.rfsuite and _G.rfsuite.session or nil
  local msp = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil
  local linkUp
  if type(msp) == "table" then
    linkUp = msp.lastConnected == true
  else
    linkUp = type(session) == "table" and session.rawRfConnected == true
  end
  -- Asked by the firmware's own sweep, outside the widget's pass: the connect runner counts per context,
  -- and only the widget's holds the tasks that run here.
  local previous = type(session) == "table" and session.event_context or nil
  if type(session) == "table" then session.event_context = "widget" end
  local status, detail, taskName, done, total, failed = ConnectionStatus.read(session, linkUp, Tree.connected(), Events)
  if type(session) == "table" then session.event_context = previous end
  return session, status, detail, taskName, done, total, failed
end

local Look = requireModule("widgets/dashboard/menu_look.lua")
local ICON_ROOT = _G.rfsuite.paths.core .. "/widgets/dashboard/roll_icons/"

local KEY_ROLE = { nolink = "warning", handshake = "warning", error = "error", ready = "muted" }

--- The quick menu: the entries offered now, BATTERY PROFILE last where it is, and MAIN MENU rolling on
--- through the suite's menu.
function M.quick(widget, entries, t)
  local session = Views.session(widget)
  local tree = Tree.of(widget, session)
  local connectionAt, connectionWord, connectionRole = nil, nil, nil
  local function reasonOf(row)
    local why = row ~= nil and whyOf(widget, row) or nil
    if why == REASON_ARMED then return t("widgets.dashboard.roll_not_armed", "Not while armed") end
    if why == REASON_FC then return t("widgets.dashboard.roll_needs_fc", "Needs the flight controller") end
    return nil
  end
  local function listOf(row)
    if row.id == "tool" and row.tree ~= true then return Tree.top(widget, tree) end
    if row.tree == true then return Tree.children(widget, tree, row) end
    return optionsOf(widget, row)
  end
  return {
    id = Views.DEFAULT_VIEW,
    title = t("widgets.dashboard.quick_settings", "QUICK SETTINGS"),
    refresh = function() Tree.refresh(tree) end,
    rows = function()
      local out = {}
      for i = 1, #entries do
        local entry = entries[i]
        if entry.id ~= "battery_profile" and quickExists(widget, entry) then out[#out + 1] = entry end
      end
      local profile = Menu.entry(widget, "battery_profile")
      if profile ~= nil and quickExists(widget, profile) then out[#out + 1] = profile end
      return out
    end,
    preview = listOf,
    enter = function(entry)
      if type(entry.confirm) == "table" then return answers(entry.confirm), entry.confirm end
      return listOf(entry), nil
    end,
    act = function(path, roll)
      local entry, choice = path[#path], nil
      if #path >= 2 and path[1].tree ~= true and path[2].tree ~= true then
        entry, choice = path[1], path[2]
      end
      if entry.tree == true then
        trace("visit " .. tostring(entry.menuId))
        Views.visit(widget, entry.menuId, Roll.place(roll))
        return nil
      end
      if choice == nil then
        trace("run " .. tostring(entry.id))
        local page = type(entry.after) == "string" and string.match(entry.after, "^openTool:(.+)$") or nil
        if page ~= nil then
          Views.visit(widget, page, Roll.place(roll))
          return nil
        end
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
    off = function(row) return row.selectable == false or whyOf(widget, row) ~= nil end,
    reason = reasonOf,
    opens = function(entry)
      if whyOf(widget, entry) ~= nil then return false end
      return entry.view ~= nil or entry.kind == "level" or (entry.id == "tool" and entry.tree ~= true)
    end,
    sub = function(row)
      if row.tree == true then return nil end
      if row.detail ~= nil then return row.detail end
      if type(row.info) ~= "function" then return nil end
      local percent = Menu.fillPercent(row)
      if percent == nil then return nil end
      return string.format(t("widgets.dashboard.erase_blackbox_confirm_used", "%d%% used"), percent)
    end,
    -- One message by rank: how a write went, or that a page could not be opened; then the connection.
    status = function(roll)
      local word = statusWord(widget, t, "battery_profile") or statusWord(widget, t, "battery_pick")
      if word ~= nil then return word, "headText" end
      if roll ~= nil and roll.couldNotOpen == true then
        return t("widgets.dashboard.roll_could_not_open", "Could not open"), "error"
      end
      local now = getTime()
      if connectionAt == nil or now - connectionAt >= CONNECTION_TICKS then
        connectionAt = now
        local _, status, detail, _, _, _, failed = connectionNow()
        local key = ConnectionStatus.stateKey(status, detail, failed)
        connectionWord, connectionRole = ConnectionStatus.title(widget.i18n, key), KEY_ROLE[key]
      end
      return connectionWord, connectionRole
    end,
    notice = function()
      local session, status, detail, taskName, done, total, failed = connectionNow()
      return ConnectionStatus.notice(widget.i18n, session, status, detail, taskName, done, total, failed)
    end,
    noticeClose = t("widgets.dashboard.roll_close", "Close"),
    icon = function(row)
      if row.iconFile == nil then
        local look = (Look ~= nil and Look.schemeName(widget)) or "light"
        row.iconFile = ICON_ROOT .. look .. "/" .. tostring(row.icon or row.id) .. ".png"
      end
      return row.iconFile
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
