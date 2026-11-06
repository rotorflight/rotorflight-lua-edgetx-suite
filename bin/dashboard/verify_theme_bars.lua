-- Checks the bars Grid, Urban and Deck draw over a press in full screen, offline:
--
--   lua5.3 bin/dashboard/verify_theme_bars.lua
--
-- A reactive `size` on an hline or a vline redraws the line on every pass whether or not the value
-- moved (radio/src/lua/lua_lvgl_widget.cpp, LvglWidgetLineBase::setSize). A rectangle there would
-- take the press unless it is built into the button. So, on every theme, at both frame settings and
-- at the sizes of the bars' two looks:
--
--   no line carries a getter for its size, position or points;
--   the fill is a rectangle in the button's children, on the screen position the zone draws it;
--   its getter gives non-negative integers for every reading, a missing one included;
--   with the frames covered, the covering comes before the fill among the children.
--
-- The accounting stubs supply EdgeTX and the module loader. Exit status: 0 green, 1 failed expectations.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end

local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
Stubs.install(ROOT)
Stubs.reset()

local failures, checks = 0, 0
local function check(ok, what)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. what)
  end
end

local function walk(nodes, visit, parent)
  for _, n in ipairs(nodes) do
    visit(n, parent)
    if type(n.children) == "table" then walk(n.children, visit, n) end
  end
end

local function isLine(n)
  return n.type == "hline" or n.type == "vline" or n.type == "line"
end

-- What a line must not have, however the tree was reached.
local function noReactiveLine(nodes, label)
  local bad = 0
  walk(nodes, function(n)
    if isLine(n) and (type(n.size) == "function" or type(n.pos) == "function" or type(n.pts) == "function") then
      bad = bad + 1
    end
  end)
  check(bad == 0, label .. ": " .. bad .. " line(s) with a getter for their geometry")
end

-- Each fill: the rectangle with a size getter, with its parent. A zone's has no parent button.
local function fills(nodes)
  local out = {}
  walk(nodes, function(n, parent)
    if n.type == "rectangle" and type(n.size) == "function" then out[#out + 1] = { node = n, parent = parent } end
  end)
  return out
end

local function screenPos(fill, insetX, insetY)
  local p = fill.parent
  if not p then return fill.node.x, fill.node.y end
  return fill.node.x + p.x + insetX, fill.node.y + p.y + insetY
end

local function state(values)
  return {
    lq = values.lq, rss1 = values.rss, rss2 = values.rss,
    derived = { TQly = values.tq, link_floor = -120 },
    fuel = values.fuel, fuelTelemetrySeen = values.fuel ~= nil,
    themeConfig = values.config or {},
  }
end

local function ctxFor()
  return { action = function() end, entry = function() end, keys = {} }
end

local READINGS = {
  { name = "missing" },
  { name = "zero", lq = 0, tq = 0, rss = -120, fuel = 0 },
  { name = "half", lq = 50, tq = 50, rss = -85, fuel = 50 },
  { name = "full", lq = 100, tq = 100, rss = -50, fuel = 100 },
  { name = "over", lq = 140, tq = 140, rss = -10, fuel = 140 },
  { name = "fraction", lq = 33.3, tq = 66.6, rss = -77.7, fuel = 12.5 },
}

-- Reads each getter over every reading, on the state it closed over.
local function checkGetters(fillList, st, label)
  for _, r in ipairs(READINGS) do
    st.lq, st.rss1, st.rss2, st.fuel = r.lq, r.rss, r.rss, r.fuel
    st.fuelTelemetrySeen = r.fuel ~= nil
    st.derived.TQly = r.tq
    for i, f in ipairs(fillList) do
      local w, h = f.node.size()
      check(math.type(w) == "integer" and w >= 0 and math.type(h) == "integer" and h > 0,
        label .. " " .. r.name .. " fill " .. i .. ": size " .. tostring(w) .. ", " .. tostring(h))
    end
  end
end

-- The covering's four rectangles have to lie before the first fill in the button's children, on the
-- button's own edges, two pixels wide. `insetX`, `insetY` are the firmware's padding at this screen.
local function checkCovering(fillList, Common, insetX, insetY, label)
  for i, f in ipairs(fillList) do
    local p = f.parent
    check(p and p.type == "button", label .. " fill " .. i .. ": not built into a button")
    if p then
      local expect = {
        { 0, 0, p.w, 2 }, { 0, p.h - 2, p.w, 2 }, { 0, 0, 2, p.h }, { p.w - 2, 0, 2, p.h },
      }
      local covering, at = 0, nil
      for k, child in ipairs(p.children) do
        if child == f.node then at = k break end
        for _, e in ipairs(expect) do
          if child.type == "rectangle" and child.filled and child.color == p.color
            and child.x == e[1] - insetX and child.y == e[2] - insetY and child.w == e[3] and child.h == e[4] then
            covering = covering + 1
          end
        end
      end
      if Common.tapFrames then
        check(covering == 0, label .. " fill " .. i .. ": covering drawn with the frames on")
      else
        check(covering == 4, label .. " fill " .. i .. ": " .. covering .. " of 4 covers on the button's edges before it")
        check(p.cornerRadius == 0, label .. ": a covered button keeps its round corners")
      end
      check(at ~= nil, label .. " fill " .. i .. ": missing from its parent's children")
    end
  end
end

local SIZES = { { name = "outlined", h = 30, font = 2, fontH = 16 }, { name = "plain", h = 14, font = 1, fontH = 12 } }

-- The firmware's padding plus its 2 px frame, per screen class (radio/src/gui/colorlcd/libui/etx_lv_theme.cpp,
-- pad_button; etx_lv_theme.h, LAYOUT_SCALE), written out so a wrong L.buttonInset cannot cancel itself out here.
local SCREENS = { { w = 800, insetX = 10, insetY = 5 }, { w = 480, insetX = 8, insetY = 4 } }

