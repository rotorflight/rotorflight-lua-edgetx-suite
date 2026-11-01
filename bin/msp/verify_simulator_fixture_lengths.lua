-- Every MSP API module's simulatorResponse must have the length its own parser walks.
--
-- In the simulator tasks/msp/queue.lua hands a module's simulatorResponse to the reply handler as
-- the flight controller's answer, so a fixture that is longer or shorter than the layout shifts or
-- drops fields on every page that reads it. Each module's parse() is run on its own fixture through
-- a proxy that records which bytes it reads:
--   * parse() returns a table (a parser that refuses its own fixture leaves its page with nothing);
--   * no byte past the end is read (the fixture is shorter than the layout);
--   * the last byte is read (a fixture longer than the layout ends in bytes nothing reads);
--   * where the module declares Api.fields, the fixture is at least as long as those fields (a
--     fixture covers the whole layout its module declares, record tables included);
--   * where a parser cannot bound the reply itself, the fixture has the length listed below;
--   * given more bytes than the fixture (zeros, then ones), the parser reads no further than one
--     byte past it (a parser that would go on into an optional section means the fixture leaves
--     that section out);
--   * an empty fixture is listed: an empty reply proves nothing about a layout.
-- A module without a parse() or without a fixture must be listed, so a fixture or parser that goes
-- missing fails here instead of dropping out of the check.
-- What this cannot prove: the length of a reply whose parser takes any number of records, or
-- refuses every longer reply, unless that length is listed below.
-- Offline only: desktop Lua 5.3, no simulator and no flight controller.
--
-- Usage, from the repository root: lua5.3 bin/msp/verify_simulator_fixture_lengths.lua [api dir]

local root = arg[1] or "src/rfsuite/tasks/msp/api/"
if string.sub(root, -1) ~= "/" then root = root .. "/" end

-- Parsers that read a string up to its terminator: the scan ends by reading the byte after the
-- last character (ipairs() past the end, or a zero in a longer reply), so for these one read past
-- the end is how the scan ends, not a missing byte.
local SCAN_TO_TERMINATOR = {
  ["name.lua"] = true,
  ["variant.lua"] = true,
}

-- Fixtures of reads no page sends on a supported board, kept empty on purpose. The exception covers
-- the empty fixture only: once one carries bytes, it is checked like every other.
local NOT_SENT = {
  -- MSP_ADJUSTMENT_RANGES (588 bytes) is the Adjustments page's route below API 12.09 only; from
  -- 12.09 it reads the table in pages, and the suite refuses an older board on connect. The
  -- developer API tester can still send it and shows no parsed result.
  ["adjustment_ranges.lua"] = true,
}

-- Reads whose empty fixture is a valid reply: no mode names.
local EMPTY_REPLY = {
  ["boxnames.lua"] = true,
}

-- Write-only modules: no parse(), and no fixture or the empty reply of a write.
local WRITE_ONLY = {
  ["4wif_esc_fwd_prog.lua"] = true,
  ["acc_calibration.lua"] = true,
  ["arming_disable.lua"] = true,
  ["dataflash_erase.lua"] = true,
  ["eeprom_write.lua"] = true,
  ["reboot.lua"] = true,
  ["servo_override_all.lua"] = true,
  ["set_adjustment_range.lua"] = true,
  ["set_mode_range.lua"] = true,
  ["set_pid_profile.lua"] = true,
}

-- Replies whose parser accepts more than one length, with the length the firmware sends:
-- MSP_TELEMETRY_CONFIG is 12 header bytes and TELEM_SENSOR_SLOT_COUNT (40) sensor slots, and the
-- parser copies the whole buffer; MSP_VTX_CONFIG is 9 bytes, pit_mode_freq and the four VTX table
-- bytes, and the parser stops at the first optional field a reply does not carry; MSP_MODE_RANGES
-- and MSP_MODE_RANGES_EXTRA carry MAX_MODE_ACTIVATION_CONDITION_COUNT (20) records of 4 and 3
-- bytes (the latter after a count byte), and both parsers take as many records as arrive.
local EXPECTED_LENGTH = {
  ["mode_ranges.lua"] = 80,
  ["mode_ranges_extra.lua"] = 61,
  ["telemetry_config.lua"] = 52,
  ["vtx_config.lua"] = 15,
}

-- Modules with a parser and no fixture on purpose: in the simulator such a read ends through its
-- errorHandler. The two *_ini modules stand for settings files, not MSP replies, and return defaults.
local NO_FIXTURE = {
  ["battery_ini.lua"] = true,
  ["board_auto_align.lua"] = true,
  ["esc_sensor_trial.lua"] = true,
  ["flight_stats_ini.lua"] = true,
}

