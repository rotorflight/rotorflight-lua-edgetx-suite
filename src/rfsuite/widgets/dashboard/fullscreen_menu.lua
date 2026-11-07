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

-- The translator, with the fallback the menu has always carried: a widget that has no i18n
-- table of its own still draws the English text an entry names.
local function translator(widget)
  local i18n = widget.i18n
  if i18n and type(i18n.t) == "function" then return i18n.t end
  return function(k, f) return f or k end
end

-- The fullscreen views' shared vocabulary: the conditions a `visibleWhen` may name, and the
-- actions an `after` may name.
local Views = requireModule("widgets/dashboard/views.lua")

local Log = requireModule("lib/log.lua")

local Look = requireModule("widgets/dashboard/menu_look.lua")

-- An entry without `visibleWhen` is always there. A named condition is resolved in views.lua,
-- where a name that is not known is false and hides its entry, which is what an unresolvable
-- condition does in `app/menu_registry.lua` as well.
local function isEntryVisible(entry, widget)
  local conditionKey = entry.visibleWhen
  if conditionKey == nil then return true end
  if not (Views and type(Views.condition) == "function") then return false end
  return Views.condition(conditionKey, widget) == true
end

-- Whether a press on a row is refused because the menu does not offer that row now. A refused
-- press does nothing, nothing follows it, and the surface is built again, so the row is gone.
--
-- Hiding the row is not enough on its own: a view is built again only when its key changes, and
-- the arm edge does not change the menu's, so a menu that was open when the model armed -- or a
-- theme's page drawn from the same records -- still shows the row, and an ERASE answered after
-- the arm was asked before it. The work would come to nothing anyway: the MSP runtime clears its
-- queue on every pass while the model is armed (tasks/msp/runtime.lua).
--
-- What is checked is the row itself: an action, or the button that opens a view. The options of a
-- `choice` that names a `view` are pressed in that view, which keeps its own rules -- the runtime
-- refuses a battery pick made while armed, and a battery profile's press queues nothing while
-- armed or before the connection is ready -- and its close has to work whatever the state.
local function refused(widget, entry, option)
  if option ~= nil and option.selectable == false then return true end
  if option ~= nil and entry.id == "battery_pick" and option ~= entry.close and Views
    and type(Views.status) == "function" and Views.status(widget, entry.id) == "busy" then
    return true
  end
  if option ~= nil and entry.view ~= nil then return false end
  if isEntryVisible(entry, widget) then return false end
  if Log and type(Log.emit) == "function" then
    Log.emit("rfsuite.widget", "entry '" .. tostring(entry.id) .. "' not run: it is not offered now", "warn")
  end
  widget.built = false
  widget.renderKey = nil
  return true
end

-- A button's press: the row's own work, if it has any, and then the action that follows it.
local function pressFor(widget, work, after)
  return function()
    if type(work) == "function" then work() end
    if Views and type(Views.navigate) == "function" then Views.navigate(widget, after) end
  end
end

-- Which entries the quick menu shows and in which order is the pilot's to choose, on
-- Settings > Dashboard > Quick Settings; the ids, the default and the stored form are in
-- quick_menu_order.lua, which that page reads as well.
local Order = requireModule("widgets/dashboard/quick_menu_order.lua")

-- The menus the widget offers, each a list of entry ids in the order they are drawn. The quick
-- menu is the one there is; a theme draws it, or takes entries out of it by id, and adds none.
-- `quick` here is the menu's default; what is drawn is the pilot's list (`quickIds` below).
M.LISTS = {
  quick = Order and Order.DEFAULT or {},
}

-- The quick menu's ids as the pilot has arranged them, read from the preferences of this pass,
-- so a save on the settings page reaches the next build of the menu with the widget's reload of
-- the preferences file.
local function quickIds(widget)
  if Order == nil then return M.LISTS.quick end
  local prefs = widget.preferences
  local dashboard = type(prefs) == "table" and prefs.dashboard or nil
  return Order.ids(type(dashboard) == "table" and dashboard[Order.KEY] or nil)
end

-- ---------------------------------------------------------------------------
-- Work that talks to the flight controller
-- ---------------------------------------------------------------------------

-- Queue a chain of messages, in order.
--
-- With a `report` -- only a theme's run hands one in; the menu's own presses never do, so what
-- they queue is exactly what they always queued -- the chain also says how it went: "busy" once
-- it is queued, "ok" when the LAST message has been answered, and "failed" when any message is
-- given up, whether out of retries, timed out or dropped by a clear of the queue. A message's own
-- reply and error handlers are kept and run first: they are wrapped, never replaced.
local function queueChain(queue, chain, report)
  local last = #chain
  if report ~= nil then
    for i = 1, last do
      local msg = chain[i]
      local ownError = msg.errorHandler
      msg.errorHandler = function(m, reason)
        if type(ownError) == "function" then ownError(m, reason) end
        report("failed")
      end
      if i == last then
        local ownReply = msg.processReply
        msg.processReply = function(m, buf)
          if type(ownReply) == "function" then ownReply(m, buf) end
          report("ok")
        end
      end
    end
  end
  for i = 1, last do queue:add(chain[i]) end
  if report ~= nil and last > 0 then report("busy") end
end

-- ---------------------------------------------------------------------------
-- The battery prompt's work
-- ---------------------------------------------------------------------------

