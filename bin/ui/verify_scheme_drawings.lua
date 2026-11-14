-- Run from the repository root: lua5.3 bin/ui/verify_scheme_drawings.lua
-- The tool's own drawings read on the scheme's page in both schemes. Drives the real ui/palette.lua
-- over the real lib/color_schemes.lua, and the real Logs graph module for its curve colours:
--   log rows      Session Logs draws error, warn, info and debug rows in four colours (the page's
--                 getLogColor, read here through its palette roles);
--   3D model      the Alignment page's outlines, light and mid faces, boom ring and discs read 3:1 on the
--                 page, its darkest face differs from the page (it is outlined);
--   log curves    the four curves of the Logs graph read 3:1 on the page and stay four colours;
--   tile icons    a page picture with no scheme picture is drawn as it is, not as a blank tile;
--   no literals   no page or tool module under app/ and ui/ draws a radio-theme colour or a fixed
--                 white or black itself (ui/palette.lua maps the roles); the known fallbacks are listed.
local checks, failures = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

-- EdgeTX packs a colour into a number; here lcd.RGB keeps the 0xRRGGBB value readable.
local function packed(r, g, b)
  if g == nil then return r end
  return (r << 16) | (g << 8) | b
end
_G.lcd = { RGB = packed }
_G.YELLOW, _G.CYAN, _G.GREEN, _G.MAGENTA = -1, -2, -3, -4

local Schemes = assert(loadfile("src/rfsuite/lib/color_schemes.lua"))()
_G.rfsuite = {
  paths = { core = "/SCRIPTS/RFSUITE/core" },
  require = function(path)
    if path == "lib/color_schemes.lua" then return Schemes end
    if path == "lib/log.lua" then return { wanted = function() return false end, emit = function() end } end
    error("unexpected module: " .. tostring(path))
  end,
}
local Palette = assert(loadfile("src/rfsuite/ui/palette.lua"))()
local Graph = assert(loadfile("src/rfsuite/app/pages/logs/graph.lua"))()

-- WCAG contrast of two 0xRRGGBB values as an RGB565 panel draws them.
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
check(math.abs(contrast(0x000000, 0xFFFFFF) - 21) < 0.01, "control: black on white reads 21")
check(contrast(0xFFFFFF, 0xEFF3F7) < 1.2, "control: white on the light page reads under 1.2")

-- The roles Session Logs' getLogColor returns, read from the page in the order error, warn, info,
-- and the rest (debug/trace).
local LOG_ROLES = {}
do
  local fh = assert(io.open("src/rfsuite/app/pages/tools/diagnostics/session_logs/page.lua", "r"))
  local src = fh:read("a")
  fh:close()
  local body = string.match(src, "local function getLogColor%(level%)(.-)\nend")
  check(body ~= nil, "log rows: getLogColor is found on the page")
  for role in string.gmatch(body or "", "return Palette%.([%w_]+)") do LOG_ROLES[#LOG_ROLES + 1] = role end
  check(#LOG_ROLES == 4, "log rows: getLogColor returns four roles (" .. table.concat(LOG_ROLES, ",") .. ")")
end

for _, name in ipairs({ "light", "dark" }) do
  check(Palette.apply(name) == name, name .. ": the palette takes the scheme")
  local page = Palette.panel
  check(type(page) == "number", name .. ": the model's backdrop is a colour")

  local levels = {}
  for _, role in ipairs(LOG_ROLES) do levels[#levels + 1] = Palette[role] end
  for i = 1, #levels do
    for j = i + 1, #levels do
      check(levels[i] ~= levels[j], string.format("%s: log levels %d and %d are drawn apart", name, i, j))
    end
  end

  for _, role in ipairs({ "modelLine", "modelFaceLight", "modelFaceMid", "modelAccent", "modelDisc" }) do
    local value = Palette[role]
    check(type(value) == "number" and contrast(value, page) >= 3,
      string.format("%s: %s reads 3:1 on the page (%.2f)", name, role, type(value) == "number" and contrast(value, page) or 0))
  end
  check(type(Palette.modelFaceDark) == "number" and Palette.modelFaceDark ~= page,
    name .. ": the darkest model face is not the page itself")

  local seen = {}
  for k = 1, 4 do
    local c = Graph.getCurveColor(k)
    check(type(c) == "number" and c >= 0, string.format("%s: curve %d is a colour, not the named fallback", name, k))
    if type(c) == "number" and c >= 0 then
      check(contrast(c, page) >= 3, string.format("%s: curve %d reads 3:1 on the page (%.2f)", name, k, contrast(c, page)))
      check(not seen[c], string.format("%s: curve %d has a colour of its own", name, k))
      seen[c] = true
    end
  end
end

-- Tile icons: the scheme picture where it exists, the page's own picture where it does not.
do
  local core = _G.rfsuite.paths.core
  local present = { [core .. "/app/icons/light/setup_mixer_icon.png"] = true }
  _G.fstat = function(path) if present[path] then return { size = 1 } end return nil end
  Palette.apply("light")
  check(Palette.iconPath(core .. "/app/pages/setup/mixer/icon.png") == core .. "/app/icons/light/setup_mixer_icon.png",
    "tile icons: a page picture is drawn from its scheme set")
  check(Palette.iconPath(core .. "/app/pages/setup/newpage/icon.png") == core .. "/app/pages/setup/newpage/icon.png",
    "tile icons: a page picture with no scheme picture is drawn as it is")
  check(Palette.iconPath("/WIDGETS/mine/icon.png") == "/WIDGETS/mine/icon.png", "tile icons: a picture of the pilot's own is drawn as it is")
  _G.fstat = nil
end

-- No literals: a colour of the radio's theme (COLOR_THEME_*) or a fixed WHITE/BLACK drawn by a page
-- does not follow the scheme. Comments are skipped; each allowed site says why.
do
  local ALLOWED = {
    -- a fallback for a palette that is not loaded yet
    ["src/rfsuite/app/pages/helicopter_setup/page.lua"] = 1,
    -- the message on a radio without LVGL, drawn before any scheme can apply
    ["src/rfsuite/ui/home.lua"] = 1,
  }
  local list = assert(io.popen("find src/rfsuite/app src/rfsuite/ui -name '*.lua' | sort"))
  local files = 0
  for path in list:lines() do
    if path ~= "src/rfsuite/ui/palette.lua" then
      files = files + 1
      local fh = assert(io.open(path, "r"))
      local hits, n = {}, 0
      for line in fh:lines() do
        n = n + 1
        local code = string.gsub(line, "%-%-.*$", "")
        for _, word in ipairs({ "COLOR_THEME_[%u%d_]+", "%f[%w_]WHITE%f[^%w_]", "%f[%w_]BLACK%f[^%w_]" }) do
          if string.find(code, word) then hits[#hits + 1] = n; break end
        end
      end
      fh:close()
      check(#hits <= (ALLOWED[path] or 0), string.format("no literals: %s draws a theme or fixed colour at line(s) %s",
        path, table.concat(hits, ",")))
    end
  end
  list:close()
  check(files > 100, "no literals: the census read the tool's modules (" .. files .. ")")
end

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
