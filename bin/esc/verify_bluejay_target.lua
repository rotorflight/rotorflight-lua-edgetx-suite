-- Run the real Bluejay page through target isolation, session restore and save refusal.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

-- Keep a failed scenario in the summary, including errors from the real page.
local function scenario(label, run)
  local ok, err = pcall(run)
  equal(ok and "no error" or tostring(err), "no error", label)
end

local pagePath = "src/rfsuite/app/pages/setup/esc_motors/esc_tools/escmfg/bluejay/page.lua"
local pending = {}
local ticks = 0
local readReplies = 0
local refusedReplies = 0
local rows = {}
local header = nil
local firmware = nil
local version = nil
local notice = nil

local queue = {}
function queue:add(message)
  pending[#pending + 1] = message
end

-- Capture the values and callbacks supplied by the real page's build function.
local controls = {
  appendStaticSectionHeader = function(_, _, _, _, text) header = text end,
  appendEscSubheader = function(_, _, _, _, fw, ver)
    firmware, version = fw, ver
    return 20
  end,
  appendComboSelect = function(_, _, _, _, label, _, value, set)
    rows[label] = { value = value, set = set }
    return 20
  end,
  appendNumberField = function(_, _, _, _, label, options)
    rows[label] = { value = options.get(), set = options.set }
    return 20
  end
}

local good = {
  [5] = 209,
  parsed = {
    motor_direction = 2,
    rpm_power_slope = 7,
    startup_power_min = 1110,
    startup_power_max = 1200,
    pwm_frequency = 48,
    commutation_timing = 3,
    beep_strength = 66
  },
  model = "ESC1-MODEL",
  version = "ESC1-VERSION",
  firmware = "ESC1-FIRMWARE"
}
local refused = { [5] = 209 }

-- Stub the page's dependencies, leaving its cache and connection logic real.
local modules = {
  ["app/pages/settings/common.lua"] = {
    pageT = function()
      return function(_, _, fallback) return fallback end
    end
  },
  ["ui/controls.lua"] = controls,
  ["tasks/msp/runtime.lua"] = { getState = function() return { queue = queue } end },
  ["tasks/msp/api/esc_parameters_bluejay.lua"] = {
    command = 217,
    writeCommand = 218,
    parse = function(buf)
      if not buf.parsed then refusedReplies = refusedReplies + 1 end
      return buf.parsed
    end,
    buildWritePayload = function(data) return data end
  },
  ["tasks/msp/api/4wif_esc_fwd_prog.lua"] = {
    -- A synthetic command identifier, retained from the target-isolation probe.
    writeCommand = 245,
    buildWritePayload = function(data) return { data.target } end
  },
  ["app/pages/setup/esc_motors/esc_tools/escmfg/bluejay/init.lua"] = {
    getEscModel = function(buf) return buf.model end,
    getEscVersion = function(buf) return buf.version end,
    getEscFirmware = function(buf) return buf.firmware end,
    supportsLedControl = function() return false end
  },
  ["ui/loading_overlay.lua"] = {
    append = function() end,
    appendNotice = function(_, options) notice = options.press end
  },
  ["ui/confirm_dialog.lua"] = {}
}

_G.rfsuite = { palette = { accent = 0 }, session = { esc4WayMotorCount = 2 } }
_G.SMLSIZE = 0
_G.getTime = function() return ticks end
_G.loadScript = function(path)
  local relative = string.gsub(path, "^/SCRIPTS/TOOLS/rfsuite%-core/", "")
  local module = modules[relative]
  assert(module, "unexpected module: " .. relative)
  return function() return module end
end

local ctx = {
  children = {}, x = 0, y = 0, w = 480, h = 320,
  requestRebuild = function() end
}

local function render(page)
  rows, header, firmware, version, notice = {}, nil, nil, nil, nil
  ctx.children = {}
  page.build(ctx)
  if notice then
    local dismiss = notice
    notice = nil
    dismiss()
    ctx.children = {}
    page.build(ctx)
  end
end

-- Drive the real connection state machine with a virtual clock, acknowledging
-- target reset/select writes before delivering the requested parameter reply.
local function deliverRead(page, reply)
  local before = readReplies
  for _ = 1, 12 do
    while #pending > 0 do
      local message = table.remove(pending, 1)
      if message.command == 217 then
        readReplies = readReplies + 1
        message.processReply(message, reply)
      else
        assert(message.command == 245, "unexpected queued command")
        message.processReply(message, {})
      end
    end
    page.wakeup(ctx)
    if readReplies > before and #pending == 0 then
      render(page)
      return
    end
    ticks = ticks + 300
  end
  error("no parameter read was queued")
end

local function rowValue(label)
  return assert(rows[label], "missing row: " .. label).value
end

local function selectTarget(value)
  assert(rows["ESC Target"], "missing ESC Target control").set(value)
end

local function assertSaveRefused(page, label)
  local queued = #pending
  local reported = nil
  local result = page.onSave({ reportSave = function(data) reported = data.message end })
  equal(result, false, label .. " save remains refused without a parsed read")
  equal(reported, "Read the ESC before saving.", label .. " save keeps the not-read message")
  equal(#pending, queued, label .. " refused save queues no write")
end

local page
scenario("initial ESC 1 read", function()
  -- Positive control: distinctive values must reach the real reply handler and UI.
  page = assert(loadfile(pagePath))()
  render(page)
  deliverRead(page, good)
  equal(header, "Bluejay Configurator - ESC1-MODEL", "good reply reaches the model text")
  equal(rowValue("Motor Direction"), 2, "good reply reaches the config")
  equal(rowValue("Min Startup Power"), 1110, "good reply reaches the numeric field")
  equal(_G.rfsuite.session.setup_esc_motors_esc_tools_bluejay.escModel,
    "ESC1-MODEL", "good reply populates the session")
end)

scenario("switch to ESC 2", function()
  -- Exercise the actual target callback and subsequent ensureLoaded/build path.
  selectTarget(1)
  render(page)
  deliverRead(page, refused)
  equal(rowValue("ESC Target"), 1, "target control switches to ESC 2")
  equal(header, "Bluejay Configurator", "ESC 2 does not show ESC 1's model")
  equal(firmware, nil, "ESC 2 does not show ESC 1's firmware")
  equal(version, nil, "ESC 2 does not show ESC 1's version")
  equal(rowValue("Motor Direction"), 0, "ESC 2 shows the not-read direction")
  equal(rows["Rampup Start Power"] and rows["Rampup Start Power"].value,
    0, "ESC 2 shows the not-read layout and config")
  equal(rowValue("Min Startup Power"), 1000, "ESC 2 shows the not-read startup power")
  equal(rowValue("Max Startup Power"), 1300, "ESC 2 shows the not-read maximum startup power")
  equal(rowValue("PWM Frequency"), 0, "ESC 2 shows the not-read PWM frequency")
  assertSaveRefused(page, "ESC 2")
end)

scenario("reopen ESC 1", function()
  -- Keep the session cache when loading a fresh page. onClose deliberately removes
  -- it, so calling onClose here would not exercise session restoration itself.
  assert(#pending == 0, "reopen requires a drained queue")
  page = assert(loadfile(pagePath))()
  render(page)
  deliverRead(page, refused)
  equal(rowValue("ESC Target"), 0, "reopened page selects ESC 1")
  equal(header, "Bluejay Configurator - ESC1-MODEL", "same-target model is restored")
  equal(firmware, "ESC1-FIRMWARE", "same-target firmware is restored")
  equal(version, "ESC1-VERSION", "same-target version is restored")
  equal(rowValue("Motor Direction"), 2, "same-target direction is restored")
  equal(rowValue("Min Startup Power"), 1110, "same-target numeric config is restored")
  assertSaveRefused(page, "reopened ESC 1")
  equal(readReplies, 3, "one good read and two refused reads are delivered")
  equal(refusedReplies, 2, "two replies are refused by the parser")
end)

print("Bluejay target: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