-- A pick records a REQUEST on the widget and nothing else. The pick, the card write and the
-- flight controller write all happen in the runtime's job pass: an LVGL press callback runs
-- inside the firmware's event dispatch, where a card write or a queue turn is the one thing a
-- widget must not do. A pick that moves the board onto another profile says so at once, and the
-- job hands the same reporter the board's answer.
local function requestPick(widget, id, writes)
  -- `false` rather than nil for "no battery": nil is what the runtime reads as "no request at
  -- all", so the answer that clears the pack would never reach the job. Written out rather than
  -- as `(id == nil) and false or id`, which cannot produce `false` at all -- the `or` arm takes
  -- over the moment the `and` arm is false, and hands back the nil it was meant to replace.
  if id == nil then
    widget._batteryPickRequest = false
  else
    widget._batteryPickRequest = id
  end
  widget._batteryPickPress = nil
  if writes and Views and type(Views.reporter) == "function" then
    local report = Views.reporter(widget, "battery_pick")
    report("busy")
    -- What the answer closes is what stood when the pilot pressed: the job may run passes later.
    widget._batteryPickPress = { report = report, visit = Views.session(widget), top = Views.top(widget) }
  end
end

-- Closing without a pick ends the prompt for this connection. `pending` is the condition that
-- opens the picker on its own, so it is cleared here, or the picker would open again at once.
local function dismissBatteryPick(widget)
  local pick = widget.state and widget.state.batteryPick or nil
  if type(pick) == "table" then
    pick.dismissed = true
    pick.pending = false
  end
end

-- The board's profile for each pack, worked out once per battery configuration: asking for it logs
-- every exit, and the options are made afresh on every build of the picker.
local function resolvePacks(pick, config)
  local BatteryPick = requireModule("lib/battery_pick.lua")
  if type(BatteryPick) ~= "table" or type(BatteryPick.targetProfile) ~= "function" then return end
  local key = BatteryPick.configKey(config)
  if pick.resolvedFor == key and pick.resolvedPacks == pick.candidates then return end
  pick.resolvedFor, pick.resolvedPacks = key, pick.candidates
  for i = 1, #pick.candidates do
    local pack = pick.candidates[i]
    pack.targetProfile = BatteryPick.targetProfile(pack, config)
    pack.pickFacts = nil
  end
end

-- Whether a pick also moves the board onto the pack's profile (Settings of the Flight Log page).
local function picksSetProfile(widget)
  local BatteryPick = requireModule("lib/battery_pick.lua")
  if type(BatteryPick) ~= "table" or type(BatteryPick.settings) ~= "function" then return false end
  local _, setsProfile = BatteryPick.settings(widget.preferences)
  return setsProfile == true
end

