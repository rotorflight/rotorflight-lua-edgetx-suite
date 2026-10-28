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

local function buildPage(delta)
  local captured = {}
  local controls = {}
  function controls.appendTextField(_, _, _, _, _, options)
    captured.nameLength = options.length
    return 0
  end
  function controls.appendComboSelect(_, _, _, _, _, choices)
    captured.choices = choices
    return 0
  end
  function controls.appendRadioSwitch()
    return 0
  end

  -- Each scenario gets a fresh page and session. With no MSP queue, build uses
  -- the session's configuration and hands the real choices to the UI helpers.
  local env = setmetatable({
    rfsuite = { session = { setup_configuration = {
      task_delta_time_gyro = delta,
      pid_process_denom = 1
    } } }
  }, { __index = _G })
  env._G = env

  local stubs = {
    ["ui/controls.lua"] = controls,
    ["app/pages/settings/common.lua"] = {
      pageT = function()
        return function(_, _, fallback) return fallback end
      end
    },
    ["tasks/msp/runtime.lua"] = { getState = function() return {} end },
    ["tasks/msp/save_pipeline.lua"] = { takeResult = function() return nil end },
    ["ui/loading_overlay.lua"] = {
      append = function() error("unexpected loading overlay without an MSP queue") end
    }
  }
  local actual = {
    ["tasks/msp/api/name.lua"] = true,
    ["tasks/msp/api/advanced_config.lua"] = true,
    ["tasks/msp/api/feature_config.lua"] = true,
    ["tasks/msp/api/status.lua"] = true
  }
  function env.loadScript(path)
    local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
    if stubs[relative] then return function() return stubs[relative] end end
    if actual[relative] then return assert(loadfile("src/rfsuite/" .. relative, "t", env)) end
    error("unexpected loadScript path: " .. tostring(path))
  end

  local page = assert(loadfile("src/rfsuite/app/pages/setup/configuration/page.lua", "t", env))()
  page.build({ children = {}, x = 0, y = 0, w = 800, h = 400 })
  return captured
end

local cases = {
  { delta = 125, labels = { "8.00 kHz", "4.00 kHz", "2.67 kHz", "2.00 kHz" } },
  { delta = 250, labels = { "4.00 kHz", "2.00 kHz", "1.33 kHz", "1.00 kHz" } },
  { delta = 312, labels = { "3.21 kHz", "1.60 kHz", "1.07 kHz", "0.80 kHz" } },
  { delta = 150, labels = { "6.67 kHz", "3.33 kHz", "2.22 kHz", "1.67 kHz" } }
}

for _, case in ipairs(cases) do
  local label = string.format("%d us", case.delta)
  scenario(label, function()
    local choices = assert(buildPage(case.delta).choices, "PID-loop choices missing")
    equal(#choices, 4, label .. " choice count")
    for denom = 1, 4 do
      local choice = choices[denom]
      equal(choice and choice.value, denom, label .. " divisor " .. denom)
      equal(choice and choice.label, case.labels[denom], label .. " label " .. denom)
    end
  end)
end

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
