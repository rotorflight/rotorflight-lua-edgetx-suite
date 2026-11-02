-- The dashboard widget's fullscreen views: which surface fullscreen shows, and what follows a
-- press on one of them.
--
-- A view is a module with `build(children, widget)`, and optionally `renderKey(widget)`, that
-- draws the whole fullscreen tree. A free-form theme may register views of its own and replace
-- the look of the widget's (see `register` below); a theme's module has `build(children, zone,
-- state, ctx)` instead, like the rest of a theme. Which one is on screen is a bounded stack of
-- view ids on the widget, `widget._viewStack`, lying above a base layer:
--
--   * the top of the stack is what fullscreen shows;
--   * with the stack empty the base layer shows. `widget._viewBase` names it: `"theme"` while the
--     active theme has asked for fullscreen (`fullscreen = "theme"` in its init.lua), which the
--     runtime then builds at the fullscreen size, and nil otherwise. With no base layer and an
--     empty stack the default view -- the quick menu -- is shown, which is what fullscreen has
--     always shown on entry.
--
-- The stack is one field, so that the pass which arrives without an event -- fullscreen has
-- been left, possibly by a long press on RTN that Lua never saw -- drops all of it in one
-- assignment in widgets/dashboard/runtime.lua. The same table is the fullscreen session: what
-- else belongs to one visit to fullscreen -- the outcome of the work a theme ran -- is kept on
-- it, beside the views, and goes with it. Once a visit has one, it stays a table while the
-- visit lasts, empty or not.
--
-- What follows a press is data rather than code. An entry, an option or a button carries an
-- `after` action; its `press` does the work only, and `navigate()` below performs the follow-up.
-- `navigate()` is therefore the one place a view leaves fullscreen from. The in-flight tuning
-- surface is not a view here -- it takes fullscreen ahead of all of them -- and keeps its own
-- close box.
--
-- Loaded on the first fullscreen pass, never on a zone pass -- except that of a free-form theme
-- that registers zone views, whose conditions are asked here -- and by the rfsuite.batteryPick
-- handle when something calls it. Nothing here is module state: the registry and the stack live
-- on the widget, so a second copy of this module would change nothing.

