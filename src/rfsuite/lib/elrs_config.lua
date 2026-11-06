-- Read-only ExpressLRS transmitter-module configuration.
--
-- CRSF parameter replies carry no transaction id. One owner must therefore serialize every
-- parameter conversation in a Lua state; consumers share the completed snapshot below.

local M = {}

if type(_G) == "table" and _G.rfsuite and _G.rfsuite.elrs_config then
  return _G.rfsuite.elrs_config
end

local DEVICE_PING, DEVICE_INFO = 0x28, 0x29
local PARAMETER_ENTRY, PARAMETER_READ = 0x2B, 0x2C
local MODULE, RADIO, ELRS_LUA = 0xEE, 0xEA, 0xEF
local TYPE_TEXT_SELECTION = 9
local PING_RETRY, READ_RETRY = 1.0, 0.5
local MAX_PINGS, MAX_SENDS, MAX_FIELDS, MAX_CHUNKS, MAX_POPS, MAX_FIELD_BYTES = 4, 48, 48, 8, 2, 512
local ELRS_SERIAL = { 0x45, 0x4C, 0x52, 0x53 }

local lease, generation, active, last = nil, 0, nil, nil
local quarantine = false
local quarantineUntil = nil
local powerDecoder = nil
-- Field ids per module, for the life of this Lua state. Ids are given out in registration order,
-- and what is registered depends on the hardware and the build, so the first read of a module walks
-- the list by name; later reads ask for the fields it found directly. The key is the module's name,
-- versions and field count off its device information: the same key is the same numbering.
local idsByModule = {}

local function logRead(level, fmt, ...)
  local Log = type(_G) == "table" and _G.rfsuite and _G.rfsuite.Log
  if Log and type(Log.emitf) == "function" then Log.emitf("rfsuite.elrs", level, fmt, ...) end
end

local function getPowerDecoder()
  if powerDecoder then return powerDecoder end
  if type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.require) == "function" then
    powerDecoder = _G.rfsuite.require("lib/elrs_power.lua")
  elseif type(loadScript) == "function" then
    local chunk = loadScript(_G.rfsuite.paths.core .. "/lib/elrs_power.lua", "t")
    if type(chunk) == "function" then
      local ok, loaded = pcall(chunk)
      if ok then powerDecoder = loaded end
    end
  end
  return powerDecoder
end

