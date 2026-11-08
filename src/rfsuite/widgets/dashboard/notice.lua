-- A large information tile: a title and lines of text in one rounded card, wrapped to its room and
-- drawn in the largest font that shows all of it. The text is read once, so no font has to stay
-- comfortable; it only has to fit.
--
-- It holds nothing: the nodes it hands back carry their strings, and a caller loads this file only
-- for the build that shows a tile.
local M = {}

local PADDING_X, PADDING_Y, ROW_GAP = 8, 5, 1

local function textWidth(text, font)
  local w = lcd.sizeText(text, font)
  return w
end

-- Whole lines first: a line that fits costs one measurement, and only one that does not is walked
-- word by word. False when a single word is wider than the room, since nothing can break it.
local function wrap(text, width, font, rows)
  if textWidth(text, font) <= width then
    rows[#rows + 1] = text
    return true
  end
  local line = nil
  for word in string.gmatch(text, "%S+") do
    local candidate = line and (line .. " " .. word) or word
    if textWidth(candidate, font) > width then
      if line == nil then return false end
      if textWidth(word, font) > width then return false end
      rows[#rows + 1] = line
      line = word
    else
      line = candidate
    end
  end
  if line then rows[#rows + 1] = line end
  return true
end

local function fonts()
  local out = {}
  local names = { "STDSIZE", "SMLSIZE", "TINSIZE" }
  for i = 1, #names do
    local value = _G[names[i]]
    if names[i] == "STDSIZE" and type(value) ~= "number" then value = 0 end
    if type(value) == "number" then out[#out + 1] = value end
  end
  return out
end

--- The tile for this room, or nil where the text does not fit at the smallest font.
--- `colors` are the color scheme's roles. The nodes go on the end of `children`.
function M.append(children, x, y, w, h, title, lines, colors)
  local innerW, innerH = w - PADDING_X * 2, h - PADDING_Y * 2
  local chosen, rows, rowH = nil, nil, 0
  local list = fonts()
  for i = 1, #list do
    local font = list[i]
    local wrapped = {}
    local wide = wrap(title, innerW, font, wrapped)
    for l = 1, #lines do wide = wrap(lines[l], innerW, font, wrapped) and wide end
    local _, fontH = lcd.sizeText("Ag", font)
    local height = fontH + ROW_GAP
    if wide and #wrapped * height <= innerH then
      chosen, rows, rowH = font, wrapped, height
      break
    end
  end
  if chosen == nil then return nil end
  children[#children + 1] = { type = "rectangle", x = x, y = y, w = w, h = h,
    color = colors.card, filled = true, rounded = 7 }
  for r = 1, #rows do
    children[#children + 1] = { type = "label", x = x + PADDING_X, y = y + PADDING_Y + (r - 1) * rowH,
      w = innerW, h = rowH, text = rows[r], font = chosen,
      color = r == 1 and colors.accentInk or colors.text }
  end
  return #rows
end

return M
