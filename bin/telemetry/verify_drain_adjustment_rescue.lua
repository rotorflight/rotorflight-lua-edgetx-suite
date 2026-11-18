-- Run from the repository root: lua5.3 bin/telemetry/verify_drain_adjustment_rescue.lua
-- Drive the real custom-telemetry drain with hand-made frames and read whether a step's
-- adjustment report survives the widget drain's decode cap:
--   dropped report   14 frames in one pass, the adjustment entry in an old one the cap drops: it is
--                    published (red before the rescue: the pass published nothing for it);
--   newer wins       a dropped report and a newer one among the kept frames: the newer lands last;
--   no report        a backlog without an adjustment entry publishes none (control);
--   value bytes      a value whose bytes equal the adjustment id, in a dropped frame: no report
--                    is invented (the byte search's false hit is sorted out by the walk);
--   not awaited      outside the 3 s after a step the cap drops as before (no search);
--   walk bound       entries that pass the search's check in every newer dropped frame: at most two
--                    are walked, so the report behind them waits for the board's repeat (red without
--                    the bound);
--   standing value   a value whose bytes are the id in every newer dropped frame (a pack at 46.40 V)
--                    does not pass the search's check, so the report is still rescued;
--   rescue cost      instructions of a capped pass with and without a step awaited, printed.
local checks, failures = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and (": " .. detail) or ""))
  end
end

local bit32 = {
  band = function(a, b) return a & b end,
  bor = function(a, b) return a | b end,
  lshift = function(a, n) return (a << n) & 0xFFFFFFFF end,
  rshift = function(a, n) return (a & 0xFFFFFFFF) >> n end,
  extract = function(a, f, w) return (a >> f) & ((1 << w) - 1) end,
  btest = function(a, b) return (a & b) ~= 0 end,
}

local ARM, STAT, ADJ = 0x1202, 0x1230, 0x1220

