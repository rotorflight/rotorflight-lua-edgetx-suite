-- Run the real lib/log.lua and lib/log_sink.lua against an in-memory card and a controllable
-- clock: the files of one power-up share one prefix across Lua states, a tool opened twice in a
-- run appends to one file, old runs are pruned and foreign files are not, the step throttle
-- holds per kind, the first name a state is given is the one it keeps, and the resource line
-- reports what the radio offers.
--
-- Usage, from the repository root: lua5.3 bin/tests/verify_log_runs.lua
local checks, failures = 0, 0
local function ok(cond, label)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

-- ── The card ────────────────────────────────────────────────────────────────
local files = {}
local writesTo = {}
local realIo = io
local fakeIo = {}
function fakeIo.open(path, mode)
  if mode == "r" then
    if files[path] == nil then return nil end
    return { path = path, pos = 1 }
  end
  if mode == "w" or files[path] == nil then files[path] = "" end
  writesTo[path] = (writesTo[path] or 0) + 1
  return { path = path, pos = 1 }
end
function fakeIo.write(handle, text)
  files[handle.path] = files[handle.path] .. tostring(text)
  return handle
end
function fakeIo.read(handle, n)
  local text = files[handle.path] or ""
  local chunk = string.sub(text, handle.pos, handle.pos + (n or #text) - 1)
  handle.pos = handle.pos + #chunk
  return chunk
end
function fakeIo.close() return true end
io = fakeIo

function mkdir() return 0 end
function del(path) files[path] = nil; return 0 end
function dir(path)
  local names = {}
  local prefix = path .. "/"
  for name in pairs(files) do
    if string.sub(name, 1, #prefix) == prefix and not string.find(string.sub(name, #prefix + 1), "/", 1, true) then
      names[#names + 1] = string.sub(name, #prefix + 1)
    end
  end
  table.sort(names)
  local i = 0
  return function() i = i + 1; return names[i] end
end

-- ── The clock ───────────────────────────────────────────────────────────────
-- `bootWall` is the wall time of the current power-up, `ticks` the 10 ms ticks since it.
local bootWall, ticks, rtcSkew = 1793260000, 0, 0
function getTime() return ticks end
function getRtcTime() return bootWall + ticks // 100 + rtcSkew end

local DIR = "/SCRIPTS/RFSUITE/user/logs"
files["/SCRIPTS/RFSUITE/core/build.txt"] = "abcdef0123456789-0.2.2\n"

local function expectedPrefix(wall)
  return os.date("!%Y-%m-%d_%H-%M-%S", wall)
end

-- ── A Lua state: its own _G.rfsuite, its own copies of the two modules ─────
local function newState(name, general)
  local root = {
    paths = dofile("src/rfsuite/lib/paths.lua"),
    preferences = { general = general or { log_to_card = true, debug_level = "off" } },
    require = function(path)
      if path == "lib/version.lua" then return { VERSION = "0.2.2" } end
      return nil
    end
  }
  _G.rfsuite = root
  local Log = assert(loadfile("src/rfsuite/lib/log.lua"))()
  local Sink = assert(loadfile("src/rfsuite/lib/log_sink.lua"))()
  if name then Sink.configure(name) end
  return { root = root, Log = Log, Sink = Sink }
end

local function use(st) _G.rfsuite = st.root end

local function countOf(text, pattern)
  local n = 0
  for _ in string.gmatch(text or "", pattern) do n = n + 1 end
  return n
end

-- ── 1. Three states of one power-up land on one prefix ──────────────────────
ticks = 1000
local dash = newState("dashboard")
dash.Log.emit("rfsuite.widget", "dashboard up", "info")
dash.Sink.tick(false)
local p1 = expectedPrefix(bootWall)
local dashFile = files[DIR .. "/" .. p1 .. "_dashboard.log"]
ok(dashFile ~= nil, "the dashboard writes <power-up>_dashboard.log")
ok(dashFile and string.find(dashFile, "state=dashboard run=" .. p1, 1, true) ~= nil, "the header names the state and the run")
ok(dashFile and string.find(dashFile, "build=abcdef0123456789-0.2.2", 1, true) ~= nil, "the header names the build")
ok(dashFile and string.find(dashFile, "dashboard up", 1, true) ~= nil, "the dashboard's line reaches its file")

-- The background decoder starts 2.5 s later and its wall clock reads one second off.
ticks, rtcSkew = 1250, 1
local fn = newState("function")
fn.Log.emit("rfsuite.functions", "decoder up", "info")
fn.Sink.tick(true)
rtcSkew = 0
ok(files[DIR .. "/" .. p1 .. "_function.log"] ~= nil, "the decoder joins the same power-up despite a second of clock skew")

-- ── 2. The tool opened twice in one run appends to one file ─────────────────
ticks = 5000
local tool1 = newState("tool")
tool1.Log.emit("rfsuite.ui", "first visit", "info")
tool1.Sink.tick(false)
tool1.Sink.shutdown()
ticks = 60000
local tool2 = newState("tool")
tool2.Log.emit("rfsuite.ui", "second visit", "info")
tool2.Sink.tick(false)
local toolFile = files[DIR .. "/" .. p1 .. "_tool.log"] or ""
ok(countOf(toolFile, "%-%- rfsuite diagnostics log") == 2, "a second tool session appends under a header of its own")
ok(string.find(toolFile, "first visit", 1, true) and string.find(toolFile, "second visit", 1, true), "both tool visits are in the file")

-- ── 3. The first name a state is given is the one it keeps ──────────────────
ticks = 70000
local hosted = newState("dashboard")
hosted.Sink.configure("tool")
hosted.Log.emit("rfsuite.ui", "hosted tool line", "info")
hosted.Sink.tick(false)
local dashAfter = files[DIR .. "/" .. p1 .. "_dashboard.log"] or ""
ok(string.find(dashAfter, "hosted tool line", 1, true) ~= nil, "a tool opened in the dashboard's state writes to the dashboard's file")
ok(string.find(files[DIR .. "/" .. p1 .. "_tool.log"] or "", "hosted tool line", 1, true) == nil, "and not to a tool file")

-- ── 4. Old runs are pruned, foreign files are not ──────────────────────────
files[DIR .. "/widget_1.log"] = "an older release's file\n"
files[DIR .. "/widget_seq.txt"] = "1"
local runs = { p1 }
for i = 1, 5 do
  bootWall = bootWall + 3600 * i
  ticks = 800
  local st = newState("dashboard", { log_to_card = true, debug_level = "off", log_runs = 3 })
  st.Log.emit("rfsuite.widget", "run " .. i, "info")
  st.Sink.tick(false)
  runs[#runs + 1] = expectedPrefix(bootWall)
end
local present = {}
for name in pairs(files) do
  local prefix = string.match(name, "^" .. DIR .. "/(%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d)_")
  if prefix then present[prefix] = true end
end
local kept = 0
for _ in pairs(present) do kept = kept + 1 end
ok(kept == 3, "three runs are kept when the setting says three (kept " .. kept .. ")")
ok(present[runs[#runs]] and present[runs[#runs - 1]] and present[runs[#runs - 2]], "the newest three are the ones kept")
ok(not present[p1], "the oldest run is gone")
ok(files[DIR .. "/widget_1.log"] ~= nil and files[DIR .. "/widget_seq.txt"] ~= nil, "files outside the scheme are left alone")

-- ── 5. The step throttle holds per kind ────────────────────────────────────
ticks = 900
local stepper = newState("dashboard")
stepper.Sink.step("warm up", true, "warm")
local stepPath = DIR .. "/" .. expectedPrefix(bootWall) .. "_dashboard.step"
local before = writesTo[stepPath] or 0
for i = 1, 100 do
  ticks = ticks + 5
  if i % 2 == 0 then
    stepper.Sink.step("task telemetry:wakeup " .. i, false, "task")
  else
    stepper.Sink.step("job scene " .. i, false, "wgt job")
  end
end
local alternating = (writesTo[stepPath] or 0) - before
ok(alternating <= 42, "two alternating kinds are each throttled (" .. alternating .. " writes in 5 s)")
ok(alternating >= 2, "and each kind is still written")
before = writesTo[stepPath] or 0
for _ = 1, 100 do
  ticks = ticks + 5
  stepper.Sink.step("same", false, "same")
end
local repeated = (writesTo[stepPath] or 0) - before
ok(repeated <= 21, "one repeating kind is throttled (" .. repeated .. " writes in 5 s)")
ok(string.find(files[stepPath] or "", "same", 1, true) ~= nil, "the step file holds the last step")

-- ── 6. The resource line and the recording test ────────────────────────────
local st = newState(nil, { debug_level = "off" })
local Log = st.Log
getAvailableMemory = function() return 1000 end
ok(string.find(Log.resources(), "free - kB", 1, true) ~= nil, "a simulator's constant 1000 bytes is not reported as a reading")
getAvailableMemory = function() return 2048000 end
local line = Log.resources()
ok(string.find(line, "free 2000 kB", 1, true) ~= nil, "free heap is reported in kB")
ok(string.find(line, "cpu", 1, true) == nil and string.find(line, "fps", 1, true) == nil, "no load figures where the radio has none")
getCpuLoad = function() return 41 end
lvgl = { getPerf = function() return 30, 22 end }
line = Log.resources()
ok(string.find(line, ", cpu 41%", 1, true) ~= nil, "the CPU load is reported where the radio has it")
ok(string.find(line, ", ui 30 fps / 22%", 1, true) ~= nil, "the LVGL frame rate and load are reported where the radio has them")
getAvailableMemory, getCpuLoad, lvgl = nil, nil, nil
ok(Log.recording() == false, "nobody records at OFF without a card sink")
Log.attachSink()
ok(Log.recording() == true, "a card sink records at every level")
Log.detachSink()
st.root.preferences.general.debug_level = "info"
ok(Log.recording() == true, "the INFO level records")

io = realIo
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