local M = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require) or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local chunk = loadScript(fullPath, "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Log = requireModule("lib/log.lua")
local KeyBindings = nil

local function viewLog(msg)
  if Log and type(Log.emit) == "function" then
    Log.emit("rfsuite.widget", msg, "warn")
  end
end

-- How deep the stack may grow. A push beyond it is refused rather than dropping the bottom
-- entry: a view that silently disappeared from under the others would be a way back that no
-- longer leads anywhere.
M.STACK_LIMIT = 4

-- What an empty stack shows when there is no base layer.
M.DEFAULT_VIEW = "menu"

-- The view that asks a press its question before the press is performed. It carries no
-- `openWhen`: it only ever opens from `M.confirm`, which an entry's own `confirm` reaches
-- (widgets/dashboard/fullscreen_menu.lua, `M.run`).
local CONFIRM_VIEW = "confirm"

-- The views the widget ships, in the order their `openWhen` is asked, ahead of a theme's.
local CORE_VIEWS = {
  { id = "battery_pick", module = "widgets/dashboard/battery_pick_menu.lua", openWhen = "batteryPickPending" },
  { id = CONFIRM_VIEW, module = "widgets/dashboard/confirm_menu.lua" },
  { id = "battery_profile", module = "widgets/dashboard/battery_profile_menu.lua" },
  { id = "menu", module = "widgets/dashboard/fullscreen_menu.lua" },
}

-- ---------------------------------------------------------------------------
-- Conditions
-- ---------------------------------------------------------------------------

-- The conditions a menu entry's `visibleWhen` and a view's `openWhen` may name. Both are asked
-- on the pass that draws or resolves, so a condition is a function of the widget rather than a
-- flag in a table prepared beforehand; a name that is not here is false, which hides an entry
-- and never opens a view -- what an unresolvable condition does in `app/menu_registry.lua` as
-- well.
--
-- Only the vocabulary an entry or a view actually uses is resolved. `enabledWhen` and
-- `lockedWhileArmed` are part of the same manifest vocabulary and nothing sets one, so the
-- first entry that needs one brings its resolver with it. `confirm` is the first that did, and
-- its resolver is not a condition but the confirmation below: an entry that carries one is
-- held by `M.run` until the pilot has answered.
--
-- A condition that opens a view is cleared by whoever set it when the view is answered or
-- closed. A view opens when its condition rises, not while it holds (see `resolve`), so one that
-- is closed while its condition is still true stays closed until the condition has fallen and
-- risen again.
local CONDITIONS = {}

-- In-flight tuning, while the preview switch and the radio's own master switch for the
-- overlay are both on -- the two preferences runtime.lua's inflightEnabled reads.
--
-- This entry is the only way the tuning surface is opened, and the drive that publishes
-- `state.inflight` runs only while that surface is open. So the entry is decided from the
-- preferences of this pass and never from the snapshot: asking for the snapshot would hide
-- the entry until the surface had been opened, which it then never could be.
--
-- It is offered only while the model is disarmed, so a mis-press in the air -- of the entry or
-- of a key bound to it -- cannot open a surface that changes flight controller parameters. A
-- surface opened on the ground stays open through arming; one closed in the air (the firmware's
-- fullscreen exit, a page switch) can be opened again after the landing.
function CONDITIONS.previewInflightTuning(widget)
  if widget.state and widget.state.armed == true then return false end
  local prefs = widget.preferences
  local previewOn = prefs and prefs.general and prefs.general.preview_inflight_tuning == true
  local radioOn = prefs and type(prefs.inflight) == "table" and prefs.inflight.enabled == true
  return previewOn == true and radioOn == true
end

-- The battery prompt, re-opened: only where the registry has a pack for this model, so a pilot
-- who keeps no registry never sees a button that opens an empty list, and only while the model
-- is disarmed, because a pack chosen in the air would be recorded against the flight in progress.
function CONDITIONS.batteryPickHasPacks(widget)
  if widget.state and widget.state.armed == true then return false end
  local pick = widget.state and widget.state.batteryPick or nil
  local candidates = (type(pick) == "table" and type(pick.candidates) == "table") and pick.candidates or nil
  return candidates ~= nil and #candidates > 0
end

-- The battery prompt is waiting for an answer. Raised by the runtime's registry load once per
-- connection; cleared by a pick, by closing the picker, by arming and by a reconnect.
--
-- A pick is answered in two steps: the press records `_batteryPickRequest`, and `pending` falls
-- only when the runtime's apply step has run in a free job slot, some passes later. In between
-- the prompt counts as answered, or a surface that stays up after the press -- the theme under
-- the picker -- would see the picker open again at once. The test is against nil because
-- `false` is a request too: it is the "no battery" answer.
function CONDITIONS.batteryPickPending(widget)
  local pick = widget.state and widget.state.batteryPick or nil
  return type(pick) == "table" and pick.pending == true and widget._batteryPickRequest == nil
end

-- The suite's tool, which is opened only while the model is disarmed (tool_host.lua says why),
-- and the quick menu's two writes, ERASE BLACKBOX and BATTERY PROFILE (below), which the MSP
-- runtime would drop while the model is armed.
function CONDITIONS.modelDisarmed(widget)
  return not (widget.state and widget.state.armed == true)
end

-- Fullscreen shortcuts can open the menu before the connection is ready. The rows that write to
-- the flight controller stay hidden until it is, as they do while the model is armed.
function CONDITIONS.connectionReadyDisarmed(widget)
  return widget.connectionReady == true and CONDITIONS.modelDisarmed(widget)
end

-- The BATTERY PROFILE row: while the connection is ready and the model is disarmed, like the write
-- it leads to, and only where the flight controller has reported at least one profile with a
-- capacity -- a row that opens a page with nothing to choose on it is not offered.
function CONDITIONS.batteryProfileOffered(widget)
  if not CONDITIONS.connectionReadyDisarmed(widget) then return false end
  local config = widget.state and widget.state.battery_config or nil
  if type(config) ~= "table" then return false end
  for i = 0, 5 do
    local cap = tonumber(config["batteryCapacity_" .. i])
    if cap ~= nil and cap > 0 then return true end
  end
  return false
end

-- The tool opened on its Flight Log page: like the tool, and like the page's own tile, only while
-- the model is disarmed.
function CONDITIONS.flightLogOffered(widget)
  return CONDITIONS.modelDisarmed(widget)
end

--- Whether the named condition holds for this widget. Unknown names, nil included, are false.
function M.condition(name, widget)
  local condition = CONDITIONS[name]
  if type(condition) ~= "function" then return false end
  return condition(widget) == true
end

-- ---------------------------------------------------------------------------
-- What opens a view
-- ---------------------------------------------------------------------------

-- A view's `openWhen` is one of:
--
--   "name"                                  a condition from the list above
--   { switch = "SA", pos = "up" }           a switch position: "up", "mid" or "down"
--   { switch = "L01" }                      a logical switch, true while it is on
--   { switch = { pref = "key", default = "SA" }, pos = "down" }
--                                           the switch the theme's own settings name under
--                                           `key` (state.themeConfig), `default` where they
--                                           name none
--   function(state) ... end                 a theme's own test of the widget state
--
-- A switch is named as the radio's menus name it, and the firmware looks the position up by that
-- name (getSwitchIndex, radio/src/strhelpers.cpp): the switch, then an arrow for up and down or
-- a dash for the middle (getSwitchPositionName, CHAR_UP / CHAR_DOWN in
-- radio/src/translations/untranslated.h), and a logical switch as L and two digits. A setting
-- that holds a number rather than a name is a stored switch POSITION -- what the radio's own
-- switch picker hands over, and what the in-flight tuning interlock stores -- and is read as it is.
local POSITION_SUFFIX = { up = "\194\130", mid = "-", down = "\194\131" }

-- A firmware function, or nil where this radio does not have it.
local function callGlobal(name, ...)
  local fn = _G[name]
  if type(fn) ~= "function" then return nil end
  return fn(...)
end

-- The switch position an `openWhen` names, as the index getSwitchValue takes; nil where it names
-- none this radio has.
--
-- Looked up once and kept on the registry entry, against the theme settings it was looked up
-- in: a theme load makes the registry anew, and saving the theme's settings replaces
-- `state.themeConfig`, so either one looks it up again, and every other pass reads one value.
local function switchIndex(entry, widget)
  local config = widget.state and widget.state.themeConfig or nil
  if entry.switchResolved and entry.switchFor == config then return entry.switchIndex end
  entry.switchResolved = true
  entry.switchFor = config

  local spec = entry.openWhen
  local name = spec.switch
  if type(name) == "table" then
    local setting = (type(config) == "table" and name.pref ~= nil) and config[name.pref] or nil
    if setting == nil or setting == "" then setting = name.default end
    name = setting
  end

  local index = nil
  local position = tonumber(name)
  if position ~= nil then
    if position ~= 0 then index = position end
  elseif type(name) == "string" and name ~= "" then
    local logical = string.match(name, "^[Ll](%d+)$")
    local lookup = nil
    if logical ~= nil then
      lookup = string.format("L%02d", tonumber(logical))
    elseif spec.pos == nil then
      lookup = name
    elseif POSITION_SUFFIX[spec.pos] ~= nil then
      lookup = name .. POSITION_SUFFIX[spec.pos]
    end
    if lookup ~= nil then index = callGlobal("getSwitchIndex", lookup) end
  end
  entry.switchIndex = index
  return index
end

--- Whether the view's `openWhen` holds on this pass.
--
-- A theme's function is called with the widget state and nothing else, under pcall: one that
-- raises answers false, and says so in one log line per theme and view for the life of the
-- widget, rather than on every pass it keeps raising.
function M.opens(entry, widget)
  local spec = entry.openWhen
  local kind = type(spec)
  if kind == "string" then return M.condition(spec, widget) end
  if kind == "table" then
    local index = switchIndex(entry, widget)
    if index == nil then return false end
    return callGlobal("getSwitchValue", index) == true
  end
  if kind == "function" then
    local ok, result = pcall(spec, widget.state)
    if ok then return result ~= nil and result ~= false end
    local faults = widget._viewFaults
    if faults == nil then
      faults = {}
      widget._viewFaults = faults
    end
    local key = tostring(widget.themePath) .. "|" .. tostring(entry.id)
    if not faults[key] then
      faults[key] = true
      viewLog("view '" .. tostring(entry.id) .. "': its openWhen raised and counts as false: " .. tostring(result))
    end
    return false
  end
  return false
end

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

--- This widget's views, in `openWhen` order.
--
-- A copy per widget, entry tables included: the runtime caches a view's loaded module on its
-- entry, and a later addition to one widget's list must not reach another's.
function M.registry(widget)
  local registry = widget._viewRegistry
  if registry == nil then
    registry = {}
    for i = 1, #CORE_VIEWS do
      local entry = {}
      for k, v in pairs(CORE_VIEWS[i]) do entry[k] = v end
      registry[i] = entry
    end
    widget._viewRegistry = registry
  end
  return registry
end

--- This widget's registry entry for `id`, or nil.
function M.find(widget, id)
  local registry = M.registry(widget)
  for i = 1, #registry do
    if registry[i].id == id then return registry[i] end
  end
  return nil
end

--- Make this widget's registry anew: the core views, then the views the theme on screen
--- registers.
--
-- `themeViews` is a list of `{ id, openWhen, load }`, in the theme's order; `load()` returns the
-- theme's module, read through the theme loader, and is not called here -- a theme's view is
-- loaded when it is first built, so a theme that registers ten views and opens one pays for one.
--
--   * An id the widget already has replaces that view's LOOK and nothing else. The core module
--     stays the entry's `module`, and its `back`, its `openWhen` and what its presses are
--     followed by are still the core's; the theme's module only draws it.
--   * Any other id is a view of the theme's own, after the core views.
--
-- An entry that carries `load` is built `build(children, zone, state, ctx)` like the rest of a
-- theme; a core view keeps `build(children, widget)`.
--
-- A view on the stack that the new registry no longer has is taken off it. Left there it would
-- be a job no step can build, queued again on every pass.
function M.register(widget, themeViews)
  widget._viewRegistry = nil
  local registry = M.registry(widget)
  if type(themeViews) == "table" then
    for i = 1, #themeViews do
      local view = themeViews[i]
      local entry = M.find(widget, view.id)
      if entry == nil then
        registry[#registry + 1] = { id = view.id, openWhen = view.openWhen, load = view.load, theme = true }
      elseif entry.load == nil then
        entry.load = view.load
      end
    end
  end

  local stack = widget._viewStack
  if stack ~= nil then
    for i = #stack, 1, -1 do
      if M.find(widget, stack[i].id) == nil then table.remove(stack, i) end
    end
  end
  return registry
end

-- ---------------------------------------------------------------------------
-- The stack
-- ---------------------------------------------------------------------------

local function indexOf(stack, id)
  if stack == nil then return nil end
  for i = 1, #stack do
    if stack[i].id == id then return i end
  end
  return nil
end

--- The id of the view on top of the stack, or nil when the stack is empty.
function M.top(widget)
  local stack = widget._viewStack
  local entry = stack and stack[#stack] or nil
  return entry and entry.id or nil
end

-- Put `id` on top. A view already on the stack is returned to -- everything above it is
-- dropped -- rather than pushed a second time. An explicit open (`auto` not set) takes the
-- automatic mark off an entry its condition had pushed, so it no longer closes when the
-- condition falls.
--
-- Returns false when nothing changed because the stack is full. The refusal is logged once and
-- the latch sits on the stack table itself, so any change to the stack -- the one-assignment
-- clear included -- rearms it; the resolve pass runs on every interactive pass and must not log
-- on every one of them.
local function push(widget, id, auto)
  local stack = widget._viewStack
  local at = indexOf(stack, id)
  if at ~= nil then
    for i = #stack, at + 1, -1 do stack[i] = nil end
    if not auto then stack[at].auto = nil end
    stack.refused = nil
    return true
  end
  stack = stack or {}
  if #stack >= M.STACK_LIMIT then
    if not stack.refused then
      stack.refused = true
      viewLog("view '" .. tostring(id) .. "' not opened: the view stack is full")
    end
    return false
  end
  stack[#stack + 1] = { id = id, auto = auto and true or nil }
  stack.refused = nil
  widget._viewStack = stack
  return true
end

-- Take the top entry off. An empty stack stays a table: it is still the session of this visit
-- to fullscreen, and what is kept on it is not dropped by closing the last view.
local function pop(widget)
  local stack = widget._viewStack
  if stack == nil then return end
  stack[#stack] = nil
  stack.refused = nil
end

-- Bring `id` to the top. A view already on the stack is moved there, and the views that were
-- above it stay open, under it; a view that is not on it is pushed, marked automatic. This is
-- what the rise of a view's condition does -- where an explicit open returns to a view and closes
-- what lies above it.
local function raise(widget, id)
  local stack = widget._viewStack
  local at = indexOf(stack, id)
  if at == nil then return push(widget, id, true) end
  if at < #stack then
    local entry = table.remove(stack, at)
    stack[#stack + 1] = entry
    stack.refused = nil
  end
  return true
end

--- This visit's session: the stack table, made when a visit has none yet.
function M.session(widget)
  local stack = widget._viewStack
  if stack == nil then
    stack = {}
    widget._viewStack = stack
  end
  return stack
end

--- Give up on the theme's module for `entry`: it did not load, or its build raised. It is not
--- asked for again. A replaced look falls back to the core view, which is what the pilot then
--- gets; a view of the theme's own is refused from then on, and closed where it is open. Either
--- way with one log line, not one per pass.
function M.fail(widget, entry, why)
  viewLog("view '" .. tostring(entry.id) .. "' of the theme " .. why)
  entry.load = nil
  entry.loaded = nil
  if entry.theme then
    entry.failed = true
    local stack = widget._viewStack
    local at = indexOf(stack, entry.id)
    if at ~= nil then table.remove(stack, at) end
  end
end

--- Load the module that builds `entry`, once: the theme's where it has one for it, else the
--- core's. Returns nil where nothing loads; a theme's module that does not load is given up on
--- (`fail`).
function M.load(widget, entry)
  local view = entry.loaded
  if view ~= nil then return view end
  if entry.load ~= nil then
    view = entry.load()
    if type(view) ~= "table" or type(view.build) ~= "function" then
      M.fail(widget, entry, "did not load")
      if entry.theme then return nil end
      view = nil
    end
  end
  if view == nil then
    view = requireModule(entry.module)
    if type(view) ~= "table" or type(view.build) ~= "function" then return nil end
  end
  entry.loaded = view
  return view
end

--- The view fullscreen shows on this pass, and the render key for it.
--
-- Every view's `openWhen` is asked once per pass, in registry order -- the widget's views, then
-- the theme's in the order it lists them -- and what each answered is kept on the session for
-- the next pass (`held`). Then:
--
-- 1. A view its own condition opened is closed again once that condition has fallen. That is
--    what keeps the battery prompt as it has always been: it shows while it is pending, and
--    three places end the pending state without closing anything -- the arm edge in
--    `updateDerivedFlightState`, a pick in `batteryPickApplyStep`, and the reconnect edge.
-- 2. A view whose condition has RISEN -- false on the last pass, true on this one -- is opened,
--    or brought to the top where it is already open. Entering fullscreen with a condition
--    already true is a rise: a visit starts with nothing held. A condition that merely holds
--    forces nothing, so a view opened over it -- the menu over a switch's view -- stays usable,
--    and a view closed while its condition holds stays closed. Where several rise on one pass
--    each is brought up in turn, so the last of them in registry order is on top.
-- 3. The top of the stack is the view. With the stack empty: the base layer, reported as nil,
--    or with no base layer the default view.
--
-- The key is the view id, followed by the view's own `renderKey(widget)` where it has one and
-- its module is already loaded -- `renderKey(zone, state)` for a theme's module, as a theme's
-- phase module has it. A module is never loaded here; that is the job pass's work.
function M.resolve(widget)
  local registry = M.registry(widget)
  local session = M.session(widget)
  local held = session.held
  if held == nil then
    held = {}
    session.held = held
  end

  local risen = nil
  for i = 1, #registry do
    local entry = registry[i]
    if entry.openWhen ~= nil and not entry.failed then
      if M.opens(entry, widget) then
        if not held[entry.id] then
          risen = risen or {}
          risen[#risen + 1] = entry.id
          held[entry.id] = true
        end
      else
        held[entry.id] = nil
      end
    end
  end

  local changed = false
  for i = #session, 1, -1 do
    if session[i].auto and not held[session[i].id] then
      table.remove(session, i)
      changed = true
    end
  end
  if changed then session.refused = nil end

  if risen ~= nil then
    for i = 1, #risen do raise(widget, risen[i]) end
  end

  local id = M.top(widget)
  if id == nil then
    if widget._viewBase ~= nil then return nil, nil end
    id = M.DEFAULT_VIEW
  end

  return id, M.viewKey(widget, M.find(widget, id), id)
end

--- The render key of view `id`: the id, followed by its module's own `renderKey` where the
--- module is loaded and has one -- `renderKey(widget)` for the widget's views,
--- `renderKey(zone, state)` for a theme's.
--
-- `resolve` keys a view with it, and the job that first loads and builds a view records it, so
-- the pass after that build computes the key the build was made for rather than a longer one,
-- which would build the view a second time.
function M.viewKey(widget, entry, id)
  local view = entry and entry.loaded or nil
  if view ~= nil and type(view.renderKey) == "function" then
    if entry.load ~= nil then
      return id .. "|" .. tostring(view.renderKey(widget.zone, widget.state))
    end
    return id .. "|" .. tostring(view.renderKey(widget))
  end
  return id
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

-- An action is a string: `openView:<id>`, `closeView`, `done`, `exitFullscreen`, `openTool`,
-- `openTool:<menuId>`, `openTuning` or `none`.
local SIMPLE_ACTIONS = {
  closeView = true, done = true, exitFullscreen = true, openTool = true, openTuning = true, none = true
}

-- The pages `openTool:<menuId>` may open the tool on, each with the condition that has to hold for
-- it: the page has to be in the tool's menu and reachable now. A target that is not here is
-- refused, so a key bound to a page that is not offered does nothing rather than opening the tool
-- somewhere else.
local TOOL_LANDINGS = {
  tools_flight_log_page = "flightLogOffered",
}

--- The one place an action is read: its verb, and the view id for `openView` or the page for
--- `openTool:<menuId>`.
--
-- nil and anything unrecognised are `none`, so a missing `after` leaves the view where it is.
-- A later form that is not a string is added here and nowhere else.
function M.parseAction(after)
  if type(after) ~= "string" then return "none", nil end
  if SIMPLE_ACTIONS[after] then return after, nil end
  local id = string.match(after, "^openView:(.+)$")
  if id ~= nil then return "openView", id end
  local page = string.match(after, "^openTool:(.+)$")
  if page ~= nil then return "openTool", page end
  viewLog("unknown view action '" .. after .. "' ignored")
  return "none", nil
end

-- Whatever is built is dropped, so the next interactive pass builds the view now on top.
--
-- Navigation can arrive while a fullscreen view or connection splash is queued,
-- including on legacy themes. A stale job must not paint over the new surface.
function M.invalidate(widget)
  widget.built = false
  widget.renderKey = nil
  local job = widget._job
  if job ~= nil and (job.fullscreen or job.fullscreenSplash or M.find(widget, job.kind) ~= nil) then
    widget._job = nil
  end
end

local function exitFullscreen(widget)
  M.invalidate(widget)
  if lcd and type(lcd.exitFullScreen) == "function" then
    lcd.exitFullScreen()
  end
end

-- A new session, empty, which keeps only what the conditions of the THEME's views answered on
-- the last pass: the outcomes lapse, and a theme's view whose condition still holds is not opened
-- again over the surface the pilot returns to. The widget's own views are not carried over, so
-- the battery prompt, still waiting for an answer, comes back as a rise -- as it always has when
-- the menu over it was closed. `done` starts one, and so does `openTool`, whose tool takes
-- fullscreen while no pass asks a condition: what held when it opened is what the first pass
-- after it closes compares against.
local function newSession(widget)
  local old = widget._viewStack
  local carried = nil
  if old ~= nil and old.held ~= nil then
    for heldId in pairs(old.held) do
      local entry = M.find(widget, heldId)
      if entry ~= nil and entry.theme then
        carried = carried or {}
        carried[heldId] = true
      end
    end
  end
  widget._viewStack = carried and { held = carried } or nil
end

--- Perform the action that follows a press.
--
--   openView:<id>   open that view, or return to it where it is already on the stack
--   closeView       close the view on top; what is under it shows again
--   done            the interaction is finished: the stack is emptied, which leaves fullscreen
--                   where there is no base layer and shows the base layer where there is one;
--                   the session starts anew, carrying only what the theme's views' conditions
--                   last answered
--   exitFullscreen  empty the stack and leave fullscreen, base layer or not
--   openTool        open the suite's tool inside the widget (widgets/dashboard/tool_host.lua);
--                   it takes fullscreen until it is closed; the session starts anew as for
--                   `done`, so what the tool hands back to is the base layer, or the default
--                   view, and a theme's view whose condition still holds is not opened again
--   openTool:<menuId>
--                   the same, with the tool opened on that page rather than on its menu, and
--                   closed again by the back key there; only for a page in TOOL_LANDINGS whose
--                   condition holds, and nothing at all otherwise
--   none            nothing at all; the press did whatever needed doing itself
--
-- An `openView` that is refused -- a view this widget does not have, a theme's view that did not
-- load, or a full stack -- changes nothing and forces no rebuild. A view that is not in the
-- registry would otherwise be a job no step can build, re-queued on every pass.
function M.navigate(widget, after)
  local verb, id = M.parseAction(after)
  if verb == "none" then return end
  if verb == "openView" then
    local entry = M.find(widget, id)
    if entry == nil or entry.failed then
      viewLog("view '" .. id .. "' not opened: this widget has no such view")
      return
    end
    if not push(widget, id, false) then return end
    M.invalidate(widget)
  elseif verb == "closeView" then
    pop(widget)
    M.invalidate(widget)
  elseif verb == "done" then
    newSession(widget)
    if widget._viewBase == nil then
      exitFullscreen(widget)
      return true
    else
      M.invalidate(widget)
    end
  elseif verb == "exitFullscreen" then
    widget._viewStack = nil
    exitFullscreen(widget)
    return true
  elseif verb == "openTuning" then
    -- The same flag the quick menu's IN-FLIGHT TUNING entry raises, under the same condition: a
    -- key bound to it does nothing where the entry would not be offered.
    if not M.condition("previewInflightTuning", widget) then
      viewLog("in-flight tuning not opened: the overlay is not enabled, or the model is armed")
      return
    end
    widget.inflightFullscreen = true
    M.invalidate(widget)
  elseif verb == "openTool" then
    if id ~= nil and not M.condition(TOOL_LANDINGS[id], widget) then
      viewLog("tool not opened on '" .. id .. "': that page is not offered now")
      return
    end
    local ToolHost = requireModule("widgets/dashboard/tool_host.lua")
    if type(ToolHost) == "table" and type(ToolHost.request) == "function" and ToolHost.request(widget, id) then
      newSession(widget)
      M.invalidate(widget)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Confirmations
-- ---------------------------------------------------------------------------

--- Hold a press behind the pilot's answer, and raise the question that asks for it.
--
-- `spec` is the entry's `confirm` table, its strings already resolved: `title`, `message`, and
-- the optional `detail`, `confirmLabel` and `cancelLabel`. `work` is the press and the action
-- that follows it, run only where the pilot agrees.
--
-- Returns true when the question is up. False where there is no confirmation view or no room
-- left on the stack, and the caller must then NOT run `work`: a press that cannot ask its
-- question does nothing rather than doing it unguarded. That is the whole point of a
-- confirmation on an irreversible action -- refusing loses nothing, proceeding loses the logs.
--
-- The pending press lives on this visit's session, beside the views, and goes when the visit
-- does: a full screen left with the question standing never performs it. A second press while a
-- question is up replaces the first -- there is one question at a time.
function M.confirm(widget, spec, work)
  if type(spec) ~= "table" or type(work) ~= "function" then return false end
  if M.find(widget, CONFIRM_VIEW) == nil then return false end
  local session = M.session(widget)
  session.confirm = { spec = spec, work = work }
  if not push(widget, CONFIRM_VIEW, false) then
    session.confirm = nil
    return false
  end
  M.invalidate(widget)
  return true
end

--- The press waiting for an answer, or nil: `{ spec, work }` on this visit's session.
function M.pendingConfirm(widget)
  local session = widget._viewStack
  return session and session.confirm or nil
end

--- Answer the question and close it: forget the pending press and take the confirmation view off
-- the stack, so the surface under it shows again. The `work` the question held is NOT run here --
-- the caller runs it (agreeing) or does not (declining).
--
-- The view is removed only where it is on top; a question that is not the surface showing leaves
-- the stack as it is.
function M.closeConfirm(widget)
  local session = widget._viewStack
  if session ~= nil then session.confirm = nil end
  if M.top(widget) == CONFIRM_VIEW then
    pop(widget)
    M.invalidate(widget)
  end
end

-- ---------------------------------------------------------------------------
-- Outcomes
-- ---------------------------------------------------------------------------

-- What became of the work a theme ran through `ctx.run`, per entry id: "busy" once the work has
-- queued its messages to the flight controller, "ok" when the last of them has been answered,
-- "failed" when any of them was given up -- out of retries, timed out, or dropped by a clear of
-- the queue. Work that queues nothing has no outcome.
--
-- The outcome is kept on the session it was started in and lapses with it: `done`,
-- `exitFullscreen`, the pass without an event and a reconnect all start a new one. A reply that
-- arrives after that writes into the session it belonged to, which nothing reads any more, and
-- forces no rebuild -- the widget may be back in its zone by then. Of two runs of one entry the
-- later one is reported; a chain that has failed stays failed.

--- A reporter for one run of entry `id`, bound to this visit's session.
function M.reporter(widget, id)
  local session = M.session(widget)
  local runs = session.runs
  if runs == nil then
    runs = {}
    session.runs = runs
  end
  local failed = false
  local report
  report = function(value)
    if failed or session.runs ~= runs or runs[id] ~= report then return end
    if value == "failed" then failed = true end
    local status = session.status
    if status == nil then
      status = {}
      session.status = status
    end
    if status[id] == value then return end
    status[id] = value
    -- A theme draws the outcome, so a new one is a new picture.
    if widget._viewStack == session then
      widget.built = false
      widget.renderKey = nil
    end
  end
  runs[id] = report
  return report
end

--- The outcome of the last run of entry `id` in this visit: nil, "busy", "ok" or "failed".
function M.status(widget, id)
  local session = widget._viewStack
  local status = session and session.status or nil
  return status and status[id] or nil
end

--- Drop every outcome: the theme they were drawn by has gone.
function M.forgetOutcomes(widget)
  local session = widget._viewStack
  if session ~= nil then
    session.status = nil
    session.runs = nil
  end
end

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

-- The keys only a theme gives a meaning to. Outside fullscreen they are the firmware's shortcuts
-- (NavWindow::onEvent in gui/colorlcd/libui/window.cpp); a fullscreen widget is no NavWindow, and
-- LuaWidget::onEvent hands them to the script instead, so without a binding they do nothing.
local THEME_KEYS = { mdl = true, sys = true, tele = true }

-- The firmware's names for the keys, read when a key arrives rather than when this file loads,
-- and compared only where the radio defines them. The values differ between targets
-- (radio/util/hw_defs/lua_keys.jinja maps each onto the release edge of whatever key the radio
-- has), so no number is written down here. Only the release edges are answered: the press edge
-- of RTN is also what a long press delivers before the firmware leaves fullscreen on its own.
-- MDL, SYS and TELE are asked after the three every radio's layout uses.
local function keyName(event)
  local nextPage, prevPage, exit = _G.EVT_VIRTUAL_NEXT_PAGE, _G.EVT_VIRTUAL_PREV_PAGE, _G.EVT_VIRTUAL_EXIT
  if nextPage ~= nil and event == nextPage then return "pageDown" end
  if prevPage ~= nil and event == prevPage then return "pageUp" end
  if exit ~= nil and event == exit then return "exit" end
  local mdl, sys, tele = _G.EVT_MODEL_BREAK, _G.EVT_SYS_BREAK, _G.EVT_TELEM_BREAK
  if mdl ~= nil and event == mdl then return "mdl" end
  if sys ~= nil and event == sys then return "sys" end
  if tele ~= nil and event == tele then return "tele" end
  return nil
end

--- Answer a fullscreen key. Returns true when the key was one of the six and answered. Theme
--- bindings for MDL, SYS and TELE with a view on top return false unless they toggle that view;
--- a radio-wide choice (Settings > Dashboard > Keys, widgets/dashboard/keys.lua) still applies
--- on top. That includes a key's default there: the page keys, SYS and TELE are not on Theme
--- unless the pilot put them there. The rules below are those of a key on Theme.
--
--   PAGE down / up  with the quick menu on top: close it. With any other view on top: open the
--                   menu over it. With the base layer showing: `ctx.keys`, then `init.keys`,
--                   else nothing.
--   RTN             with a view on top: that view's `back(widget)` where its module has one --
--                   for a view of the theme's own, `back(ctx)` -- else `closeView`. With the
--                   base layer showing: its `keys.exit`, else nothing -- a long press on RTN
--                   still leaves fullscreen, in the firmware.
--   MDL, SYS, TELE  with the base layer showing: `ctx.keys`, then `init.keys`,
--                   else nothing. With a view on top: a key on Theme does nothing, while a
--                   radio-wide choice still applies.
--
-- A key the base layer binds to `openView:<id>`, RTN aside, closes that view again while it is
-- on top, whatever the rules above say for that key: a bound key toggles its view.
--
-- With the theme base showing and no view on top, unbound Theme keys are consumed without
-- navigation. The runtime calls this ahead of builds and connection splashes, except while the
-- tool or tuning owns input. Radio-wide choices also work without a theme base; Theme keys
-- return false there so LVGL can handle them.
function M.key(widget, event)
  local name = keyName(event)
  if name == nil then return false end
  local top = M.top(widget)
  local ctx = widget._viewCtx
  local keys = ctx and ctx.keys
  if KeyBindings == nil then KeyBindings = requireModule("widgets/dashboard/keys.lua") end
  local bound, global
  if KeyBindings then
    local prefs = widget.preferences
    bound, global = KeyBindings.resolve(prefs and prefs.dashboard, name, keys, widget._declaredKeys)
  else
    bound = type(keys) == "table" and keys[name] or nil
  end
  -- A theme without a base layer binds no keys of its own, so a key on Theme stays unanswered
  -- there; a radio-wide choice works on those themes as well.
  if widget._viewBase == nil and not global then return false end
  local after
  if global then
    after = bound
    if top ~= nil and bound == "openView:" .. top then after = "closeView" end
  elseif top == nil then
    -- An absent base-layer binding is consumed below without navigation, including PAGE keys.
    after = bound
  elseif name ~= "exit" and bound == "openView:" .. top then
    -- The key bound to the view on top: close it, rather than open the menu over it.
    after = "closeView"
  elseif THEME_KEYS[name] then
    return false
  elseif name == "exit" then
    local entry = M.find(widget, top)
    if entry ~= nil and entry.module ~= nil then
      -- A core view: its own `back(widget)`, whoever draws it. A theme that replaced the look
      -- did not replace what RTN does.
      local core = entry.core
      if core == nil then
        core = requireModule(entry.module)
        if type(core) == "table" then entry.core = core end
      end
      if type(core) == "table" and type(core.back) == "function" then
        core.back(widget)
        return true
      end
    elseif entry ~= nil then
      -- A view of the theme's own: its `back(ctx)` where it declares one.
      local view = M.load(widget, entry)
      if view ~= nil and type(view.back) == "function" then
        view.back(widget._viewCtx or M.bind(widget))
        return true
      end
    end
    after = "closeView"
  elseif top == M.DEFAULT_VIEW then
    after = "closeView"
  else
    after = "openView:" .. M.DEFAULT_VIEW
  end
  local exited = M.navigate(widget, after)
  return true, exited
end

-- ---------------------------------------------------------------------------
-- The context a theme is handed
-- ---------------------------------------------------------------------------

--- The actions and building blocks, bound to one widget, for code that holds no widget of its
--- own to pass -- above all a theme that draws its own fullscreen, which receives this as the
--- third argument of its `build(zone, state, ctx)`.
--
--   ctx.action(after)          performs `after` exactly as `navigate(widget, after)` does
--   ctx.keys                   a table the theme fills: `exit`, `pageDown`, `pageUp`, `mdl`,
--                              `sys`, `tele`, each an action; read by `key()` while the base
--                              layer shows
--   ctx.condition(name)        `condition(name, widget)`
--   ctx.entries()              the quick menu's entries, `fullscreen_menu.entries(widget)`: the
--                              ones the pilot has put in it, in the pilot's order
--   ctx.menu(children, list)   the quick menu's builder, appending to `children`; `list`
--                              defaults to the menu's own entries, and one handed in chooses
--                              and orders them by id -- it cannot bring a press of its own
--
-- and, for a theme that draws the entries itself -- the theme draws, the widget acts:
--
--   ctx.entry(id)              the entry `id` of the menu's records, or nil -- whether or not
--                              the pilot has put it in the quick menu
--   ctx.list(name)             the records of a named list (`fullscreen_menu.LISTS`), in its
--                              order -- for "quick" the pilot's list; an empty list for a name
--                              there is none of
--   ctx.visible(entry)         whether the entry is offered now, as the quick menu asks it
--   ctx.run(entry, option, after)
--                              the entry's work, or the option's, and then what follows it --
--                              the menu's own record and option of that id, whatever table the
--                              theme hands in; `after` replaces the follow-up, nil keeps it
--   ctx.status(id)             what became of the last `ctx.run` of that entry in this visit
--                              to fullscreen: nil, "busy", "ok" or "failed"
--   ctx.info(entry)            what the entry has to say about the state it acts on, read now
--                              (the blackbox fill for ERASE BLACKBOX), or nil
--
-- The menu module is loaded on the first call that needs it, not here.
function M.bind(widget)
  local menu = nil
  local function menuModule()
    if menu == nil then menu = requireModule("widgets/dashboard/fullscreen_menu.lua") end
    if type(menu) == "table" then return menu end
    return nil
  end
  return {
    action = function(after) M.navigate(widget, after) end,
    keys = {},
    condition = function(name) return M.condition(name, widget) end,
    entries = function()
      local m = menuModule()
      if m and type(m.entries) == "function" then return m.entries(widget) end
      return {}
    end,
    -- A list a theme hands in chooses and orders the menu's own entries and nothing more: each
    -- item is replaced by the menu's record of that id, and an item whose id the menu does not
    -- have is left out, so no press of the theme's is ever drawn as one of the menu's.
    menu = function(children, entries)
      local m = menuModule()
      if not (m and type(m.build) == "function") then return children end
      if entries ~= nil then
        entries = type(m.coreList) == "function" and m.coreList(widget, entries) or {}
      end
      m.build(children, widget, entries)
      return children
    end,
    entry = function(id)
      local m = menuModule()
      if m and type(m.entry) == "function" then return m.entry(widget, id) end
      return nil
    end,
    list = function(name)
      local m = menuModule()
      if m and type(m.list) == "function" then return m.list(widget, name) end
      return {}
    end,
    visible = function(entry)
      local m = menuModule()
      local core = (m and type(m.resolve) == "function") and m.resolve(widget, entry) or nil
      if core == nil then return false end
      return m.visible(widget, core)
    end,
    -- What is run is the menu's own record, and its own option, looked up again from what the
    -- theme hands in: never a press out of the theme's table. An entry or an option the menu does
    -- not have is refused, so a theme cannot put work of its own behind the widget's name for it.
    -- Only `after`, the follow-up, is the theme's to choose.
    run = function(entry, option, after)
      local m = menuModule()
      if not (m and type(m.resolve) == "function" and type(m.run) == "function") then return end
      local core, coreOption = m.resolve(widget, entry, option)
      if core == nil then
        viewLog("entry '" .. tostring(type(entry) == "table" and entry.id or entry)
          .. "' not run: the menu has no such entry or option")
        return
      end
      m.run(widget, core, coreOption, after, M.reporter(widget, core.id))
    end,
    status = function(id) return M.status(widget, id) end,
    info = function(entry)
      local m = menuModule()
      local core = (m and type(m.resolve) == "function") and m.resolve(widget, entry) or nil
      if core ~= nil and type(core.info) == "function" then return core.info() end
      return nil
    end,
  }
end

return M
