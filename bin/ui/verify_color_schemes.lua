-- Run from the repository root: lua5.3 bin/ui/verify_color_schemes.lua
-- Drive the real lib/color_schemes.lua: both schemes carry the same roles, a role reads on the
-- surfaces it is meant for as the panel draws it (RGB565), and colors() resolves through lcd.RGB.
local checks, failures = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

local rgbCalls = 0
_G.lcd = {
  RGB = function(...)
    rgbCalls = rgbCalls + 1
    assert(select("#", ...) == 1, "lcd.RGB is given one packed number")
    return (select(1, ...)) + 0x1000000
  end
}
_G.rfsuite = nil

local chunk = assert(loadfile("src/rfsuite/lib/color_schemes.lua"))
local Schemes = chunk()

-- WCAG contrast of two 0xRRGGBB values as RGB565 draws them.
local function drawn(rgb)
  local r5, g6, b5 = (rgb >> 19) & 0x1F, (rgb >> 10) & 0x3F, (rgb >> 3) & 0x1F
  return (r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2)
end
local function linear(c)
  c = c / 255
  if c <= 0.03928 then return c / 12.92 end
  return ((c + 0.055) / 1.055) ^ 2.4
end
local function luminance(rgb)
  local r, g, b = drawn(rgb)
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
end
local function contrast(a, b)
  local la, lb = luminance(a), luminance(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end

-- Controls: the measure itself has to read a known pair, and has to fail a pair it must fail.
check(math.abs(contrast(0x000000, 0xFFFFFF) - 21) < 0.01, "control: black on white reads 21")
check(contrast(0x123456, 0x123456) == 1, "control: a colour on itself reads 1")
do
  local r, g, b = drawn(0xF1F2F3)
  check(r == 247 and g == 243 and b == 247, "control: 241,242,243 draws 247,243,247")
end

check(rawget(_G, "M") == nil, "the module leaves no global behind")
check(Schemes.SCHEMES[Schemes.DEFAULT] ~= nil, "the default names a scheme")

-- Both schemes carry exactly these roles, each a whole 0xRRGGBB, and the developer page names them.
-- A role added or removed changes this list, both schemes and the page together.
local ROLES = {
  "page", "card", "raised", "header", "headerText", "text", "muted", "disabled", "accent", "accentInk",
  "onAccent", "selection", "warning", "error", "onError", "ok", "onOk", "rule",
}
local listed = {}
for _, role in ipairs(ROLES) do listed[role] = true end

local names = { "light", "dark" }
for _, name in ipairs(names) do
  local scheme = Schemes.SCHEMES[name]
  check(type(scheme) == "table", name .. ": scheme exists")
  for _, role in ipairs(ROLES) do
    check(scheme[role] ~= nil, name .. ": has role " .. role)
  end
  for role, value in pairs(scheme) do
    check(listed[role] == true, name .. "." .. role .. ": a role this test does not list")
    check(math.type(value) == "integer" and value >= 0 and value <= 0xFFFFFF, name .. "." .. role .. ": a whole 0xRRGGBB")
  end
end

do
  local file = assert(io.open("docs/developer/color-schemes.md", "r"))
  local page = file:read("a")
  file:close()
  for _, role in ipairs(ROLES) do
    check(string.find(page, "`" .. role .. "`", 1, true) ~= nil, "docs/developer/color-schemes.md: names role " .. role)
  end
end

-- Each foreground against each surface it is drawn on; 4.5 for text, 3 for a line or a disabled text.
local PAIRS = {
  { "text", "page", 4.5 }, { "text", "card", 4.5 }, { "text", "raised", 4.5 }, { "text", "selection", 4.5 },
  { "muted", "page", 4.5 }, { "muted", "card", 4.5 }, { "muted", "raised", 4.5 }, { "muted", "selection", 4.5 },
  { "accentInk", "page", 4.5 }, { "accentInk", "card", 4.5 }, { "accentInk", "raised", 4.5 },
  { "accentInk", "selection", 4.5 },
  { "headerText", "header", 4.5 }, { "onAccent", "accent", 4.5 }, { "onError", "error", 4.5 },
  { "onOk", "ok", 4.5 }, { "onAccent", "warning", 4.5 },
  { "warning", "page", 4.5 }, { "warning", "card", 4.5 }, { "error", "page", 4.5 }, { "error", "card", 4.5 },
  { "ok", "page", 4.5 }, { "ok", "card", 4.5 },
  { "disabled", "page", 3 }, { "disabled", "card", 3 },
  { "accent", "page", 3 }, { "accent", "card", 3 }, { "accent", "selection", 3 }, { "accent", "raised", 3 },
  { "warning", "raised", 3 },
  -- A progress bar: the fill on its track, and the empty track on the page.
  { "accent", "rule", 2.4 }, { "rule", "page", 1.4 },
}
for _, name in ipairs(names) do
  local scheme = Schemes.SCHEMES[name]
  for _, pair in ipairs(PAIRS) do
    local value = contrast(scheme[pair[1]], scheme[pair[2]])
    check(value >= pair[3], string.format("%s: %s on %s reads %.2f, needs %.1f", name, pair[1], pair[2], value, pair[3]))
  end
end

-- A meaning colour does not cross over: dark's warning is not legible on the light page.
check(contrast(Schemes.SCHEMES.dark.warning, Schemes.SCHEMES.light.page) < 3, "dark's warning does not read on the light page")

-- The stored value.
check(Schemes.name("dark") == "dark", "name: dark stays dark")
check(Schemes.name("light") == "light", "name: light stays light")
check(Schemes.name(nil) == Schemes.DEFAULT, "name: nothing stored is the default")
check(Schemes.name("neon") == Schemes.DEFAULT, "name: an unknown scheme is the default")
check(Schemes.name(1) == Schemes.DEFAULT, "name: a number is the default")

-- Resolving: every role to its own value, each scheme once. colors() converts in place, so the
-- expected values are copied first.
local function copy(scheme)
  local out = {}
  for role, value in pairs(scheme) do out[role] = value end
  return out
end
local rawDark, rawLight = copy(Schemes.SCHEMES.dark), copy(Schemes.SCHEMES.light)
local roleCount = 0
for _ in pairs(rawDark) do roleCount = roleCount + 1 end
local dark = Schemes.colors("dark")
check(rgbCalls == roleCount, "colors: every role resolved once")
for role, value in pairs(rawDark) do
  check(dark[role] == value + 0x1000000, "colors: dark." .. role .. " holds what lcd.RGB returned for it")
end
check(Schemes.colors("dark") == dark and rgbCalls == roleCount, "colors: the same scheme is not resolved again")
local light = Schemes.colors("light")
check(light ~= dark and rgbCalls == 2 * roleCount, "colors: another scheme is resolved")
for role, value in pairs(rawLight) do
  check(light[role] == value + 0x1000000, "colors: light." .. role .. " holds what lcd.RGB returned for it")
end
check(Schemes.colors("dark") == dark and rgbCalls == 2 * roleCount, "colors: going back resolves nothing again")
check(dark.page == rawDark.page + 0x1000000, "colors: going back keeps the values")
check(Schemes.colors("neon") == light, "colors: an unknown scheme gives the default's colours")

-- With the logger of a running suite present, a resolve is logged once at debug.
do
  local lines = {}
  _G.rfsuite = { require = function(path)
    assert(path == "lib/log.lua", "unexpected module: " .. tostring(path))
    return { emit = function(tag, msg, level) lines[#lines + 1] = tag .. "|" .. msg .. "|" .. level end }
  end }
  local fresh = assert(loadfile("src/rfsuite/lib/color_schemes.lua"))()
  fresh.colors("dark")
  fresh.colors("dark")
  check(#lines == 1 and lines[1] == "rfsuite.colors|scheme resolved: dark|debug", "colors: one debug line per resolve")
  _G.rfsuite = nil
end

print(string.format("verify_color_schemes: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
