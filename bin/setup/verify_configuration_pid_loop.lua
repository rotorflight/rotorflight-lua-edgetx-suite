-- Runs Configuration PID-loop label and craft-name limit checks with desktop Lua 5.3.

local checks, failures = 0, 0

local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print(string.format("FAIL %s: expected %s, got %s", label, tostring(expected), tostring(actual)))
  end
end

local function scenario(label, run)
  local ok, err = pcall(run)
  if not ok then
    equal(tostring(err), "no error", label .. " scenario")
  end
end

local function boardReply(rate)
  -- Identifier, revision, type, capabilities and four empty length-prefixed strings.
  local buf = {84, 69, 83, 84, 0, 0, 0, 0, 0, 0, 0, 0}
  for _ = 1, 32 do buf[#buf + 1] = 0 end -- Signature.
  buf[#buf + 1] = 0 -- MCU type.
  buf[#buf + 1] = 0 -- Configuration state.
  if rate ~= nil then
    buf[#buf + 1] = rate % 256
    buf[#buf + 1] = math.floor(rate / 256)
    for _ = 1, 6 do buf[#buf + 1] = 0 end -- Problems and device counts.
  end
  return buf
end

local function buildPage(delta, denom)
  local captured = { rebuilds = 0, overlays = 0 }
  local queue = { messages = {} }
  function queue:add(message)
    self.messages[#self.messages + 1] = message
  end
  local controls = {}
  function controls.appendTextField(_, _, _, _, _, options)
    captured.nameLength = options.length
    return 0
  end
  function controls.appendComboSelect(_, _, _, _, _, choices, selected)
    captured.choices = choices
    captured.selected = selected
    return 0
  end
  function controls.appendRadioSwitch()
    return 0
  end

  -- Deliver the four configuration replies separately, then the optional BOARD_INFO.
  -- The real page, common lifecycle helpers and API parsers run in a fresh session.
  local env = setmetatable({
    rfsuite = { palette = {}, session = { setup_configuration = {
      task_delta_time_gyro = delta,
      pid_process_denom = denom or 1
    } } }
  }, { __index = _G })
  env._G = env

  local stubs = {
    ["ui/controls.lua"] = controls,
    ["tasks/msp/runtime.lua"] = { getState = function() return { queue = queue } end },
    ["tasks/msp/save_pipeline.lua"] = { takeResult = function() return nil end },
    ["ui/loading_overlay.lua"] = {
      append = function() captured.overlays = captured.overlays + 1 end
    }
  }
  local actual = {
    ["app/pages/settings/common.lua"] = true,
    ["tasks/msp/api/name.lua"] = true,
    ["tasks/msp/api/advanced_config.lua"] = true,
    ["tasks/msp/api/feature_config.lua"] = true,
    ["tasks/msp/api/status.lua"] = true,
    ["tasks/msp/api/board_info.lua"] = true
  }
  function env.loadScript(path)
    local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
    if stubs[relative] then return function() return stubs[relative] end end
    if actual[relative] then return assert(loadfile("src/rfsuite/" .. relative, "t", env)) end
    error("unexpected loadScript path: " .. tostring(path))
  end

  local page = assert(loadfile("src/rfsuite/app/pages/setup/configuration/page.lua", "t", env))()
  local ctx = {
    children = {}, x = 0, y = 0, w = 800, h = 400,
    requestRebuild = function() captured.rebuilds = captured.rebuilds + 1 end
  }
  function captured.build()
    ctx.children = {}
    page.build(ctx)
  end
  function captured.finishConfiguration()
    local commands = {101, 10, 90, 36} -- STATUS, NAME, ADVANCED_CONFIG, FEATURE_CONFIG.
    for _, command in ipairs(commands) do
      equal(#queue.messages, 1, "one configuration read pending")
      local message = assert(table.remove(queue.messages, 1), "configuration read missing")
      equal(message.command, command, "configuration read order")
      local buf = {}
      for i, value in ipairs(message.simulatorResponse) do buf[i] = value end
      if command == 101 then
        buf[3], buf[4] = delta % 256, math.floor(delta / 256)
      elseif command == 90 then
        buf[2] = denom or 1
      end
      message.processReply(message, buf)
      page.wakeup(ctx)
    end
    equal(#queue.messages, 0, "BOARD_INFO does not gate the first form build")
    equal(page.canSave(), true, "configuration ready before BOARD_INFO")
    captured.build()
    equal(captured.overlays, 1, "first form build needs no additional loading pass")
    equal(type(captured.choices), "table", "choices available before BOARD_INFO")
    page.wakeup(ctx)
    equal(#queue.messages, 1, "BOARD_INFO queued after the first form build")
    local message = table.remove(queue.messages, 1)
    equal(message and message.command, 4, "optional read is BOARD_INFO")
    captured.boardMessage = message
    page.wakeup(ctx)
    equal(#queue.messages, 0, "BOARD_INFO queued only once")
  end
  function captured.reply(rate, refused)
    local message = captured.boardMessage
    if message then
      if refused then message.errorHandler(message, "refused")
      else message.processReply(message, boardReply(rate)) end
    end
  end
  captured.page, captured.ctx = page, ctx
  captured.build()
  equal(captured.choices, nil, "configuration reads precede choices")
  captured.finishConfiguration()
  return captured
end

local cases = {
  { delta = 125, rate = 8000, labels = { "8.00 kHz", "4.00 kHz", "2.67 kHz", "2.00 kHz" } },
  { delta = 250, rate = 4000, labels = { "4.00 kHz", "2.00 kHz", "1.33 kHz", "1.00 kHz" } },
  { delta = 267, rate = 4000, labels = { "4.00 kHz", "2.00 kHz", "1.33 kHz", "1.00 kHz" } },
  { delta = 312, rate = 4000, labels = { "4.00 kHz", "2.00 kHz", "1.33 kHz", "1.00 kHz" } },
  { delta = 312, rate = 3200, labels = { "3.20 kHz", "1.60 kHz", "1.07 kHz", "0.80 kHz" } },
  { delta = 150, rate = 6660, labels = { "6.66 kHz", "3.33 kHz", "2.22 kHz", "1.67 kHz" } }
}

local function checkChoices(fields, labels, label)
  local choices = assert(fields.choices, "PID-loop choices missing")
  equal(#choices, #labels, label .. " choice count")
  for denom, expected in ipairs(labels) do
    local choice = choices[denom]
    equal(choice and choice.value, denom, label .. " divisor " .. denom)
    equal(choice and choice.label, expected, label .. " label " .. denom)
  end
end

for _, case in ipairs(cases) do
  local label = string.format("%d Hz, %d us", case.rate, case.delta)
  scenario(label, function()
    local fields = buildPage(case.delta)
    local rebuilds = fields.rebuilds
    fields.reply(case.rate)
    equal(fields.rebuilds, rebuilds + 1, label .. " reply requests relabelling")
    fields.build()
    checkChoices(fields, case.labels, label)
    equal(fields.page.hasUnsavedChanges(), false, label .. " labels do not dirty settings")
  end)
end

for _, mode in ipairs({"missing", "zero", "refused"}) do
  scenario("BOARD_INFO " .. mode, function()
    local fields = buildPage(312)
    local labels = {"3.0 kHz", "1.5 kHz", "1 kHz", "0.75 kHz"}
    checkChoices(fields, labels, "before BOARD_INFO")
    local rebuilds = fields.rebuilds
    fields.reply(mode == "zero" and 0 or nil, mode == "refused")
    equal(fields.rebuilds, rebuilds, mode .. " retains fallback without rebuilding")
    fields.build()
    checkChoices(fields, labels, mode .. " uses master's STATUS labels")
    equal(fields.page.canSave(), true, mode .. " does not block saving")
  end)
end

scenario("stored divisor 6", function()
  local fields = buildPage(312, 6)
  equal(#fields.choices, 5, "stored divisor adds a fifth choice")
  equal(fields.choices[5].value, 6, "stored divisor preserved")
  equal(fields.choices[5].label, "0.5 kHz", "stored divisor uses master fallback")
  equal(fields.selected, 6, "stored divisor remains selected")
  fields.reply(4000)
  fields.build()
  equal(#fields.choices, 5, "nominal labels retain the extra choice")
  for denom = 1, 4 do equal(fields.choices[denom].value, denom, "usual divisor retained") end
  equal(fields.choices[5].value, 6, "nominal labels preserve stored divisor")
  equal(fields.choices[5].label, "0.67 kHz", "stored divisor uses nominal rate")
  equal(fields.selected, 6, "relabelling preserves selected divisor")
  equal(fields.page.hasUnsavedChanges(), false, "stored divisor is not changed")
end)

scenario("late BOARD_INFO after close and reopen", function()
  local fields = buildPage(267)
  local stale = fields.boardMessage
  fields.page.onClose()
  local rebuilds = fields.rebuilds
  fields.reply(8000)
  fields.reply(nil, true)
  equal(fields.rebuilds, rebuilds, "closed page receives no rebuild")
  fields.overlays = 0
  fields.build()
  fields.finishConfiguration()
  fields.reply(4000)
  fields.build()
  rebuilds = fields.rebuilds
  if stale then stale.processReply(stale, boardReply(8000)) end
  equal(fields.rebuilds, rebuilds, "old visit cannot rebuild reopened page")
  fields.build()
  equal(fields.choices[1].label, "4.00 kHz", "old visit cannot change reopened labels")
end)

scenario("late BOARD_INFO after reload", function()
  local fields = buildPage(267)
  local stale = fields.boardMessage
  fields.page.onReload(fields.ctx)
  local rebuilds = fields.rebuilds
  if stale then stale.processReply(stale, boardReply(8000)) end
  equal(fields.rebuilds, rebuilds, "old read cannot rebuild during reload")
  fields.finishConfiguration()
  fields.reply(3200)
  fields.build()
  rebuilds = fields.rebuilds
  if stale then stale.processReply(stale, boardReply(8000)) end
  equal(fields.rebuilds, rebuilds, "old read cannot rebuild after reload")
  fields.build()
  equal(fields.choices[1].label, "3.20 kHz", "reload keeps its own nominal rate")
end)

scenario("craft name", function()
  local fields = buildPage(250)
  local nameApi = assert(loadfile("src/rfsuite/tasks/msp/api/name.lua"))()
  -- An overlong ASCII name exposes the actual writer's truncation length.
  local payload = nameApi.buildWritePayload({ name = "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345" })
  equal(#payload, 16, "MSP_SET_NAME write length")
  equal(fields.nameLength, 16, "craft-name field limit")
  equal(fields.nameLength, #payload, "craft-name field limit matches MSP_SET_NAME")
end)

print(string.format("Configuration PID-loop and craft-name checks: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
