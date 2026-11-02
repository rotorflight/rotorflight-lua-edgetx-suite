-- The flight log's per-cell voltage columns, with the cell count the flight record resolved:
--   lua5.3 bin/flight_log/verify_flight_log_cells.lua
--
-- The flight record (tasks/events/telemetry/flight_record.lua) and the disarm task that writes
-- the flight's line (tasks/events/ondisarm/tasks/flight_log.lua) are real; the EdgeTX clock, the
-- sensor reads and the flight log's data core are stubbed, and the data core only keeps the
-- statistics it was handed. A configured cell count of 0 means the flight controller detects the
-- count and reports it in telemetry; the per-cell columns then divide by that count, which the
-- record already read while the craft was armed -- so the sensor is asked no more often than the
-- record asks it on master. Controlled checks, no hardware or timing claim.
-- Exit status: 0 green, 1 failed expectations.

local failures, checks = 0, 0
local function check(label, ok, detail)
  checks = checks + 1
  if ok then
    print("  ok    " .. label)
  else
    failures = failures + 1
    print("FAIL " .. label)
    if detail ~= nil then print("        " .. tostring(detail)) end
  end
end

local PATHS = dofile("src/rfsuite/lib/paths.lua")
local recordChunk = assert(loadfile("src/rfsuite/tasks/events/telemetry/flight_record.lua"))
local disarmChunk = assert(loadfile("src/rfsuite/tasks/events/ondisarm/tasks/flight_log.lua"))

-- luacheck: globals loadScript getTime
--- One connection: a record, a session, sensors that count their reads, and a data core that keeps
--- what the disarm task appends.
local function newWorld(config, sensors)
  local world = { now = 0, reads = {}, appended = nil, sensors = sensors }
  local core = {
    storedBatteryId = function() return nil end,
    appendFlight = function(_, _, _, _, stats)
      world.appended = stats or {}
      return true
    end,
  }
  local modules = {
    ["lib/sensors.lua"] = { getValue = function(name)
      world.reads[name] = (world.reads[name] or 0) + 1
      return world.sensors[name]
    end },
    ["lib/log.lua"] = { emit = function() end },
  }
  _G.getTime = function() return world.now * 100 end
  _G.loadScript = function(path)
    if path == PATHS.core .. "/lib/flight_log.lua" then return function() return core end end
    return nil
  end
  _G.rfsuite = {
    paths = PATHS,
    session = { batteryConfig = config },
    preferences = { flightlog = { enabled = true, min_seconds = 0 } },
    require = function(path) return assert(modules[path], path) end,
  }
  world.session = _G.rfsuite.session
  world.record = recordChunk()

  --- Arm, 25 samples 0.5 s apart, disarm; then the disarm task writes the flight's line.
  function world:fly()
    self.reads, self.appended = {}, nil
    self.session.flightlog = { open = true, startTicks = self.now * 100, startDate = { year = 2026, mon = 11, day = 2 },
      model = "goblin" }
    self.record.open()
    for sample = 1, 25 do
      self.record.wakeup(true, true)
      if sample < 25 then self.now = self.now + 0.5 end
    end
    self.record.close()
    local task = disarmChunk()
    task.reset()
    task.wakeup()
    return self.appended or {}
  end
  return world
end

local function sensors(cellCount)
  return { rpm = 2000, link = 100, current = 10, voltage = 24.6, throttle_percent = 60, governor = 4,
    battery_cell_count = cellCount }
end

local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end

-- The board detects the count (configured 0) and telemetry reports 6.
do
  local world = newWorld({ batteryCellCount = 0, vbatmincellvoltage = 330 }, sensors(6))
  local stats = world:fly()
  check("configured 0, telemetry 6: the per-cell columns divide by 6",
    near(stats.vcel_min, 4.1) and near(stats.vcel_max, 4.1),
    string.format("vcel_min=%s vcel_max=%s", tostring(stats.vcel_min), tostring(stats.vcel_max)))
  check("configured 0, telemetry 6: the record asked the cell-count sensor once, as it does to arm the sag detector",
    world.reads.battery_cell_count == 1, tostring(world.reads.battery_cell_count))
  check("configured 0, telemetry 6: the flight closes with that count", world.session.flight.lastCells == 6,
    tostring(world.session.flight.lastCells))
end

-- The same, with a minimum cell voltage outside 1.00 to 5.00 V: the sag detector stays off, and
-- the count still reaches the per-cell columns.
do
  local world = newWorld({ batteryCellCount = 0, vbatmincellvoltage = 0 }, sensors(6))
  local stats = world:fly()
  check("configured 0, no valid minimum cell voltage: the per-cell columns still divide by 6",
    near(stats.vcel_min, 4.1) and near(stats.vcel_max, 4.1),
    string.format("vcel_min=%s vcel_max=%s", tostring(stats.vcel_min), tostring(stats.vcel_max)))
  check("configured 0, no valid minimum cell voltage: no sag figures", stats.sags == nil and stats.sag_min == nil,
    string.format("sags=%s sag_min=%s", tostring(stats.sags), tostring(stats.sag_min)))
end

-- A configured count answers without the sensor, as before.
do
  local world = newWorld({ batteryCellCount = 6, vbatmincellvoltage = 330 }, sensors(nil))
  local stats = world:fly()
  check("configured 6: the per-cell columns divide by 6", near(stats.vcel_min, 4.1) and near(stats.vcel_max, 4.1),
    string.format("vcel_min=%s vcel_max=%s", tostring(stats.vcel_min), tostring(stats.vcel_max)))
  check("configured 6: the cell-count sensor is not asked", world.reads.battery_cell_count == nil,
    tostring(world.reads.battery_cell_count))
end

-- Neither the board nor telemetry gives a count: the columns stay empty, and so does the next flight
-- after a reconnect.
do
  local world = newWorld({ batteryCellCount = 0, vbatmincellvoltage = 330 }, sensors(nil))
  local stats = world:fly()
  check("no count anywhere: the per-cell columns stay empty", stats.vcel_min == nil and stats.vcel_max == nil,
    string.format("vcel_min=%s vcel_max=%s", tostring(stats.vcel_min), tostring(stats.vcel_max)))
  check("no count anywhere: positive control, the line was written with other statistics", stats.curr_max == 10,
    tostring(stats.curr_max))
end
do
  local world = newWorld({ batteryCellCount = 0, vbatmincellvoltage = 330 }, sensors(6))
  world:fly()
  world.record.reset()
  check("a reconnect forgets the count of the flight before it", world.session.flight.lastCells == nil,
    tostring(world.session.flight.lastCells))
  world.sensors.battery_cell_count = nil
  local stats = world:fly()
  check("the next flight without a count leaves the per-cell columns empty", stats.vcel_min == nil,
    tostring(stats.vcel_min))
end

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
