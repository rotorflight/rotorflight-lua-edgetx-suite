-- lib/color_schemes.lua
-- The suite's two colour schemes, in one place: change a value here and everything that reads the
-- role changes with it. Docs: docs/developer/color-schemes.md.
--
-- The tool and the dashboard widget are separate Lua states, so each loads its own copy of this
-- file. That is why it lives under lib/ and holds nothing but numbers until a state asks for them.
--
-- The values are the tokens of the Rotorflight Configurator's light and dark themes
-- (src/css/app.css, rotorflight-configurator at 2b6d4161). Where they differ from a token:
--   page in light   token 241,242,243: RGB565 gives green one more bit, so it draws 247,243,247, pink.
--   card in dark    token 26,28,31: draws 24,28,24, green.
--   header in light token 249,250,250: draws 255,251,255, pink.
--   disabled        each theme's neutral-500, since dark's own disabled token equals its secondary
--                   text and shows no step. In light (130,141,151) green is one RGB565 step down,
--                   since it read just under 3:1 on the page.
--   selection       the accent-soft token blended over the page at 10 % (light) and 16 % (dark).
--   onOk            no token for a foreground on the success colour, so it takes on-danger's value.

local M = {}

M.DEFAULT = "light"

-- The logo each scheme draws, under widgets/dashboard/gfx/. FLIGHT is white in logo.png, which cannot
-- be read on the light page.
M.LOGOS = { light = "logo_on_light.png", dark = "logo.png" }

-- How far a disabled tile's icon fades into the tile's face, 0-255 (an LVGL opacity). Dark draws a
-- disabled tile as an empty frame on the page, so its icon fades; light greys the face instead and
-- keeps the icon. Dark's 102 (40 %) keeps the faded icon at 3:1 on the face.
M.ICON_FADE = { light = 0, dark = 102 }

-- 0xRRGGBB per role: one number per role keeps less resident than a table of three, and lcd.RGB
-- takes it as it is from EdgeTX 2.11, the oldest version the suite runs on. colors() converts a
-- scheme in place the first time it is asked for, so read a scheme through colors() only.
M.SCHEMES = {
  light = {
    page       = 0xEFF3F7, -- behind everything
    card       = 0xFFFFFF, -- a surface on the page
    raised     = 0xE3E6E8, -- an inactive row or a track
    header     = 0xFFFFFF,
    headerText = 0x131516,
    text       = 0x131516,
    muted      = 0x545C64, -- secondary text
    disabled   = 0x828997,
    accent     = 0x007BC7, -- focus outline, primary button, divider: a fill or a line, not small text
    accentInk  = 0x0065A3, -- the accent where it is text or a glyph on a light surface
    onAccent   = 0xFFFFFF, -- text on an accent fill
    selection  = 0xD9E6EF, -- the selected row
    warning    = 0x855000,
    error      = 0xC5261B,
    onError    = 0xFFFFFF,
    ok         = 0x196C3B,
    onOk       = 0xFFFFFF, -- a mark on an ok fill
    rule       = 0xBCC2C7, -- a quiet divider
    tileOff    = 0xE3E6E8, -- a disabled tile's face: raised's value, so the tile reads greyed out
    tileOffText = 0x545C64, -- a disabled tile's text: muted's value, which reads on that face
  },
  dark = {
    page       = 0x101213,
    card       = 0x181C21,
    raised     = 0x25292C,
    header     = 0x25292C,
    headerText = 0xF4F5F6,
    text       = 0xF4F5F6,
    muted      = 0xACB3B9,
    disabled   = 0x68737D,
    accent     = 0x1798E8,
    accentInk  = 0x61B9EF,
    onAccent   = 0x101518,
    selection  = 0x172A36,
    warning    = 0xF5CA47,
    error      = 0xF37168,
    onError    = 0x101518,
    ok         = 0x66CC90,
    onOk       = 0x101518,
    rule       = 0x33383D,
    tileOff    = 0x101213, -- page's value: an enabled tile is a card, a disabled one an empty frame
    tileOffText = 0x68737D, -- disabled's value, on page where it reads 3:1
  },
}

--- The scheme a stored value stands for: its own name, anything else the default.
function M.name(value)
  if type(value) == "string" and M.SCHEMES[value] ~= nil then return value end
  return M.DEFAULT
end

--- The fade of a disabled tile's icon for a stored value, 0-255.
function M.iconFade(value)
  return M.ICON_FADE[M.name(value)]
end

--- The logo's file for a stored value.
function M.logo(value)
  return _G.rfsuite.paths.core .. "/widgets/dashboard/gfx/" .. M.LOGOS[M.name(value)]
end

-- Which schemes colors() has converted. In place, so no state holds a role twice.
local resolved = {}

--- The scheme's colours as lcd and lvgl take them, by role. Read it, never write to it: the table
--- is shared by every caller in this Lua state.
function M.colors(value)
  local name = M.name(value)
  local colors = M.SCHEMES[name]
  if not resolved[name] then
    for role, rgb in pairs(colors) do
      colors[role] = lcd.RGB(rgb)
    end
    resolved[name] = true
    local Log = _G.rfsuite and _G.rfsuite.require and _G.rfsuite.require("lib/log.lua") or nil
    if Log and type(Log.emit) == "function" then Log.emit("rfsuite.colors", "scheme resolved: " .. name, "debug") end
  end
  return colors
end

return M
