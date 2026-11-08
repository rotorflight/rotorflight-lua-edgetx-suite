-- Run the real ESC pages with recorded MSP requests and the APIs' simulator replies.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = copy(v) end
  return result
end

local function same(actual, expected)
  if type(actual) ~= "table" or type(expected) ~= "table" then return actual == expected end
  for k, v in pairs(expected) do if not same(actual[k], v) then return false end end
  for k in pairs(actual) do if expected[k] == nil then return false end end
  return true
end

local base = "app/pages/setup/esc_motors/esc_tools/escmfg/"
local function newPage(family, apiName)
  local apiPath = "tasks/msp/api/esc_parameters_" .. apiName .. ".lua"
  local api = assert(loadfile("src/rfsuite/" .. apiPath))()
  local queue = { entries = {} }
  function queue:add(entry) self.entries[#self.entries + 1] = entry end
  local remembers, forgets, rebuilds = {}, {}, 0
  local modules = {
    ["app/pages/settings/common.lua"] = {
      pageT = function() return function(_, _, fallback) return fallback end end,
      resetPageState = function(ui) ui.loaded = false; ui.dirty = false; ui.runtime = nil end
    },
    ["ui/controls.lua"] = {},
    ["ui/loading_overlay.lua"] = {},
    ["ui/confirm_dialog.lua"] = {},
    ["tasks/msp/runtime.lua"] = { getState = function() return { queue = queue } end },
    [apiPath] = api,
    [base .. family .. "/init.lua"] = {},
    ["app/pages/setup/esc_motors/esc_tools/esc_current_limit.lua"] = {
      remember = function(session, amps, source)
        remembers[#remembers + 1] = { session = session, amps = amps, source = source }
      end,
      forget = function(session, source)
        forgets[#forgets + 1] = { session = session, source = source }
      end
    }
  }
  _G.rfsuite = { palette = {}, session = {} }
  _G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")
  function loadScript(path)
    local relative = string.match(path, "/SCRIPTS/RFSUITE/core/(.+)$")
    assert(modules[relative], "unexpected module: " .. tostring(path))
    return function() return modules[relative] end
  end
  local page = assert(loadfile("src/rfsuite/" .. base .. family .. "/page.lua"))()
  -- Inspect the module's state without adding a test-only export to the page.
  local ui
  for i = 1, 20 do
    local name, value = debug.getupvalue(page.hasUnsavedChanges, i)
    if name == "ui" then ui = value; break end
    if not name then break end
  end
  assert(ui, "page state not found")
  local ctx = { requestRebuild = function() rebuilds = rebuilds + 1 end }
  page.wakeup(ctx)
  local function snapshot()
    return copy({ ui = ui, session = _G.rfsuite.session, queued = #queue.entries,
      remembers = #remembers, rebuilds = rebuilds })
  end
  return { page = page, ui = ui, api = api, queue = queue, ctx = ctx,
    remembers = remembers, forgets = forgets, snapshot = snapshot }
end

local function answer(entry, bytes) entry.processReply(entry, bytes) end
local function readInitial(h)
  local entry = assert(h.queue.entries[1], "initial read missing")
  answer(entry, h.api.simulatorResponse)
end

for _, spec in ipairs({ { "flrtr", "flyrotor", "cell_count" }, { "yge", "yge", "current_limit" } }) do
  local family, apiName, field = table.unpack(spec)
  local function eq(actual, expected, label) equal(actual, expected, family .. " " .. label) end
  local h = newPage(family, apiName)
  local initial = h.queue.entries[1]
  eq(initial.command, h.api.command, "initial read command")
  eq(initial.retryOnErrorReply, nil, "initial read has no error-reply retry")
  eq(h.ui.loading, true, "initial read shows loading")
  readInitial(h)
  h.page.onReload(h.ctx)
  local manual = h.queue.entries[2]
  eq(manual.command, h.api.command, "manual read command")
  eq(manual.retryOnErrorReply, nil, "manual read has no error-reply retry")
  answer(manual, h.api.simulatorResponse)

  local parsed = assert(h.api.parse(h.api.simulatorResponse))
  h.ui.config[field] = parsed[field] + 1
  h.ui.dirty = true
  eq(h.page.onSave(h.ctx), true, "save accepted after read")
  local write = h.queue.entries[3]
  eq(write.command, h.api.writeCommand, "save queues write command")
  eq(write.isWrite, true, "save classified as write")
  eq(assert(h.api.parse(write.payload))[field], parsed[field] + 1, "write carries edited value")
  local rememberedBefore = #h.remembers
  answer(write, {})
  eq(#h.queue.entries, 4, "post-save read queued next")
  local readback = h.queue.entries[4]
  if readback then
    eq(readback.command, h.api.command, "post-save read command")
    eq(readback.retryOnErrorReply, true, "post-save read retries error replies")
    eq(h.ui.loading, false, "post-save read has no loading overlay")
    eq(h.ui.saving, false, "write success clears saving")
    eq(h.ui.dirty, false, "write success clears dirty")
    eq(h.ui.progress, 100, "post-save read keeps completed progress")
    eq(h.ui.runtime.readPending, true, "post-save read pending")
    if family == "flrtr" then
      eq(h.ui.runtime.escReadComplete, false, "post-save read clears read-complete gate")
    else
      eq(h.ui.runtime.escReadComplete, false, "post-save read clears read-complete gate")
      eq(h.ui.parsedCache, nil, "post-save read clears cached-block gate")
      eq(#h.remembers, rememberedBefore, "write success does not remember unconfirmed limit")
    end
    eq(h.page.onSave(h.ctx), false, "save refused until read-back arrives")
    eq(#h.queue.entries, 4, "pending read-back prevents another write")
    answer(readback, h.api.simulatorResponse)
    eq(h.ui.config[field], parsed[field], "read-back replaces edited value with reply")
    eq(h.ui.runtime.readPending, false, "read-back clears pending")
    if family == "yge" then
      eq(h.ui.runtime.escReadComplete, true, "read-back sets read-complete gate")
      eq(h.ui.parsedCache ~= nil, true, "read-back restores cached-block gate")
      eq(#h.remembers, rememberedBefore + 1, "read-back remembers current limit")
      local remembered = h.remembers[#h.remembers]
      eq(remembered.session, _G.rfsuite.session, "remember uses current session")
      eq(remembered.amps, parsed.current_limit / 100, "remember uses read-back amps")
      eq(remembered.source, "yge", "remember uses YGE source")
      eq(#h.forgets, 0, "a real limit forgets nothing")

      -- A read-back of no limit forgets instead of remembering, and one too short to carry the
      -- field does neither, though its parse reads the missing field as 0.
      local function readBack(reply)
        h.page.onReload(h.ctx)
        answer(h.queue.entries[#h.queue.entries], reply)
      end
      local rememberedNow = #h.remembers
      local zero = { table.unpack(h.api.simulatorResponse) }
      zero[57], zero[58] = 0, 0
      readBack(zero)
      eq(h.ui.config.current_limit, 0, "a reported 0 is what the page holds")
      eq(#h.forgets, 1, "a reported 0 forgets")
      eq(h.forgets[1].source, "yge", "forget uses YGE source")
      eq(#h.remembers, rememberedNow, "a reported 0 is not remembered")
      readBack({ table.unpack(h.api.simulatorResponse, 1, 56) })
      eq(#h.forgets, 1, "a block too short to carry the limit forgets nothing")
      eq(#h.remembers, rememberedNow, "a block too short to carry the limit remembers nothing")
    end
    eq(h.page.onSave(h.ctx), true, "save accepted after read-back")
  end

  if family == "yge" then
    h = newPage(family, apiName)
    readInitial(h)
    eq(h.ui.parsedCache ~= nil, true, "focused gate starts with cached block")
    eq(h.ui.runtime.escReadComplete, true, "focused gate starts read-complete")
    -- Inject an inconsistent state: Reload clears the block as it clears the flag,
    -- so the normal read lifecycle cannot isolate the flag's write gate.
    h.ui.runtime.escReadComplete = false
    eq(h.page.onSave(h.ctx), false, "save refused with cached block but incomplete read")
    eq(#h.queue.entries, 1, "incomplete read prevents write despite cached block")
    eq(h.ui.parsedCache ~= nil, true, "refused save retains cached block")
    h.ui.runtime.escReadComplete = true
    eq(h.page.onSave(h.ctx), true, "save accepted with same block after read-complete restored")
    eq(#h.queue.entries, 2, "complete read permits write with same cached block")
  end

  -- Keep dependencies loaded here: a nil runtime alone must prevent every side effect.
  for _, kind in ipairs({ "write reply", "write error", "read reply", "read error" }) do
    h = newPage(family, apiName)
    local entry = h.queue.entries[1]
    if string.match(kind, "^write") then
      readInitial(h)
      assert(h.page.onSave(h.ctx))
      entry = h.queue.entries[2]
    end
    h.ui.runtime = nil
    local before = h.snapshot()
    local ok = pcall(function()
      if string.match(kind, "error$") then entry.errorHandler(entry)
      else answer(entry, string.match(kind, "^read") and h.api.simulatorResponse or {}) end
    end)
    eq(ok, true, "late " .. kind .. " does not raise")
    eq(same(h.snapshot(), before), true, "late " .. kind .. " changes nothing")
  end

  -- Closing also releases the API module; callbacks must return before using it.
  for _, kind in ipairs({ "read reply", "read error" }) do
    h = newPage(family, apiName)
    local entry = h.queue.entries[1]
    h.page.onClose()
    eq(h.ui.runtime, nil, "close releases runtime")
    local before = h.snapshot()
    local ok = pcall(function()
      if kind == "read error" then entry.errorHandler(entry)
      else answer(entry, h.api.simulatorResponse) end
    end)
    eq(ok, true, "closed-page " .. kind .. " does not raise")
    eq(same(h.snapshot(), before), true, "closed-page " .. kind .. " changes nothing")
  end
end

if failures > 0 then
  error("ESC read-back after save: " .. failures .. " of " .. checks .. " assertions failed")
end
print("ESC read-back after save: " .. checks .. " assertions passed")
