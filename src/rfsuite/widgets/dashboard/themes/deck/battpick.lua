-- The battery picker this theme draws for itself.
--
-- M.layout draws it, and pickview.lua is what calls it: the host's `battery_pick` record turned
-- into a spec. The presses are pickview.lua's too -- it hands them in with the spec -- so this
-- file writes nothing back to the host.
--
-- It is a one-shot build: every string is a constant computed in this function. Nothing of
-- the picker runs in the firmware's reactive sweep, which is the cheapest way to satisfy
-- the reactive-closure rule rather than the carefully memoised way the flight view needs.

if type(_G) == "table" and type(_G.__rfsuiteThemeDeckBattpickModule) == "table" then
  return _G.__rfsuiteThemeDeckBattpickModule
end

local function requireModule(path)
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require(path)
    if type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local UD = requireModule("widgets/dashboard/themes/deck/common.lua")
local K = requireModule("widgets/dashboard/themes/deck/viewkit.lua")
if not UD or not K or type(K.geometry) ~= "function" then return {} end

local M = {}
local num = UD.num

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
-- `selected`, `press`) and NO BATTERY (`label`, `selected`, `press`). pickview.lua fills it from
-- the host's `battery_pick` record.
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

if type(_G) == "table" then _G.__rfsuiteThemeDeckBattpickModule = M end

return M