-- One custom telemetry frame: destination, origin, frame id, then (sensor id, one byte) entries.
-- The adjustment entry is laid out as on the wire: id, a 16-bit function (20 here), a 32-bit value.
local function frame(id, entries)
  local data = { 0, 0, id }
  for _, e in ipairs(entries) do
    data[#data + 1] = (e[1] >> 8) & 0xFF
    data[#data + 1] = e[1] & 0xFF
    if e[1] == ADJ then
      data[#data + 1] = 0; data[#data + 1] = 20
      data[#data + 1] = 0; data[#data + 1] = 0; data[#data + 1] = 0
    end
    data[#data + 1] = e[2]
  end
  return data
end

local function newDrain()
  local h = { published = {}, queued = {}, frames = 0 }
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.bit32 = bit32
  env.rfsuite = { loadMode = "t", paths = dofile("src/rfsuite/lib/paths.lua") }
  env.getValue = function() return nil end
  env.setTelemetryValue = function(id, _, _, value)
    h.published[#h.published + 1] = { id = id, value = value }
  end
  local crsf = { popFrame = function() return table.remove(h.queued, 1) end }
  local function oneByte(data, pos) return data[pos], pos + 1 end
  local decoder = {
    [ARM] = { name = "ARM", dec = oneByte },
    [STAT] = { name = "STAT", dec = oneByte },
    -- The adjustment decoder writes the teller's pair before anything decides about publishing,
    -- as lib/rf2tlm_sensors.lua's decAdjFunc does.
    [ADJ] = { name = "ADJ", dec = function(data, pos)
      local fun, val = data[pos] * 256 + data[pos + 1], data[pos + 5]
      local report = env.rfsuite.adjustmentReport
      if type(report) == "table" then report[1], report[2] = fun, val end
      return val, pos + 6
    end },
    [0x1210] = { name = "OTHR", dec = oneByte },
    [0x2010] = { name = "OTH2", dec = oneByte },
    [0x2000] = { name = "OTH3", dec = oneByte },
  }
  env.loadScript = function(path)
    if string.find(path, "rf2tlm_sensors.lua", 1, true) then return function() return decoder end end
    if string.find(path, "crsf.lua", 1, true) then return function() return crsf end end
    error("unexpected module: " .. path)
  end
  h.env = env
  h.drain = assert(loadfile("src/rfsuite/tasks/events/telemetry_bg/drain.lua", "t", env))()
  function h:push(entries)
    self.frames = self.frames + 1
    self.queued[#self.queued + 1] = frame(self.frames % 256, entries)
  end
  function h:published_values(id)
    local values = {}
    for _, e in ipairs(self.published) do
      if e.id == id then values[#values + 1] = e.value end
    end
    return values
  end
  -- Load both modules (one wakeup each) and end with a pass that empties the queue, so the
  -- frames pushed afterwards count as fresh.
  function h:prime(pass, t)
    self.drain[pass](t); self.drain[pass](t + 0.1); self.drain[pass](t + 0.2)
    return t + 0.2
  end
  return h
end

local function scenario(name, run)
  local ok, err = pcall(run)
  check(ok, name .. " runs without error", ok and nil or tostring(err))
end


local OTHER = 0x1210
local function backlog(h, n, adjAt, adjValue, extra)
  for i = 1, n do
    if i == adjAt then h:push({ { OTHER, 1 }, { ADJ, adjValue } })
    elseif extra and extra[i] then h:push(extra[i])
    else h:push({ { OTHER, i } }) end
  end
end

scenario("dropped_report", function()
  local h = newDrain()
  local t = h:prime("wakeup", 0.1)
  h.env.rfsuite.adjustmentStepAt = math.floor(t * 100)
  backlog(h, 14, 3, 11)
  local popped = h.drain.wakeup(t + 0.1)
  check(popped == 14, "dropped_report: one pass takes the backlog", "popped=" .. tostring(popped))
  local adj = h:published_values(ADJ)
  check(#adj == 1 and adj[1] == 11, "dropped_report: the report in a dropped frame is published",
    "ADJ published " .. #adj .. " time(s)")
  -- Positive control: the cap still holds -- the dropped frames' other values are not published.
  local other = h:published_values(OTHER)
  check(#other <= 4, "dropped_report: the cap still decodes only the newest frames", "OTHER published " .. #other)
end)

scenario("newer_wins", function()
  local h = newDrain()
  local t = h:prime("wakeup", 0.1)
  h.env.rfsuite.adjustmentStepAt = math.floor(t * 100)
  backlog(h, 14, 3, 11, { [13] = { { ADJ, 12 } } })
  h.drain.wakeup(t + 0.1)
  local adj = h:published_values(ADJ)
  check(#adj >= 1 and adj[#adj] == 12, "newer_wins: the newer report lands last",
    table.concat(adj, ","))
end)

scenario("no_report", function()
  local h = newDrain()
  local t = h:prime("wakeup", 0.1)
  h.env.rfsuite.adjustmentStepAt = math.floor(t * 100)
  backlog(h, 14, nil, nil)
  h.drain.wakeup(t + 0.1)
  check(#h:published_values(ADJ) == 0, "no_report: a backlog without a report publishes none")
end)

scenario("value_bytes", function()
  local h = newDrain()
  local t = h:prime("wakeup", 0.1)
  -- A step is awaited, so the search runs and finds the bytes; only the walk can refuse them.
  h.env.rfsuite.adjustmentStepAt = math.floor(t * 100)
  -- (OTHER, 0x12), (OTHER, 0x20): the bytes 0x12 0x20 appear, no adjustment entry exists.
  backlog(h, 14, nil, nil, { [2] = { { OTHER, 0x12 }, { 0x2000, 0x00 }, { OTHER, 1 }, { OTHER, 2 } } })
  h.drain.wakeup(t + 0.1)
  check(#h:published_values(ADJ) == 0, "value_bytes: no report is invented from a value's bytes")
end)

scenario("false_hit_newer", function()
  local h = newDrain()
  local t = h:prime("wakeup", 0.1)
  h.env.rfsuite.adjustmentStepAt = math.floor(t * 100)
  -- An older dropped frame carries the report; a newer dropped frame only has its bytes in values.
  backlog(h, 14, 3, 11, { [6] = { { OTHER, 0x12 }, { 0x2000, 0x00 }, { OTHER, 1 }, { OTHER, 2 } } })
  h.drain.wakeup(t + 0.1)
  local adj = h:published_values(ADJ)
  check(#adj == 1 and adj[1] == 11, "false_hit_newer: a newer look-alike does not hide the older report",
    table.concat(adj, ","))
end)

scenario("walk_bound", function()
  local h = newDrain()
  local t = h:prime("wakeup", 0.1)
  h.env.rfsuite.adjustmentStepAt = math.floor(t * 100)
  -- The report in frame 3; frames 5, 6 and 7, newer and dropped too, each hold the id's bytes as
  -- values. Walked newest first, the two walks the bound allows are spent on 7 and 6.
  local lookalike = { { OTHER, 0x12 }, { 0x2000, 0x00 }, { OTHER, 1 }, { OTHER, 2 } }
  backlog(h, 14, 3, 11, { [5] = lookalike, [6] = lookalike, [7] = lookalike })
  h.drain.wakeup(t + 0.1)
  check(#h:published_values(ADJ) == 0, "walk_bound: three newer look-alikes spend the walks, the older report waits")
  -- Positive control: one newer look-alike leaves the second walk for the report.
  h = newDrain()
  t = h:prime("wakeup", 0.1)
  h.env.rfsuite.adjustmentStepAt = math.floor(t * 100)
  backlog(h, 14, 3, 11, { [7] = lookalike })
  h.drain.wakeup(t + 0.1)
  local adj = h:published_values(ADJ)
  check(#adj == 1 and adj[1] == 11, "walk_bound: one newer look-alike still lets the report through", table.concat(adj, ","))
end)

scenario("standing_value", function()
  local h = newDrain()
  local t = h:prime("wakeup", 0.1)
  h.env.rfsuite.adjustmentStepAt = math.floor(t * 100)
  -- A value standing in every newer dropped frame whose bytes are the id (a pack at 46.40 V): the
  -- byte after it is the next sensor id's high byte, so the search passes it over and the walks
  -- are left for the report.
  local voltage = { { OTHER, 0x12 }, { 0x2010, 0x20 }, { OTHER, 1 } }
  local extra = {}
  for i = 4, 10 do extra[i] = voltage end
  backlog(h, 14, 3, 11, extra)
  h.drain.wakeup(t + 0.1)
  local adj = h:published_values(ADJ)
  check(#adj == 1 and adj[1] == 11, "standing_value: a look-alike value in every newer frame leaves the report its walk",
    table.concat(adj, ","))
end)

scenario("not_awaited", function()
  local h = newDrain()
  local t = h:prime("wakeup", 0.1)
  -- The last step went out 4 s before this pass: outside the window, no search, no rescue.
  h.env.rfsuite.adjustmentStepAt = math.floor((t - 4) * 100)
  backlog(h, 14, 3, 11)
  h.drain.wakeup(t + 0.1)
  check(#h:published_values(ADJ) == 0, "not_awaited: outside a step's window the cap drops as before")
end)

scenario("decode_all_unchanged", function()
  local h = newDrain()
  local t = h:prime("wakeup", 0.1)
  h.env.rfsuite.adjustmentStepAt = math.floor(t * 100)
  backlog(h, 14, 3, 11)
  h.drain.wakeup(t + 0.1, true)
  local adj = h:published_values(ADJ)
  check(#adj == 1 and adj[1] == 11, "decode_all_unchanged: the uncapped drain publishes the report as before")
end)

-- The cost of a capped pass of 15 frames, counted by the VM's instruction hook.
do
  local five = {}
  for i = 1, 15 do five[i] = { { OTHER, i }, { OTHER, i }, { OTHER, i }, { OTHER, i }, { OTHER, i } } end
  local function count(adjAt, awaited)
    local h = newDrain()
    local t = h:prime("wakeup", 0.1)
    if awaited then h.env.rfsuite.adjustmentStepAt = math.floor(t * 100) end
    backlog(h, 15, adjAt, 11, five)
    local n = 0
    debug.sethook(function() n = n + 1 end, "", 1)
    h.drain.wakeup(t + 0.1)
    debug.sethook()
    return n
  end
  print(string.format("capped pass of 15 five-entry frames: %d instructions with no step awaited; while one is: %d without a report, %d with one in a dropped frame",
    count(nil, false), count(nil, true), count(3, true)))
  -- Worst case: the id's bytes as a value in every frame, no report.
  for i = 1, 15 do five[i][1] = { OTHER, 0x12 }; five[i][2] = { 0x2000, 0x00 } end
  print(string.format("  with a look-alike value in every frame: %d instructions while a step is awaited", count(nil, true)))
end

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
