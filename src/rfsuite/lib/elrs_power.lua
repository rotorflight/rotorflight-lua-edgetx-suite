-- lib/elrs_power.lua
--
-- The transmitter module's power settings, read over the CRSF parameter protocol: the maximum
-- power the pilot set in the module, and whether dynamic power is on. The TX power alert in
-- lib/audio.lua needs both -- the power as a share of the maximum, and only where the module
-- regulates its power at all -- and neither is on any telemetry frame.
--
-- ExpressLRS registers both inside its "TX Power" folder, by name, in 3.x and 4.x alike
-- (4.1.0 src/lib/tx-crsf/TXModuleParameters.cpp:101-118, 3.6.4 src/lib/LUA/tx_devLUA.cpp:76-90):
--
--   "Max Power"  a text selection of power levels in mW, cut to what the hardware can do
--                (CRSFEndpoint.cpp filterOptions), so the value is an index into the cut list and
--                only the LABEL says the power;
--   "Dynamic"    "Off;Dyn;AUX9;AUX10;AUX11;AUX12". Every choice but Off is dynamic power: an AUX
--                choice adds a switch that boosts to the maximum (4.1.0 src/src/dynpower.cpp:106-113).
--
-- lib/elrs_config.lua owns the one bounded parameter conversation. This module keeps the public
-- power-field decoders and a compatibility step wrapper for older callers.

local PowerRead = {}

local ADDRESS_MODULE = 0xEE
local SERIAL_ELRS = { 0x45, 0x4C, 0x52, 0x53 }  -- 'E' 'L' 'R' 'S'

local TYPE_TEXT_SELECTION = 9

-- Compatibility value; the shared provider owns the actual bound.
PowerRead.FRAME_BUDGET = 48

--- The module's identity and field count from a device-information payload; nil where the payload
--- is not the transmitter module's answer, false where the module is not ExpressLRS.
---
--- The layout is the one lib/link_rates.lua reads (generationFromDeviceInfo): destination, origin,
--- the name and its terminating nought, then serial, hardware and software version, four bytes
--- each, then the parameter count.
function PowerRead.identity(data)
  if type(data) ~= "table" or data[2] ~= ADDRESS_MODULE then return nil end
  local i = 3
  while data[i] ~= nil and data[i] ~= 0 do i = i + 1 end
  if data[i] == nil then return nil end
  local offset = i + 1
  local count = data[offset + 12]
  if type(count) ~= "number" then return nil end
  for k = 1, 4 do
    if data[offset + k - 1] ~= SERIAL_ELRS[k] then return false end
  end
  local name = {}
  for k = 3, i - 1 do name[#name + 1] = string.char(data[k]) end
  local key = table.concat(name) .. "|" .. table.concat(data, ".", offset + 4, offset + 11) .. "|" .. count
  return key, count
end

-- A nought-terminated string out of `bytes` from `from`; the string and the index after its nought,
-- or nil where the nought is not there.
local function cString(bytes, from)
  local i = from
  while bytes[i] ~= nil and bytes[i] ~= 0 do i = i + 1 end
  if bytes[i] == nil then return nil end
  local chars = {}
  for k = from, i - 1 do chars[#chars + 1] = string.char(bytes[k]) end
  return table.concat(chars), i + 1
end

--- Which of the two fields a parameter name is: "max", "dynamic", or nil.
function PowerRead.classify(name)
  if type(name) ~= "string" then return nil end
  local lower = string.lower(name)
  if lower == "max power" then return "max" end
  if lower == "dynamic" then return "dynamic" end
  return nil
end

--- A whole parameter entry, its chunks joined: parent, type, name, and for a text selection the
--- options, the selected index and the unit. `bytes` starts at the parent byte (the payload after
--- destination, origin, field id and chunks remaining). Nil where it is not a whole text selection.
function PowerRead.parseSelection(bytes)
  local fieldType = bytes[2]
  if type(fieldType) ~= "number" or fieldType % 128 ~= TYPE_TEXT_SELECTION then return nil end
  local name, after = cString(bytes, 3)
  if not name then return nil end
  local optionText, valueAt = cString(bytes, after)
  if not optionText then return nil end
  local value = bytes[valueAt]
  if type(value) ~= "number" then return nil end
  -- value, min, max, default, then the unit.
  local unit = cString(bytes, valueAt + 4) or ""
  local options = {}
  for option in string.gmatch(optionText .. ";", "([^;]*);") do options[#options + 1] = option end
  return { name = name, options = options, value = value, unit = unit }
end

--- The maximum power in mW a parsed "Max Power" field selects, or nil.
---
--- Nil where the label is not a plain number: on a dual-band module built for the CE domain the
--- labels are pairs ("25/250", the limit of each band), and which one applies depends on the band
--- the link runs on, which this field does not say.
function PowerRead.maxPowerMilliwatts(field)
  if type(field) ~= "table" or string.lower(field.unit or "") ~= "mw" then return nil end
  local label = field.options[field.value + 1]
  local mw = tonumber(label)
  if mw == nil or mw <= 0 then return nil end
  return mw
end

--- Whether a parsed "Dynamic" field says dynamic power is on, or nil where its options are not
--- the ones this reads.
function PowerRead.dynamicOn(field)
  if type(field) ~= "table" or string.lower(field.options[1] or "") ~= "off" then return nil end
  return field.value > 0
end

local function finish(st)
  st.done = true
  st.phase = nil
end

local function configProvider()
  local config = type(_G) == "table" and _G.rfsuite and _G.rfsuite.elrs_config or nil
  if config or type(loadScript) ~= "function" then return config end
  local chunk = loadScript(_G.rfsuite.paths.core .. "/lib/elrs_config.lua", "t")
  if type(chunk) ~= "function" then return nil end
  local ok, loaded = pcall(chunk)
  if ok then return loaded end
  return nil
end

--- Drive one conversation one step. `st` is the caller's table for one connection; `crsf` is the
--- frame multiplexer (lib/crsf.lua) and `push` is crossfireTelemetryPush. When `st.done` is set the
--- results stand on it: `maxMilliwatts` (number or nil) and `dynamic` (true, false or nil), nil
--- meaning not known. Every frame this sends goes out in place of one RC channels frame, so it
--- sends at most one per call, and a caller calls it only while the model is disarmed.
function PowerRead.step(st, crsf, push, now)
  if st.done then return end
  local config = configProvider()
  if not config then finish(st); return end
  local identityKey = config.currentIdentity()
  local accepted = config.request(identityKey, { owner = "legacy_power" })
  if not accepted then return end
  local snapshot = config.step({
    owner = "legacy_power", identity = identityKey, crsf = crsf, push = push, now = now,
  })
  if snapshot and snapshot.status ~= "reading" then
    local max = snapshot.fields and snapshot.fields.maxPower
    local dynamic = snapshot.fields and snapshot.fields.dynamic
    local dynamicValue = nil
    if dynamic then dynamicValue = dynamic.enabled end
    st.maxMilliwatts = max and max.milliwatts or nil
    st.dynamic = dynamicValue
    finish(st)
  end
end

--- Forget the shared module snapshot and stop an in-flight legacy read.
function PowerRead.forget()
  local config = configProvider()
  if config then config.invalidate(nil) end
end

return PowerRead
