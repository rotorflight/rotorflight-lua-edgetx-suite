local source = string.sub(debug.getinfo(1, "S").source, 2)
local root = string.match(source, "^(.*)[/\\]bin[/\\]tests[/\\]") or "."
_G.rfsuite = {}
_G.rfsuite.paths = dofile(root .. "/src/rfsuite/lib/paths.lua")
-- The provider's log lines, formatted here so a format that does not fit its arguments fails.
local readLines = {}
_G.rfsuite.require = function(path)
  if path == "lib/log.lua" then
    return { emitf = function(_, level, fmt, ...) readLines[#readLines + 1] = level .. ": " .. string.format(fmt, ...) end }
  end
  return assert(loadfile(root .. "/src/rfsuite/" .. path))()
end
local currentFilename = "model01.yml"
model = {
  getInfo = function() return { filename = currentFilename, name = "Model", bitmap = "m.png" } end,
  getModule = function(i) return { Type = i == 0 and 5 or 0, subType = 0 } end,
}
loadScript = function(path)
  local relative = string.match(path, "/SCRIPTS/RFSUITE/core/(.+)$")
  if not relative then return nil end
  return loadfile(root .. "/src/rfsuite/" .. relative)
end
local Config = assert(loadfile(root .. "/src/rfsuite/lib/elrs_config.lua"))()
local function add(out, values) for i = 1, #values do out[#out + 1] = values[i] end end
local function str(value)
  local out = {}
  for i = 1, #value do out[#out + 1] = string.byte(value, i) end
  out[#out + 1] = 0
  return out
end
local function info(count)
  local out = { 0xEA, 0xEE }; add(out, str("ELRS TX"))
  add(out, { 0x45, 0x4C, 0x52, 0x53, 0, 0, 0, 1, 0, 4, 1, 0, count })
  return out
end
local function field(id, name, options, selected, unit)
  local out = { 0xEA, 0xEE, id, 0, 0, 9 }; add(out, str(name)); add(out, str(table.concat(options, ";")))
  add(out, { selected, 0, #options - 1, 0 }); add(out, str(unit or "")); return out
end
local function selectionBytes(value)
  local out = {}
  for i = 5, #value do out[#out + 1] = value[i] end
  return out
end
local function transport()
  local q, sent, stats = {}, {}, { pops = 0 }
  local crsf = { popFrame = function(kind)
    stats.pops = stats.pops + 1
    if not q[kind] or #q[kind] == 0 then return nil end
    return table.remove(q[kind], 1)
  end }
  local function push(kind, payload) sent[#sent + 1] = { kind, payload }; return true end
  local function put(kind, value) q[kind] = q[kind] or {}; q[kind][#q[kind] + 1] = value end
  return crsf, push, put, sent, stats
end
local function drain(crsf)
  Config.drain({ crsf = crsf, now = 0 })
  Config.drain({ crsf = crsf, now = 0.6 })
end
local function read(dynamicLabel)
  Config.invalidate(nil)
  local crsf, push, put, sent = transport(); local identity = Config.currentIdentity()
  assert(Config.request(identity, { owner = "test" }))
  Config.step({ owner = "test", identity = identity, crsf = crsf, push = push, now = 0 })
  assert(#sent == 1 and sent[1][1] == 0x28, "ping sends=" .. tostring(#sent) .. " kind=" .. tostring(sent[1] and sent[1][1]))
  put(0x29, info(4)); Config.step({ owner = "test", identity = identity, crsf = crsf, push = push, now = 0.1 })
  local values = {
    field(1, "Packet Rate", { "D250", "500Hz" }, 1),
    field(2, "Telem Ratio", { "Std", "Race", "Off", "1:16" }, 1),
    field(3, "Max Power", { "25", "1000" }, 1, "mW"),
    field(4, "Dynamic", { "Off", "Dyn", "AUX9" }, dynamicLabel == "Off" and 0 or 2),
  }
  for i = 1, #values do
    Config.step({ owner = "test", identity = identity, crsf = crsf, push = push, now = i })
    put(0x2B, values[i]); Config.step({ owner = "test", identity = identity, crsf = crsf, push = push, now = i + 0.1 })
  end
  local got = Config.snapshot(identity)
  assert(got.status == "ready" and got.packetRate == "500Hz" and got.telemetryRatio == "Race")
  assert(got.maxPower == "1000" and got.fields.maxPower.milliwatts == 1000)
  assert(got.dynamic == dynamicLabel and got.fields.dynamic.enabled == (dynamicLabel ~= "Off"))
end
read("AUX9"); read("Off")
-- After a complete walk the module's field ids are kept: a forced read of the same module asks for
-- the four fields directly, past the fields that are not among them.
do
  Config.invalidate(nil)
  local crsf, push, put, sent = transport(); local identity = Config.currentIdentity()
  local entries = {
    [2] = field(2, "Packet Rate", { "D250", "500Hz" }, 1),
    [4] = field(4, "Telem Ratio", { "Std", "Race" }, 1),
    [6] = field(6, "Max Power", { "25", "1000" }, 1, "mW"),
    [7] = field(7, "Dynamic", { "Off", "Dyn" }, 1),
  }
  local function conversation(force, moved)
    local first = #sent + 1
    assert(Config.request(identity, { owner = "test", force = force }))
    local at = 10 * (#sent + 1)
    if force then drain(crsf) end
    Config.step({ owner = "test", identity = identity, crsf = crsf, push = push, now = at })
    put(0x29, info(8)); Config.step({ owner = "test", identity = identity, crsf = crsf, push = push, now = at + 0.1 })
    -- The module answers every read at once, so a read is never sent twice.
    local answered = #sent
    for i = 1, 40 do
      if Config.snapshot(identity).status ~= "reading" then break end
      for k = answered + 1, #sent do
        if sent[k][1] == 0x2C then
          local id = sent[k][2][3]
          put(0x2B, (moved and moved[id]) or entries[id] or field(id, "Field " .. id, { "A", "B" }, 0))
        end
      end
      answered = #sent
      Config.step({ owner = "test", identity = identity, crsf = crsf, push = push, now = at + i * 0.1 })
    end
    local reads = {}
    for i = first, #sent do
      if sent[i][1] == 0x2C then reads[#reads + 1] = sent[i][2][3] end
    end
    return table.concat(reads, ","), Config.snapshot(identity)
  end
  local walked, got = conversation(false)
  assert(walked == "1,2,3,4,5,6,7" and got.status == "ready" and got.reason == nil,
    "first read did not walk to the last of the four fields: " .. walked)
  local direct
  direct, got = conversation(true)
  assert(direct == "2,4,6,7" and got.status == "ready" and got.maxPower == "1000",
    "forced read of a known module did not ask for its four fields directly: " .. direct)
  -- A kept id that names another field now: the ids are forgotten and the list is walked again,
  -- until the field that is still missing is found; the ids found are kept for the next read.
  local moved = { [2] = field(2, "Antenna Mode", { "Gemini", "Ant 1" }, 0),
    [3] = field(3, "Packet Rate", { "D250", "500Hz" }, 1) }
  local again
  again, got = conversation(true, moved)
  assert(again == "2,4,6,7,1,2,3" and got.status == "ready" and got.packetRate == "500Hz",
    "a moved field was not found by walking the list again: " .. again)
  local kept
  kept, got = conversation(true, moved)
  assert(kept == "3,4,6,7" and got.status == "ready" and got.reason == nil,
    "the ids found by the second walk were not kept: " .. kept)
  Config.invalidate(nil)
end
do
  local hidden = field(1, "Dynamic", { "Off", "Dyn" }, 1)
  hidden[6] = 128 + 9
  local parsed = Config.parseSelection(selectionBytes(hidden))
  assert(parsed and parsed.selectedLabel == "Dyn", "hidden text selection was rejected")
end
do
  local crsf, push, put, sent = transport()
  _G.rfsuite.require = function(path)
    if path == "lib/elrs_config.lua" then return Config end
    if path == "lib/crsf.lua" then return crsf end
    return nil
  end
  crossfireTelemetryPush = push
  local Audio = assert(loadfile(root .. "/src/rfsuite/lib/audio.lua"))()
  local function namedUpvalue(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true
    local index = 1
    while true do
      local name, value = debug.getupvalue(fn, index)
      if not name then return nil end
      if name == wanted then return value end
      if type(value) == "function" then
        local found = namedUpvalue(value, wanted, seen)
        if found then return found end
      end
      index = index + 1
    end
  end
  local audioRead = assert(namedUpvalue(Audio.process, "txPowerModuleRead"))
  local state = {}
  assert(audioRead(state, false, 0) == nil and #sent == 0)
  assert(audioRead(state, false, 0.6) == nil and #sent == 0)
  assert(audioRead(state, false, 0.7) == nil and sent[1][1] == 0x28,
    "audio accepted the previous ready snapshot instead of forcing a connection refresh")
  put(0x29, info(2)); assert(audioRead(state, false, 0.8) == nil)
  assert(audioRead(state, false, 0.9) == nil)
  put(0x2B, field(1, "Max Power", { "100", "1000" }, 1, "mW"))
  assert(audioRead(state, false, 1.0) == nil)
  assert(audioRead(state, false, 1.1) == nil)
  put(0x2B, field(2, "Dynamic", { "Off", "Dyn" }, 0))
  local result = audioRead(state, false, 1.2)
  assert(result and result.done and result.maxMilliwatts == 1000 and result.dynamic == false,
    "audio did not complete the forced refresh with an explicit Off result")

  local function startAudioRead(target, at)
    assert(audioRead(target, false, at) == nil)
    assert(audioRead(target, false, at + 0.6) == nil)
    assert(audioRead(target, false, at + 0.7) == nil)
    assert(Config.snapshot(Config.currentIdentity()).status == "reading")
  end
  local function handoffAfterAbort(crsfTransport, at)
    assert(not Config.acquire("diagnostics"), "aborted audio read bypassed late-frame quarantine")
    Config.drain({ owner = "diagnostics", crsf = crsfTransport, now = at })
    Config.drain({ owner = "diagnostics", crsf = crsfTransport, now = at + 0.6 })
    assert(Config.acquire("diagnostics"), "aborted audio read retained its lease")
    Config.release("diagnostics")
  end

  local armedState = {}
  startAudioRead(armedState, 2)
  assert(audioRead(armedState, true, 2.8) == nil)
  handoffAfterAbort(crsf, 2.8)

  local resetState = {}
  startAudioRead(resetState, 4)
  Audio.resetConnectionState(resetState)
  assert(resetState.txPowerRequested == nil)
  handoffAfterAbort(crsf, 4.8)

  local disabledState = {}
  startAudioRead(disabledState, 6)
  Audio.process({
    audioState = disabledState, state = { zoneH = 320 },
    preferences = { audio_events = { tpwr_alert = false } },
  })
  assert(disabledState.txPowerRequested == nil, "disabling the alert retained the audio owner")
  handoffAfterAbort(crsf, 6.8)

  local chainState = {}
  startAudioRead(chainState, 8)
  _G.rfsuite.modules = {
    ["/SCRIPTS/RFSUITE/core/tasks/events/runtime.lua"] = {
      getOnconnectProgress = function() return { total = 1, done = 0 } end,
    },
  }
  assert(audioRead(chainState, false, 8.8) == nil and chainState.txPowerRequested == nil,
    "connect-chain priority retained the audio owner")
  _G.rfsuite.modules = nil
  handoffAfterAbort(crsf, 8.8)

  local primary, secondary = {}, {}
  startAudioRead(primary, 10)
  assert(audioRead(secondary, false, 10.8) == nil and secondary.txPowerOwner ~= primary.txPowerOwner)
  secondary.txPowerRequested = "integration-model"
  Audio.process({
    audioState = secondary, state = { zoneH = 320 },
    preferences = { audio_events = { tpwr_alert = false } },
  })
  assert(Config.snapshot(Config.currentIdentity()).status == "reading",
    "disabling one audio state cancelled another state's reader")
  audioRead(primary, true, 10.9)
  handoffAfterAbort(crsf, 10.9)

  drain(crsf)
  assert(Config.acquire("diagnostics"), "diagnostics did not acquire the real provider")
  local retained = Config.snapshot(Config.currentIdentity())
  local blocked = {}
  for i = 1, 6 do
    assert(audioRead(blocked, false, 12 + i * 0.1) == nil, "busy audio read returned a result")
  end
  assert(Config.request("different-model", { owner = "hosted-standby", force = true }) == false,
    "foreign identity replaced the diagnostics owner")
  assert(Config.snapshot(Config.currentIdentity()) == retained,
    "a refused foreign identity request invalidated the completed snapshot")
  Config.release("diagnostics")
  local hostedPushes = {}
  local function hostedPush(kind, payload)
    hostedPushes[#hostedPushes + 1] = { kind, payload }
    return true
  end
  assert(Config.request("hosted-model", { owner = "hosted-tool", force = true }),
    "refused audio refresh armed quarantine or retained the lease")
  Config.step({ owner = "hosted-tool", identity = "hosted-model", crsf = crsf, push = hostedPush, now = 13 })
  Config.step({ owner = "hosted-tool", identity = "hosted-model", crsf = crsf, push = hostedPush, now = 13.6 })
  Config.step({ owner = "hosted-tool", identity = "hosted-model", crsf = crsf, push = hostedPush, now = 13.7 })
  put(0x29, info(0))
  Config.step({ owner = "hosted-tool", identity = "hosted-model", crsf = crsf, push = hostedPush, now = 13.8 })
  assert(Config.snapshot("hosted-model").reason == "no_fields",
    "hosted third owner did not complete after diagnostics contention")
end
do
  local Power = assert(loadfile(root .. "/src/rfsuite/lib/elrs_power.lua"))()
  Config.publish(Config.currentIdentity(), {
    status = "ready", maxPower = "1000", dynamic = "Off",
    fields = { maxPower = { milliwatts = 1000 }, dynamic = { enabled = false } },
  }, 14)
  local crsf, push = transport(); local legacy = {}
  Power.step(legacy, crsf, push, 0)
  assert(legacy.done and legacy.maxMilliwatts == 1000 and legacy.dynamic == false)
  assert(Power.FRAME_BUDGET == Config.limits.sends)
end
do
  local identity = Config.currentIdentity(); local crsf, push, put, sent = transport()
  assert(Config.request(identity, { owner = "test" }))
  Config.step({ owner = "test", identity = identity, crsf = crsf, push = push, now = 0 })
  assert(#sent == 0, "a completed snapshot must be reused without traffic")
  assert(Config.request(identity, { owner = "test", force = true }))
  put(0x29, info(2))
  put(0x2B, field(1, "Packet Rate", { "stale" }, 0))
  local refreshing = Config.step({ owner = "test", identity = identity, crsf = crsf, push = push, now = 0 })
  assert(refreshing.status == "reading" and refreshing.previous and refreshing.previous.status == "ready")
  assert(#sent == 0, "a forced refresh accepted a copied reply before draining its RX queue")
  local before = #sent
  local foreign = Config.step({ owner = "intruder", identity = identity, crsf = crsf, push = push, now = 0.1, allow = false })
  assert(foreign.status == "reading" and #sent == before, "a foreign owner changed the active transaction")
  Config.step({ owner = "test", identity = identity, crsf = crsf, push = push, now = 0.6 })
  assert(#sent == 0, "the final drain pass also sent discovery")
  Config.step({ owner = "test", identity = identity, crsf = crsf, push = push, now = 0.7 })
  assert(#sent == 1 and sent[1][1] == 0x28, "a connection-entry refresh did not start fresh discovery")
  Config.cancel("test", "test")
end
do
  Config.invalidate(nil); local crsf, push, _, sent = transport()
  drain(crsf)
  assert(Config.request("timeout", { owner = "test" })); assert(not Config.acquire("diagnostics"))
  for i = 0, 5 do Config.step({ owner = "test", identity = "timeout", crsf = crsf, push = push, now = i }) end
  assert(#sent == Config.limits.pings and Config.snapshot("timeout").status == "unavailable")
  assert(Config.snapshot("timeout").reason == "no_answer", "unanswered discovery did not report no_answer")
end
do
  -- A full output buffer refuses every push: that spends the send budget, not the ping budget,
  -- and ends as a timeout rather than as a missing module.
  Config.invalidate(nil); local crsf = transport(); drain(crsf)
  local refused = 0
  local full = function() refused = refused + 1; return false end
  assert(Config.request("full", { owner = "test" }))
  for i = 1, Config.limits.sends + 2 do Config.step({ owner = "test", identity = "full", crsf = crsf, push = full, now = i * 0.05 }) end
  local got = Config.snapshot("full")
  assert(refused == Config.limits.sends and got.status == "unavailable" and got.reason == "timeout",
    "refused pushes ended as " .. tostring(got.reason) .. " after " .. refused)
end
do
  Config.invalidate(nil); local crsf, push = transport(); drain(crsf)
  currentFilename = "model01.yml"
  local oldIdentity = Config.currentIdentity()
  assert(Config.request(oldIdentity, { owner = "audio", force = true }))
  Config.step({ owner = "audio", identity = oldIdentity, crsf = crsf, push = push, now = 0 })
  currentFilename = "model02.yml"
  local newIdentity = Config.currentIdentity()
  assert(newIdentity ~= oldIdentity and Config.request(newIdentity, { owner = "audio", force = true }))
  local switched = Config.snapshot(newIdentity)
  assert(switched.status == "reading" and switched.previous == nil, "model switch retained the old snapshot")
  Config.cancel("audio", "test_done")
  currentFilename = "model01.yml"
end
do
  Config.invalidate(nil); local crsf, push, put, sent = transport()
  drain(crsf)
  assert(Config.request("partial", { owner = "test" }))
  Config.step({ owner = "test", identity = "partial", crsf = crsf, push = push, now = 0 })
  put(0x29, info(48)); Config.step({ owner = "test", identity = "partial", crsf = crsf, push = push, now = 0.1 })
  Config.step({ owner = "test", identity = "partial", crsf = crsf, push = push, now = 0.2 })
  put(0x2B, field(1, "Packet Rate", { "250Hz" }, 0))
  Config.step({ owner = "test", identity = "partial", crsf = crsf, push = push, now = 0.3 })
  for i = 1, 60 do Config.step({ owner = "test", identity = "partial", crsf = crsf, push = push, now = i }) end
  local got = Config.snapshot("partial")
  assert(got.status == "ready" and got.reason == "partial_timeout" and got.packetRate == "250Hz")
  assert(#sent == Config.limits.sends)
  for i = 1, #sent do assert(sent[i][1] == 0x28 or sent[i][1] == 0x2C, "read-only provider emitted a write") end
end
do
  Config.invalidate(nil); local crsf, push, put = transport()
  drain(crsf)
  assert(Config.request("old", { owner = "test" })); Config.step({ owner = "test", identity = "old", crsf = crsf, push = push, now = 0 })
  put(0x2B, field(1, "Packet Rate", { "250Hz" }, 0)); Config.cancel("test", "model_change")
  assert(Config.request("new", { owner = "test" })); Config.step({ owner = "test", identity = "new", crsf = crsf, push = push, now = 0.1 })
  Config.step({ owner = "test", identity = "new", crsf = crsf, push = push, now = 0.7 })
  assert(Config.snapshot("new").packetRate == nil)
  Config.cancel("test", "test_done")
end
do
  Config.invalidate(nil); local crsf, _, put, _, stats = transport()
  drain(crsf)
  assert(Config.acquire("diagnostics")); Config.release("diagnostics", true)
  put(0x2B, field(1, "Packet Rate", { "stale" }, 0))
  local deviceInfo = info(4)
  put(0x29, deviceInfo)
  assert(not Config.acquire("next"), "dirty diagnostic release bypassed quarantine")
  local before = stats.pops
  assert(not Config.drain({ crsf = crsf, now = 0.1 }))
  assert(stats.pops - before == 1 and stats.pops - before <= Config.limits.pops,
    "drain did not limit itself to the stale parameter reply")
  assert(not Config.acquire("next"), "diagnostic acquired before the drain deadline")
  assert(Config.drain({ crsf = crsf, now = 0.7 }))
  assert(crsf.popFrame(0x2B) == nil and Config.acquire("next"))
  local LinkRates = assert(loadfile(root .. "/src/rfsuite/lib/link_rates.lua"))()
  assert(LinkRates.resolveGeneration({}, crsf, function() error("preserved reply should avoid a ping") end) == 4,
    "quarantine stole link rates' device-info reply")
  Config.release("next")
end
do
  Config.invalidate(nil); local crsf, _, put, sent = transport()
  drain(crsf)
  local refused = 4
  local function congestedPush(kind, payload)
    sent[#sent + 1] = { kind, payload }
    if refused > 0 then refused = refused - 1; return false end
    return true
  end
  assert(Config.request("congested", { owner = "test" }))
  for i = 0, 4 do
    Config.step({ owner = "test", identity = "congested", crsf = crsf, push = congestedPush, now = i })
  end
  assert(#sent == 5 and Config.snapshot("congested").status == "reading",
    "refused discovery pushes consumed the accepted-ping allowance")
  put(0x29, info(0))
  Config.step({ owner = "test", identity = "congested", crsf = crsf, push = congestedPush, now = 4.1 })
  assert(Config.snapshot("congested").reason == "no_fields", "provider did not complete after congestion cleared")
end
do
  Config.invalidate(nil); local crsf, push, put = transport()
  assert(Config.request("chunks", { owner = "test" }))
  Config.step({ owner = "test", identity = "chunks", crsf = crsf, push = push, now = 0 })
  put(0x29, info(1)); Config.step({ owner = "test", identity = "chunks", crsf = crsf, push = push, now = 0.1 })
  Config.step({ owner = "test", identity = "chunks", crsf = crsf, push = push, now = 0.2 })
  local whole = field(1, "Packet Rate", { "250Hz" }, 0)
  local first, second = { 0xEA, 0xEE, 1, 1 }, { 0xEA, 0xEE, 1, 0 }
  for i = 5, 12 do first[#first + 1] = whole[i] end
  for i = 13, #whole do second[#second + 1] = whole[i] end
  put(0x2B, first); Config.step({ owner = "test", identity = "chunks", crsf = crsf, push = push, now = 0.3 })
  put(0x2B, first); put(0x2B, second)
  Config.step({ owner = "test", identity = "chunks", crsf = crsf, push = push, now = 0.4 })
  local got = Config.snapshot("chunks")
  assert(got.status == "ready" and got.packetRate == "250Hz", "duplicate chunk was appended")
end
do
  Config.invalidate(nil); local crsf, push, put = transport()
  assert(Config.request("oversize", { owner = "test" }))
  Config.step({ owner = "test", identity = "oversize", crsf = crsf, push = push, now = 0 })
  put(0x29, info(1)); Config.step({ owner = "test", identity = "oversize", crsf = crsf, push = push, now = 0.1 })
  Config.step({ owner = "test", identity = "oversize", crsf = crsf, push = push, now = 0.2 })
  local huge = { 0xEA, 0xEE, 1, 0 }
  for i = 1, Config.limits.fieldBytes + 1 do huge[#huge + 1] = 65 end
  put(0x2B, huge); Config.step({ owner = "test", identity = "oversize", crsf = crsf, push = push, now = 0.3 })
  assert(Config.snapshot("oversize").status == "unavailable", "oversized field was retained")
end
do
  local started, finished = false, false
  for i = 1, #readLines do
    started = started or string.find(readLines[i], "trace: read started for ", 1, true) ~= nil
    finished = finished or string.find(readLines[i], "debug: read finished: ", 1, true) ~= nil
  end
  assert(started and finished, "a read did not log its start and its finish")
end
print("elrs_config_test: ok")
