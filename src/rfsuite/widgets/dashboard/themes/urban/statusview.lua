-- The status view (init.lua registers it as `urban_status`): the arm state and what stands in its
-- way, the governor, the throttle and the speed controller, over the widget's history of what
-- changed on the craft.
--
-- Opened in full screen by a tap on the flight view's governor and status rows, or by a key the
-- pilot sets to it on the Keys settings page.
--
-- Everything it shows is already on the host's state: the arm state and the arming-disable flags,
-- the governor and the throttle, the speed controller's live verdict (`esc_status_live`, which the
-- flight view declares whatever its rows show, layout.lua ALWAYS_DECLARED), and the event history
-- (`state.eventLog`, widgets/dashboard/runtime.lua, noteEvent). So the view names no sources of its
-- own and is never rebuilt for a reading: every figure is a closure, and a new history entry
-- reaches the rows without a rebuild.
--
-- The history shows the newest entries the page holds, newest at the top; older ones are kept by
-- the host and are not shown here.

local function requireModule(path)
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require(path)
    if type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(_G.rfsuite.paths.core .. "/" .. path, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local K = requireModule("widgets/dashboard/themes/urban/viewkit.lua") or {}

local M = {}

-- The governor states by the flight controller's own index, as the flight view names them
-- (common.lua, `gov_state_<n>`), looked up once here so a history row concatenates no key.
local GOV_NAMES = nil

local function governorNames(T)
  if GOV_NAMES ~= nil then return GOV_NAMES end
  GOV_NAMES = {}
  for i = 0, 9 do GOV_NAMES[i] = T["gov_state_" .. i] end
  return GOV_NAMES
end

-- How many characters fit a box of `w` px in `font`, measured against a word of capitals as the
-- flight view's status line measures it (layout.lua, L.statusPanel), and a cut to that many made
-- once per text rather than once per frame. The cut is made in the format path because a closure
-- may make no firmware call.
local CAPS_SAMPLE = "BOOTGRACE"

local function fitter(UD, font, w)
  local cap = math.floor(w * #CAPS_SAMPLE / math.max(1, UD.textWidth(font, CAPS_SAMPLE)))
  local lastRaw, lastCut = nil, ""
  return function(raw)
    if cap <= 4 or #raw <= cap then return raw end
    if raw ~= lastRaw then
      lastRaw = raw
      lastCut = UD.cutUtf8(raw, cap - 1) .. "."
    end
    return lastCut
  end
end

-- One history entry in words and its colour. The host gives a kind and a value; the words are
-- this theme's, so they follow the package's language. The speed controller's verdict arrives in
-- words already, and the row puts the column's name before it.
local function describe(e, T, C, gov)
  local kind = e.kind
  local text
  if kind == "armed" then
    text = T.armed
  elseif kind == "disarmed" then
    text = T.disarmed
  elseif kind == "connected" then
    text = T.connected
  elseif kind == "disconnected" then
    text = T.state_offline
  elseif kind == "governor" then
    text = T.governor .. ": " .. ((type(e.value) == "number" and gov[e.value]) or T.gov_unknown)
  elseif kind == "esc" then
    -- Named like the governor's rows: a controller the decoder knows no family of says only
    -- "OK", which on a line of its own would not say whose verdict it is.
    text = T.esc .. ": " .. tostring(e.text or "")
  else
    text = tostring(kind)
  end
  local level = tonumber(e.level) or 1
  local color = C.text
  if level >= 3 then
    color = C.crit
  elseif level == 2 then
    color = C.warn
  end
  return text, color
end

function M.build(children, zone, state, ctx)
  if type(K.begin) ~= "function" then return children end
  state = state or {}
  local g = K.begin(zone, state)
  if g == nil then return children end
  local UD, C, T = K.UD, K.C, K.T

  local closePress = nil
  if type(ctx) == "table" and type(ctx.action) == "function" then
    closePress = function() ctx.action("closeView") end
  end
  local top = K.header(children, g, T.view_status, closePress, UD.modelName(state))

  local x, w = g.x + g.pad, g.w - 2 * g.pad
  local bottom = g.y + g.h - g.pad
  local f = K.rowFonts(g)
  local tp = g.textPad

  -- ---------------------------------------------------------------- the two cards
  -- The arm card a third of the width less a little, the other card the rest, both as tall as the
  -- arm word and the line under it need. The arm word takes the face one step above the flight
  -- view's where it fits, so it is the largest thing on the page after the title.
  local gap = g.gap
  local armW = math.floor(w * 0.30)
  local infoX = x + armW + gap
  local infoW = w - armW - gap
  local armInner = armW - 2 * tp

  local armSample = T.disarmed_caps
  if #T.armed_caps > #armSample then armSample = T.armed_caps end
  local armFont = UD.selectFont(f.nameH * 2, armInner, armSample, K.stepFace(g.font, 1))
  local armH = UD.measure(armFont, armSample)
  local cardH = tp + armH + f.subH + tp

  UD.rect(children, x, top, armW, cardH, C.track, false, math.max(4, math.floor(cardH * 0.12)), 1)
  UD.rect(children, infoX, top, infoW, cardH, C.track, false, math.max(4, math.floor(cardH * 0.12)), 1)

  -- The arm word, in the colours the bottom bar gives it: the very closure the flight view draws its
  -- arm state with (common.lua, M.armedColor), so the pilot's *Arm state colours* on the Look page
  -- (`arm_colors`) colour it here as there, whichever way round they are set. Without a flight
  -- controller the state is not known, so it says nothing and the line under it says why.
  local armColor = UD.armedColor(state)
  UD.label(children, x + tp, top + tp, armInner, armH, function()
    if state.rfConnected ~= true then return "-" end
    if state.armed == true then return T.armed_caps end
    return T.disarmed_caps
  end, armFont, armColor, CENTER)

  -- The line under it: why the model cannot be armed, in the bottom bar's readable names and its
  -- warning colour, joined and cut to the card once per change of the flags; "Ready to arm" while
  -- nothing stands in the way; nothing while armed.
  local reasons = UD.armDisableList(state)
  local fitReason = fitter(UD, f.sub, armInner)
  local lastList, joined = nil, nil
  local function reasonText()
    local list = reasons()
    if list ~= lastList then
      lastList = list
      joined = list and fitReason(table.concat(list, ", ")) or nil
    end
    return joined
  end
  UD.label(children, x + tp, top + tp + armH, armInner, f.subH, function()
    if state.rfConnected ~= true then return T.no_fc end
    if state.armed == true then return "" end
    return reasonText() or T.ready_to_arm
  end, f.sub, function()
    if state.rfConnected ~= true then return C.disabled end
    if state.armed == true then return C.text end
    if reasonText() ~= nil then return C.warning end
    return C.ok
  end, CENTER)

  -- Governor, throttle and speed controller: the name over the reading, left, centre and right.
  -- The readings share one face, the largest that fits each column's widest sample, so the three
  -- read as one row.
  local colX = infoX + tp
  local colW = infoW - 2 * tp
  local govW = math.floor(colW * 0.34)
  local thrW = math.floor(colW * 0.24)
  local escW = colW - govW - thrW
  local valueRoom = cardH - 2 * tp - f.subH
  local govSample = UD.governorSample()
  local escSample = "YGE ESC OK"
  local valueFont, valueH = nil, nil
  local samples = { { govW, govSample }, { thrW, "100%" }, { escW, escSample } }
  for i = 1, #samples do
    local font = UD.selectFont(valueRoom, samples[i][1] - 4, samples[i][2], g.font)
    local fh = UD.measure(font, "Ag")
    if valueH == nil or fh < valueH then valueFont, valueH = font, fh end
  end
  local labelY = top + tp
  local valueY = labelY + f.subH + math.max(0, math.floor((valueRoom - valueH) / 2))

  UD.label(children, colX, labelY, govW, f.subH, T.governor, f.sub, C.label, LEFT)
  UD.label(children, colX, valueY, govW, valueH, UD.governorText(state), valueFont, C.text, LEFT)
  UD.label(children, colX + govW, labelY, thrW, f.subH, T.throttle, f.sub, C.label, CENTER)
  UD.label(children, colX + govW, valueY, thrW, valueH, UD.throttleText(state), valueFont, C.text, CENTER)

  -- The speed controller's live verdict, as the flight view's status line reads it, in its level's
  -- colour; `-` without a link or without a verdict.
  local fitEsc = fitter(UD, valueFont, escW)
  UD.label(children, colX + govW + thrW, labelY, escW, f.subH, T.esc, f.sub, C.label, RIGHT)
  UD.label(children, colX + govW + thrW, valueY, escW, valueH, function()
    if state.rfConnected ~= true then return "-" end
    local d = state.derived
    local esc = d and d.esc_status_live
    if type(esc) ~= "string" or esc == "" then return "-" end
    return fitEsc(esc)
  end, valueFont, function()
    local d = state.derived
    local level = d and d.esc_status_live_level
    if state.rfConnected == true and type(level) == "number" then
      if level >= 3 then return C.crit end
      if level == 2 then return C.warn end
    end
    return C.text
  end, RIGHT)

  -- ---------------------------------------------------------------- the event history
  local captionY = top + cardH + gap
  UD.label(children, x, captionY, w, f.subH, T.event_log, f.sub, C.label, LEFT)
  UD.hline(children, x, captionY + f.subH + 1, w)

  local listY = captionY + f.subH + 1 + gap
  local rowH = f.subH + tp
  local slots = math.max(0, math.floor((bottom - listY) / rowH))
  local timeW = UD.textWidth(f.sub, "00:00:00") + 2 * g.pad
  local textW = w - timeW

  -- Every row reads the host's list by its distance from the newest entry, and redescribes its
  -- entry only when another one has moved into its place.
  local gov = governorNames(T)
  for i = 1, slots do
    local rowY = listY + (i - 1) * rowH
    local function entry()
      local log = state.eventLog
      if type(log) ~= "table" then return nil end
      return log[#log - i + 1]
    end
    local last, text, color = nil, "", C.text
    local function refresh()
      local e = entry()
      if e ~= last then
        last = e
        if e == nil then
          text, color = "", C.text
        else
          text, color = describe(e, T, C, gov)
        end
      end
    end
    UD.label(children, x, rowY, timeW, f.subH, function()
      local e = entry()
      return e and e.time or ""
    end, f.sub, C.label, LEFT)
    UD.label(children, x + timeW, rowY, textW, f.subH, function()
      refresh()
      return text
    end, f.sub, function()
      refresh()
      return color
    end, LEFT)
  end

  -- What the empty list says, in the middle of where the rows would be.
  local emptyY = listY + math.max(0, math.floor((bottom - listY - f.nameH) / 2))
  UD.label(children, x, emptyY, w, f.nameH, T.no_events, f.name, C.label, CENTER)
  children[#children].visible = function()
    local log = state.eventLog
    return type(log) ~= "table" or #log == 0
  end

  return children
end

return M
