-- Checks the gauge and tile fields themes declare, through the exported object entrypoints,
-- offline:
--
--   lua5.3 bin/dashboard/verify_gauge_render.lua
--
-- objects/gauge.lua's renderers are local, so every case goes through Wrapper.render with a box
-- and a state, and reads the node list it returns: the getters a scene hands to lvgl are called
-- the way the reactive sweep calls them. The accounting stubs supply EdgeTX and the module loader.
-- Exit status: 0 green, 1 failed expectations.

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

local Gauge = _G.rfsuite.require("widgets/dashboard/objects/gauge.lua")
local Utils = _G.rfsuite.require("widgets/dashboard/objects/common.lua")
assert(type(Gauge) == "table" and type(Gauge.render) == "function", "objects/gauge.lua did not load")

local RECT = { x = 0, y = 0, w = 200, h = 100 }

local function render(box, state)
  local nodes = {}
  Gauge.render(nodes, RECT, box, state)
  return nodes
end

-- The fill of a bar: the one rectangle whose size is a getter.
local function fillSize(nodes)
  for _, n in ipairs(nodes) do
    if n.type == "rectangle" and type(n.size) == "function" then return n.size() end
  end
end

-- The value label: the first label whose text is a getter.
local function valueText(nodes)
  for _, n in ipairs(nodes) do
    if n.type == "label" and type(n.text) == "function" then return n.text() end
  end
end

local function arcEnd(nodes)
  for _, n in ipairs(nodes) do
    if n.type == "arc" and type(n.endAngle) == "function" then return n.endAngle() end
  end
end

local function flightState(live, max)
  return {
    derived = { rpm = live, esc_temp = live },
    flight = { armed = false, current = {}, last = {
      [Utils.statFields("rpm", "max")] = max,
      [Utils.statFields("esc_temp", "max")] = max,
    } },
  }
end

-- 1. A bar with stattype "max" fills to the flight's maximum, not to the live reading.
do
  local box = { type = "gauge", subtype = "bar", source = "rpm", stattype = "max", min = 0, max = 2000,
    gaugepaddingleft = 0, gaugepaddingright = 0 }
  local w = fillSize(render(box, flightState(500, 1500)))
  check(w == 150, "a max bar fills to the recorded 1500 of 2000 (" .. tostring(w) .. " of 200 px)")
  local live = { type = "gauge", subtype = "bar", source = "rpm", min = 0, max = 2000,
    gaugepaddingleft = 0, gaugepaddingright = 0 }
  w = fillSize(render(live, flightState(500, 1500)))
  check(w == 50, "a bar without stattype fills to the live 500 (" .. tostring(w) .. " px)")
end

-- 2. An arc with stattype "max" sweeps to the flight's maximum.
do
  local box = { type = "gauge", subtype = "arc", source = "rpm", stattype = "max", min = 0, max = 2000,
    arcstart = 0, arcend = 200 }
  local angle = arcEnd(render(box, flightState(500, 1500)))
  check(angle == 150, "a max arc sweeps to the recorded value (" .. tostring(angle) .. ")")
end

-- 3. With Fahrenheit chosen, a temperature bar labels the value in Fahrenheit, as it fills.
do
  _G.rfsuite.preferences = _G.rfsuite.preferences or {}
  _G.rfsuite.preferences.localizations = { temperature_unit = 1 }
  for _, orientation in ipairs({ "horizontal", "vertical" }) do
    local box = { type = "gauge", subtype = "bar", gaugeorientation = orientation, source = "esc_temp",
      stattype = "max", min = 0, max = 150 }
    local text = valueText(render(box, flightState(40, 100)))
    check(text == "212°F", orientation .. " bar labels 100 °C as 212°F (" .. tostring(text) .. ")")
  end
  _G.rfsuite.preferences.localizations = nil
end

-- 4. Paddings larger than the panel leave the bar inside the tile.
do
  local box = { type = "gauge", subtype = "bar", source = "rpm", min = 0, max = 2000,
    gaugepaddingtop = 300, gaugepaddingbottom = 300, gaugepaddingleft = 500, gaugepaddingright = 500 }
  local nodes = render(box, flightState(1000, 1000))
  local inside = true
  for _, n in ipairs(nodes) do
    if n.type == "rectangle" and n.filled then
      if n.x < RECT.x or n.y < RECT.y or n.x + n.w > RECT.x + RECT.w or n.y + n.h > RECT.y + RECT.h
        or n.w < 1 or n.h < 1 then
        inside = false
      end
    end
  end
  check(inside, "a bar with oversized paddings stays inside its tile")
end

-- 5. The tile frame: named colours, and fields given as functions of the box and the state.
do
  local nodes = {}
  Utils.drawContainer(nodes, RECT, { bordercolor = "cyan" }, {})
  check(#nodes == 2 and nodes[2].color ~= WHITE, "bordercolor = \"cyan\" is not drawn white")

  local seenBox, seenState
  local box = { bgcolor = false, rounded = function() return 6 end,
    bordercolor = function(b, s) seenBox, seenState = b, s return RED end,
    borderwidth = function() return 3 end }
  local state = { tag = true }
  nodes = {}
  Utils.drawContainer(nodes, RECT, box, state)
  check(#nodes == 1, "bgcolor = false draws the frame and no fill")
  local frame = nodes[1]
  check(frame and frame.color == RED and frame.thickness == 3 and frame.rounded == 6,
    "functional frame fields are resolved at build")
  check(seenBox == box and seenState == state, "a functional bordercolor is called with the box and the state")
end

print(string.format("%d gauge and tile checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
