-- Run from the repository root: lua5.3 bin/ui/verify_tile_disabled.lua [--self-test]
-- Drive the real ui/tiles.lua: a disabled tile draws its face and text in the palette's disabled-tile
-- roles, and its icon gets the face laid over it at the scheme's fade; an enabled tile, and every tile
-- of a scheme with no fade, gets no such layer; a tile that enables live shows the layer only while it
-- is disabled. --self-test runs the same checks against a tile built with the fade switched off and
-- passes only if they go red.
local selfTest = arg[1] == "--self-test"

local checks, failures = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    if not selfTest then print("FAIL " .. label) end
  end
end

local FACE, OFF_TEXT, TEXT = 0x101, 0x202, 0x303
local palette = {
  tile = FACE, tileMuted = OFF_TEXT, text = TEXT, error = 0x404, ok = 0x505, accentText = 0x606,
  iconFade = 102,
  iconPath = function(file) return "scheme/" .. file end,
}
_G.rfsuite = { palette = palette }
_G.lcd = nil

local Tiles = assert(loadfile("src/rfsuite/ui/tiles.lua"))()
local FADE = 102

local function build(enabled)
  local children = {}
  if selfTest and palette.iconFade == FADE then palette.iconFade = 0 end
  Tiles.append(children, 10, 20, 100, "app/pages/setup/icon.png", "Setup", false, function() end, enabled)
  return children
end
local function find(children, pred)
  local out = {}
  for i, c in ipairs(children) do if pred(c) then out[#out + 1] = { i = i, c = c } end end
  return out
end
local function layers(children)
  return find(children, function(c) return c.type == "rectangle" and c.opacity ~= nil end)
end
local function image(children)
  return find(children, function(c) return c.type == "image" end)[1]
end
local function label(children)
  return find(children, function(c) return c.type == "label" end)[1]
end

-- Control: the fixture has to be able to tell a fade from none.
check(#layers({ { type = "rectangle", opacity = 1 } }) == 1, "control: a rectangle with an opacity is found")
check(#layers({ { type = "rectangle" } }) == 0, "control: a plain rectangle is not")

-- A disabled tile.
do
  local c = build(false)
  local face = find(c, function(x) return x.type == "rectangle" and x.opacity == nil and x.color == FACE end)
  check(#face == 1, "disabled: the face is drawn in the disabled tile's role")
  check(label(c).c.color == OFF_TEXT, "disabled: the text takes the disabled tile's text role")
  local l, img = layers(c), image(c)
  check(#l == 1, "disabled: one fade layer over the icon")
  if #l == 1 then
    local x = l[1].c
    check(x.color == FACE and x.filled == true and x.opacity == 102, "disabled: the layer is the face at the scheme's fade")
    check(x.x == img.c.x and x.y == img.c.y and x.w == img.c.w and x.h == img.c.h, "disabled: the layer covers the icon exactly")
    check(l[1].i > img.i and l[1].i < label(c).i, "disabled: the layer lies over the icon and under the text")
    check(x.visible == nil, "disabled: a fixed tile's layer is always shown")
  end
  check(img.c.file == "scheme/app/pages/setup/icon.png", "disabled: the icon is the scheme's picture")
end

-- An enabled tile.
do
  local c = build(true)
  check(#layers(c) == 0, "enabled: no fade layer")
  check(#find(c, function(x) return x.type == "rectangle" end) == 0, "enabled: no face drawn over the button")
  check(label(c).c.color == TEXT, "enabled: the text takes the text role")
end

-- A tile that enables live.
do
  local on = false
  local c = build(function() return on end)
  local l = layers(c)
  check(#l == 1 and type(l[1].c.visible) == "function", "live: one fade layer, shown by a function")
  if #l == 1 and type(l[1].c.visible) == "function" then
    check(l[1].c.visible() == true, "live: the layer shows while the tile is disabled")
    on = true
    check(l[1].c.visible() == false, "live: the layer hides once the tile enables")
  end
end

-- A scheme with no fade draws no layer.
do
  local saved = palette.iconFade
  palette.iconFade = 0
  check(#layers(build(false)) == 0, "no fade: a disabled tile gets no layer")
  palette.iconFade = nil
  check(#layers(build(false)) == 0, "no fade set: a disabled tile gets no layer")
  palette.iconFade = saved
end

if selfTest then
  print(string.format("verify_tile_disabled --self-test: %d checks, %d failures with the fade off", checks, failures))
  if failures == 0 then
    print("FAIL self-test: the checks stay green with the fade off")
    os.exit(1)
  end
  return
end
print(string.format("verify_tile_disabled: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
