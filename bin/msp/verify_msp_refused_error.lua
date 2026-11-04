-- Run from the repository root: lua5.3 bin/msp/verify_msp_refused_error.lua
-- Exercise the real runtime and Info error reader with controlled transport replies.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function upvalue(fn, wanted)
  local index = 1
  while true do
    local name, value = debug.getupvalue(fn, index)
    if not name then error("missing upvalue: " .. wanted) end
    if name == wanted then return value end
    index = index + 1
  end
end

local function newScenario(language, oneMessagePerCall)
  local core = "src/rfsuite/"
  local radio = "/SCRIPTS/RFSUITE/core/"
  local h = { clock = 1000, rssi = 100, answer = { 0, 12, 8 } }
  _G.__rfsuite_msp_runtime_module = nil
  _G.__rfsuite_msp_service_module = nil
  _G.rfsuite = { session = {}, diagnostics = {} }
  getTime = function() return h.clock end
  getRSSI = function() return h.rssi end
  getValue = function() return 0 end
  lcd = { RGB = function() return 0 end }

  loadScript = function(path)
    assert(string.sub(path, 1, #radio) == radio, "unexpected module path: " .. tostring(path))
    local relative = string.sub(path, #radio + 1)
    if relative == "lib/log.lua" then
      return function()
        return {
          tagged = function() return function() end end,
          emit = function() end,
          emitf = function() end,
          wanted = function() return false end
        }
      end
    elseif relative == "lib/sensors.lua" then
      return function()
        return { isSimulator = function() return false end, getValue = function() return nil end }
      end
    end
    return loadfile(core .. relative)
  end
  assert(loadfile(core .. "lib/require.lua"))()

  h.translations = assert(loadfile(core .. "i18n/" .. language .. ".lua"))()
  local i18n = {}
  function i18n.t(key, fallback)
    local value = h.translations
    for part in string.gmatch(key, "[^.]+") do
      if type(value) ~= "table" then value = nil; break end
      value = value[part]
    end
    if type(value) == "string" then return value end
    return fallback or key
  end
  h.i18n = i18n

  local Runtime = assert(_G.rfsuite.require("tasks/msp/runtime.lua"))
  local queue = { items = {}, held = false, cleared = {} }
  function queue:add(message)
    self.items[#self.items + 1] = message
    return self
  end
  function queue:clear()
    local items = self.items
    self.items = {}
    for _, message in ipairs(items) do
      if message.errorHandler then
        self.cleared[#self.cleared + 1] = message.command
        message.errorHandler(message, "cleared")
      end
    end
  end
  function queue:isProcessed() return #self.items == 0 end
  function queue:processQueue()
    if self.held then return end
    local items
    if oneMessagePerCall then
      -- Keep later requests queued while the reply runs, as the real queue does.
      items = { table.remove(self.items, 1) }
    else
      -- Settle unrelated startup reads in the same tick for the link-state cases.
      items = self.items
      self.items = {}
    end
    for _, message in ipairs(items) do
      if message.command == 1 then
        if h.answer then message.processReply(message, h.answer)
        else message.errorHandler(message, "timeout") end
      end
    end
  end
  h.queue = queue
  h.state = Runtime.getState()
  h.state.initialized = true
  h.state.available = true
  h.state.queue = queue
  h.state.lastConnected = false
  function h.tick(count)
    for _ = 1, (count or 1) do
      h.clock = h.clock + 100
      Runtime.tick()
    end
  end

  -- Reach the page's private reader and state without adding test exports to src/.
  local Info = assert(loadfile(core .. "app/pages/tools/diagnostics/info/page.lua"))()
  h.infoText = upvalue(Info.wakeup, "readRuntimeErrorMessage")
  h.pageState = upvalue(Info.wakeup, "state")
  h.pageState.i18n = i18n
  h.startLiveLoad = upvalue(Info.build, "startLiveLoad")
  h.diagnostics = _G.rfsuite.diagnostics
  h.session = _G.rfsuite.session
  return h
end

local function refusedText(h)
  local format = assert(h.translations.app.pages.diagnostics_info.api_refused, "missing api_refused translation")
  return string.format(format, "12.08")
end

local scenarios = {
  { "refused", function(h, eq)
    h.tick(3)
    eq(h.diagnostics.mspErrorKind, "refused", "error kind")
    eq(type(h.diagnostics.mspLastError) == "string" and h.diagnostics.mspLastError ~= "", true, "error retained")
    eq(h.session.refusedApiVersion, "12.08", "refused version")
    eq(h.infoText(), refusedText(h), "Info refusal text")
  end },
  { "no_reply", function(h, eq)
    h.answer = nil
    h.tick()
    eq(h.diagnostics.mspErrorKind, "no_reply", "error kind")
    local messages = h.translations.app.msp
    eq(h.infoText(), messages.no_reply_message_1 .. "\n" .. messages.no_reply_message_2, "Info no-reply text")
  end },
  { "loss", function(h, eq)
    h.answer = { 0, 12, 9 }
    h.tick(2)
    eq(h.session.fblConnected, true, "supported board connected")
    h.answer = nil
    h.state.pendingVersionRead = true
    h.state.requestBackoffUntil = 0
    h.tick()
    eq(h.diagnostics.mspErrorKind, "no_reply", "error before loss")
    eq(type(h.diagnostics.mspLastError) == "string" and h.diagnostics.mspLastError ~= "", true, "message before loss")
    h.rssi = 0
    h.tick()
    eq(h.diagnostics.mspErrorKind, nil, "error kind cleared")
    eq(h.diagnostics.mspLastError, nil, "message cleared")
    eq(h.infoText(), nil, "Info text cleared")
  end },
  { "stale_refused", function(h, eq)
    h.tick(3)
    eq(h.session.refusedApiVersion, "12.08", "first board refused")
    eq(h.diagnostics.apiSupported, false, "first board unsupported")
    h.rssi = 0
    h.tick()
    h.rssi = 100
    h.answer = { 0, 12, 9 }
    h.tick(3)
    eq(h.session.fblConnected, true, "supported board connected")
    eq(h.diagnostics.mspErrorKind, nil, "error kind cleared")
    eq(h.infoText(), nil, "Info text cleared")
  end },
  { "stale_no_reply", function(h, eq)
    h.answer = nil
    h.tick()
    eq(h.diagnostics.mspErrorKind, "no_reply", "error before reply")
    h.answer = { 0, 12, 9 }
    h.clock = h.state.requestBackoffUntil * 100
    h.tick(3)
    eq(h.session.fblConnected, true, "supported board connected")
    eq(h.diagnostics.mspErrorKind, nil, "error kind cleared")
    eq(h.infoText(), nil, "Info text cleared")
  end },
  { "cleared", function(h, eq)
    h.queue.held = true
    h.tick()
    eq(#h.queue.items, 2, "startup reads held")
    eq(h.queue.items[1].command, 1, "API version read first")
    h.startLiveLoad()
    eq(h.pageState.loading, true, "Info loading")
    eq(#h.queue.items, 6, "four Info reads queued behind startup")
    h.queue.held = false
    h.tick()
    eq(#h.queue.cleared, 4, "four Info error handlers notified")
    eq(h.queue:isProcessed(), true, "refusal clears pending requests")
    eq(h.pageState.errorMessage, nil, "cleared requests do not report load failure")
    eq(h.infoText(), refusedText(h), "Info refusal text")
  end }
}

for _, language in ipairs({ "en", "de" }) do
  for _, scenario in ipairs(scenarios) do
    local label = language .. " " .. scenario[1]
    local function eq(actual, expected, detail) equal(actual, expected, label .. " " .. detail) end
    local ok, err = pcall(function()
      local h = newScenario(language, scenario[1] == "cleared")
      local timeoutKey = "app.pages.diagnostics_info.loading_timeout"
      eq(h.i18n.t(timeoutKey), h.translations.app.pages.diagnostics_info.loading_timeout, "dotted translation lookup")
      eq(h.i18n.t(timeoutKey) ~= timeoutKey, true, "known translation resolved")
      scenario[2](h, eq)
    end)
    eq(ok and "no error" or tostring(err), "no error", "scenario completed")
  end
end

print("MSP refused error: " .. checks .. " assertions, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
