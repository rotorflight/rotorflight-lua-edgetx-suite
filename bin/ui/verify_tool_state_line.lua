-- The standalone tool's five-second state line (ui/home.lua) ends with what the telemetry decoder in
-- the tool's Lua state did since the last line: `decoder tool, N frames, G gaps`, `decoder elsewhere`,
-- `decoder idle`, or `decoder -` before the decoder has loaded (tasks/events/telemetry_bg/drain.lua,
-- summary). Runs the real tool on the accounting stubs at Log Level INFO and reads the Session Logs ring.
--   lua5.3 bin/ui/verify_tool_state_line.lua
local checks, failures = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail ~= nil and (": " .. tostring(detail)) or ""))
  end
end

local Stubs = assert(loadfile("bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile("bin/accounting/stubs/fc.lua"))()
Stubs.clearCard()
Stubs.install("."); FC.install(Stubs); Stubs.reset(); FC.reset()
Stubs.installTool()

local realPrint = print
_G.print = function() end

local function setLevel(level)
  local r = _G.rfsuite
  r.preferences = r.preferences or {}
  r.preferences.general = r.preferences.general or {}
  r.preferences.general.debug_level = level
end

local Home = assert(loadfile("src/rfsuite/ui/home.lua"))()
Home.init({})
setLevel("info")
_G.rfsuite.log_history = {}
-- 1 500 passes of 10 ticks: about thirty state-line intervals of 500 ticks.
-- One custom telemetry frame per pass (the MCU temperature, sensor 0x10A3), so the tool's decoder has
-- frames to count.
local frameId = 0
for _ = 1, 1500 do
  setLevel("info")
  frameId = (frameId + 1) % 256
  Stubs.pushFrame(0x88, { 0, 0, frameId, 0x10, 0xA3, 40 })
  Stubs.tick()
  Home.run(0)
end
_G.print = realPrint

local lines, withDecoder, first, counted = 0, 0, nil, 0
local history = _G.rfsuite.log_history or {}
for i = 1, #history do
  local e = history[i]
  if e.tag == "rfsuite.ui" and type(e.msg) == "string" and string.find(e.msg, "state: page", 1, true) then
    lines = lines + 1
    first = first or e.msg
    if string.match(e.msg, ", decoder tool, [1-9]%d* frames, %d+ gaps$") then counted = counted + 1 end
    if string.match(e.msg, ", decoder tool, %d+ frames, %d+ gaps$") or string.match(e.msg, ", decoder elsewhere$")
      or string.match(e.msg, ", decoder idle$") or string.match(e.msg, ", decoder %-$") then
      withDecoder = withDecoder + 1
    end
  end
end

check(lines >= 1, "tool state line: written at INFO", lines)
check(counted >= 1, "tool state line: names the tool decoding the frames it was given", first)
check(withDecoder == lines, "tool state line: each ends with the decoder fragment",
  withDecoder .. " of " .. lines .. (first and (": " .. first) or ""))

if failures > 0 then
  print(string.format("tool state line: %d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("OK tool state line: %d checks hold", checks))
