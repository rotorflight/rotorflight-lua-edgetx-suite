-- Run the real governor connect task, effective-mode helper and tuning pages with scripted MSP replies.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function scenario(label, run)
  local function eq(actual, expected, detail)
    equal(actual, expected, label .. " " .. detail)
  end
  -- Module loading belongs inside the protected scenario too: a missing helper
  -- must fail the check without aborting the remaining scenarios with a traceback.
  local ok, err = pcall(function() run(eq) end)
  eq(ok, true, "scenario completed" .. (ok and "" or ": " .. tostring(err)))
end

local sourceRoot = "src/rfsuite/"
local function loadModule(path)
  return assert(loadfile(sourceRoot .. path))()
end

local function installLoader(stubs)
  function loadScript(path)
    local relative = assert(string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$"), path)
    if stubs[relative] then return function() return stubs[relative] end end
    return loadfile(sourceRoot .. relative)
  end
end

local function beginConnect(eq)
  local pending = {}
  local queue = {}
  function queue:add(message)
    pending[#pending + 1] = message
  end
  installLoader({
    ["lib/log.lua"] = { emit = function() end },
    ["tasks/msp/runtime.lua"] = { getState = function() return { queue = queue } end }
  })
  -- Stand in for the previous board, including a known enabled feature.
  _G.rfsuite = { session = { governorMode = 4, governorFeature = true, governor_config = {} } }
  local governorApi = loadModule("tasks/msp/api/governor_config.lua")
  local featureApi = loadModule("tasks/msp/api/feature_config.lua")
  local task = loadModule("tasks/events/common/governor_config.lua")
  local function pop(command)
    eq(#pending, 1, "exactly one pending request")
    local message = assert(table.remove(pending, 1), "pending request missing")
    eq(message.command, command, "MSP command")
    return message
  end
  local function governorReply(message, mode)
    local buf = {}
    for i, value in ipairs(governorApi.simulatorResponse) do buf[i] = value end
    buf[1] = mode
    message.processReply(message, buf)
  end
  task.wakeup()
  eq(task.isComplete(), false, "initial read is incomplete")
  eq(_G.rfsuite.session.governorMode, nil, "initial read clears previous mode")
  eq(_G.rfsuite.session.governorFeature, nil, "initial read clears previous feature")
  local message = pop(governorApi.command)
  task.wakeup()
  eq(#pending, 0, "pending governor read is not duplicated")
  return {
    task = task, message = message, pending = pending, pop = pop,
    governorReply = governorReply, featureApi = featureApi,
    governor = loadModule("lib/governor.lua"), session = _G.rfsuite.session
  }
end

for _, enabled in ipairs({ false, true }) do
  scenario("connect feature " .. (enabled and "on" or "off"), function(eq)
    local h = beginConnect(eq)
    local task, session = h.task, h.session
    eq(h.message.timeout * (h.message.maxRetries + 1) < 25, true, "governor read budget stays below task timeout")
    h.governorReply(h.message, 2) -- DIRECT; ELECTRO is mode 3.
    eq(session.governorMode, 2, "governor reply stores mode")
    eq(task.isComplete(), true, "governor reply completes the task, as before")
    eq(session.governorFeature, nil, "feature is unknown before its reply")
    eq(h.governor.getEffectiveMode(session), 2, "unknown feature keeps stored mode")
    -- The feature read trails the completed task instead of lengthening the connect chain.
    local featureMessage = h.pop(h.featureApi.command)
    task.wakeup()
    eq(#h.pending, 0, "completed task queues nothing more")
    featureMessage.processReply(featureMessage,
      h.featureApi.buildWritePayload({ enabledFeatures = enabled and (1 << 26) or 0 }))
    eq(session.governorMode, 2, "feature reply preserves stored mode")
    eq(session.governorFeature, enabled, "feature reply stores feature flag")
    eq(h.governor.getEffectiveMode(session), enabled and 2 or 0, "effective mode")
    task.reset()
    eq(task.isComplete(), false, "reset clears completion")
    eq(session.governorMode, nil, "reset clears stored mode")
    eq(session.governorFeature, nil, "reset clears feature flag")
    eq(session.governor_config, nil, "reset clears governor configuration")
  end)
end

-- Failed, malformed or dropped feature reads preserve the stored mode with an unknown feature.
for _, failure in ipairs({ "max_retries", "refused", "cleared", "malformed" }) do
  scenario("feature read " .. failure, function(eq)
    local h = beginConnect(eq)
    h.governorReply(h.message, 2)
    local message = h.pop(h.featureApi.command)
    if failure == "malformed" then
      message.processReply(message, {})
    else
      message.errorHandler(message, failure)
    end
    eq(h.task.isComplete(), true, "task stays complete")
    eq(h.session.governorMode, 2, "failed feature read preserves stored mode")
    eq(h.session.governorFeature, nil, "failed feature read leaves feature unknown")
    eq(h.governor.getEffectiveMode(h.session), 2, "unknown feature keeps stored mode")
    h.task.wakeup()
    eq(#h.pending, 0, "a failed feature read is not repeated by the task")
  end)
end

scenario("governor read failure", function(eq)
  local h = beginConnect(eq)
  h.message.errorHandler(h.message, "max_retries")
  eq(h.task.isComplete(), true, "failed governor read completes task")
  eq(#h.pending, 0, "no feature read without a governor reply")
  eq(h.session.governorMode, nil, "no stored mode")
end)

scenario("reconnect drops the trailing feature read", function(eq)
  -- The session table is kept and reset in place across a reconnect; what stops the previous
  -- board's answer is the queue clear on disconnect, which reports "cleared" and sets nothing.
  local h = beginConnect(eq)
  h.governorReply(h.message, 3)
  local message = h.pop(h.featureApi.command)
  h.task.reset()
  message.errorHandler(message, "cleared")
  eq(h.session.governorFeature, nil, "a cleared feature read sets nothing")
  eq(h.session.governorMode, nil, "reset cleared the stored mode")
end)

for _, spec in ipairs({
  { label = "missing session", expected = nil },
  { label = "empty session", session = {}, expected = nil },
  { label = "feature off without mode", session = { governorFeature = false }, expected = 0 }
}) do
  scenario(spec.label, function(eq)
    local governor = loadModule("lib/governor.lua")
    eq(governor.getEffectiveMode(spec.session), spec.expected, "effective mode")
  end)
end

local function newPage(path, mode, feature)
  _G.rfsuite = {
    palette = {},
    session = {
      governorMode = mode, governorFeature = feature, governor_profile = {},
      apiVersion = "12.0.9"
    }
  }
  -- Suppress unrelated page-load reads. The real pages still load their APIs and
  -- helper; only the queue runtime, profile selection and UI services are stubbed.
  installLoader({
    ["tasks/msp/runtime.lua"] = { getState = function() return nil end },
    ["app/pages/settings/common.lua"] = {
      createProfileAwareRuntime = function() return {} end,
      pageT = function(pageKey)
        return function(_, key)
          if key == "title" then
            return pageKey == "flight_tuning_governor" and "Governor" or "Tail Rotor"
          end
          return key
        end
      end
    },
    ["ui/controls.lua"] = {
      CTRL_H = 32,
      labelY = function(y) return y end,
      computeGridMetrics = function() return { labelW = 100, gap = 8, cellW = 60 } end,
      appendStaticSectionHeader = function(children, _, _, _, title)
        children[#children + 1] = { type = "section", text = title }
      end
    },
    ["lib/profile.lua"] = { getActivePidProfile = function() return 1 end },
    ["lib/sensors.lua"] = {},
    ["ui/loading_overlay.lua"] = {}
  })
  local page = loadModule(path)
  local ctx = {
    children = {}, x = 0, y = 0, w = 480, h = 272,
    navButtons = { save = { enabled = true }, reload = { enabled = true } }
  }
  return page, ctx
end

local function countFields(children)
  local count = 0
  for _, child in ipairs(children) do
    if child.type == "numberEdit" then count = count + 1 end
  end
  return count
end

local modeNames = { [0] = "OFF", "LIMIT", "DIRECT", "ELECTRO", "NITRO" }
for mode = 0, 4 do
  for _, featureState in ipairs({ "unknown", "off", "on" }) do
    local feature
    if featureState == "off" then feature = false end
    if featureState == "on" then feature = true end
    local effective = feature == false and 0 or mode
    local label = "mode " .. mode .. " feature " .. featureState
    scenario("Governor " .. label, function(eq)
      local page, ctx = newPage("app/pages/flight_tuning/governor/page.lua", mode, feature)
      page.build(ctx)
      local fields = countFields(ctx.children)
      eq(ctx.children[1].text, "Governor #1 - " .. modeNames[effective], "heading")
      if effective == 0 then
        eq(fields, 0, "OFF hides fields")
        eq(ctx.navButtons.save.enabled, false, "OFF disables Save")
      else
        eq(fields > 0, true, "enabled mode shows fields")
        eq(ctx.navButtons.save.enabled, true, "enabled mode keeps Save enabled")
        if effective >= 3 then eq(fields > 2, true, "ELECTRO/NITRO shows gains") end
      end
    end)

    for _, readComplete in ipairs({ false, true }) do
      scenario("Tail Rotor " .. label .. " profile read " .. tostring(readComplete), function(eq)
        local page, ctx = newPage("app/pages/flight_tuning/advanced/tail_rotor/page.lua", mode, feature)
        -- Use the page's existing public UI state to isolate its TTA gates from
        -- profile transport. No export or implementation is added to the page.
        page.ui.runtime.governorReadComplete = readComplete
        page.build(ctx)
        eq(ctx.children[1].text, "Tail Rotor #1", "real page built")
        local ttaRows, ttaFields = 0, {}
        for _, child in ipairs(ctx.children) do
          if child.type == "label" and child.text == "Tail Torque Assist" then
            ttaRows = ttaRows + 1
          elseif child.type == "numberEdit" and ttaRows > 0 then
            ttaFields[#ttaFields + 1] = child
          end
        end
        local visible = effective >= 1
        eq(ttaRows, visible and 1 or 0, "TTA row follows effective mode")
        eq(#ttaFields, visible and 2 or 0, "TTA gain and limit visibility")
        eq(countFields(ctx.children), visible and 9 or 7, "PID fields remain visible")
        for i, field in ipairs(ttaFields) do
          eq(field.active(), readComplete, "TTA field " .. i .. " requires profile read")
        end
      end)
    end
  end
end

for _, spec in ipairs({
  { path = "app/pages/flight_tuning/governor/page.lua", label = "Governor" },
  { path = "app/pages/flight_tuning/advanced/tail_rotor/page.lua", label = "Tail Rotor" }
}) do
  scenario(spec.label .. " rebuilds when the feature arrives after its build", function(eq)
    local page, ctx = newPage(spec.path, 3, nil)
    local rebuilds = 0
    ctx.requestRebuild = function() rebuilds = rebuilds + 1 end
    page.build(ctx)
    page.wakeup(ctx)
    eq(rebuilds, 0, "no rebuild while the feature is unchanged")
    _G.rfsuite.session.governorFeature = false
    page.wakeup(ctx)
    eq(rebuilds, 1, "a late feature reply asks for one rebuild")
    page.wakeup(ctx)
    eq(rebuilds, 1, "and only once")
    _G.rfsuite.session.governorFeature = true
    page.wakeup(ctx)
    eq(rebuilds, 2, "a later change asks again")
  end)
end

print("Governor effective mode: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
