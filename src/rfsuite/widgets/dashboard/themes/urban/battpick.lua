-- The battery picker this theme draws for itself.
--
-- M.layout draws it, and pickview.lua is what calls it on a host with theme views: the host's
-- `battery_pick` record turned into a spec. M.build fills the same spec from a widget's
-- `state.batteryPick` for a host that calls a theme's `batteryPick(children, widget)` hook; the
-- phase modules of this theme export no such hook.
--
-- It is a one-shot build: every string is a constant computed in this function. Nothing of
-- the picker runs in the firmware's reactive sweep, which is the cheapest way to satisfy
-- the reactive-closure rule rather than the carefully memoised way the flight view needs.
--
-- What the theme may write back is fixed by the host contract, and it is all this file
-- does: a press sets `widget._batteryPickRequest` to the entry's id (`false` for "no
-- battery"; nil is the host's "nothing was pressed"), the close box calls the host's
-- `rfsuite.batteryPick.dismiss()` or, where
-- that is not published, sets `widget.state.batteryPick.dismissed` itself, and both leave
-- fullscreen. In particular the `widget.built = false; widget.renderKey = nil` reset the
-- stock fullscreen menu performs is deliberately NOT done here -- the contract says nothing
-- else is written to the host, so the host keys its own rebuild off `pending`/`dismissed`.

if type(_G) == "table" and type(_G.__rfsuiteThemeUrbanBattpickModule) == "table" then
  return _G.__rfsuiteThemeUrbanBattpickModule
end

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

local UD = requireModule("widgets/dashboard/themes/urban/common.lua")
local K = requireModule("widgets/dashboard/themes/urban/viewkit.lua")
if not UD or not K or type(K.geometry) ~= "function" then return {} end

local M = {}
local num = UD.num

local function exitFullScreen()
  if lcd and type(lcd.exitFullScreen) == "function" then lcd.exitFullScreen() end
end

-- A press records a request and leaves. The host performs the pick on its next pass; no
-- card write and no MSP queue call may happen inside an LVGL press callback.
local function pressRequest(widget, id)
  return function()
    widget._batteryPickRequest = id
    exitFullScreen()
  end
end

-- The close box dismisses through the host's own published helper wherever it exists:
-- `rfsuite.batteryPick.dismiss()` clears `pending` and invalidates the render key as well as
-- setting the flag, and neither of those is reachable from a theme. The direct write stays
-- as the fallback for a host that does not publish it -- `dismissed` is the one state field
-- the contract lets a theme set, and setting it alongside the helper would be writing a
-- field the helper already owns.
--
-- The lookup sits inside the callback rather than at build time: the runtime publishes the
-- table when it comes up, which need not be before this module was loaded. A press callback
-- is not a reactive closure, so a global read here is legal.
local function pressDismiss(widget)
  return function()
    local api = _G.rfsuite and _G.rfsuite.batteryPick
    if api and type(api.dismiss) == "function" then
      api.dismiss()
    else
      local st = widget and widget.state
      local bp = st and st.batteryPick
      if type(bp) == "table" then bp.dismissed = true end
    end
    exitFullScreen()
  end
end

