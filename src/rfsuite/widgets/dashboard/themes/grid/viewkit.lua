-- The chrome this theme's full screen views share: the header with its title and close box, the
-- row button, and the few words a view says about the host's work.
--
-- The views are registered in init.lua (`views`) and exist only on a host that has theme views;
-- the host loads a view's module the first time the view is built, so this file loads in a
-- fullscreen job pass and never in the pass that reloads the theme. Every view draws its header
-- through K.header, the battery picker (battpick.lua) included, so the picker, the menus and the
-- link view read as one set -- and as the flight view they open from: a white page, black text,
-- 1 px lines, outlined controls, and colour only where it means something.
--
-- Nothing here decides what a press does. Every press a view binds is `ctx.action(...)` or
-- `ctx.run(...)`: the host performs the work and what follows it.

if type(_G) == "table" and type(_G.__rfsuiteThemeGridViewkitModule) == "table" then
  return _G.__rfsuiteThemeGridViewkitModule
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

local UD = requireModule("widgets/dashboard/themes/grid/common.lua")
if not UD then return {} end

local K = {}
K.UD = UD
K.C = UD.C
K.T = UD.T

-- The faces the firmware exports, largest first -- the order common.lua's font picker walks. A
-- face one step up or down from another is its neighbour in this list, never a ratio of heights:
-- the faces are not evenly spaced, and a ratio can land on another face for one pixel of
-- difference between two firmware builds.
local FACES = {}
do
  local order = { "XXLSIZE", "XLSIZE", "DBLSIZE", "MIDSIZE", "STDSIZE", "SMLSIZE", "TINSIZE" }
  for i = 1, #order do
    local value = _G[order[i]]
    if order[i] == "STDSIZE" and type(value) ~= "number" then value = 0 end
    if type(value) == "number" then FACES[#FACES + 1] = value end
  end
end

-- The face `steps` places from `font` in FACES: positive is larger, negative smaller. A step past
-- either end answers that end; a face that is not in the list answers itself.
function K.stepFace(font, steps)
  for i = 1, #FACES do
    if FACES[i] == font then
      return FACES[math.max(1, math.min(#FACES, i - steps))]
    end
  end
  return font
end

-- The start of every view build: the scheme and the frames the pilot chose, the metric cache
-- for this zone, and the geometry. Answers the geometry, or nil where the zone has no area.
function K.begin(zone, state)
  UD.applyScheme(((state and state.themeConfig) or {}).scheme)
  UD.applyFrames(state and state.themeConfig)
  UD.beginBuild(zone)
  return K.geometry(zone)
end

-- The geometry alone, without touching the scheme: the paddings, the close box and the face.
--
-- The face is the flight view's own -- the one its top bar, its clock and its value-row names are
-- drawn in (layout.lua, L.buildFlight: a bar of 7.5 % of the height, at least 18 px, its face
-- sized against "Total Time"). Taken by the same rule from the same height, a view's row names
-- are the size of the screen the view opens from, on every screen size; the title is up to one
-- face larger (K.header).
--
-- The close box is the one fixed size: 72 px on a screen taller than 350 px, 36 px below that.
function K.geometry(zone)
  local w = math.floor(UD.num(zone and zone.w) or 0)
  local h = math.floor(UD.num(zone and zone.h) or 0)
  if w <= 0 or h <= 0 then return nil end
  local isLarge = h > 350
  local barH = math.max(18, math.floor(h * 0.075))
  local font = UD.selectFont(barH - 2, nil, "Total Time")
  return {
    x = math.floor(UD.num(zone.x) or 0), y = math.floor(UD.num(zone.y) or 0), w = w, h = h,
    pad = isLarge and 12 or 5,
    gap = isLarge and 8 or 4,
    textPad = isLarge and 5 or 2,
    closeSize = isLarge and 72 or 36,
    closeMargin = isLarge and 4 or 2,
    font = font,
    fontH = UD.measure(font, "Total Time"),
  }
end

local function line(nodes, x1, y1, x2, y2, color, thickness)
  nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0,
    pts = { { x1, y1 }, { x2, y2 } }, color = color, thickness = thickness }
end

-- A box outline drawn as four lines, as the flight view's menu glyph is drawn: a line is created
-- not clickable, so the outline can lie over a button without taking its press, where a rectangle
-- over a button would take it.
function K.outline(nodes, x, y, w, h, color, thickness)
  local x1, y1 = x + w - 1, y + h - 1
  local th = thickness or 2
  line(nodes, x, y, x1, y, color, th)
  line(nodes, x, y1, x1, y1, color, th)
  line(nodes, x, y, x, y1, color, th)
  line(nodes, x1, y, x1, y1, color, th)
end

-- The host's quick menu numbers (widgets/dashboard/fullscreen_menu.lua, M.PLACES and
-- M.TWO_COLUMNS_FROM): the pilot's entries on a fixed raster of six places, in two columns from
-- this width up, and the BATTERY PROFILE row on the row after the raster's last. The mark after a
-- row's value that says the row opens a page is the host's as well (M.OPENS_MARK).
K.PLACES = 6
K.TWO_COLUMNS_FROM = 300
K.OPENS_MARK = " >"

-- The background, the header, its title and -- where `closePress` is given -- the close box.
-- `aside` is an optional second text after the title, in the label colour, which the link view
-- uses for the air rate. `backPress`, where given, puts a back box left of the title: the close
-- box's shape with a `<` drawn in it. Answers the y the content starts at.
--
-- No strip: the header stands on the page's own background and a 1 px line closes it, inset by
-- the padding, as the flight view separates its groups. The close box takes the menu glyph's
-- shape: an outlined square with the X drawn as two lines, in the line colour. The header is as
-- tall as the box needs; a header without one (the link view in the widget zone) is as tall as
-- its title.
function K.header(nodes, g, title, closePress, aside, backPress)
  local C = UD.C
  local headerH = g.fontH + 2 * g.textPad
  if closePress ~= nil or backPress ~= nil then headerH = g.closeSize + 2 * g.closeMargin end

  UD.rect(nodes, g.x, g.y, g.w, g.h, C.bg, true)
  UD.hline(nodes, g.x + g.pad, g.y + headerH - 1, g.w - 2 * g.pad)

  local right = g.x + g.w - g.pad
  if closePress ~= nil then
    local size = g.closeSize
    local closeX = right - size
    local closeY = g.y + g.closeMargin
    UD.button(nodes, closeX, closeY, size, size, C.bg, closePress)
    K.outline(nodes, closeX, closeY, size, size, C.line, 2)
    local inset = math.floor(size * 0.28)
    local th = math.max(2, math.floor(size * 0.09))
    local a, b = closeX + inset, closeX + size - 1 - inset
    local c, d = closeY + inset, closeY + size - 1 - inset
    line(nodes, a, c, b, d, C.line, th)
    line(nodes, a, d, b, c, C.line, th)
    right = closeX - g.pad
  end

  local left = g.x + g.pad
  if backPress ~= nil then
    local size = g.closeSize
    local backY = g.y + g.closeMargin
    UD.button(nodes, left, backY, size, size, C.bg, backPress)
    K.outline(nodes, left, backY, size, size, C.line, 2)
    local inset = math.floor(size * 0.3)
    local th = math.max(2, math.floor(size * 0.09))
    local tipX, tailX = left + inset, left + size - 1 - inset
    local midY = backY + math.floor(size / 2)
    local reach = math.floor((size - 2 * inset) / 2)
    line(nodes, tailX, midY - reach, tipX, midY, C.line, th)
    line(nodes, tipX, midY, tailX, midY + reach, C.line, th)
    left = left + size + g.pad
  end

  -- The title on one line, in the largest face up to 1.4 times the flight view's that fits the
  -- room beside the close box: a face above the top bar's where the header has the height, the
  -- top bar's own where it has not (a header without a close box is exactly as tall as that).
  local titleW = math.max(10, right - left)
  local titleFont = UD.selectFont(math.min(headerH - 2 * g.textPad, math.floor(g.fontH * 1.4)), titleW, title)
  local titleH = UD.measure(titleFont, title)
  local titleY = g.y + math.floor((headerH - titleH) / 2)
  local shown = UD.fit(titleFont, title, titleW)
  UD.label(nodes, left, titleY, titleW, titleH, shown, titleFont, C.text, LEFT)
  if aside ~= nil then
    local used = UD.textWidth(titleFont, shown) + 2 * g.pad
    local asideW = titleW - used
    if asideW > 10 then
      UD.label(nodes, left + used, g.y + math.floor((headerH - g.fontH) / 2), asideW, g.fontH,
        aside, g.font, C.label, LEFT)
    end
  end
  return g.y + headerH + g.gap
end

-- The two faces a row uses: the name in the flight view's face, the line under it one face
-- smaller. `rowH` is a row with both lines, `lineH` a row with the name alone -- each the height
-- its text needs; how much taller a row is drawn is the view's call (K.stretch).
function K.rowFonts(g)
  local subFont = K.stepFace(g.font, -1)
  local subH = UD.measure(subFont, "Ag")
  return { name = g.font, nameH = g.fontH, sub = subFont, subH = subH,
           rowH = g.fontH + subH + 2 * g.textPad, lineH = g.fontH + 2 * g.textPad }
end

-- The heights of a stack of rows that has to fit `avail` px: each row at least its own `natural`
-- height, and every row grown alike toward the close box's size with the room that is left -- so
-- a short list gets targets as large as the X, and a long one still shows every row. `fixed` is
-- what the stack spends on anything but rows (titles, gaps). Answers one height per row.
function K.stretch(g, avail, fixed, naturals)
  local n = #naturals
  local heights = {}
  if n == 0 then return heights end
  local room = avail - fixed
  -- A row whose own height is above the even share keeps its own height, and the share is worked
  -- out again over the others.
  local share = math.floor(room / n)
  local big, rest = 0, 0
  for i = 1, n do
    if naturals[i] > share then big = big + naturals[i] else rest = rest + 1 end
  end
  if rest > 0 then share = math.floor((room - big) / rest) end
  share = math.min(share, g.closeSize)
  for i = 1, n do heights[i] = math.max(naturals[i], share) end
  return heights
end

-- A button with a name and an optional line under it. White with a 2 px outline in the line
-- colour, as the flight view's own controls are drawn; `selected` fills it in the ok colour -- the
-- one choice in force. The labels and the outline lie over the button and are labels and lines,
-- never rectangles: a rectangle drawn over a press takes the press away from it.
function K.button(nodes, g, f, x, y, w, h, name, sub, selected, press)
  local C = UD.C
  UD.button(nodes, x, y, w, h, selected and C.ok or C.bg, press)
  K.outline(nodes, x, y, w, h, selected and C.ok or C.line, 2)
  local ink = selected and C.ink or C.text
  local subInk = selected and C.ink or C.label
  local inner = w - 2 * g.textPad
  local hasSub = sub ~= nil and sub ~= ""
  local blockH = f.nameH + (hasSub and f.subH or 0)
  local top = y + math.max(0, math.floor((h - blockH) / 2))
  UD.label(nodes, x + g.textPad, top, inner, f.nameH, UD.fit(f.name, name, inner), f.name, ink, CENTER)
  if hasSub then
    UD.label(nodes, x + g.textPad, top + f.nameH, inner, f.subH, UD.fit(f.sub, sub, inner), f.sub, subInk, CENTER)
  end
end

-- A row with a name on the left and a value on the right, the whole row one press: the BATTERY
-- PROFILE row of the quick menu. `values` are the host's texts for the value, longest first, each
-- a shortening of the one before; the longest that fits is shown, with the mark that the row opens
-- a page after it, and the last where none fits.
function K.valueRow(nodes, g, f, x, y, w, h, name, values, press)
  local C = UD.C
  UD.button(nodes, x, y, w, h, C.bg, press)
  K.outline(nodes, x, y, w, h, C.line, 2)
  local top = y + math.max(0, math.floor((h - f.nameH) / 2))
  local inner = w - 2 * g.textPad - 2 * g.pad
  local nameW = math.min(UD.textWidth(f.name, name), math.floor(inner / 2))
  UD.label(nodes, x + g.textPad + g.pad, top, nameW, f.nameH, UD.fit(f.name, name, nameW), f.name, C.text, LEFT)
  local valueW = inner - nameW - g.pad
  local value = K.OPENS_MARK
  if type(values) == "table" and #values > 0 then
    value = values[#values] .. K.OPENS_MARK
    for i = 1, #values do
      local text = values[i] .. K.OPENS_MARK
      if UD.textWidth(f.name, text) <= valueW then
        value = text
        break
      end
    end
  end
  UD.label(nodes, x + w - g.textPad - g.pad - valueW, top, valueW, f.nameH, value, f.name, C.text, RIGHT)
end

-- A button that cannot be pressed now: drawn as K.button draws it -- `selected` filled in the ok
-- colour -- but as an outline in the track colour, with labels in the label colour, and no press.
function K.inert(nodes, g, f, x, y, w, h, name, sub, selected)
  local C = UD.C
  if selected then UD.rect(nodes, x, y, w, h, C.ok, true) end
  UD.rect(nodes, x, y, w, h, selected and C.ok or C.track, false, 0, 2)
  local ink = selected and C.ink or C.label
  local inner = w - 2 * g.textPad
  local hasSub = sub ~= nil and sub ~= ""
  local blockH = f.nameH + (hasSub and f.subH or 0)
  local top = y + math.max(0, math.floor((h - blockH) / 2))
  UD.label(nodes, x + g.textPad, top, inner, f.nameH, UD.fit(f.name, name, inner), f.name, ink, CENTER)
  if hasSub then
    UD.label(nodes, x + g.textPad, top + f.nameH, inner, f.subH, UD.fit(f.sub, sub, inner), f.sub, ink, CENTER)
  end
end

-- A row that is not offered now: its name and why, in the label colour, a 2 px outline in the
-- track colour, and no press.
function K.unavailable(nodes, g, f, x, y, w, h, name)
  local C = UD.C
  UD.rect(nodes, x, y, w, h, C.track, false, 0, 2)
  local inner = w - 2 * g.textPad
  local top = y + math.max(0, math.floor((h - f.nameH - f.subH) / 2))
  UD.label(nodes, x + g.textPad, top, inner, f.nameH, UD.fit(f.name, name, inner), f.name, C.label, CENTER)
  UD.label(nodes, x + g.textPad, top + f.nameH, inner, f.subH, UD.fit(f.sub, UD.T.unavailable, inner),
    f.sub, C.label, CENTER)
end

-- What became of the host's work on an entry, as the host reports it (`ctx.status`): the word and
-- its colour, or nil where nothing has been run in this visit.
function K.outcome(status)
  local C, T = UD.C, UD.T
  if status == "busy" then return T.run_busy, C.warn end
  if status == "ok" then return T.run_ok, C.ok end
  if status == "failed" then return T.run_failed, C.crit end
  return nil, nil
end

if type(_G) == "table" then _G.__rfsuiteThemeGridViewkitModule = K end

return K