function M.currentIdentity()
  local parts = {}
  if type(model) == "table" and type(model.getInfo) == "function" then
    local ok, info = pcall(model.getInfo)
    if ok and type(info) == "table" then
      parts[#parts + 1] = tostring(info.filename or info.name or "")
      parts[#parts + 1] = tostring(info.name or "")
      parts[#parts + 1] = tostring(info.bitmap or "")
    end
  end
  if type(model) == "table" and type(model.getModule) == "function" then
    for index = 0, 1 do
      local ok, module = pcall(model.getModule, index)
      if ok and type(module) == "table" then
        parts[#parts + 1] = tostring(module.Type or module.type or "") .. ":" .. tostring(module.subType or "")
      else
        parts[#parts + 1] = "-"
      end
    end
  end
  return table.concat(parts, "|")
end

local function nowSeconds()
  if type(getTime) == "function" then return getTime() / 100 end
  return 0
end

local function cString(bytes, from)
  local i = from
  while bytes[i] ~= nil and bytes[i] ~= 0 do i = i + 1 end
  if bytes[i] == nil then return nil end
  local chars = {}
  for k = from, i - 1 do chars[#chars + 1] = string.char(bytes[k]) end
  return table.concat(chars), i + 1
end

local function classify(name, options)
  if type(name) ~= "string" then return nil end
  local lower = string.lower(name)
  if lower == "max power" then return "maxPower" end
  if lower == "dynamic" then return "dynamic" end
  if string.find(lower, "packet rate", 1, true) or string.find(lower, "pkt rate", 1, true)
      or string.find(lower, "air rate", 1, true) or string.find(lower, "rf rate", 1, true)
      or lower == "rate" then return "packetRate" end
  if string.find(lower, "telem ratio", 1, true) or string.find(lower, "telemetry ratio", 1, true)
      or string.find(lower, "tlm ratio", 1, true) or lower == "ratio" then return "telemetryRatio" end
  local rate, ratio = false, false
  for i = 1, #(options or {}) do
    local option = string.lower(options[i] or "")
    if string.find(option, "std", 1, true) or string.find(option, "race", 1, true)
        or string.find(option, "1:", 1, true) or string.find(option, "1/", 1, true) then ratio = true end
    if not string.find(option, "ghz", 1, true) and not string.find(option, "mhz", 1, true)
        and (string.find(option, "hz", 1, true) or string.match(option, "^%s*[dfk]%d+")) then rate = true end
  end
  if rate ~= ratio then return rate and "packetRate" or "telemetryRatio" end
  return nil
end

local function parseSelection(bytes)
  local fieldType = bytes[2]
  if type(fieldType) ~= "number" or fieldType % 128 ~= TYPE_TEXT_SELECTION then return nil end
  local name, after = cString(bytes, 3)
  if not name then return nil end
  local optionText, valueAt = cString(bytes, after)
  if not optionText then return nil end
  local value = bytes[valueAt]
  if type(value) ~= "number" then return nil end
  local options = {}
  for option in string.gmatch(optionText .. ";", "([^;]*);") do options[#options + 1] = option end
  local selected = options[value + 1]
  if selected == nil then return nil end
  local unit = cString(bytes, valueAt + 4) or ""
  return { name = name, options = options, selectedIndex = value, selectedLabel = selected, unit = unit }
end

local function identity(data)
  if type(data) ~= "table" or data[2] ~= MODULE then return nil end
  local i = 3
  while data[i] ~= nil and data[i] ~= 0 do i = i + 1 end
  if data[i] == nil then return nil end
  local offset = i + 1
  local count = data[offset + 12]
  if type(count) ~= "number" then return nil end
  for k = 1, 4 do if data[offset + k - 1] ~= ELRS_SERIAL[k] then return false end end
  local chars = {}
  for k = 3, i - 1 do chars[#chars + 1] = string.char(data[k]) end
  local name = table.concat(chars)
  local key = name .. "|" .. table.concat(data, ".", offset + 4, offset + 11) .. "|" .. tostring(count)
  return key, name, count
end

local function finish(st, status, reason, now)
  st.status, st.reason, st.readAt, st.done = status, reason, now, true
  logRead("debug", "read finished: %s, reason %s, %d pings, %d sends", tostring(status), tostring(reason),
    st.pings or 0, st.sent or 0)
  if status == "ready" or status == "unavailable" then
    last = {
      status = status, reason = reason, readAt = now, identity = st.identity,
      moduleIdentity = st.moduleIdentity, moduleName = st.moduleName,
      packetRate = st.values.packetRate, telemetryRatio = st.values.telemetryRatio,
      maxPower = st.values.maxPower, dynamic = st.values.dynamic, fields = st.fields,
    }
  end
  if st.pingAt ~= nil or st.requestAt ~= nil then
    quarantine, quarantineUntil = true, nil
  end
  active = nil
  lease = nil
end

-- Keeps the ids a complete walk found. A walk cut short by the send budget is not complete: a
-- field it did not reach may still exist.
local function remember(st)
  if st.plan then return end
  local ids = {}
  for kind, field in pairs(st.fields) do ids[kind] = field.id end
  if next(ids) then idsByModule[st.moduleIdentity] = ids end
end

-- The kept ids of a module in reading order, or nil.
local function planFor(key)
  local ids = idsByModule[key]
  if not ids then return nil end
  local plan = {}
  for _, id in pairs(ids) do plan[#plan + 1] = id end
  table.sort(plan)
  return plan
end

local function planHeld(st)
  for kind, id in pairs(idsByModule[st.moduleIdentity] or {}) do
    if not st.fields[kind] or st.fields[kind].id ~= id then return false end
  end
  return true
end

local function nextField(st)
  st.chunk, st.expectedRemain, st.requestAt, st.buf = 0, nil, nil, {}
  if st.plan then
    st.planAt = st.planAt + 1
    if st.plan[st.planAt] then st.field = st.plan[st.planAt]; return end
    if planHeld(st) then
      finish(st, next(st.values) and "ready" or "unavailable",
        next(st.values) and "partial" or "no_matching_fields", st.now)
      return
    end
    -- A kept id no longer names the field it named: forget the ids and walk the list again.
    idsByModule[st.moduleIdentity], st.plan, st.field = nil, nil, 1
    return
  end
  st.field = st.field + 1
  if st.field > st.fieldCount or st.field > MAX_FIELDS then
    remember(st)
    finish(st, next(st.values) and "ready" or "unavailable",
      next(st.values) and "partial" or "no_matching_fields", st.now)
  end
end

local function takeField(st)
  local field = parseSelection(st.buf)
  if field then
    local kind = classify(field.name, field.options)
    if kind then
      field.id = st.field
      st.fields[kind] = field
      st.values[kind] = field.selectedLabel
      if kind == "maxPower" then
        local decoder = getPowerDecoder()
        field.milliwatts = decoder and decoder.maxPowerMilliwatts({
          options = field.options, value = field.selectedIndex, unit = field.unit,
        }) or nil
      elseif kind == "dynamic" then
        local decoder = getPowerDecoder()
        if decoder then
          field.enabled = decoder.dynamicOn({ options = field.options, value = field.selectedIndex })
        end
      end
    end
  end
  if st.values.packetRate and st.values.telemetryRatio and st.values.maxPower and st.values.dynamic then
    remember(st)
    finish(st, "ready", nil, st.now)
  else
    nextField(st)
  end
end

local function takeEntry(st, data)
  if data[2] ~= MODULE or data[3] ~= st.field or st.requestAt == nil then return end
  local remain = data[4]
  if type(remain) ~= "number" or remain < 0 or remain >= MAX_CHUNKS then return end
  if st.expectedRemain ~= nil and remain ~= st.expectedRemain then return end
  if st.chunk >= MAX_CHUNKS or #st.buf + (#data - 4) > MAX_FIELD_BYTES then nextField(st); return end
  for i = 5, #data do st.buf[#st.buf + 1] = data[i] end
  if remain > 0 then
    st.chunk, st.expectedRemain, st.requestAt = st.chunk + 1, remain - 1, nil
  else
    st.requestAt = nil
    takeField(st)
  end
end

function M.acquire(owner)
  if type(owner) ~= "string" or owner == "" then return false end
  if quarantine then return false end
  if lease == nil or lease == owner then lease = owner; return true end
  return false
end

function M.release(owner, dirty)
  if lease == owner then
    if dirty then quarantine, quarantineUntil = true, nil end
    lease = nil
  end
end

-- Whether this instance may be unloaded: nobody holds it and no late replies are left to drain.
-- The second value says whether an owner holds it, which is when nobody else may drain.
function M.idle()
  local held = lease ~= nil or active ~= nil
  return not held and not quarantine, held
end

function M.request(identityKey, context)
  context = context or {}
  local owner = context.owner or "standby"
  -- A refused request must not disturb the current owner's transaction or arm its quarantine.
  if active and active.owner ~= owner then return false, "busy" end
  if lease ~= nil and lease ~= owner then return false, "busy" end
  if (active and active.identity ~= identityKey) or (last and last.identity ~= identityKey) then
    M.invalidate(identityKey)
  end
  if active then
    if active.owner == owner then return true, "reading" end
    return false, "busy"
  end
  -- A completed transaction can still have copied replies in another widget manager's RX queue.
  -- Every explicit refresh drains that owner's queue before it sends a discovery ping.
  if context.force then quarantine, quarantineUntil = true, nil end
  if last and last.identity == identityKey and not context.force then return true, "ready" end
  if quarantine then
    if lease ~= nil and lease ~= owner then return false, "busy" end
    lease = owner
  elseif not M.acquire(owner) then return false, "busy" end
  generation = generation + 1
  logRead("trace", "read started for %s, %s", tostring(owner), quarantine and "draining first" or "discovery ping")
  active = {
    owner = owner, identity = identityKey, generation = generation, status = "reading",
    sent = 0, pings = 0, phase = quarantine and "drain" or "ping", pingAt = nil,
    values = {}, fields = {}, buf = {},
  }
  return true, "reading"
end

function M.cancel(owner, reason)
  if active and (owner == nil or active.owner == owner) then
    logRead("trace", "read cancelled: %s", tostring(reason))
    if active.pingAt ~= nil or active.requestAt ~= nil then quarantine, quarantineUntil = true, nil end
    generation = generation + 1
    active = nil
  end
  if owner == nil or lease == owner then lease = nil end
  return reason
end

function M.invalidate(identityKey)
  if identityKey == nil then
    for key in pairs(idsByModule) do idsByModule[key] = nil end
  end
  if identityKey == nil or (last and last.identity ~= identityKey) then last = nil end
  if active and (identityKey == nil or active.identity ~= identityKey) then M.cancel(active.owner, "invalidated") end
end

function M.snapshot(identityKey)
  if active and (identityKey == nil or active.identity == identityKey) then
    return { status = "reading", identity = active.identity, previous = last }
  end
  if last and (identityKey == nil or last.identity == identityKey) then return last end
  return { status = "unavailable", reason = "not_read", identity = identityKey }
end

function M.drain(context)
  if not quarantine then return true, false end
  context = context or {}
  if active and context.owner ~= active.owner then return false, false end
  local crsf = context.crsf
  if type(crsf) ~= "table" or type(crsf.popFrame) ~= "function" then return false, false end
  local now = context.now or nowSeconds()
  if quarantineUntil == nil then quarantineUntil = now + READ_RETRY end
  -- Parameter replies cannot be attributed after an interrupted conversation. Device-info
  -- replies can: leave them for the consumer that sent the discovery ping (for example link rates).
  crsf.popFrame(PARAMETER_ENTRY)
  if now < quarantineUntil then return false, true end
  quarantine, quarantineUntil = false, nil
  return true, true
end

function M.publish(identityKey, snapshot, now)
  if type(snapshot) ~= "table" then return false end
  last = {
    status = snapshot.status or "ready", reason = snapshot.reason,
    readAt = now or nowSeconds(), identity = identityKey,
    moduleIdentity = snapshot.moduleIdentity, moduleName = snapshot.moduleName,
    packetRate = snapshot.packetRate, telemetryRatio = snapshot.telemetryRatio,
    maxPower = snapshot.maxPower, dynamic = snapshot.dynamic,
    fields = snapshot.fields or {},
  }
  return true
end

function M.step(context)
  local st = active
  if not st or st.done then return M.snapshot(context and context.identity) end
  context = context or {}
  if context.owner ~= st.owner then return M.snapshot(context.identity) end
  if context.identity ~= nil and context.identity ~= st.identity then
    M.invalidate(context.identity)
    return M.snapshot(context.identity)
  end
  if context.allow == false then M.cancel(st.owner, "yielded"); return M.snapshot(st.identity) end
  local crsf, push = context.crsf, context.push
  if type(crsf) ~= "table" or type(crsf.popFrame) ~= "function" or type(push) ~= "function" then
    finish(st, "unavailable", "transport", context.now or nowSeconds()); return last
  end
  local now = context.now or nowSeconds()
  st.now = now
  if st.phase == "drain" then
    local drained = M.drain({ owner = st.owner, crsf = crsf, now = now })
    if not drained then return M.snapshot(st.identity) end
    st.phase = "ping"
    -- The drain used this pass's complete pop budget. Start discovery on the next pass.
    return M.snapshot(st.identity)
  end
  if st.phase == "ping" then
    local popped = 0
    while st.pingAt and popped < MAX_POPS do
      popped = popped + 1
      local data = crsf.popFrame(DEVICE_INFO)
      if data == nil then break end
      local key, name, count = identity(data)
      if key == false then finish(st, "unavailable", "not_elrs", now); return last end
      if key then
        st.moduleIdentity, st.moduleName, st.fieldCount = key, name, math.min(count, MAX_FIELDS)
        st.pingAt = nil
        st.plan, st.planAt = planFor(key), 1
        st.field, st.chunk, st.buf, st.phase = st.plan and st.plan[1] or 1, 0, {}, "read"
        st.requestAt, st.expectedRemain = nil, nil
        if st.fieldCount <= 0 then finish(st, "unavailable", "no_fields", now) end
        break
      end
    end
    if st.phase == "ping" and (st.pingAt == nil or now - st.pingAt >= PING_RETRY) then
      -- No device information after every discovery ping: no ELRS module answers on this radio.
      -- A send budget spent on a full output buffer says nothing about the module.
      if st.pings >= MAX_PINGS then finish(st, "unavailable", "no_answer", now); return last end
      if st.sent >= MAX_SENDS then finish(st, "unavailable", "timeout", now); return last end
      st.sent = st.sent + 1
      local ok, queued = pcall(push, DEVICE_PING, { MODULE, RADIO })
      if ok and queued == nil then finish(st, "unavailable", "no_crsf", now); return last end
      if ok and queued then
        st.pings = st.pings + 1
        st.pingAt = now
      end
    end
    return M.snapshot(st.identity)
  end
  local popped = 0
  while not st.done and popped < MAX_POPS do
    popped = popped + 1
    local data = crsf.popFrame(PARAMETER_ENTRY)
    if data == nil then break end
    takeEntry(st, data)
  end
  if st.done then return last end
  if st.requestAt == nil or now - st.requestAt >= READ_RETRY then
    if st.sent >= MAX_SENDS then
      finish(st, next(st.values) and "ready" or "unavailable",
        next(st.values) and "partial_timeout" or "timeout", now)
      return last
    end
    st.sent = st.sent + 1
    local ok, queued = pcall(push, PARAMETER_READ, { MODULE, ELRS_LUA, st.field, st.chunk })
    if ok and queued == nil then finish(st, "unavailable", "no_crsf", now)
    elseif ok and queued then st.requestAt = now end
  end
  return M.snapshot(st.identity)
end

M.classify = classify
M.parseSelection = parseSelection
M.identity = identity
M.limits = {
  pings = MAX_PINGS, sends = MAX_SENDS, fields = MAX_FIELDS,
  chunks = MAX_CHUNKS, pops = MAX_POPS, fieldBytes = MAX_FIELD_BYTES,
}

if type(_G) == "table" then
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.elrs_config = M
end

return M