-- A pack's line under its name: the capacity, the cycle count and the battery profile a pick
-- selects, each where the registry or the board gives one. `targetProfile` is 0-based, as the
-- host resolves it; a pack with no `cycles=` in the registry has not been counted yet, which is
-- zero. Every number is floored, because a float into "%d" raises.
function M.detail(cap, cycles, targetProfile)
  local T = UD.T
  local parts = {}
  cap = num(cap)
  if cap and cap > 0 then parts[#parts + 1] = string.format("%d mAh", math.floor(cap + 0.5)) end
  parts[#parts + 1] = string.format(T.pick_cycles, math.floor(num(cycles) or 0))
  targetProfile = num(targetProfile)
  if targetProfile then parts[#parts + 1] = string.format(T.pick_profile, math.floor(targetProfile) + 1) end
  return table.concat(parts, " - ")
end

-- NO BATTERY as one line in the flight view's face, in an outline: the answer in force is marked
-- by the ok colour on the outline and the text rather than by a filled bar, so the foot row stays
-- as quiet as its one line.
local function noneRow(nodes, g, x, y, w, h, label, selected, press)
  local C = UD.C
  local ink = selected and C.ok or C.text
  UD.button(nodes, x, y, w, h, C.bg, press)
  K.outline(nodes, x, y, w, h, selected and C.ok or C.line, 2)
  local inner = w - 2 * g.textPad
  UD.label(nodes, x + g.textPad, y + math.max(0, math.floor((h - g.fontH) / 2)), inner, g.fontH,
    UD.fit(g.font, label, inner), g.font, ink, CENTER)
end

-- The picker's picture, apart from what its presses do and where its strings come from: the
-- `spec` names the title, the close box's press, the packs in registry order (`name`, `sub`,
-- `selected`, `press`) and NO BATTERY (`label`, `selected`, `press`). M.build below fills it
-- from the widget for the host hook; pickview.lua fills it from the host's `battery_pick`
-- record, so the two pickers are one drawing.
--
-- The header is the one every view of this theme draws (viewkit.lua, K.header), from the
-- screen's top left corner. The packs stand in two columns from two packs up, each a cell with
-- the pack's name one face above the flight view's and its line (M.detail) in that face.
-- NO BATTERY always gets a full-width row of its own at the foot, reserved before the pack grid
-- is measured so it can never be the entry that falls off the bottom. It holds one line, so it
-- is only as tall as that line or the close box, whichever is taller, and the pack cells get
-- the rest.
--
-- Where the packs need more rows than the room above NO BATTERY holds, the grid scrolls: the
-- cells keep the size they have when the room is full, and every row stands in a `box` the size
-- of that room, which the firmware scrolls in full screen -- by a swipe, and by the rotary
-- encoder, whose focus moves from button to button and brings the focused one into view. Every
-- pack can then be reached and picked; NO BATTERY and the header stay where they are. The box
-- takes no option beyond its geometry: the firmware's defaults scroll it in both directions,
-- which is vertical only here because the rows are never wider than the box, and show a scroll
-- bar while there is more to see, for which the cells leave a strip at the right.
function M.layout(children, dW, dH, spec)
  local g = K.geometry({ x = 0, y = 0, w = dW, h = dH })
  if g == nil then return children end
  local packs = spec.packs or {}
  local contentY = K.header(children, g, spec.title, spec.closePress)

  local cols = (#packs >= 2) and 2 or 1
  local fullW = dW - 2 * g.pad
  local btnW = math.floor((fullW - (cols - 1) * g.gap) / cols)
  if btnW < 20 then return children end
  local contentH = dH - contentY - g.pad
  if contentH < 20 then return children end

  local nameFont = K.stepFace(g.font, 1)
  local f = { name = nameFont, nameH = UD.measure(nameFont, "Ag"), sub = g.font, subH = g.fontH }
  -- A cell is never lower than the close box, so every target on the picker is at least its size.
  local minBtnH = math.max(f.nameH + f.subH + 2 * g.textPad, g.closeSize)

  local noneH = math.min(math.max(g.fontH + 2 * g.textPad, g.closeSize), contentH)
  local noneY = contentY + contentH - noneH
  local gridH = contentH - noneH - g.gap

  -- How many pack rows the remaining height shows at once: three on the 800x480, 480x320 and
  -- 480x272 screens, six packs.
  local rowsFit = 0
  if gridH >= minBtnH then rowsFit = math.floor((gridH + g.gap) / (minBtnH + g.gap)) end
  local rowsNeeded = math.ceil(#packs / cols)
  local rows = math.min(rowsNeeded, rowsFit)

  local btnH = minBtnH
  if rows > 0 then
    local fair = math.floor((gridH - (rows - 1) * g.gap) / rows)
    -- Capped, or two packs become slabs as tall as the picker.
    btnH = math.max(minBtnH, math.min(fair, 2 * minBtnH))
  end

  if rowsNeeded <= rowsFit then
    for i = 1, #packs do
      local pack = packs[i]
      if type(pack) ~= "table" then break end
      local row = math.floor((i - 1) / cols)
      local col = (i - 1) % cols
      K.button(children, g, f, g.pad + col * (btnW + g.gap), contentY + row * (btnH + g.gap), btnW, btnH,
        pack.name, pack.sub, pack.selected, pack.press)
    end
  elseif gridH > 0 then
    -- The scrolling grid. A box clips what it holds to its own area, and a 2 px line reaches one
    -- pixel above and left of its coordinate, so the cells start one pixel in from the box's top
    -- left corner and the box one pixel before the grid: the first row's outline is drawn whole.
    -- The strip at the right is the scroll bar's.
    local barW = 2 * g.gap
    local cellW = math.floor((fullW - barW - (cols - 1) * g.gap) / cols)
    local cells = {}
    for i = 1, #packs do
      local pack = packs[i]
      if type(pack) ~= "table" then break end
      local row = math.floor((i - 1) / cols)
      local col = (i - 1) % cols
      K.button(cells, g, f, 1 + col * (cellW + g.gap), 1 + row * (btnH + g.gap), cellW, btnH,
        pack.name, pack.sub, pack.selected, pack.press)
    end
    children[#children + 1] = {
      type = "box", x = g.pad - 1, y = contentY - 1, w = fullW + 1, h = gridH + 1, children = cells
    }
  end

  local none = spec.none
  if none ~= nil then
    noneRow(children, g, g.pad, noneY, fullW, noneH, none.label, none.selected, none.press)
  end

  return children
end

-- The host hook's picker: the spec made from the widget, with the presses the hook's contract
-- allows a theme -- a request on the widget, the host's dismiss helper -- and nothing else.
function M.build(children, widget)
  children = children or {}
  local zone = (widget and widget.zone) or {}
  -- Fullscreen hands the whole screen as the zone and the stock menu draws it from 0,0;
  -- this one does the same rather than trusting a zone origin that is not set there.
  local dW = math.floor(num(zone.w) or 0)
  local dH = math.floor(num(zone.h) or 0)
  if dW <= 0 or dH <= 0 then return children end

  local t = function(k, f) return f or k end
  if widget and type(widget.i18n) == "table" and type(widget.i18n.t) == "function" then
    t = widget.i18n.t
  end

  local state = (widget and widget.state) or {}
  -- The picker is drawn by the HOST, in fullscreen, outside any build of the two views, so it
  -- applies the colour scheme itself rather than inheriting whichever one the last build of a
  -- view happened to leave in place.
  UD.applyScheme((type(state.themeConfig) == "table" and state.themeConfig.scheme) or nil)
  UD.applyFrames(state.themeConfig)
  local pick = (type(state.batteryPick) == "table" and state.batteryPick) or {}
  local candidates = (type(pick.candidates) == "table" and pick.candidates) or {}
  local selectedId = pick.selectedId
  local noneSelected = (selectedId == nil or selectedId == "")

  local packs = {}
  for i = 1, #candidates do
    local entry = candidates[i]
    if type(entry) ~= "table" then break end

    -- The comparison is by string so a numeric registry id and a stored string id still
    -- match; the id itself goes back to the host untouched -- the host owns its type.
    packs[i] = {
      name = tostring(entry.name or entry.id or "?"),
      sub = M.detail(entry.cap, entry.cycles, entry.targetProfile),
      selected = (not noneSelected) and (tostring(entry.id) == tostring(selectedId)),
      press = pressRequest(widget, entry.id),
    }
  end

  -- `false`, not "" and not nil: the host reads nil as "no request made on this pass", so
  -- "no battery" needs a value that is present and still not an id. It accepts "" as well,
  -- but `false` is what its contract states and what this theme sends.
  return M.layout(children, dW, dH, {
    title = t("widgets.dashboard.battery_pick_title", "WHICH BATTERY?"),
    closePress = pressDismiss(widget),
    packs = packs,
    none = { label = t("widgets.dashboard.battery_pick_none", "NO BATTERY"), selected = noneSelected,
             press = pressRequest(widget, false) },
  })
end

if type(_G) == "table" then _G.__rfsuiteThemeUrbanBattpickModule = M end

return M