-- Optional sections a fixture leaves out on purpose: the parser reads them when a reply has them.
local OPTIONAL_LEFT_OUT = {
  -- The cyclic and yaw master gains arrive from API 12.10; the simulator answers API_VERSION with 12.09.
  ["pid_profile.lua"] = true,
  -- MSP_RC carries as many channels as the receiver has; the fixture has 16 of up to 18.
  ["rc.lua"] = true,
}

local WIDTH = { U8 = 1, S8 = 1, U16 = 2, S16 = 2, U24 = 3, S24 = 3, U32 = 4, S32 = 4, U64 = 8, S64 = 8 }

local checks, failures = 0, 0
local quiet = false
local function fail(label)
  failures = failures + 1
  if not quiet then print("FAIL " .. label) end
end

local function listModules(path)
  local pipe = io.popen("ls -1 '" .. path .. "' 2>/dev/null")
  if not pipe then error("cannot list " .. path) end
  local names = {}
  for name in pipe:lines() do
    if string.match(name, "%.lua$") then names[#names + 1] = name end
  end
  pipe:close()
  table.sort(names)
  return names
end

-- Runs parse() on the fixture and reports what it read: the result, the highest index read past
-- the end (or nil), and the highest index read within it (0 when none was).
local function trace(parse, fixture)
  local n = #fixture
  local last, past = 0, nil
  local proxy = setmetatable({}, {
    __index = function(_, k)
      if math.type(k) == "integer" then
        if k >= 1 and k <= n then
          if k > last then last = k end
        elseif k > n and (past == nil or k > past) then past = k end
      end
      return fixture[k]
    end,
    __len = function() return n end,
  })
  local ok, result = pcall(parse, proxy)
  return ok, result, past, last
end

-- How far parse() reads when the reply is longer than the fixture: the fixture followed by zeros,
-- then by ones (a zero ends a string or a length-prefixed section early). nil when the parser
-- refuses both, or reads all of what it is given.
local PAD = 64
local function reach(parse, fixture)
  local furthest = nil
  for _, value in ipairs({ 0, 1 }) do
    local longer = {}
    for i = 1, #fixture do longer[i] = fixture[i] end
    for i = #fixture + 1, #fixture + PAD do longer[i] = value end
    local ok, result, _, last = trace(parse, longer)
    if ok and type(result) == "table" and last < #longer and (furthest == nil or last > furthest) then
      furthest = last
    end
  end
  return furthest
end

local function fieldBytes(fields)
  local total = 0
  for _, field in ipairs(fields) do
    local width = WIDTH[field[2] or field.type]
    if width == nil then return nil end
    total = total + width
  end
  return total
end

local function check(name, Api)
  local fixture = Api.simulatorResponse
  local n = #fixture
  checks = checks + 1
  if n == 0 and not EMPTY_REPLY[name] then
    fail(name .. ": simulatorResponse is empty (list the module in EMPTY_REPLY if that is a valid reply)")
    return
  end
  local ok, result, past, last = trace(Api.parse, fixture)
  if not ok then
    fail(name .. ": parse() raises on its own simulatorResponse: " .. tostring(result))
    return
  end
  if type(result) ~= "table" then
    fail(name .. ": parse() refuses its own simulatorResponse (" .. n .. " bytes)")
    return
  end
  if past ~= nil and not (SCAN_TO_TERMINATOR[name] and past == n + 1) then
    fail(name .. ": parse() reads byte " .. past .. " of a " .. n .. "-byte simulatorResponse")
  end
  if last < n then
    fail(name .. ": parse() never reads bytes " .. (last + 1) .. ".." .. n .. " of its simulatorResponse")
  end
  if type(Api.fields) == "table" then
    local need = fieldBytes(Api.fields)
    if need == nil then
      fail(name .. ": Api.fields has a type this check does not know")
    elseif n < need then
      fail(name .. ": simulatorResponse is " .. n .. " bytes, Api.fields declares " .. need)
    end
  end
  local expected = EXPECTED_LENGTH[name]
  if expected ~= nil and n ~= expected then
    fail(name .. ": simulatorResponse is " .. n .. " bytes, the reply is " .. expected)
  end
  -- A parser that refuses a longer reply, or reads all of it, has no section to leave out.
  local further = reach(Api.parse, fixture)
  local allowed = SCAN_TO_TERMINATOR[name] and n + 1 or n
  if further ~= nil and further > allowed and not OPTIONAL_LEFT_OUT[name] then
    fail(name .. ": parse() reads up to byte " .. further .. " of a longer reply; the " .. n
      .. "-byte simulatorResponse leaves that out")
  end
end

-- Controls: each planted mismatch must be flagged, and a matching fixture must not be, or a run of
-- this check proves nothing.
do
  local function parse4(buf)
    return { a = buf[1], b = buf[2], c = buf[3], d = buf[4] }
  end
  local function copyAll(buf)
    local out = {}
    for i = 1, #buf do out[i] = buf[i] end
    return out
  end
  local controls = {
    { "matching", 0, { parse = parse4, simulatorResponse = { 1, 2, 3, 4 } } },
    { "short", 2, { parse = parse4, simulatorResponse = { 1, 2, 3 } } },
    { "long", 1, { parse = parse4, simulatorResponse = { 1, 2, 3, 4, 5 } } },
    { "fields", 1, { parse = parse4, simulatorResponse = { 1, 2, 3, 4 }, fields = { { "a", "U32" }, { "b", "U8" } } } },
    { "refused", 1, { parse = function() return nil end, simulatorResponse = { 1 } } },
    { "optional", 1, { parse = function(buf)
      local out = { a = buf[1], b = buf[2] }
      if #buf >= 4 then out.c = buf[3]; out.d = buf[4] end
      return out
    end, simulatorResponse = { 1, 2 } } },
    { "prefixed", 1, { parse = function(buf)
      local out = { len = buf[1], text = {} }
      if #buf >= 1 + buf[1] then
        for i = 2, 1 + buf[1] do out.text[#out.text + 1] = buf[i] end
      end
      return out
    end, simulatorResponse = { 3 } } },
    { "empty", 1, { parse = function() return {} end, simulatorResponse = {} } },
  }
  local bad = false
  quiet = true
  for _, control in ipairs(controls) do
    local before = failures
    check("control-" .. control[1], control[3])
    if failures - before ~= control[2] then
      bad = true
      quiet = false
      print("FAIL control " .. control[1] .. ": " .. (failures - before) .. " finding(s), expected " .. control[2])
      quiet = true
    end
    failures = before
  end
  EXPECTED_LENGTH["control-copy"] = 4
  local before = failures
  check("control-copy", { parse = copyAll, simulatorResponse = { 1, 2, 3, 4, 5 } })
  if failures - before ~= 1 then
    bad = true
    quiet = false
    print("FAIL control copy: an over-long fixture of a copying parser was not flagged")
  end
  EXPECTED_LENGTH["control-copy"] = nil
  quiet = false
  if bad then os.exit(1) end
  failures, checks = 0, 0
end

local modules = listModules(root)
if #modules == 0 then
  print("FAIL no modules found under " .. root)
  os.exit(1)
end

local writeOnly, noFixture, notSent = 0, 0, 0
for _, name in ipairs(modules) do
  local chunk, err = loadfile(root .. name)
  if not chunk then
    fail(name .. ": does not load: " .. tostring(err))
  else
    local ok, Api = pcall(chunk)
    if not ok then
      fail(name .. ": raises when loaded: " .. tostring(Api))
    elseif type(Api) ~= "table" then
      fail(name .. ": does not return a module table")
    elseif type(Api.parse) ~= "function" then
      local fixture = Api.simulatorResponse
      if WRITE_ONLY[name] and (fixture == nil or (type(fixture) == "table" and #fixture == 0)) then
        writeOnly = writeOnly + 1
      else
        fail(name .. ": has no parse() (list the module in WRITE_ONLY if it only writes)")
      end
    elseif type(Api.simulatorResponse) ~= "table" then
      if NO_FIXTURE[name] then
        noFixture = noFixture + 1
      else
        fail(name .. ": parse() has no simulatorResponse (list the module in NO_FIXTURE if that is on purpose)")
      end
    elseif NOT_SENT[name] and #Api.simulatorResponse == 0 then
      notSent = notSent + 1
    else
      check(name, Api)
    end
  end
end

if failures > 0 then
  print("simulator fixture lengths: " .. failures .. " failure(s) in " .. checks .. " modules")
  os.exit(1)
end
print("simulator fixture lengths: " .. checks .. " modules match their parsers (" .. writeOnly
  .. " write-only, " .. noFixture .. " without a fixture on purpose, " .. notSent .. " read never sent)")