for _, theme in ipairs({ "grid", "urban", "deck" }) do
  local prefix = "widgets/dashboard/themes/" .. theme
  local L = _G.rfsuite.require(prefix .. "/layout.lua")
  local Common = _G.rfsuite.require(prefix .. "/common.lua")
  -- Grid and Urban call it their top bar, Deck its header.
  local topBar = L.topBar or L.header
  assert(type(L) == "table" and type(topBar) == "function", theme .. ": layout.lua did not load")

  for _, screen in ipairs(SCREENS) do
    _G.LCD_W = screen.w
    local insetX, insetY = screen.insetX, screen.insetY
    local gotX, gotY = L.buttonInset()
    check(gotX == insetX and gotY == insetY,
      theme .. " at " .. screen.w .. ": inset " .. gotX .. "," .. gotY .. " against the firmware's " .. insetX .. "," .. insetY)

    for _, size in ipairs(SIZES) do
      for _, frames in ipairs({ "on", "off" }) do
        local label = theme .. " " .. screen.w .. " " .. size.name .. " frames " .. frames
        Common.applyFrames({ tap_frames = frames })

        local st = state({ lq = 80, tq = 80, rss = -70, config = { tap_frames = frames } })
        local full, zone = {}, {}
        topBar(full, st, 0, 0, screen.w, size.h, size.font, size.fontH, ctxFor(), true)
        topBar(zone, st, 0, 0, screen.w, size.h, size.font, size.fontH, nil, true)

        noReactiveLine(full, label)
        local f, z = fills(full), fills(zone)
        check(#f > 0, label .. ": no fill in the full screen bar")
        check(#f == #z, label .. ": " .. #f .. " fills in full screen against " .. #z .. " in the zone")
        for i = 1, math.min(#f, #z) do
          local x, y = screenPos(f[i], insetX, insetY)
          local zx, zy = screenPos(z[i])
          check(x == zx and y == zy, label .. " fill " .. i .. ": at " .. x .. "," .. y .. " against the zone's " .. zx .. "," .. zy)
        end
        checkCovering(f, Common, insetX, insetY, label)
        checkGetters(f, st, label)
      end
    end

    -- Deck's battery strip: the same shape, over its own press, at the foot of the screen.
    if type(L.battStrip) == "function" then
      for _, frames in ipairs({ "on", "off" }) do
        local label = "deck strip " .. screen.w .. " frames " .. frames
        Common.applyFrames({ tap_frames = frames })
        local st = state({ lq = 80, fuel = 60, config = { tap_frames = frames } })
        local g = { sml = 1, smlH = 12 }
        local full, zone = {}, {}
        L.battStrip(full, st, g, 10, 200, screen.w - 20, 16, ctxFor())
        L.battStrip(zone, st, g, 10, 200, screen.w - 20, 16, nil)
        noReactiveLine(full, label)
        local f, z = fills(full), fills(zone)
        check(#f == 1, label .. ": " .. #f .. " fills")
        if f[1] and z[1] then
          local x, y = screenPos(f[1], insetX, insetY)
          check(x == z[1].node.x and y == z[1].node.y, label .. ": fill at " .. x .. "," .. y)
        end
        checkCovering(f, Common, insetX, insetY, label)
        checkGetters(f, st, label)
      end
    end
  end
  Common.applyFrames({ tap_frames = "on" })
end

print(string.format("verify_theme_bars: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
