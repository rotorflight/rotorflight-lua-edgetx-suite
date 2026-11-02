-- The telemetry view (init.lua registers it as `urban_telemetry`): up to twelve readings as
-- tiles, three to a row, each with its name, its figure and -- where the flight record keeps one
-- -- the least and the most the flight reached.
--
-- Opened in full screen by a tap on the flight view's value rows, or by a key the pilot sets to it
-- on the Keys settings page. The tiles are chosen on the Telemetry settings page, from the
-- catalogue the five value rows choose from (layout.lua, L.SOURCES), so a tile shows a reading
-- exactly as a row does: the same name, the same figure, the same colour, the same unit setting.
-- A tile set to nothing is left out and the others close up.
--
-- The range line is the flight record's (tasks/events/telemetry/flight_record.lua): the flight in
-- progress where it has taken a value, the flight that ended otherwise. So it is empty until the
-- model has been armed once, it covers the armed time only, and a side the record does not keep
-- -- the least MCU temperature, the most fuel -- reads `-`. A reading the record does not keep at
-- all (ESC load, ESC status, air rate, rate floor) has no range line.

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
local L = requireModule("widgets/dashboard/themes/urban/layout.lua") or {}

local M = {}

local COLUMNS = 3

function M.build(children, zone, state, ctx)
  if type(K.begin) ~= "function" or type(L.tileRows) ~= "function" then return children end
  state = state or {}
  local g = K.begin(zone, state)
  if g == nil then return children end
  local UD, C, T = K.UD, K.C, K.T

  local closePress = nil
  if type(ctx) == "table" and type(ctx.action) == "function" then
    closePress = function() ctx.action("closeView") end
  end
  local top = K.header(children, g, T.view_telemetry, closePress)

  local x, w = g.x + g.pad, g.w - 2 * g.pad
  local bottom = g.y + g.h - g.pad
  local tiles = L.tileRows(state)
  local n = #tiles
  if n == 0 then
    local msgY = top + math.floor((bottom - top - g.fontH) / 2)
    UD.label(children, x, msgY, w, g.fontH, UD.fit(g.font, T.no_tiles, w), g.font, C.label, CENTER)
    return children
  end

  -- The grid: three columns, as many rows as the tiles need, every tile the same size. Fewer tiles
  -- give each one more height, and the figure grows with it.
  local rowsN = math.floor((n + COLUMNS - 1) / COLUMNS)
  local gap = g.gap
  local tileW = math.floor((w - (COLUMNS - 1) * gap) / COLUMNS)
  local tileH = math.floor((bottom - top - (rowsN - 1) * gap) / rowsN)
  local inner = tileW - 2 * g.textPad

  -- The name in the face the flight view's row names are drawn in, the range one face smaller;
  -- on a tile too short for both at that size, both step down one face.
  local nameFont, rangeFont = g.font, K.stepFace(g.font, -1)
  local nameH, rangeH = g.fontH, UD.measure(rangeFont, "Ag")
  if nameH + rangeH + 2 * g.textPad > math.floor(tileH / 2) then
    nameFont, rangeFont = rangeFont, K.stepFace(rangeFont, -1)
    nameH, rangeH = UD.measure(nameFont, "Ag"), UD.measure(rangeFont, "Ag")
  end
  local rangeBoxH = rangeH + 2

  -- One face for every figure, the largest that fits what a tile leaves between its name and its
  -- range line, so the tiles read as one set. A tile whose own widest figure does not fit that face
  -- takes the largest face below it that does, and no tile is ever larger than the set.
  local showUnits = L.setting(state, "units") == "on"
  local unitFont = rangeFont
  local unitH = rangeH
  local valueH = tileH - (g.textPad + nameH) - (rangeBoxH + g.textPad) - 2
  local setFont = UD.selectFont(math.max(8, valueH), inner, "888.8")

  for i = 1, n do
    local tile = tiles[i]
    local col = (i - 1) % COLUMNS
    local row = math.floor((i - 1) / COLUMNS)
    local tx = x + col * (tileW + gap)
    local ty = top + row * (tileH + gap)

    UD.rect(children, tx, ty, tileW, tileH, C.track, false, math.max(4, math.floor(tileH * 0.10)), 1)

    UD.label(children, tx + g.textPad, ty + g.textPad, inner, nameH,
      UD.fitLabel(nameFont, tile.label, inner), nameFont, C.label, CENTER)

    local unit = showUnits and (tile.unit or "") or ""
    local unitW = (unit ~= "") and (UD.textWidth(unitFont, unit) + 3) or 0
    local sample = tile.sample or "8888"
    local valueFont = UD.selectFont(math.max(8, valueH), inner - unitW, sample, setFont)
    local figureH = UD.measure(valueFont, sample)
    local valueTop = ty + g.textPad + nameH
    local valueY = valueTop + math.max(0, math.floor((valueH - figureH) / 2))
    if unitW == 0 then
      UD.label(children, tx + g.textPad, valueY, inner, figureH, tile.value, valueFont, tile.color or C.text, CENTER)
    else
      -- The figure right-aligned to a gutter placed from its widest sample, so a full-width figure
      -- and its unit sit centred together, and the unit always hugs the figure. A shorter figure
      -- leans a little right of centre rather than costing a width measurement per frame.
      local sampleW = UD.textWidth(valueFont, sample)
      local gutter = tx + math.floor(tileW / 2) + math.floor((sampleW - unitW) / 2)
      gutter = math.min(gutter, tx + tileW - g.textPad - unitW)
      UD.label(children, tx + g.textPad, valueY, gutter - (tx + g.textPad), figureH,
        tile.value, valueFont, tile.color or C.text, RIGHT)
      UD.label(children, gutter + 2, valueY + figureH - unitH, unitW, unitH, unit, unitFont, C.tick, LEFT)
    end

    if tile.range ~= nil then
      local rangeW = math.min(inner, UD.textWidth(rangeFont, tile.rangeSample) + 2 * g.textPad + 4)
      local rx = tx + math.floor((tileW - rangeW) / 2)
      local ry = ty + tileH - g.textPad - rangeBoxH
      UD.rect(children, rx, ry, rangeW, rangeBoxH, C.track, true, math.floor(rangeBoxH / 2))
      UD.label(children, rx, ry + 1, rangeW, rangeH, tile.range, rangeFont, C.text, CENTER)
    end
  end
  return children
end

-- The readings the tiles need beyond the fixed state fields (layout.lua, L.tileSources). A host
-- with view sources resolves them while this view is on top and at no other time.
function M.sources(_, state)
  if type(L.tileSources) ~= "function" then return {} end
  return L.tileSources(state or {})
end

-- The cell count divides the cell tile's figure and its range, and it is fixed at build time, as
-- it is in the flight view; a pack with another count rebuilds the view. The range of the flight
-- that ended is the exception: it is divided by the count of the pack that flew
-- (layout.lua, extremeReader), which the reader takes per frame and no key needs to carry.
function M.renderKey(_, state)
  local UD = K.UD
  if UD == nil or type(UD.cells) ~= "function" then return "" end
  return tostring(UD.cells(state or {}))
end

return M