-- The prompt's options: one per pack this model has, in registry order, and NO BATTERY last.
--
-- Every string an option carries is built here, once per call, so what draws them builds none.
-- `label` is the pack's name and `detail` the line under it. `details` holds that line and its
-- shortenings, longest first, for a surface that has less room, and `facts` the same facts one by
-- one; `pack` is the registry entry itself. A pack's option carries the pack's `id`, by which a run
-- is matched to it. NO BATTERY is marked `none`, because the picker reserves the foot row for it
-- before the packs are laid out, and it is the answer in force where no pack is.
--
-- Where a pick moves the board onto the pack's profile, a pack with no clear profile on this board
-- cannot be picked: `selectable` is false, it is still listed, and it says why. `writes` marks a
-- pick that sends something, whose press stays up until the board has answered (see the runtime's
-- apply step) and is stored only then.
local function batteryPickOptions(widget, t)
  local pick = widget.state and widget.state.batteryPick or nil
  local candidates = (type(pick) == "table" and type(pick.candidates) == "table") and pick.candidates or {}
  local selectedId = type(pick) == "table" and pick.selectedId or nil
  local config = widget.state and widget.state.battery_config or nil
  if #candidates > 0 then resolvePacks(pick, config) end
  local setsProfile = picksSetProfile(widget)

  local profileFmt = t("widgets.dashboard.battery_pick_profile", "Profile %d")
  local noProfile = t("widgets.dashboard.battery_pick_profile_none", "no profile")
  local cyclesFmt = t("widgets.dashboard.battery_pick_cycles", "%d cycles")
  -- What a pack's kept words were made in: another language makes them anew.
  local wordsKey = profileFmt .. noProfile .. cyclesFmt

  local options = {}
  for i = 1, #candidates do
    local pack = candidates[i]

    local nameText = pack.name
    if type(nameText) ~= "string" or nameText == "" then nameText = tostring(pack.id) end
    local target = pack.targetProfile
    local hasProfile = type(target) == "number"
    local selectable = (not setsProfile) or hasProfile

    -- What a pack says is made once and kept on the pack, while its language and its profile stand: the
    -- options are made afresh on every build, so a list of many packs would pay for these strings on each.
    local facts = pack.pickFacts
    if facts == nil or pack.pickKey ~= wordsKey or pack.pickTarget ~= target then
      facts = {}
      if type(pack.cap) == "number" and pack.cap > 0 then
        facts[#facts + 1] = string.format("%d mAh", math.floor(pack.cap))
      end
      if type(pack.cycles) == "number" then
        facts[#facts + 1] = string.format(cyclesFmt, math.floor(pack.cycles))
      end
      facts[#facts + 1] = hasProfile and string.format(profileFmt, target + 1) or noProfile
      pack.pickFacts, pack.pickKey, pack.pickTarget = facts, wordsKey, target
      pack.pickDetails, pack.pickDetailsOff = nil, nil
    end

    -- Short of room the profile goes first, and where the pack cannot be picked for want of one, the
    -- reason stays.
    local details
    if selectable then details = pack.pickDetails else details = pack.pickDetailsOff end
    if details == nil then
      details = { table.concat(facts, " - ") }
      if selectable then
        if #facts > 1 then details[#details + 1] = table.concat(facts, " - ", 1, #facts - 1) end
        if #facts > 2 then details[#details + 1] = facts[1] end
        pack.pickDetails = details
      else
        if #facts > 2 then details[#details + 1] = facts[1] .. " - " .. facts[#facts] end
        if #facts > 1 then details[#details + 1] = facts[#facts] end
        pack.pickDetailsOff = details
      end
    end

    local writes = setsProfile and hasProfile and target ~= pick.boardProfile
    local id = pack.id
    options[i] = {
      id = id,
      label = nameText,
      detail = details[1],
      details = details,
      facts = facts,
      current = (selectedId ~= nil and id == selectedId),
      selectable = selectable,
      writes = writes,
      pack = pack,
      press = function() requestPick(widget, id, writes) end,
      after = writes and "none" or "done"
    }
  end

  -- "No battery": the honest answer for a flight nobody wants in the log against a pack, and
  -- the one that clears a choice carried over from the previous connection.
  options[#options + 1] = {
    label = t("widgets.dashboard.battery_pick_none", "NO BATTERY"),
    none = true,
    current = selectedId == nil,
    press = function() requestPick(widget, nil) end,
    after = "done"
  }
  return options
end

-- The entries, one builder each, in the quick menu's default order. A caller that wants one
-- entry -- the battery picker wants its own record, and a theme one entry by its id -- builds that
-- one and not all of them, their translations and closures included.
local BUILD = {}

-- How full the blackbox is, as the flight controller last reported it: the summary read on
-- connecting, and again after every erase. It is the row's `info`, and it is also what the
-- erase's question is worded from: how much is about to be lost is the one thing a pilot cannot
-- recover by looking afterwards.
local function blackboxFill()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  local stats = session and session.dataflash or nil
  if type(stats) ~= "table" then return nil end
  return { used = stats.used, total = stats.total }
end

function BUILD.erase_blackbox(widget, t)
  -- The erase is irreversible and sits one tap from the quick menu, so the entry carries the
  -- question and `M.run` holds the press behind it: nothing is queued, and full screen is not
  -- left, until the pilot has agreed. `detail` is omitted where no summary has been read, so the
  -- question is the same shape with or without a number in it.
  --
  -- Offered only while the model is disarmed: the MSP runtime drops every queued message while
  -- it is armed, so an erase pressed in the air would never be sent.
  local confirm = {
    title = t("widgets.dashboard.erase_blackbox_confirm_title", "ERASE BLACKBOX"),
    message = t("widgets.dashboard.erase_blackbox_confirm_message",
      "Erase the flight controller's blackbox? This cannot be undone."),
    confirmLabel = t("widgets.dashboard.erase_blackbox_confirm_yes", "ERASE"),
    cancelLabel = t("widgets.dashboard.erase_blackbox_confirm_no", "CANCEL"),
  }
  local fill = blackboxFill()
  if fill and type(fill.used) == "number" and type(fill.total) == "number" and fill.total > 0 then
    confirm.detail = string.format(
      t("widgets.dashboard.erase_blackbox_confirm_used", "%d%% used"),
      math.floor(fill.used / fill.total * 100 + 0.5))
  end

  return {
    id = "erase_blackbox",
    kind = "action",
    title = t("widgets.dashboard.erase_blackbox", "ERASE BLACKBOX"),
    visibleWhen = "connectionReadyDisarmed",
    confirm = confirm,
    press = function(report)
         local mspModule = requireModule("tasks/msp/runtime.lua")
         if mspModule and mspModule.getState then
            local mState = mspModule.getState()
            if mState and mState.queue then
               local eraseApi = requireModule("tasks/msp/api/dataflash_erase.lua")
               local summaryApi = requireModule("tasks/msp/api/dataflash_summary.lua")

               if eraseApi and summaryApi then
                 queueChain(mState.queue, {
                   {
                     command = eraseApi.writeCommand,
                     payload = eraseApi.buildWritePayload({}),
                     simulatorResponse = {},
                     isWrite = true,
                     timeout = 10.0,
                   },
                   {
                     command = summaryApi.command,
                     simulatorResponse = summaryApi.simulatorResponse,
                     processReply = function(_, buf)
                       local stats = summaryApi.parse(buf)
                       if stats then
                         if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
                           _G.rfsuite.session.dataflash = stats
                         end
                       end
                     end
                   }
                 }, report)
               end
            end
         end
    end,
    info = blackboxFill,
    after = "done"
  }
end

-- The tuning surface is not a view on the stack: it takes fullscreen ahead of every view while
-- its own flag is up, so the press raises the flag and nothing follows it.
function BUILD.inflight_tuning(widget, t)
  return {
    id = "inflight_tuning",
    kind = "action",
    title = t("widgets.dashboard.inflight_open", "IN-FLIGHT TUNING"),
    visibleWhen = "previewInflightTuning",
    existsWhen = "inflightSwitchedOn",
    press = function()
        widget.inflightFullscreen = true
        widget.built = false
        widget.renderKey = nil
    end,
    after = "none"
  }
end

-- The battery prompt, as one record. Its options are the picks -- one per pack, then NO
-- BATTERY -- and `close` ends the prompt for this connection without a pick; the picker view
-- (battery_pick_menu.lua) draws this record, so what a pick does is written down once, here.
--
-- In this menu the record is the BATTERY row: a `choice` that names a `view` is drawn as the
-- single button that opens that view, which is its own `after`. The prompt comes up on its own
-- once per connection; this is the way back to it after it has been answered or closed. It
-- stays full screen, the picker taking the menu's place.
--
-- `options` needs no argument: the widget is the one this list was made for, so a caller that
-- holds only the record can still ask for the options as they stand now.
function BUILD.battery_pick(widget, t)
  return {
    id = "battery_pick",
    kind = "choice",
    view = "battery_pick",
    title = t("widgets.dashboard.battery_pick_open", "BATTERY"),
    visibleWhen = "batteryPickHasPacks",
    existsWhen = "batteryPickKnowsPacks",
    after = "openView:battery_pick",
    writesProfile = picksSetProfile(widget),
    options = function() return batteryPickOptions(widget, t) end,
    close = {
      press = function() dismissBatteryPick(widget) end,
      after = "done"
    }
  }
end

-- The suite's tool, run inside the widget until it is closed (widgets/dashboard/tool_host.lua).
-- The whole effect is the action, so the row has no press of its own.
function BUILD.tool(widget, t)
  return {
    id = "tool",
    kind = "action",
    title = t("widgets.dashboard.tool_open", "MAIN MENU"),
    visibleWhen = "modelDisarmed",
    after = "openTool"
  }
end

-- The suite's tool, opened on its Flight Log page rather than on its menu, and closed again by
-- the back key there. Offered only while the model is disarmed; not in the default list, so it is
-- in the menu only where the pilot puts it.
function BUILD.flight_log(widget, t)
  return {
    id = "flight_log",
    kind = "action",
    title = t("widgets.dashboard.flight_log_open", "FLIGHT LOG"),
    visibleWhen = "flightLogOffered",
    after = "openTool:tools_flight_log_page"
  }
end

-- The facts a battery profile carries beside its capacity, as the flight controller reported them:
-- its cell count and its warning voltage per cell, in centivolts. Only firmware that reports
-- them per profile has them (tasks/msp/api/battery_config.lua, `hasProfileCells`); elsewhere both
-- are nil, and what is shown is the capacity alone.
local function profileFacts(config, i)
  if type(config) ~= "table" or config.hasProfileCells ~= true then return nil, nil end
  local cells = tonumber(config["batteryCellCount_" .. i])
  local warn = tonumber(config["vbatwarningcellvoltage_" .. i])
  if cells ~= nil and cells <= 0 then cells = nil end
  if warn ~= nil and warn <= 0 then warn = nil end
  return cells, warn
end

-- The separator between the facts of a profile. Plain ASCII: the radio's LVGL fonts carry ASCII,
-- Latin-1 letters and a few symbols only, and draw a character outside them as nothing.
local FACT_SEPARATOR = " / "

-- The facts of one profile as text, from the parts that are present, in the order cells,
-- capacity, warning voltage: `6S`, `2000mAh`, `Warn 3.50V`.
local function joinFacts(parts)
  return table.concat(parts, FACT_SEPARATOR)
end

local function cellsText(cells) return string.format("%dS", math.floor(cells)) end
local function capacityText(cap) return string.format("%dmAh", math.floor(cap)) end
local function warnText(warnWord, warn) return string.format("%s %.2fV", warnWord, warn / 100) end

-- BATTERY PROFILE: a choice whose options are pressed on a page of their own (the view
-- `battery_profile`, battery_profile_menu.lua), so in a menu it is the one row that opens that
-- page. It is not one of the pilot's entries: the menu draws it under them, always in the same
-- place (M.build). Offered while the connection is ready, the model is disarmed and the board has reported a profile
-- (`batteryProfileOffered`).
--
-- A profile write pressed in the air is dropped with the rest of the MSP queue, and the options of
-- a choice that has a view are not refused by the menu's own test (`refused` above): the page
-- stays up when the model arms. So each option's press asks the arm state itself and queues
-- nothing while the model is armed.
--
-- Every string is built here, once per call. An option carries the capacity as `label` and, where
-- the board reports them, the cell count and the warning voltage as `detail`. `values(w)` answers
-- the profile in force as up to three texts, longest first, each a shortening of the one before
-- -- all its facts, then without the warning voltage, then the capacity alone -- for a row that
-- shows the longest one that fits; an empty list where no profile is known to be in force.
function BUILD.battery_profile(widget, t)
  local warnWord = t("widgets.dashboard.battery_profile_warn", "Warn")
  return {
    id = "battery_profile",
    kind = "choice",
    view = "battery_profile",
    title = t("widgets.dashboard.battery_profile", "BATTERY PROFILE"),
    visibleWhen = "batteryProfileOffered",
    existsWhen = "batteryProfileExists",
    after = "openView:battery_profile",
    -- What a page of profiles says while the model is armed and nothing on it can be pressed.
    armedNote = t("widgets.dashboard.battery_profile_armed", "CHANGEABLE ONLY WHEN DISARMED"),
    -- And what it says before the connection is ready, when a press queues nothing either.
    notReadyNote = t("widgets.dashboard.battery_profile_not_ready", "CHANGEABLE ONLY WHEN CONNECTED"),
    -- One option per capacity the flight controller carries, resolved when the row is drawn
    -- rather than when the list is made, so an entry stays a description of what it offers. The
    -- widget is the one this list was made for where the caller passes none.
    options = function(w)
      w = w or widget
      local options = {}
      local state = w and w.state or {}
      local config = state.battery_config
      if config then
        for i=0,5 do
          local cap = config["batteryCapacity_"..i] or 0
          if cap > 0 then
            local cells, warn = profileFacts(config, i)
            local detailParts = {}
            if cells ~= nil then detailParts[#detailParts + 1] = cellsText(cells) end
            if warn ~= nil then detailParts[#detailParts + 1] = warnText(warnWord, warn) end
            options[#options+1] = {
              -- The profile the pilot reads, 1 to 6, by which a run is matched to this option.
              id = i + 1,
              label = tostring(cap).." mAh",
              detail = (#detailParts > 0) and joinFacts(detailParts) or nil,
              -- The profile in force: the battery_profile sensor (BatP) is 1-based.
              current = (state.batteryProfile == (i + 1)),
              press = function(report)
                -- The page can stay up when the link drops, and a key can open it on the
                -- connection screen: queue nothing until the connection is ready, as while armed.
                if w.connectionReady ~= true or (w.state and w.state.armed == true) then return end
                local mspModule = requireModule("tasks/msp/runtime.lua")
                if mspModule and mspModule.getState then
                  local mState = mspModule.getState()
                  if mState and mState.queue then
                     local chain = {}
                     -- 1. Set Battery Profile
                     local api = requireModule("tasks/msp/api/battery_profile.lua")
                     if api and type(api.buildWritePayload) == "function" then
                       chain[#chain+1] = {
                          command = api.writeCommand,
                          payload = api.buildWritePayload({ batteryProfile = i }),
                          simulatorResponse = {}
                       }
                       -- The battery prompt keeps the profile the board reported on connecting
                       -- and skips a pick that matches it. After this write that report is
                       -- stale, so it is dropped and the next pick writes.
                       local batteryPick = w.state and w.state.batteryPick or nil
                       if type(batteryPick) == "table" then batteryPick.boardProfile = nil end
                     end
                     -- 2. Save to EEPROM so the FC applies and broadcasts the change
                     local eepromApi = requireModule("tasks/msp/api/eeprom_write.lua")
                     if eepromApi and type(eepromApi.buildWritePayload) == "function" then
                       chain[#chain+1] = {
                          command = eepromApi.writeCommand,
                          payload = eepromApi.buildWritePayload({}),
                          simulatorResponse = {},
                          isWrite = true,
                       }
                     end
                     queueChain(mState.queue, chain, report)
                  end
                end
              end,
              -- The page stays up, so the pilot sees how the write went.
              after = "none"
            }
          end
        end
      end
      return options
    end,
    values = function(w)
      w = w or widget
      local state = w and w.state or {}
      local config = state.battery_config
      local profile = tonumber(state.batteryProfile)
      if type(config) ~= "table" or profile == nil then return {} end
      local i = math.floor(profile) - 1
      local cap = tonumber(config["batteryCapacity_" .. i])
      if cap == nil or cap <= 0 then return {} end
      local cells, warn = profileFacts(config, i)
      local capPart = capacityText(cap)
      local out = {}
      if cells ~= nil and warn ~= nil then
        out[#out + 1] = joinFacts({ cellsText(cells), capPart, warnText(warnWord, warn) })
      elseif warn ~= nil then
        out[#out + 1] = joinFacts({ capPart, warnText(warnWord, warn) })
      end
      if cells ~= nil then out[#out + 1] = joinFacts({ cellsText(cells), capPart }) end
      out[#out + 1] = capPart
      return out
    end
  }
end

--- What the menu offers, as a list rather than as drawing code.
--
-- One entry per button, in the order they are drawn, carrying the manifest's own vocabulary:
-- `id`, `title`, `kind`, `visibleWhen` and `press`. `kind` says what the entry is -- `action` is
-- one press, `choice` a set of options. Every `choice` names in `view` the page its options are
-- pressed on, so in the menu it is the single button that opens that view.
--
-- `press` does the row's work and nothing else. What follows it -- leaving fullscreen, opening
-- another view, or nothing -- is the row's `after`, an action views.lua performs; an option of a
-- `choice` carries its own. A row whose press must be agreed to first also carries a `confirm`,
-- the question `M.run` raises before the work: ERASE BLACKBOX is the one, and it is what keeps a
-- mis-tap on an irreversible action from meaning anything.
--
-- The title is resolved here, and it is resolved from a complete literal key: the translation
-- precompiler rewrites what it can read, and a key assembled from parts ships the English
-- fallback in every language with nothing saying so.
--
-- The rows are the pilot's: the entries the pilot has put in the quick menu, in that order
-- (quickIds).
-- Whether a row is drawn is still its `visibleWhen`, asked on top of that choice.
function M.entries(widget)
  local t = translator(widget)
  local list = {}
  local ids = quickIds(widget)
  for i = 1, #ids do
    local build = BUILD[ids[i]]
    if build ~= nil then list[#list + 1] = build(widget, t) end
  end
  return list
end

--- The entry `id` of this widget's list, or nil. Only that entry is built.
function M.entry(widget, id)
  local build = BUILD[id]
  if build == nil then return nil end
  return build(widget, translator(widget))
end

--- The entries of the named list in `M.LISTS`, in its order; an empty list for an unknown name.
--- `quick` is the pilot's list, the one the quick menu draws.
function M.list(widget, name)
  if name == "quick" then return M.entries(widget) end
  local ids = M.LISTS[name]
  local out = {}
  if type(ids) ~= "table" then return out end
  local t = translator(widget)
  for i = 1, #ids do
    local build = BUILD[ids[i]]
    if build ~= nil then out[#out+1] = build(widget, t) end
  end
  return out
end

--- The menu's own record, and its own option, for what a caller hands in; nil for either where
--- the menu has none.
--
-- A caller's tables are never run: they only name what is meant. The entry is found by its `id`;
-- an option by its `id` among the record's options as they stand now -- a pack's id, a battery
-- profile's number -- or, for NO BATTERY, by `none`, and the record's `close` by being the
-- `close` of the table handed in. Matching by identity would not do: a record's options are made
-- anew on every call, so the table a caller drew is never one of them by the time it is run.
function M.resolve(widget, entry, option)
  if type(entry) ~= "table" then return nil end
  local core = M.entry(widget, entry.id)
  if core == nil then return nil end
  if option == nil then return core, nil end
  if type(option) ~= "table" then return nil end
  if core.close ~= nil and option == entry.close then return core, core.close end
  local options = core.options
  if type(options) == "function" then options = options(widget) end
  if type(options) ~= "table" then return nil end
  for i = 1, #options do
    local candidate = options[i]
    if option.none == true then
      if candidate.none == true then return core, candidate end
    elseif candidate.id ~= nil and candidate.id == option.id then
      return core, candidate
    end
  end
  return nil
end

--- The menu's own records for a list a caller hands in, in its order: each item replaced by the
--- record of its `id`, and an item whose id the menu does not have left out.
--
-- Every entry the menu can build counts, not only the ones the pilot has put in the quick menu:
-- a theme that names an entry asks for that entry, as `M.entry` answers it.
function M.coreList(widget, list)
  local out = {}
  if type(list) ~= "table" then return out end
  local t = translator(widget)
  for i = 1, #list do
    local item = list[i]
    local build = type(item) == "table" and BUILD[item.id] or nil
    if build ~= nil then out[#out+1] = build(widget, t) end
  end
  return out
end

--- Whether the entry is offered now: the test the menu makes for each of its rows.
function M.visible(widget, entry)
  return isEntryVisible(entry, widget)
end

-- The work a press does and the action that follows it, in that order. Split out of `run` so
-- that a press which must be confirmed can be performed from the answer instead of here. The
-- row is asked again here because an answer can come after the row has stopped being offered.
local function perform(widget, entry, option, after, report)
  if refused(widget, entry, option) then return end
  local source = option or entry
  if type(source.press) == "function" then source.press(report) end
  if after == nil then after = source.after end
  if Views and type(Views.navigate) == "function" then Views.navigate(widget, after) end
end

--- The work and what follows it, for a surface that has already had the pilot's answer to the
--- entry's `confirm` itself. Everything else goes through `M.run`.
M.perform = perform

--- Run an entry, or one of its options: the work, then the action that follows it. This is the
--- one place both happen, for the menu's own buttons, the picker's and a theme's alike.
--
-- The work is the option's when an option is given and the entry's otherwise; so is the action,
-- unless `after` names another one. `report` is handed to the work, which tells it how the
-- messages it queued fared (see queueChain); the menu's own buttons pass none.
--
-- An entry that carries `confirm` is a press that must be agreed to first: its work is NOT
-- performed here but handed to the confirmation view (views.confirm), which runs it from the
-- pilot's answer. A question that cannot be raised leaves the press unperformed -- refusing
-- loses nothing where a mis-tap would lose the logs.
--
-- A `choice` entry's own `confirm` guards every option it runs; an option that carries one is
-- held by its own question, which is preferred where both carry one.
--
-- A row the menu does not offer now -- its `visibleWhen` does not hold -- is refused, here and
-- again when a question is answered (see `refused`): a surface built before the change still
-- draws it, and a theme can hand in any record.
--
-- This runs whatever it is handed: the `press` of the table it is given, with no check of where
-- that table came from. A caller resolves first and passes only the menu's own records -- the
-- menu's buttons and the picker take theirs from M.entries / M.entry, and anything a theme hands
-- in goes through M.resolve (as ctx.run in views.lua does). A caller that skips that step lets a
-- theme put work of its own behind one of the menu's entries.
function M.run(widget, entry, option, after, report)
  if refused(widget, entry, option) then return end
  local source = option or entry
  if after == nil then after = source.after end
  local confirm = (option and option.confirm) or entry.confirm
  if type(confirm) == "table" then
    if Views and type(Views.confirm) == "function" then
      Views.confirm(widget, confirm, function() perform(widget, entry, option, after, report) end)
    end
    return
  end
  perform(widget, entry, option, after, report)
end

-- The places the pilot's entries are laid out on: a fixed raster of six, in two columns where the
-- zone is wide enough and in one where it is not. The raster does not shrink or grow with the
-- number of entries shown, so a button keeps its size and its place whatever is hidden at the
-- moment; places with nothing in them stay empty. Under the raster, always on the row after its
-- last, is the BATTERY PROFILE row, the width of the zone. This is the one layout: a theme that
-- restyles the menu hands in its look (`style` at M.build) and the numbers stay here.
M.PLACES = 6
M.TWO_COLUMNS_FROM = 300

-- The mark after a row's value that says the row opens a page. ASCII, for the reason given
-- at FACT_SEPARATOR.
M.OPENS_MARK = " >"

-- The width `text` takes in `font`, or nil where the firmware cannot say.
local function textWidth(text, font)
  if lcd and type(lcd.sizeText) == "function" then
    local ok, w = pcall(lcd.sizeText, text, font)
    if ok and type(w) == "number" then return w end
  end
  return nil
end

--- The longest of `texts` -- longest first, each a shortening of the one before -- that fits
--- `maxW` in `font`; the last where none fits, and the first where nothing can be measured.
function M.fitFirst(texts, font, maxW, measure)
  measure = measure or textWidth
  if type(texts) ~= "table" or #texts == 0 then return nil end
  for i = 1, #texts do
    local w = measure(texts[i], font)
    if w == nil then return texts[1] end
    if w <= maxW then return texts[i] end
  end
  return texts[#texts]
end

--- What moves the menu: the profile in force, which the BATTERY PROFILE row names, and the board's
--- battery configuration arriving or going, which decides whether the row is there. A state alone
--- is what a theme's view has to key on, so a theme asks this rather than writing it out again.
function M.stateKey(state)
  if state == nil then return "" end
  return tostring(state.batteryProfile) .. (state.battery_config ~= nil and "|c" or "|")
end

--- How full the blackbox of `entry` is as a whole percentage, or nil where nothing has been read.
function M.fillPercent(entry)
  local info = type(entry.info) == "function" and entry.info() or nil
  if type(info) ~= "table" then return nil end
  local used, total = tonumber(info.used), tonumber(info.total)
  if used == nil or total == nil or total <= 0 then return nil end
  return math.floor(used * 100 / total + 0.5)
end

-- Which style the pilot has chosen for the widget's own menu.
local function menuStyle(widget)
  return Look and Look.style(widget) or "card"
end

local function rollModule()
  local Roll = requireModule("widgets/dashboard/menu_roll.lua")
  if type(Roll) == "table" and type(Roll.build) == "function" then return Roll end
  return nil
end

--- How the last pick's write went, in the words the picker shows; "" while there is nothing to say.
function M.pickStatusText(widget, t)
  local status = Views and type(Views.status) == "function" and Views.status(widget, "battery_pick") or nil
  if status == "busy" then return t("widgets.dashboard.battery_profile_busy", "SENDING...") end
  if status == "failed" then return t("widgets.dashboard.battery_profile_failed", "NOT SAVED") end
  return ""
end

--- Rebuilt when `stateKey` moves. The rolling style also when the model arms or disarms, or the
--- connection comes or goes, which decide what its lists hold, and when it asks to be built again.
function M.renderKey(widget)
  local state = widget and widget.state or nil
  if state == nil then return "" end
  local key = M.stateKey(state)
  if menuStyle(widget) == "rotary" then
    local Roll = rollModule()
    if Roll then
      -- The flight controller's own answer as well as the dashboard's readiness: a row of the suite's
      -- menu goes by the first.
      local session = _G.rfsuite and _G.rfsuite.session or nil
      key = key .. (state.armed == true and "|a" or "|") .. (state.connectionReady == true and "r" or "")
        .. (session ~= nil and session.fblConnected == true and "f" or "")
        .. "|" .. Roll.renderKey(widget)
    end
  end
  return key
end

-- The card style's drawing, in the colours of the scheme the pilot has chosen (menu_look.lua).
--
-- `frame(children)` draws the background and the header with its close box and answers where the
-- content goes; `button` draws one entry, `valueRow` the BATTERY PROFILE row, and `fillText` words
-- the blackbox's fill under ERASE BLACKBOX.
local function cardStyle(widget, t)
  local p = Look.profile(widget.zone.h)
  local colors = Look.colors(widget)
  local titleFont, fontH, paddingX, btnTextOffY = p.titleFont, p.fontH, p.paddingX, p.btnTextOffY
  local isLarge, smallH = p.isLarge, p.smallH

  return {
    frame = function(children)
      local _, _, top = Look.frame(children, widget, t("widgets.dashboard.quick_settings", "QUICK SETTINGS"),
        pressFor(widget, nil, "done"))
      local dW, dH = widget.zone.w, widget.zone.h
      return {
        x = paddingX, w = dW - paddingX * 2, zoneW = dW,
        top = top, bottom = dH - p.gapY,
        gapX = paddingX, gapY = p.gapY,
      }
    end,
    button = function(children, x, y, w, h, name, sub, press)
      children[#children+1] = {
        type = "button", x=x, y=y, w=w, h=h, color=colors.fill, press = press
      }
      if type(sub) == "string" and sub ~= "" then
        local top = y + math.floor((h - fontH - smallH)/2) + btnTextOffY
        children[#children+1] = {
          type = "label", x=x, y=top, w=w, text=name, color=colors.text, align=CENTER, font=titleFont
        }
        children[#children+1] = {
          type = "label", x=x, y=top + fontH + (isLarge and 8 or 2), w=w, text=sub, color=colors.muted, align=CENTER, font=SMLSIZE
        }
      else
        children[#children+1] = {
          type = "label", x=x, y=y + math.floor((h - fontH)/2) + btnTextOffY, w=w,
          text=name, color=colors.text, align=CENTER, font=titleFont
        }
      end
    end,
    valueRow = function(children, x, y, w, h, name, values, press)
      local textY = y + math.floor((h - fontH)/2) + btnTextOffY
      children[#children+1] = {
        type = "button", x=x, y=y, w=w, h=h, color=colors.fill, press = press
      }
      local titleW = textWidth(name, titleFont) or math.floor(w / 3)
      children[#children+1] = {
        type = "label", x=x + paddingX, y=textY, w=titleW + paddingX,
        text=name, color=colors.text, align=LEFT, font=titleFont
      }
      local valueW = w - titleW - 4 * paddingX
      local marks = {}
      for i = 1, #values do marks[i] = values[i] .. M.OPENS_MARK end
      local value = M.fitFirst(marks, titleFont, valueW) or M.OPENS_MARK
      children[#children+1] = {
        type = "label", x=x + w - paddingX - valueW, y=textY, w=valueW,
        text=value, color=colors.text, align=RIGHT, font=titleFont
      }
    end,
    fillText = function(percent)
      return string.format(t("widgets.dashboard.erase_blackbox_confirm_used", "%d%% used"), percent)
    end,
  }
end

--- Draw the menu.
--
-- `entries` is the list to draw; omitted, the menu draws its own, which is what the runtime
-- asks for. Taking the list as an argument is the point of the split: the same drawing code
-- can serve a list assembled somewhere else.
--
-- Every entry is one button on a place of the raster (M.PLACES), in the order of the list; an
-- entry that is not offered now takes no place, and an entry past the last place is not drawn.
-- BATTERY PROFILE is drawn on its own row under the raster and never on a place, so a list that
-- names it does not draw it twice.
function M.build(children, widget, entries)
  local given = entries
  entries = entries or M.entries(widget)
  local t = translator(widget)

  if menuStyle(widget) == "rotary" and Look ~= nil then
    local Roll = rollModule()
    local Sources = Roll and requireModule("widgets/dashboard/menu_roll_sources.lua") or nil
    if Roll == nil or type(Sources) ~= "table" then
      if Log and type(Log.emit) == "function" then
        Log.emit("rfsuite.widget", "rotary menu did not load, drawing the card", "warn")
      end
    else
      -- The roll keeps its scene when the wheel rests and asks for the entries afresh then, as a build would.
      local function renew(list)
        local source = Sources.quick(widget, list or given or M.entries(widget), t)
        source.renew = renew
        return source
      end
      Roll.build(children, widget, renew(entries), Look.colors(widget))
      return
    end
  end

  -- Drawn as buttons: a rolling menu from before, a theme's look registered since or the pilot's
  -- choice changed, has stopped answering the wheel.
  if Views and type(Views.dropRoll) == "function" then Views.dropRoll(widget, Views.DEFAULT_VIEW) end

  local style = cardStyle(widget, t)
  local frame = style.frame(children)
  if frame == nil then return end

  local function run(entry) M.run(widget, entry) end

  -- The raster, then the BATTERY PROFILE row: rows of one height, the raster's and the battery
  -- row's alike.
  local contentY, bottom = frame.top, frame.bottom
  local gapX, gapY = frame.gapX, frame.gapY
  local cols = (frame.zoneW >= M.TWO_COLUMNS_FROM) and 2 or 1
  local rows = math.ceil(M.PLACES / cols)
  local rowH = math.floor((bottom - contentY - rows * gapY) / (rows + 1))
  local cellW = math.floor((frame.w - (cols - 1) * gapX) / cols)

  local place = 0
  for _, entry in ipairs(entries) do
    if entry.id ~= "battery_profile" and isEntryVisible(entry, widget) then
      place = place + 1
      if place > M.PLACES then break end
      local bx = frame.x + ((place - 1) % cols) * (cellW + gapX)
      local by = contentY + math.floor((place - 1) / cols) * (rowH + gapY)
      local sub = nil
      local percent = M.fillPercent(entry)
      if percent ~= nil then sub = style.fillText(percent) end
      style.button(children, bx, by, cellW, rowH, entry.title or "", sub, function() run(entry) end)
    end
  end

  -- BATTERY PROFILE, on the row after the raster's last: its title on the left, the profile in
  -- force on the right, as long as it fits, and the mark that it opens a page.
  local profile = M.entry(widget, "battery_profile")
  if profile ~= nil and isEntryVisible(profile, widget) then
    local values = type(profile.values) == "function" and profile.values(widget) or {}
    style.valueRow(children, frame.x, contentY + rows * (rowH + gapY), frame.w, rowH, profile.title or "", values,
      function() run(profile) end)
  end
end

return M
